import SwiftUI
import GX85Core

struct SettingsView: View {
    @ObservedObject var session: CameraSession
    @ObservedObject var settings: CameraSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("相机连接") {
                    TextField("相机地址", text: $settings.host)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("相机 IPv4 地址")
                    TextField("接收端口", text: $settings.portText).keyboardType(.numberPad).accessibilityLabel("监看接收端口")
                    if session.isActive { Text("修改连接设置前，请先断开相机。").font(.footnote).foregroundStyle(.secondary) }
                }.disabled(session.isActive)
                Section {
                    Button(session.isActive ? "断开相机" : "连接相机") {
                        if session.isActive { session.disconnect() }
                        else { session.connect(); dismiss() }
                    }
                    Text("请先在 iPhone 设置中加入 GX85 的 Wi-Fi，并在相机上允许连接。").font(.footnote).foregroundStyle(.secondary)
                }
                if let notice = session.notice { Section("最近操作结果") { Text(notice) } }
                if let error = session.lastError { Section("连接提示") { Text(error).foregroundStyle(.yellow) } }
                Section("实时监看画质") {
                    if let pixels = session.image?.cgImage { Text("相机输出：\(pixels.width) × \(pixels.height)") }
                    else { Text("收到实时画面后显示分辨率") }
                    Text("连接及返回相册后，尝试使用相机允许的 VGA（640 × 480）。这里显示实际源像素；放大到 iPhone 屏幕不会增加细节，清晰度受相机无线输出限制。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink("连接诊断") { DiagnosticsView(session: session, log: session.diagnostics) }
                    DisclosureGroup("高级连接设置") {
                        TextField("相机连接标识（自动识别）", text: $settings.accessID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(session.isActive)
                        Text("通常自动填写。如果相机拒绝连接，可按安装说明用 Windows 读取相机标识后填入。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("关于") {
                    Text("GX85 Monitor 0.2.5（build 7）")
                    Text("照片和视频先保存在相机存储卡，可在相机相册选择原文件导出到 iPhone。无线画面的清晰度与流畅度由相机输出和当前网络共同决定。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
