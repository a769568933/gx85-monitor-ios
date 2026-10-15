import Foundation

public enum CameraMediaKind: Equatable, Sendable { case photo, video, other }

public struct CameraMediaResource: Equatable, Sendable {
    public enum Role: Equatable, Sendable { case original, preview, thumbnail, unknown }
    public let url: URL
    public let mimeType: String
    public let role: Role
    public let size: Int64?
    public init(url: URL, mimeType: String, role: Role, size: Int64? = nil) {
        self.url = url; self.mimeType = mimeType; self.role = role; self.size = size
    }
}

public struct CameraMediaItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let kind: CameraMediaKind
    public let resources: [CameraMediaResource]
    public let isContainer: Bool
    public init(id: String, title: String, kind: CameraMediaKind, resources: [CameraMediaResource], isContainer: Bool = false) {
        self.id = id; self.title = title; self.kind = kind; self.resources = resources; self.isContainer = isContainer
    }
    public var originalResource: CameraMediaResource? {
        guard !isContainer else { return nil }
        return resources.first { $0.role == .original }
    }
    public var thumbnailResource: CameraMediaResource? {
        resources.first { $0.role == .thumbnail && $0.mimeType.hasPrefix("image/") }
            ?? resources.first { $0.role == .preview && $0.mimeType == "image/jpeg" }
            ?? resources.first { $0.role == .original && $0.mimeType == "image/jpeg" }
    }
    public var imagePreviewResource: CameraMediaResource? {
        resources.first { $0.role == .preview && $0.mimeType == "image/jpeg" }
            ?? resources.first { $0.role == .original && $0.mimeType == "image/jpeg" }
            ?? thumbnailResource
    }
}

public struct CameraMediaPage: Equatable, Sendable {
    public let items: [CameraMediaItem]
    public let numberReturned: Int
    public let totalMatches: Int
    public let nextStartingIndex: Int?
    public let updateID: String?
    public init(items: [CameraMediaItem], numberReturned: Int, totalMatches: Int, nextStartingIndex: Int?, updateID: String? = nil) {
        self.items = items; self.numberReturned = numberReturned; self.totalMatches = totalMatches
        self.nextStartingIndex = nextStartingIndex; self.updateID = updateID
    }
}

public enum MediaURLPolicy {
    public static func validate(_ url: URL, cameraHost: String) throws -> URL {
        let host = try CameraEndpoint(host: cameraHost).host
        let absolute = url.absoluteURL
        guard absolute.scheme?.lowercased() == "http", absolute.host == host,
              absolute.user == nil, absolute.password == nil, absolute.fragment == nil,
              absolute.port.map({ (1...65535).contains($0) }) ?? true else { throw CameraMediaError.invalidURL }
        return absolute
    }
}

public enum CameraMediaError: LocalizedError {
    case invalidURL, malformedDirectory, originalUnavailable, noProgress
    case invalidDirectoryField(String), directoryChanged
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "媒体地址不属于当前相机，已拒绝访问。"
        case .malformedDirectory, .invalidDirectoryField: return "无法识别相机相册回复，请重试本页或查看诊断。"
        case .directoryChanged: return "相机内容已变化，请重新载入相册。"
        case .originalUnavailable: return "相机未提供此格式的无线原文件，不能将预览图作为原片导出。"
        case .noProgress: return "相机没有返回下一页，请重新载入相册。"
        }
    }
}
