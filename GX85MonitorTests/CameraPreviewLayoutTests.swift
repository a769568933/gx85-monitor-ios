import SwiftUI
import UIKit
import XCTest
import GX85Core
@testable import GX85Monitor

@MainActor
final class CameraPreviewLayoutTests: XCTestCase {
    // A cyan marker in a synthetic live frame reveals actual SwiftUI placement,
    // including parent layout, safe areas and notices. No pure-fit mirror assertion.
    func testPreviewCenterAndNoticeDoNotMoveRealRenderedImage() async throws {
        let cases: [(CGSize, CGSize)] = [
            (CGSize(width: 390, height: 844), CGSize(width: 640, height: 480)),
            (CGSize(width: 844, height: 390), CGSize(width: 640, height: 480)),
            (CGSize(width: 390, height: 844), CGSize(width: 640, height: 360)),
            (CGSize(width: 844, height: 390), CGSize(width: 640, height: 360))
        ]
        for (size, imageSize) in cases {
            let receiver = LayoutReceiver()
            let settings = CameraSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            settings.accessID = "layout-test-camera"
            let session = CameraSession(settings: settings, makeClient: { _ in LayoutCommands() }, makeReceiver: { receiver }, controlSleep: { _ in await Task.yield() })
            session.connect()
            for _ in 0..<200 {
                if session.canCapture { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let pattern = UIGraphicsImageRenderer(size: imageSize).image { _ in
                UIColor.magenta.setFill(); UIRectFill(CGRect(origin: .zero, size: imageSize))
                UIColor.cyan.setFill(); UIRectFill(CGRect(x: imageSize.width / 2 - 32, y: imageSize.height / 2 - 32, width: 64, height: 64))
            }
            receiver.emit(try XCTUnwrap(pattern.jpegData(compressionQuality: 1)))
            for _ in 0..<200 {
                if session.image != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(session.image)
            let host = UIHostingController(rootView: CameraView(session: session).overlay(alignment: .top) {
                Text("模拟画面 · 非相机连接").font(.caption).padding(4).background(Color.black.opacity(0.8))
            })
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let before = try marker(in: host.view, size: size)
            XCTAssertEqual(before.midX, size.width / 2, accuracy: 1.5)
            XCTAssertEqual(before.midY, size.height / 2, accuracy: 1.5)
            session.capture()
            for _ in 0..<200 {
                if session.notice != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(session.notice)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let after = try marker(in: host.view, size: size)
            XCTAssertEqual(after, before, "A notice must not move or resize the rendered live frame")
            session.disconnect()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func marker(in view: UIView, size: CGSize) throws -> CGRect {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "模拟取景-\(Int(size.width))x\(Int(size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset] < 80 && pixels[offset + 1] > 190 && pixels[offset + 2] > 190 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { throw LayoutError.markerMissing }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    private enum LayoutError: Error { case markerMissing }
}

private actor LayoutCommands: CommandSending {
    func send(_ command: LumixCommand) async throws -> LumixResponse {
        // Successful captures are deliberately quiet. Exercise the remaining
        // error banner so this rendering test still covers overlay geometry.
        if command == .capture { throw CommandError.cameraRejected("err_reject") }
        return LumixResponse(status: .success, fields: ["rec": "off", "focusmode": "mf"])
    }
}
private final class LayoutReceiver: LiveViewReceiving {
    private var callback: (@Sendable (Data) -> Void)?
    func start(endpoint: CameraEndpoint, onDatagram: @escaping @Sendable (Data) -> Void) async throws { callback = onDatagram }
    func stop() { callback = nil }
    func emit(_ data: Data) { callback?(data) }
}
