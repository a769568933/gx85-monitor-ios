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
    @Published private(set) var isSavingPhotos = false
    let downloader: any MediaDownloading
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var itemToken = UUID()
    private var activeConsumption: URL?
    private var pendingFiles: [PreparedMedia] = []

    init(downloader: any MediaDownloading) { self.downloader = downloader }
    func start(_ items: [CameraMediaItem]) {
        guard !isRunning, prepared.isEmpty, pendingFiles.isEmpty, activeConsumption == nil else { return }
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
        task?.cancel(); task = nil; isRunning = false; isSavingPhotos = false; currentItem = nil; progress = nil
        let files = prepared.filter { $0.fileURL != activeConsumption }; prepared = []
        let downloader = downloader
        Task { for file in files { await downloader.discard(file.fileURL) } }
    }

    func savePhotos(using writer: any PhotoLibraryWriting = PhotoLibraryWriter()) {
        guard !isRunning, !prepared.isEmpty, pendingFiles.isEmpty, activeConsumption == nil else { return }
        let files = prepared, current = UUID(); runID = current
        isRunning = true; isSavingPhotos = true; completedCount = 0; totalCount = files.count
        task = Task { [weak self] in
            guard let self else { return }
            for file in files {
                guard !Task.isCancelled, self.runID == current else { break }
                self.currentItem = file.item; self.activeConsumption = file.fileURL
                do {
                    try await writer.save(fileURL: file.fileURL, kind: file.item.kind)
                    guard !Task.isCancelled, self.runID == current else {
                        await self.downloader.discard(file.fileURL)
                        if self.activeConsumption == file.fileURL { self.activeConsumption = nil }
                        return
                    }
                    self.successfulIDs.insert(file.id)
                    self.prepared.removeAll { $0.id == file.id }
                    self.failures.removeAll { $0.id == file.id }
                    await self.downloader.discard(file.fileURL)
                } catch {
                    guard !Task.isCancelled, self.runID == current else {
                        await self.downloader.discard(file.fileURL)
                        if self.activeConsumption == file.fileURL { self.activeConsumption = nil }
                        return
                    }
                    self.failures.removeAll { $0.id == file.id }
                    self.failures.append(MediaExportFailure(item: file.item, message: error.localizedDescription))
                }
                if self.activeConsumption == file.fileURL { self.activeConsumption = nil }
                guard self.runID == current else { return }
                self.completedCount += 1
            }
            guard self.runID == current else { return }
            self.isRunning = false; self.isSavingPhotos = false; self.currentItem = nil; self.task = nil
        }
    }

    func beginFilesExport() -> [URL] {
        guard !isRunning, pendingFiles.isEmpty, activeConsumption == nil else { return [] }
        pendingFiles = prepared; prepared = []
        return pendingFiles.map(\.fileURL)
    }
    func completeFilesExport(success: Bool) async {
        let files = pendingFiles; pendingFiles = []
        if success {
            successfulIDs.formUnion(files.map(\.id))
            let saved = Set(files.map(\.id)); failures.removeAll { saved.contains($0.id) }
        }
        for file in files { await downloader.discard(file.fileURL) }
    }
}
