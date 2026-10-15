import Foundation
import GX85Core

protocol MediaDownloading: Sendable {
    func download(_ resource: CameraMediaResource, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
    func discard(_ url: URL) async
}

enum MediaDownloadError: LocalizedError {
    case tooLarge, insufficientSpace, incomplete, invalidResponse
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "原文件超过本版本的 8 GiB 下载上限。"
        case .insufficientSpace: return "iPhone 可用空间不足，请释放空间后重试。"
        case .incomplete: return "原文件未完整下载，请检查相机连接后重试。"
        case .invalidResponse: return "相机未返回可下载的完整原文件。"
        }
    }
}

actor MediaDownloadService: MediaDownloading {
    static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let reserveBytes: Int64 = 64 * 1024 * 1024
    private let host: String
    private let root: URL
    private let session: URLSession
    private let collector: DownloadCollector
    private let availableBytes: @Sendable () -> Int64
    private let gate = CameraPermitPool(limit: 1)
    private var owned = Set<URL>()
    var ownedFileCount: Int { owned.count }

    init(cameraHost: String, configuration: URLSessionConfiguration = .ephemeral,
         availableBytes: @escaping @Sendable () -> Int64 = MediaDownloadService.freeBytes) {
        host = cameraHost; self.availableBytes = availableBytes
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GX85-\(UUID().uuidString)", isDirectory: true)
        collector = DownloadCollector(host: cameraHost, availableBytes: availableBytes)
        configuration.allowsCellularAccess = false; configuration.waitsForConnectivity = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 3600
        configuration.httpMaximumConnectionsPerHost = 1
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: collector, delegateQueue: queue)
    }
    nonisolated static func freeBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSTemporaryDirectory())
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    func download(_ resource: CameraMediaResource, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        guard resource.role == .original else { throw CameraMediaError.originalUnavailable }
        let url = try MediaURLPolicy.validate(resource.url, cameraHost: host)
        if let size = resource.size, size < 0 || size > Self.maximumBytes { throw MediaDownloadError.tooLarge }
        try await gate.acquire()
        defer { Task { await gate.release() } }
        try Task.checkCancellation()
        let required = resource.size ?? Self.reserveBytes
        guard availableBytes() >= required + Self.reserveBytes else { throw MediaDownloadError.insufficientSpace }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ext: String
        switch resource.mimeType { case "image/jpeg": ext = "JPG"; case "video/mp4": ext = "MP4"; case "image/x-panasonic-raw": ext = "RW2"; default: ext = "bin" }
        let destination = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        let cancellation = DownloadCancellation()
        progress(nil)
        let file = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: url)
                collector.register(task: task, destination: destination, expected: resource.size, progress: progress, continuation: continuation)
                cancellation.install(task)
                task.resume()
            }
        }, onCancel: { cancellation.cancel() })
        if Task.isCancelled { try? FileManager.default.removeItem(at: file); throw CancellationError() }
        owned.insert(file)
        return file
    }
    func discard(_ url: URL) {
        guard owned.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }
    deinit { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
}

private final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ task: URLSessionTask) { lock.withLock { self.task = task; if cancelled { task.cancel() } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
}

/// URLSession writes media to disk. The delegate only inspects metadata and moves the file.
private final class DownloadCollector: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Transfer {
        let destination: URL
        let expected: Int64?
        let progress: @Sendable (Double?) -> Void
        let continuation: CheckedContinuation<URL, Error>
        var failure: Error?
        var moved = false
        var lastProgress: TimeInterval = 0
    }
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private let host: String
    private let availableBytes: @Sendable () -> Int64
    init(host: String, availableBytes: @escaping @Sendable () -> Int64) { self.host = host; self.availableBytes = availableBytes }
    func register(task: URLSessionTask, destination: URL, expected: Int64?, progress: @escaping @Sendable (Double?) -> Void, continuation: CheckedContinuation<URL, Error>) {
        lock.withLock { transfers[task.taskIdentifier] = Transfer(destination: destination, expected: expected, progress: progress, continuation: continuation) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let valid = request.url.flatMap { try? MediaURLPolicy.validate($0, cameraHost: host) }
        completionHandler(valid == nil ? nil : request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let maximum = MediaDownloadService.maximumBytes
        let now = ProcessInfo.processInfo.systemUptime
        var callback: (@Sendable (Double?) -> Void)?
        var progress: Double?
        var failure: Error?
        lock.withLock {
            guard var transfer = transfers[downloadTask.taskIdentifier] else { return }
            if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { failure = MediaDownloadError.tooLarge }
            else if let expected = transfer.expected, totalBytesWritten > expected { failure = MediaDownloadError.incomplete }
            if now - transfer.lastProgress >= 0.1 {
                if availableBytes() < MediaDownloadService.reserveBytes { failure = MediaDownloadError.insufficientSpace }
                transfer.lastProgress = now
                callback = transfer.progress
                if totalBytesExpectedToWrite > 0 { progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
            }
            if let failure { transfer.failure = failure }
            transfers[downloadTask.taskIdentifier] = transfer
        }
        if failure != nil { downloadTask.cancel() } else { callback?(progress) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.withLock {
            guard var transfer = transfers[downloadTask.taskIdentifier], transfer.failure == nil else { return }
            do {
                guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200, let finalURL = response.url else { throw MediaDownloadError.invalidResponse }
                _ = try MediaURLPolicy.validate(finalURL, cameraHost: host)
                let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? -1
                guard size >= 0, size <= MediaDownloadService.maximumBytes,
                      response.expectedContentLength <= MediaDownloadService.maximumBytes else { throw MediaDownloadError.tooLarge }
                guard transfer.expected.map({ $0 == size }) ?? true,
                      response.expectedContentLength < 0 || response.expectedContentLength == size else { throw MediaDownloadError.incomplete }
                try FileManager.default.moveItem(at: location, to: transfer.destination)
                transfer.moved = true
            } catch { transfer.failure = error }
            transfers[downloadTask.taskIdentifier] = transfer
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = transfer.failure ?? error {
            if transfer.moved { try? FileManager.default.removeItem(at: transfer.destination) }
            transfer.continuation.resume(throwing: failure)
        } else if transfer.moved {
            transfer.continuation.resume(returning: transfer.destination)
        } else { transfer.continuation.resume(throwing: MediaDownloadError.incomplete) }
    }
}
