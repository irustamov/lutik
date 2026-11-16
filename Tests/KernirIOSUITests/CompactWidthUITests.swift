import XCTest

/// iPad at compact width, as in Split View or Slide Over. The DEBUG `-KernirCompactWidth` launch
/// argument makes every window's horizontal size class compact: the bar's centre items go to
/// "More", and popovers and form sheets come up as sheets. iPhone is compact anyway and runs the
/// whole suite that way, so these tests skip there.
@MainActor
final class CompactWidthUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches at compact width and opens `fixture`. Skips on iPhone.
    private func launchCompact(fixture: String = "zip/deflate.zip") throws -> XCUIApplication {
        // Not `isRegularWidth`: these tests run on iPad under the override, which that would reject.
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPhone is compact anyway")
        let app = XCUIApplication()
        app.launchArguments += ["-KernirCompactWidth"]
        app.launchOpening(fixture: fixture)
        return app
    }

    /// Rows, a pushed level and back, then closing to the launch browser. The launch browser is
    /// kept as a screenshot: it runs out of process, and whether it follows the override is recorded.
    func testCompactBrowseSmoke() throws {
        try skipUnlessLaunchView()
        let app = try launchCompact()
        let docs = app.row("docs")
        app.waitForArchive(docs)
        for path in ["empty-dir", "empty.txt", "hello.txt"] {
            XCTAssertTrue(app.row(path).exists, path)
        }
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "no search field")
        app.attachScreenshot("Compact root")

        docs.tap()
        XCTAssertTrue(app.row("docs/nested").waitForExistence(timeout: 5))
        XCTAssertTrue(app.row("docs/notes.txt").exists)
        XCTAssertTrue(app.navigationBars["docs"].exists)
        app.attachScreenshot("Compact docs")

        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 5), "back at the root")
        XCTAssertTrue(app.row("docs/notes.txt").waitForNonExistence(timeout: 5))

        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10), app.debugDescription)
        let sidebar = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sidebar.item"))
        let firstSidebarItem = sidebar.firstMatch
        let tabBarButton = app.tabBars.buttons.firstMatch
        _ = firstSidebarItem.waitForExistence(timeout: 5) || tabBarButton.waitForExistence(timeout: 1)
        app.attachScreenshot("Compact launch browser | sidebar items: \(sidebar.count)")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
    }

    /// The search field is on screen in a pushed level as at the root, without pulling the list
    /// down: iPhone shows it on every level (iOS 26: in the bottom bar), and a pushed iPad level
    /// at compact width hid it under the bar. Extract's Files picker still comes up there.
    func testCompactSearchFieldOnEveryLevel() throws {
        let app = try launchCompact()
        let docs = app.row("docs")
        app.waitForArchive(docs)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field at the root")
        XCTAssertTrue(field.isHittable, "root: \(field.debugDescription)")

        docs.tap()
        XCTAssertTrue(app.row("docs/notes.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field in docs\n\(app.debugDescription)")
        XCTAssertTrue(field.isHittable, "docs: \(field.debugDescription)")
        app.attachScreenshot("Compact docs search field")

        // The level's own search placement leaves its pickers working.
        app.extractTo()
        XCTAssertTrue(app.filesPicker.waitForExistence(timeout: 10), "the Files picker did not come up in docs")
        app.cancelPicker()
        XCTAssertTrue(app.row("docs/notes.txt").waitForExistence(timeout: 5))
    }

    /// Share comes up as a sheet, not a popover.
    func testCompactShareIsSheet() throws {
        let app = try launchCompact()
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.contextMenuButton("Share", on: row).tap()
        app.assertShareSheetShown()
        XCTAssertFalse(app.otherElements["PopoverDismissRegion"].exists, "the share sheet is a popover")
        XCTAssertTrue(app.otherElements["ActivityListView"].exists)
        app.dismissShareSheet()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// Select is placed the same at the root and in a pushed level, whichever place the compact
    /// window gives it (the bar or "More"), and Select mode starts and selects from there.
    /// Where the centre items go under compact is recorded, not asserted.
    func testCompactSelectPlacementConsistent() throws {
        let app = try launchCompact()
        let docs = app.row("docs")
        app.waitForArchive(docs)
        let atRoot = app.isOnBar("Select")
        app.attachScreenshot("Compact root: Select \(atRoot ? "on the bar" : "in More or absent")")

        docs.tap()
        let notes = app.row("docs/notes.txt")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        let inDocs = app.isOnBar("Select")
        app.attachScreenshot("Compact docs: Select \(inDocs ? "on the bar" : "in More or absent")")
        XCTAssertEqual(inDocs, atRoot, "Select is placed differently at the root and in docs")

        app.startSelecting()
        let delete = app.toolbars.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "nothing selected yet")
        notes.tap()
        XCTAssertTrue(delete.waitForEnabled(timeout: 5), "the row is selected")
        XCTAssertFalse(app.previewController.exists, "the row was opened, not selected")
    }

    /// Save As Copy's options come up as a sheet across the window, not a centred form sheet.
    func testCompactSaveOptionsSheet() throws {
        let app = try launchCompact()
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.tapSaveAsCopy()
        app.assertSpansWindow(app.navigationBars["Save a Copy"], "the Save a Copy sheet")
        app.assertFormat("ZIP")
        app.attachScreenshot("Compact Save As Copy sheet")

        app.saveOptionsButton("Cancel").tap()
        XCTAssertTrue(app.navigationBars["Save a Copy"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.filesPicker.exists, app.debugDescription)
        XCTAssertTrue(row.exists)
    }

    /// The password sheet comes up as a sheet across the window, and unlocks the archive.
    func testCompactPasswordSheet() throws {
        let app = try launchCompact(fixture: "zip/aes256.zip")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        app.waitUntilSettled(field)
        app.assertSpansWindow(app.navigationBars["Enter Password"], "the password sheet")
        app.attachScreenshot("Compact password sheet")

        field.tap()
        field.typeText("kernir")
        app.buttons["Open"].tap()
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 10))
        XCTAssertFalse(field.exists)
    }

    /// Extract's Files picker comes up in folder mode and cancels cleanly. The picker runs out of
    /// process: its width is recorded, and the compact assert is on the app's own bar. It also
    /// guards the root's `.searchable` placement (FolderScreen `Search`): an earlier root/pushed
    /// split was kept because this picker once didn't come up with the computed placement there.
    func testCompactExtractPicker() throws {
        let app = try launchCompact()
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.extractTo()
        XCTAssertTrue(app.filesPicker.waitForExistence(timeout: 10), "the Files picker did not come up")
        app.recordWidth(of: app.filesPicker, "Compact Extract picker")
        XCTAssertTrue(app.pickerOffersNewFolder(), "Extract's picker picks a folder\n\(app.debugDescription)")
        app.cancelPicker()
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertTrue(row.exists)
    }
}
