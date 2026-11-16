import XCTest

/// Hardware keyboard on the sheets: Return is the confirm button (Create, Save, Open) and Escape
/// is Cancel. In the archive: ⌘S saves, ⌘⌫ deletes the selection, ⌘A selects every row, ⌘F
/// searches, ⌘W closes the document and ⌘Z undoes on every level.
@MainActor
final class KeyboardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Escape on the password sheet cancels it, as its Cancel button does: back to the launch browser.
    func testEscapeCancelsPasswordSheet() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/aes256.zip")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        app.waitUntilSettled(app.buttons["Cancel"])

        app.pressEscapeAfterLaunch()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Escape did not cancel\n\(app.debugDescription)")
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.hasArchiveSearchField)
    }

    /// Return on the New Archive sheet is Create: the new, empty archive opens. Each run leaves an
    /// "Untitled" archive where the browser saved it, as `testNewArchiveFromBrowser` does.
    func testReturnCreatesNewArchive() {
        let app = XCUIApplication()
        app.launchSkippingWelcome()
        app.tapNewArchive()
        let create = app.saveOptionsButton("Create")
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(create.isEnabled)

        // Open question, not a confirmed simulator limit. A `return` inside the block would leave
        // only the closure, so the block yields whether the archive opened; if not, the (expected)
        // failure is recorded and the test ends here, before the unguarded checks below.
        let created: Bool = XCTExpectFailure(
            "iOS 27: Return over the launch browser does not reach the New Archive sheet (⌘. does; Return works "
            + "without the browser). Known iOS 27 launch-browser issue. Open: verify on a real device.",
            enabled: Self.isIOS27, strict: false, failingBlock: {
                app.pressReturnAfterLaunch()
                let opened = app.staticTexts["No Items"].waitForExistence(timeout: 15)
                XCTAssertTrue(opened, "Return did not create\n\(app.debugDescription)")
                return opened
            })
        guard created else { return }
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertFalse(create.exists)
    }

    /// Escape on the Save As Copy sheet cancels it: the sheet goes, no file mover comes up, and the
    /// archive stays open as it was.
    func testEscapeCancelsSaveAsCopy() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.tapSaveAsCopy()
        let save = app.saveOptionsButton("Save")
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)

        app.pressEscapeAfterLaunch()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "Escape did not cancel\n\(app.debugDescription)")
        XCTAssertFalse(app.filesPicker.exists, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertTrue(row.exists)
        XCTAssertTrue(app.row("docs").exists)
    }

    // MARK: - Archive commands

    /// ⌘S writes the pending edit, as the bar's Save does: Save leaves the bar.
    func testCommandSSaves() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        app.deleteBySwiping(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        app.assertSaveOnBar()

        app.pressKeyAfterLaunch("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 20), "⌘S did not save\n\(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertFalse(row.exists)
        XCTAssertTrue(app.row("docs").exists)
    }

    /// ⌘⌫ removes the rows selected in Select mode, as the toolbar's Delete does.
    func testCommandDeleteRemovesSelection() throws {
        // The iOS 26.5 simulator never delivers the Delete key to the app, with or without
        // modifiers (checked on the simulator: press log had ⌘ and the ⌘1…⌘5 markers, no Delete, and
        // UIKit never asked canPerformAction(delete:)). The command is covered by the
        // ArchiveCommandsTests and ScreenStateTests delete tests; check ⌘⌫ on a device.
        try XCTSkipIf(true, "Simulator does not deliver the Delete key to the app (seen on the simulator)")
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let hello = app.row("hello.txt")
        let empty = app.row("empty.txt")
        app.waitForArchive(hello)
        app.startSelecting()
        hello.tap()
        empty.tap()
        XCTAssertTrue(app.toolbars.buttons["Delete"].waitForEnabled(timeout: 5), "the rows are selected")

        app.pressKeyAfterLaunch(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5), "⌘⌫ did not delete\n\(app.debugDescription)")
        XCTAssertFalse(empty.exists)
        XCTAssertTrue(app.row("docs").exists)
        app.assertSaveOnBar()
    }

    /// A read-only archive (RAR) can still select every row with ⌘A, but ⌘⌫ removes nothing.
    func testCommandDeleteDoesNothingOnReadOnly() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "third-party/rar/rar5-solid.rar")
        let row = app.row("test.bin")
        app.waitForArchive(row)

        app.pressKeyAfterLaunch("a", modifierFlags: .command)
        let share = app.toolbars.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "⌘A did not start Select mode\n\(app.debugDescription)")
        XCTAssertTrue(share.waitForEnabled(timeout: 5), "⌘A did not select")
        // The simulator drops the Delete key (see testCommandDeleteRemovesSelection), so on a
        // simulator this only guards ⌘A; ScreenStateTests.deleteCommandNeedsEditableSelection
        // covers the read-only rule.
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)
        XCTAssertFalse(row.waitForNonExistence(timeout: 2), "⌘⌫ deleted from a read-only archive")
        for name in ["Undo", "Redo", "Save"] {
            XCTAssertFalse(app.navigationBars.buttons[name].exists, name)
        }
    }

    /// ⌘A turns Select mode on with every row of the folder selected.
    func testCommandASelectsAllRows() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"))
        XCTAssertFalse(app.toolbars.buttons["Share"].exists, "not in Select mode yet")

        app.pressKeyAfterLaunch("a", modifierFlags: .command)
        let delete = app.toolbars.buttons["Delete"]
        if !delete.waitForEnabled(timeout: 3) {
            // The iPhone simulator can drop the first key events after a stretch with no keys,
            // even after pressKeyAfterLaunch's Shift (fix1d: first in the runner, or right after
            // ExtractConflictUITests). ⌘A is idempotent, so a second press tests the same command.
            app.typeKey("a", modifierFlags: .command)
        }
        XCTAssertTrue(delete.waitForEnabled(timeout: 5), "⌘A did not select\n\(app.debugDescription)")
        XCTAssertTrue(app.toolbars.buttons["Share"].exists, "Select mode is on")
        XCTAssertTrue(app.toolbars.buttons["Share"].isEnabled)
        let selected = app.cells.matching(NSPredicate(format: "isSelected == true"))
        XCTAssertEqual(selected.count, 4, "docs, empty-dir, empty.txt and hello.txt\n\(app.debugDescription)")
    }

    /// ⌘F activates the search field: typing filters the rows.
    func testCommandFFocusesSearch() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let hello = app.row("hello.txt")
        app.waitForArchive(hello)

        app.pressKeyAfterLaunch("f", modifierFlags: .command)
        let focused = app.searchFields.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        if !focused.waitForExistence(timeout: 3) {
            // The simulator can drop the first key events after launch, as for ⌘A (fix1e: ⌘F was
            // lost once, then typing found no focus). ⌘F is idempotent: a second press tests the
            // same command.
            app.typeKey("f", modifierFlags: .command)
        }
        app.typeText("hello")
        XCTAssertTrue(app.row("docs").waitForNonExistence(timeout: 5), "⌘F did not focus search\n\(app.debugDescription)")
        XCTAssertTrue(hello.exists)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "hello")
    }

    /// ⌘W closes the document, as the back chevron does: back to the launch browser, and the
    /// document's Save goes with it.
    func testCommandWClosesDocument() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        app.deleteBySwiping(row)
        app.assertSaveOnBar()

        app.pressKeyAfterLaunch("w", modifierFlags: .command)
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10), "⌘W did not close\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.hasArchiveSearchField)
        XCTAssertEqual(app.state, .runningForeground, "⌘W closed the window, not the document")
    }

    /// ⌘Z and ⇧⌘Z reach the document's undo manager from a pushed folder level too.
    func testCommandZInPushedFolder() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let docs = app.row("docs")
        app.waitForArchive(docs)
        docs.tap()
        let notes = app.row("docs/notes.txt")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        app.deleteBySwiping(notes)
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))

        app.pressKeyAfterLaunch("z", modifierFlags: .command)
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "⌘Z did not undo\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5), "⇧⌘Z did not redo")
        app.assertSaveOnBar()
    }
}

extension XCUIApplication {
    /// Escape. On the iOS 26.5 simulator `typeKey(.escape)` never reaches the app, with or without
    /// modifiers (no press at `UIApplication.sendEvent`). ⌘. does: UIKit hands it
    /// to the app as `UIKeyInputEscape` with no modifiers, the very key command that
    /// `.keyboardShortcut(.cancelAction)` registers. Without that shortcut ⌘. leaves the sheet up.
    func pressEscapeAfterLaunch() {
        pressKeyAfterLaunch(".", modifierFlags: .command)
    }

    /// Return. On the iOS 26.5 simulator `typeKey(.return)` ("\r") never reaches the app; "\n"
    /// arrives as the Return key (HID usage 40), which `.keyboardShortcut(.defaultAction)` handles.
    func pressReturnAfterLaunch() {
        pressKeyAfterLaunch("\n", modifierFlags: [])
    }

    /// The simulator can drop the first hardware key event after a launch (see
    /// `testCommandZUndoesAndRedoes`), so a Shift press goes first and `key` is the event under test.
    func pressKeyAfterLaunch(_ key: String, modifierFlags: XCUIElement.KeyModifierFlags = []) {
        typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        typeKey(key, modifierFlags: modifierFlags)
    }
}
