import SwiftUI
import GX85Core

struct ShutterButton: View {
    let mode: CameraShootingMode
    let recordingState: CameraRecordingState
    let enabled: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(enabled || busy ? 1 : 0.35), lineWidth: 4)
                if mode == .video {
                    if recordingState == .recording {
                        RoundedRectangle(cornerRadius: 5).fill(.red).padding(23)
                    } else {
                        Circle().fill(.red.opacity(enabled || busy ? 1 : 0.35)).padding(7)
                    }
                } else { Circle().fill(.white.opacity(enabled || busy ? 1 : 0.25)).padding(7) }
                if busy { ProgressView().tint(mode == .video ? .white : .black) }
            }
            .frame(width: 76, height: 76)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(busy ? "等待相机确认" : (mode == .video ? (recordingState == .recording ? "停止录像" : "开始录像") : "拍照"))
        .accessibilityIdentifier("primaryShutter")
        .accessibilityHint("媒体保存在 GX85 存储卡")
    }
}
