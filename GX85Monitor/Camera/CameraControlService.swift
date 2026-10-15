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
    private(set) var lastRecordingMutationSent = false
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
                var stage = "拍前状态"
                do {
                    let state = try await self.readStateUnlocked()
                    if let reason = self.photoRestriction(state) { return .rejected(reason) }
                    self.log("拍前：卡=\(state.cardStatus ?? "未知")，占用=\(state.isBusy.map(String.init) ?? "未知")；保留机身对焦优先设置。")
                    stage = "读取拍摄方式"
                    let selfFinishingSingle = try await self.shouldLetSingleExposureFinish()
                    // capture applies the camera's own focus priority. GX80 can reject
                    // oneshot_af in AFS; that optional command must not block the shutter.
                    stage = "发送快门"
                    pressed = true
                    self.log("发送快门请求：mode=camcmd&value=capture（仅发送一次）")
                    _ = try await self.send(.capture)
                    accepted = true
                    if selfFinishingSingle {
                        // A normal finite exposure is self-terminating. Canceling at
                        // 100ms may abort delayed AF/electronic capture before it starts.
                        pressed = false
                        self.log("已确认单张有限曝光：等待机身完成，不提前发送 capture_cancel。")
                    } else {
                        try await self.sleep(0.1)
                        stage = "释放快门"
                        releaseAttempted = true
                        self.log("发送释放快门请求：mode=camcmd&value=capture_cancel")
                        _ = try await self.send(.releaseCapture)
                        pressed = false
                    }
                    stage = "拍后状态"
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
                    self.log("拍摄事务（\(stage)）：\(error.localizedDescription)")
                    if !accepted, case CommandError.cameraRejected(let code) = error { return .rejected(code) }
                    return .unknown
                }
            }
        } catch { return .unknown }
    }

    private func shouldLetSingleExposureFinish() async throws -> Bool {
        do {
            let menu = try await send(.getInfo("curmenu"))
            let drive = try CameraCapabilities.driveMode(currentMenu: menu.body)
            log("拍摄驱动：\(drive ?? "未知，使用兼容释放")")
            guard drive == "normal" else { return false }
            let setting = try await send(.getSetting("shtrspeed"))
            guard let raw = setting.fields["shtrspeed"] ?? setting.fields["value"] else { return false }
            let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] == "256", let numerator = Int(parts[0]), (-2048...4096).contains(numerator) else {
                log("快门为长按或未知编码：\(String(raw.prefix(64)))；保留释放步骤。")
                return false
            }
            return true
        } catch CommandError.cameraRejected(let code) {
            log("拍摄方式未提供：\(code)；使用兼容释放。")
            return false
        } catch ResponseError.malformed {
            log("拍摄方式元数据未识别；使用兼容释放。")
            return false
        }
        // Timeouts, cancellation, and access errors propagate: never fire after
        // an uncertain preflight or try a second shutter as a fallback.
    }

    func prepareLiveViewQuality() async throws {
        try await transaction {
            do {
                let menu = try await self.send(.getInfo("allmenu"))
                guard try CameraCapabilities.supportsVGALiveView(menu: menu.body) else { return }
                let reply = try await self.send(.getSetting("liveviewsize"))
                let size = reply.fields["liveviewsize"] ?? reply.fields["value"] ?? ""
                self.log("相机监看设置：\(size.prefix(64))；以实际帧分辨率为准。")
                guard size == "qvga" else { return }
                let state = try await self.readStateUnlocked()
                guard state.recordingState == .stopped, state.isBusy != true else { return }
                _ = try await self.send(.setSetting(type: "liveviewsize", value: "vga"))
                let actual = try await self.send(.getSetting("liveviewsize"))
                self.log("已请求 VGA 监看；回读=\(actual.fields["liveviewsize"] ?? actual.fields["value"] ?? "未知")；等待实际画面确认。")
            } catch {
                try Task.checkCancellation()
                self.log("可选监看画质设置不可用：\(error.localizedDescription)；保留相机现有输出。")
            }
        }
    }

    func setRecording(_ active: Bool) async throws -> CameraRecordingState {
        try await transaction {
            self.lastRecordingMutationSent = false
            let before = try await self.readStateUnlocked()
            let desired: CameraRecordingState = active ? .recording : .stopped
            if before.recordingState == desired { return desired }
            guard before.recordingState != .unknown else { throw CameraControlError.unconfirmed }
            if active, before.isBusy == true { throw CameraControlError.unavailable("相机正在忙，请稍后再录像。") }
            do {
                _ = try await self.send(active ? .videoStart : .videoStop)
                self.lastRecordingMutationSent = true
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
                if after.isPlayback == true { return after }
                try await self.sleep(0.1)
            }
            throw CameraControlError.unconfirmed
        }
    }

    func leavePlayback(port: UInt16) async throws -> CameraControlState {
        try await transaction {
            var state = try await self.readStateUnlocked()
            // A physical camera operation has priority over the album's previous state.
            // GX85 omits rec in an explicit play state; that is a valid state from
            // which to return to rec, not an unknown recording in shooting mode.
            guard state.recordingState != .unknown || state.isPlayback == true else { throw CameraControlError.unconfirmed }
            if state.isPlayback == true, state.recordingState == .recording { throw CameraControlError.unconfirmed }
            if state.recordingState != .recording {
                _ = try await self.send(.recordMode)
                var restored = false
                for _ in 0..<8 {
                    state = try await self.readStateUnlocked()
                    if state.isPlayback == false, state.recordingState != .unknown { restored = true; break }
                    try await self.sleep(0.1)
                }
                guard restored else { throw CameraControlError.unconfirmed }
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
            let x = Int((point.x * 1000).rounded()), y = Int((point.y * 1000).rounded())
            self.log("点按对焦请求：type=touch，位置=\(x)/\(y)，value2=on。")
            _ = try await self.send(.touchFocus(x: x, y: y))
        }
    }

    private func photoRestriction(_ state: CameraControlState) -> String? {
        guard state.recordingState == .stopped else { return "无法确认相机已停止录像，请检查机身。" }
        if state.isBusy == true { return "相机正在忙或写卡，请稍后再拍。" }
        if state.isPlayback == true { return "相机处于回放，请先返回拍摄。" }
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
