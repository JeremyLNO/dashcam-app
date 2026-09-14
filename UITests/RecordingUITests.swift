import XCTest

final class RecordingUITests: UITestCase {
    /// The Simulator has no cameras, so the recording screen has to say so plainly and
    /// keep Start unusable rather than pretending to record nothing.
    func testRecordingScreenReportsCameraUnavailabilityHonestly() {
        launch()
        waitForTabBar()

        // The REC indicator is a combined accessibility element, so its spoken label —
        // not the raw "Stopped" glyph text — is what a client sees.
        XCTAssertTrue(app.staticTexts["Not recording"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Start Drive"].exists)
        XCTAssertFalse(app.buttons["Start Drive"].isEnabled, "no camera in the Simulator")
    }

    /// Three hardware cards before the drive, four figures under the button. The cards
    /// are the pre-flight check; the figures are what the screen is worth reading for
    /// while stopped.
    func testStatusTilesAreAllPresent() {
        launch()
        waitForTabBar()

        for label in ["Road camera", "Cabin camera", "GPS"] {
            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.exists,
                "missing hardware card: \(label)"
            )
        }

        // The drive stats are below the fold, and their grid builds lazily — so they
        // exist only once scrolled to, which is also the only way a user meets them.
        for label in ["Duration", "Distance", "Storage free", "Protected events"] {
            let tile = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            for _ in 0..<4 where !tile.exists { app.swipeUp() }
            XCTAssertTrue(tile.exists, "missing drive stat: \(label)")
        }
    }

    /// The discreet screen has to be reachable on purpose, not only by waiting for a
    /// countdown — and it has to give the cameras back on the first touch anywhere.
    ///
    /// What this cannot check is the part that matters most at night: the backlight
    /// coming down and going back up. That lives in `ScreenDimmerTests`, because a
    /// simulator has no backlight to measure.
    func testTheDimButtonGoesDiscreetAndATouchBringsTheCamerasBack() {
        launch()
        waitForTabBar()

        let dim = app.buttons["dimScreen"]
        XCTAssertTrue(dim.waitForExistence(timeout: 10), "no way into the discreet screen")
        dim.tap()

        XCTAssertTrue(
            app.staticTexts["Tap anywhere to show the cameras"].waitForExistence(timeout: 5),
            "the discreet screen has to say how to leave it"
        )
        XCTAssertFalse(app.buttons["Start Drive"].exists, "the driving screen is gone while discreet")

        // Anywhere, not a button: that is the promise the screen makes.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["Start Drive"].waitForExistence(timeout: 5))
    }

    /// Protect is meaningless while stopped, and the UI says so by disabling it rather
    /// than failing after the tap.
    func testProtectIsDisabledWhileNotRecording() {
        launch()
        waitForTabBar()
        XCTAssertFalse(app.buttons["Protect"].isEnabled)
    }
}
