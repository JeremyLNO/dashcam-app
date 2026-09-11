import XCTest

final class LibraryUITests: UITestCase {
    func testEmptyLibraryExplainsItself() {
        launch(seedLibrary: false)
        waitForTabBar()
        tab("Videos").tap()

        XCTAssertTrue(app.staticTexts["No drives yet"].waitForExistence(timeout: 10))
    }

    func testSeededDrivesAppearGroupedWithTheirSummary() {
        launch(seedLibrary: true)
        waitForTabBar()
        tab("Videos").tap()

        XCTAssertTrue(app.staticTexts["Used"].waitForExistence(timeout: Self.launchTimeout))
        XCTAssertTrue(app.staticTexts["Drives"].exists)
        XCTAssertTrue(app.staticTexts["Recorded"].exists)
    }

    func testOpeningADriveShowsItsDetailAndPlayer() {
        launch(seedLibrary: true)
        waitForTabBar()
        tab("Videos").tap()

        XCTAssertTrue(firstSessionRow.waitForExistence(timeout: Self.launchTimeout))
        firstSessionRow.tap()

        XCTAssertTrue(app.staticTexts["Duration"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Segments"].exists)
        XCTAssertTrue(app.buttons["exportButton"].exists)
    }

    func testSelectionModeEnablesMultipleDeletion() {
        launch(seedLibrary: true)
        waitForTabBar()
        tab("Videos").tap()

        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: Self.launchTimeout))
        XCTAssertTrue(firstSessionRow.waitForExistence(timeout: Self.launchTimeout))
        select.tap()

        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "nothing selected yet")

        firstSessionRow.tap()
        XCTAssertTrue(delete.isEnabled)
    }
}
