import CoreGraphics

enum PreviewLayout {
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
