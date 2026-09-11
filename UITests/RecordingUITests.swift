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
        XCTAssertTrue(app.buttons["Start recording"].exists)
        XCTAssertFalse(app.buttons["Start recording"].isEnabled, "no camera in the Simulator")
    }

    func testStatusTilesAreAllPresent() {
        launch()
        waitForTabBar()

        for label in ["Road camera", "Cabin camera", "GPS", "Free space", "Time left", "Quality"] {
            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.exists,
                "missing status tile: \(label)"
            )
        }
    }

    /// Protect is meaningless while stopped, and the UI says so by disabling it rather
    /// than failing after the tap.
    func testProtectIsDisabledWhileNotRecording() {
        launch()
        waitForTabBar()
        XCTAssertFalse(app.buttons["Protect"].isEnabled)
    }
}
