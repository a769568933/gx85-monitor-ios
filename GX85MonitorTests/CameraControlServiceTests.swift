import Foundation
import XCTest
import GX85Core
@testable import GX85Monitor

final class CameraControlServiceTests: XCTestCase {
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

    func testAutomaticFocusPrecedesShutterButMFIsPreserved() async {
        for scenario in [ControlCamera.Scenario.autoFocus, .ackOnly] {
            let camera = ControlCamera(scenario)
            _ = await service(camera).capturePhoto()
            let calls = await camera.calls
            if scenario == .autoFocus {
                XCTAssertLessThan(calls.firstIndex(of: .autoFocus) ?? Int.max, calls.firstIndex(of: .capture) ?? 0)
            } else { XCTAssertFalse(calls.contains(.autoFocus)) }
            XCTAssertFalse(calls.contains { if case .setSetting(type: "focusmode", value: _) = $0 { return true }; return false })
        }
    }

    func testExplicitAFFailureDoesNotForceShutter() async {
        let camera = ControlCamera(.focusFailure)
        let result = await service(camera).capturePhoto()
        guard case .rejected = result else { return XCTFail("Failed AF must reject") }
        let calls = await camera.calls
        XCTAssertFalse(calls.contains(.capture))
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
            if await camera.captureStarted { break }
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
    enum Scenario { case ackOnly, timeout, busy, cardMissing, unknownRecording, autoFocus, focusFailure, releaseFailure, recordNoTransition, recordConfirmed, alreadyRecording, slowCapture, rejectParameter }
    let scenario: Scenario
    private(set) var calls: [LumixCommand] = []
    private(set) var captureStarted = false
    private var recording = false
    init(_ scenario: Scenario) { self.scenario = scenario; recording = scenario == .alreadyRecording }
    func send(_ command: LumixCommand) async throws -> LumixResponse {
        calls.append(command)
        if command == .state {
            var fields = ["cammode": "recmode", "rec": recording ? "on" : "off", "sdcardstatus": "writeenable", "recremaincapacity": "42"]
            if scenario == .busy { fields["busy"] = "on" }
            if scenario == .cardMissing { fields["sdcardstatus"] = "no_card" }
            if scenario == .unknownRecording { fields.removeValue(forKey: "rec") }
            return LumixResponse(status: .success, fields: fields)
        }
        if command == .getSetting("focusmode") {
            return LumixResponse(status: .success, fields: ["focusmode": [.autoFocus, .focusFailure].contains(scenario) ? "afs" : "mf"])
        }
        if command == .autoFocus && scenario == .focusFailure { throw CommandError.cameraRejected("err_focus") }
        if command == .capture {
            captureStarted = true
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
