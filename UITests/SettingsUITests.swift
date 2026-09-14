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
        XCTAssertTrue(app.tabBars.buttons["Trajets"].exists)
    }

    /// Every quality tier states what an hour of it costs in storage.
    ///
    /// Strict about the unit on purpose: `unit.gb_per_hour` is "GB/h" in English, "Go/h"
    /// in French and "GB/Std." in German, so an assertion that accepted all three would
    /// go on passing with the wrong bundle loaded — which is the thing it is here to
    /// catch. It can afford to be strict because `UITestCase` pins the language.
    func testQualityOptionsShowTheirStorageCost() {
        launch()
        waitForTabBar()
        tab("Settings").tap()

        let quality = app.buttons["Quality"].firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: Self.launchTimeout))
        quality.tap()

        // The picker screen by identifier, not by one of its option titles: "Standard —
        // 1080p" is written on the row that opens it as well, so waiting for that text
        // proved nothing and let the test sail past a tap that had not navigated at all.
        let picker = app.descendants(matching: .any).matching(identifier: "optionPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the quality picker never opened")

        let costs = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"\d+\.\d GB/h"#))
        XCTAssertTrue(
            costs.element(boundBy: 2).waitForExistence(timeout: 5),
            "each quality tier must state its GB per hour; the screen reads \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
    }
}
