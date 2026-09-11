import XCTest

final class SettingsUITests: UITestCase {
    func testSupportAndBrandLinksArePresent() {
        launch()
        waitForTabBar()
        tab("Settings").tap()

        // Form rows are built lazily; the support and brand rows sit well below the fold.
        XCTAssertTrue(app.staticTexts["Subscription"].waitForExistence(timeout: Self.launchTimeout))
        for _ in 0..<8 where !app.buttons["supportLink"].exists { app.swipeUp() }

        XCTAssertTrue(app.buttons["supportLink"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.buttons["brandLink"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["brandLink"].waitForExistence(timeout: 5))
    }

    func testEveryConfigurableSectionIsReachable() {
        launch()
        waitForTabBar()
        tab("Settings").tap()

        XCTAssertTrue(app.staticTexts["Subscription"].waitForExistence(timeout: Self.launchTimeout))
        for section in ["Recording", "Storage"] {
            XCTAssertTrue(app.staticTexts[section].exists, "missing section \(section)")
        }
    }

    /// The user's language choice outranks the device language and takes effect
    /// immediately, without a relaunch.
    func testChangingLanguageUpdatesTheInterfaceImmediately() {
        launch()
        waitForTabBar()
        tab("Settings").tap()

        XCTAssertTrue(app.staticTexts["Subscription"].waitForExistence(timeout: Self.launchTimeout))
        let picker = app.descendants(matching: .any).matching(identifier: "languagePicker").firstMatch
        for _ in 0..<8 where !picker.exists { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()

        app.buttons["Français"].tap()

        XCTAssertTrue(app.tabBars.buttons["Réglages"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Vidéos"].exists)
    }

    func testQualityOptionsShowTheirStorageCost() {
        launch()
        waitForTabBar()
        tab("Settings").tap()

        let quality = app.buttons["Quality"].firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: Self.launchTimeout))
        quality.tap()

        XCTAssertTrue(app.staticTexts["Standard — 1080p"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'GB/h'")).firstMatch.exists,
            "each quality tier must state its GB per hour"
        )
    }
}
