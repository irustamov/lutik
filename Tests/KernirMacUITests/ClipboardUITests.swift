import AppKit
import XCTest

/// Copy on the archive window's rows puts extracted copies on the general pasteboard, as file URLs
/// Finder pastes. The test reads them back in this runner (never through Finder or any other app) while Kernir
/// still runs: at quit Kernir removes its copies and clears the pasteboard while it is still its own. The
/// pasteboard's previous contents are put back in tear down. Most tests work on a copy of `zip/deflate.zip`:
/// docs/ (nested/deep/data.bin, notes.txt, readme.md), empty-dir/, empty.txt, hello.txt ("Hello, Kernir!\n");
/// the image preview's on `QuickLook/ql-types.zip` (Pixel.png).
final class ClipboardUITests: KernirMacUITestCase {
    /// The general pasteboard's items before the test, put back in tear down: plain types only; nil when the
    /// test was skipped before it read them or the pasteboard holds file promises (then it is left alone).
    private var savedPasteboard: [[NSPasteboard.PasteboardType: Data]]?

    /// Types read and put back: plain ones, mostly written eagerly. Others are never read, so no other app is
    /// asked for lazily provided data.
    private static let savedTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .html, .URL, .fileURL, .png, .tiff, .pdf,
    ]

    /// Markers of file promises (`NSFilePromiseProvider`, Finder's promised files): such a pasteboard is not
    /// read at all.
    private static let promiseTypes: Set<NSPasteboard.PasteboardType> = [
        .init("com.apple.NSFilePromiseItemMetaData"), .init("com.apple.pasteboard.promised-file-url"),
        .init("com.apple.pasteboard.promised-file-content-type"),
    ]

    override func setUp() async throws {
        try await super.setUp()
        app.launchArguments += ["-KernirWindowFrame", "900x560"]
        let items = NSPasteboard.general.pasteboardItems ?? []
        guard !items.contains(where: { !Self.promiseTypes.isDisjoint(with: $0.types) }) else { return }
        savedPasteboard = items.map { item in
            var saved: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where Self.savedTypes.contains(type) { saved[type] = item.data(forType: type) }
            return saved
        }
    }

    override func tearDown() async throws {
        dismissPanels()
        // After Kernir quits: at quit it clears the pasteboard while its Copy is still there.
        try await super.tearDown()
        guard let savedPasteboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = savedPasteboard.filter { !$0.isEmpty }.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// hello.txt and empty.txt selected, ⌘C: the pasteboard holds copies of both, with their contents, and
    /// Kernir's own item.
    func testCommandCCopiesTheSelectedRowsAsFiles() throws {
        _ = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        XCUIElement.perform(withKeyModifiers: .command) { app.row("empty.txt").select() }
        // ⌘C only once the ⌘-click has landed: else it copies hello.txt alone.
        waitForSelected(["hello.txt", "empty.txt"])
        let before = NSPasteboard.general.changeCount
        app.typeKey("c", modifierFlags: .command)

        let urls = try waitForCopiedFiles(after: before)
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["hello.txt", "empty.txt"])
        let helloCopy = try XCTUnwrap(urls.first { $0.lastPathComponent == "hello.txt" })
        XCTAssertEqual(try String(contentsOf: helloCopy, encoding: .utf8), "Hello, Kernir!\n")
        let emptyCopy = try XCTUnwrap(urls.first { $0.lastPathComponent == "empty.txt" })
        XCTAssertEqual(try Data(contentsOf: emptyCopy).count, 0)
        XCTAssertTrue(NSPasteboard.general.types?.contains(.init("com.kernir.app.archive-items")) == true,
                      "no Kernir item on the pasteboard")
    }

    /// The context menu's Copy on the docs row (hello.txt selected): the copy is docs, a folder with its
    /// contents, not the selection.
    func testContextMenuCopyCopiesTheClickedFolder() throws {
        _ = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        let before = NSPasteboard.general.changeCount
        rowCenter(app.row("docs")).rightClick()
        try contextMenuItem("Copy").click()

        let urls = try waitForCopiedFiles(after: before)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["docs"])
        let docs = try XCTUnwrap(urls.first)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDirectory)
                      && isDirectory.boolValue, "docs is not a folder: \(docs.path)")
        let notes = docs.appendingPathComponent("notes.txt")
        XCTAssertEqual(try Data(contentsOf: notes).count, 20_000)
        XCTAssertEqual(try Data(contentsOf: docs.appendingPathComponent("readme.md")).count, 52)
        XCTAssertEqual(try Data(contentsOf: docs.appendingPathComponent("nested/deep/data.bin")).count, 70_000)
    }

    /// A Copy that fails leaves the user's clipboard alone: SwiftUI's ⌘C must not clear the
    /// general pasteboard before the export is done. link-to-hello in `zip/symlinks.zip` is a top-level symlink,
    /// so its Copy fails ("is a link and can’t be copied out of the archive"); the string put on the pasteboard
    /// before the ⌘C is still there after the alert.
    func testAFailedCopyKeepsThePasteboard() throws {
        _ = try openFixture("zip/symlinks.zip")
        let link = app.row("link-to-hello")
        waitForArchive(link)
        link.select()
        waitForSelected(["link-to-hello"])
        let marker = "Kernir clipboard marker \(UUID().uuidString)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(marker, forType: .string))
        let before = pasteboard.changeCount

        app.typeKey("c", modifierFlags: .command)
        let message = app.text(containing: "is a link and can’t be copied out of the archive")
        XCTAssertTrue(message.waitForExistence(timeout: 20), "no Copy failure alert\n\(app.debugDescription)")
        app.buttons["OK"].firstMatch.click()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5), "the alert stayed\n\(app.debugDescription)")

        XCTAssertEqual(pasteboard.changeCount, before, "the failed Copy touched the pasteboard")
        XCTAssertEqual(pasteboard.string(forType: .string), marker)
    }

    /// ⌘C in the name field is the field's own copy:: the selected base name "hello" goes on the
    /// pasteboard as text, and the rows are not copied (no Kernir item, no files).
    func testCommandCInTheNameFieldCopiesTheSelectedText() throws {
        _ = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        waitForSelected(["hello.txt"])
        app.typeKey(.return, modifierFlags: [])
        let field = app.archiveOutline.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Return showed no name field\n\(app.debugDescription)")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let before = pasteboard.changeCount

        app.typeKey("c", modifierFlags: .command)
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pasteboard.changeCount != before },
                                                object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [written], timeout: 5), .completed, "⌘C wrote nothing")

        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertFalse(pasteboard.types?.contains(.init("com.kernir.app.archive-items")) == true,
                       "⌘C in the name field copied the rows")
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) == true, "⌘C in the name field copied files")
        XCTAssertTrue(field.exists, "⌘C ended the rename")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    /// ⌘C in the Info popover's comment (a child window of the archive window) with text selected
    /// is the text's own copy:: the typed text goes on the pasteboard, not the selected rows.
    func testCommandCInTheInfoPopoverCopiesTheSelectedText() throws {
        _ = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        waitForSelected(["hello.txt"])
        let field = try openInfoComment()
        field.typeText("Clip text")
        app.typeKey("a", modifierFlags: .command)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let before = pasteboard.changeCount

        app.typeKey("c", modifierFlags: .command)
        waitForWrite(after: before)
        XCTAssertEqual(pasteboard.string(forType: .string), "Clip text")
        XCTAssertFalse(pasteboard.types?.contains(.init("com.kernir.app.archive-items")) == true,
                       "⌘C in the popover's text copied the rows")
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) == true, "⌘C in the popover's text copied files")
    }

    /// ⌘C with only the caret in the Info popover's empty comment (editable text, clip-fu2 r2): Edit > Copy is off
    /// there and does nothing: neither empty text nor the selected rows go on the pasteboard.
    func testCommandCWithOnlyTheCaretInTheInfoCommentDoesNothing() throws {
        _ = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        waitForSelected(["hello.txt"])
        let field = try openInfoComment()
        XCTAssertEqual(field.value as? String, "", "deflate.zip has a comment")
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount

        app.typeKey("c", modifierFlags: .command)
        // Nothing to wait for: the pasteboard must stay as it was for a while (a Copy of the rows writes it within
        // ~1 s, a text Copy at once).
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pasteboard.changeCount != before },
                                                object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [written], timeout: 2), .timedOut,
                       "⌘C at the caret wrote the pasteboard: types \(pasteboard.types ?? [])")
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertFalse(pasteboard.types?.contains(.init("com.kernir.app.archive-items")) == true,
                       "⌘C at the caret copied the rows")
        XCTAssertTrue(field.exists, "⌘C took the popover down")
    }

    /// ⌘C in the Save As panel's name field (a sheet on the archive window, out of process: its view validates
    /// informally) is the field's own copy:: the selected name goes on the pasteboard, not the rows.
    func testCommandCInTheSavePanelNameFieldCopiesTheText() throws {
        _ = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        waitForSelected(["hello.txt"])
        app.typeKey("s", modifierFlags: [.command, .shift])
        // A sandboxed app's save panel comes from a system service and can be slow (SaveUITests).
        let format = app.popUpButtons["saveFormat"].firstMatch
        XCTAssertTrue(format.waitForExistence(timeout: 30), "no Save As panel\n\(app.debugDescription)")
        // By identifier, not by its "deflate…" proposal: the query is resolved again after the typing.
        let nameField = savePanel.textFields["saveAsNameTextField"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "no name field\n\(app.debugDescription)")
        let proposed = nameField.value as? String ?? ""
        XCTAssertTrue(proposed.hasPrefix("deflate"), "the name field proposes \(String(reflecting: proposed))")
        nameField.click()
        app.typeKey("a", modifierFlags: .command)
        nameField.typeText("Clip name")
        app.typeKey("a", modifierFlags: .command)
        let typed = try XCTUnwrap(nameField.value as? String)
        XCTAssertTrue(typed.hasPrefix("Clip name"), typed)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let before = pasteboard.changeCount

        app.typeKey("c", modifierFlags: .command)
        waitForWrite(after: before)
        XCTAssertEqual(pasteboard.string(forType: .string), typed)
        XCTAssertFalse(pasteboard.types?.contains(.init("com.kernir.app.archive-items")) == true,
                       "⌘C in the save panel copied the rows")
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) == true, "⌘C in the save panel copied files")
        savePanel.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(format.waitForNonExistence(timeout: 10), "the Save As panel stayed open\n\(app.debugDescription)")
    }

    /// ⌘C in the preview window on an image: Quick Look's view may enable copy: with nothing
    /// selected, but with no text selected the archive window's rows are the target: Pixel.png's copy goes on the
    /// pasteboard as a file, with Kernir's item, not the image.
    func testCommandCInAnImagePreviewCopiesTheRows() throws {
        app.launchArguments += ["-KernirPreviewFrameAutosave", "NO"]
        let source = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .appendingPathComponent("QuickLook/ql-types.zip")
        let copy = workDirectory.appendingPathComponent("ql-types.zip")
        try FileManager.default.copyItem(at: source, to: copy)
        open(copy)
        let pixel = app.row("Pixel.png")
        waitForArchive(pixel)
        pixel.select()
        waitForSelected(["Pixel.png"])
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        let preview = app.children(matching: .any).matching(NSPredicate(format: "identifier == %@", "preview")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "no preview window\n\(app.debugDescription)")
        let titled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title == %@", "Pixel.png"), object: preview)
        XCTAssertEqual(XCTWaiter().wait(for: [titled], timeout: 10), .completed, "the preview is not on Pixel.png")
        // Let the image render, so Quick Look's view is the one answering copy: (PreviewWindowUITests: ~0.3 s). A
        // fixed wait: the render is out of process and shows no element or value to wait for (PreviewWindowUITests
        // waits the same way).
        Thread.sleep(forTimeInterval: 1.5)
        let before = NSPasteboard.general.changeCount

        app.typeKey("c", modifierFlags: .command)
        let urls = try waitForCopiedFiles(after: before)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Pixel.png"])
        XCTAssertTrue(NSPasteboard.general.types?.contains(.init("com.kernir.app.archive-items")) == true,
                      "no Kernir item on the pasteboard")
        XCTAssertTrue(preview.exists, "⌘C closed the preview")
    }

    // MARK: - Helpers

    /// The Save As panel's sheet (InfoUITests).
    private var savePanel: XCUIElement { app.sheets["save-panel"].firstMatch }

    /// No test leaves the Save As panel or the Info popover up when Kernir is quit: a run that failed with the
    /// save panel open (an out-of-process sheet) left the next test's launch unable to activate Kernir ("Running
    /// Background"). Best effort, before the base class quits Kernir; a failed test skips its own closing.
    private func dismissPanels() {
        guard let app, app.state == .runningForeground else { return }
        let cancel = savePanel.buttons["Cancel"].firstMatch
        if cancel.exists {
            cancel.click()
            _ = savePanel.waitForNonExistence(timeout: 10)
        }
        let popover = app.popovers.firstMatch
        if popover.exists {
            app.typeKey(.escape, modifierFlags: [])
            _ = popover.waitForNonExistence(timeout: 5)
        }
    }

    /// ⌘I on the selected row, then a click in the Info popover's comment (empty in deflate.zip, so the caret is
    /// at its end); returns the comment field. No ⌘↓ to move the caret: with a row selected it is the File menu's
    /// hidden Open, which opens the row in its default app and takes the popover down.
    private func openInfoComment(file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        app.typeKey("i", modifierFlags: .command)
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "no Info popover\n\(app.debugDescription)",
                      file: file, line: line)
        let field = popover.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no comment field\n\(app.debugDescription)",
                      file: file, line: line)
        field.click()
        return field
    }

    /// Waits up to 5 s until the general pasteboard's change count is past `before`.
    private func waitForWrite(after before: Int, file: StaticString = #filePath, line: UInt = #line) {
        let pasteboard = NSPasteboard.general
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pasteboard.changeCount != before },
                                                object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [written], timeout: 5), .completed, "⌘C wrote nothing",
                       file: file, line: line)
    }

    /// Waits up to 5 s until every row in `names` is selected.
    private func waitForSelected(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        let selected = NSPredicate(format: "isSelected == true")
        let expectations = names.map { XCTNSPredicateExpectation(predicate: selected, object: app.row($0)) }
        let result = XCTWaiter().wait(for: expectations, timeout: 5)
        XCTAssertEqual(result, .completed, "\(names) not all selected\n\(app.debugDescription)", file: file, line: line)
    }

    /// The file URLs on the general pasteboard once Kernir has written it (its change count past `before`) and
    /// they exist; fails after 20 s (the copies are extracted under a progress sheet first).
    private func waitForCopiedFiles(after before: Int, file: StaticString = #filePath,
                                    line: UInt = #line) throws -> [URL] {
        let pasteboard = NSPasteboard.general
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
                    .compactMap { $0 as? URL } ?? []
                if !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                    return urls
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("no copied files on the pasteboard (types \(pasteboard.types ?? []))\n\(app.debugDescription)",
                file: file, line: line)
        throw CopyTimedOut()
    }

    private struct CopyTimedOut: Error {}

    /// The middle of a row's Name text, for clicks (see `select()` on hittability).
    private func rowCenter(_ row: XCUIElement) -> XCUICoordinate {
        let name = row.cells.firstMatch.staticTexts.firstMatch
        return (name.exists ? name : row).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// The hittable, enabled context-menu item titled `title` (the Edit menu's Copy is never hittable while the
    /// menu bar is closed; MoveUITests).
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
}
