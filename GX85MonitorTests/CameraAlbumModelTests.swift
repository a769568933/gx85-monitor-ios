import Foundation
import XCTest
import GX85Core
@testable import GX85Monitor

@MainActor
final class CameraAlbumModelTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Album transition did not arrive")
    }
    private func item(_ id: String) -> CameraMediaItem {
        CameraMediaItem(id: id, title: id + ".JPG", kind: .photo, resources: [CameraMediaResource(url: URL(string: "http://192.168.54.1/\(id).JPG")!, mimeType: "image/jpeg", role: .original)])
    }

    func testDuplicatePageStopsRatherThanLoadingItForever() async {
        let first = CameraMediaPage(items: [item("1")], numberReturned: 1, totalMatches: 3, nextStartingIndex: 1)
        let duplicate = CameraMediaPage(items: [item("1")], numberReturned: 1, totalMatches: 3, nextStartingIndex: 2)
        let client = AlbumPages([first, duplicate])
        let album = CameraAlbumModel(client: client)
        album.loadNextPage()
        await wait { album.items.count == 1 }
        album.loadNextPage()
        await wait { album.errorMessage != nil }
        album.loadNextPage()
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(album.items.count, 1)
        await album.close()
    }

    func testChangedTotalRequiresReloadWithoutMixingDatasets() async {
        let client = AlbumPages([
            CameraMediaPage(items: [item("1")], numberReturned: 1, totalMatches: 3, nextStartingIndex: 1),
            CameraMediaPage(items: [item("2")], numberReturned: 1, totalMatches: 4, nextStartingIndex: 2)
        ])
        let album = CameraAlbumModel(client: client)
        album.loadNextPage(); await wait { album.items.count == 1 }
        album.loadNextPage(); await wait { album.errorMessage != nil }
        XCTAssertEqual(album.items.map(\.id), ["1"])
        await album.close()
    }

    func testFailedOlderPageCanRetrySameOffsetWithoutClearingLatestPhotos() async {
        let latest = CameraMediaPage(items: [item("newest")], numberReturned: 1, totalMatches: 2, nextStartingIndex: 1)
        let older = CameraMediaPage(items: [item("older")], numberReturned: 1, totalMatches: 2, nextStartingIndex: nil)
        let client = RetryAlbumPages(first: latest, last: older)
        let album = CameraAlbumModel(client: client)
        album.loadNextPage(); await wait { !album.isLoading && album.items.count == 1 }
        album.loadNextPage(); await wait { !album.isLoading && album.errorMessage != nil }
        XCTAssertEqual(album.items.map(\.id), ["newest"])
        XCTAssertFalse(album.hasMore, "An error must stop automatic loading until a manual retry")
        album.loadNextPage(); await wait { !album.isLoading && album.items.count == 2 }
        XCTAssertEqual(album.items.map(\.id), ["newest", "older"])
        XCTAssertNil(album.errorMessage)
        let offsets = await client.offsets
        XCTAssertEqual(offsets, [0, 1, 1])
        await album.close()
    }

    func testLatePageAfterCloseCannotRepopulateAlbum() async {
        let page = CameraMediaPage(items: [item("late")], numberReturned: 1, totalMatches: 1, nextStartingIndex: nil)
        let client = AlbumPages([page], held: true)
        let album = CameraAlbumModel(client: client)
        album.loadNextPage()
        for _ in 0..<400 { let waiting = await client.waiting; if waiting { break }; await Task.yield() }
        let waiting = await client.waiting
        XCTAssertTrue(waiting)
        await album.close()
        await client.release()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(album.items.isEmpty)
        XCTAssertTrue(album.isClosed)
    }
}

private actor RetryAlbumPages: CameraMediaBrowsing {
    let first: CameraMediaPage, last: CameraMediaPage
    private(set) var offsets: [Int] = []
    init(first: CameraMediaPage, last: CameraMediaPage) { self.first = first; self.last = last }
    func browse(start: Int, count: Int, objectID: String) async throws -> CameraMediaPage {
        offsets.append(start)
        if offsets.count == 1 { return first }
        if offsets.count == 2 { throw CameraMediaError.malformedDirectory }
        return last
    }
}

private actor AlbumPages: CameraMediaBrowsing {
    private var pages: [CameraMediaPage]
    private var held: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    private(set) var waiting = false
    init(_ pages: [CameraMediaPage], held: Bool = false) { self.pages = pages; self.held = held }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func browse(start: Int, count: Int, objectID: String) async throws -> CameraMediaPage {
        calls += 1
        if held { waiting = true; await withCheckedContinuation { continuation = $0 } }
        guard !pages.isEmpty else { throw CameraMediaError.noProgress }
        return pages.removeFirst()
    }
}
