import Foundation
import Network
import GX85Core

/// Unicast to the entered camera only. No multicast entitlement or Wi-Fi scanning required.
enum CameraIdentityResolver {
    static func descriptionLocation(endpoint: CameraEndpoint) async -> URL? {
        try? await UnicastDiscovery().location(endpoint: endpoint)
    }
    static func resolve(endpoint: CameraEndpoint) async -> String? {
        do {
            let probe = UnicastDiscovery()
            let location = try await probe.location(endpoint: endpoint)
            try Task.checkCancellation()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.allowsCellularAccess = false
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 2
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: SameCameraRedirectGuard(host: endpoint.host), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: location)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return DiscoveryReply.accessID(data: data)
        } catch { return nil }
    }
}

final class SameCameraRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, (try? MediaURLPolicy.validate(url, cameraHost: host)) != nil { completionHandler(request) }
        else { completionHandler(nil) }
    }
}

private final class UnicastDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GX85Monitor.identity")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancelled = false

    func location(endpoint: CameraEndpoint) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                queue.async {
                    if self.cancelled { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let parameters = NWParameters.udp
                    parameters.requiredInterfaceType = .wifi
                    let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: 1900, using: parameters)
                    self.connection = connection
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        guard let self, let connection else { return }
                        switch state {
                        case .ready:
                            let search = "M-SEARCH * HTTP/1.1\r\nHOST: \(endpoint.host):1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n"
                            connection.send(content: Data(search.utf8), completion: .contentProcessed { [weak self] error in
                                if let error { self?.finish(.failure(error)) }
                            })
                            self.receive(host: endpoint.host)
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                    connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 2) { self.finish(.failure(CommandError.timedOut)) }
                }
            }
        }, onCancel: { self.queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) } })
    }

    private func receive(host: String) {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.continuation != nil else { return }
            if let error { self.finish(.failure(error)) }
            else if let data, let url = DiscoveryReply.location(data: data, cameraHost: host) { self.finish(.success(url)) }
            else { self.receive(host: host) }
        }
    }
    private func finish(_ result: Result<URL, Error>) {
        let value = continuation
        continuation = nil
        connection?.cancel()
        connection = nil
        value?.resume(with: result)
    }
}
