import XCTest
@testable import GX85Monitor

final class PreviewLayoutTests: XCTestCase {
    func testCompleteViewportCentersForSupportedAspects() {
        for (viewport, center) in [(CGSize(width: 390, height: 844), CGPoint(x: 195, y: 422)), (CGSize(width: 844, height: 390), CGPoint(x: 422, y: 195))] {
            for image in [CGSize(width: 640, height: 480), CGSize(width: 1920, height: 1080)] {
                let rect = PreviewLayout.fit(imageSize: image, in: viewport)
                XCTAssertEqual(rect.midX, center.x, accuracy: 0.01)
                XCTAssertEqual(rect.midY, center.y, accuracy: 0.01)
            }
        }
    }

    func testInvalidDimensionsNeverProduceNonfiniteRectangles() {
        for image in [CGSize(width: -1, height: 480), CGSize(width: CGFloat.infinity, height: 480), CGSize(width: 640, height: CGFloat.nan)] {
            XCTAssertEqual(PreviewLayout.fit(imageSize: image, in: CGSize(width: 390, height: 844)), .zero)
        }
    }
    func testPortraitFits43WithoutCropping() {
        let rect = PreviewLayout.fit(imageSize: CGSize(width: 640, height: 480), in: CGSize(width: 390, height: 600))
        XCTAssertEqual(rect.width, 390, accuracy: 0.01)
        XCTAssertEqual(rect.height, 292.5, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 300, accuracy: 0.01)
    }
    func testLandscapeFits169Beside96PointControls() {
        let rect = PreviewLayout.fit(imageSize: CGSize(width: 1920, height: 1080), in: CGSize(width: 684, height: 350))
        XCTAssertEqual(rect.height, 350, accuracy: 0.01)
        XCTAssertEqual(rect.width, 622.222222, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 684)
    }
    func testFullscreenUsesAvailableArea() {
        let rect = PreviewLayout.fit(imageSize: CGSize(width: 640, height: 480), in: CGSize(width: 780, height: 350))
        XCTAssertEqual(rect.height, 350, accuracy: 0.01)
        XCTAssertEqual(rect.width, 466.666666, accuracy: 0.01)
    }
    func testZeroImageDimensionsDoNotDivideByZero() {
        XCTAssertEqual(PreviewLayout.fit(imageSize: .zero, in: CGSize(width: 390, height: 600)), .zero)
        XCTAssertEqual(PreviewLayout.fit(imageSize: CGSize(width: 640, height: 480), in: .zero), .zero)
    }
}
