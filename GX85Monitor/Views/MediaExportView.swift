import SwiftUI

struct MediaExportView: View {
    @ObservedObject var model: MediaExportCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isRunning {
                Text(model.currentItem?.title ?? "下载原文件").lineLimit(2)
                if let progress = model.progress { ProgressView(value: progress) }
                else { ProgressView() }
                Text("已处理 \(model.completedCount) / \(model.totalCount)").font(.caption).foregroundStyle(.secondary)
                Button("取消下载", role: .cancel) { model.cancel() }
            } else {
                Text("已下载 \(model.prepared.count) 项原文件").font(.headline)
                Text("下载完成后仍需选择保存位置。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.failures) { failure in
                Text("\(failure.item.title)：\(failure.message)").font(.footnote).foregroundStyle(.yellow)
            }
        }.padding(16)
    }
}
