import XCTest

/// Preview and share when extracting takes a while (`-KernirSlowExtract`): the progress sheet
/// comes up first, and the preview or share sheet must still come up, once, after it has gone.
/// Also: previews in pushed levels, read-only and unlocked encrypted archives, and rotation.
@MainActor
final class PreviewShareUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The "Preparing “name”…" progress sheet.
    private func preparing(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Preparing")).firstMatch
    }

    /// Launches with every extraction taking `seconds` (3 s: long enough that the progress sheet,
    /// polled once a second, can't be missed).
    private func launchSlow(_ seconds: String = "3", fixture: String = "zip/deflate.zip") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-KernirSlowExtract", seconds]
        app.launchOpening(fixture: fixture)
        return app
    }

    /// Rotation tests put the device back upright, whatever happens.
    private func restoreOrientationAfterTest() {
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
        }
    }

    // MARK: - Slow preview and share

    func testSlowPreviewShowsProgressThenPreview() {
        let app = launchSlow()
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        row.tap()
        XCTAssertTrue(preparing(in: app).waitForExistence(timeout: 5),
                      "the progress sheet did not come up\n\(app.debugDescription)")
        app.assertPreviewShown(title: "hello", timeout: 15)
        XCTAssertFalse(preparing(in: app).exists)
        app.closePreview()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(preparing(in: app).exists, "the progress sheet came back")
    }

    func testSlowShareShowsProgressThenShareSheet() {
        let app = launchSlow()
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.contextMenuButton("Share", on: row).tap()
        XCTAssertTrue(preparing(in: app).waitForExistence(timeout: 5),
                      "the progress sheet did not come up\n\(app.debugDescription)")
        app.assertShareSheetShown(timeout: 15)
        XCTAssertFalse(preparing(in: app).exists)
        app.dismissShareSheet()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.assertNoPopover()
    }

    /// In Select mode the toolbar's Share goes through the progress sheet too.
    func testSlowSelectionShareShowsShareSheet() {
        let app = launchSlow()
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.startSelecting()
        row.tap()
        let share = app.toolbars.buttons["Share"]
        XCTAssertTrue(share.waitForEnabled(timeout: 5))
        share.tap()
        XCTAssertTrue(preparing(in: app).waitForExistence(timeout: 5),
                      "the progress sheet did not come up\n\(app.debugDescription)")
        app.assertShareSheetShown(timeout: 15)
        app.dismissShareSheet()
        app.assertNoPopover()
    }

    /// The extraction ends just after the progress sheet starts coming up (0.35 s against the
    /// sheet's 0.3 s delay): the sheet must not get stuck, and the preview still comes up.
    func testPreviewEndingAsSheetComesUp() {
        let app = launchSlow("0.35")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        row.tap()
        app.assertPreviewShown(title: "hello")
        XCTAssertFalse(preparing(in: app).exists)
        app.closePreview()
        XCTAssertFalse(preparing(in: app).exists, "the progress sheet came back")
        XCTAssertTrue(row.isHittable)
    }

    func testShareEndingAsSheetComesUp() {
        let app = launchSlow("0.35")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.contextMenuButton("Share", on: row).tap()
        app.assertShareSheetShown()
        XCTAssertFalse(preparing(in: app).exists)
        app.dismissShareSheet()
        XCTAssertFalse(preparing(in: app).exists, "the progress sheet came back")
        XCTAssertTrue(row.isHittable)
        app.assertNoPopover()
    }

    // MARK: - Where previews and shares come from

    /// A file in a pushed folder level previews over that level, which is still there after.
    func testPreviewInPushedFolder() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let docs = app.row("docs")
        app.waitForArchive(docs)
        docs.tap()
        let notes = app.row("docs/notes.txt")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))

        notes.tap()
        app.assertPreviewShown(title: "notes")
        app.closePreview()
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["docs"].exists, "still in the docs level")
    }

    /// A read-only format (ISO) previews and shares like any other.
    func testReadOnlyArchiveSharesAndPreviews() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "iso/basic.iso")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.contextMenuButton("Share", on: row).tap()
        app.assertShareSheetShown()
        app.dismissShareSheet()

        row.tap()
        app.assertPreviewShown(title: "hello")
        app.closePreview()
        XCTAssertTrue(app.extractMenu.isEnabled)
    }

    /// An AES-256 ZIP, once unlocked, previews and shares its encrypted entries.
    func testUnlockedZipPreviewsAndShares() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/aes256.zip")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        app.waitUntilSettled(field)
        field.tap()
        field.typeText("kernir")
        app.buttons["Open"].tap()
        let row = app.row("hello.txt")
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        row.tap()
        app.assertPreviewShown(title: "hello")
        app.closePreview()

        app.contextMenuButton("Share", on: row).tap()
        app.assertShareSheetShown()
        app.dismissShareSheet()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    // MARK: - Rotation

    func testRotatingKeepsPreview() {
        restoreOrientationAfterTest()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        row.tap()
        app.assertPreviewShown(title: "hello")

        XCUIDevice.shared.orientation = .landscapeLeft
        app.assertPreviewShown(title: "hello")
        XCUIDevice.shared.orientation = .portrait
        app.assertPreviewShown(title: "hello")
        app.closePreview()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// The share sheet from a row (a popover on iPad) stays up through rotation.
    func testRotatingKeepsRowShareSheet() {
        restoreOrientationAfterTest()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        app.contextMenuButton("Share", on: row).tap()
        app.assertShareSheetShown()

        XCUIDevice.shared.orientation = .landscapeLeft
        app.assertShareSheetStillShown()
        XCUIDevice.shared.orientation = .portrait
        app.assertShareSheetStillShown()
        app.dismissShareSheet()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// The share sheet from the bottom bar's Share (a popover on iPad) stays up through rotation.
    func testRotatingKeepsToolbarShareSheet() {
        restoreOrientationAfterTest()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        app.startSelecting()
        row.tap()
        let share = app.toolbars.buttons["Share"]
        XCTAssertTrue(share.waitForEnabled(timeout: 5))
        share.tap()
        app.assertShareSheetShown()

        XCUIDevice.shared.orientation = .landscapeLeft
        app.assertShareSheetStillShown()
        XCUIDevice.shared.orientation = .portrait
        app.assertShareSheetStillShown()
        app.dismissShareSheet()
    }
}

extension XCUIApplication {
    /// Long-presses `row` and returns the context menu's `action` button.
    func contextMenuButton(_ action: String, on row: XCUIElement,
                           file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        row.press(forDuration: 1.2)
        let button = collectionViews.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(action) in the context menu", file: file, line: line)
        return button
    }

    /// The preview is up and has loaded the file titled `title`.
    func assertPreviewShown(title: String, timeout: TimeInterval = 10,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(previewController.waitForExistence(timeout: timeout),
                      "the preview did not come up\n\(debugDescription)", file: file, line: line)
        XCTAssertTrue(previewBar(title).waitForExistence(timeout: 10),
                      "the preview does not show \(title)\n\(debugDescription)", file: file, line: line)
    }

    /// Done on the preview: it goes, and stays gone.
    func closePreview(file: StaticString = #filePath, line: UInt = #line) {
        previewDoneButton.tap()
        XCTAssertTrue(previewController.waitForNonExistence(timeout: 5),
                      "the preview did not close\n\(debugDescription)", file: file, line: line)
    }

    /// After rotating: still exactly one share sheet; on a regular-width iPad, still a popover.
    func assertShareSheetStillShown(file: StaticString = #filePath, line: UInt = #line) {
        let sheet = otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the share sheet went away\n\(debugDescription)",
                      file: file, line: line)
        XCTAssertEqual(otherElements.matching(identifier: "ActivityListView").count, 1, debugDescription,
                       file: file, line: line)
        if isRegularWidth {
            XCTAssertTrue(otherElements["PopoverDismissRegion"].exists, "the share sheet is no longer a popover",
                          file: file, line: line)
        }
    }

    /// Nothing is left presented as a popover (an empty one would block the screen).
    func assertNoPopover(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(otherElements["PopoverDismissRegion"].waitForNonExistence(timeout: 5),
                      "a popover is still up\n\(debugDescription)", file: file, line: line)
    }
}
