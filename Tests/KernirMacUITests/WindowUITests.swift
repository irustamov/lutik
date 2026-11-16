import XCTest

/// The archive window: outline, toolbar, search, footer, empty and read-only states.
final class WindowUITests: KernirMacUITestCase {
    func testOpensZipShowsRootEntries() throws {
        try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))

        // Root of deflate.zip in Finder order: folders first, then files by name.
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])
        XCTAssertTrue(app.windows.firstMatch.staticTexts["deflate.zip"].exists, "window title")
        XCTAssertTrue(app.text(containing: "ZIP · ").exists, "subtitle: format and size")

        // Footer: every entry (files and folders) and the format.
        let footer = app.footer
        XCTAssertTrue(footer.exists)
        let summary = try XCTUnwrap(footer.value as? String)
        XCTAssertTrue(summary.hasPrefix("9 items · "), summary)
        XCTAssertTrue(summary.hasSuffix(" · ZIP"), summary)

        // A writable archive: ＋ is on, － waits for a selection.
        XCTAssertTrue(app.addButton.isEnabled)
        XCTAssertFalse(app.deleteButton.isEnabled)
        app.row("hello.txt").select()
        XCTAssertTrue(app.deleteButton.isEnabled)
    }

    func testExpandingFolderShowsChildren() throws {
        try openFixture("zip/deflate.zip")
        let docs = app.row("docs")
        waitForArchive(docs)
        XCTAssertFalse(app.row("notes.txt").exists)

        docs.expand()
        XCTAssertTrue(app.row("nested").waitForExistence(timeout: 5))
        XCTAssertTrue(app.row("notes.txt").exists)
        XCTAssertTrue(app.row("readme.md").exists)
        XCTAssertEqual(app.visibleRowNames,
                       ["docs", "nested", "notes.txt", "readme.md", "empty-dir", "empty.txt", "hello.txt"])

        app.row("nested").expand()
        XCTAssertTrue(app.row("deep").waitForExistence(timeout: 5))
        app.row("deep").expand()
        XCTAssertTrue(app.row("data.bin").waitForExistence(timeout: 5))
    }

    func testSearchFiltersRowsLive() throws {
        try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))
        XCTAssertTrue(app.row("empty.txt").exists)

        let search = app.searchField
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("hel")
        // Live: no Return needed.
        XCTAssertTrue(app.row("empty.txt").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.row("hello.txt").exists)
        XCTAssertFalse(app.row("docs").exists)

        // A match inside a folder shows the folder, opened.
        search.typeKey("a", modifierFlags: .command)
        search.typeText("readme")
        XCTAssertTrue(app.row("readme.md").waitForExistence(timeout: 5))
        XCTAssertTrue(app.row("docs").exists)
        XCTAssertFalse(app.row("hello.txt").exists)
        XCTAssertFalse(app.row("notes.txt").exists)

        // No match: the search empty state.
        search.typeKey("a", modifierFlags: .command)
        search.typeText("zzz-no-such-entry")
        XCTAssertTrue(app.row("readme.md").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.text(containing: "No Results").waitForExistence(timeout: 5))

        // Clearing the search restores every root row, with docs closed again.
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 5))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])
    }

    /// Finder's Compress adds `__MACOSX/` and `._` AppleDouble files; the window hides them.
    func testMacOSFinderZipHidesMetadata() throws {
        try openFixture("zip/macos-finder.zip")
        let project = app.row("Project")
        waitForArchive(project)
        XCTAssertEqual(app.visibleRowNames, ["Project"])

        project.expand()
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 5))
        app.row("docs").expand()
        XCTAssertTrue(app.row("readme.md").waitForExistence(timeout: 5))

        let names = app.visibleRowNames
        XCTAssertEqual(names, ["Project", "docs", "readme.md", "hello.txt"])
        XCTAssertFalse(names.contains { $0 == "__MACOSX" || $0.hasPrefix("._") }, "\(names)")
        // The footer counts what is shown, not the hidden metadata.
        let summary = try XCTUnwrap(app.footer.value as? String)
        XCTAssertTrue(summary.hasPrefix("4 items · "), summary)
    }

    /// ISO is read-only (not in `ArchiveFormat.writable`): it lists, but nothing edits it.
    func testReadOnlyFormatDisablesEditing() throws {
        try openFixture("iso/basic.iso")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        XCTAssertTrue(app.text(containing: "ISO · ").exists, "subtitle names the read-only format")
        let summary = try XCTUnwrap(app.footer.value as? String)
        XCTAssertTrue(summary.hasSuffix(" · ISO"), summary)

        hello.select()
        XCTAssertFalse(app.addButton.isEnabled, "＋ on a read-only archive")
        XCTAssertFalse(app.deleteButton.isEnabled, "－ with a selection in a read-only archive")

        let delete = app.openMenu("Edit", item: "Delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "Edit > Delete")
        app.typeKey(.escape, modifierFlags: [])

        let addFiles = app.openMenu("File", item: "Add Files…")
        XCTAssertTrue(addFiles.waitForExistence(timeout: 5))
        XCTAssertFalse(addFiles.isEnabled, "File > Add Files…")
        app.typeKey(.escape, modifierFlags: [])

        // The Delete key does nothing either.
        hello.select()
        app.archiveOutline.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(hello.exists)
        // Nor ⌘⌫.
        app.archiveOutline.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(hello.exists)
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])
    }

    func testEmptyZipShowsEmptyState() throws {
        try openFixture("zip/empty.zip")
        let empty = app.text(containing: "Drag Files Here")
        waitForArchive(empty)
        XCTAssertTrue(app.text(containing: "drag them into this window").exists)
        XCTAssertEqual(app.visibleRowNames, [])
        let summary = try XCTUnwrap(app.footer.value as? String)
        XCTAssertTrue(summary.hasPrefix("0 items · "), summary)
    }

    /// Delete is undoable before saving.
    func testRemoveAndUndo() throws {
        try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        app.deleteButton.click()
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt"])

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(hello.waitForExistence(timeout: 5))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])
    }

    /// ⌘⌫ deletes the selected rows, as in Finder (undoable); in the search and name fields it deletes the
    /// text up to the caret instead, never a row (0.1.0 scope item #8).
    func testCommandDeleteRemovesRowsButEditsText() throws {
        try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        app.archiveOutline.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt"])
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(hello.waitForExistence(timeout: 5))

        let search = app.searchField
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("hel")
        XCTAssertTrue(app.row("empty.txt").waitForNonExistence(timeout: 5))
        search.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(app.row("empty.txt").waitForExistence(timeout: 5), "⌘⌫ left the search text")
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])

        // The name field: Return preselects "hello"; → puts the caret after it.
        hello.select()
        app.typeKey(.return, modifierFlags: [])
        let field = app.archiveOutline.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Return showed no name field\n\(app.debugDescription)")
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertEqual(field.value as? String, ".txt")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])

        // Back on the row after the cancelled rename, ⌘⌫ deletes it.
        hello.select()
        app.archiveOutline.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5), "⌘⌫ after rename → Esc → click left the row")
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt"])
    }

    /// ⌘⌫ with no row selected deletes nothing.
    func testCommandDeleteWithoutSelectionDeletesNothing() throws {
        try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        let names = ["docs", "empty-dir", "empty.txt", "hello.txt"]
        XCTAssertEqual(app.visibleRowNames, names)
        XCTAssertFalse(names.contains { app.row($0).isSelected }, "a row starts selected\n\(app.debugDescription)")
        app.archiveOutline.typeKey(.delete, modifierFlags: .command)
        XCTAssertFalse(hello.waitForNonExistence(timeout: 2))
        XCTAssertEqual(app.visibleRowNames, names)
    }
}
