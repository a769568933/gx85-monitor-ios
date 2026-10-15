import Foundation
import GX85Core

protocol CameraMediaBrowsing: Sendable {
    func browse(start: Int, count: Int, objectID: String) async throws -> CameraMediaPage
}

actor CameraMediaClient: CameraMediaBrowsing {
    nonisolated let cameraHost: String
    private let descriptionURL: URL?
    private let session: URLSession
    private let catalogGate = CameraPermitPool(limit: 1)
    private let imageGate = CameraPermitPool(limit: 3)
    private var service: ContentDirectoryService?
    private let log: @Sendable (String) -> Void

    init(endpoint: CameraEndpoint, descriptionURL: URL? = nil, configuration: URLSessionConfiguration = .ephemeral,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        cameraHost = endpoint.host; self.descriptionURL = descriptionURL; self.log = log
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: SameCameraRedirectGuard(host: endpoint.host), delegateQueue: nil)
    }

    func browse(start: Int, count: Int = 40, objectID: String = "0") async throws -> CameraMediaPage {
        guard start >= 0, (1...40).contains(count), !objectID.isEmpty, objectID.utf8.count <= 1024,
              !objectID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CameraMediaError.malformedDirectory }
        try await catalogGate.acquire()
        defer { Task { await catalogGate.release() } }
        try Task.checkCancellation()
        let resolved = try await resolveService()
        var request = URLRequest(url: resolved.url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(resolved.serviceType)#Browse\"", forHTTPHeaderField: "SOAPAction")
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Browse xmlns:u="\(resolved.serviceType)"><ObjectID>\(Self.escape(objectID))</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>\(start)</StartingIndex><RequestedCount>\(count)</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>
        """
        request.httpBody = Data(body.utf8)
        let data = try await CameraHTTPReader.data(for: request, session: session, cameraHost: cameraHost, limit: 4 * 1024 * 1024)
        try Task.checkCancellation()
        return try ContentDirectoryReply.parse(data: data, cameraHost: cameraHost, startingIndex: start)
    }

    func imageData(_ resource: CameraMediaResource, maximumSize: Int = 2 * 1024 * 1024) async throws -> Data {
        guard maximumSize > 0, maximumSize <= 4 * 1024 * 1024, resource.mimeType.hasPrefix("image/") else { throw CameraMediaError.malformedDirectory }
        let url = try MediaURLPolicy.validate(resource.url, cameraHost: cameraHost)
        try await imageGate.acquire()
        defer { Task { await imageGate.release() } }
        try Task.checkCancellation()
        return try await CameraHTTPReader.data(for: URLRequest(url: url), session: session, cameraHost: cameraHost, limit: maximumSize)
    }

    private func resolveService() async throws -> ContentDirectoryService {
        if let service { return service }
        if let descriptionURL {
            do {
                let data = try await CameraHTTPReader.data(for: URLRequest(url: descriptionURL), session: session, cameraHost: cameraHost, limit: 256 * 1024)
                try Task.checkCancellation()
                let result = try ContentDirectoryService.parseDescription(data: data, descriptionURL: descriptionURL, cameraHost: cameraHost)
                service = result
                return result
            } catch {
                try Task.checkCancellation()
                log("媒体服务发现：\(error.localizedDescription)；尝试当前相机的 GX85 兼容路径。")
            }
        }
        let result = try ContentDirectoryService.fallback(cameraHost: cameraHost)
        service = result
        return result
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    deinit { session.invalidateAndCancel() }
}

/// Runs outside an actor so the byte iterator does not hop back to an actor per byte.
enum CameraHTTPReader {
    static func data(for request: URLRequest, session: URLSession, cameraHost: String, limit: Int) async throws -> Data {
        guard let url = request.url else { throw CameraMediaError.invalidURL }
        _ = try MediaURLPolicy.validate(url, cameraHost: cameraHost)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw ResponseError.malformed }
        _ = try MediaURLPolicy.validate(finalURL, cameraHost: cameraHost)
        guard (200..<300).contains(http.statusCode) else { throw CommandError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw CameraMediaError.malformedDirectory }
        var data = Data()
        data.reserveCapacity(min(limit, Int(max(0, response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < limit else { throw CameraMediaError.malformedDirectory }
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}

actor CameraPermitPool {
    private let limit: Int
    private var occupied = 0
    private var queue: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int) { self.limit = max(1, limit) }
    func acquire() async throws {
        try Task.checkCancellation()
        if occupied < limit { occupied += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { queue.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    func release() {
        if queue.isEmpty { occupied -= 1 }
        else { queue.removeFirst().1.resume() }
    }
    private func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.0 == id }) { queue.remove(at: index).1.resume(throwing: CancellationError()) }
    }
}
