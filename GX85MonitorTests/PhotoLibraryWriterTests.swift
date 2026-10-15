import Foundation
import Photos
import XCTest
import GX85Core
@testable import GX85Monitor

final class PhotoLibraryWriterTests: XCTestCase {
    func testDeniedAndRestrictedNeverSubmitAsset() async throws {
        let calls = PhotoWriteCalls()
        for status in [PHAuthorizationStatus.denied, .restricted] {
            let writer = PhotoLibraryWriter(authorize: { status }, write: { _, kind in await calls.append(kind) })
            do { try await writer.save(fileURL: URL(fileURLWithPath: "/tmp/photo.JPG"), kind: .photo); XCTFail("Permission required") } catch { }
        }
        let submitted = await calls.values
        XCTAssertTrue(submitted.isEmpty)
    }
    func testPhotoAndVideoUseFileURLAndSystemFailurePropagates() async throws {
        let calls = PhotoWriteCalls()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".JPG")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = PhotoLibraryWriter(authorize: { .authorized }, write: { file, kind in
            XCTAssertTrue(file.isFileURL); XCTAssertEqual(file, url); await calls.append(kind)
        })
        try await writer.save(fileURL: url, kind: .photo)
        try await writer.save(fileURL: url, kind: .video)
        let submitted = await calls.values
        XCTAssertEqual(submitted, [.photo, .video])
        let broken = PhotoLibraryWriter(authorize: { .limited }, write: { _, _ in throw CocoaError(.fileWriteUnknown) })
        do { try await broken.save(fileURL: url, kind: .photo); XCTFail("System failure must propagate") } catch { }
    }
}
private actor PhotoWriteCalls {
    var values: [CameraMediaKind] = []
    func append(_ value: CameraMediaKind) { values.append(value) }
}

@MainActor
final class MediaSavingTests: XCTestCase {
    private func items() -> [CameraMediaItem] {
        ["one", "two"].map { CameraMediaItem(id: $0, title: $0, kind: .photo, resources: [CameraMediaResource(url: URL(string: "http://192.168.54.1/\($0).JPG")!, mimeType: "image/jpeg", role: .original)]) }
    }
    private func settle(_ model: MediaExportCoordinator) async {
        for _ in 0..<400 { if !model.isRunning { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Save did not settle")
    }
    func testPartialPhotosSuccessRetainsFailedFileForFilesFallback() async {
        let downloader = FakeMediaDownloader()
        let model = MediaExportCoordinator(downloader: downloader)
        model.start(items()); await settle(model)
        model.savePhotos(using: SelectivePhotoWriter())
        await settle(model)
        XCTAssertEqual(model.successfulIDs, ["one"])
        XCTAssertEqual(model.prepared.map(\.item.id), ["two"])
        XCTAssertEqual(model.failures.map(\.item.id), ["two"])
        let deleted = await downloader.discarded
        XCTAssertEqual(deleted.count, 1)
        model.cancel()
    }
    func testFilesCancelDoesNotReportSuccessAndKeepsURLsUntilPickerCompletes() async {
        let downloader = FakeMediaDownloader()
        let model = MediaExportCoordinator(downloader: downloader)
        model.start(items()); await settle(model)
        let urls = model.beginFilesExport()
        XCTAssertEqual(urls.count, 2)
        model.cancel()
        await Task.yield()
        let beforeDismiss = await downloader.discarded
        XCTAssertTrue(beforeDismiss.isEmpty, "Picker still consumes these URLs")
        await model.completeFilesExport(success: false)
        XCTAssertTrue(model.successfulIDs.isEmpty)
        let afterDismiss = await downloader.discarded
        XCTAssertEqual(afterDismiss.count, 2)
    }
    func testFilesCompletionReportsOnlyConfirmedItems() async {
        let model = MediaExportCoordinator(downloader: FakeMediaDownloader())
        model.start(items()); await settle(model)
        _ = model.beginFilesExport()
        XCTAssertTrue(model.successfulIDs.isEmpty)
        await model.completeFilesExport(success: true)
        XCTAssertEqual(model.successfulIDs, ["one", "two"])
        XCTAssertTrue(model.prepared.isEmpty)
    }
    func testCancellationRetainsFileUntilPhotosCompletionReturns() async {
        let downloader = FakeMediaDownloader()
        let writer = BlockingPhotoWriter()
        let model = MediaExportCoordinator(downloader: downloader)
        model.start(items()); await settle(model)
        model.savePhotos(using: writer)
        for _ in 0..<200 { if (await writer.started) { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        model.cancel()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let duringSave = await downloader.discarded
        XCTAssertEqual(duringSave.count, 1, "In-flight Photos operation still consumes its file")
        await writer.finish()
        for _ in 0..<200 { if (await downloader.discarded).count == 2 { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        let afterSave = await downloader.discarded
        XCTAssertEqual(afterSave.count, 2)
        XCTAssertTrue(model.successfulIDs.isEmpty)
    }
}
private actor SelectivePhotoWriter: PhotoLibraryWriting {
    var calls = 0
    func save(fileURL: URL, kind: CameraMediaKind) async throws {
        calls += 1
        if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
    }
}
private actor BlockingPhotoWriter: PhotoLibraryWriting {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func save(fileURL: URL, kind: CameraMediaKind) async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
