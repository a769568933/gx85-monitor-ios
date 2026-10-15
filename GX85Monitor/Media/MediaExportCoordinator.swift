import Foundation
import Combine
import GX85Core

struct PreparedMedia: Identifiable {
    let item: CameraMediaItem
    let fileURL: URL
    var id: String { item.id }
}
struct MediaExportFailure: Identifiable {
    let item: CameraMediaItem
    let message: String
    var id: String { item.id }
}

@MainActor
final class MediaExportCoordinator: ObservableObject {
    @Published private(set) var prepared: [PreparedMedia] = []
    @Published private(set) var failures: [MediaExportFailure] = []
    @Published private(set) var successfulIDs = Set<String>()
    @Published private(set) var currentItem: CameraMediaItem?
    @Published private(set) var progress: Double?
    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    let downloader: any MediaDownloading
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var itemToken = UUID()

    init(downloader: any MediaDownloading) { self.downloader = downloader }
    func start(_ items: [CameraMediaItem]) {
        guard !isRunning, prepared.isEmpty else { return }
        runID = UUID(); let current = runID
        failures = []; successfulIDs = []; completedCount = 0; totalCount = items.count
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            for item in items {
                guard !Task.isCancelled, self.runID == current else { break }
                self.currentItem = item; self.progress = nil
                let token = UUID(); self.itemToken = token
                let slot = LatestValueSlot<Double?>()
                do {
                    guard let resource = item.originalResource else { throw CameraMediaError.originalUnavailable }
                    let file = try await self.downloader.download(resource) { [weak self] value in
                        if slot.offer(value) {
                            Task { @MainActor [weak self] in
                                guard let value = slot.take(), let self, self.runID == current, self.itemToken == token else { return }
                                self.progress = value
                            }
                        }
                    }
                    guard !Task.isCancelled, self.runID == current else { await self.downloader.discard(file); break }
                    self.prepared.append(PreparedMedia(item: item, fileURL: file))
                } catch {
                    guard !Task.isCancelled, self.runID == current else { break }
                    self.failures.append(MediaExportFailure(item: item, message: error.localizedDescription))
                }
                self.completedCount += 1
            }
            guard self.runID == current else { return }
            self.isRunning = false; self.currentItem = nil; self.progress = nil; self.task = nil
        }
    }
    func cancel() {
        runID = UUID(); itemToken = UUID()
        task?.cancel(); task = nil; isRunning = false; currentItem = nil; progress = nil
        let files = prepared; prepared = []
        let downloader = downloader
        Task { for file in files { await downloader.discard(file.fileURL) } }
    }
}
