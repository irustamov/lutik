import AppKit
import CryptoKit
import XCTest
import zlib

/// The pre-release Mac checks that need neither Finder nor System Settings
/// (the release checklist), the English-only launch, and
/// the data-safety items a window can run on its own launched app and its own disk images.
///
/// Desktop rules: this class only drives its own
/// target app. The force-quit test kills only the Lutik process whose bundle sits next to this
/// test runner (this build's own app), by PID.
///
/// Xcode signs the macOS UI test runner with app-sandbox, so these tests can't run hdiutil,
/// python3 or dd, or write outside the runner's container. The disk images come from
/// `scripts/fixtures/mac-ui-volumes.sh attach DIR` (attached with `-nobrowse`, so Finder never
/// shows them), passed as TEST_RUNNER_KERNIR_MAC_UI_VOLUMES=DIR; without it those tests skip.
final class OwnerChecksUITests: KernirMacUITestCase {

    // MARK: - Settings and About

    func testSettingsWindowLight() throws {
        try checkSettingsWindow(appearance: "light")
    }

    func testSettingsWindowDark() throws {
        try checkSettingsWindow(appearance: "dark")
    }

    /// ⌘, opens a small Settings window with the Quick Look section and its button. The button
    /// isn't clicked: it opens System Settings, which is another app (the URL it opens is
    /// checked in KernirMacTests' SettingsViewTests; the page System Settings lands on stays
    /// on the manual checklist). The screenshot is for the "looks like a normal Mac settings
    /// window" judgement.
    private func checkSettingsWindow(appearance: String) throws {
        // `-KernirAppearance` sets the app's appearance when the archive window opens, so the
        // runner's own light or dark setting can't leak into the screenshot.
        app.launchArguments += ["-KernirAppearance", appearance]
        try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "⌘, opened no Settings window\n\(app.debugDescription)")
        let open = settings.buttons["Open Login Items & Extensions…"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "no Open Login Items & Extensions… button")
        // The Section header. CI's failure tree lists it as `StaticText … label: 'Quick Look'`,
        // yet neither staticTexts["Quick Look"] nor a value/label predicate on staticTexts ever
        // matched it (runs 42718794297, 42721544029). Query any element type, and fall back to
        // the window's accessibility tree, which is what that failure output printed.
        let header = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@", "Quick Look", "Quick Look", "Quick Look"))
            .firstMatch
        XCTAssertTrue(header.exists || settings.debugDescription.contains("label: 'Quick Look'"),
                      "no Quick Look section\n\(settings.debugDescription)")
        XCTAssertTrue(settings.staticText(containing: "Login Items & Extensions → Quick Look").exists)
        XCTAssertTrue(open.isEnabled)
        XCTAssertLessThanOrEqual(settings.frame.width, 600, "the Settings window isn't small")

        // ⌘, again brings the same window forward instead of opening a second one.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.matching(identifier: "Settings").count, 1)

        attachScreenshot(of: settings, name: "settings-\(appearance)")
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
    }

    /// Lutik > About Lutik: the standard About window, whose scrolling credits include
    /// libarchive's license with its line breaks kept.
    func testAboutWindowCreditsKeepLibarchiveLicense() throws {
        app.launch()
        let about = app.openMenu("Lutik", item: "About Lutik")
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()

        let credits = app.textViews.firstMatch
        XCTAssertTrue(credits.waitForExistence(timeout: 5), "no credits in the About window\n\(app.debugDescription)")
        let text = try XCTUnwrap(credits.value as? String, "the credits have no text")
        XCTAssertTrue(text.contains("Acknowledgements"), text)
        XCTAssertTrue(text.contains("libarchive"), text)
        // One line per license line, as in THIRD_PARTY_NOTICES.md, not one long paragraph.
        XCTAssertTrue(text.contains("libarchive contributors\nAll rights reserved."), text)
        XCTAssertTrue(text.contains("with or without\nmodification"), text)
        XCTAssertFalse(text.contains("```"), "a markdown fence leaked into the credits")

        // The standard About panel isn't in `app.windows`; shoot whatever holds the credits.
        let panel = [app.windows.firstMatch, app.dialogs.firstMatch].first { $0.exists } ?? credits
        attachScreenshot(of: panel, name: "about")
    }

    // Dragging a row onto a folder in the same window now moves it; see
    // MoveUITests.testDragFileOntoFolderMovesItIn, which replaces the old "does nothing" check.

    // MARK: - English only

    /// The app ships English only. With Russian as the
    /// language and region for this launch only, no window, menu, sheet or alert shows
    /// Cyrillic. The fixtures used have ASCII names only, so any Cyrillic is the app's.
    func testRussianLanguageShowsEnglishOnly() throws {
        app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        assertNoCyrillic("archive window")

        for menu in ["Lutik", "File", "Edit", "View", "Window", "Help"] {
            let item = app.menuBars.menuBarItems[menu]
            XCTAssertTrue(item.exists, "no \(menu) menu (localized title?)\n\(app.menuBars.firstMatch.debugDescription)")
            item.click()
            assertNoCyrillic("\(menu) menu")
            app.typeKey(.escape, modifierFlags: [])
        }

        // A context menu on a row.
        hello.nameCenter.rightClick()
        assertNoCyrillic("row context menu")
        app.typeKey(.escape, modifierFlags: [])

        // Settings.
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        assertNoCyrillic("Settings window")
        settings.typeKey("w", modifierFlags: .command)

        // The standard About window.
        app.openMenu("Lutik", item: "About Lutik").click()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        assertNoCyrillic("About window")
        app.typeKey("w", modifierFlags: .command)

        // An unsaved edit, then the close confirmation sheet.
        hello.select()
        app.deleteButton.click()
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5))
        app.windows.firstMatch.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "no save confirmation\n\(app.debugDescription)")
        assertNoCyrillic("close confirmation sheet")
        app.typeKey(.escape, modifierFlags: [])

        // An error alert, in a fresh Russian launch: openFixture quits this one (with its
        // unsaved edit) first, since a second open would start a second Lutik.
        try openFixture("corrupt/random.zip")
        XCTAssertTrue(app.text(containing: "isn't a supported archive").waitForExistence(timeout: 10),
                      "no error for random bytes\n\(app.debugDescription)")
        assertNoCyrillic("error alert")
    }

    /// Fails if any element of the app (titles, labels, values) contains a Cyrillic letter.
    private func assertNoCyrillic(_ place: String, file: StaticString = #filePath, line: UInt = #line) {
        let tree = app.debugDescription
        let cyrillic = tree.split(separator: "\n").filter {
            $0.range(of: "\\p{Script=Cyrillic}", options: .regularExpression) != nil
        }
        XCTAssertTrue(cyrillic.isEmpty, "Cyrillic in the \(place):\n\(cyrillic.joined(separator: "\n"))",
                      file: file, line: line)
    }

    // MARK: - Data safety

    /// Saving onto a full disk: a clear error, and the original is unchanged with nothing left
    /// next to it.
    func testSaveOntoFullDiskKeepsOriginal() throws {
        // A 20 MB volume holding deflate.zip and a filler file up to the last byte.
        let volume = try preparedVolume("full")
        let archive = volume.appendingPathComponent("deflate.zip")
        let before = try Self.sha256(of: archive)
        let listingBefore = try Self.listing(of: volume)

        open(archive)
        removeHelloAndSave()

        let error = app.text(containing: "could not be saved")
        XCTAssertTrue(error.waitForExistence(timeout: 20), "no save error on a full disk\n\(app.debugDescription)")
        attachScreenshot(of: app.windows.firstMatch, name: "full-disk-error")
        XCTAssertEqual(try Self.sha256(of: archive), before, "the original changed")
        XCTAssertEqual(try Self.listing(of: volume), listingBefore, "files were left next to the archive")

        app.sheets.buttons["OK"].firstMatch.click()
        XCTAssertFalse(app.row("hello.txt").exists, "the unsaved edit was lost")
        XCTAssertEqual(try Self.sha256(of: archive), before)
    }

    /// An archive on a read-only volume: editing is disabled, or saving tells the user and
    /// offers another place. Either way the original is never touched.
    func testReadOnlyVolumeNeverTouchesOriginal() throws {
        let volume = try preparedVolume("readonly")
        let archive = volume.appendingPathComponent("deflate.zip")
        let before = try Self.sha256(of: archive)

        open(archive)
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        guard app.deleteButton.isEnabled else {
            XCTContext.runActivity(named: "Editing is disabled on the read-only volume") { _ in }
            XCTAssertEqual(try Self.sha256(of: archive), before)
            return
        }
        app.deleteButton.click()
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5))
        app.typeKey("s", modifierFlags: .command)

        // Something must tell the user: an alert, or a save panel for another place.
        let told = NSPredicate { _, _ in
            self.app.sheets.firstMatch.exists || self.app.dialogs.firstMatch.exists
        }
        expectation(for: told, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        attachScreenshot(of: app.windows.firstMatch, name: "read-only-save")
        XCTAssertNotEqual(app.state, .notRunning, "the app crashed")
        XCTAssertEqual(try Self.sha256(of: archive), before, "the original on the read-only volume changed")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The archive changes on disk while the window has an unsaved edit. ⌘S must show the
    /// stock "changed by another application" handling, never silently overwrite the change.
    func testChangedOnDiskIsNotSilentlyOverwritten() throws {
        let archive = try openFixture("zip/deflate.zip")
        let hello = app.row("hello.txt")
        waitForArchive(hello)
        hello.select()
        app.deleteButton.click()
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5))

        // Another app replaces the file: store.zip's bytes, a minute newer.
        let replacement = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("zip/store.zip"))
        try replacement.write(to: archive, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: archive.path)
        let external = try Self.sha256(of: archive)

        app.typeKey("s", modifierFlags: .command)
        let notice = app.text(containing: "changed by another application")
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "no \"changed by another application\" notice\n\(app.debugDescription)")
        attachScreenshot(of: app.windows.firstMatch, name: "changed-on-disk")
        XCTAssertEqual(try Self.sha256(of: archive), external, "the other app's change was overwritten")

        // The stock alert offers Save and Don't Save, no Cancel, so Escape does nothing. Its
        // buttons carry a title ("Don’t Save", curly apostrophe) and no label.
        let dontSave = NSPredicate(format: "title BEGINSWITH %@ OR label BEGINSWITH %@", "Don", "Don")
        app.sheets.firstMatch.buttons.matching(dontSave).firstMatch.click()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try Self.sha256(of: archive), external, "the other app's change was overwritten")
    }

    /// Force-quit mid-save of a 1 GiB archive: the original is byte-identical and no
    /// temporary file is visible next to it (or it's gone after the next launch).
    func testForceQuitMidSaveKeepsOriginal() throws {
        let archive = workDirectory.appendingPathComponent("big.zip")
        // 1 GiB of random bytes as a Deflate entry. A repack keeps Deflate and compresses all of
        // it again (~15 s at ~70 MiB/s), so the kill lands mid-write. A stored entry was copied
        // in about a second, and the kill came after the save.
        try Self.writeBigZip(to: archive)
        let before = try Self.streamingSHA256(of: archive)
        let listingBefore = try Self.listing(of: workDirectory)

        open(archive)
        let small = app.row("small.txt")
        waitForArchive(small, timeout: 30)
        small.select()
        app.deleteButton.click()
        XCTAssertTrue(small.waitForNonExistence(timeout: 5))
        app.typeKey("s", modifierFlags: .command)

        let saving = app.text(containing: "Saving “big.zip”")
        guard saving.waitForExistence(timeout: 10) else {
            throw XCTSkip("The save finished before its progress sheet was seen; no mid-save moment to quit at.")
        }
        let pid = try ownAppPID()
        if kill(pid, SIGKILL) != 0 {
            // The runner's sandbox may refuse to signal another app. XCUITest's terminate goes
            // through testmanagerd and doesn't wait for the save either.
            let error = errno
            XCTContext.runActivity(named: "kill(\(pid)) failed with errno \(error); terminating through XCUITest") { _ in }
            app.terminate()
        }
        let ended = NSPredicate { _, _ in self.app.state == .notRunning }
        expectation(for: ended, evaluatedWith: nil)
        waitForExpectations(timeout: 10)

        // NSDocument swaps the finished file in while the sheet is still up (the saved archive is
        // reopened under it), so a late kill can find the save done. Both are safe; anything else
        // is data loss: the file is either the untouched original or the complete saved archive.
        let after = try Self.streamingSHA256(of: archive)
        let entries = try Self.run("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n").sorted()
        if after == before {
            XCTAssertEqual(entries, ["big.bin", "small.txt"])
        } else {
            XCTAssertEqual(entries, ["big.bin"], "the original changed and isn't the saved archive")
            XCTAssertNoThrow(try Self.run("/usr/bin/unzip", ["-tqq", archive.path]), "the saved archive is damaged")
        }
        var listing = try Self.listing(of: workDirectory)
        if listing != listingBefore {
            // Allowed if the next launch cleans it up.
            app.launch()
            _ = app.menuBars.firstMatch.waitForExistence(timeout: 10)
            Thread.sleep(forTimeInterval: 3)
            listing = try Self.listing(of: workDirectory)
        }
        XCTAssertEqual(listing, listingBefore, "a temporary file stayed next to the archive")
        if after != before {
            throw XCTSkip("The kill came after the save had finished: the saved archive is complete, but no mid-write moment was hit.")
        }
    }

    // MARK: - Helpers

    /// Selects hello.txt, removes it with the toolbar's －, and presses ⌘S.
    private func removeHelloAndSave(file: StaticString = #filePath, line: UInt = #line) {
        let hello = app.row("hello.txt")
        waitForArchive(hello, file: file, line: line)
        hello.select()
        app.deleteButton.click()
        XCTAssertTrue(hello.waitForNonExistence(timeout: 5), file: file, line: line)
        app.typeKey("s", modifierFlags: .command)
    }

    private func attachScreenshot(of element: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The PID of this build's own Lutik: the running app whose bundle is in the same
    /// products folder as this test runner. Never matched by name or bundle identifier alone,
    /// so an installed /Applications/Lutik.app is never touched.
    private func ownAppPID() throws -> pid_t {
        let own = Self.ownInstances()
        guard own.count == 1, let app = own.first else {
            throw XCTSkip("Expected exactly one Lutik from this build, found \(own.map { $0.bundleURL?.path ?? "?" }).")
        }
        return app.processIdentifier
    }

    /// A volume that `scripts/fixtures/mac-ui-volumes.sh` attached at `<DIR>/<name>`, where DIR
    /// is TEST_RUNNER_KERNIR_MAC_UI_VOLUMES. Skips the test when the script hasn't run.
    private func preparedVolume(_ name: String) throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["KERNIR_MAC_UI_VOLUMES"], !directory.isEmpty else {
            throw XCTSkip("Run scripts/fixtures/mac-ui-volumes.sh attach DIR and set TEST_RUNNER_KERNIR_MAC_UI_VOLUMES=DIR.")
        }
        let volume = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let archive = volume.appendingPathComponent("deflate.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw XCTSkip("\(archive.path) is missing; run scripts/fixtures/mac-ui-volumes.sh attach \(directory).")
        }
        return volume
    }

    /// Writes a zip: small.txt stored, then big.bin with `randomBytes` of random data as Deflate
    /// made of stored blocks (no compression work here; a repack has to compress it for real).
    /// Plain zip (1 GiB fits 32-bit sizes); each CRC and compressed size is patched into its
    /// local header after the data.
    private static func writeBigZip(to url: URL, randomBytes: Int = 1 << 30) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        func addEntry(_ name: String, size: Int, deflate: Bool = false,
                      body: ((Data) throws -> Void) throws -> Void) throws {
            let headerOffset = try handle.offset()
            let nameBytes = Data(name.utf8)
            func header(central: Bool, crc: UInt32, compressedSize: Int) -> Data {
                var data = Data()
                data.appendLittleEndian(central ? UInt32(0x0201_4b50) : UInt32(0x0403_4b50))
                if central { data.appendLittleEndian(UInt16(20)) } // version made by
                data.appendLittleEndian(UInt16(20)) // version needed
                data.appendLittleEndian(UInt16(0)) // flags
                data.appendLittleEndian(UInt16(deflate ? 8 : 0)) // method: Deflate or stored
                data.appendLittleEndian(UInt16(0)) // time
                data.appendLittleEndian(UInt16((2026 - 1980) << 9 | 1 << 5 | 2)) // date: 2026-01-02
                data.appendLittleEndian(crc)
                data.appendLittleEndian(UInt32(compressedSize))
                data.appendLittleEndian(UInt32(size)) // size
                data.appendLittleEndian(UInt16(nameBytes.count))
                data.appendLittleEndian(UInt16(0)) // extra field length
                if central {
                    data.appendLittleEndian(UInt16(0)) // comment length
                    data.appendLittleEndian(UInt16(0)) // disk number
                    data.appendLittleEndian(UInt16(0)) // internal attributes
                    data.appendLittleEndian(UInt32(0)) // external attributes
                    data.appendLittleEndian(UInt32(headerOffset))
                }
                data.append(nameBytes)
                return data
            }
            try handle.write(contentsOf: header(central: false, crc: 0, compressedSize: 0))
            var crc = crc32(0, nil, 0)
            var written = 0
            var compressedSize = 0
            func emit(_ bytes: Data) throws {
                try handle.write(contentsOf: bytes)
                compressedSize += bytes.count
            }
            // A Deflate stored block: the final-block bit and type 00 in one byte, then LEN and ~LEN.
            func storedBlock(_ bytes: Data, final: Bool) throws {
                var block = Data([final ? 1 : 0])
                block.appendLittleEndian(UInt16(bytes.count))
                block.appendLittleEndian(~UInt16(bytes.count))
                try emit(block)
                try emit(bytes)
            }
            try body { chunk in
                crc = chunk.withUnsafeBytes {
                    crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
                }
                written += chunk.count
                guard deflate else { return try emit(chunk) }
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    let end = min(start + 0xFFFF, chunk.endIndex)
                    try storedBlock(chunk[start..<end], final: false)
                    start = end
                }
            }
            if deflate { try storedBlock(Data(), final: true) }
            precondition(written == size, "\(name): wrote \(written) of \(size) bytes")
            let end = try handle.offset()
            try handle.seek(toOffset: headerOffset + 14) // the local header's CRC and compressed size
            var patch = Data()
            patch.appendLittleEndian(UInt32(crc))
            patch.appendLittleEndian(UInt32(compressedSize))
            try handle.write(contentsOf: patch)
            try handle.seek(toOffset: end)
            centralDirectory.append(header(central: true, crc: UInt32(crc), compressedSize: compressedSize))
            entryCount += 1
        }

        let small = Data("remove me\n".utf8)
        try addEntry("small.txt", size: small.count) { write in try write(small) }
        try addEntry("big.bin", size: randomBytes, deflate: true) { write in
            var chunk = Data(count: 8 << 20)
            var left = randomBytes
            while left > 0 {
                let count = min(left, chunk.count)
                chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
                try write(chunk.prefix(count))
                left -= count
            }
        }

        let directoryOffset = try handle.offset()
        try handle.write(contentsOf: centralDirectory)
        var end = Data()
        end.appendLittleEndian(UInt32(0x0605_4b50))
        end.appendLittleEndian(UInt16(0)) // this disk
        end.appendLittleEndian(UInt16(0)) // disk with the central directory
        end.appendLittleEndian(entryCount)
        end.appendLittleEndian(entryCount)
        end.appendLittleEndian(UInt32(centralDirectory.count))
        end.appendLittleEndian(UInt32(directoryOffset))
        end.appendLittleEndian(UInt16(0)) // comment length
        try handle.write(contentsOf: end)
    }

    /// Runs `tool` and returns its standard output; throws if it exits non-zero.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        let errorOutput = Pipe()
        process.standardError = errorOutput
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "OwnerChecksUITests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(errorText)",
            ])
        }
        return text
    }

    /// Names in `directory`, hidden files included, sorted.
    /// The names in `directory`. The system's `.TemporaryItems` folder (made by safe saves on a
    /// non-boot volume, then left there empty) counts only by what is inside it, so an emptied one
    /// is not a leftover but a temporary file in it is.
    private static func listing(of directory: URL) throws -> [String] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(atPath: directory.path).flatMap { name -> [String] in
            guard name == ".TemporaryItems" else { return [name] }
            let inside = directory.appendingPathComponent(name).path
            return (fm.subpaths(atPath: inside) ?? []).map { "\(name)/\($0)" }
        }.sorted()
    }

    /// SHA-256 without reading a 1 GiB file into memory.
    private static func streamingSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension XCUIElement {
    /// The middle of a row's Name text, for drags (see `select()` on hittability).
    var nameCenter: XCUICoordinate {
        let name = cells.firstMatch.staticTexts.firstMatch
        return (name.exists ? name : self).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// A static text in this element whose value or label contains `text`.
    func staticText(containing text: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
