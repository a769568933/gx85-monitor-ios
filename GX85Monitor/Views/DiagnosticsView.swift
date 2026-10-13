import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var session: CameraSession
    @ObservedObject var log: DiagnosticsLog

    var body: some View {
        List {
            Section("当前状态") {
                LabeledContent("连接", value: session.phase.title)
                LabeledContent("有效帧率", value: String(format: "%.1f fps", session.frameIsStale ? 0 : session.frameRate))
                LabeledContent("最近画面", value: session.lastFrameAge.map { String(format: "%.1f 秒前", $0) } ?? "尚未收到")
                LabeledContent("收到数据包", value: String(session.packets))
                LabeledContent("丢弃不完整帧", value: String(session.droppedFrames))
                LabeledContent("无法解码帧", value: String(session.invalidImages))
                LabeledContent("处理过载丢包", value: String(session.droppedPackets))
                LabeledContent("恢复尝试", value: String(session.recoveryCount))
            }
            Section {
                ShareLink(item: log.text) { Label("导出诊断记录", systemImage: "square.and.arrow.up") }
            }
            Section("最近记录") {
                ForEach(Array(log.entries.enumerated()), id: \.offset) { _, entry in
                    Text(entry).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("连接诊断").navigationBarTitleDisplayMode(.inline)
    }
}
