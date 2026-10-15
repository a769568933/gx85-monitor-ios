import Foundation
import Photos
import GX85Core

protocol PhotoLibraryWriting: Sendable {
    func save(fileURL: URL, kind: CameraMediaKind) async throws
}
enum PhotoSaveError: LocalizedError {
    case permission, unsupported, failed
    var errorDescription: String? {
        switch self {
        case .permission: return "未获添加照片的权限，可在设置中允许，或选择保存到文件。"
        case .unsupported: return "此格式无法直接保存到照片，请选择保存到文件。"
        case .failed: return "系统未能保存此原文件，请尝试保存到文件。"
        }
    }
}
struct PhotoLibraryWriter: PhotoLibraryWriting {
    private let authorize: @Sendable () async -> PHAuthorizationStatus
    private let write: @Sendable (URL, CameraMediaKind) async throws -> Void
    init(authorize: @escaping @Sendable () async -> PHAuthorizationStatus = PhotoLibraryWriter.authorization,
         write: @escaping @Sendable (URL, CameraMediaKind) async throws -> Void = PhotoLibraryWriter.createAsset) {
        self.authorize = authorize; self.write = write
    }
    func save(fileURL: URL, kind: CameraMediaKind) async throws {
        try Task.checkCancellation()
        let status = await authorize()
        try Task.checkCancellation()
        guard status == .authorized || status == .limited else { throw PhotoSaveError.permission }
        guard kind == .photo || kind == .video else { throw PhotoSaveError.unsupported }
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { throw MediaDownloadError.incomplete }
        try Task.checkCancellation()
        try await write(fileURL, kind)
    }
    static func authorization() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status != .notDetermined { return status }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
    }
    static func createAsset(_ file: URL, _ kind: CameraMediaKind) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: kind == .video ? .video : .photo, fileURL: file, options: options)
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? PhotoSaveError.failed) }
            }
        }
    }
}
