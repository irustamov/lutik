import XCTest

/// Moving rows inside an archive on Mac. A row dragged onto a folder row moves into that folder; one
/// dropped on the table's blank space below the rows (or on a file row) moves to the top level
/// (`ArchiveTableDragAnchor.moveTarget`); the row's context menu Move To… picks a folder in a sheet. Each
/// move is saved (⌘S), the window closed, and the archive reopened from disk to check the layout persisted.
/// Every test works on a copy of `zip/deflate.zip`:
/// docs/ (nested/deep/data.bin, notes.txt, readme.md), empty-dir/, empty.txt, hello.txt.
final class MoveUITests: KernirMacUITestCase {
    override func setUp() async throws {
        try await super.setUp()
        // A fixed frame on the menu-bar display (RenameUITests), tall enough for blank table space below the rows.
        app.launchArguments += ["-KernirWindowFrame", "900x560"]
    }

    /// hello.txt dragged onto the docs row moves into docs; it persists through ⌘S and a reopen.
    func testDragFileOntoFolderMovesItIn() throws {
        let archive = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])

        hello.nameCenter.press(forDuration: 0.6, thenDragTo: app.row("docs").nameCenter)
        // No top-level-only check here: AppKit may spring-open docs while the drag hovers it. In Finder order
        // a top-level hello.txt would come after empty.txt, so the list below tells inside from outside.
        app.row("docs").expand()
        waitForRows(["docs", "nested", "hello.txt", "notes.txt", "readme.md", "empty-dir", "empty.txt"],
                    "hello.txt is not inside docs")
        try assertItemCount(9)

        try saveAndReopen(archive)
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt"], "the top level after the reopen")
        app.row("docs").expand()
        waitForRows(["docs", "nested", "hello.txt", "notes.txt", "readme.md", "empty-dir", "empty.txt"],
                    "hello.txt is not inside docs after the reopen")
        try assertItemCount(9)
    }

    /// docs/nested dragged onto the blank table space below the rows moves to the top level, with its
    /// contents; it persists through ⌘S and a reopen.
    func testDragFolderOntoBlankSpaceMovesItToTopLevel() throws {
        let archive = try openFixture("zip/deflate.zip")
        let docs = app.row("docs")
        waitForArchive(docs)
        docs.expand()
        waitForRows(["docs", "nested", "notes.txt", "readme.md", "empty-dir", "empty.txt", "hello.txt"],
                    "docs did not open")

        app.row("nested").nameCenter.press(forDuration: 0.6, thenDragTo: try blankSpaceBelowRows())
        waitForRows(["docs", "notes.txt", "readme.md", "empty-dir", "nested", "empty.txt", "hello.txt"],
                    "nested did not move to the top level")
        try assertItemCount(9)

        try saveAndReopen(archive)
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "nested", "empty.txt", "hello.txt"],
                       "the top level after the reopen")
        app.row("docs").expand()
        waitForRows(["docs", "notes.txt", "readme.md", "empty-dir", "nested", "empty.txt", "hello.txt"],
                    "docs still holds nested after the reopen")
        app.row("nested").expand()
        XCTAssertTrue(app.row("deep").waitForExistence(timeout: 5), "nested lost deep\n\(app.debugDescription)")
        app.row("deep").expand()
        XCTAssertTrue(app.row("data.bin").waitForExistence(timeout: 5), "deep lost data.bin\n\(app.debugDescription)")
        try assertItemCount(9)
    }

    /// Context menu > Move To… on hello.txt, docs chosen in the sheet, Move: hello.txt moves into docs; it
    /// persists through ⌘S and a reopen.
    func testMoveToSheetMovesFileIntoFolder() throws {
        let archive = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        hello.nameCenter.rightClick()
        try contextMenuItem("Move To…").click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no Move To… sheet\n\(app.debugDescription)")
        XCTAssertTrue(sheet.staticText(containing: "Move “hello.txt” to:").waitForExistence(timeout: 5),
                      "the sheet's heading\n\(sheet.debugDescription)")
        let move = sheet.buttons["Move"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 5), "no Move button\n\(sheet.debugDescription)")
        XCTAssertFalse(move.isEnabled, "Move is enabled with no folder selected")
        // The sheet's outline opens on the archive's row, with its folders (docs, empty-dir) under it.
        waitForSheetRows(sheet, ["deflate.zip", "docs", "empty-dir"], "the sheet's rows")
        try clickSheetRow("docs", in: sheet)
        waitUntil("Move stays disabled with docs selected\n\(sheet.debugDescription)") { move.isEnabled }
        move.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the sheet stayed open\n\(app.debugDescription)")

        waitForRows(["docs", "empty-dir", "empty.txt"], "hello.txt is still at the top level after Move")
        app.row("docs").expand()
        waitForRows(["docs", "nested", "hello.txt", "notes.txt", "readme.md", "empty-dir", "empty.txt"],
                    "hello.txt is not inside docs")
        try assertItemCount(9)

        try saveAndReopen(archive)
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt"], "the top level after the reopen")
        app.row("docs").expand()
        waitForRows(["docs", "nested", "hello.txt", "notes.txt", "readme.md", "empty-dir", "empty.txt"],
                    "hello.txt is not inside docs after the reopen")
    }

    /// Move To… on docs/notes.txt: the sheet opens on docs, the folder notes.txt is in now, which is disabled
    /// (a click selects nothing) yet still closes and opens onto nested, which takes the move; the archive's
    /// row is selectable and moves notes.txt to the top level.
    func testMoveToSheetRootRowAndDisabledParent() throws {
        _ = try openFixture("zip/deflate.zip")
        let docsInWindow = app.row("docs")
        waitForArchive(docsInWindow)
        docsInWindow.expand()
        waitForRows(["docs", "nested", "notes.txt", "readme.md", "empty-dir", "empty.txt", "hello.txt"],
                    "docs did not open")
        let notes = app.row("notes.txt")
        notes.select()
        notes.nameCenter.rightClick()
        try contextMenuItem("Move To…").click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no Move To… sheet\n\(app.debugDescription)")
        XCTAssertTrue(sheet.staticText(containing: "Move “notes.txt” to:").waitForExistence(timeout: 5),
                      "the sheet's heading\n\(sheet.debugDescription)")
        let move = sheet.buttons["Move"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 5), "no Move button\n\(sheet.debugDescription)")
        // The archive's row and docs, the folder above notes.txt, start open.
        waitForSheetRows(sheet, ["deflate.zip", "docs", "nested", "empty-dir"], "the sheet's rows")

        // docs is where notes.txt is: a click selects nothing.
        try clickSheetRow("docs", in: sheet)
        XCTAssertFalse(move.isEnabled, "Move is enabled with docs, notes.txt's own folder, clicked")
        // Its triangle still closes and opens it, onto nested, which takes the move.
        try clickSheetTriangle("docs", in: sheet)
        waitForSheetRows(sheet, ["deflate.zip", "docs", "empty-dir"], "docs did not close")
        try clickSheetTriangle("docs", in: sheet)
        waitForSheetRows(sheet, ["deflate.zip", "docs", "nested", "empty-dir"], "docs did not open again")
        try clickSheetRow("nested", in: sheet)
        waitUntil("Move stays disabled with nested selected\n\(sheet.debugDescription)") { move.isEnabled }

        // The archive's row: notes.txt moves to the top level (not into nested).
        try clickSheetRow("deflate.zip", in: sheet)
        XCTAssertTrue(move.isEnabled, "Move is disabled with the archive's row selected\n\(sheet.debugDescription)")
        move.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the sheet stayed open\n\(app.debugDescription)")
        waitForRows(["docs", "nested", "readme.md", "empty-dir", "empty.txt", "hello.txt", "notes.txt"],
                    "notes.txt did not move to the top level")
        try assertItemCount(9)
    }

    // MARK: - Helpers

    /// The Move To… sheet's visible outline rows, top to bottom, read from one snapshot of the sheet, not
    /// through element queries: on the gate's run (macOS 26) a row with a disclosure triangle (the archive's,
    /// a folder with subfolders) showed `OutlineRow > Cell > StaticText, label: 'docs'` in the sheet's tree,
    /// yet neither `cells.firstMatch.staticTexts.firstMatch` nor a `label == "docs"` predicate found that
    /// text; only a leaf folder's row (its name in the text's value) did.
    private func sheetRows(_ sheet: XCUIElement) -> [SheetRow] {
        guard let snapshot = try? sheet.snapshot() else { return [] }
        return snapshot.descendants(ofType: .outlineRow).compactMap { SheetRow($0, in: snapshot.frame) }
    }

    private func sheetRowNames(_ sheet: XCUIElement) -> [String] {
        sheetRows(sheet).map(\.name)
    }

    /// Waits up to 5 s for the sheet's visible rows to read `names`, top to bottom.
    private func waitForSheetRows(_ sheet: XCUIElement, _ names: [String], _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("\(message): \(sheetRowNames(sheet))\n\(sheet.debugDescription)", file: file, line: line) {
            self.sheetRowNames(sheet) == names
        }
    }

    /// The sheet's visible row named `name`, waiting up to 5 s for it.
    private func sheetRow(_ name: String, in sheet: XCUIElement, file: StaticString = #filePath,
                          line: UInt = #line) throws -> SheetRow {
        let find = { self.sheetRows(sheet).first { $0.name == name } }
        let deadline = Date().addingTimeInterval(5)
        var row = find()
        while row == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            row = find()
        }
        return try XCTUnwrap(row, "no \(name) row in the sheet: \(sheetRowNames(sheet))\n\(sheet.debugDescription)",
                             file: file, line: line)
    }

    /// Clicks the middle of the sheet row `name`'s text.
    private func clickSheetRow(_ name: String, in sheet: XCUIElement, file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let row = try sheetRow(name, in: sheet, file: file, line: line)
        sheet.coordinate(withNormalizedOffset: .zero).withOffset(row.nameOffset).click()
    }

    /// Clicks the sheet row `name`'s disclosure triangle.
    private func clickSheetTriangle(_ name: String, in sheet: XCUIElement, file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        let row = try sheetRow(name, in: sheet, file: file, line: line)
        let offset = try XCTUnwrap(row.triangleOffset,
                                   "the \(name) row has no disclosure triangle\n\(sheet.debugDescription)",
                                   file: file, line: line)
        sheet.coordinate(withNormalizedOffset: .zero).withOffset(offset).click()
    }

    /// Waits up to `timeout` for the visible rows to read `names`, top to bottom.
    private func waitForRows(_ names: [String], _ message: String, timeout: TimeInterval = 5,
                             file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("\(message): \(app.visibleRowNames)\n\(app.debugDescription)", timeout: timeout,
                  file: file, line: line) { self.app.visibleRowNames == names }
    }

    /// Polls `condition` every 0.25 s for up to `timeout` (≤ 10 s); fails with `message` when it never holds.
    private func waitUntil(_ message: @autoclosure () -> String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(min(timeout, 10))
        while !condition() {
            guard Date() < deadline else {
                XCTFail(message(), file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func assertItemCount(_ count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let summary = try XCTUnwrap(app.footer.value as? String, file: file, line: line)
        XCTAssertTrue(summary.hasPrefix("\(count) items · "), summary, file: file, line: line)
    }

    /// A point in the table's blank space below its last row: the table itself, which takes a move to the
    /// top level.
    private func blankSpaceBelowRows() throws -> XCUICoordinate {
        let outline = app.archiveOutline
        let last = try XCTUnwrap(outline.outlineRows.allElementsBoundByIndex.last, "no rows")
        let gap = outline.frame.maxY - last.frame.maxY
        guard gap > 24 else { throw NoBlankSpace(gap: gap, tree: app.debugDescription) }
        let offset = CGVector(dx: outline.frame.width / 2, dy: last.frame.maxY - outline.frame.minY + min(gap / 2, 60))
        return outline.coordinate(withNormalizedOffset: .zero).withOffset(offset)
    }

    private struct NoBlankSpace: LocalizedError {
        let gap: CGFloat
        let tree: String
        var errorDescription: String? { "no blank table space below the rows (\(gap) pt)\n\(tree)" }
    }

    /// The hittable context-menu item titled `title` (a menu-bar item of that title is never hittable while
    /// the menu bar is closed; RenameUITests).
    private func contextMenuItem(_ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let items = app.menuItems.matching(NSPredicate(format: "title == %@", title))
        var item: XCUIElement?
        let deadline = Date().addingTimeInterval(5)
        while item == nil, Date() < deadline {
            item = items.allElementsBoundByIndex.first { $0.exists && $0.isHittable && $0.isEnabled }
            if item == nil { Thread.sleep(forTimeInterval: 0.3) }
        }
        return try XCTUnwrap(item, "no enabled \(title) in the row's context menu\n\(app.debugDescription)",
                             file: file, line: line)
    }

    /// ⌘S, waits (≤ 10 s) for the archive on disk to change, closes the window (⌘W) and reopens the archive
    /// from disk in a fresh Kernir (`open(_:)` quits the running one first).
    private func saveAndReopen(_ archive: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try Self.sha256(of: archive)
        app.typeKey("s", modifierFlags: .command)
        let failed = app.text(containing: "could not be saved")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !failed.exists, try Self.sha256(of: archive) == before {
            XCTAssertNotEqual(app.state, .notRunning, "the app crashed while saving", file: file, line: line)
            _ = failed.waitForExistence(timeout: 0.5)
        }
        XCTAssertFalse(failed.exists, "the save failed\n\(app.debugDescription)", file: file, line: line)
        XCTAssertNotEqual(try Self.sha256(of: archive), before, "⌘S did not write the archive", file: file, line: line)
        XCTAssertTrue(app.text(containing: "Saving “").waitForNonExistence(timeout: 10),
                      "the save is still running\n\(app.debugDescription)", file: file, line: line)

        let window = app.windows.firstMatch
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "⌘W left the window open (unsaved changes?)\n"
                      + app.debugDescription, file: file, line: line)

        open(archive)
        waitForArchive(app.row("docs"), file: file, line: line)
    }
}

private extension XCUIElement {
    /// The middle of a row's Name text, for clicks and drags (see `select()` on hittability).
    var nameCenter: XCUICoordinate {
        let name = cells.firstMatch.staticTexts.firstMatch
        return (name.exists ? name : self).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// A static text in this element whose value or label contains `text`.
    func staticText(containing text: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
    }
}

/// A Move To… sheet row in a snapshot of the sheet: its name, and where to click its text and its disclosure
/// triangle, as offsets from the sheet's top-left corner.
private struct SheetRow {
    let name: String
    let nameOffset: CGVector
    let triangleOffset: CGVector?

    /// Nil when the row has no text. The name is the text's label when that is non-empty (a row with a
    /// disclosure triangle), else its value (a leaf folder's row).
    @MainActor init?(_ row: XCUIElementSnapshot, in sheetFrame: CGRect) {
        let cell = row.descendants(ofType: .cell).first ?? row
        guard let text = cell.descendants(ofType: .staticText).first else { return nil }
        let name = text.label.isEmpty ? (text.value as? String ?? "") : text.label
        guard !name.isEmpty else { return nil }
        func offset(_ frame: CGRect) -> CGVector {
            CGVector(dx: frame.midX - sheetFrame.minX, dy: frame.midY - sheetFrame.minY)
        }
        self.name = name
        nameOffset = offset(text.frame)
        triangleOffset = row.descendants(ofType: .disclosureTriangle).first.map { offset($0.frame) }
    }
}

private extension XCUIElementSnapshot {
    /// The descendants of type `type`, in tree order (top to bottom for rows).
    func descendants(ofType type: XCUIElement.ElementType) -> [XCUIElementSnapshot] {
        children.flatMap { child in (child.elementType == type ? [child] : []) + child.descendants(ofType: type) }
    }
}
