import Foundation
import UIKit
import XCTest
import GX85Core
@testable import GX85Monitor

@MainActor
final class CameraSessionTests: XCTestCase {
    private func makeSession(_ commands: TestCommands, receiver: TestReceiver = TestReceiver(), clock: @escaping @Sendable () -> TimeInterval = { 0 }) -> CameraSession {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = CameraSettings(defaults: defaults)
        settings.accessID = "test-camera-uuid"
        return CameraSession(settings: settings, makeClient: { _ in commands }, makeReceiver: { receiver }, clock: clock, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, controlSleep: { _ in try Task.checkCancellation(); await Task.yield() }, makeMediaClient: { CameraMediaClient(endpoint: $0) })
    }

    func testConnectionUpgradesAdvertisedQVGAStreamBeforeStartingMonitoring() async {
        let commands = TestCommands()
        await commands.configureLiveView(size: "qvga")
        let session = makeSession(commands)
        session.connect(); await waitUntil { session.canCapture }
        let size = await commands.liveViewSize
        let streamSize = await commands.sizeWhenStreamStarted
        XCTAssertEqual(size, "vga")
        XCTAssertEqual(streamSize, "vga")
        session.disconnect()
    }

    func testUnknownHigherStreamSettingIsNotDowngradedToVGA() async {
        let commands = TestCommands()
        await commands.configureLiveView(size: "1280x960")
        let session = makeSession(commands)
        session.connect(); await waitUntil { session.canCapture }
        let size = await commands.liveViewSize
        XCTAssertEqual(size, "1280x960")
        session.disconnect()
    }

    func testMonitoringPreservesReceivedPixelsAndReportsActualResolution() async {
        let commands = TestCommands(), receiver = TestReceiver()
        let session = makeSession(commands, receiver: receiver)
        session.connect(); await waitUntil { session.canCapture }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 960), format: format).image { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1280, height: 960))
        }
        receiver.emit(source.jpegData(compressionQuality: 0.95)!)
        await waitUntil { session.image != nil }
        XCTAssertEqual(session.image?.cgImage?.width, 1280)
        XCTAssertEqual(session.image?.cgImage?.height, 960)
        XCTAssertTrue(session.diagnostics.text.contains("1280×960"))
        session.disconnect()
    }

    func testRecordingTimerStartsOnlyAfterConfirmationAndStopsWithRecording() async {
        let commands = TestCommands(), time = ManualClock()
        let session = makeSession(commands, clock: { time.now })
        session.connect(); await waitUntil { session.canCapture }
        XCTAssertNil(session.recordingElapsed)
        session.selectShootingMode(.video)
        session.performPrimaryAction()
        XCTAssertNil(session.recordingElapsed, "Click alone must not start a timer")
        await waitUntil { !session.actionInProgress && session.controlState.recordingState == .recording }
        XCTAssertEqual(session.recordingElapsed, 0)
        await time.advance(to: 17)
        XCTAssertEqual(session.recordingElapsed, 17)
        XCTAssertEqual(session.recordingTimerText, "00:17")
        session.performPrimaryAction()
        await waitUntil { !session.actionInProgress && session.controlState.recordingState == .stopped }
        XCTAssertNil(session.recordingElapsed)
        session.disconnect()
    }

    func testReconnectIntoExistingRecordingDoesNotInventClipDuration() async {
        let commands = TestCommands(), time = ManualClock()
        let session = makeSession(commands, clock: { time.now })
        session.connect(); await waitUntil { session.canCapture }
        session.selectShootingMode(.video); session.performPrimaryAction()
        await waitUntil { !session.actionInProgress && session.controlState.recordingState == .recording }
        await time.advance(to: 10)
        XCTAssertEqual(session.recordingElapsed, 10)
        session.setForeground(false)
        XCTAssertNil(session.recordingElapsed)
        session.setForeground(true)
        await waitUntil { session.canCapture && session.controlState.recordingState == .recording }
        XCTAssertNil(session.recordingElapsed)
        XCTAssertEqual(session.recordingTimerText, "时长未知")
        let starts = await commands.videoStartCount
        XCTAssertEqual(starts, 1)
        session.disconnect()
    }
    func testBodyStartedRecordingBeforeActionDoesNotInventStartTime() async {
        let commands = TestCommands()
        let session = makeSession(commands)
        session.connect(); await waitUntil { session.canCapture }
        await commands.setBodyRecording(true)
        session.selectShootingMode(.video); session.performPrimaryAction()
        await waitUntil { !session.actionInProgress && session.controlState.recordingState == .recording }
        XCTAssertNil(session.recordingElapsed)
        let starts = await commands.videoStartCount
        XCTAssertEqual(starts, 0)
        session.disconnect()
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("State transition did not arrive")
    }

    func testDisconnectIgnoresLateHandshake() async {
        let commands = TestCommands()
        await commands.holdAccess()
        let session = makeSession(commands)
        session.connect()
        for _ in 0..<200 {
            let waiting = await commands.accessWaiting
            if waiting { break }
            await Task.yield()
        }
        session.disconnect()
        await commands.releaseAccess()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(session.phase, .disconnected)
        XCTAssertFalse(session.wantsConnection)
        XCTAssertFalse(session.canCapture)
    }

    func testPlaybackChecksFreshRecordingStateBeforeStoppingStream() async {
        let commands = TestCommands()
        let session = makeSession(commands)
        session.connect()
        await waitUntil { session.canCapture }
        await commands.setBodyRecording(true)
        do { _ = try await session.beginPlayback(); XCTFail("A newly started body recording must block playback") }
        catch { }
        let playback = await commands.playbackCount
        let stops = await commands.stopStreamCount
        XCTAssertEqual(playback, 0)
        XCTAssertEqual(stops, 0)
        XCTAssertFalse(session.isBrowsing)
        session.disconnect()
    }

    func testClosingPlaybackRestoresRecordModeAndReceiver() async throws {
        let commands = TestCommands()
        let receiver = TestReceiver()
        let session = makeSession(commands, receiver: receiver)
        session.connect()
        await waitUntil { session.canCapture }
        _ = try await session.beginPlayback()
        XCTAssertTrue(session.isBrowsing)
        XCTAssertFalse(session.canCapture)
        XCTAssertGreaterThan(receiver.stops, 0)
        await session.endPlayback()
        XCTAssertFalse(session.isBrowsing)
        XCTAssertTrue(session.canCapture)
        XCTAssertEqual(receiver.starts, 2)
        let recordModes = await commands.recordModeCount
        let streams = await commands.startStreamCount
        XCTAssertEqual(recordModes, 2)
        XCTAssertEqual(streams, 2)
        session.disconnect()
    }

    func testPlaybackWatchdogDoesNotReenterRecordMode() async throws {
        let time = ManualClock()
        let commands = TestCommands()
        let receiver = TestReceiver()
        let settings = CameraSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.accessID = "playback-clock-test"
        let session = CameraSession(settings: settings, makeClient: { _ in commands }, makeReceiver: { receiver }, clock: { time.now }, sleep: { try await time.sleep($0) }, makeMediaClient: { CameraMediaClient(endpoint: $0) })
        session.connect()
        await waitUntil { session.canCapture }
        _ = try await session.beginPlayback()
        await time.advance(to: 30)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(session.isBrowsing)
        XCTAssertEqual(receiver.starts, 1)
        let modes = await commands.recordModeCount
        XCTAssertEqual(modes, 1)
        await session.endPlayback()
        session.disconnect()
    }

    func testOldAlbumCloseCannotCloseNewPlaybackOwner() async throws {
        let session = makeSession(TestCommands())
        session.connect(); await waitUntil { session.canCapture }
        _ = try await session.beginPlayback()
        let previous = try XCTUnwrap(session.playbackID)
        await session.endPlayback(owner: previous)
        _ = try await session.beginPlayback()
        let current = try XCTUnwrap(session.playbackID)
        XCTAssertNotEqual(previous, current)
        await session.endPlayback(owner: previous)
        XCTAssertTrue(session.isBrowsing)
        XCTAssertEqual(session.playbackID, current)
        await session.endPlayback(owner: current)
        session.disconnect()
    }

    func testUnknownRecordingOnConnectDoesNotForceRecordMode() async {
        let commands = TestCommands()
        await commands.setBodyRecording(true)
        await commands.setRecordingReadout(false)
        let session = makeSession(commands)
        session.connect(); await waitUntil { session.canCapture }
        let modes = await commands.recordModeCount
        XCTAssertEqual(modes, 0)
        XCTAssertEqual(session.controlState.recordingState, .unknown)
        session.disconnect()
    }

    func testBackgroundStopsReceiverAndForegroundResumesOnlyWhenWanted() async {
        let receiver = TestReceiver()
        let session = makeSession(TestCommands(), receiver: receiver)
        session.connect()
        await waitUntil { session.canCapture }
        session.setForeground(false)
        XCTAssertGreaterThan(receiver.stops, 0)
        XCTAssertFalse(session.canCapture)
        session.disconnect()
        session.setForeground(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(session.phase, .disconnected)
        XCTAssertFalse(session.wantsConnection)
    }

    func testCaptureTimeoutSentOnceAndReportsUnknown() async {
        let commands = TestCommands()
        await commands.setCaptureError(CommandError.timedOut)
        let session = makeSession(commands)
        session.connect()
        await waitUntil { session.canCapture }
        session.capture()
        await waitUntil { !session.isCapturing && session.notice != nil }
        let count = await commands.captureCount
        XCTAssertEqual(count, 1)
        XCTAssertTrue(session.notice?.contains("结果未知") == true)
        session.disconnect()
    }

    func testAcceptedCaptureDoesNotClaimSavedPhoto() async {
        let session = makeSession(TestCommands())
        session.connect()
        await waitUntil { session.canCapture }
        session.capture()
        await waitUntil { !session.isCapturing && session.notice != nil }
        XCTAssertFalse(session.notice?.contains("照片保存在") == true)
        XCTAssertTrue(session.notice?.contains("待确认") == true)
        session.disconnect()
    }

    func testUnknownVideoActionOnlyRefreshesStateBeforeMutatingCamera() async {
        let commands = TestCommands()
        await commands.setRecordingReadout(false)
        let session = makeSession(commands)
        session.connect()
        await waitUntil { session.canCapture }
        XCTAssertEqual(session.controlState.recordingState, .unknown)
        await commands.setRecordingReadout(true)
        session.selectShootingMode(.video)
        session.performPrimaryAction()
        await waitUntil { !session.actionInProgress }
        let starts = await commands.videoStartCount
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(session.controlState.recordingState, .stopped)
        session.disconnect()
    }

    func testVideoSelectionUsesVideoStartAndBackgroundDoesNotStopRecording() async {
        let commands = TestCommands()
        let session = makeSession(commands)
        session.connect()
        await waitUntil { session.canCapture }
        session.selectShootingMode(.video)
        session.performPrimaryAction()
        await waitUntil { !session.actionInProgress && session.controlState.recordingState == .recording }
        let photos = await commands.captureCount
        let starts = await commands.videoStartCount
        XCTAssertEqual(photos, 0)
        XCTAssertEqual(starts, 1)
        session.setForeground(false)
        for _ in 0..<20 { await Task.yield() }
        let stops = await commands.videoStopCount
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(session.controlState.recordingState, .unknown)
        session.disconnect()
    }

    func testConcurrentCaptureIsDisabled() async {
        let commands = TestCommands()
        await commands.holdCapture()
        let session = makeSession(commands)
        session.connect()
        await waitUntil { session.canCapture }
        session.capture()
        session.capture()
        XCTAssertFalse(session.canCapture)
        for _ in 0..<50 { await Task.yield() }
        let count = await commands.captureCount
        XCTAssertEqual(count, 1)
        await commands.releaseCapture()
        await waitUntil { !session.isCapturing }
        session.disconnect()
    }

    func testRotationDoesNotRestartTransport() async {
        let receiver = TestReceiver()
        let session = makeSession(TestCommands(), receiver: receiver)
        session.connect()
        await waitUntil { session.canCapture }
        // Both geometry branches consume the same model; querying layout has no transport effects.
        for size in [CGSize(width: 390, height: 700), CGSize(width: 750, height: 350)] {
            _ = PreviewLayout.fit(imageSize: CGSize(width: 640, height: 480), in: size)
        }
        XCTAssertEqual(receiver.starts, 1)
        session.disconnect()
    }

    func testHealthFailureDuringCaptureDoesNotRecoverUntilCaptureSettles() async {
        let time = ManualClock()
        let commands = TestCommands()
        let receiver = TestReceiver()
        let settings = CameraSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.accessID = "camera-id"
        let session = CameraSession(settings: settings, makeClient: { _ in commands }, makeReceiver: { receiver }, clock: { time.now }, sleep: { seconds in try await time.sleep(seconds) }, controlSleep: { _ in try Task.checkCancellation(); await Task.yield() })
        session.connect()
        await waitUntil { session.canCapture }
        await waitUntil { time.pendingSleeps >= 2 }
        await commands.failNextHealthChecks(2)
        await time.advance(to: 2)
        await waitForHealthCount(commands, atLeast: 2)
        await waitUntil { time.pendingSleeps >= 2 }
        await time.advance(to: 4)
        await waitForHealthCount(commands, atLeast: 3)
        await waitUntil { time.pendingSleeps >= 2 }
        await commands.holdFailingHealth()
        await time.advance(to: 6)
        for _ in 0..<200 { let waiting = await commands.healthWaiting; if waiting { break }; await Task.yield() }
        await commands.holdCapture()
        session.capture()
        await commands.releaseFailingHealth()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(session.isCapturing)
        XCTAssertEqual(receiver.starts, 1)
        await commands.releaseCapture()
        await waitUntil { !session.isCapturing }
        session.disconnect()
    }

    func testStaleClockRunsWhileHealthRequestIsSuspended() async {
        let time = ManualClock()
        let commands = TestCommands()
        let receiver = TestReceiver()
        let settings = CameraSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.accessID = "camera-id"
        let session = CameraSession(settings: settings, makeClient: { _ in commands }, makeReceiver: { receiver }, clock: { time.now }, sleep: { seconds in try await time.sleep(seconds) }, controlSleep: { _ in try Task.checkCancellation(); await Task.yield() })
        session.connect()
        await waitUntil { session.canCapture }
        await waitUntil { time.pendingSleeps >= 2 }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        receiver.emit(image.jpegData(compressionQuality: 0.8)!)
        await waitUntil { session.image != nil }
        await commands.holdFailingHealth()
        await time.advance(to: 2)
        for _ in 0..<200 { let waiting = await commands.healthWaiting; if waiting { break }; await Task.yield() }
        await time.advance(to: 2.5)
        await waitUntil { session.frameIsStale }
        XCTAssertGreaterThanOrEqual(session.lastFrameAge ?? 0, 2)
        session.disconnect()
        await commands.releaseFailingHealth()
    }

    private func waitForHealthCount(_ commands: TestCommands, atLeast count: Int) async {
        for _ in 0..<200 { let current = await commands.healthCount; if current >= count { return }; await Task.yield() }
        XCTFail("Health request was not sent")
    }
}

private actor TestCommands: CommandSending {
    private(set) var liveViewSize: String?
    private(set) var sizeWhenStreamStarted: String?
    func configureLiveView(size: String) { liveViewSize = size }
    var captureCount = 0
    var videoStartCount = 0
    var videoStopCount = 0
    var playbackCount = 0
    var stopStreamCount = 0
    var startStreamCount = 0
    var recordModeCount = 0
    private var playback = false
    private var recording = false
    private var recordingReadout = true
    var accessWaiting = false
    var healthWaiting = false
    var healthCount = 0
    private var accessHeld = false
    private var captureHeld = false
    private var accessContinuation: CheckedContinuation<Void, Never>?
    private var captureContinuation: CheckedContinuation<Void, Never>?
    private var captureError: Error?
    private var healthFailures = 0
    private var holdHealth = false
    private var healthContinuation: CheckedContinuation<Void, Never>?
    func holdAccess() { accessHeld = true }
    func setRecordingReadout(_ available: Bool) { recordingReadout = available }
    func setBodyRecording(_ active: Bool) { recording = active }
    func holdCapture() { captureHeld = true }
    func setCaptureError(_ error: Error) { captureError = error }
    func releaseAccess() { accessHeld = false; accessContinuation?.resume(); accessContinuation = nil }
    func releaseCapture() { captureHeld = false; captureContinuation?.resume(); captureContinuation = nil }
    func failNextHealthChecks(_ count: Int) { healthFailures = count }
    func holdFailingHealth() { holdHealth = true }
    func releaseFailingHealth() { holdHealth = false; healthContinuation?.resume(); healthContinuation = nil }
    func send(_ command: LumixCommand) async throws -> LumixResponse {
        if command == .playbackMode { playbackCount += 1; playback = true }
        if command == .recordMode { recordModeCount += 1; playback = false }
        if command == .stopStream { stopStreamCount += 1 }
        if case .startStream = command { startStreamCount += 1; sizeWhenStreamStarted = liveViewSize }
        if liveViewSize != nil {
            if command == .getInfo("allmenu") {
                let xml = "<camrply><result>ok</result><menuset model=\"GX80\"><item id=\"menu_item_id_liveview_quality\"><item id=\"menu_item_id_liveviewsize_vga\" cmd_mode=\"setsetting\" cmd_type=\"liveviewsize\" cmd_value=\"vga\"/><item id=\"menu_item_id_liveviewsize_qvga\" cmd_mode=\"setsetting\" cmd_type=\"liveviewsize\" cmd_value=\"qvga\"/></item></menuset></camrply>"
                return try LumixResponse.parse(data: Data(xml.utf8))
            }
            if command == .getSetting("liveviewsize") { return LumixResponse(status: .success, fields: ["liveviewsize": liveViewSize!]) }
            if case .setSetting(type: "liveviewsize", value: let value) = command {
                _ = try command.makeURL(endpoint: CameraEndpoint(host: "192.168.54.1"))
                liveViewSize = value
            }
        }
        if command == .videoStart { videoStartCount += 1; recording = true }
        if command == .videoStop { videoStopCount += 1; recording = false }
        if command == .state {
            healthCount += 1
            if holdHealth {
                healthWaiting = true
                await withCheckedContinuation { healthContinuation = $0 }
                throw CommandError.timedOut
            }
            if healthFailures > 0 { healthFailures -= 1; throw CommandError.timedOut }
        }
        if case .requestAccess = command, accessHeld {
            accessWaiting = true
            await withCheckedContinuation { accessContinuation = $0 }
        }
        if command == .capture {
            captureCount += 1
            if captureHeld { await withCheckedContinuation { captureContinuation = $0 } }
            if let captureError { throw captureError }
        }
        var fields = ["focusmode": "mf", "cammode": playback ? "playmode" : "recmode"]
        if recordingReadout { fields["rec"] = recording ? "on" : "off" }
        return LumixResponse(status: .success, fields: fields, summary: "ok")
    }
}

private final class TestReceiver: LiveViewReceiving {
    var starts = 0
    var stops = 0
    private var callback: (@Sendable (Data) -> Void)?
    func start(endpoint: CameraEndpoint, onDatagram: @escaping @Sendable (Data) -> Void) async throws { starts += 1; callback = onDatagram }
    func stop() { stops += 1; callback = nil }
    func emit(_ data: Data) { callback?(data) }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    private var waiters: [(UUID, TimeInterval, CheckedContinuation<Void, Error>)] = []
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    var pendingSleeps: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                waiters.append((id, value + seconds, continuation))
                lock.unlock()
            }
        }, onCancel: {
            self.lock.lock()
            let index = self.waiters.firstIndex { $0.0 == id }
            let waiter = index.map { self.waiters.remove(at: $0) }
            self.lock.unlock()
            waiter?.2.resume(throwing: CancellationError())
        })
    }
    func advance(to time: TimeInterval) async {
        let ready = advanceValue(to: time)
        for waiter in ready { waiter.2.resume() }
        for _ in 0..<20 { await Task.yield() }
    }
    private func advanceValue(to time: TimeInterval) -> [(UUID, TimeInterval, CheckedContinuation<Void, Error>)] {
        lock.lock()
        defer { lock.unlock() }
        value = time
        let ready = waiters.filter { $0.1 <= time }
        waiters.removeAll { $0.1 <= time }
        return ready
    }
}
