import Foundation
import XCTest
import GX85Core
import UIKit
@testable import GX85Monitor

final class CameraMediaClientTests: XCTestCase {
    override func tearDown() { MediaStubProtocol.reset(); super.tearDown() }
    private func client(description: URL? = nil) throws -> CameraMediaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStubProtocol.self]
        return CameraMediaClient(endpoint: try CameraEndpoint(host: "192.168.54.1"), descriptionURL: description, configuration: config)
    }

    func testDescriptionResolvesRelativeControlURLOnCameraOnly() throws {
        let description = Data("<root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>CDS_custom</controlURL></service></serviceList></device></root>".utf8)
        let service = try ContentDirectoryService.parseDescription(data: description, descriptionURL: URL(string: "http://192.168.54.1:60606/Server0/ddd.xml")!, cameraHost: "192.168.54.1")
        XCTAssertEqual(service.url.absoluteString, "http://192.168.54.1:60606/Server0/CDS_custom")
        let evil = Data("<root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>http://evil.invalid/control</controlURL></service></serviceList></device></root>".utf8)
        XCTAssertThrowsError(try ContentDirectoryService.parseDescription(data: evil, descriptionURL: URL(string: "http://192.168.54.1/ddd.xml")!, cameraHost: "192.168.54.1"))
    }

    func testFallbackBrowseUsesSOAPAndSameCameraEndpoint() async throws {
        MediaStubProtocol.set({ _ in Self.emptyPage })
        let camera = try client()
        let page = try await camera.browse(start: 0, count: 40)
        XCTAssertTrue(page.items.isEmpty)
        let request = try XCTUnwrap(MediaStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.54.1:60606/Server0/CDS_control")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "SOAPAction"), "\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("<RequestedCount>1</RequestedCount>"))
        XCTAssertTrue(body.contains("<StartingIndex>0</StartingIndex>"))
        XCTAssertTrue(body.contains("<BrowseFlag>BrowseDirectChildren</BrowseFlag>"))
        XCTAssertTrue(body.contains("<pana:X_FromCP>LumixLink2.0</pana:X_FromCP>"), "Request the camera's Lumix resource metadata")
    }

    @MainActor
    func testStandardDLNAThumbnailDecodesWithoutBecomingAnOriginal() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let response = Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:BrowseResponse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><Result><![CDATA[<DIDL-Lite><item id=\"photo\"><res protocolInfo=\"http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN\">http://192.168.54.1/TN.JPG</res><res protocolInfo=\"http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG\">http://192.168.54.1/LRG.JPG</res></item></DIDL-Lite>]]></Result><NumberReturned>1</NumberReturned><TotalMatches>1</TotalMatches></u:BrowseResponse></s:Body></s:Envelope>".utf8)
        MediaStubProtocol.set { request in request.httpMethod == "POST" ? response : jpeg }
        let camera = try client()
        let page = try await camera.browse(start: 0, count: 40)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.thumbnailResource?.role, .thumbnail)
        XCTAssertEqual(item.imagePreviewResource?.role, .preview)
        XCTAssertNil(item.originalResource, "Generic DLNA JPEGs must never be exported as originals")
        guard let resource = item.thumbnailResource else { return XCTFail("A displayable thumbnail is required") }
        let image = await CameraThumbnailLoader(client: camera).load(resource)
        XCTAssertEqual(image?.cgImage?.width, 32)
        XCTAssertEqual(image?.cgImage?.height, 24)
        XCTAssertEqual(MediaStubProtocol.requests.last?.url?.path, "/TN.JPG")
    }

    @MainActor
    func testFailedThumbnailFallsBackToJPEGPreviewAndLogsDecodeFailure() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let messages = MediaMessages()
        MediaStubProtocol.set { request in request.url?.path == "/bad.JPG" ? Data("not a JPEG".utf8) : jpeg }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStubProtocol.self]
        let camera = CameraMediaClient(endpoint: try CameraEndpoint(host: "192.168.54.1"), configuration: config, log: { messages.append($0) })
        let bad = CameraMediaResource(url: URL(string: "http://192.168.54.1/bad.JPG")!, mimeType: "image/jpeg", role: .thumbnail)
        let preview = CameraMediaResource(url: URL(string: "http://192.168.54.1/good.JPG")!, mimeType: "image/jpeg", role: .preview)
        let item = CameraMediaItem(id: "photo", title: "photo", kind: .photo, resources: [bad, preview])
        let image = await CameraThumbnailLoader(client: camera).load(item)
        XCTAssertEqual(image?.cgImage?.width, 24)
        XCTAssertEqual(MediaStubProtocol.requests.map { $0.url?.path }, ["/bad.JPG", "/good.JPG"])
        XCTAssertTrue(messages.values.contains { $0.contains("无法解码") && $0.contains("bad.JPG") })
        XCTAssertNil(item.originalResource)
    }

    func testUnknownJPEGCanBePreviewedButCannotBeExported() throws {
        let resource = CameraMediaResource(url: URL(string: "http://192.168.54.1/preview.JPG")!, mimeType: "image/jpeg", role: .unknown)
        let item = CameraMediaItem(id: "photo", title: "photo", kind: .photo, resources: [resource])
        XCTAssertEqual(item.thumbnailResource, resource)
        XCTAssertEqual(item.imagePreviewResource, resource)
        XCTAssertNil(item.originalResource)
    }

    func testNewestFirstPagingStartsAtCatalogTailAndNeverReordersLoadedPages() async throws {
        MediaStubProtocol.set { request in Self.catalogReply(request, total: 85) }
        let camera = try client()
        let first = try await camera.browse(start: 0, count: 40)
        XCTAssertEqual(first.items.first?.id, "84")
        XCTAssertEqual(first.items.last?.id, "45")
        XCTAssertEqual(first.nextStartingIndex, 40)
        let second = try await camera.browse(start: 40, count: 40)
        let last = try await camera.browse(start: 80, count: 40)
        XCTAssertEqual(second.items.first?.id, "44")
        XCTAssertEqual(second.items.last?.id, "5")
        XCTAssertEqual(last.items.map(\.id), ["4", "3", "2", "1", "0"])
        XCTAssertNil(last.nextStartingIndex)
        XCTAssertEqual(Set((first.items + second.items + last.items).map(\.id)).count, 85)
        let requests = MediaStubProtocol.requests.map { Self.range($0) }
        XCTAssertEqual(requests.map(\.0), [0, 45, 5, 0])
        XCTAssertEqual(requests.map(\.1), [1, 40, 40, 5])
    }

    func testCameraReturningShortChunksDoesNotSkipOrDuplicateOlderPhotos() async throws {
        MediaStubProtocol.set { request in Self.catalogReply(request, total: 43, cap: 7) }
        let camera = try client()
        let first = try await camera.browse(start: 0, count: 40)
        let last = try await camera.browse(start: 40, count: 40)
        XCTAssertEqual(first.items.count, 40)
        XCTAssertEqual(first.items.first?.id, "42")
        XCTAssertEqual(first.items.last?.id, "3")
        XCTAssertEqual(last.items.map(\.id), ["2", "1", "0"])
        XCTAssertNil(last.nextStartingIndex)
        XCTAssertEqual(MediaStubProtocol.requests.count, 8)
    }

    func testReloadReprobesTotalSoNewCaptureAppearsFirst() async throws {
        MediaStubProtocol.set { request in Self.catalogReply(request, total: 2) }
        let camera = try client()
        let before = try await camera.browse(start: 0, count: 40)
        XCTAssertEqual(before.items.first?.id, "1")
        MediaStubProtocol.set { request in Self.catalogReply(request, total: 3) }
        let after = try await camera.browse(start: 0, count: 40)
        XCTAssertEqual(after.items.map(\.id), ["2", "1", "0"])
    }

    func testCatalogChangeBetweenPagesDoesNotMixOldAndNewOffsets() async throws {
        MediaStubProtocol.set { request in Self.catalogReply(request, total: 45) }
        let camera = try client()
        _ = try await camera.browse(start: 0, count: 40)
        MediaStubProtocol.set { request in Self.catalogReply(request, total: 46) }
        do { _ = try await camera.browse(start: 40, count: 40); XCTFail("Changed catalog must require reload") } catch { }
    }

    private static func range(_ request: URLRequest) -> (Int, Int) {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        func number(_ tag: String) -> Int {
            guard let after = body.components(separatedBy: "<\(tag)>").dropFirst().first,
                  let raw = after.components(separatedBy: "</\(tag)>").first else { return -1 }
            return Int(raw) ?? -1
        }
        return (number("StartingIndex"), number("RequestedCount"))
    }

    private static func catalogReply(_ request: URLRequest, total: Int, cap: Int = 40) -> Data {
        let (start, count) = range(request)
        guard start >= 0, count > 0 else { return Data() }
        let end = min(total, start + min(count, cap))
        let items = start < end ? (start..<end).map { "<item id=\"\($0)\"><res protocolInfo=\"http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_ORG\">http://192.168.54.1/DO\($0).JPG</res></item>" }.joined() : ""
        return Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:BrowseResponse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><Result><![CDATA[<DIDL-Lite>\(items)</DIDL-Lite>]]></Result><NumberReturned>\(max(0, end - start))</NumberReturned><TotalMatches>\(total)</TotalMatches><UpdateID>1</UpdateID></u:BrowseResponse></s:Body></s:Envelope>".utf8)
    }

    func testInvalidPageRequestNeverMakesHTTPCall() async throws {
        MediaStubProtocol.set({ _ in Self.emptyPage })
        let camera = try client()
        do { _ = try await camera.browse(start: -1, count: 40); XCTFail("Negative start must reject") } catch { }
        do { _ = try await camera.browse(start: 0, count: 41); XCTFail("Overlarge page must reject") } catch { }
        XCTAssertTrue(MediaStubProtocol.requests.isEmpty)
    }

    func testAtMostThreeImageRequestsRunWhileFourthWaits() async throws {
        let firstThree = expectation(description: "Three image transfers")
        firstThree.expectedFulfillmentCount = 3
        let unexpectedFourth = expectation(description: "Fourth request must wait")
        unexpectedFourth.isInverted = true
        MediaStubProtocol.set({ _ in Data([7]) }, held: true, onStart: { count in
            if count <= 3 { firstThree.fulfill() } else { unexpectedFourth.fulfill() }
        })
        let camera = try client()
        let resource = CameraMediaResource(url: URL(string: "http://192.168.54.1/thumb.JPG")!, mimeType: "image/jpeg", role: .thumbnail)
        let tasks = (0..<4).map { _ in Task { try await camera.imageData(resource) } }
        await fulfillment(of: [firstThree], timeout: 2)
        await fulfillment(of: [unexpectedFourth], timeout: 0.3)
        XCTAssertEqual(MediaStubProtocol.requests.count, 3)
        MediaStubProtocol.releaseAll()
        for task in tasks { let data = try await task.value; XCTAssertEqual(data, Data([7])) }
        XCTAssertEqual(MediaStubProtocol.requests.count, 4)
    }

    func testRedirectGuardRejectsCredentialedSameHostURL() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = URL(string: "http://192.168.54.1/file.JPG")!
        let request = URLRequest(url: URL(string: "http://user:password@192.168.54.1/file.JPG")!)
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = session.dataTask(with: source)
        let decision = RedirectDecision()
        decision.url = source
        let callback = expectation(description: "Redirect decision")
        SameCameraRedirectGuard(host: "192.168.54.1").urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { decision.url = $0?.url; callback.fulfill() }
        wait(for: [callback], timeout: 1)
        XCTAssertNil(decision.url)
        task.cancel()
    }

    private static let emptyPage = Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:BrowseResponse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><Result>&lt;DIDL-Lite/&gt;</Result><NumberReturned>0</NumberReturned><TotalMatches>0</TotalMatches></u:BrowseResponse></s:Body></s:Envelope>".utf8)
}

private final class RedirectDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var url: URL? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

private final class MediaStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: (@Sendable (URLRequest) -> Data)?
    private static var recorded: [URLRequest] = []
    private static var held = false
    private static var pending: [MediaStubProtocol] = []
    private static var onStart: (@Sendable (Int) -> Void)?
    private var receivedRequest: URLRequest?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func set(_ value: @escaping @Sendable (URLRequest) -> Data, held: Bool = false, onStart: (@Sendable (Int) -> Void)? = nil) {
        lock.withLock { handler = value; recorded = []; self.held = held; pending = []; self.onStart = onStart }
    }
    static func releaseAll() {
        let waiting = lock.withLock { () -> [MediaStubProtocol] in held = false; onStart = nil; let values = pending; pending = []; return values }
        for value in waiting { value.respond() }
    }
    static func reset() { releaseAll(); lock.withLock { handler = nil; recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var received = request
        if received.httpBody == nil, let stream = received.httpBodyStream {
            stream.open()
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, body.count < 16 * 1024 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            received.httpBody = body
        }
        receivedRequest = received
        let (hold, count, callback) = Self.lock.withLock { () -> (Bool, Int, (@Sendable (Int) -> Void)?) in
            Self.recorded.append(received)
            if Self.held { Self.pending.append(self) }
            return (Self.held, Self.recorded.count, Self.onStart)
        }
        callback?(count)
        if !hold { respond() }
    }
    private func respond() {
        let reply = Self.lock.withLock { Self.handler }
        let data = reply?(receivedRequest ?? request) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class MediaMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ message: String) { lock.withLock { stored.append(message) } }
}
