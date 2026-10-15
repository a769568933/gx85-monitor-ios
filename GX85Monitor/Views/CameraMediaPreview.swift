import SwiftUI
import UIKit
import GX85Core

struct CameraMediaPreview: View {
    let item: CameraMediaItem
    let client: CameraMediaClient
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    if let image { Image(uiImage: image).resizable().scaledToFit() }
                    else if loading { ProgressView("读取预览图").tint(.white) }
                    else { Image(systemName: item.kind == .video ? "video" : "photo").font(.system(size: 56)).foregroundStyle(.secondary) }
                }
                Text(item.kind == .video ? "视频预览图 · 原片下载后可播放" : "相机预览图").font(.caption).foregroundStyle(.secondary)
                if item.originalResource == nil { Text("相机未提供此格式的无线原文件").font(.caption).foregroundStyle(.yellow) }
                if let error { Text(error).font(.footnote).foregroundStyle(.yellow).padding(.horizontal) }
            }
            .padding(.bottom, 12).background(.black)
            .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task(id: item.id) {
            guard let resource = item.imagePreviewResource else { loading = false; return }
            do {
                let data = try await client.imageData(resource, maximumSize: 4 * 1024 * 1024)
                try Task.checkCancellation()
                let decoded = await Task.detached(priority: .utility) { CameraImageDecode.image(data: data, maximumPixelSize: 2048) }.value
                try Task.checkCancellation()
                image = decoded
                if decoded == nil { error = "无法显示相机提供的预览图。" }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
