import Foundation

public struct SessionPolicy {
    public enum Action: Equatable { case none, restartStream, reconnect, giveUp }
    private var failures = 0
    private var lastFrameOrStart: TimeInterval?
    private var restartedAt: TimeInterval?
    private var restarting = false
    private var healthy = false
    private var capturing = false
    private var suppressUntil: TimeInterval = 0
    private var retryIndex = 0

    public init() {}
    public mutating func connectionSucceeded() { retryIndex = 0 }
    public mutating func streamStarted(now: TimeInterval) {
        lastFrameOrStart = now
        restartedAt = nil
        restarting = false
        failures = 0
        healthy = true
    }
    public mutating func frameReceived(now: TimeInterval) {
        lastFrameOrStart = now
        restartedAt = nil
        restarting = false
    }
    public mutating func streamRestarted(now: TimeInterval) {
        restarting = false
        restartedAt = now
    }
    public mutating func captureStarted() { capturing = true }
    public mutating func captureFinished(now: TimeInterval) {
        capturing = false
        suppressUntil = now + 2
    }
    public mutating func recordHealth(succeeded: Bool) -> Action {
        healthy = succeeded
        failures = succeeded ? 0 : failures + 1
        return failures >= 3 ? .reconnect : .none
    }
    public mutating func evaluate(now: TimeInterval) -> Action {
        guard healthy, !capturing, !restarting, now >= suppressUntil, let last = lastFrameOrStart else { return .none }
        if let restarted = restartedAt { return now - restarted >= 3 ? .reconnect : .none }
        if now - last >= 3 {
            restarting = true
            return .restartStream
        }
        return .none
    }
    public mutating func nextReconnectDelay() -> TimeInterval? {
        let delays: [TimeInterval] = [1, 2, 4, 8]
        guard retryIndex < delays.count else { return nil }
        defer { retryIndex += 1 }
        return delays[retryIndex]
    }
}
