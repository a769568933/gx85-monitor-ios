import Foundation
import GX85Core

protocol CommandSending: Sendable {
    func send(_ command: LumixCommand) async throws -> LumixResponse
}

enum CommandError: LocalizedError {
    case httpStatus(Int), cameraRejected(String), timedOut, waitingApproval
    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "相机返回 HTTP \(code)。"
        case .cameraRejected(let code):
            if code == "err_already_connected" { return "相机正在被其他 App 控制。请关闭原厂 App，再重新开启相机遥控。" }
            return "相机未接受操作：\(code)。"
        case .timedOut: return "相机回应超时，请检查是否仍连接着相机 Wi-Fi。"
        case .waitingApproval: return "请在相机上允许连接。"
        }
    }
}

/// An actor alone is reentrant across URLSession awaits; the gate enforces one actual HTTP command.
actor LumixCommandClient: CommandSending {
    private let endpoint: CameraEndpoint
    private let session: URLSession
    private let gate = RequestGate()
    private let log: @Sendable (String) -> Void

    init(endpoint: CameraEndpoint, configuration: URLSessionConfiguration = .ephemeral, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.endpoint = endpoint
        self.log = log
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration, delegate: SameCameraRedirectGuard(host: endpoint.host), delegateQueue: nil)
    }

    func send(_ command: LumixCommand) async throws -> LumixResponse {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        try Task.checkCancellation()
        var request = URLRequest(url: try command.makeURL(endpoint: endpoint))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("GX85Monitor/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ResponseError.malformed }
            guard (200..<300).contains(http.statusCode) else { throw CommandError.httpStatus(http.statusCode) }
            let parsed: LumixResponse
            do { parsed = try LumixResponse.parse(data: data) }
            catch {
                let summary = String(decoding: data.prefix(512), as: UTF8.self)
                log("\(command.label)无法识别的回应：\(summary)")
                throw error
            }
            if case .rejected(let code) = parsed.status { throw CommandError.cameraRejected(code) }
            if command != .state { log("\(command.label)：\(parsed.summary)") }
            return parsed
        } catch {
            if Task.isCancelled { throw CancellationError() }
            log("\(command.label)失败：\(error.localizedDescription)")
            if (error as? URLError)?.code == .timedOut { throw CommandError.timedOut }
            throw error
        }
    }

    deinit { session.invalidateAndCancel() }
}

private actor RequestGate {
    private var occupied = false
    private var queue: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { queue.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
        // Once a permit is granted, the caller owns it even if cancellation races with release.
    }

    func release() {
        if queue.isEmpty { occupied = false }
        else { queue.removeFirst().1.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.0 == id }) else { return }
        queue.remove(at: index).1.resume(throwing: CancellationError())
    }
}
