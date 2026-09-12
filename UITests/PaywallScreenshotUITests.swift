import XCTest

/// Produces the App Store review screenshot Apple requires for every subscription.
///
/// This screen cannot be captured the way the other App Store shots were. The local
/// StoreKit configuration is attached to the *scheme*, and `simctl launch` bypasses the
/// scheme entirely: the app then starts with no store at all, `Product.products(for:)`
/// comes back empty and the paywall renders its "store unavailable" state. Running it as
/// a UI test is what puts the configuration in play, so the prices on the image are the
/// ones StoreKit really returned.
///
/// The capture is therefore gated on a currency amount being on screen — an empty
/// paywall must fail the test rather than produce a useless screenshot.
final class PaywallScreenshotUITests: UITestCase {
    func testCapturePaywallForAppStoreReview() {
        launch()
        waitForTabBar()
        tab("Settings").tap()

        let openPaywall = app.buttons["openPaywall"]
        XCTAssertTrue(openPaywall.waitForExistence(timeout: Self.launchTimeout))
        openPaywall.tap()

        XCTAssertTrue(app.staticTexts["Unlock your Dashcam"].waitForExistence(timeout: 30))

        for period in ["monthly", "quarterly", "yearly"] {
            let row = app.descendants(matching: .any).matching(identifier: "plan-\(period)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "missing \(period) plan")
        }

        // A price is the proof the store answered. Without it the shot would show the
        // three rows with blank amounts, which is exactly what a reviewer must not get.
        let priced = app.staticTexts.containing(NSPredicate(format: "label MATCHES %@", ".*[0-9]+[.,][0-9]{2}.*"))
        XCTAssertGreaterThan(priced.count, 0, "no StoreKit price on screen — the store did not answer")

        // Let the trial note and the selection state settle before freezing the frame.
        Thread.sleep(forTimeInterval: 2)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "paywall"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
