import XCTest

final class CameraInteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(slowParameters: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-monitor"] + (slowParameters ? ["--fixture-slow-parameter"] : [])
        app.launch()
        XCTAssertTrue(app.images["livePreview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["fixtureStatus"].firstMatch.exists)
        return app
    }

    func testImageTapSendsAutofocusRequest() {
        let app = launch()
        app.images["livePreview"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let requested = NSPredicate(format: "value == %@", "对焦请求:1")
        expectation(for: requested, evaluatedWith: app.descendants(matching: .any)["fixtureStatus"].firstMatch)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.descendants(matching: .any)["focusIndicator"].firstMatch.exists)
    }

    func testOverlayParameterControlDoesNotFocusImage() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let iso = app.buttons["parameter-iso"]
        XCTAssertTrue(iso.waitForExistence(timeout: 3))
        let center = CGPoint(x: iso.frame.midX, y: iso.frame.midY)
        XCTAssertTrue(app.images["livePreview"].frame.contains(center), "The control must overlap the image for this regression test")
        iso.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 3))
        wheel.adjust(toPickerWheelValue: "400")
        XCTAssertTrue(app.staticTexts["相机：400"].waitForExistence(timeout: 5), "Scrolling must apply without confirmation")
        XCTAssertTrue(wheel.exists)
        app.buttons["完成"].tap()
        assertNoFocus(in: app)
    }

    func testAperturePickerScrollsToSmallApertureWithoutFocusingImage() {
        let app = launch()
        app.buttons["parameter-aperture"].tap()
        let wheel = app.pickerWheels.firstMatch
        guard wheel.waitForExistence(timeout: 3) else { return XCTFail("Exposure choices need a native scroll wheel") }
        wheel.swipeUp()
        wheel.adjust(toPickerWheelValue: "F22")
        XCTAssertTrue(app.staticTexts["相机：F22"].waitForExistence(timeout: 5))
        XCTAssertTrue(wheel.exists, "Selection should stay open while values apply")
        app.buttons["完成"].tap()
        assertNoFocus(in: app)
        XCTAssertFalse(app.staticTexts["光圈已由相机确认。"].exists)
    }

    func testLatestWheelChoiceSurvivesSlowCameraAndOpeningDoesNotWrite() {
        let app = launch(slowParameters: true)
        app.buttons["parameter-iso"].tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 3))
        let counter = app.staticTexts["fixtureParameterWriteCount"]
        XCTAssertEqual(counter.label, "设置次数:0", "Opening a parameter must not write a default")
        wheel.adjust(toPickerWheelValue: "400")
        expectation(for: NSPredicate(format: "label == %@", "设置次数:1"), evaluatedWith: counter)
        waitForExpectations(timeout: 3)
        wheel.adjust(toPickerWheelValue: "100")
        expectation(for: NSPredicate(format: "label == %@", "设置次数:2"), evaluatedWith: counter)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["相机：100"].waitForExistence(timeout: 5))
        XCTAssertTrue(wheel.exists)
        app.buttons["完成"].tap()
        assertNoFocus(in: app)
    }

    func testPortraitBlackBorderDoesNotSendFocus() {
        let app = launch()
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width }, evaluatedWith: app.windows.firstMatch)
        waitForExpectations(timeout: 5)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        assertNoFocus(in: app)
    }

    private func assertNoFocus(in app: XCUIApplication) {
        let badge = app.descendants(matching: .any)["fixtureStatus"].firstMatch
        XCTAssertEqual(badge.value as? String, "对焦请求:0")
        let unexpected = expectation(for: NSPredicate(format: "value != %@", "对焦请求:0"), evaluatedWith: badge)
        unexpected.isInverted = true
        waitForExpectations(timeout: 1)
    }
}
