import SwiftUI

struct CameraView: View {
    @ObservedObject var session: CameraSession
    @State private var fullscreen = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if fullscreen {
                    preview
                        .overlay(alignment: .topTrailing) {
                            iconButton("arrow.down.right.and.arrow.up.left", label: "退出全屏监看") { fullscreen = false }
                                .background(.black.opacity(0.55), in: Circle()).padding(8)
                        }
                } else if landscape {
                    HStack(spacing: 0) {
                        preview
                        landscapeControls.frame(width: 96)
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            status
                            Spacer()
                            iconButton("gearshape", label: "设置") { showSettings = true }
                        }
                        .padding(.leading, 18).padding(.trailing, 6).frame(height: 44)
                        preview.frame(maxHeight: .infinity)
                        portraitControls.frame(height: 128)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = session.notice {
                HStack(alignment: .center, spacing: 8) {
                    Text(notice).font(.footnote).foregroundStyle(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    iconButton("xmark", label: "关闭拍照提示", action: session.clearNotice)
                }
                .padding(.leading, 12).padding(.trailing, 4)
                .background(.black)
                .accessibilityElement(children: .contain)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView(session: session, settings: session.settings) }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image = session.image {
                    let rect = PreviewLayout.fit(imageSize: image.size, in: geometry.size)
                    Image(uiImage: image).resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityLabel("GX85 实时取景画面")
                    if session.frameIsStale {
                        Label("画面已暂停", systemImage: "pause.circle")
                            .font(.callout.weight(.medium)).foregroundStyle(.yellow)
                            .padding(12).background(.black.opacity(0.75), in: Capsule())
                    }
                } else {
                    ConnectionGuideView(phase: session.phase, error: session.lastError, connect: session.connect)
                }
            }
        }
    }

    private var status: some View {
        HStack(spacing: 7) {
            Circle().fill(session.phase == .monitoring && !session.frameIsStale ? Color.green : Color.yellow).frame(width: 6, height: 6)
            Text(session.frameIsStale ? "画面已暂停" : session.phase.title)
                .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
    }

    private var portraitControls: some View {
        VStack(spacing: 8) {
            Text("拍照").font(.caption.weight(.semibold)).foregroundStyle(.yellow)
            HStack {
                connectionButton.frame(maxWidth: .infinity)
                ShutterButton(enabled: session.canCapture, busy: session.isCapturing, action: session.capture)
                iconButton("arrow.up.left.and.arrow.down.right", label: "全屏监看") { fullscreen = true }
                    .frame(maxWidth: .infinity)
            }
            Text("GX85").font(.caption2).foregroundStyle(.white.opacity(0.35))
        }
    }

    private var landscapeControls: some View {
        VStack(spacing: 4) {
            iconButton("gearshape", label: "设置") { showSettings = true }
            Text(session.frameIsStale ? "画面已暂停" : session.phase.title)
                .font(.system(size: 10)).foregroundStyle(.yellow).lineLimit(2).multilineTextAlignment(.center)
            Spacer(minLength: 2)
            ShutterButton(enabled: session.canCapture, busy: session.isCapturing, action: session.capture)
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

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular)).foregroundStyle(.white)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}
