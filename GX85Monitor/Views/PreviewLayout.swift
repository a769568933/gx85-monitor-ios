import CoreGraphics

enum PreviewLayout {
    static func focusPoint(at point: CGPoint, in imageRect: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              imageRect.origin.x.isFinite, imageRect.origin.y.isFinite,
              imageRect.width.isFinite, imageRect.height.isFinite,
              imageRect.width > 0, imageRect.height > 0,
              point.x >= imageRect.minX, point.x <= imageRect.maxX,
              point.y >= imageRect.minY, point.y <= imageRect.maxY else { return nil }
        return CGPoint(x: (point.x - imageRect.minX) / imageRect.width,
                       y: (point.y - imageRect.minY) / imageRect.height)
    }
    static func fit(imageSize: CGSize, in available: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              available.width > 0, available.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              available.width.isFinite, available.height.isFinite else { return .zero }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (available.width - width) / 2, y: (available.height - height) / 2, width: width, height: height)
    }
}
