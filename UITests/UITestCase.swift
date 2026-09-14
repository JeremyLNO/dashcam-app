import XCTest

/// Shared launch plumbing.
///
/// Every UI test runs in one pinned language, whatever the host machine is set to and
/// whatever an earlier test left on disk. Two arguments are needed, not one:
///
///  * `-settings.language` is the app's own override, which is what `LanguageManager`
///    reads.
///  * `-AppleLanguages` is the device language underneath it, which still decides what
///    `.system` resolves to and what iOS draws itself.
///
/// Both land in the argument domain of `UserDefaults`, which outranks anything written
/// to disk — so neither `-uiTestReset` nor the language test that runs first alphabetically
/// can change what language a test starts in.
///
/// The locale is deliberately *not* pinned: what has to be deterministic here is the
/// language the strings are read in, not how numbers and dates are formatted.
class UITestCase: XCTestCase {
    /// The language every UI test runs in. Assertions on English wording — "GB/h" rather
    /// than "Go/h" — are only meaningful because of this.
    static let language = "en"

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-uiTestReset",
            "-settings.language", Self.language,
            "-AppleLanguages", "(\(Self.language))",
        ]
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
        // The tab bar is the first thing on screen written in the app's language, so a
        // language that did not take hold is caught here — with the labels it actually
        // found — rather than five assertions later, where it reads as a missing element.
        XCTAssertTrue(
            appeared,
            "no tab bar in \(Self.language) after \(Int(Self.launchTimeout))s; tabs read \(tabLabels)",
            file: file, line: line
        )
        return appeared
    }

    /// What the tab bar currently says, for failure messages.
    var tabLabels: [String] {
        app.tabBars.buttons.allElementsBoundByIndex.map(\.label)
    }

    /// First drive row in the library.
    var firstSessionRow: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sessionRow").firstMatch
    }
}
