import Foundation
import Combine
import GX85Core

@MainActor
final class CameraAlbumModel: ObservableObject {
    @Published private(set) var items: [CameraMediaItem] = []
    @Published private(set) var selection = Set<String>()
    @Published private(set) var isLoading = false
    @Published private(set) var isClosed = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var totalMatches: Int?
    @Published private(set) var path: [CameraMediaItem] = []
    @Published private(set) var generation = UUID()
    private let client: any CameraMediaBrowsing
    private let onClose: @MainActor (String?) async -> Void
    private var loadTask: Task<Void, Never>?
    private var nextIndex: Int? = 0
    private var updateID: String?
    private var paginationFailed = false

    init(client: any CameraMediaBrowsing, onClose: @escaping @MainActor (String?) async -> Void = { _ in }) {
        self.client = client; self.onClose = onClose
    }
    var hasMore: Bool { !isClosed && !paginationFailed && nextIndex != nil }
    var selectedItems: [CameraMediaItem] { items.filter { selection.contains($0.id) } }
    var folderTitle: String { path.last?.title ?? "相机相册" }

    func loadNextPage() {
        guard !isClosed, !isLoading, !paginationFailed, let start = nextIndex else { return }
        isLoading = true
        let current = generation, objectID = path.last?.id ?? "0"
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.client.browse(start: start, count: 40, objectID: objectID)
                try Task.checkCancellation()
                guard self.generation == current, !self.isClosed else { return }
                if let total = self.totalMatches, total != page.totalMatches { throw AlbumError.changed }
                if let previous = self.updateID, let current = page.updateID, previous != current { throw AlbumError.changed }
                let seen = Set(self.items.map(\.id))
                guard !page.items.contains(where: { seen.contains($0.id) }),
                      Set(page.items.map(\.id)).count == page.items.count else { throw AlbumError.changed }
                guard page.numberReturned == page.items.count,
                      page.nextStartingIndex.map({ $0 > start }) ?? true,
                      !(page.items.isEmpty && start < page.totalMatches) else { throw CameraMediaError.noProgress }
                self.items.append(contentsOf: page.items)
                self.totalMatches = page.totalMatches
                self.updateID = page.updateID
                self.nextIndex = page.nextStartingIndex
            } catch {
                guard self.generation == current, !self.isClosed, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.paginationFailed = true
                self.nextIndex = nil
            }
            guard self.generation == current, !self.isClosed else { return }
            self.isLoading = false; self.loadTask = nil
        }
    }

    func toggleSelection(_ item: CameraMediaItem) {
        guard !isClosed, !item.isContainer, items.contains(where: { $0.id == item.id }), item.originalResource != nil else {
            errorMessage = CameraMediaError.originalUnavailable.localizedDescription
            return
        }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }
    func enter(_ folder: CameraMediaItem) {
        guard !isClosed, folder.isContainer else { return }
        path.append(folder); reload()
    }
    func goBack() {
        guard !isClosed, !path.isEmpty else { return }
        path.removeLast(); reload()
    }
    func reload() {
        guard !isClosed else { return }
        loadTask?.cancel(); loadTask = nil; generation = UUID()
        items = []; selection = []; totalMatches = nil; updateID = nil
        nextIndex = 0; paginationFailed = false; errorMessage = nil; isLoading = false
        loadNextPage()
    }
    func close() async {
        guard !isClosed else { return }
        isClosed = true; generation = UUID(); loadTask?.cancel(); loadTask = nil
        isLoading = false; nextIndex = nil; selection = []; items = []
        await onClose(errorMessage)
    }
    private enum AlbumError: LocalizedError {
        case changed
        var errorDescription: String? { "相机内容已变化或返回重复页面，请重新载入相册。" }
    }
}
