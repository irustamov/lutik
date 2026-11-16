import XCTest

/// Split archives: opening one part of a complete set from Finder leaves the sandboxed app
/// without access to the other parts, so the window is locked until the user grants the folder.
final class MultiVolumeUITests: KernirMacUITestCase {
    private static let splitText = "This archive is split into parts."
    private static let missingText = "Part 2 of “s7.7z.001” is missing."
    private static let grantAccess = "Grant Access…"
    /// The set's top-level entries (Fixtures/multivolume/EXPECTED.json, set s7).
    private static let topLevel = ["data", "gamma.bin"]
    private static let parts = ["s7.7z.001", "s7.7z.002", "s7.7z.003"]

    /// Copies `Fixtures/multivolume/<folder><names>` flat into the work folder; returns the copies.
    private func copyParts(_ names: [String], from folder: String = "multivolume") throws -> [URL] {
        try names.map {
            let source = Self.fixturesDirectory.appendingPathComponent("\(folder)/\($0)")
            let copy = workDirectory.appendingPathComponent($0)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        }
    }

    func testGrantAccessOpensWholeSet() throws {
        let urls = try copyParts(Self.parts)
        let before = try urls.map { try Self.sha256(of: $0) }
        open(urls[1])

        waitForArchive(app.text(containing: Self.splitText), timeout: 30)
        XCTAssertTrue(app.buttons[Self.grantAccess].firstMatch.exists)
        XCTAssertEqual(app.archiveOutline.outlineRows.count, 0, "rows listed before access was granted")

        grantAccess()
        waitForArchive(app.row(Self.topLevel[0]), timeout: 30)
        for name in Self.topLevel { XCTAssertTrue(app.row(name).exists, "no row \(name)") }
        XCTAssertTrue(app.text(containing: Self.splitText).waitForNonExistence(timeout: 5), "the locked text stayed")

        // A set is read-only (plan: "Save menu disabled; Save As works"): Save is off, and Save As…
        // asks where to write one ordinary archive.
        let saveAs = app.openMenu("File", item: "Save As…")
        XCTAssertTrue(saveAs.waitForExistence(timeout: 5), "no Save As… in the File menu\n\(app.debugDescription)")
        XCTAssertFalse(app.menuItem("File", "Save").isEnabled, "Save is enabled on a set")
        XCTAssertTrue(saveAs.isEnabled, "Save As… is disabled on a set")
        saveAs.click()
        if let cancel = savePanelCancelButton(name: "set-save-as") {
            cancel.click()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), "the Save As panel stayed open\n\(app.debugDescription)")
        }

        XCTAssertEqual(try urls.map { try Self.sha256(of: $0) }, before, "a part changed")
    }

    /// Control for `savePanelCancelButton`: Save As on an ordinary archive shows the same panel, so
    /// a failure on the set alone is the set's.
    func testSaveAsPanelOnAnOrdinaryArchive() throws {
        try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))
        app.typeKey("s", modifierFlags: [.command, .shift])
        if let cancel = savePanelCancelButton(name: "ordinary-save-as") {
            cancel.click()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), "the Save As panel stayed open\n\(app.debugDescription)")
        }
    }

    /// The Cancel button of the Save panel that Save As brought up, found anywhere in the app: a
    /// sandboxed app's save panel comes from a system service, and on a busy Mac it wasn't in
    /// `app.sheets` within 10 s while the window was already disabled under it (10b-3). Waits 30 s
    /// and keeps a screenshot and the hierarchy either way; nil after a failure.
    private func savePanelCancelButton(name: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR title == 'Cancel'")).firstMatch
        let found = cancel.waitForExistence(timeout: 30)
        keep(XCTAttachment(screenshot: XCUIScreen.main.screenshot()), name: "\(name)-screen")
        keep(XCTAttachment(string: app.debugDescription), name: "\(name)-hierarchy")
        XCTContext.runActivity(named: "\(name): sheets \(app.sheets.count), dialogs \(app.dialogs.count), "
                               + "windows \(app.windows.count), text fields \(app.textFields.count)") { _ in }
        guard found else {
            XCTFail("no Save As panel: no Cancel button anywhere in the app\n\(app.debugDescription)", file: file, line: line)
            return nil
        }
        XCTAssertTrue(app.textFields.firstMatch.exists, "the panel has no name field\n\(app.debugDescription)",
                      file: file, line: line)
        return cancel
    }

    private func keep(_ attachment: XCTAttachment, name: String) {
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMissingPartNeverLists() throws {
        let urls = try copyParts(["s7.7z.001", "s7.7z.003"], from: "multivolume/missing")
        open(urls[0])

        // Before a grant either text is right: the sandbox hides the siblings, or part 2 is missing.
        let either = NSPredicate(format: "value CONTAINS %@ OR value CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                 Self.splitText, Self.missingText, Self.splitText, Self.missingText)
        waitForArchive(app.staticTexts.matching(either).firstMatch, timeout: 30)
        if app.buttons[Self.grantAccess].firstMatch.exists, app.text(containing: Self.splitText).exists {
            grantAccess()
        }
        waitForArchive(app.text(containing: Self.missingText), timeout: 30)
        XCTAssertEqual(app.archiveOutline.outlineRows.count, 0, "a set with a missing part listed rows")
    }

    /// After a grant, Open Recent on the same part brings back the same window (showWindows on a
    /// document that already lists): the full listing stays and the locked text never returns.
    func testReopenAfterGrantKeepsListing() throws {
        let urls = try copyParts(Self.parts)
        open(urls[1])
        waitForArchive(app.text(containing: Self.splitText), timeout: 30)
        grantAccess()
        waitForArchive(app.row(Self.topLevel[0]), timeout: 30)

        let recent = app.openMenu("File", item: "Open Recent")
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "no Open Recent in the File menu\n\(app.debugDescription)")
        recent.click()
        let entry = recent.menus.menuItems["s7.7z.002"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "s7.7z.002 is not in Open Recent\n\(recent.debugDescription)")
        entry.click()

        XCTAssertNotEqual(app.state, .notRunning, "Kernir quit on reopen")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "the window went away")
        waitForArchive(app.row(Self.topLevel[0]), timeout: 30)
        for name in Self.topLevel { XCTAssertTrue(app.row(name).exists, "no row \(name) after reopen") }
        XCTAssertFalse(app.text(containing: Self.splitText).exists, "the locked text came back")
    }
}
