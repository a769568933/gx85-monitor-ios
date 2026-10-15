import Foundation
import XCTest
@testable import GX85Core

final class CameraControlCommandTests: XCTestCase {
    func testRecordReleaseAndFocusCommandsUseCameraProtocol() throws {
        let endpoint = try CameraEndpoint(host: "192.168.54.1")
        let cases: [(LumixCommand, String)] = [
            (.videoStart, "mode=camcmd&value=video_recstart"),
            (.videoStop, "mode=camcmd&value=video_recstop"),
            (.releaseCapture, "mode=camcmd&value=capture_cancel"),
            (.autoFocus, "mode=camcmd&value=oneshot_af"),
            (.playbackMode, "mode=camcmd&value=playmode"),
            (.getInfo("allmenu"), "mode=getinfo&type=allmenu"),
            (.getSetting("iso"), "mode=getsetting&type=iso")
        ]
        for (command, query) in cases {
            XCTAssertEqual(try command.makeURL(endpoint: endpoint).absoluteString, "http://192.168.54.1/cam.cgi?" + query)
        }
    }

    func testExposureCommandsKeepRawValueInOneQueryItem() throws {
        let endpoint = try CameraEndpoint(host: "192.168.54.1")
        for (type, value) in [("shtrspeed", "1780/256"), ("focal", "392/256"), ("iso", "auto")] {
            let url = try LumixCommand.setSetting(type: type, value: value).makeURL(endpoint: endpoint)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "mode", value: "setsetting"), URLQueryItem(name: "type", value: type), URLQueryItem(name: "value", value: value)])
        }
    }

    func testRejectsArbitrarySettingAndQueryInjection() throws {
        let endpoint = try CameraEndpoint(host: "192.168.54.1")
        for command in [LumixCommand.setSetting(type: "format", value: "start"), .setSetting(type: "iso", value: "400&mode=camcmd"), .getInfo("http://evil.invalid"), .getSetting("iso&value=capture")] {
            XCTAssertThrowsError(try command.makeURL(endpoint: endpoint))
        }
    }

    func testTouchFocusUsesCameraCoordinatesAndRejectsOutOfBounds() throws {
        let endpoint = try CameraEndpoint(host: "192.168.54.1")
        let url = try LumixCommand.touchFocus(x: 0, y: 1000).makeURL(endpoint: endpoint)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "mode", value: "camctrl"), URLQueryItem(name: "type", value: "touchaf"), URLQueryItem(name: "value", value: "0/1000")])
        for (x, y) in [(-1, 500), (1001, 0), (0, -1), (500, 1001)] {
            XCTAssertThrowsError(try LumixCommand.touchFocus(x: x, y: y).makeURL(endpoint: endpoint))
        }
    }
}
