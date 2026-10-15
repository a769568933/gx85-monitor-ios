import XCTest
@testable import GX85Monitor

final class FocusMappingTests: XCTestCase {
    func testCenterAndInclusiveEdgesMapToCameraSpace() throws {
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        for (point, expected) in [
            (CGPoint(x: 300, y: 350), CGPoint(x: 0.5, y: 0.5)),
            (CGPoint(x: 100, y: 200), CGPoint(x: 0, y: 0)),
            (CGPoint(x: 500, y: 200), CGPoint(x: 1, y: 0)),
            (CGPoint(x: 100, y: 500), CGPoint(x: 0, y: 1)),
            (CGPoint(x: 500, y: 500), CGPoint(x: 1, y: 1))
        ] {
            XCTAssertEqual(try XCTUnwrap(PreviewLayout.focusPoint(at: point, in: rect)), expected)
        }
    }

    func testBlackBordersAndInvalidCoordinatesAreIgnored() {
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        for point in [CGPoint(x: 99, y: 350), CGPoint(x: 501, y: 350), CGPoint(x: 300, y: 199), CGPoint(x: 300, y: 501), CGPoint(x: CGFloat.nan, y: 300)] {
            XCTAssertNil(PreviewLayout.focusPoint(at: point, in: rect))
        }
        XCTAssertNil(PreviewLayout.focusPoint(at: .zero, in: .zero))
    }

    func testSameRelativePointSurvivesRotationAndSourceAspectChange() throws {
        // Hand-derived fitted rectangles and the same quarter-width/three-quarter-height point.
        for (rect, point) in [
            (CGRect(x: 0, y: 275.75, width: 390, height: 292.5), CGPoint(x: 97.5, y: 495.125)),
            (CGRect(x: 162, y: 0, width: 520, height: 390), CGPoint(x: 292, y: 292.5)),
            (CGRect(x: 0, y: 312.3125, width: 390, height: 219.375), CGPoint(x: 97.5, y: 476.84375))
        ] {
            let mapped = try XCTUnwrap(PreviewLayout.focusPoint(at: point, in: rect))
            XCTAssertEqual(mapped.x, 0.25, accuracy: 0.00001)
            XCTAssertEqual(mapped.y, 0.75, accuracy: 0.00001)
        }
    }
}
