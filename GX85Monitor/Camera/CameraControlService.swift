import Foundation
import GX85Core

enum CameraCaptureOutcome: Equatable, Sendable {
    case confirmed, acceptedUnconfirmed, unknown
    case rejected(String)
}

enum CameraControlError: LocalizedError {
    case unavailable(String), unconfirmed
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .unconfirmed: return "相机状态尚未确认，请检查机身。操作没有自动重发。"
        }
    }
}

/// Owns the entire transaction, including awaits; the HTTP client's gate alone
/// cannot prevent a health request from splitting press and release.
actor CameraControlService {
    private let client: any CommandSending
    private let gate = ControlTransactionGate()
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let log: @Sendable (String) -> Void
    private var loggedFields: [String: String]?
    private(set) var latestState = CameraControlState(response: LumixResponse(status: .success))

    init(client: any CommandSending,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.client = client; self.sleep = sleep; self.log = log
    }

    func readState() async throws -> CameraControlState {
        try await transaction { try await self.readStateUnlocked() }
    }

    func sendExclusive(_ command: LumixCommand) async throws -> LumixResponse {
        try await transaction { try await self.send(command) }
    }

    func capturePhoto() async -> CameraCaptureOutcome {
        do {
            return try await transaction {
                var pressed = false
                var releaseAttempted = false
                var accepted = false
                do {
                    let state = try await self.readStateUnlocked()
                    if let reason = self.photoRestriction(state) { return .rejected(reason) }
                    let focus: String
                    do {
                        let response = try await self.send(.getSetting("focusmode"))
                        focus = (response.fields["focusmode"] ?? response.fields["value"] ?? "").lowercased()
                    } catch CommandError.cameraRejected {
                        // A camera that does not expose focusmode keeps its own focus priority.
                        focus = ""
                        self.log("相机未提供对焦模式；不改变机身对焦设置。")
                    }
                    self.log("拍前：对焦=\(focus.isEmpty ? "未知" : focus)，卡=\(state.cardStatus ?? "未知")，占用=\(state.isBusy.map(String.init) ?? "未知")")
                    if ["afs", "afc", "aff"].contains(focus) { _ = try await self.send(.autoFocus) }
                    pressed = true
                    _ = try await self.send(.capture)
                    accepted = true
                    try await self.sleep(0.1)
                    releaseAttempted = true
                    _ = try await self.send(.releaseCapture)
                    pressed = false
                    let deadline = ProcessInfo.processInfo.systemUptime + 4
                    for _ in 0..<20 {
                        try Task.checkCancellation()
                        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                        try await self.sleep(0.2)
                        _ = try await self.readStateUnlocked()
                    }
                    // Capacity estimates and an OK acknowledgment do not identify a new file.
                    self.log("拍后：指令已接受，缺少新文件确认；未自动重复快门。")
                    return .acceptedUnconfirmed
                } catch {
                    if pressed && !releaseAttempted {
                        let client = self.client
                        // Release an uncertain press even when the requesting view was canceled.
                        _ = await Task.detached { try? await client.send(.releaseCapture) }.value
                    }
                    self.log("拍摄事务：\(error.localizedDescription)")
                    if !accepted, case CommandError.cameraRejected(let code) = error { return .rejected(code) }
                    return .unknown
                }
            }
        } catch { return .unknown }
    }

    func setRecording(_ active: Bool) async throws -> CameraRecordingState {
        try await transaction {
            let before = try await self.readStateUnlocked()
            let desired: CameraRecordingState = active ? .recording : .stopped
            if before.recordingState == desired { return desired }
            guard before.recordingState != .unknown else { throw CameraControlError.unconfirmed }
            if active, before.isBusy == true { throw CameraControlError.unavailable("相机正在忙，请稍后再录像。") }
            do {
                _ = try await self.send(active ? .videoStart : .videoStop)
                let deadline = ProcessInfo.processInfo.systemUptime + 4
                for _ in 0..<20 {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    let state = try await self.readStateUnlocked()
                    if state.recordingState == desired { return desired }
                    try await self.sleep(0.2)
                }
                throw CameraControlError.unconfirmed
            } catch {
                self.latestState = CameraControlState(response: LumixResponse(status: .success))
                throw error
            }
        }
    }

    func setParameter(_ parameter: ExposureParameter, rawValue: String) async throws {
        try await transaction {
            _ = try await self.send(.setSetting(type: parameter.commandType, value: rawValue))
            let actual = try await self.send(.getSetting(parameter.commandType))
            guard (actual.fields[parameter.commandType] ?? actual.fields["value"]) == rawValue else { throw CameraControlError.unconfirmed }
        }
    }

    func enterPlayback() async throws -> CameraControlState {
        try await transaction {
            let state = try await self.readStateUnlocked()
            guard state.recordingState == .stopped else { throw CameraControlError.unavailable("录像中或录像状态未确认，不能进入相册。") }
            guard state.isBusy != true else { throw CameraControlError.unavailable("相机正在忙，请稍后打开相册。") }
            _ = try await self.send(.stopStream)
            _ = try await self.send(.playbackMode)
            for _ in 0..<4 {
                let after = try await self.readStateUnlocked()
                if after.rawFields["cammode"] != "recmode" { return after }
                try await self.sleep(0.1)
            }
            throw CameraControlError.unconfirmed
        }
    }

    func leavePlayback(port: UInt16) async throws -> CameraControlState {
        try await transaction {
            var state = try await self.readStateUnlocked()
            // A physical camera operation has priority over the album's previous state.
            if state.recordingState != .recording {
                _ = try await self.send(.recordMode)
                state = try await self.readStateUnlocked()
                guard state.rawFields["cammode"] != "playmode" else { throw CameraControlError.unconfirmed }
            }
            _ = try await self.send(.startStream(port: port))
            return state
        }
    }

    func focus(at point: CGPoint) async throws {
        try await transaction {
            guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { throw ControlInputError.invalidParameter }
            let response = try await self.send(.getSetting("focusmode"))
            let mode = (response.fields["focusmode"] ?? response.fields["value"] ?? "").lowercased()
            guard mode != "mf" else { throw CameraControlError.unavailable("机身处于 MF，请切换自动对焦。") }
            guard ["afs", "afc", "aff"].contains(mode) else { throw CameraControlError.unavailable("无法确认当前对焦模式。") }
            _ = try await self.send(.touchFocus(x: Int((point.x * 1000).rounded()), y: Int((point.y * 1000).rounded())))
        }
    }

    private func photoRestriction(_ state: CameraControlState) -> String? {
        guard state.recordingState == .stopped else { return "无法确认相机已停止录像，请检查机身。" }
        if state.isBusy == true { return "相机正在忙或写卡，请稍后再拍。" }
        if state.rawFields["cammode"] == "playmode" { return "相机处于回放，请先返回拍摄。" }
        if let card = state.cardStatus?.lowercased(), ["no_card", "none", "error", "full", "write_protected"].contains(card) { return "存储卡不可写：\(card)。" }
        if state.remainingPhotos == 0 { return "相机报告没有剩余拍摄张数。" }
        return nil
    }

    private func readStateUnlocked() async throws -> CameraControlState {
        let reply = try await send(.state)
        latestState = CameraControlState(response: reply)
        if loggedFields != reply.fields {
            loggedFields = reply.fields
            log("相机状态：" + String(reply.fields.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "，").prefix(512)))
        }
        return latestState
    }
    private func send(_ command: LumixCommand) async throws -> LumixResponse {
        try Task.checkCancellation()
        let reply = try await client.send(command)
        switch reply.status {
        case .success: return reply
        case .pendingApproval: throw CommandError.waitingApproval
        case .rejected(let code): throw CommandError.cameraRejected(code)
        }
    }
    private func transaction<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        try Task.checkCancellation()
        return try await body()
    }
}

private actor ControlTransactionGate {
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
    }
    func release() {
        if queue.isEmpty { occupied = false }
        else { queue.removeFirst().1.resume() }
    }
    private func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.0 == id }) { queue.remove(at: index).1.resume(throwing: CancellationError()) }
    }
}
