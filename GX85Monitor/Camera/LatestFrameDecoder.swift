import Foundation
import UIKit
import ImageIO
import GX85Core

final class LatestFrameDecoder: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "GX85Monitor.frames", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "GX85Monitor.decode", qos: .userInitiated)
    private var mailbox = LatestFrameMailbox()
    private var assembler = JPEGFrameAssembler()
    private var decoding = false
    private var generation = UUID()
    private var packets = 0
    private var invalidImages = 0
    private var ingressDropped = 0
    private let inbox = BoundedDatagramInbox()
    private let displaySlot = LatestValueSlot<(UIImage, UUID)>()
    private let onImage: @MainActor @Sendable (UIImage, UUID) -> Void
    private let onStats: @Sendable (Int, Int, Int, Int, UUID) -> Void
    private var lastStats: TimeInterval = 0

    init(onImage: @escaping @MainActor @Sendable (UIImage, UUID) -> Void, onStats: @escaping @Sendable (Int, Int, Int, Int, UUID) -> Void) {
        self.onImage = onImage
        self.onStats = onStats
    }

    func reset(generation: UUID) {
        inbox.reset()
        displaySlot.reset()
        stateQueue.async {
            self.generation = generation
            self.mailbox.reset()
            self.assembler = JPEGFrameAssembler()
            self.packets = 0
            self.invalidImages = 0
            self.ingressDropped = 0
            self.lastStats = 0
            // The in-flight decode remains single; its result is invalidated by generation.
        }
    }

    func receive(_ datagram: Data, generation: UUID) {
        if inbox.offer(datagram, generation: generation) {
            stateQueue.async { self.drain() }
        }
    }

    private func drain() {
        let batch = inbox.takeBatch(limit: 4)
        if batch.dropped > 0 { assembler.reset(); ingressDropped += batch.dropped }
        let now = ProcessInfo.processInfo.systemUptime
        for item in batch.items {
            guard item.generation == generation else { continue }
            packets += 1
            for frame in assembler.append(item.data, now: now) { mailbox.offer(frame) }
        }
        if now - lastStats >= 1 {
            lastStats = now
            onStats(packets, assembler.droppedFrames, invalidImages, ingressDropped, generation)
        }
        pump()
        if inbox.needsAnotherDrain() { stateQueue.async { self.drain() } }
    }

    private func offerDisplay(_ image: UIImage, generation: UUID) {
        if displaySlot.offer((image, generation)) {
            DispatchQueue.main.async {
                if let (latest, current) = self.displaySlot.take() {
                    self.onImage(latest, current)
                }
            }
        }
    }

    func submit(_ jpeg: Data, generation: UUID) {
        stateQueue.async {
            guard self.generation == generation else { return }
            self.mailbox.offer(jpeg)
            self.pump()
        }
    }

    private func pump() {
        guard !decoding, let data = mailbox.take() else { return }
        decoding = true
        let current = generation
        decodeQueue.async {
            let image: UIImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 8192, height <= 8192,
                      width * height <= 16_000_000,
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
                let exif = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
                let orientation: UIImage.Orientation
                switch exif {
                case 2: orientation = .upMirrored
                case 3: orientation = .down
                case 4: orientation = .downMirrored
                case 5: orientation = .leftMirrored
                case 6: orientation = .right
                case 7: orientation = .rightMirrored
                case 8: orientation = .left
                default: orientation = .up
                }
                return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
            }
            self.stateQueue.async {
                self.decoding = false
                if self.generation == current {
                    if let image { self.offerDisplay(image, generation: current) }
                    else { self.invalidImages += 1 }
                }
                self.pump()
            }
        }
    }
}
