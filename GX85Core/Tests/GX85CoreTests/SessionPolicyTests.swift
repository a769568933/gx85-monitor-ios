import XCTest
@testable import GX85Core

final class SessionPolicyTests: XCTestCase {
    func testReconnectAfterThreeFailures() {
        var policy = SessionPolicy()
        XCTAssertEqual(policy.recordHealth(succeeded: false), .none)
        XCTAssertEqual(policy.recordHealth(succeeded: false), .none)
        XCTAssertEqual(policy.recordHealth(succeeded: false), .reconnect)
        _ = policy.recordHealth(succeeded: true)
        XCTAssertEqual(policy.recordHealth(succeeded: false), .none)
    }

    func testHealthyControlRestartsOnlyStalledStream() {
        var policy = SessionPolicy()
        policy.streamStarted(now: 0)
        _ = policy.recordHealth(succeeded: true)
        XCTAssertEqual(policy.evaluate(now: 2.9), .none)
        XCTAssertEqual(policy.evaluate(now: 3), .restartStream)
        policy.streamRestarted(now: 3)
        XCTAssertEqual(policy.evaluate(now: 4), .none)
        XCTAssertEqual(policy.evaluate(now: 6), .reconnect)
        policy.frameReceived(now: 6.1)
        XCTAssertEqual(policy.evaluate(now: 6.5), .none)
    }

    func testSlowRestartGetsGraceAfterResponse() {
        var policy = SessionPolicy()
        policy.streamStarted(now: 0)
        _ = policy.recordHealth(succeeded: true)
        XCTAssertEqual(policy.evaluate(now: 3), .restartStream)
        XCTAssertEqual(policy.evaluate(now: 5.9), .none)
        policy.streamRestarted(now: 5.9)
        XCTAssertEqual(policy.evaluate(now: 6), .none)
        XCTAssertEqual(policy.evaluate(now: 8.8), .none)
        XCTAssertEqual(policy.evaluate(now: 9), .reconnect)
    }

    func testRetriesStopAfter1248Seconds() {
        var policy = SessionPolicy()
        XCTAssertEqual(policy.nextReconnectDelay(), 1)
        XCTAssertEqual(policy.nextReconnectDelay(), 2)
        XCTAssertEqual(policy.nextReconnectDelay(), 4)
        XCTAssertEqual(policy.nextReconnectDelay(), 8)
        XCTAssertNil(policy.nextReconnectDelay())
        policy.connectionSucceeded()
        XCTAssertEqual(policy.nextReconnectDelay(), 1)
    }

    func testCapturePauseDoesNotTriggerImmediateReconnect() {
        var policy = SessionPolicy()
        policy.streamStarted(now: 0)
        _ = policy.recordHealth(succeeded: true)
        policy.captureStarted()
        XCTAssertEqual(policy.evaluate(now: 4), .none)
        policy.captureFinished(now: 4)
        XCTAssertEqual(policy.evaluate(now: 5.9), .none)
        XCTAssertEqual(policy.evaluate(now: 6), .restartStream)
    }
}
