import XCTest

final class OnboardingUITests: UITestCase {
    /// The five screens, in order, ending on the camera explanation — the system prompt
    /// must never be the first thing the user sees.
    func testOnboardingWalksThroughEveryScreenBeforeAskingForTheCamera() {
        launch(skipOnboarding: false)

        XCTAssertTrue(app.staticTexts["Turn your iPhone into a dashcam"].waitForExistence(timeout: Self.launchTimeout))

        let advance = app.buttons["onboardingContinue"]
        XCTAssertTrue(advance.exists)

        advance.tap()
        XCTAssertTrue(app.staticTexts["Two cameras. One drive."].waitForExistence(timeout: 3))

        advance.tap()
        XCTAssertTrue(app.staticTexts["Important moments protect themselves"].waitForExistence(timeout: 3))

        advance.tap()
        XCTAssertTrue(app.staticTexts["Your videos stay yours"].waitForExistence(timeout: 3))

        advance.tap()
        XCTAssertTrue(app.staticTexts["One permission to start"].waitForExistence(timeout: 3))
        // Only now is there anything that triggers a permission prompt.
        XCTAssertTrue(app.buttons["Not now"].exists)
    }

    func testSkippingTheCameraPromptStillReachesTheApp() {
        launch(skipOnboarding: false)
        let advance = app.buttons["onboardingContinue"]
        XCTAssertTrue(advance.waitForExistence(timeout: Self.launchTimeout))

        for _ in 0..<4 { advance.tap() }
        app.buttons["Not now"].tap()

        XCTAssertTrue(drivesTab.waitForExistence(timeout: 5))
    }

    func testOnboardingIsNotShownAgainOnceCompleted() {
        launch(skipOnboarding: true)
        waitForTabBar()
        XCTAssertFalse(app.staticTexts["Turn your iPhone into a dashcam"].exists)
    }
}
