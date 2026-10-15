import SwiftUI

struct ConnectionGuideView: View {
    let phase: CameraSession.Phase
    let error: String?
    let notice: String?
    let clearNotice: () -> Void
    let connect: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "camera.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.6))
                Text(phase == .disconnected || phase == .failed ? "连接你的 GX85" : phase.title)
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                if phase == .disconnected || phase == .failed {
                    step("1", "相机开启「遥控拍摄与查看」")
                    step("2", "在 iPhone 设置中加入相机 Wi-Fi")
                    step("3", "返回这里连接，并允许本地网络访问")
                    Button("连接相机", action: connect)
                        .font(.headline).foregroundStyle(.black)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(.yellow, in: Capsule())
                } else {
                    ProgressView().tint(.yellow)
                    Text(phase == .waitingApproval ? "请在相机屏幕上选择「是」。" : "保持相机开启，确认手机仍在相机 Wi-Fi。")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true)
                }
                if let notice { NoticeOverlay(message: notice, onDismiss: clearNotice) }
            }
            .frame(maxWidth: 330, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                .frame(width: 24, height: 24).background(.white.opacity(0.12), in: Circle())
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
