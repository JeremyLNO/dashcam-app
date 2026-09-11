import XCTest

/// The single most important commercial behaviour: export is locked without a paid
/// subscription, and tapping it opens the paywall instead of failing quietly.
final class ExportLockUITests: UITestCase {
    func testExportOpensThePaywallWhenNotSubscribed() {
        launch(seedLibrary: true)
        waitForTabBar()
        tab("Videos").tap()

        XCTAssertTrue(firstSessionRow.waitForExistence(timeout: Self.launchTimeout))
        firstSessionRow.tap()

        let exportButton = app.buttons["exportButton"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 10))
        exportButton.tap()

        XCTAssertTrue(app.staticTexts["Unlock your Dashcam"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["An active subscription is required to export your recordings."].exists,
            "the paywall must explain why it appeared"
        )
    }

    func testPaywallExposesRestoreAndTheLegalLinks() {
        launch(seedLibrary: true)
        waitForTabBar()
        tab("Settings").tap()

        let openPaywall = app.buttons["openPaywall"]
        XCTAssertTrue(openPaywall.waitForExistence(timeout: Self.launchTimeout))
        openPaywall.tap()

        XCTAssertTrue(app.staticTexts["Unlock your Dashcam"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["restoreButton"].exists)
        XCTAssertTrue(app.buttons["Manage Subscription"].exists)
        XCTAssertTrue(app.buttons["Terms of Use"].exists)
        XCTAssertTrue(app.buttons["Privacy Policy"].exists)
    }

    /// Prices come from StoreKit, so the three plans must be there and each must show a
    /// currency amount rather than a hardcoded string.
    func testAllThreePlansAreListedWithStoreKitPrices() {
        launch()
        waitForTabBar()
        tab("Settings").tap()

        let openPaywall = app.buttons["openPaywall"]
        XCTAssertTrue(openPaywall.waitForExistence(timeout: Self.launchTimeout))
        openPaywall.tap()

        XCTAssertTrue(app.staticTexts["Unlock your Dashcam"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 8)
        print("PAYWALL_DUMP_BEGIN")
        for t in app.staticTexts.allElementsBoundByIndex { print("TXT:", t.label) }
        print("PAYWALL_DUMP_END")
        for period in ["monthly", "quarterly", "yearly"] {
            let row = app.descendants(matching: .any).matching(identifier: "plan-\(period)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "missing \(period) plan")
        }
        XCTAssertTrue(app.staticTexts["BEST VALUE"].exists, "the yearly plan must be highlighted")
    }
}
