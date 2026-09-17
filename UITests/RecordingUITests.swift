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

    /// The discreet screen belongs to a drive. Stopped, the button is there — visible, so
    /// the driver knows where it lives — and inert, the same treatment Protect gets.
    ///
    /// A tap is sent anyway rather than trusting `isEnabled`: a control can report itself
    /// disabled and still act, and what is being pinned here is that the screen does not
    /// go dark. The simulator has no cameras, so no recording can be started from a test
    /// and the lit half of the rule lives in `ScreenDimmerTests` — as does the part no UI
    /// test could ever see, the backlight itself.
    func testTheDimButtonIsInertWhileNoDriveIsRunning() {
        launch()
        waitForTabBar()

        let dim = app.buttons["dimScreen"]
        XCTAssertTrue(dim.waitForExistence(timeout: 10), "the moon button must stay visible")
        XCTAssertFalse(dim.isEnabled, "nothing to be discreet about before a drive starts")

        dim.tap()
        XCTAssertFalse(
            app.staticTexts["Tap anywhere to leave the discreet screen"].waitForExistence(timeout: 3),
            "the screen went discreet with no recording running"
        )
        XCTAssertTrue(app.buttons["Start Drive"].exists, "and Start is exactly what it would have hidden")
    }

    /// Landscape is how this app is actually used — a phone in a windscreen cradle — and
    /// it has a layout of its own, not a stretched portrait one. A control that exists in
    /// only one of the two is a control half the drivers never get.
    func testTheDimButtonIsThereInTheOrientationTheAppIsMeantForToo() {
        launch()
        waitForTabBar()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        XCTAssertTrue(app.buttons["dimScreen"].waitForExistence(timeout: 10),
                      "the driving orientation lost the button")
    }

    /// Protect is meaningless while stopped, and the UI says so by disabling it rather
    /// than failing after the tap.
    func testProtectIsDisabledWhileNotRecording() {
        launch()
        waitForTabBar()
        XCTAssertFalse(app.buttons["Protect"].isEnabled)
    }
}
