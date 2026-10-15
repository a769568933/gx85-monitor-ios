import SwiftUI
import GX85Core

struct CameraView: View {
    @ObservedObject var session: CameraSession
    @State private var fullscreen = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                preview.ignoresSafeArea()
                if fullscreen {
                    VStack {
                        HStack {
                            Spacer()
                            iconButton("arrow.down.right.and.arrow.up.left", label: "退出全屏监看") { fullscreen = false }
                                .background(.black.opacity(0.55), in: Circle()).padding(8)
                        }
                        Spacer()
                    }
                } else if landscape {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            status
                            CameraParameterBar(session: session).frame(maxWidth: 300)
                            Spacer()
                        }.padding(12)
                        Spacer(minLength: 0)
                        landscapeControls.frame(width: 104).background(.black.opacity(0.5))
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            status
                            Spacer()
                            iconButton("gearshape", label: "设置") { showSettings = true }
                        }
                        .padding(.leading, 18).padding(.trailing, 6).frame(height: 44)
                        CameraParameterBar(session: session).padding(.horizontal, 12)
                        Spacer(minLength: 0)
                        portraitControls.frame(height: 160).background(.black.opacity(0.55))
                    }
                }
                if let message = session.notice {
                    VStack {
                        Spacer(minLength: 0)
                        NoticeOverlay(message: message, onDismiss: session.clearNotice)
                            .frame(maxWidth: 560)
                            .padding(.horizontal, landscape ? 108 : 12)
                            .padding(.bottom, fullscreen ? 12 : (landscape ? 12 : 168))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView(session: session, settings: session.settings) }
    }

    private var preview: some View {
        GeometryReader { geometry in
            let rect = PreviewLayout.fit(imageSize: session.image?.size ?? .zero, in: geometry.size)
            ZStack {
                Color.black
                if let image = session.image {
                    Image(uiImage: image).resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityLabel("GX85 实时取景画面")
                        .accessibilityIdentifier("livePreview")
                    if let request = session.focusRequest {
                        RoundedRectangle(cornerRadius: 6).stroke(.yellow, lineWidth: 2)
                            .frame(width: 64, height: 64)
                            .position(x: rect.minX + request.point.x * rect.width, y: rect.minY + request.point.y * rect.height)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("对焦请求位置，尚未确认合焦")
                            .accessibilityIdentifier("focusIndicator")
                            .allowsHitTesting(false)
                    }
                    if session.frameIsStale {
                        Label("画面已暂停", systemImage: "pause.circle")
                            .font(.callout.weight(.medium)).foregroundStyle(.yellow)
                            .padding(12).background(.black.opacity(0.75), in: Capsule())
                    }
                } else {
                    ConnectionGuideView(phase: session.phase, error: session.lastError, connect: session.connect)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                if let point = PreviewLayout.focusPoint(at: value.location, in: rect) { session.focus(at: point) }
            })
        }
    }

    private var status: some View {
        HStack(spacing: 7) {
            Circle().fill(session.phase == .monitoring && !session.frameIsStale ? Color.green : Color.yellow).frame(width: 6, height: 6)
            Text(session.controlState.recordingState == .recording ? "正在录像" : (session.selectedShootingMode == .video && session.controlState.recordingState == .unknown ? "录像状态未确认" : (session.frameIsStale ? "画面已暂停" : session.phase.title)))
                .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
    }

    private var portraitControls: some View {
        VStack(spacing: 8) {
            modePicker
            HStack {
                connectionButton.frame(maxWidth: .infinity)
                shutter
                iconButton("arrow.up.left.and.arrow.down.right", label: "全屏监看") { fullscreen = true }
                    .frame(maxWidth: .infinity)
            }
            Text("GX85").font(.caption2).foregroundStyle(.white.opacity(0.35))
        }
    }

    private var landscapeControls: some View {
        VStack(spacing: 4) {
            iconButton("gearshape", label: "设置") { showSettings = true }
            modePicker
            Spacer(minLength: 2)
            shutter
            Spacer(minLength: 2)
            HStack(spacing: 0) {
                connectionButton
                iconButton("arrow.up.left.and.arrow.down.right", label: "全屏监看") { fullscreen = true }
            }
        }
        .padding(.vertical, 4)
    }

    private var connectionButton: some View {
        iconButton(session.isActive ? "wifi.slash" : "wifi", label: session.isActive ? "断开相机" : "连接相机") {
            if session.isActive { session.disconnect() } else { session.connect() }
        }
    }

    private var shutter: some View {
        ShutterButton(mode: session.selectedShootingMode, recordingState: session.controlState.recordingState,
                      enabled: session.canCapture, busy: session.actionInProgress, action: session.performPrimaryAction)
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            modeButton("照片", mode: .photo)
            modeButton("视频", mode: .video)
        }
        .disabled(session.actionInProgress || session.controlState.recordingState == .recording)
    }

    private func modeButton(_ title: String, mode: CameraShootingMode) -> some View {
        Button { session.selectShootingMode(mode) } label: {
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(session.selectedShootingMode == mode ? .yellow : .white)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(session.selectedShootingMode == mode ? .isSelected : [])
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular)).foregroundStyle(.white)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}
