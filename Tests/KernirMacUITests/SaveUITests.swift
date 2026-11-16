import XCTest

/// Remove → ⌘S. Every save is a full repack into a temporary file that NSDocument swaps in.
/// Failed saves (full disk, read-only volume, force-quit mid-save) are in OwnerChecksUITests.
final class SaveUITests: KernirMacUITestCase {
    /// The full round trip: remove hello.txt, save, reopen; hello.txt is gone and the rest is
    /// intact, with nothing left next to the archive. Skipped if the writer is ever a stub again.
    func testRemoveSaveRoundTrip() throws {
        let archive = try openFixture("zip/deflate.zip")
        let before = try Self.sha256(of: archive)

        removeHelloAndSave()

        let stub = app.text(containing: Self.stubText)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !stub.exists, try Self.sha256(of: archive) == before {
            XCTAssertNotEqual(app.state, .notRunning, "the app crashed while saving")
            _ = stub.waitForExistence(timeout: 0.5)
        }
        if stub.exists {
            XCTAssertEqual(try Self.sha256(of: archive), before)
            throw XCTSkip("KernirCore's repack writer is still a stub (\"\(Self.stubText)\").")
        }
        XCTAssertNotEqual(try Self.sha256(of: archive), before, "the save did not write the archive")
        XCTAssertFalse(app.text(containing: "could not be saved").exists)
        XCTAssertEqual(try directoryListing(), [archive.lastPathComponent], "leftovers next to the archive")

        // Reopen from disk (open(_:) quits the running app first).
        open(archive)
        waitForArchive(app.row("docs"))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt"])
        app.row("docs").expand()
        XCTAssertTrue(app.row("readme.md").waitForExistence(timeout: 5))
        XCTAssertTrue(app.row("notes.txt").exists)
        app.row("nested").expand()
        app.row("deep").expand()
        XCTAssertTrue(app.row("data.bin").waitForExistence(timeout: 5))
        let summary = try XCTUnwrap(app.footer.value as? String)
        XCTAssertTrue(summary.hasPrefix("8 items · "), summary)
    }

    /// Split Save As, Replace: a second split save under the same name into the same place,
    /// with fewer volumes, replaces the earlier set through the panel's Replace. On this local volume the
    /// earlier folder goes to the Trash (`SplitSetPlacement.place`; it stays there as "kernir-uitest-split")
    /// and the new set moves in, under the panel's grant, outside the app's container.
    func testSplitSaveReplacesEarlierSet() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernir-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        // 2.5 MB of random bytes, stored: about 2.5 MB as 7z, so 3 volumes at 1 MB and 2 at 2 MB.
        let archive = folder.appendingPathComponent("\(Self.setName).zip")
        try Self.writeSplitSource(to: archive, from: workDirectory)
        open(archive)
        waitForArchive(app.row("blob.bin"))
        let entries = app.visibleRowNames
        XCTAssertEqual(entries, ["blob.bin", "readme.txt"])

        let set = folder.appendingPathComponent(Self.setName, isDirectory: true)
        saveSplit(megabytes: "1", name: Self.setName, replacing: false, shot: "split-1mb")
        waitForListing(of: set, ["001", "002", "003"].map { "\(Self.setName).7z.\($0)" })

        saveSplit(megabytes: "2", name: Self.setName, replacing: true, shot: "split-2mb")
        let parts = ["001", "002"].map { "\(Self.setName).7z.\($0)" }
        waitForListing(of: set, parts)
        // The new set's first volume (2 000 000 bytes), not the earlier one's (1 000 000).
        let size = try FileManager.default.attributesOfItem(atPath: set.appendingPathComponent(parts[0]).path)[.size]
        XCTAssertEqual((size as? NSNumber)?.intValue, 2_000_000, "the first volume isn't the new set's")
        // Nothing stray next to the set either: no "kernir-uitest-split 2", no staging or recovered folder.
        XCTAssertEqual(try Self.listing(of: folder), [Self.setName, archive.lastPathComponent])
        for alert in ["could not be saved", "partly replaced", "changed while saving"] {
            XCTAssertFalse(app.text(containing: alert).exists, "an alert says \"\(alert)\"\n\(app.debugDescription)")
        }

        // Reopen from disk (open(_:) quits the running app first): the set lists the same entries.
        // The panel's save already gave the app the set folder, so the reopen may list at once;
        // only a locked window ("split into parts") needs Grant Access first.
        open(set.appendingPathComponent(parts[0]))
        let splitText = "This archive is split into parts."
        let either = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@ OR value == %@",
                                 splitText, splitText, "blob.bin")
        waitForArchive(app.staticTexts.matching(either).firstMatch, timeout: 30)
        if app.text(containing: splitText).exists { grantAccess() }
        waitForArchive(app.row("blob.bin"), timeout: 30)
        XCTAssertEqual(app.visibleRowNames, entries)
    }

    // MARK: - Helpers

    /// The split set's name: the archive's, so the panel proposes it, and recognisable in the Trash.
    private static let setName = "kernir-uitest-split"

    /// Save As… (⇧⌘S) as 7z split at Custom `megabytes` MB into the archive's folder, named `name`;
    /// `replacing` confirms the panel's Replace. Keeps a screenshot of the panel (accessory layout).
    /// Typed values are checked before Save, so a mistyped name never saves anywhere.
    private func saveSplit(megabytes: String, name: String, replacing: Bool, shot: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("s", modifierFlags: [.command, .shift])
        // A sandboxed app's save panel comes from a system service and can be slow (MultiVolumeUITests).
        let format = app.popUpButtons["saveFormat"].firstMatch
        XCTAssertTrue(format.waitForExistence(timeout: 30), "no Save As panel with options\n\(app.debugDescription)",
                      file: file, line: line)
        format.click()
        format.menuItems["7z"].click()
        let split = app.popUpButtons["saveSplit"].firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 5), "no Split popup for 7z\n\(app.debugDescription)",
                      file: file, line: line)
        split.click()
        split.menuItems["Custom…"].click()
        let size = app.textFields["saveSplitCustom"].firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5), "no Custom size field\n\(app.debugDescription)",
                      file: file, line: line)
        size.click()
        app.typeKey("a", modifierFlags: .command)
        size.typeText(megabytes)
        XCTAssertEqual(size.value as? String, megabytes, "the size field", file: file, line: line)

        // The name field holds the proposal: the set's name, or "<name> 2" once that is taken.
        let nameField = app.textFields.matching(NSPredicate(format: "value BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "no name field proposing \(name)\n\(app.debugDescription)",
                      file: file, line: line)
        if nameField.value as? String != name {
            nameField.click()
            app.typeKey("a", modifierFlags: .command)
            nameField.typeText(name)
        }
        XCTAssertEqual(nameField.value as? String, name, "the name field", file: file, line: line)
        keepScreenshot(shot)

        // In the panel's sheets: the Touch Bar has a Save and a Replace too, which can't be clicked.
        let save = app.sheets.buttons["Save"].firstMatch
        XCTAssertTrue(save.isEnabled, "Save is disabled\n\(app.debugDescription)", file: file, line: line)
        save.click()
        if replacing {
            let replace = app.sheets.buttons["Replace"].firstMatch
            XCTAssertTrue(replace.waitForExistence(timeout: 10), "no Replace confirmation\n\(app.debugDescription)",
                          file: file, line: line)
            keepScreenshot("\(shot)-replace")
            replace.click()
        }
        XCTAssertTrue(format.waitForNonExistence(timeout: 10), "the Save As panel stayed open\n\(app.debugDescription)",
                      file: file, line: line)
        XCTAssertTrue(app.text(containing: "Saving “").waitForNonExistence(timeout: 30),
                      "the save is still running\n\(app.debugDescription)", file: file, line: line)
    }

    /// Waits up to 30 s for `folder` to hold exactly `names` (`.DS_Store` aside, which Finder and the
    /// save panel may write and the app never removes).
    private func waitForListing(of folder: URL, _ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, (try? Self.listing(of: folder)) != names {
            XCTAssertNotEqual(app.state, .notRunning, "the app crashed while saving", file: file, line: line)
            _ = app.text(containing: "could not be saved").waitForExistence(timeout: 0.5)
        }
        XCTAssertEqual(try Self.listing(of: folder), names, "\(folder.lastPathComponent)\n\(app.debugDescription)",
                       file: file, line: line)
    }

    /// Names in `folder`, hidden files included, `.DS_Store` aside.
    private static func listing(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }.sorted()
    }

    /// A stored ZIP with `blob.bin` (2.5 MB of random bytes) and `readme.txt`, made with `/usr/bin/zip`
    /// from files in `scratch`.
    private static func writeSplitSource(to archive: URL, from scratch: URL) throws {
        var blob = Data(count: 2_500_000)
        blob.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let blobURL = scratch.appendingPathComponent("blob.bin")
        let readmeURL = scratch.appendingPathComponent("readme.txt")
        try blob.write(to: blobURL)
        try Data("Split me.\n".utf8).write(to: readmeURL)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-0", "-j", archive.path, blobURL.path, readmeURL.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: archive.path])
        }
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Selects hello.txt, removes it with the toolbar's －, and presses ⌘S.
    private func removeHelloAndSave(file: StaticString = #filePath, line: UInt = #line) {
        let hello = app.row("hello.txt")
        waitForArchive(hello, file: file, line: line)
        hello.select()
        XCTAssertTrue(app.deleteButton.isEnabled, file: file, line: line)
        app.deleteButton.click()
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt"], file: file, line: line)
        app.typeKey("s", modifierFlags: .command)
    }

    /// Names in the work folder (the archive's folder), hidden files included.
    private func directoryListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workDirectory.path).sorted()
    }
}
