import Foundation
import XCTest
import AVFoundation
import GX85Core
@testable import GX85Monitor

@MainActor
final class MediaExportCoordinatorTests: XCTestCase {
    func testMoviePlayerUsesDownloadedFileAndReleasesItOnClose() async throws {
        let downloader = FakeMediaDownloader()
        let preview = CameraVideoPreviewModel(downloader: downloader)
        let resource = CameraMediaResource(url: URL(string: "http://192.168.54.1/movie.MP4")!, mimeType: "video/mp4", role: .original)
        await preview.load(resource)
        let asset = try XCTUnwrap(preview.player?.currentItem?.asset as? AVURLAsset)
        XCTAssertTrue(asset.url.isFileURL, "AVPlayer must never fetch camera redirects itself")
        await preview.close()
        XCTAssertNil(preview.player)
        let discarded = await downloader.discarded
        XCTAssertEqual(discarded, [asset.url])
    }
    private func item(_ id: String, original: Bool = true) -> CameraMediaItem {
        CameraMediaItem(id: id, title: id + ".JPG", kind: .photo, resources: [CameraMediaResource(url: URL(string: "http://192.168.54.1/\(id).JPG")!, mimeType: "image/jpeg", role: original ? .original : .thumbnail)])
    }
    private func settle(_ model: MediaExportCoordinator) async {
        for _ in 0..<400 { if !model.isRunning { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Export did not settle")
    }
    func testOnlyOriginalsDownloadAndPreparedIsNotSavedSuccess() async {
        let fake = FakeMediaDownloader()
        let model = MediaExportCoordinator(downloader: fake)
        model.start([item("thumb", original: false), item("photo")])
        await settle(model)
        let requests = await fake.requested
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(model.prepared.map(\.item.id), ["photo"])
        XCTAssertEqual(model.failures.map(\.item.id), ["thumb"])
        XCTAssertTrue(model.successfulIDs.isEmpty, "Download does not mean saved to Photos or Files")
        model.cancel()
        for _ in 0..<100 { if await fake.discarded.count == 1 { break }; await Task.yield() }
        let removed = await fake.discarded
        XCTAssertEqual(removed.count, 1)
    }
    func testLatePreviousProgressCannotChangeCurrentItemAndBackgroundCancels() async {
        let fake = FakeMediaDownloader(holdSecond: true)
        let model = MediaExportCoordinator(downloader: fake)
        model.start([item("first"), item("second")])
        for _ in 0..<300 { if model.currentItem?.id == "second" { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        await fake.lateFirstProgress()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(model.currentItem?.id, "second")
        XCTAssertNotEqual(model.progress, 0.9)
        model.cancel()
        await fake.releaseSecond()
        await settle(model)
        for _ in 0..<200 { if await fake.discarded.count == 2 { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.prepared.isEmpty)
        XCTAssertTrue(model.successfulIDs.isEmpty)
        let removed = await fake.discarded
        XCTAssertEqual(removed.count, 2, "Late completed file must be discarded too")
    }
}

actor FakeMediaDownloader: MediaDownloading {
    var requested: [CameraMediaResource] = []
    var discarded: [URL] = []
    private let holdSecond: Bool
    private var firstProgress: (@Sendable (Double?) -> Void)?
    private var second: CheckedContinuation<Void, Never>?
    init(holdSecond: Bool = false) { self.holdSecond = holdSecond }
    func download(_ resource: CameraMediaResource, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        requested.append(resource)
        if requested.count == 1 { firstProgress = progress }
        if requested.count == 2 && holdSecond { await withCheckedContinuation { second = $0 } }
        progress(nil)
        return URL(fileURLWithPath: "/tmp/\(UUID().uuidString).JPG")
    }
    func lateFirstProgress() { firstProgress?(0.9) }
    func releaseSecond() { second?.resume(); second = nil }
    func discard(_ url: URL) { discarded.append(url) }
}
