import XCTest

final class LibraryUITests: UITestCase {
    func testEmptyLibraryExplainsItself() {
        launch(seedLibrary: false)
        waitForTabBar()
        drivesTab.tap()

        XCTAssertTrue(app.staticTexts["No drives yet"].waitForExistence(timeout: 10))
    }

    func testSeededDrivesAppearGroupedWithTheirSummary() {
        launch(seedLibrary: true)
        waitForTabBar()
        drivesTab.tap()

        XCTAssertTrue(app.staticTexts["Used"].waitForExistence(timeout: Self.launchTimeout))
        XCTAssertTrue(app.staticTexts["Drives"].exists)
        XCTAssertTrue(app.staticTexts["Recorded"].exists)
    }

    func testOpeningADriveShowsItsDetailAndPlayer() {
        launch(seedLibrary: true)
        waitForTabBar()
        drivesTab.tap()

        XCTAssertTrue(firstSessionRow.waitForExistence(timeout: Self.launchTimeout))
        firstSessionRow.tap()

        XCTAssertTrue(app.staticTexts["Duration"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Trip Stats"].exists)
        XCTAssertTrue(app.buttons["exportButton"].exists)
    }

    /// Deleting from inside a drive has to come back to the list: staying on the detail
    /// screen would leave the user looking at something that no longer exists.
    func testDeletingFromTheDetailScreenReturnsToTheList() {
        launch(seedLibrary: true)
        waitForTabBar()
        drivesTab.tap()

        XCTAssertTrue(firstSessionRow.waitForExistence(timeout: Self.launchTimeout))
        let rowsBefore = app.descendants(matching: .any).matching(identifier: "sessionRow").count
        firstSessionRow.tap()

        let delete = app.buttons["deleteDrive"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()

        // Back on the library: its own title is there again, and one drive fewer. The
        // screen draws its header itself, so there is no navigation bar to look for.
        XCTAssertTrue(app.staticTexts["Your recorded trips and events."].waitForExistence(timeout: 10),
                      "the detail screen did not pop after deleting")
        XCTAssertFalse(delete.exists, "still on the detail screen")

        let rowsAfter = app.descendants(matching: .any).matching(identifier: "sessionRow").count
        XCTAssertEqual(rowsAfter, rowsBefore - 1, "the deleted drive is gone from the list")
    }

    func testSelectionModeEnablesMultipleDeletion() {
        launch(seedLibrary: true)
        waitForTabBar()
        drivesTab.tap()

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
