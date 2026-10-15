import XCTest
import UIKit

final class CameraPresentationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(recording: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-monitor"] + (recording ? ["--fixture-recording"] : [])
        app.launch()
        XCTAssertTrue(app.images["livePreview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["fixtureStatus"].firstMatch.exists)
        return app
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "SIMULATION-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func assertTestCardAtScreenshotCenter(_ screenshot: XCUIScreenshot) {
        guard let image = screenshot.image.cgImage,
              let pixel = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)) else { XCTFail("Missing screenshot pixels"); return }
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(Double(rgba[0]), 235, accuracy: 20, "Screenshot must contain the orange test target at screen center")
        XCTAssertEqual(Double(rgba[1]), 153, accuracy: 20)
        XCTAssertEqual(Double(rgba[2]), 61, accuracy: 20)
    }
    func testPortraitAndBothLandscapesStayCentered() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait-photo"), (.landscapeLeft, "landscape-left-photo"), (.landscapeRight, "landscape-right-photo")] {
            XCUIDevice.shared.orientation = orientation
            let image = app.images["livePreview"]
            let window = app.windows.firstMatch
            let centered = NSPredicate { _, _ in
                let targetShape = orientation == .portrait ? window.frame.height > window.frame.width : window.frame.width > window.frame.height
                return targetShape && abs(image.frame.midX - window.frame.midX) <= 2 && abs(image.frame.midY - window.frame.midY) <= 2
            }
            expectation(for: centered, evaluatedWith: image)
            waitForExpectations(timeout: 5)
            let settledFrame = image.frame
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertEqual(image.frame, settledFrame, "Rotation must finish before capture")
            assertTestCardAtScreenshotCenter(XCUIScreen.main.screenshot())
            attach(app, name)
        }
    }
    func testNoticeDoesNotChangePreviewFrame() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app.windows.firstMatch)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 0.8)
        let image = app.images["livePreview"]
        let before = image.frame
        app.buttons["fixtureNotice"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "模拟长提示：")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(image.frame, before)
        attach(app, "landscape-long-notice")
    }
    func testPhotoAndRecordingButtonsReflectConfirmedState() {
        let app = launch()
        XCTAssertEqual(app.buttons["primaryShutter"].label, "拍照")
        app.buttons["视频"].tap()
        XCTAssertEqual(app.buttons["primaryShutter"].label, "开始录像")
        app.buttons["primaryShutter"].tap()
        let confirmed = NSPredicate(format: "label == %@", "停止录像")
        expectation(for: confirmed, evaluatedWith: app.buttons["primaryShutter"])
        waitForExpectations(timeout: 4)
        XCTAssertTrue(app.staticTexts["recordingTimer"].waitForExistence(timeout: 3), "Confirmed recording needs an elapsed-time overlay")
        attach(app, "portrait-recording")
        app.buttons["primaryShutter"].tap()
        let stopped = NSPredicate(format: "label == %@", "开始录像")
        expectation(for: stopped, evaluatedWith: app.buttons["primaryShutter"])
        waitForExpectations(timeout: 4)
    }
    func testParameterMenuAndAlbumUseLabeledSimulation() {
        let app = launch()
        app.buttons["parameter-iso"].tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 3))
        attach(app, "portrait-iso-options")
        wheel.adjust(toPickerWheelValue: "400")
        XCTAssertTrue(app.staticTexts["相机：400"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["相机相册"].tap()
        XCTAssertTrue(app.staticTexts["模拟相册 · 非相机连接"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["SIM-PHOTO.JPG"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["album-image-sim-photo"].waitForExistence(timeout: 8), "The cell must contain decoded image pixels")
        app.buttons["选择 SIM-PHOTO.JPG"].tap()
        XCTAssertTrue(app.buttons["导出原文件"].isEnabled)
        attach(app, "portrait-camera-album")
        app.buttons["返回监看"].tap()
        XCTAssertTrue(app.images["livePreview"].waitForExistence(timeout: 6))
    }
}
