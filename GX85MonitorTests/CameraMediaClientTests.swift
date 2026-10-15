import Foundation
import XCTest
import GX85Core
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
        MediaStubProtocol.set { _ in Self.emptyPage }
        let camera = try client()
        let page = try await camera.browse(start: 0, count: 40)
        XCTAssertTrue(page.items.isEmpty)
        let request = try XCTUnwrap(MediaStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.54.1:60606/Server0/CDS_control")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "SOAPAction"), "\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("<RequestedCount>40</RequestedCount>"))
        XCTAssertTrue(body.contains("<StartingIndex>0</StartingIndex>"))
        XCTAssertTrue(body.contains("<BrowseFlag>BrowseDirectChildren</BrowseFlag>"))
    }

    func testInvalidPageRequestNeverMakesHTTPCall() async throws {
        MediaStubProtocol.set { _ in Self.emptyPage }
        let camera = try client()
        do { _ = try await camera.browse(start: -1, count: 40); XCTFail("Negative start must reject") } catch { }
        do { _ = try await camera.browse(start: 0, count: 41); XCTFail("Overlarge page must reject") } catch { }
        XCTAssertTrue(MediaStubProtocol.requests.isEmpty)
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
        SameCameraRedirectGuard(host: "192.168.54.1").urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { decision.url = $0; callback.fulfill() }
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
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func set(_ value: @escaping @Sendable (URLRequest) -> Data) { lock.withLock { handler = value; recorded = [] } }
    static func reset() { lock.withLock { handler = nil; recorded = [] } }
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
        let reply = Self.lock.withLock { () -> (@Sendable (URLRequest) -> Data)? in Self.recorded.append(received); return Self.handler }
        let data = reply?(received) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
