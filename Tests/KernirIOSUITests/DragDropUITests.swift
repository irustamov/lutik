import XCTest

/// Drag and drop within the app. Drops from Files can't be scripted (XCUITest can't arrange
/// Split View with Files); `DragDropTests` feeds the same handler real item providers.
@MainActor
final class DragDropUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A row dragged onto a folder of the same archive is refused: nothing is
    /// added, so no Save, and the folder lists only its own children.
    func testDraggingRowOntoOwnFolderAddsNothing() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        let docs = app.row("docs")

        row.press(forDuration: 1.0, thenDragTo: docs)

        XCTAssertFalse(app.buttons["Save"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertTrue(row.exists)
        docs.tap()
        XCTAssertTrue(app.row("docs/readme.md").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.row("docs/notes.txt").exists)
        XCTAssertTrue(app.row("docs/nested").exists)
        XCTAssertFalse(app.row("docs/hello.txt").exists)
    }

    /// Rows are drag sources now, but a long press without moving still opens the context menu.
    func testLongPressStillOpensContextMenu() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        row.press(forDuration: 1.2)

        for action in ["Preview", "Extract To…", "Share", "Delete"] {
            XCTAssertTrue(app.collectionViews.buttons[action].waitForExistence(timeout: 5), action)
        }
        XCTAssertFalse(app.buttons["Save"].exists)
    }
}
