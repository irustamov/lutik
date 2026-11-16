import XCTest

/// Copy and Paste in the folder screen.
@MainActor
final class ClipboardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A long press on the list's empty space, below the rows, shows Paste in the edit menu, as ＋ does,
    /// and pastes through the same path: a copy pasted into the folder it came from is refused, in one alert.
    func testLongPressBelowRowsOffersPaste() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        row.press(forDuration: 1.2)
        let copy = app.collectionViews.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(app.staticTexts["Copying…"].waitForNonExistence(timeout: 10))

        // Well below the fixture's few rows, above the bottom bar.
        let list = app.collectionViews.firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the empty-space menu offers Paste")
        XCTAssertTrue(paste.isEnabled)
        paste.tap()
        XCTAssertTrue(app.alerts["Couldn't Paste"].waitForExistence(timeout: 10))
    }
}
