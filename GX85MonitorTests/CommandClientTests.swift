import Foundation
import XCTest
import GX85Core
@testable import GX85Monitor

final class CommandClientTests: XCTestCase {
    func testMenuUsesSeparateBoundedBodyBudget() async throws {
        let xml = "<camrply><result>ok</result><menuset><!--" + String(repeating: "x", count: 300_000) + "--></menuset></camrply>"
        StubProtocol.set { _ in .reply(200, Data(xml.utf8)) }
        let camera = try client()
        let menu = try await camera.send(.getInfo("allmenu"))
        XCTAssertEqual(menu.body, Data(xml.utf8))
        do { _ = try await camera.send(.state); XCTFail("State replies must keep the smaller budget") }
        catch is ResponseError { }
    }

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private func client() throws -> LumixCommandClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return LumixCommandClient(endpoint: try CameraEndpoint(host: "192.168.54.1"), configuration: configuration)
    }

    func testHTTP200WithCameraRejectionThrows() async throws {
        StubProtocol.set { _ in .reply(200, Data("err_reject".utf8)) }
        let client = try client()
        do { _ = try await client.send(.capture); XCTFail("Rejected capture must throw") }
        catch CommandError.cameraRejected(let code) { XCTAssertEqual(code, "err_reject") }
    }

    func testTimeoutDoesNotRetryCapture() async throws {
        StubProtocol.set { _ in .failure(URLError(.timedOut)) }
        let client = try client()
        do { _ = try await client.send(.capture); XCTFail("Timeout must throw") }
        catch CommandError.timedOut { }
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testMalformedReplyKeepsBoundedDiagnosticSummary() async throws {
        StubProtocol.set { _ in .reply(200, Data(("not-a-camera-result-" + String(repeating: "A", count: 4096)).utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let log = TestLogRecorder()
        let client = LumixCommandClient(endpoint: try CameraEndpoint(host: "192.168.54.1"), configuration: configuration, log: { log.append($0) })
        do { _ = try await client.send(.capture); XCTFail("Malformed camera reply must fail") }
        catch is ResponseError { }
        XCTAssertTrue(log.messages.contains { $0.contains("not-a-camera-result-") })
        XCTAssertTrue(log.messages.allSatisfy { $0.count <= 600 })
    }

    func testCancellationReleasesQueuedCommands() async throws {
        StubProtocol.set { request in
            if request.url?.query == "mode=getstate" { return .delayed }
            return .reply(200, Data("ok".utf8))
        }
        let client = try client()
        let started = expectation(description: "First command started")
        StubProtocol.onStart = { request in if request.url?.query == "mode=getstate" { started.fulfill() } }
        let first = Task { try await client.send(.state) }
        await fulfillment(of: [started], timeout: 1)
        let second = Task { try await client.send(.capture) }
        second.cancel()
        first.cancel()
        _ = try? await first.value
        do { _ = try await second.value; XCTFail("Cancelled queued command must not run") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        _ = try await client.send(.stopStream)
        XCTAssertFalse(StubProtocol.requests.contains { $0.url?.query == "mode=camcmd&value=capture" })
    }
}

private final class TestLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ message: String) { lock.lock(); values.append(message); lock.unlock() }
}

private final class StubProtocol: URLProtocol {
    enum Result { case reply(Int, Data), failure(Error), delayed }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Result)?
    private static var recorded: [URLRequest] = []
    static var onStart: ((URLRequest) -> Void)?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func set(_ value: @escaping (URLRequest) -> Result) { lock.lock(); handler = value; recorded = []; lock.unlock() }
    static func reset() { lock.lock(); handler = nil; recorded = []; onStart = nil; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let result = Self.handler?(request) ?? .failure(URLError(.unknown))
        let callback = Self.onStart
        Self.lock.unlock()
        callback?(request)
        switch result {
        case let .reply(status, data):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error): client?.urlProtocol(self, didFailWithError: error)
        case .delayed: break
        }
    }
    override func stopLoading() {}
}
