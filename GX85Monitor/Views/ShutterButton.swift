import SwiftUI

struct ShutterButton: View {
    let enabled: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(enabled || busy ? 1 : 0.35), lineWidth: 4)
                Circle().fill(.white.opacity(enabled || busy ? 1 : 0.25)).padding(7)
                if busy { ProgressView().tint(.black) }
            }
            .frame(width: 76, height: 76)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(busy ? "正在发送拍照指令" : "拍照")
        .accessibilityHint("照片保存在 GX85 存储卡")
    }
}
