import Foundation
import Combine
import UIKit
import ImageIO
import GX85Core

@MainActor
final class CameraThumbnailLoader: ObservableObject {
    private let client: CameraMediaClient
    private let cache = NSCache<NSString, UIImage>()
    private var order: [String] = []
    private var costs: [String: Int] = [:]
    private var totalCost = 0
    private var epoch = UUID()
    private let budget = 32 * 1024 * 1024
    init(client: CameraMediaClient) { self.client = client; cache.totalCostLimit = budget }

    func load(_ item: CameraMediaItem) async -> UIImage? {
        for resource in item.thumbnailCandidates {
            guard !Task.isCancelled else { return nil }
            if let image = await load(resource) { return image }
        }
        return nil
    }

    func loadPreview(_ item: CameraMediaItem) async -> UIImage? {
        for resource in item.imagePreviewCandidates {
            guard !Task.isCancelled else { return nil }
            if let image = await load(resource, maximumPixelSize: 2048) { return image }
        }
        return nil
    }

    func load(_ resource: CameraMediaResource, maximumPixelSize: Int = 320) async -> UIImage? {
        guard (1...2048).contains(maximumPixelSize) else { return nil }
        let key = resource.url.absoluteString + "#\(maximumPixelSize)"
        if let image = cache.object(forKey: key as NSString) {
            order.removeAll { $0 == key }; order.append(key)
            return image
        }
        let current = epoch
        do {
            if let size = resource.size, size > 4 * 1024 * 1024 {
                await client.reportImageFailure(resource, reason: "图片超过预览传输上限")
                return nil
            }
            let data = try await client.imageData(resource, maximumSize: 4 * 1024 * 1024)
            try Task.checkCancellation()
            let image = await Task.detached(priority: .utility) { CameraImageDecode.image(data: data, maximumPixelSize: maximumPixelSize) }.value
            try Task.checkCancellation()
            guard current == epoch else { return nil }
            guard let image, let cg = image.cgImage else {
                await client.reportImageFailure(resource, reason: "无法解码图片，字节=\(data.count)")
                return nil
            }
            let cost = cg.bytesPerRow * cg.height
            guard cost <= budget else { return nil }
            if let old = costs.removeValue(forKey: key) { totalCost -= old; order.removeAll { $0 == key } }
            while totalCost + cost > budget, let oldest = order.first {
                order.removeFirst(); totalCost -= costs.removeValue(forKey: oldest) ?? 0
                cache.removeObject(forKey: oldest as NSString)
            }
            costs[key] = cost; order.append(key); totalCost += cost
            cache.setObject(image, forKey: key as NSString, cost: cost)
            return image
        } catch { return nil }
    }
    func reset() { epoch = UUID(); cache.removeAllObjects(); order = []; costs = [:]; totalCost = 0 }
}

enum CameraImageDecode {
    static func image(data: Data, maximumPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16 * 1024 * 1024 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
