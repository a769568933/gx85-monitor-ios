import Foundation

/// Serial-queue value type. Handles JPEG boundaries, not undocumented packet sequence numbers.
public struct JPEGFrameAssembler {
    public let maxBytes: Int
    public let timeout: TimeInterval
    public private(set) var droppedFrames = 0
    private var bytes: [UInt8] = []
    private var trailingFF = false
    private var startedAt: TimeInterval?

    public var bufferedBytes: Int { bytes.count + (trailingFF ? 1 : 0) }

    public init(maxBytes: Int = 2 * 1024 * 1024, timeout: TimeInterval = 0.5) {
        self.maxBytes = max(4, maxBytes)
        self.timeout = max(0.01, timeout)
    }

    public mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        trailingFF = false
        startedAt = nil
    }

    public mutating func append(_ datagram: Data, now: TimeInterval) -> [Data] {
        if let start = startedAt, now - start > timeout {
            droppedFrames += 1
            reset()
        }
        var frames: [Data] = []
        for byte in datagram {
            if startedAt == nil {
                if trailingFF && byte == 0xd8 {
                    bytes = [0xff, 0xd8]
                    startedAt = now
                    trailingFF = false
                } else {
                    trailingFF = byte == 0xff
                }
                continue
            }
            let previous = bytes.last
            bytes.append(byte)
            if bytes.count > maxBytes {
                droppedFrames += 1
                reset()
                trailingFF = byte == 0xff
            } else if previous == 0xff && byte == 0xd8 {
                droppedFrames += 1
                bytes = [0xff, 0xd8]
                startedAt = now
            } else if previous == 0xff && byte == 0xd9 {
                frames.append(Data(bytes))
                reset()
            }
        }
        return frames
    }
}
