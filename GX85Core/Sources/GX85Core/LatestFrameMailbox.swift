import Foundation

/// Owned by a serial queue. Offering replaces the waiting frame instead of adding latency.
public struct LatestFrameMailbox {
    private var pending: Data?
    public init() {}
    public mutating func offer(_ frame: Data) { pending = frame }
    public mutating func take() -> Data? {
        defer { pending = nil }
        return pending
    }
    public mutating func reset() { pending = nil }
}
