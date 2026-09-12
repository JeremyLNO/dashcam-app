import XCTest

/// Shared launch plumbing.
///
/// Every UI test runs in English regardless of the host machine's language: passing
/// `-settings.language en` lands in the argument domain of `UserDefaults`, which is
/// exactly where `LanguageManager` reads the override from.
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-settings.language", "en"]
    }

    func launch(skipOnboarding: Bool = true, seedLibrary: Bool = false) {
        if skipOnboarding { app.launchArguments.append("-uiTestSkipOnboarding") }
        if seedLibrary { app.launchArguments.append("-uiTestSeed") }
        app.launch()
    }

    func tab(_ name: String) -> XCUIElement {
        app.tabBars.buttons[name]
    }

    /// The drives tab, named once here: it went from "Videos" to "Drives" with the
    /// redesign, and a dozen tests should not each know that.
    var drivesTab: XCUIElement { tab("Drives") }

    /// A cold launch runs recovery, a retention sweep and the first StoreKit round trip
    /// before the tab bar exists, which on a busy CI machine is comfortably more than the
    /// default five seconds.
    static let launchTimeout: TimeInterval = 30

    @discardableResult
    func waitForTabBar(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let appeared = tab("Record").waitForExistence(timeout: Self.launchTimeout)
        XCTAssertTrue(appeared, "the app never reached its tab bar", file: file, line: line)
        return appeared
    }

    /// First drive row in the library.
    var firstSessionRow: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sessionRow").firstMatch
    }
}
