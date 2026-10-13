import Foundation
import XCTest
@testable import GX85Core

final class DiscoveryReplyTests: XCTestCase {
    func testLocationMustPointToSelectedCamera() {
        let response = Data("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.54.1:60606/device/ddd\r\n\r\n".utf8)
        XCTAssertEqual(DiscoveryReply.location(data: response, cameraHost: "192.168.54.1")?.absoluteString, "http://192.168.54.1:60606/device/ddd")
        XCTAssertNil(DiscoveryReply.location(data: response, cameraHost: "192.168.1.1"))
        let external = Data("HTTP/1.1 200 OK\r\nLOCATION: https://example.com/\r\n\r\n".utf8)
        XCTAssertNil(DiscoveryReply.location(data: external, cameraHost: "192.168.54.1"))
    }
    func testExtractsUDNFromDeviceDescription() throws {
        let data = Data("<root><device><UDN>uuid:4D454930-0100-1000-8001-ABCDEF123456</UDN></device></root>".utf8)
        XCTAssertEqual(DiscoveryReply.accessID(data: data), "4D454930-0100-1000-8001-ABCDEF123456")
        XCTAssertNil(DiscoveryReply.accessID(data: Data("<root>".utf8)))
    }
}
