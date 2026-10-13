import Foundation
import Combine
import UIKit
import GX85Core

@MainActor
final class CameraSession: ObservableObject {
    enum Phase: Equatable {
        case disconnected, connecting, waitingApproval, ready, monitoring, recovering, failed
        var title: String {
            switch self {
            case .disconnected: return "未连接"
            case .connecting: return "正在连接"
            case .waitingApproval: return "请在相机上允许连接"
            case .ready: return "等待画面"
            case .monitoring: return "监看中"
            case .recovering: return "正在恢复连接"
            case .failed: return "连接未成功"
            }
        }
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var image: UIImage?
    @Published private(set) var isCapturing = false
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
    private let makeReceiver: () -> any LiveViewReceiving
    private let clock: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var client: (any CommandSending)?
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
         }) {
        self.settings = settings
        self.clock = clock
        self.sleep = sleep
        self.makeReceiver = makeReceiver
        self.makeClient = makeClient
    }

    var canCapture: Bool { controlReady && foreground && wantsConnection && !isCapturing && !streamRestarting }
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
        cancelTasksAndTransport()
        phase = .disconnected
        image = nil
        frameIsStale = false
        lastFrameAge = nil
        notice = nil
        diagnostics.append("已主动断开")
        // The old client belongs only to this session. It never operates a later connection.
        stopOldStream(previousClient)
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if !value {
            let previousClient = client
            cancelTasksAndTransport()
            phase = .disconnected
            image = nil
            diagnostics.append("进入后台，停止监看")
            stopOldStream(previousClient)
        } else if wantsConnection {
            policy = SessionPolicy()
            diagnostics.append("返回前台，重新连接")
            launchConnection(delayed: false)
        }
    }

    func clearNotice() { notice = nil }

    func capture() {
        guard canCapture, let client else { return }
        isCapturing = true
        notice = nil
        policy.captureStarted()
        let current = epoch
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.send(.capture)
                try self.check(current)
                guard response.status == .success else { throw CommandError.waitingApproval }
                self.notice = "相机已接受拍照指令，照片保存在相机中。"
                self.diagnostics.append("快门：相机已接受指令")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                guard self.isCurrent(current) else { return }
                if case CommandError.cameraRejected(let code) = error {
                    self.notice = "相机未接受拍照：\(code)。"
                } else {
                    self.notice = "拍摄结果未知，请检查相机。为避免重复拍摄，未自动重试。"
                }
                self.diagnostics.append("快门：\(error.localizedDescription)")
            }
            guard self.isCurrent(current) else { return }
            self.isCapturing = false
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
        try await sendSuccess(.recordMode, via: commandClient, current: current)
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
    }

    private func sendSuccess(_ command: LumixCommand, via client: any CommandSending, current: UUID) async throws {
        let response = try await client.send(command)
        try check(current)
        guard response.status == .success else { throw CommandError.waitingApproval }
    }

    private func startMonitor(_ current: UUID) {
        startDisplayClock(current)
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var lastHealth = self.clock()
            while self.isCurrent(current), self.controlReady, !Task.isCancelled {
                do { try await self.sleep(0.5); try self.check(current) }
                catch { return }
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
                    if self.policy.recordHealth(succeeded: healthy) == .reconnect {
                        self.recover(); return
                    }
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
        if isCapturing {
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
        generation = UUID()
        decoder.reset(generation: generation)
        image = nil
        frameIsStale = false
        lastFrameAge = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stopOldStream(_ previous: (any CommandSending)?) {
        guard let previous else { return }
        let stoppedEpoch = epoch
        cleanupTask = Task { [weak self] in
            guard let self, self.epoch == stoppedEpoch else { return }
            _ = try? await previous.send(.stopStream)
        }
    }

    private func cancelTasksAndTransport() {
        epoch = UUID()
        connectionTask?.cancel(); connectionTask = nil
        monitorTask?.cancel(); monitorTask = nil
        captureTask?.cancel(); captureTask = nil
        isCapturing = false
        deferredRecovery = false
        closeTransport()
    }
}
