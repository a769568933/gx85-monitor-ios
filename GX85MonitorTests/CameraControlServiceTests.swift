import Foundation
import XCTest
import GX85Core
@testable import GX85Monitor

final class CameraControlServiceTests: XCTestCase {
    func testUnknownRecordingDoesNotMutateModeWhenRestoringPlayback() async {
        let camera = ControlCamera(.unknownRecording)
        do { _ = try await service(camera).leavePlayback(port: 49152); XCTFail("Unknown recording state must not switch camera mode") }
        catch { }
        let calls = await camera.calls
        XCTAssertFalse(calls.contains(.recordMode))
        XCTAssertFalse(calls.contains(.videoStop))
    }
    func testTapFocusPreservesMFAndNeverTriggersCapture() async {
        let camera = ControlCamera(.ackOnly)
        do { try await service(camera).focus(at: CGPoint(x: 0.5, y: 0.5)); XCTFail("MF must not request touch autofocus") }
        catch { }
        let calls = await camera.calls
        XCTAssertFalse(calls.contains(.capture))
        XCTAssertFalse(calls.contains(.touchFocus(x: 500, y: 500)))
    }

    func testTapAutofocusSendsPositionWithoutTouchShutter() async throws {
        let camera = ControlCamera(.autoFocus)
        try await service(camera).focus(at: CGPoint(x: 0.25, y: 0.75))
        let calls = await camera.calls
        XCTAssertTrue(calls.contains(.touchFocus(x: 250, y: 750)))
        XCTAssertFalse(calls.contains(.capture))
    }
    private func service(_ camera: ControlCamera) -> CameraControlService {
        CameraControlService(client: camera, sleep: { _ in try Task.checkCancellation(); await Task.yield() })
    }

    func testOKWithUnchangedStateDoesNotConfirmSavedPhoto() async {
        let camera = ControlCamera(.ackOnly)
        let result = await service(camera).capturePhoto()
        XCTAssertEqual(result, .acceptedUnconfirmed)
        let calls = await camera.calls
        XCTAssertEqual(calls.filter { $0 == .capture }.count, 1)
        XCTAssertEqual(calls.filter { $0 == .releaseCapture }.count, 1)
    }

    func testTimeoutNeverRetriesCapture() async {
        let camera = ControlCamera(.timeout)
        let result = await service(camera).capturePhoto()
        XCTAssertEqual(result, .unknown)
        let calls = await camera.calls
        XCTAssertEqual(calls.filter { $0 == .capture }.count, 1)
    }

    func testBusyAndCardErrorsDoNotSendShutter() async {
        for scenario in [ControlCamera.Scenario.busy, .cardMissing, .unknownRecording] {
            let camera = ControlCamera(scenario)
            let result = await service(camera).capturePhoto()
            guard case .rejected = result else { XCTFail("Unsafe preflight must reject: \(scenario)"); continue }
            let calls = await camera.calls
            XCTAssertFalse(calls.contains(.capture))
        }
    }

    func testCaptureUsesCameraFocusPriorityWithoutSeparateAFCommand() async {
        for scenario in [ControlCamera.Scenario.autoFocus, .ackOnly] {
            let camera = ControlCamera(scenario)
            _ = await service(camera).capturePhoto()
            let calls = await camera.calls
            XCTAssertFalse(calls.contains(.autoFocus))
            XCTAssertFalse(calls.contains(.getSetting("focusmode")))
            XCTAssertEqual(calls.filter { $0 == .capture }.count, 1)
            XCTAssertFalse(calls.contains { if case .setSetting(type: "focusmode", value: _) = $0 { return true }; return false })
        }
    }

    func testUnsupportedOneShotAFDoesNotBlockGX80Capture() async {
        // The user's GX80 log reports focusmode=afs, followed by oneshot_af err_reject.
        let camera = ControlCamera(.unsupportedAF)
        let result = await service(camera).capturePhoto()
        XCTAssertEqual(result, .acceptedUnconfirmed)
        let calls = await camera.calls
        XCTAssertFalse(calls.contains(.autoFocus))
        XCTAssertEqual(calls.filter { $0 == .capture }.count, 1)
        XCTAssertEqual(calls.filter { $0 == .releaseCapture }.count, 1)
    }

    func testCameraRejectingCaptureForFocusIsNotOverriddenOrRetried() async {
        let camera = ControlCamera(.captureFocusFailure)
        let result = await service(camera).capturePhoto()
        XCTAssertEqual(result, .rejected("err_focus"))
        let calls = await camera.calls
        XCTAssertEqual(calls.filter { $0 == .capture }.count, 1)
        XCTAssertFalse(calls.contains { if case .setSetting(type: "focusmode", value: _) = $0 { return true }; return false })
    }

    func testReleaseFailureDoesNotClaimConfirmedCapture() async {
        let camera = ControlCamera(.releaseFailure)
        let result = await service(camera).capturePhoto()
        XCTAssertEqual(result, .unknown)
        let calls = await camera.calls
        XCTAssertEqual(calls.filter { $0 == .capture }.count, 1)
    }

    func testRecordingAckWithoutTransitionIsUnconfirmedAndSentOnce() async {
        let camera = ControlCamera(.recordNoTransition)
        do { _ = try await service(camera).setRecording(true); XCTFail("An ack alone must not confirm recording") }
        catch { }
        let calls = await camera.calls
        XCTAssertEqual(calls.filter { $0 == .videoStart }.count, 1)
        XCTAssertFalse(calls.contains(.capture))
    }

    func testRecordingStartStopUsesConfirmedCameraState() async throws {
        let camera = ControlCamera(.recordConfirmed)
        let controls = service(camera)
        let started = try await controls.setRecording(true)
        let stopped = try await controls.setRecording(false)
        XCTAssertEqual(started, .recording)
        XCTAssertEqual(stopped, .stopped)
    }

    func testAlreadyRecordingDoesNotSendAnotherStart() async throws {
        let camera = ControlCamera(.alreadyRecording)
        let state = try await service(camera).setRecording(true)
        XCTAssertEqual(state, .recording)
        let calls = await camera.calls
        XCTAssertFalse(calls.contains(.videoStart))
    }

    func testHealthReadCannotInterleaveShutterTransaction() async throws {
        let camera = ControlCamera(.slowCapture)
        let controls = service(camera)
        let capture = Task { await controls.capturePhoto() }
        for _ in 0..<500 {
            let started = await camera.captureStarted
            if started { break }
            await Task.yield()
        }
        let health = Task { try await controls.readState() }
        _ = await capture.value
        _ = try await health.value
        let calls = await camera.calls
        let shutter = try XCTUnwrap(calls.firstIndex(of: .capture))
        XCTAssertEqual(calls[shutter + 1], .releaseCapture)
    }

    func testRejectedParameterChangeDoesNotPretendAccepted() async {
        let camera = ControlCamera(.rejectParameter)
        do { try await service(camera).setParameter(.iso, rawValue: "400"); XCTFail("Camera rejection must escape") }
        catch { }
        let calls = await camera.calls
        XCTAssertTrue(calls.contains(.setSetting(type: "iso", value: "400")))
    }
}

private actor ControlCamera: CommandSending {
    enum Scenario: Equatable { case ackOnly, timeout, busy, cardMissing, unknownRecording, autoFocus, unsupportedAF, captureFocusFailure, releaseFailure, recordNoTransition, recordConfirmed, alreadyRecording, slowCapture, rejectParameter }
    let scenario: Scenario
    private(set) var calls: [LumixCommand] = []
    private(set) var captureStarted = false
    private var recording = false
    init(_ scenario: Scenario) { self.scenario = scenario; recording = scenario == .alreadyRecording }
    func send(_ command: LumixCommand) async throws -> LumixResponse {
        calls.append(command)
        if command == .state {
            var fields = ["cammode": "recmode", "rec": recording ? "on" : "off", "sdcardstatus": "write_enable", "recremaincapacity": "42"]
            if scenario == .busy { fields["busy"] = "on" }
            if scenario == .cardMissing { fields["sdcardstatus"] = "no_card" }
            if scenario == .unknownRecording { fields.removeValue(forKey: "rec") }
            return LumixResponse(status: .success, fields: fields)
        }
        if command == .getSetting("focusmode") {
            return LumixResponse(status: .success, fields: ["focusmode": [.autoFocus, .unsupportedAF, .captureFocusFailure].contains(scenario) ? "afs" : "mf"])
        }
        if command == .autoFocus && scenario == .unsupportedAF { throw CommandError.cameraRejected("err_reject") }
        if command == .capture {
            captureStarted = true
            if scenario == .captureFocusFailure { throw CommandError.cameraRejected("err_focus") }
            if scenario == .timeout { throw CommandError.timedOut }
            if scenario == .slowCapture { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        if command == .releaseCapture && scenario == .releaseFailure { throw CommandError.cameraRejected("err_reject") }
        if scenario == .recordConfirmed {
            if command == .videoStart { recording = true }
            if command == .videoStop { recording = false }
        }
        if case .setSetting = command, scenario == .rejectParameter { throw CommandError.cameraRejected("err_reject") }
        return LumixResponse(status: .success)
    }
}
