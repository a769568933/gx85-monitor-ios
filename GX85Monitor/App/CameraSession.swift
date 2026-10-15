import Foundation
import Combine
import UIKit
import GX85Core

@MainActor
final class CameraSession: ObservableObject {
    struct FocusRequest: Identifiable {
        let id = UUID()
        let point: CGPoint
    }
    enum Phase: Equatable {
        case disconnected, connecting, waitingApproval, ready, monitoring, recovering, failed, browsing
        var title: String {
            switch self {
            case .disconnected: return "未连接"
            case .connecting: return "正在连接"
            case .waitingApproval: return "请在相机上允许连接"
            case .ready: return "等待画面"
            case .monitoring: return "监看中"
            case .recovering: return "正在恢复连接"
            case .failed: return "连接未成功"
            case .browsing: return "浏览相册"
            }
        }
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var image: UIImage?
    @Published private(set) var isCapturing = false
    @Published private(set) var actionInProgress = false
    @Published private(set) var controlState = CameraControlState(response: LumixResponse(status: .success))
    @Published private(set) var selectedShootingMode: CameraShootingMode = .photo
    @Published private var recordingStartedUptime: TimeInterval?
    var recordingElapsed: TimeInterval? {
        guard controlState.recordingState == .recording, let start = recordingStartedUptime else { return nil }
        let elapsed = clock() - start
        return elapsed.isFinite ? max(0, elapsed) : nil
    }
    var recordingTimerText: String {
        guard let elapsed = recordingElapsed else { return "时长未知" }
        let seconds = Int(min(elapsed, Double(Int.max / 2)))
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        if seconds >= 3600 { return "\(two(seconds / 3600)):\(two(seconds / 60 % 60)):\(two(seconds % 60))" }
        return "\(two(seconds / 60)):\(two(seconds % 60))"
    }
    @Published private(set) var parameterOptions: [ExposureParameter: [CameraParameterOption]] = [:]
    @Published private(set) var parameterValues: [ExposureParameter: String] = [:]
    @Published private(set) var focusRequest: FocusRequest?
    @Published private(set) var isBrowsing = false
    private(set) var playbackID: UUID?
    @Published private(set) var frameIsStale = false
    @Published private(set) var notice: String?
    @Published private(set) var lastError: String?
    @Published private(set) var frameRate = 0.0
    @Published private(set) var lastFrameAge: TimeInterval?
    @Published private(set) var packets = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var invalidImages = 0
    @Published private(set) var droppedPackets = 0
    @Published private(set) var streamRestarting = false
    @Published private(set) var recoveryCount = 0
    private(set) var wantsConnection = false
    let settings: CameraSettings
    let diagnostics = DiagnosticsLog()

    private let makeClient: ((CameraEndpoint) -> any CommandSending)?
    private let makeMediaClient: ((CameraEndpoint) async -> CameraMediaClient)?
    private let makeReceiver: () -> any LiveViewReceiving
    private let clock: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let controlSleep: @Sendable (TimeInterval) async throws -> Void
    private var client: (any CommandSending)?
    private var controls: CameraControlService?
    private var parameterService: CameraParameterService?
    private var parameterTask: Task<Void, Never>?
    private var parameterRequest = UUID()
    private var lastParameterWarning: String?
    private var focusFeedbackTask: Task<Void, Never>?
    private var playbackTask: Task<CameraMediaClient, Error>?
    private var playbackRestoreTask: Task<Void, Error>?
    private var playbackKeepaliveTask: Task<Void, Never>?
    private var receiver: (any LiveViewReceiving)?
    private var connectionTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var displayClockTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var epoch = UUID()
    private var generation = UUID()
    private var foreground = true
    private var controlReady = false
    private var deferredRecovery = false
    private var policy = SessionPolicy()
    private var lastFrameTime: TimeInterval?
    private var fpsStart: TimeInterval = 0
    private var fpsFrames = 0

    private lazy var decoder = LatestFrameDecoder(onImage: { [weak self] image, generation in
        self?.received(image, generation: generation)
    }, onStats: { [weak self] packets, dropped, invalid, lostPackets, generation in
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation, self.wantsConnection, self.foreground else { return }
            self.packets = packets
            self.droppedFrames = dropped
            self.invalidImages = invalid
            self.droppedPackets = lostPackets
        }
    })

    init(settings: CameraSettings,
         makeClient: ((CameraEndpoint) -> any CommandSending)? = nil,
         makeReceiver: @escaping () -> any LiveViewReceiving = { LiveViewReceiver() },
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         },
         controlSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         },
         makeMediaClient: ((CameraEndpoint) async -> CameraMediaClient)? = nil) {
        self.settings = settings
        self.clock = clock
        self.sleep = sleep
        self.controlSleep = controlSleep
        self.makeReceiver = makeReceiver
        self.makeClient = makeClient
        self.makeMediaClient = makeMediaClient
    }

    var canCapture: Bool { controlReady && foreground && wantsConnection && !actionInProgress && !streamRestarting && !isBrowsing }
    var isActive: Bool { wantsConnection }

    func connect() {
        guard foreground else { return }
        cancelTasksAndTransport()
        wantsConnection = true
        epoch = UUID()
        policy = SessionPolicy()
        recoveryCount = 0
        notice = nil
        lastError = nil
        image = nil
        diagnostics.append("开始连接 \(settings.host)")
        launchConnection(delayed: false)
    }

    func disconnect() {
        wantsConnection = false
        let previousClient = client
        let previousControls = controls
        cancelTasksAndTransport()
        phase = .disconnected
        image = nil
        frameIsStale = false
        lastFrameAge = nil
        notice = nil
        diagnostics.append("已主动断开")
        // The old client belongs only to this session. It never operates a later connection.
        stopOldStream(previousClient, controls: previousControls)
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if !value {
            let previousClient = client
            let previousControls = controls
            cancelTasksAndTransport()
            phase = .disconnected
            image = nil
            diagnostics.append("进入后台，停止监看")
            stopOldStream(previousClient, controls: previousControls)
        } else if wantsConnection {
            policy = SessionPolicy()
            diagnostics.append("返回前台，重新连接")
            launchConnection(delayed: false)
        }
    }

    func clearNotice() { notice = nil }
    func showNotice(_ message: String) { notice = String(message.prefix(2048)) }

    func beginPlayback() async throws -> CameraMediaClient {
        guard canCapture, let controls else { throw CameraControlError.unavailable("请先连接相机并停止当前操作。") }
        actionInProgress = true
        playbackID = UUID()
        parameterTask?.cancel(); parameterTask = nil; parameterRequest = UUID()
        let current = epoch
        let task = Task<CameraMediaClient, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try await controls.readState()
            try self.check(current)
            self.applyControlState(state)
            guard state.recordingState == .stopped else { throw CameraControlError.unavailable("录像中或录像状态未确认，不能进入相册。") }
            self.isBrowsing = true; self.controlReady = false; self.phase = .browsing
            self.monitorTask?.cancel(); self.monitorTask = nil
            self.displayClockTask?.cancel(); self.displayClockTask = nil
            self.receiver?.stop(); self.receiver = nil
            self.generation = UUID(); self.decoder.reset(generation: self.generation)
            self.image = nil; self.focusRequest = nil
            let playbackState = try await controls.enterPlayback()
            try self.check(current)
            self.applyControlState(playbackState)
            let endpoint = try self.settings.endpoint()
            let client: CameraMediaClient
            if let factory = self.makeMediaClient { client = await factory(endpoint) }
            else {
                let description = await CameraIdentityResolver.descriptionLocation(endpoint: endpoint)
                try self.check(current)
                client = CameraMediaClient(endpoint: endpoint, descriptionURL: description, log: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.epoch == current else { return }
                        self.diagnostics.append(message)
                    }
                })
            }
            try self.check(current)
            self.startPlaybackKeepalive(current, controls: controls)
            return client
        }
        playbackTask = task
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try check(current)
            playbackTask = nil; actionInProgress = false
            return result
        } catch {
            if isCurrent(current) {
                playbackTask = nil; actionInProgress = false
                if isBrowsing {
                    await Task { @MainActor [weak self] in await self?.endPlayback() }.value
                }
                if isCurrent(current) { playbackID = nil; notice = error.localizedDescription }
            }
            throw error
        }
    }

    func endPlayback(owner: UUID? = nil, noticeAfter: String? = nil) async {
        if let owner, playbackID != owner { return }
        guard isBrowsing else { return }
        isBrowsing = false
        playbackID = nil
        playbackKeepaliveTask?.cancel(); playbackKeepaliveTask = nil
        guard wantsConnection, foreground, let controls else { return }
        actionInProgress = true
        let current = epoch
        let task = Task<Void, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let endpoint = try self.settings.endpoint()
            self.generation = UUID()
            let frameGeneration = self.generation, decoder = self.decoder
            decoder.reset(generation: frameGeneration)
            let receiver = self.makeReceiver()
            self.receiver = receiver
            try await receiver.start(endpoint: endpoint) { decoder.receive($0, generation: frameGeneration) }
            try self.check(current)
            let state = try await controls.leavePlayback(port: endpoint.port)
            try self.check(current)
            self.applyControlState(state)
            self.policy = SessionPolicy(); self.policy.streamStarted(now: self.clock())
            self.lastFrameTime = nil; self.lastFrameAge = nil; self.frameIsStale = false
            self.fpsStart = self.clock(); self.fpsFrames = 0; self.frameRate = 0
            self.controlReady = true; self.phase = .ready
            self.startMonitor(current)
        }
        playbackRestoreTask = task
        do {
            try await task.value
            guard isCurrent(current) else { return }
            playbackRestoreTask = nil; actionInProgress = false
            refreshParameters()
            if let noticeAfter { notice = noticeAfter }
        } catch {
            guard isCurrent(current) else { return }
            playbackRestoreTask = nil; actionInProgress = false
            notice = (noticeAfter.map { $0 + "\n" } ?? "") + "恢复监看未成功：\(error.localizedDescription)"
            recover()
        }
    }

    private func startPlaybackKeepalive(_ current: UUID, controls: CameraControlService) {
        playbackKeepaliveTask?.cancel()
        playbackKeepaliveTask = Task { [weak self] in
            guard let self else { return }
            while self.isCurrent(current), self.isBrowsing, !Task.isCancelled {
                do {
                    try await self.sleep(2); try self.check(current)
                    let state = try await controls.readState()
                    try self.check(current)
                    guard self.isBrowsing else { return }
                    self.applyControlState(state)
                } catch {
                    guard self.isCurrent(current), self.isBrowsing, !Task.isCancelled else { return }
                    self.diagnostics.append("相册连接状态：\(error.localizedDescription)")
                }
            }
        }
    }

    func selectShootingMode(_ mode: CameraShootingMode) {
        guard mode != .unknown, !actionInProgress, controlState.recordingState != .recording else { return }
        selectedShootingMode = mode
        refreshParameters()
    }

    func capture() { performPrimaryAction() }

    func performPrimaryAction() {
        guard canCapture, let controls else { return }
        isCapturing = true
        actionInProgress = true
        notice = nil
        policy.captureStarted()
        let current = epoch
        let mode = selectedShootingMode
        let shouldStartRecording = controlState.recordingState != .recording
        let refreshRecordingOnly = mode == .video && controlState.recordingState == .unknown
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                if mode == .video {
                    var initiatedStart = false
                    if refreshRecordingOnly { _ = try await controls.readState() }
                    else {
                        _ = try await controls.setRecording(shouldStartRecording)
                        let sent = await controls.lastRecordingMutationSent
                        initiatedStart = shouldStartRecording && sent
                    }
                    try self.check(current)
                    self.applyControlState(await controls.latestState)
                    if initiatedStart, self.controlState.recordingState == .recording { self.recordingStartedUptime = self.clock() }
                    if refreshRecordingOnly { self.notice = "已读取录像状态，请再次点击开始或停止；状态未确认时不会自动开始录像。" }
                    else { self.notice = self.controlState.recordingState == .recording ? "相机已确认开始录像。" : "相机已确认停止录像。" }
                } else {
                    let outcome = await controls.capturePhoto()
                    try self.check(current)
                    self.applyControlState(await controls.latestState)
                    switch outcome {
                    case .confirmed: self.notice = "相机已确认生成新照片。"
                    case .acceptedUnconfirmed: self.notice = "拍照指令已接受，拍摄结果待确认，请检查相机。"
                    case .rejected(let reason): self.notice = "无法拍照：\(reason)"
                    case .unknown: self.notice = "拍摄结果未知，请检查相机。为避免重复拍摄，未自动重试。"
                    }
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                guard self.isCurrent(current) else { return }
                self.controlState = CameraControlState(response: LumixResponse(status: .success))
                self.recordingStartedUptime = nil
                self.notice = error.localizedDescription
                self.diagnostics.append("拍摄操作：\(error.localizedDescription)")
            }
            guard self.isCurrent(current) else { return }
            self.isCapturing = false
            self.actionInProgress = false
            self.policy.captureFinished(now: self.clock())
            self.captureTask = nil
            if self.deferredRecovery { self.deferredRecovery = false; self.recover() }
        }
    }

    private func launchConnection(delayed: Bool) {
        let current = epoch
        connectionTask = Task { [weak self] in
            guard let self else { return }
            // An old stopstream must settle before a new startstream reaches the same camera.
            if let cleanup = self.cleanupTask { await cleanup.value }
            guard self.isCurrent(current), !Task.isCancelled else { return }
            var shouldDelay = delayed
            while self.isCurrent(current) && !Task.isCancelled {
                if shouldDelay {
                    guard let delay = self.policy.nextReconnectDelay() else {
                        self.phase = .failed
                        self.lastError = "恢复尝试已结束。请检查相机遥控模式和 Wi-Fi，然后点重新连接。"
                        self.controlReady = false
                        self.connectionTask = nil
                        return
                    }
                    self.phase = .recovering
                    self.recoveryCount += 1
                    self.diagnostics.append("\(Int(delay)) 秒后尝试恢复，第 \(self.recoveryCount) 次")
                    do { try await self.sleep(delay); try self.check(current) }
                    catch { return }
                }
                do {
                    try await self.establish(current)
                    try self.check(current)
                    self.connectionTask = nil
                    self.startMonitor(current)
                    return
                } catch {
                    guard self.isCurrent(current), !Task.isCancelled else { return }
                    self.lastError = error.localizedDescription
                    self.diagnostics.append("连接失败：\(error.localizedDescription)")
                    self.closeTransport()
                    shouldDelay = true
                }
            }
        }
    }

    private func establish(_ current: UUID) async throws {
        try check(current)
        let endpoint = try settings.endpoint()
        generation = UUID()
        let frameGeneration = generation
        decoder.reset(generation: frameGeneration)
        phase = .connecting
        controlReady = false
        frameRate = 0
        packets = 0
        droppedFrames = 0
        invalidImages = 0
        droppedPackets = 0
        lastFrameTime = nil
        fpsStart = clock()
        fpsFrames = 0
        let commandClient: any CommandSending = makeClient?(endpoint) ?? LumixCommandClient(endpoint: endpoint, log: { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == current else { return }
                self.diagnostics.append(message)
            }
        })
        client = commandClient
        controls = CameraControlService(client: commandClient, sleep: controlSleep, log: { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == current else { return }
                self.diagnostics.append(message)
            }
        })
        if let controls { parameterService = CameraParameterService(controls: controls) }
        var id = settings.accessID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            if let discovered = await CameraIdentityResolver.resolve(endpoint: endpoint) {
                try check(current)
                id = discovered
                settings.accessID = discovered
                diagnostics.append("已读取相机连接标识")
            } else {
                try check(current)
                diagnostics.append("相机未回应单播识别，尝试本机连接标识；若失败请按协议说明设置标识")
            }
        }
        let accessID = id.isEmpty ? settings.clientID : id.replacingOccurrences(of: "uuid:", with: "")
        var permitted = false
        let deadline = clock() + 30
        for _ in 0..<30 {
            let response = try await commandClient.send(.requestAccess(clientID: accessID, name: "GX85 Monitor"))
            try check(current)
            if response.status == .success { permitted = true; break }
            phase = .waitingApproval
            if clock() >= deadline { break }
            try await sleep(1)
            try check(current)
        }
        guard permitted else { throw CommandError.waitingApproval }
        try await sendSuccess(.state, via: commandClient, current: current)
        if controlState.recordingState == .stopped { try await sendSuccess(.recordMode, via: commandClient, current: current) }
        if controlState.recordingState == .stopped { try await controls?.prepareLiveViewQuality() }
        try check(current)
        let liveReceiver = makeReceiver()
        receiver = liveReceiver
        let decoder = self.decoder
        try await liveReceiver.start(endpoint: endpoint) { data in decoder.receive(data, generation: frameGeneration) }
        try check(current)
        try await sendSuccess(.startStream(port: endpoint.port), via: commandClient, current: current)
        controlReady = true
        phase = .ready
        policy.streamStarted(now: clock())
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true
        diagnostics.append("控制连接就绪，等待有效画面")
        refreshParameters()
    }

    private func sendSuccess(_ command: LumixCommand, via client: any CommandSending, current: UUID) async throws {
        if command == .state, let controls {
            let state = try await controls.readState()
            try check(current)
            applyControlState(state)
            return
        }
        let response: LumixResponse
        if let controls { response = try await controls.sendExclusive(command) }
        else { response = try await client.send(command) }
        try check(current)
        guard response.status == .success else { throw CommandError.waitingApproval }
    }

    private func applyControlState(_ state: CameraControlState) {
        if state.recordingState != .recording || controlState.recordingState != .recording { recordingStartedUptime = nil }
        if let lens = state.rawFields["lens"], lens != controlState.rawFields["lens"] {
            parameterTask?.cancel(); parameterTask = nil; parameterRequest = UUID()
            parameterOptions = [:]; parameterValues = [:]
        }
        controlState = state
        if state.shootingMode != .unknown { selectedShootingMode = state.shootingMode }
    }

    private func refreshParameters() {
        guard controlReady, foreground, wantsConnection, !actionInProgress, parameterTask == nil, let parameterService else { return }
        let current = epoch, request = UUID(), lens = controlState.rawFields["lens"]
        parameterRequest = request
        parameterTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await parameterService.load(lens: lens)
                try self.check(current)
                guard self.parameterRequest == request else { return }
                self.parameterValues.merge(snapshot.values) { _, new in new }
                self.parameterOptions = snapshot.options
                let warning = snapshot.warnings.joined(separator: "；")
                if !warning.isEmpty, warning != self.lastParameterWarning {
                    for message in snapshot.warnings { self.diagnostics.append(message) }
                }
                self.lastParameterWarning = warning
            } catch {
                guard self.isCurrent(current), !Task.isCancelled, self.parameterRequest == request else { return }
                let warning = "读取曝光参数：\(error.localizedDescription)"
                if warning != self.lastParameterWarning { self.diagnostics.append(warning) }
                self.lastParameterWarning = warning
            }
            guard self.parameterRequest == request else { return }
            self.parameterTask = nil
        }
    }

    func updateParameter(_ parameter: ExposureParameter, option: CameraParameterOption) {
        guard canCapture, let controls else { return }
        guard let allowed = parameterOptions[parameter]?.first(where: { $0.id == option.id && $0.rawValue == option.rawValue }), allowed.enabled else {
            notice = "该参数由相机控制，或当前模式没有提供可调范围。"
            return
        }
        parameterTask?.cancel(); parameterTask = nil; parameterRequest = UUID()
        actionInProgress = true; policy.captureStarted()
        let current = epoch
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await controls.setParameter(parameter, rawValue: allowed.rawValue)
                try self.check(current)
                self.parameterValues[parameter] = allowed.label
                self.notice = "\(parameter.label)已由相机确认。"
            } catch {
                guard self.isCurrent(current), !Task.isCancelled else { return }
                self.notice = error.localizedDescription
                self.diagnostics.append("\(parameter.label)设置：\(error.localizedDescription)")
            }
            guard self.isCurrent(current) else { return }
            self.actionInProgress = false; self.captureTask = nil
            self.policy.captureFinished(now: self.clock())
            if self.deferredRecovery { self.deferredRecovery = false; self.recover() }
            else { self.refreshParameters() }
        }
    }

    func focus(at point: CGPoint) {
        guard canCapture, let controls else { return }
        focusFeedbackTask?.cancel()
        let request = FocusRequest(point: point)
        focusRequest = request
        actionInProgress = true; policy.captureStarted()
        let current = epoch
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await controls.focus(at: point)
                try self.check(current)
                self.diagnostics.append("点按对焦：位置已请求，尚无合焦确认。")
            } catch {
                guard self.isCurrent(current), !Task.isCancelled else { return }
                self.focusRequest = nil
                self.notice = error.localizedDescription
            }
            guard self.isCurrent(current) else { return }
            self.actionInProgress = false; self.captureTask = nil
            self.policy.captureFinished(now: self.clock())
            self.focusFeedbackTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, self.isCurrent(current), self.focusRequest?.id == request.id else { return }
                self.focusRequest = nil
            }
            if self.deferredRecovery { self.deferredRecovery = false; self.recover() }
        }
    }

    private func startMonitor(_ current: UUID) {
        startDisplayClock(current)
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var lastHealth = self.clock()
            while self.isCurrent(current), self.controlReady, !Task.isCancelled {
                do { try await self.sleep(0.5); try self.check(current) }
                catch { return }
                if self.actionInProgress { continue }
                let now = self.clock()
                if now - lastHealth >= 2, !self.isCapturing, let client = self.client {
                    lastHealth = now
                    var healthy = false
                    do { try await self.sendSuccess(.state, via: client, current: current); healthy = true }
                    catch {
                        guard self.isCurrent(current), !Task.isCancelled else { return }
                        self.lastError = error.localizedDescription
                        self.diagnostics.append("健康检查：\(error.localizedDescription)")
                    }
                    if self.actionInProgress || self.isBrowsing { continue }
                    if self.policy.recordHealth(succeeded: healthy) == .reconnect {
                        self.recover(); return
                    }
                    if healthy { self.refreshParameters() }
                }
                switch self.policy.evaluate(now: self.clock()) {
                case .restartStream:
                    guard let client = self.client else { return }
                    self.streamRestarting = true
                    self.diagnostics.append("控制正常但画面停滞，尝试恢复画面")
                    do {
                        try await self.sendSuccess(.startStream(port: self.settings.endpoint().port), via: client, current: current)
                        self.streamRestarting = false
                        self.policy.streamRestarted(now: self.clock())
                    } catch {
                        guard self.isCurrent(current) else { return }
                        self.streamRestarting = false
                        self.recover(); return
                    }
                case .reconnect: self.recover(); return
                case .none, .giveUp: break
                }
            }
        }
    }

    private func recover() {
        guard wantsConnection, foreground else { return }
        if actionInProgress {
            deferredRecovery = true
            return
        }
        epoch = UUID()
        monitorTask?.cancel()
        monitorTask = nil
        captureTask?.cancel()
        captureTask = nil
        closeTransport()
        launchConnection(delayed: true)
    }

    private func startDisplayClock(_ current: UUID) {
        displayClockTask?.cancel()
        displayClockTask = Task { [weak self] in
            guard let self else { return }
            while self.isCurrent(current), self.controlReady, !Task.isCancelled {
                do { try await self.sleep(0.25); try self.check(current) }
                catch { return }
                if let last = self.lastFrameTime {
                    let age = max(0, self.clock() - last)
                    self.lastFrameAge = age
                    self.frameIsStale = age >= 2
                }
            }
        }
    }

    private func received(_ image: UIImage, generation: UUID) {
        guard generation == self.generation, controlReady, foreground, wantsConnection else { return }
        let now = clock()
        if let cg = image.cgImage, self.image?.cgImage?.width != cg.width || self.image?.cgImage?.height != cg.height {
            diagnostics.append("实时监看源画面：\(cg.width)×\(cg.height)；直接解码，未再次压缩或缩小。")
        }
        self.image = image
        lastFrameTime = now
        lastFrameAge = 0
        frameIsStale = false
        phase = .monitoring
        policy.frameReceived(now: now)
        policy.connectionSucceeded()
        fpsFrames += 1
        if now - fpsStart >= 1 {
            frameRate = Double(fpsFrames) / (now - fpsStart)
            fpsFrames = 0
            fpsStart = now
        }
    }

    private func isCurrent(_ current: UUID) -> Bool { epoch == current && wantsConnection && foreground }
    private func check(_ current: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(current) else { throw CancellationError() }
    }

    private func closeTransport() {
        controlReady = false
        streamRestarting = false
        displayClockTask?.cancel()
        displayClockTask = nil
        receiver?.stop()
        receiver = nil
        client = nil
        controls = nil
        parameterTask?.cancel(); parameterTask = nil; parameterRequest = UUID()
        parameterService = nil
        parameterOptions = [:]; parameterValues = [:]; lastParameterWarning = nil
        focusFeedbackTask?.cancel(); focusFeedbackTask = nil; focusRequest = nil
        playbackKeepaliveTask?.cancel(); playbackKeepaliveTask = nil
        controlState = CameraControlState(response: LumixResponse(status: .success))
        recordingStartedUptime = nil
        generation = UUID()
        decoder.reset(generation: generation)
        image = nil
        frameIsStale = false
        lastFrameAge = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stopOldStream(_ previous: (any CommandSending)?, controls previousControls: CameraControlService?) {
        guard let previous else { return }
        let stoppedEpoch = epoch
        cleanupTask = Task { [weak self] in
            guard let self, self.epoch == stoppedEpoch else { return }
            if let previousControls { _ = try? await previousControls.sendExclusive(.stopStream) }
            else { _ = try? await previous.send(.stopStream) }
        }
    }

    private func cancelTasksAndTransport() {
        epoch = UUID()
        connectionTask?.cancel(); connectionTask = nil
        monitorTask?.cancel(); monitorTask = nil
        captureTask?.cancel(); captureTask = nil
        playbackTask?.cancel(); playbackTask = nil
        playbackRestoreTask?.cancel(); playbackRestoreTask = nil
        isBrowsing = false
        playbackID = nil
        isCapturing = false
        actionInProgress = false
        deferredRecovery = false
        closeTransport()
    }
}
