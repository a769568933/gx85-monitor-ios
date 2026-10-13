import Foundation

/// One waiting value and one scheduled delivery, even if the consuming executor is blocked.
public final class LatestValueSlot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var scheduled = false
    public init() {}
    public func offer(_ newValue: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        value = newValue
        if scheduled { return false }
        scheduled = true
        return true
    }
    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        defer { value = nil; scheduled = false }
        return value
    }
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        value = nil
        // An already scheduled delivery will clear its slot using take().
    }
}
