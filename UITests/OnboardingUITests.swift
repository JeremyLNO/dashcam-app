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
        XCTAssertTrue(app.staticTexts["Choose what it does"].waitForExistence(timeout: 3),
                      "the features are offered before the camera is asked for")

        advance.tap()
        XCTAssertTrue(app.staticTexts["One permission to start"].waitForExistence(timeout: 3))
        // Only now is there anything that triggers a permission prompt.
        XCTAssertTrue(app.buttons["Not now"].exists)
    }

    func testSkippingTheCameraPromptStillReachesTheApp() {
        launch(skipOnboarding: false)
        let advance = app.buttons["onboardingContinue"]
        XCTAssertTrue(advance.waitForExistence(timeout: Self.launchTimeout))

        // Tapped until the last card rather than a fixed number of times: the count of
        // explanatory pages is a design decision, not something a test should pin down.
        let later = app.buttons["Not now"]
        for _ in 0..<8 where !later.exists { advance.tap() }
        later.tap()

        XCTAssertTrue(drivesTab.waitForExistence(timeout: 5))
    }

    /// Someone who skipped the introduction can ask for it back, and doing so must not
    /// undo the settings they have chosen since.
    func testTheIntroductionCanBeReplayedFromSettings() {
        launch()
        waitForTabBar()
        tab("Settings").tap()

        let replay = app.buttons["replayOnboarding"]
        for _ in 0..<10 where !replay.exists { app.swipeUp() }
        XCTAssertTrue(replay.waitForExistence(timeout: 5))
        replay.tap()

        XCTAssertTrue(app.staticTexts["Turn your iPhone into a dashcam"].waitForExistence(timeout: 5))
    }

    func testOnboardingIsNotShownAgainOnceCompleted() {
        launch(skipOnboarding: true)
        waitForTabBar()
        XCTAssertFalse(app.staticTexts["Turn your iPhone into a dashcam"].exists)
    }
}
