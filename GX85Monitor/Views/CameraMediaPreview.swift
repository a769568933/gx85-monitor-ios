import SwiftUI
import UIKit
import GX85Core
import AVKit

struct CameraMediaPreview: View {
    let item: CameraMediaItem
    let client: CameraMediaClient
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = true
    @State private var attempt = 0
    @StateObject private var images: CameraThumbnailLoader
    @StateObject private var movie: CameraVideoPreviewModel
    @Environment(\.scenePhase) private var scenePhase

    init(item: CameraMediaItem, client: CameraMediaClient) {
        self.item = item; self.client = client
        _images = StateObject(wrappedValue: CameraThumbnailLoader(client: client))
        _movie = StateObject(wrappedValue: CameraVideoPreviewModel(downloader: MediaDownloadService(cameraHost: client.cameraHost)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    if let player = movie.player { VideoPlayer(player: player) }
                    else if let image { Image(uiImage: image).resizable().interpolation(.high).scaledToFit().accessibilityIdentifier("media-preview-image") }
                    else if loading { ProgressView("读取预览图").tint(.white) }
                    else { Image(systemName: item.kind == .video ? "video" : "photo").font(.system(size: 56)).foregroundStyle(.secondary) }
                }
                Text(item.kind == .video ? "视频预览图 · 原片下载后可播放" : "相机预览图").font(.caption).foregroundStyle(.secondary)
                if item.kind == .video, let original = item.originalResource {
                    if movie.isLoading { ProgressView("正在下载视频原文件"); Button("取消") { Task { await movie.close() } } }
                    else if movie.player == nil { Button("下载原片并播放") { Task { await movie.load(original) } } }
                }
                if let message = movie.errorMessage { Text(message).font(.footnote).foregroundStyle(.yellow) }
                if item.originalResource == nil { Text("相机未提供此格式的无线原文件").font(.caption).foregroundStyle(.yellow) }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.yellow).padding(.horizontal)
                    Button("重试预览") { attempt += 1 }.frame(minHeight: 44)
                }
            }
            .padding(.bottom, 12).background(.black)
            .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onDisappear { Task { await movie.close() } }
        .onChange(of: scenePhase) { if $0 == .background { Task { await movie.close() } } }
        .task(id: "\(item.id)-\(attempt)") {
            loading = true; error = nil
            guard !item.imagePreviewCandidates.isEmpty else { loading = false; return }
            let decoded = await images.loadPreview(item)
            guard !Task.isCancelled else { return }
            image = decoded; loading = false
            if decoded == nil { error = "无法显示相机提供的预览图，请重试或查看连接诊断。" }
        }
    }
}
