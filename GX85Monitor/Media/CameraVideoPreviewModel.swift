import Foundation
import Combine
import AVFoundation
import GX85Core

@MainActor
final class CameraVideoPreviewModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private let downloader: any MediaDownloading
    private var file: URL?
    private var generation = UUID()
    private var downloadTask: Task<URL, Error>?
    init(downloader: any MediaDownloading) { self.downloader = downloader }
    func load(_ resource: CameraMediaResource) async {
        await close()
        guard resource.role == .original, resource.mimeType == "video/mp4" else {
            errorMessage = "此格式无法直接播放，可尝试保存到文件。"; return
        }
        let current = generation
        isLoading = true; errorMessage = nil
        let downloader = downloader
        let task = Task { try await downloader.download(resource) { _ in } }
        downloadTask = task
        do {
            let url = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled, generation == current else { await downloader.discard(url); return }
            guard url.isFileURL else { await downloader.discard(url); throw MediaDownloadError.invalidResponse }
            file = url; player = AVPlayer(url: url)
        } catch {
            guard !Task.isCancelled, generation == current else { return }
            errorMessage = error.localizedDescription
        }
        if generation == current { isLoading = false; downloadTask = nil }
    }
    func close() async {
        generation = UUID(); downloadTask?.cancel(); downloadTask = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; isLoading = false
        if let file { self.file = nil; await downloader.discard(file) }
    }
}
