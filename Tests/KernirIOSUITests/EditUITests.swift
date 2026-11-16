import XCTest

@MainActor
final class EditUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSwipeDeleteShowsSave() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        XCTAssertFalse(app.buttons["Save"].exists)

        app.deleteBySwiping(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))

        app.navigationBars.buttons["Undo"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
    }

    func testAddMenuOffersFilesAndPhotos() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"))

        app.toolbars.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["Photos…"].waitForExistence(timeout: 5))
        let files = app.buttons["Choose Files…"]
        XCTAssertTrue(files.exists)
        files.tap()
        // The system file picker comes up.
        let picker = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
    }

    func testContextMenuDeletes() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        row.press(forDuration: 1.2)
        let delete = app.collectionViews.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        for action in ["Preview", "Extract To…", "Share"] {
            XCTAssertTrue(app.collectionViews.buttons[action].isEnabled, action)
        }
        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
    }

    /// Rename typed in and cancelled changes nothing, Undo included (the alert's field registers no
    /// undo on the document); Add > New Folder, named in its alert; Rename from a file's context menu;
    /// Save. The reopened archive (the fixture hook's writable copy in Documents) lists both new names.
    func testNewFolderAndRenameSaveAndReopen() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let hello = app.row("hello.txt")
        app.waitForArchive(hello)

        hello.press(forDuration: 1.2)
        let rename = app.collectionViews.buttons["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), app.debugDescription)
        rename.tap()
        let renameAlert = app.alerts["Rename"].firstMatch
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5), app.debugDescription)
        let field = renameAlert.textFields.firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText("draft")
        renameAlert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(renameAlert.waitForNonExistence(timeout: 5), "the Rename alert stayed up")
        XCTAssertTrue(hello.exists)
        let undo = app.navigationBars.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is not on the navigation bar")
        XCTAssertFalse(undo.isEnabled, "the Rename alert's typing reached the document's undo")
        XCTAssertFalse(app.buttons["Save"].exists, "Rename then Cancel left a change to save")

        app.toolbars.buttons["Add"].tap()
        let newFolder = app.buttons["New Folder"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5), app.debugDescription)
        newFolder.tap()
        app.answerNameAlert("New Folder", with: "Stuff")
        let stuff = app.row("Stuff")
        XCTAssertTrue(stuff.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.row("untitled folder").exists)

        hello.press(forDuration: 1.2)
        XCTAssertTrue(rename.waitForExistence(timeout: 5), app.debugDescription)
        rename.tap()
        // A refused name says why; after OK the Rename alert comes back with it, to be fixed.
        app.answerNameAlert("Rename", with: "a/b")
        let refused = app.alerts.matching(NSPredicate(format: "label CONTAINS %@", "rename “hello.txt”")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 5), app.debugDescription)
        refused.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(refused.waitForNonExistence(timeout: 5), "the error alert stayed up")
        let renameAgain = app.alerts["Rename"].firstMatch
        XCTAssertTrue(renameAgain.waitForExistence(timeout: 5),
                      "the Rename alert did not come back after the refused name\n\(app.debugDescription)")
        XCTAssertEqual(renameAgain.textFields.firstMatch.value as? String, "a/b", renameAgain.debugDescription)
        app.answerNameAlert("Rename", with: "greeting.txt")
        let greeting = app.row("greeting.txt")
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(hello.exists)

        app.assertSaveOnBar()
        let save = app.navigationBars.buttons["Save"].firstMatch
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 20), "the save did not finish")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)

        // Reopen from the launch browser; iOS 27's empty browser is expected, as in MacMetadataUITests.
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("lists the app's folder as empty") }
        options.isEnabled = Self.isIOS27
        options.isStrict = false
        let reopened = XCTExpectFailure("iOS 27: launch browser lists Kernir's folder as empty. "
                                        + "Known iOS 27 launch-browser issue.",
                                        options: options) { () -> Bool in
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10), app.debugDescription)
            app.pickInLaunchBrowser("deflate.zip")
            if app.staticTexts["Folder is Empty"].firstMatch.exists { return false }
            app.waitForArchive(app.row("docs"))
            return true
        }
        guard reopened else { return }
        XCTAssertTrue(greeting.exists, "the renamed file is not in the saved archive\n\(app.debugDescription)")
        XCTAssertTrue(stuff.exists, "the new folder is not in the saved archive\n\(app.debugDescription)")
        XCTAssertFalse(hello.exists, "the old name is back after the save")
        XCTAssertFalse(app.row("untitled folder").exists)
    }

    /// A read-only archive offers no swipe-to-delete: RAR is only ever read.
    func testReadOnlyRowHasNoSwipeDelete() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "third-party/rar/rar5-solid.rar")
        let row = app.row("test.bin")
        app.waitForArchive(row)

        row.swipeLeft()
        XCTAssertFalse(app.collectionViews.buttons["Delete"].waitForExistence(timeout: 2))
        XCTAssertTrue(row.exists)
        // Nothing to undo or save: the bar has no Undo, Redo or Save.
        for name in ["Undo", "Redo", "Save"] {
            XCTAssertFalse(app.navigationBars.buttons[name].exists, name)
        }
    }

    /// An encrypted 7z asks for its password; once unlocked it is editable, and the
    /// save repacks it with AES-256.
    func testUnlockedEncrypted7zSwipeDeleteSaves() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "7z/encrypted-data.7z")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        app.waitUntilSettled(field)
        field.tap()
        field.typeText("kernir")
        app.buttons["Open"].tap()
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        XCTAssertFalse(field.exists)
        XCTAssertFalse(app.buttons["Save"].exists)

        app.deleteBySwiping(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        XCTAssertTrue(save.waitForNonExistence(timeout: 20), "the save did not finish")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertFalse(field.exists, "the saved archive asked for its password again")
        XCTAssertTrue(app.row("docs").exists)
        XCTAssertFalse(row.exists)
    }

    /// In Select mode a folder row is selected like any other row, not opened.
    func testSelectModeTapSelectsFolder() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let docs = app.row("docs")
        app.waitForArchive(docs)

        app.startSelecting()
        docs.tap()
        XCTAssertTrue(app.toolbars.buttons["Delete"].waitForEnabled(timeout: 5), "the folder is selected")
        XCTAssertFalse(app.row("docs/notes.txt").exists, "the folder was not opened")
        XCTAssertFalse(app.navigationBars["docs"].exists)

        app.toolbars.buttons["Delete"].tap()
        XCTAssertTrue(docs.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.row("hello.txt").exists)
        // The subtitle grows to "3 items · 15 bytes"; Save must stay on the bar, not in More.
        app.assertSaveOnBar()

        app.undoFromBar()
        XCTAssertTrue(docs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
    }

    /// Select and Save a Copy… sit in the same place at the root and at a pushed level: on the
    /// bar itself on a regular-width iPad, in "More" on iPhone (lead finding 3x).
    func testSelectPlacementSameOnEveryLevel() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let docs = app.row("docs")
        app.waitForArchive(docs)
        app.assertCenterItemsPlaced(level: "Root")

        docs.tap()
        XCTAssertTrue(app.row("docs/notes.txt").waitForExistence(timeout: 5))
        app.assertCenterItemsPlaced(level: "docs")
    }

    /// A pushed folder level shows Save on its own bar too.
    func testSaveOnBarInPushedFolder() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let docs = app.row("docs")
        app.waitForArchive(docs)
        docs.tap()
        let notes = app.row("docs/notes.txt")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))

        app.deleteBySwiping(notes)
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))
        app.assertSaveOnBar()

        app.undoFromBar()
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        app.navigationBars.buttons["Redo"].firstMatch.tap()
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))
        app.assertSaveOnBar()

        // Back at the root, its own Save shows the same pending edit.
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(docs.waitForExistence(timeout: 5))
        app.assertSaveOnBar()
    }

    /// A pushed level keeps Undo on its own bar, one tap away, not in "More".
    func testUndoOnBarInPushedFolder() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let docs = app.row("docs")
        app.waitForArchive(docs)
        docs.tap()
        let notes = app.row("docs/notes.txt")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))

        app.deleteBySwiping(notes)
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))
        let undo = app.navigationBars.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is not on the navigation bar")
        XCTAssertTrue(undo.isHittable, "Undo is not tappable on the bar")
        XCTAssertTrue(app.navigationBars.buttons["Redo"].firstMatch.isHittable)
        app.assertSaveOnBar()

        undo.tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
    }

    /// Undo, Redo and Save stay on the bar at the root and at a pushed level, with and without
    /// edits. Screenshots and the items' frames are kept for review.
    func testEditItemsStayOnBar() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        app.recordBar("Root, no changes", expecting: ["Undo", "Redo"])
        XCTAssertFalse(app.navigationBars.buttons["Save"].exists)

        app.deleteBySwiping(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        app.recordBar("Root, with changes", expecting: ["Undo", "Redo", "Save"])

        app.row("docs").tap()
        let notes = app.row("docs/notes.txt")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        app.recordBar("Pushed, pending root change", expecting: ["Undo", "Redo", "Save"])
        app.deleteBySwiping(notes)
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))
        app.recordBar("Pushed, with changes", expecting: ["Undo", "Redo", "Save"])
    }

    /// ⌘Z and ⇧⌘Z from a hardware keyboard undo and redo through the document's undo manager.
    func testCommandZUndoesAndRedoes() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        // Depending on the simulator's keyboard state, it drops the first hardware key event
        // after a launch (a lone ⌘Z, or ⇧⌘Z after a tap on the bar's Undo, did nothing; the
        // second press worked). A Shift press first makes ⌘Z the event under test.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        app.deleteBySwiping(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "⌘Z did not undo")
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "⇧⌘Z did not redo")
        app.assertSaveOnBar()
    }

    /// Closing the document takes its Save button away with it.
    func testClosingLeavesNoSaveOnBrowser() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        app.deleteBySwiping(row)
        app.assertSaveOnBar()

        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10))
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
    }

    /// `-KernirFailSave` makes every write fail. The alert must still come up although the
    /// progress sheet is dismissing at that moment (SwiftUI can drop an alert presented then).
    func testFailedSaveShowsAlert() {
        let app = XCUIApplication()
        app.launchArguments += ["-KernirFailSave"]
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.deleteBySwiping(row)
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        // The failing write takes three seconds, so the progress sheet is fully up when it fails.
        let saving = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Saving")).firstMatch
        XCTAssertTrue(saving.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "Save is disabled while saving")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.label.hasPrefix("Couldn't save"), alert.label)
        XCTAssertFalse(saving.exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        // The edit is kept, still unsaved.
        XCTAssertFalse(row.exists)
        XCTAssertTrue(save.exists)
    }

    // MARK: - Preview, extract, share

    func testTapFileOpensPreview() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        row.tap()
        let preview = app.previewController
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "the preview did not come up")
        // A one-shot .exists right after the preview view appeared missed the bar on iOS 27.2.
        XCTAssertTrue(app.previewBar("hello").waitForExistence(timeout: 5),
                      "the preview shows hello.txt\n\(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.previewDoneButton.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// An encrypted-data 7z asks for its password; once unlocked, its encrypted
    /// entries preview with no alert.
    func testUnlockedEncrypted7zPreviews() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "7z/encrypted-data.7z")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        app.waitUntilSettled(field)
        field.tap()
        field.typeText("kernir")
        app.buttons["Open"].tap()
        let row = app.row("hello.txt")
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        row.tap()
        let preview = app.previewController
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "the preview did not come up")
        // A one-shot .exists right after the preview view appeared missed the bar on iOS 27.2.
        XCTAssertTrue(app.previewBar("hello").waitForExistence(timeout: 5),
                      "the preview shows hello.txt\n\(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.previewDoneButton.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// An encrypted-data RAR lists, but previewing an encrypted entry says encrypted
    /// RAR isn't supported, and never asks for a password.
    func testEncryptedRarPreviewShowsAlert() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "third-party/rar/rar5-encrypted-mixed.rar")
        let row = app.row("b.txt")
        app.waitForArchive(row)

        row.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let text = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "aren't supported yet"))
        XCTAssertTrue(text.firstMatch.exists)
        XCTAssertFalse(app.secureTextFields["Password"].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.previewController.exists)
    }

    func testContextMenuSharesFile() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        row.press(forDuration: 1.2)
        let share = app.collectionViews.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        app.assertShareSheetShown()
        app.dismissShareSheet()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// In Select mode the toolbar's Share shares the selection.
    func testSelectModeSharesSelection() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.startSelecting()
        let share = app.toolbars.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertFalse(share.isEnabled, "nothing selected yet")
        row.tap()
        XCTAssertTrue(share.waitForEnabled(timeout: 5))
        share.tap()
        app.assertShareSheetShown()
        app.dismissShareSheet()
    }

    /// Extract asks for a destination folder: the one Files picker serves Add (files) and
    /// Extract (a folder), so after Add's picker it must come back in folder mode. Only the
    /// folder picker offers New Folder.
    func testExtractAsksForFolder() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"))

        app.toolbars.buttons["Add"].tap()
        let files = app.buttons["Choose Files…"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertFalse(app.pickerOffersNewFolder(), "Add's picker picks files\n\(app.debugDescription)")
        app.cancelPicker()

        app.extractTo()
        XCTAssertTrue(app.pickerOffersNewFolder(), "Extract's picker picks a folder\n\(app.debugDescription)")
        app.cancelPicker()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    /// X1: extracting into a folder that already holds the items asks first, one conflict at a
    /// time (Finder's Keep Both / Replace / Stop, "for All" while 2+ remain), and Stop writes
    /// nothing. deflate.zip has 4 top-level items, so the second extraction meets 4 conflicts.
    /// Each question is an alert of its own: "2 of 4" and "3 of 4" only show if
    /// SwiftUI presents the alert again after each answer.
    /// The destination is the DEBUG-only `-KernirExtractDestination` hook (no Files picker): a
    /// folder this runner makes in its temporary directory, reads back and removes.
    func testExtractTwiceAsksBeforeReplacing() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("X1-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let hello = folder.appendingPathComponent("hello.txt")
        let archiveHello = Data("Hello, Kernir!\n".utf8)
        let mine = Data("mine\n".utf8)

        let app = XCUIApplication()
        app.launchArguments += ["-KernirExtractDestination", folder.path]
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"))
        let items: Set = ["docs", "empty-dir", "empty.txt", "hello.txt"]
        let ask = "Do you want to replace it with the one you’re extracting?"
        let titlePrefix = "An item named “"
        let titleSuffix = "” already exists in “\(folder.lastPathComponent)”."

        // First time: into the empty folder. Nothing to ask.
        app.extractTo()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 4), app.debugDescription)
        waitForListing(of: folder, items)
        XCTAssertEqual(try Data(contentsOf: hello), archiveHello)
        // Mine now, so a Replace shows in the bytes.
        try mine.write(to: hello)

        // Second time, same folder: the four items are there, and the alert asks before anything
        // is written. Stop: nothing changes and nothing more is asked.
        app.extractTo()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no conflict alert\n\(app.debugDescription)")
        XCTAssertTrue(alert.label.hasPrefix(titlePrefix) && alert.label.hasSuffix(titleSuffix), alert.label)
        XCTAssertTrue(alert.staticTexts[ask + "\n1 of 4"].exists, alert.debugDescription)
        for name in ["Keep Both", "Replace", "Keep Both for All", "Replace for All", "Stop"] {
            XCTAssertTrue(alert.buttons[name].exists, "\(name)\n\(alert.debugDescription)")
        }
        alert.buttons["Stop"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3), "an alert after Stop")
        XCTAssertEqual(listing(of: folder), items, "Stop wrote something")
        XCTAssertEqual(try Data(contentsOf: hello), mine, "Stop changed hello.txt")

        // Again, one question at a time ("2 of 4", "3 of 4" each a new alert): Replace for
        // hello.txt, Keep Both for the others.
        app.extractTo()
        var replaced = false
        for k in 1...4 {
            // The new question's line first, so the name is read from its alert, not the last one.
            // A snapshot's label has a space where the message has its line break, so no `==`.
            let line = NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", ask, "\(k) of 4")
            let text = app.alerts.staticTexts.matching(line).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 10), "no question \(k) of 4\n\(app.debugDescription)")
            let question = app.alerts.containing(line).firstMatch
            let title = question.label
            XCTAssertTrue(title.hasPrefix(titlePrefix) && title.hasSuffix(titleSuffix), title)
            let name = String(title.dropFirst(titlePrefix.count).dropLast(titleSuffix.count))
            XCTAssertTrue(items.contains(name), "asked about \(name)")
            XCTAssertEqual(question.buttons["Keep Both for All"].exists, k < 4, question.debugDescription)
            if name == "hello.txt" {
                question.buttons["Replace"].tap()
                replaced = true
            } else {
                question.buttons["Keep Both"].tap()
            }
            XCTAssertTrue(text.waitForNonExistence(timeout: 5), "question \(k) stayed up\n\(app.debugDescription)")
        }
        XCTAssertTrue(replaced, "never asked about hello.txt")
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 4), app.debugDescription)

        // Copies of the three kept, the archive's hello.txt in place of mine.
        waitForListing(of: folder, items.union(["docs 2", "empty-dir 2", "empty 2.txt"]))
        XCTAssertEqual(try Data(contentsOf: hello), archiveHello, "Replace did not write the archive's bytes")
        XCTAssertEqual(listing(of: folder.appendingPathComponent("docs 2")), ["nested", "notes.txt", "readme.md"])
    }

    /// The names in `folder`, hidden ones too, so a leftover `.kernir-*` staging folder shows.
    private func listing(of folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// Waits until `folder` lists exactly `names` (the extraction has finished and its staging is gone).
    private func waitForListing(of folder: URL, _ names: Set<String>, timeout: TimeInterval = 20,
                                file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, listing(of: folder) != names {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertEqual(listing(of: folder), names, "the folder after extracting", file: file, line: line)
    }
}

extension XCUIApplication {
    /// The preview (QLPreviewController's view).
    var previewController: XCUIElement {
        otherElements["QLPreviewControllerView"]
    }

    /// The preview's bar for the file titled `title`: its identifier is the name without the
    /// extension ("hello") on some runtimes and the whole name ("hello.txt") on the iOS 27 sim.
    func previewBar(_ title: String) -> XCUIElement {
        previewController.navigationBars.matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@",
                                                              title, title + ".")).firstMatch
    }

    /// The preview's Done button (an "xmark" on iOS 26).
    var previewDoneButton: XCUIElement {
        previewController.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
    }

    /// The system share sheet, once; on a regular-width iPad, in a popover.
    func assertShareSheetShown(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout), "the share sheet did not come up\n\(debugDescription)",
                      file: file, line: line)
        XCTAssertEqual(otherElements.matching(identifier: "ActivityListView").count, 1, debugDescription,
                       file: file, line: line)
        if isRegularWidth {
            XCTAssertTrue(otherElements["PopoverDismissRegion"].exists, "the share sheet is not a popover",
                          file: file, line: line)
        }
        // Kept for review: where the sheet or popover points.
        let shot = XCTAttachment(screenshot: screenshot())
        shot.name = "Share sheet"
        shot.lifetime = .keepAlways
        XCTContext.runActivity(named: "Share sheet") { $0.add(shot) }
    }

    /// Closes the share sheet without sharing: its Close button, or (in an iPad popover, which
    /// has none) a tap outside it.
    func dismissShareSheet(file: StaticString = #filePath, line: UInt = #line) {
        let close = buttons["header.closeButton"]
        if close.exists {
            close.tap()
        } else {
            otherElements["PopoverDismissRegion"].firstMatch.tap()
        }
        XCTAssertTrue(otherElements["ActivityListView"].waitForNonExistence(timeout: 5), file: file, line: line)
    }
}

extension XCUIApplication {
    /// The toolbar's Extract menu (Extract Here, Extract To…).
    var extractMenu: XCUIElement {
        toolbars.buttons["Extract"]
    }

    /// Opens the toolbar's Extract menu and taps Extract To…: the Files picker comes up (or,
    /// with the DEBUG `-KernirExtractDestination` hook, the extraction goes there).
    func extractTo(file: StaticString = #filePath, line: UInt = #line) {
        let menu = extractMenu
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no Extract menu on the bar\n\(debugDescription)",
                      file: file, line: line)
        menu.tap()
        let item = buttons["Extract To…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Extract To… in the Extract menu\n\(debugDescription)",
                      file: file, line: line)
        item.tap()
    }

    /// The Files picker's bar.
    var filesPicker: XCUIElement {
        navigationBars["FullDocumentManagerViewControllerNavigationBar"]
    }

    /// Goes to On My iPhone / On My iPad in the open Files picker and says whether it offers New
    /// Folder there, which only the folder picker does: on the bar on iPad, in its More menu on
    /// iPhone. The menu is closed again.
    func pickerOffersNewFolder(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let picker = filesPicker
        goToDeviceInPicker(file: file, line: line)
        if picker.buttons["New Folder"].waitForExistence(timeout: 2) { return true }
        let menu = pickerMenuButton
        XCTAssertTrue(menu.exists, "no menu on the picker's bar\n\(debugDescription)", file: file, line: line)
        menu.tap()
        XCTAssertTrue(buttons["List"].waitForExistence(timeout: 5), "the menu did not open\n\(debugDescription)",
                      file: file, line: line)
        let offered = buttons["New Folder"].exists
        closePickerMenu(file: file, line: line)
        return offered
    }

    /// The menu on the picker's bar (iPhone keeps New Folder in it). Its identifier varies by
    /// release: "DOC.itemCollectionMenuButton…", "OverflowBarButtonItem", and on iOS 27.2
    /// "TopOverflowBarButtonItem" (iPhone 18 Pro Max run).
    private var pickerMenuButton: XCUIElement {
        filesPicker.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ OR identifier IN %@", "DOC.itemCollectionMenuButton",
            ["OverflowBarButtonItem", "TopOverflowBarButtonItem"])).firstMatch
    }

    /// A tap just left of the open menu closes it (the bar under it can't be reached).
    private func closePickerMenu(file: StaticString = #filePath, line: UInt = #line) {
        let list = buttons["List"].frame
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.minX - 30, dy: list.midY)).tap()
        XCTAssertTrue(buttons["List"].waitForNonExistence(timeout: 5), "the menu did not close", file: file, line: line)
    }

    /// Opens On My iPhone / On My iPad in the open Files picker.
    func goToDeviceInPicker(file: StaticString = #filePath, line: UInt = #line) {
        let picker = filesPicker
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the Files picker did not come up", file: file, line: line)
        // iPad lists the locations in its sidebar; iPhone under its Browse tab, maybe a few levels up.
        let device = cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sidebar.item.On My")).firstMatch
        var tries = 0
        while !device.waitForExistence(timeout: 2), tries < 4 {
            tries += 1
            let back = picker.buttons["BackButton"]
            if back.exists {
                back.tap()
            } else {
                buttons["Browse"].firstMatch.tap()
            }
        }
        XCTAssertTrue(device.exists, "no On My device location\n\(debugDescription)", file: file, line: line)
        device.tap()
        XCTAssertTrue(collectionViews["File View"].waitForExistence(timeout: 5),
                      "the location did not open\n\(debugDescription)", file: file, line: line)
    }

    /// Closes the Files picker without picking: Cancel where there is one, else a swipe down.
    func cancelPicker(file: StaticString = #filePath, line: UInt = #line) {
        let picker = filesPicker
        let cancel = buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2), cancel.isHittable {
            cancel.tap()
        } else {
            picker.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "the Files picker is still up", file: file, line: line)
    }

    /// Swipes `row` left and taps its Delete action.
    func deleteBySwiping(_ row: XCUIElement) {
        row.swipeLeft()
        let delete = collectionViews.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
    }

    /// Answers Rename's or New Folder's name alert (titled `title`): replaces the name it starts
    /// with by `name` and taps the alert's Save.
    func answerNameAlert(_ title: String, with name: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let alert = alerts[title].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no \(title) alert\n\(debugDescription)", file: file, line: line)
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.exists, alert.debugDescription, file: file, line: line)
        let old = field.value as? String ?? ""
        // A tap at the field's end puts the caret after the name, so the deletes take all of it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name)
        XCTAssertEqual(field.value as? String, name, alert.debugDescription, file: file, line: line)
        alert.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "the \(title) alert stayed up", file: file, line: line)
    }

    /// Save is a button on the navigation bar itself, tappable without opening "More".
    func assertSaveOnBar(file: StaticString = #filePath, line: UInt = #line) {
        let save = navigationBars.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save is not on the navigation bar", file: file, line: line)
        XCTAssertTrue(save.isHittable, file: file, line: line)
    }

    /// Taps Undo, which is pinned to the navigation bar itself: never in its "More" menu.
    func undoFromBar(file: StaticString = #filePath, line: UInt = #line) {
        let undo = navigationBars.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is not on the navigation bar", file: file, line: line)
        XCTAssertTrue(undo.isHittable, "Undo is not tappable on the bar", file: file, line: line)
        undo.tap()
    }

    /// Checks that `names` are tappable on the navigation bar, and keeps a screenshot and the
    /// bar items' frames (in the activity's name) for review.
    func recordBar(_ title: String, expecting names: [String],
                   file: StaticString = #filePath, line: UInt = #line) {
        let bar = navigationBars.firstMatch
        for name in names {
            let item = bar.buttons[name].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title): \(name) is not on the bar",
                          file: file, line: line)
            XCTAssertTrue(item.isHittable, "\(title): \(name) is not tappable", file: file, line: line)
        }
        let frames = bar.buttons.allElementsBoundByIndex.map { "\($0.label) \($0.frame)" }
        let screenshot = XCUIScreen.main.screenshot()
        // Two pixel rows from just left of Undo to the bar's end, through the items' middle and
        // just above their bottom edge: where the glass capsules start and end, and their tint.
        var scan = ""
        if names.contains("Undo") {
            let undo = bar.buttons["Undo"].firstMatch.frame
            let rows = [undo.midY, undo.maxY - 3].map {
                screenshot.scanline(y: $0, from: undo.minX - 16, to: frame.maxX, screenWidth: frame.width)
            }
            scan = " | scan from x=\(undo.minX - 16) \(rows.joined(separator: " / "))"
        }
        XCTContext.runActivity(named: "\(title) | bar \(bar.frame) | \(frames.joined(separator: "; "))\(scan)") {
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = title
            shot.lifetime = .keepAlways
            $0.add(shot)
        }
    }

    /// Select lives in the navigation bar's overflow menu.
    func startSelecting() {
        let select = buttons["Select"]
        if !select.exists {
            navigationBars.buttons["More"].firstMatch.tap()
        }
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
    }
}

extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)],
                                timeout: timeout) == .completed
    }
}

extension XCUIScreenshot {
    /// One character per 2 pt along the row at `y` (points), from `minX` to `maxX`: "T" for a
    /// tinted (saturated) pixel, else its darkness from "." (white) through "-", "=", "+" to "#".
    func scanline(y: CGFloat, from minX: CGFloat, to maxX: CGFloat, screenWidth: CGFloat) -> String {
        guard let cg = image.cgImage else { return "?" }
        let scale = CGFloat(cg.width) / screenWidth
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return "?" }
        let py = min(height - 1, max(0, Int(y * scale)))
        var out = ""
        for x in stride(from: max(0, minX), to: maxX, by: 2) {
            let px = min(width - 1, Int(x * scale))
            let i = (py * width + px) * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let high = max(r, g, b), low = min(r, g, b)
            let darkness = 255 - (r + g + b) / 3
            out += high - low > 60 ? "T"
                : darkness < 3 ? "." : darkness < 8 ? "-" : darkness < 16 ? "=" : darkness < 40 ? "+" : "#"
        }
        return out
    }
}
