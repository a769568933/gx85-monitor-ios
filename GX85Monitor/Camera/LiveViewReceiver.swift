import Foundation
import Network
import GX85Core

protocol LiveViewReceiving: AnyObject {
    func start(endpoint: CameraEndpoint, onDatagram: @escaping @Sendable (Data) -> Void) async throws
    func stop()
}

/// All Network state is confined to queue. Listener readiness is awaited before startstream.
final class LiveViewReceiver: LiveViewReceiving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "GX85Monitor.udp", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var ready: CheckedContinuation<Void, Error>?
    private var token = UUID()
    private var callback: (@Sendable (Data) -> Void)?

    func start(endpoint: CameraEndpoint, onDatagram: @escaping @Sendable (Data) -> Void) async throws {
        let current = UUID()
        let cancellation = ReceiverCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    self.stopOnQueue()
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.token = current
                    self.callback = onDatagram
                    self.ready = continuation
                    do {
                        let parameters = NWParameters.udp
                        parameters.requiredInterfaceType = .wifi
                        parameters.allowLocalEndpointReuse = false
                        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw EndpointError.invalidAddress }
                        let listener = try NWListener(using: parameters, on: port)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self, self.token == current else { return }
                            switch state {
                            case .ready: self.resolveReady(nil)
                            case .failed(let error): self.resolveReady(error); self.stopOnQueue()
                            case .cancelled: self.resolveReady(CancellationError())
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] newConnection in
                            guard let self, self.token == current,
                                  case .hostPort(let host, _) = newConnection.endpoint,
                                  String(describing: host) == endpoint.host,
                                  self.connection == nil else { newConnection.cancel(); return }
                            self.connection = newConnection
                            newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
                                guard let self, let newConnection, self.token == current else { return }
                                switch state {
                                case .ready: self.receive(newConnection, token: current)
                                case .failed, .cancelled:
                                    if self.connection === newConnection { self.connection = nil }
                                default: break
                                }
                            }
                            newConnection.start(queue: self.queue)
                        }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                            guard let self, self.token == current, self.ready != nil else { return }
                            self.resolveReady(CommandError.timedOut)
                            self.stopOnQueue()
                        }
                    } catch { self.resolveReady(error); self.stopOnQueue() }
                }
            }
        }, onCancel: {
            cancellation.cancel()
            self.queue.async { if self.token == current { self.stopOnQueue() } }
        })
        if Task.isCancelled { stop(); throw CancellationError() }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func resolveReady(_ error: Error?) {
        let continuation = ready
        ready = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    private func stopOnQueue() {
        token = UUID()
        resolveReady(CancellationError())
        listener?.cancel()
        connection?.cancel()
        listener = nil
        connection = nil
        callback = nil
    }

    private func receive(_ connection: NWConnection, token current: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.token == current else { return }
            if let data, !data.isEmpty { self.callback?(data) }
            if error == nil { self.receive(connection, token: current) }
            else { connection.cancel(); if self.connection === connection { self.connection = nil } }
        }
    }

    deinit { listener?.cancel(); connection?.cancel() }
}

private final class ReceiverCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
