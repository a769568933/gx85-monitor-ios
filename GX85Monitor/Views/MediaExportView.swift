import SwiftUI
import GX85Core

struct MediaExportView: View {
    @ObservedObject var model: MediaExportCoordinator
    var items: [CameraMediaItem] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var fileRequest: ExportFileRequest?
    @State private var started = false
    var body: some View {
        NavigationStack {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            if model.isRunning {
                Text(model.isSavingPhotos ? "保存到 iPhone 照片" : "下载相机原文件").font(.headline)
                Text(model.currentItem?.title ?? "下载原文件").lineLimit(2)
                if let progress = model.progress { ProgressView(value: progress) }
                else { ProgressView() }
                Text("已处理 \(model.completedCount) / \(model.totalCount)").font(.caption).foregroundStyle(.secondary)
                Button("取消", role: .cancel) { model.cancel() }
            } else {
                Text("已下载 \(model.prepared.count) 项原文件").font(.headline)
                if !model.prepared.isEmpty {
                    Text("选择保存位置；系统确认完成后才计为成功。").font(.caption).foregroundStyle(.secondary)
                    Button("保存到照片") { model.savePhotos() }.buttonStyle(.borderedProminent)
                    Button("保存到文件") {
                        let urls = model.beginFilesExport()
                        if !urls.isEmpty { fileRequest = ExportFileRequest(urls: urls) }
                    }.buttonStyle(.bordered)
                }
            }
            if !model.successfulIDs.isEmpty { Text("已成功保存 \(model.successfulIDs.count) 项").foregroundStyle(.green) }
            ForEach(model.failures) { failure in
                Text("\(failure.item.title)：\(failure.message)").font(.footnote).foregroundStyle(.yellow)
            }
        }.padding(16)
        }
        .navigationTitle("导出原文件").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { model.cancel(); dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task { if !started { started = true; model.start(items) } }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { phase in if phase == .background { model.cancel(); fileRequest = nil } }
        .sheet(item: $fileRequest, onDismiss: { Task { await model.completeFilesExport(success: false) } }) { request in
            FileExportSheet(urls: request.urls) { success in
                Task { await model.completeFilesExport(success: success); fileRequest = nil }
            }
        }
    }
}
private struct ExportFileRequest: Identifiable { let id = UUID(); let urls: [URL] }
