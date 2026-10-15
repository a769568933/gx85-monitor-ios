import Foundation
import XCTest
@testable import GX85Core

final class ProtocolTests: XCTestCase {
    func testSettingValueAttributesPreserveCameraRawValues() throws {
        let xml = "<camrply><result>ok</result><settingvalue focusmode=\"afs\" focal=\"392/256\" iso=\"400\"/></camrply>"
        let response = try LumixResponse.parse(data: Data(xml.utf8))
        XCTAssertEqual(response.fields["focusmode"], "afs")
        XCTAssertEqual(response.fields["focal"], "392/256")
        XCTAssertEqual(response.fields["iso"], "400")
    }

    func testTextSettingValueIsAvailableToParameterReadback() throws {
        XCTAssertEqual(try LumixResponse.parse(data: Data("ok,400".utf8)).fields["value"], "400")
    }

    func testRejectsInvalidIPv4AndZeroPort() throws {
        for host in ["", "camera.local", "256.1.1.1", "1.2.3", "1.2.3.4:80", "127.0.0.1/path", "1..2.3", "0.0.0.0", "255.255.255.255", "224.0.0.1"] {
            XCTAssertThrowsError(try CameraEndpoint(host: host), host)
        }
        XCTAssertThrowsError(try CameraEndpoint(host: "192.168.54.1", port: 0))
        XCTAssertEqual(try CameraEndpoint(host: " 192.168.54.1 ").host, "192.168.54.1")
    }

    func testEncodesAccessNameAndStableID() throws {
        let endpoint = try CameraEndpoint(host: "192.168.54.1")
        let url = try LumixCommand.requestAccess(clientID: "own-id", name: "我的 iPhone & Camera").makeURL(endpoint: endpoint)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "192.168.54.1")
        XCTAssertEqual(components.path, "/cam.cgi")
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values, ["mode": "accctrl", "type": "req_acc", "value": "own-id", "value2": "我的 iPhone & Camera"])
    }

    func testCaptureAndStreamCommands() throws {
        let endpoint = try CameraEndpoint(host: "192.168.54.1")
        XCTAssertEqual(try LumixCommand.capture.makeURL(endpoint: endpoint).absoluteString, "http://192.168.54.1/cam.cgi?mode=camcmd&value=capture")
        XCTAssertEqual(try LumixCommand.startStream(port: 49152).makeURL(endpoint: endpoint).absoluteString, "http://192.168.54.1/cam.cgi?mode=startstream&value=49152")
    }

    func testParsesTextAndXMLSuccess() throws {
        XCTAssertEqual(try LumixResponse.parse(data: Data("ok,GX85-123,remote,encrypted".utf8)).status, .success)
        let xml = "<camrply><result>ok</result><state><batt>3/3</batt><recremaincapacity>42</recremaincapacity></state></camrply>"
        let response = try LumixResponse.parse(data: Data(xml.utf8))
        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(response.fields["batt"], "3/3")
    }

    func testRejectsUnknownMalformedAndCameraError() throws {
        for text in ["", "this looks ok", "<camrply><result>ok</result>", "<html>ok</html>", "<other><result>ok</result></other>"] {
            XCTAssertThrowsError(try LumixResponse.parse(data: Data(text.utf8)), text)
        }
        XCTAssertEqual(try LumixResponse.parse(data: Data("err_reject".utf8)).status, .rejected("err_reject"))
        XCTAssertEqual(try LumixResponse.parse(data: Data("<camrply><result>err_busy</result></camrply>".utf8)).status, .rejected("err_busy"))
    }

    func testPendingApprovalIsNotSuccess() throws {
        XCTAssertEqual(try LumixResponse.parse(data: Data("err_unsuitable_app".utf8)).status, .rejected("err_unsuitable_app"))
        XCTAssertEqual(try LumixResponse.parse(data: Data("err_busy".utf8)).status, .rejected("err_busy"))
        XCTAssertEqual(try LumixResponse.parse(data: Data("err_wait".utf8)).status, .pendingApproval)
    }
}
