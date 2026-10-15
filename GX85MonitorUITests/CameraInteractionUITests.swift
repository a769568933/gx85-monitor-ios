import XCTest

final class CameraInteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-monitor"]
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
        app.buttons["400"].tap()
        assertNoFocus(in: app)
    }

    func testPortraitBlackBorderDoesNotSendFocus() {
        let app = launch()
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
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
