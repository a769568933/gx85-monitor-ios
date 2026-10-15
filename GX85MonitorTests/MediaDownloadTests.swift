import Foundation
import Network
import XCTest
import GX85Core
@testable import GX85Monitor

final class MediaDownloadTests: XCTestCase {
    private func resource(_ url: URL, size: Int64? = nil, role: CameraMediaResource.Role = .original) -> CameraMediaResource {
        CameraMediaResource(url: url, mimeType: "video/mp4", role: role, size: size)
    }
    func testDownloadUsesOwnedFileAndDiscardCannotDeleteOtherFiles() async throws {
        let server = try await DownloadHTTPServer.start(body: Data(repeating: 7, count: 256 * 1024))
        defer { server.stop() }
        let service = MediaDownloadService(cameraHost: "127.0.0.1")
        let url = try await service.download(resource(server.url, size: 256 * 1024)) { _ in }
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: url).count, 256 * 1024)
        XCTAssertFalse(url.lastPathComponent.contains("unsafe"))
        let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([8]).write(to: unrelated)
        defer { try? FileManager.default.removeItem(at: unrelated) }
        await service.discard(unrelated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        await service.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testUnknownLengthReportsIndeterminateAndFinishesFile() async throws {
        let server = try await DownloadHTTPServer.start(body: Data([1, 2, 3]), length: false)
        defer { server.stop() }
        let service = MediaDownloadService(cameraHost: "127.0.0.1")
        let values = DownloadProgressLog()
        let url = try await service.download(resource(server.url)) { values.append($0) }
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertTrue(values.hasIndeterminate)
        await service.discard(url)
    }
    func testUnavailableSpaceAndThumbnailNeverStartNetwork() async throws {
        let server = try await DownloadHTTPServer.start(body: Data([1]))
        defer { server.stop() }
        let service = MediaDownloadService(cameraHost: "127.0.0.1", availableBytes: { 0 })
        do { _ = try await service.download(resource(server.url, size: 1)) { _ in }; XCTFail("Space required") } catch { }
        do { _ = try await service.download(resource(server.url, role: .thumbnail)) { _ in }; XCTFail("Original required") } catch { }
        XCTAssertEqual(server.requestCount, 0)
    }
    func testOversizePartialAndExternalRedirectFailWithoutOwnedFiles() async throws {
        for headers in ["Content-Length: 8589934593\r\n", "Content-Length: 99\r\n", "Location: http://example.invalid/video.mp4\r\n"] {
            let status = headers.hasPrefix("Location") ? 302 : 200
            let server = try await DownloadHTTPServer.start(body: Data([1]), rawHeaders: headers, status: status)
            defer { server.stop() }
            let service = MediaDownloadService(cameraHost: "127.0.0.1")
            do { _ = try await service.download(resource(server.url)) { _ in }; XCTFail("Invalid transfer must fail") } catch { }
            let count = await service.ownedFileCount
            XCTAssertEqual(count, 0)
        }
    }
    func testCancellationAndNetworkLossRemoveOnlyThisTransfer() async throws {
        for cancel in [true, false] {
            let server = try await DownloadHTTPServer.start(body: Data(repeating: 4, count: 4096), rawHeaders: "Content-Length: 1048576\r\n", hang: true)
            let service = MediaDownloadService(cameraHost: "127.0.0.1")
            let task = Task { try await service.download(resource(server.url)) { _ in } }
            for _ in 0..<200 { if server.requestCount > 0 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(server.requestCount, 1)
            if cancel { task.cancel() } else { server.stop() }
            do { _ = try await task.value; XCTFail("Interrupted download must fail") } catch { }
            server.stop()
            let count = await service.ownedFileCount
            XCTAssertEqual(count, 0)
        }
    }
}

private final class DownloadProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double?] = []
    func append(_ value: Double?) { lock.withLock { values.append(value) } }
    var hasIndeterminate: Bool { lock.withLock { values.contains { $0 == nil } } }
}

/// A real loopback HTTP response exercises URLSessionDownloadTask's file delivery.
private final class DownloadHTTPServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "download-http-test")
    let lock = NSLock()
    var connections: [NWConnection] = []
    private var count = 0
    let body: Data, headers: String, status: Int, hang: Bool
    var requestCount: Int { lock.withLock { count } }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/unsafe.mp4")! }
    private init(body: Data, length: Bool, rawHeaders: String?, status: Int, hang: Bool) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.body = body; self.headers = rawHeaders ?? (length ? "Content-Length: \(body.count)\r\n" : "")
        self.status = status; self.hang = hang
    }
    static func start(body: Data, length: Bool = true, rawHeaders: String? = nil, status: Int = 200, hang: Bool = false) async throws -> DownloadHTTPServer {
        let server = try DownloadHTTPServer(body: body, length: length, rawHeaders: rawHeaders, status: status, hang: hang)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: server.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): server.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.newConnectionHandler = { [weak server] connection in
                guard let server else { connection.cancel(); return }
                server.lock.withLock { server.connections.append(connection) }
                connection.start(queue: server.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { _, _, _, _ in
                    server.lock.withLock { server.count += 1 }
                    let header = Data("HTTP/1.1 \(server.status) Test\r\n\(server.headers)Connection: close\r\n\r\n".utf8)
                    connection.send(content: header + server.body, completion: .contentProcessed { _ in if !server.hang { connection.cancel() } })
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }
    func stop() {
        listener.cancel()
        let current = lock.withLock { let result = connections; connections = []; return result }
        current.forEach { $0.cancel() }
    }
}
