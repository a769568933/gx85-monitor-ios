import Foundation

/// Bounds retained packets before work is scheduled on the frame-processing queue.
public final class BoundedDatagramInbox: @unchecked Sendable {
    public struct Item: Sendable { public let data: Data; public let generation: UUID }
    public struct Batch { public let items: [Item]; public let dropped: Int }
    private let lock = NSLock()
    private let maxBytes: Int
    private let maxPackets: Int
    private var items: [Item] = []
    private var size = 0
    private var dropped = 0
    private var drainScheduled = false

    public init(maxBytes: Int = 1024 * 1024, maxPackets: Int = 32) {
        self.maxBytes = max(1, maxBytes)
        self.maxPackets = max(1, maxPackets)
    }

    public var bufferedBytes: Int { lock.lock(); defer { lock.unlock() }; return size }

    /// True only when the caller must schedule a drain. New offers never enqueue per-packet work.
    public func offer(_ data: Data, generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= maxBytes else { dropped += 1; return false }
        while !items.isEmpty && (size + data.count > maxBytes || items.count >= maxPackets) {
            size -= items.removeFirst().data.count
            dropped += 1
        }
        items.append(Item(data: data, generation: generation))
        size += data.count
        if drainScheduled { return false }
        drainScheduled = true
        return true
    }

    public func takeBatch(limit: Int) -> Batch {
        lock.lock(); defer { lock.unlock() }
        let count = min(items.count, max(1, limit))
        let batch = Array(items.prefix(count))
        items.removeFirst(count)
        size -= batch.reduce(0) { $0 + $1.data.count }
        let loss = dropped
        dropped = 0
        return Batch(items: batch, dropped: loss)
    }

    public func needsAnotherDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if items.isEmpty { drainScheduled = false; return false }
        return true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll(keepingCapacity: true)
        size = 0
        dropped = 0
        // Keep the scheduled drain flag: an already queued drain still owns the scheduling slot.
    }
}
