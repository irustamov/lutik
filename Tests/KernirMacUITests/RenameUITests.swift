import XCTest

/// Rename (Return, File > Rename, the row's context menu) and New Folder (⇧⌘N) in the archive window,
/// with the Name cell's inline field. Every test works on a copy of `zip/deflate.zip`
/// (docs/, empty-dir/, empty.txt, hello.txt at the top level).
final class RenameUITests: KernirMacUITestCase {
    /// The Name cell's field: only one row shows it at a time.
    private var field: XCUIElement { app.archiveOutline.textFields.firstMatch }

    override func setUp() async throws {
        try await super.setUp()
        // A fixed frame centred on the menu-bar display: the default cascade put the window on the build machine's
        // second display, under another app's floating window that took the row clicks (run 1).
        app.launchArguments += ["-KernirWindowFrame", "900x560"]
    }

    /// Context menu > Rename shows the field with focus and the base name selected: typing at once replaces
    /// "hello" and keeps ".txt". Return commits, as one "Rename" undo step.
    func testContextMenuRenameAndReturnCommits() throws {
        try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        nameCenter(of: hello).rightClick()
        // File > Rename is a menu item too, never hittable while the menu bar is closed: the context menu's is.
        let renames = app.menuItems.matching(NSPredicate(format: "title == %@", "Rename"))
        var rename: XCUIElement?
        let deadline = Date().addingTimeInterval(5)
        while rename == nil, Date() < deadline {
            rename = renames.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            if rename == nil { Thread.sleep(forTimeInterval: 0.3) }
        }
        try XCTUnwrap(rename, "no Rename in the row's context menu\n\(app.debugDescription)").click()

        XCTAssertTrue(field.waitForExistence(timeout: 5), "no name field\n\(app.debugDescription)")
        XCTAssertEqual(field.value as? String, "hello.txt")
        // No click into the field: focus on appear and the preselected base name, or the typing goes elsewhere.
        app.typeText("greeting")
        note("field after typing: \(String(reflecting: field.value as? String))")
        XCTAssertEqual(field.value as? String, "greeting.txt", "the base name was not preselected, or the field had no focus")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Return left the field showing")
        XCTAssertTrue(app.row("greeting.txt").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.row("hello.txt").exists)
        XCTAssertTrue(app.row("greeting.txt").isSelected, "the renamed row lost the selection")
        XCTAssertEqual(undoMenuTitle(), "Undo Rename")
    }

    /// Return on a selected folder row starts the rename and does not open (expand) it; Esc
    /// cancels what was typed; double-click still opens the folder.
    func testReturnRenamesEscCancelsDoubleClickOpens() throws {
        try openFixture("zip/deflate.zip")
        let docs = app.row("docs")
        waitForArchive(docs)
        docs.select()
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(field.waitForExistence(timeout: 5), "Return showed no name field\n\(app.debugDescription)")
        XCTAssertEqual(field.value as? String, "docs")
        XCTAssertFalse(app.row("readme.md").exists, "Return opened (expanded) the folder as well")
        // A folder's whole name is selected: typing replaces all of it.
        app.typeText("papers")
        XCTAssertEqual(field.value as? String, "papers")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Esc left the field showing\n\(app.debugDescription)")
        XCTAssertTrue(app.row("docs").waitForExistence(timeout: 5), "Esc did not keep the old name\n\(app.debugDescription)")
        XCTAssertFalse(app.row("papers").exists, "Esc committed the typed name")
        XCTAssertFalse(app.row("readme.md").exists, "Esc opened the folder")
        // "Undo Typing" would mean the field's typing reached the document's undo manager.
        XCTAssertEqual(undoMenuTitle(), "Undo", "Esc left an undo step (Rename or Typing) on the document")

        // Double-click opens the folder in place, with no name field.
        nameCenter(of: app.row("docs")).doubleClick()
        XCTAssertTrue(app.row("readme.md").waitForExistence(timeout: 5), "double-click did not open the folder\n\(app.debugDescription)")
        XCTAssertFalse(field.exists, "double-click showed the name field")
    }

    /// While the field shows, Space types a space (no Quick Look) and letters type into the field (no
    /// type-select: "d" would select docs); the selection stays on the row being renamed.
    func testSpaceAndTypeSelectAreInertWhileEditing() throws {
        try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        let windows = app.windows.count
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Return showed no name field\n\(app.debugDescription)")

        app.typeKey("d", modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        app.typeKey("e", modifierFlags: [])
        note("field after d, Space, e: \(String(reflecting: field.value as? String))")
        XCTAssertEqual(field.value as? String, "d e.txt", "keys went somewhere other than the field")
        XCTAssertFalse(app.row("docs").isSelected, "type-select moved the selection to docs")
        XCTAssertEqual(app.windows.count, windows, "Space opened a preview while renaming")
        XCTAssertFalse(app.children(matching: .any).matching(identifier: "preview").firstMatch.exists,
                       "Space opened Quick Look while renaming")
        XCTAssertTrue(field.exists, "a key ended the rename")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 5), "Esc did not keep the old name")
        XCTAssertTrue(app.row("hello.txt").isSelected, "the selection left the row")
    }

    /// ⇧⌘N + a name, then a rename; ⌘Z twice takes both back; done again, ⌘S and a reopen from disk keep the names.
    func testNewFolderRenameUndoSaveReopen() throws {
        let archive = try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))
        let before = try Self.sha256(of: archive)

        makeFolderAndRename()
        XCTAssertEqual(undoMenuTitle(), "Undo Rename")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 5), "the first ⌘Z did not undo the rename")
        XCTAssertFalse(app.row("greeting.txt").exists)
        XCTAssertTrue(app.row("Photos").exists, "the first ⌘Z undid the new folder as well")
        // As in Finder, naming the new folder is its own Rename step after New Folder: the second ⌘Z puts
        // "untitled folder" back, and a third takes the folder away.
        app.typeKey("z", modifierFlags: .command)
        if app.row("untitled folder").waitForExistence(timeout: 3) {
            note("second ⌘Z left \(app.visibleRowNames); Edit > Undo: \(undoMenuTitle())")
            app.typeKey("z", modifierFlags: .command)
        }
        XCTAssertTrue(app.row("Photos").waitForNonExistence(timeout: 5), "⌘Z did not undo the folder\n\(app.visibleRowNames)")
        XCTAssertFalse(app.row("untitled folder").exists, "⌘Z left the untitled folder\n\(app.visibleRowNames)")
        XCTAssertEqual(Set(app.visibleRowNames), ["docs", "empty-dir", "empty.txt", "hello.txt"])

        makeFolderAndRename()
        app.typeKey("s", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, try Self.sha256(of: archive) == before {
            XCTAssertNotEqual(app.state, .notRunning, "the app crashed while saving")
            _ = app.text(containing: "could not be saved").waitForExistence(timeout: 0.5)
        }
        XCTAssertNotEqual(try Self.sha256(of: archive), before, "the save did not write the archive")
        XCTAssertFalse(app.text(containing: "could not be saved").exists, app.debugDescription)

        open(archive)
        waitForArchive(app.row("greeting.txt"))
        XCTAssertEqual(Set(app.visibleRowNames), ["docs", "empty-dir", "empty.txt", "greeting.txt", "Photos"])
    }

    /// ⌘S while the New Folder field shows, with a name typed: the save's sheet takes the focus and the commit
    /// waits for it; once the save ends the field has the focus again, and Return commits the typed name
    /// (the field stayed unfocused, with the rename still on).
    func testReturnCommitsAfterASaveDuringTheRename() throws {
        let archive = try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))
        let before = try Self.sha256(of: archive)

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⇧⌘N showed no name field\n\(app.debugDescription)")
        // The field's title shows as its placeholder when emptied (the "Name" string's catalog comment says so).
        note("field placeholder: \(String(reflecting: field.placeholderValue))")
        app.typeText("Photos")
        XCTAssertEqual(field.value as? String, "Photos")
        app.typeKey("s", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, try Self.sha256(of: archive) == before {
            XCTAssertNotEqual(app.state, .notRunning, "the app crashed while saving")
            _ = app.text(containing: "could not be saved").waitForExistence(timeout: 0.5)
        }
        XCTAssertNotEqual(try Self.sha256(of: archive), before, "the save did not write the archive")
        // The save's sheet goes after the file is written: wait for it before typing.
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10),
                      "the progress sheet stayed\n\(app.debugDescription)")
        XCTAssertTrue(field.exists, "the save ended the name field\n\(app.visibleRowNames)")
        XCTAssertEqual(field.value as? String, "Photos", "the save lost the typed name")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Return after the save left the field showing (no focus)")
        XCTAssertTrue(app.row("Photos").waitForExistence(timeout: 5), "\(app.visibleRowNames)")
        XCTAssertFalse(app.row("untitled folder").exists, "\(app.visibleRowNames)")
        XCTAssertEqual(undoMenuTitle(), "Undo Rename")
    }

    /// ⇧⌘N in a folder while the search hides the new folder ("untitled folder" matches no search): the search
    /// clears, the folder stays open, and the new folder shows with its field.
    func testNewFolderUnderASearchClearsTheSearch() throws {
        try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))
        let search = app.searchField
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("readme")
        XCTAssertTrue(app.row("readme.md").waitForExistence(timeout: 5))
        XCTAssertTrue(app.row("hello.txt").waitForNonExistence(timeout: 5))

        // docs was closed before the search: the search opened it, and clearing it must not close it again.
        app.row("docs").select()
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⇧⌘N under a search showed no name field\n\(app.visibleRowNames)")
        XCTAssertEqual(field.value as? String, "untitled folder")
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 5), "the search did not clear\n\(app.visibleRowNames)")
        app.typeText("Photos")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.row("Photos").waitForExistence(timeout: 5), "\(app.visibleRowNames)")
        XCTAssertTrue(app.row("readme.md").exists, "docs closed under the new folder\n\(app.visibleRowNames)")
    }

    // MARK: - Helpers

    /// ⇧⌘N with nothing selected: "untitled folder" at the top level, its field showing with focus; typed
    /// "Photos" + Return. Then hello.txt renamed to greeting.txt with File > Rename.
    private func makeFolderAndRename(file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⇧⌘N showed no name field\n\(app.debugDescription)",
                      file: file, line: line)
        XCTAssertEqual(field.value as? String, "untitled folder", file: file, line: line)
        // ⌘Z under the field is the field's own: it must not undo New Folder (no alert either).
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(field.exists, "⌘Z ended the name field\n\(app.visibleRowNames)", file: file, line: line)
        // The row being renamed shows a text field, not the static text `row(_:)` matches: the field is the row.
        XCTAssertEqual(field.value as? String, "untitled folder", "⌘Z undid New Folder under its field",
                       file: file, line: line)
        XCTAssertFalse(app.text(containing: "can’t be renamed").exists || app.text(containing: "can't be renamed").exists,
                       "⌘Z raised an alert\n\(app.debugDescription)", file: file, line: line)
        app.typeText("Photos")
        XCTAssertEqual(field.value as? String, "Photos", file: file, line: line)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.row("Photos").waitForExistence(timeout: 5), "\(app.visibleRowNames)", file: file, line: line)

        app.row("hello.txt").select()
        app.openMenu("File", item: "Rename").click()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "File > Rename showed no name field\n\(app.debugDescription)",
                      file: file, line: line)
        app.typeText("greeting")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.row("greeting.txt").waitForExistence(timeout: 5), "\(app.visibleRowNames)", file: file, line: line)
    }

    /// The middle of a row's Name text (rows are "not hittable" on macOS 26: see `select()`).
    private func nameCenter(of row: XCUIElement) -> XCUICoordinate {
        let name = row.cells.firstMatch.staticTexts.firstMatch
        return (name.exists ? name : row).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// Edit's first item (Undo …), read with the menu open, then closed again.
    private func undoMenuTitle() -> String {
        let edit = app.menuBars.menuBarItems["Edit"]
        edit.click()
        let undo = edit.menus.menuItems.element(boundBy: 0)
        _ = undo.waitForExistence(timeout: 5)
        let title = undo.title
        note("Edit menu first item: \(title), enabled \(undo.isEnabled)")
        app.typeKey(.escape, modifierFlags: [])
        return title
    }

    private func note(_ text: String) {
        XCTContext.runActivity(named: text) { _ in }
        print("RENAMEUI \(text)")
    }
}
