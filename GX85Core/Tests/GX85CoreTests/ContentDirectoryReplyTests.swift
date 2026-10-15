import Foundation
import XCTest
@testable import GX85Core

final class ContentDirectoryReplyTests: XCTestCase {
    private let host = "192.168.54.1"

    func testEscapedNamespacedDIDLKeepsOriginalAndThumbnailDistinct() throws {
        let didl = """
        <d:DIDL-Lite xmlns:d="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:u="urn:schemas-upnp-org:metadata-1-0/upnp/">
        <d:item id="image-1"><dc:title>A &amp; B.JPG</dc:title><u:class>object.item.imageItem.photo</u:class>
          <d:res protocolInfo="http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_TN">http://192.168.54.1:50001/thumb.JPG</d:res>
          <d:res protocolInfo="http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_ORG" size="12345">http://192.168.54.1:50001/original.JPG?x=1&amp;y=2</d:res>
        </d:item></d:DIDL-Lite>
        """
        let page = try ContentDirectoryReply.parse(data: soap(didl, returned: 1, total: 3), cameraHost: host)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.title, "A & B.JPG")
        XCTAssertEqual(item.kind, .photo)
        XCTAssertEqual(item.resources.count, 2)
        XCTAssertEqual(item.originalResource?.url.absoluteString, "http://192.168.54.1:50001/original.JPG?x=1&y=2")
        XCTAssertEqual(page.nextStartingIndex, 1)
        XCTAssertEqual(page.totalMatches, 3)
    }

    func testMP4AndRAWSelectActualOriginalResources() throws {
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:u="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="v"><dc:title>movie.MP4</dc:title><u:class>object.item.videoItem</u:class><res protocolInfo="http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_TN">http://192.168.54.1/t.JPG</res><res protocolInfo="http-get:*:video/mp4:PANASONIC.COM_PN=CAM_AVC_MP4">http://192.168.54.1/v.MP4</res></item>
          <item id="r"><dc:title>photo.RW2</dc:title><u:class>object.item.imageItem.photo</u:class><res protocolInfo="http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_RAW_JPG">http://192.168.54.1/companion.JPG</res><res protocolInfo="http-get:*:image/x-panasonic-rw2:PANASONIC.COM_PN=CAM_RAW">http://192.168.54.1/original.RW2</res></item>
        </DIDL-Lite>
        """
        let items = try ContentDirectoryReply.parse(data: soap(didl, returned: 2, total: 2), cameraHost: host).items
        XCTAssertEqual(items[0].kind, .video)
        XCTAssertEqual(items[0].originalResource?.url.pathExtension, "MP4")
        XCTAssertEqual(items[1].originalResource?.url.pathExtension, "RW2")
    }

    func testThumbnailOnlyItemDoesNotPretendOriginalExists() throws {
        let didl = "<DIDL-Lite><item id=\"1\"><res protocolInfo=\"http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_TN\">http://192.168.54.1/preview.JPG</res></item></DIDL-Lite>"
        let item = try XCTUnwrap(ContentDirectoryReply.parse(data: soap(didl, returned: 1, total: 1), cameraHost: host).items.first)
        XCTAssertNil(item.originalResource)
    }

    func testContainerIsPreservedForFolderNavigation() throws {
        let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><container id=\"folder-1\"><dc:title>DCIM</dc:title></container></DIDL-Lite>"
        let item = try XCTUnwrap(ContentDirectoryReply.parse(data: soap(didl, returned: 1, total: 1), cameraHost: host).items.first)
        XCTAssertEqual(item.id, "folder-1")
        XCTAssertTrue(item.isContainer)
        XCTAssertNil(item.originalResource)
    }

    func testEmptyPageAndNoProgressAreDifferent() throws {
        let empty = try ContentDirectoryReply.parse(data: soap("<DIDL-Lite/>", returned: 0, total: 0), cameraHost: host)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertNil(empty.nextStartingIndex)
        XCTAssertThrowsError(try ContentDirectoryReply.parse(data: soap("<DIDL-Lite/>", returned: 0, total: 40), cameraHost: host))
    }

    func testRejectsHostUserInfoSchemesAndRedirectDestinations() {
        for raw in ["http://evil.invalid/a.JPG", "https://192.168.54.1/a.JPG", "file:///a.JPG", "http://user:password@192.168.54.1/a.JPG", "http://192.168.54.10/a.JPG", "http://2130706433/a.JPG", "/relative.JPG", "http://192.168.54.1/a.JPG#fragment"] {
            XCTAssertThrowsError(try MediaURLPolicy.validate(try! XCTUnwrap(URL(string: raw)), cameraHost: host), raw)
        }
    }

    func testRejectsBadCountsFaultsAndOversizeSOAP() {
        XCTAssertThrowsError(try ContentDirectoryReply.parse(data: soap("<DIDL-Lite/>", returned: -1, total: 1), cameraHost: host))
        XCTAssertThrowsError(try ContentDirectoryReply.parse(data: Data("<Envelope><Body><Fault>bad action</Fault></Body></Envelope>".utf8), cameraHost: host))
        XCTAssertThrowsError(try ContentDirectoryReply.parse(data: Data(repeating: 32, count: 4 * 1024 * 1024 + 1), cameraHost: host))
    }

    private func soap(_ didl: String, returned: Int, total: Int) -> Data {
        let escaped = didl.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:BrowseResponse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><Result>\(escaped)</Result><NumberReturned>\(returned)</NumberReturned><TotalMatches>\(total)</TotalMatches><UpdateID>1</UpdateID></u:BrowseResponse></s:Body></s:Envelope>".utf8)
    }
}
