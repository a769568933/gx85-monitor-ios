import Foundation
import XCTest
@testable import GX85Core

final class CameraControlStateTests: XCTestCase {
    // Defaulting absent fields to idle would enable a second capture during uncertainty.
    func testMissingRecRemainsUnknown() {
        let state = CameraControlState(response: LumixResponse(status: .success))
        XCTAssertEqual(state.recordingState, .unknown)
        XCTAssertEqual(state.shootingMode, .unknown)
        XCTAssertNil(state.isBusy)
    }

    func testRecordingOnOff() {
        XCTAssertEqual(CameraControlState(response: LumixResponse(status: .success, fields: ["rec": "on"])).recordingState, .recording)
        XCTAssertEqual(CameraControlState(response: LumixResponse(status: .success, fields: ["rec": "off"])).recordingState, .stopped)
        XCTAssertEqual(CameraControlState(response: LumixResponse(status: .success, fields: ["rec": "future-value"])).recordingState, .unknown)
    }

    func testUnknownModeDoesNotSelectPhoto() {
        for value in ["recmode", "playmode", "future-value", ""] {
            let state = CameraControlState(response: LumixResponse(status: .success, fields: ["cammode": value]))
            XCTAssertEqual(state.shootingMode, .unknown, value)
        }
    }

    func testRejectedResponseDoesNotBecomeTrustedState() {
        let state = CameraControlState(response: LumixResponse(status: .rejected("err_busy"), fields: ["rec": "off", "operate": "on"]))
        XCTAssertEqual(state.recordingState, .unknown)
        XCTAssertNil(state.isBusy)
    }
}
