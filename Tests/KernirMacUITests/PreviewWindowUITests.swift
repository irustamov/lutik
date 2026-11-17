import AppKit
import XCTest

/// Quick Look on files inside an archive: Kernir's own preview window
/// opens on every type in `QuickLook/ql-types.zip`, follows ↑/↓, pages a multi-selection with
/// ←/→, gives the window back its preview state when it closes, and its Share and Open With
/// buttons act on the entry itself.
///
/// `ql-types.zip` holds Budget.csv, Table.tsv, Page.html, Page.xhtml, Logo.svg, Report.docx
/// (textutil), Sheet.xlsx, Deck.pptx (a minimal hand-built PresentationML package), Notes.txt and
/// Pixel.png. The stand-ins (`PreviewStrategy`) cover csv/tsv/html/xhtml (text), docx/xlsx/pptx
/// (rendered page) and svg (rendered, text fallback); txt and png show as they are.
///
/// The preview view's content is a remote view: the accessibility tree shows neither its spinner
/// nor its page. So "no stuck spinner" is checked by eye on the attached window shots, taken
/// after the spinner would have gone; the tests assert that the window opens, stays open, and
/// closes again. Open With runs with `-KernirOpenWithDryRun YES` (Debug builds): Kernir shows
/// what it would open in an alert and never launches another app. Folders (Open With off) are
/// covered by the hosted PreviewWindowSourceTests: ql-types.zip has none.
final class PreviewWindowUITests: KernirMacUITestCase {
    private static let entries = ["Budget.csv", "Table.tsv", "Page.html", "Page.xhtml", "Logo.svg",
                                  "Report.docx", "Sheet.xlsx", "Deck.pptx", "Notes.txt", "Pixel.png"]

    override func setUp() async throws {
        try await super.setUp()
        // Never launch a third-party app (own PIDs only): Open With only reports.
        app.launchArguments += ["-KernirOpenWithDryRun", "YES"]
        // The preview neither reads nor saves an autosaved frame: it opens over the archive
        // window every run, never where an earlier run (or the user) left it.
        app.launchArguments += ["-KernirPreviewFrameAutosave", "NO"]
    }

    /// No test leaves a full-screen Space on the test Mac: whatever state a test ended in, a
    /// Kernir window still in full screen leaves it before the app quits.
    override func tearDown() async throws {
        leaveFullScreenIfNeeded()
        try await super.tearDown()
    }

    private func openTypesArchive() throws {
        let source = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .appendingPathComponent("QuickLook/ql-types.zip")
        let copy = workDirectory.appendingPathComponent("ql-types.zip")
        try FileManager.default.copyItem(at: source, to: copy)
        open(copy)
        waitForArchive(app.row("Budget.csv"))
    }

    /// Kernir's preview window (accessibility identifier "preview"), whatever its element type:
    /// windowed it is a floating panel that can't become main, which XCUITest reports as a Dialog,
    /// not a Window; in full screen it can become main and may show as a Window. It is a direct
    /// child of the application; its toolbar items use other identifiers ("preview.share", ...).
    private var preview: XCUIElement {
        app.children(matching: .any).matching(NSPredicate(format: "identifier == %@", "preview")).firstMatch
    }

    /// Kernir's top-level windows, the preview included: every titled Window, plus the element
    /// with identifier "preview" whatever its type (a Dialog windowed). Other dialogs (the Open
    /// With dry-run alert) don't count, nor the untitled strip AppKit adds at the top of the
    /// screen while a window is in full screen ("Window {0,0,1728,33}", run-022908). One query,
    /// so a preview turning from Dialog into Window (into or out of full screen) is never counted
    /// twice or missed between two reads.
    private var topLevelWindows: XCUIElementQuery {
        app.children(matching: .any).matching(NSPredicate(format: "(elementType == %lu AND title != %@) OR identifier == %@",
                                                          XCUIElement.ElementType.window.rawValue, "", "preview"))
    }

    /// How many windows Kernir shows, the preview included.
    private var windowCount: Int { topLevelWindows.count }

    /// Kernir's top-level windows, the preview included whether it is a Window or a Dialog.
    private var allWindows: [XCUIElement] { topLevelWindows.allElementsBoundByIndex }

    /// Waits until `windowCount` matches `format` (e.g. "count > %d") with `count`.
    private func waitForWindows(_ format: String, _ count: Int, timeout: TimeInterval,
                                file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format, count)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate.evaluate(with: ["count": windowCount]) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("windows: expected \(String(format: format, count)), got \(windowCount)\n\(app.debugDescription)",
                file: file, line: line)
    }

    /// Waits until the preview window's title is `title`.
    private func waitForTitle(_ title: String, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if preview.exists && preview.title == title { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("preview title: expected \(title), got \(preview.exists ? preview.title : "no preview")\n\(app.debugDescription)",
                file: file, line: line)
    }

    /// A toolbar button of the preview window, by its label or its toolbar item identifier.
    private func previewButton(_ label: String, identifier: String) -> XCUIElement {
        preview.toolbars.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@", label, identifier)).firstMatch
    }

    /// An element of the preview window's toolbar by its label only: what a button reads.
    private func previewToolbarItem(labeled label: String) -> XCUIElement {
        preview.toolbars.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Each stand-in waits this long before it is made (`-KernirPreviewStandInDelay`, Debug builds
    /// only), so a window closed or left right after Space is closed or left mid-render, rather
    /// than racing a ~0.3 s render against XCUI's click latency.
    private static let standInDelay: TimeInterval = 3

    private func delayStandIns() {
        app.launchArguments += ["-KernirPreviewStandInDelay", "\(Self.standInDelay)"]
    }

    /// Attaches a shot of the preview window only: never a full-screen shot of the runner's desktop.
    private func attachShot(of window: XCUIElement, named name: String, to activity: (any XCTActivity)? = nil) {
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        if let activity { activity.add(shot) } else { add(shot) }
    }

    /// Space on each type opens the preview window titled with the entry's own name; after the
    /// stand-in is made and any spinner would have stopped, it is still there (shot attached);
    /// Space closes it.
    func testSpaceOnEachType() throws {
        try openTypesArchive()
        let before = windowCount
        for name in Self.entries {
            XCTContext.runActivity(named: name) { activity in
                let row = app.row(name)
                XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
                row.select()  // macOS 26 rows are "not hittable": see `select()`
                app.archiveOutline.typeKey(.space, modifierFlags: [])
                waitForWindows("count > %d", before, timeout: 10)
                // A rendered page takes ~0.3 s (run 2); a spinner still there after 4 s is the bug.
                Thread.sleep(forTimeInterval: 4)
                guard preview.exists else {
                    XCTFail("\(name): no preview window\n\(app.debugDescription)")
                    return
                }
                XCTAssertEqual(preview.title, name, "\(name): not titled with the entry's own name")
                attachShot(of: preview, named: "ql-\(name)", to: activity)
                XCTAssertTrue(row.isSelected, "\(name): the selection moved while previewing")
                app.typeKey(.space, modifierFlags: [])
                waitForWindows("count == %d", before, timeout: 5)
            }
        }
    }

    /// ↓ and ↑ typed into the preview window move the table's selection, and the window stays
    /// open on the new row (E2), as in Finder.
    func testArrowKeysInPreview() throws {
        try openTypesArchive()
        let before = windowCount
        let names = app.visibleRowNames
        let first = try XCTUnwrap(names.first, app.debugDescription)
        let second = try XCTUnwrap(names.dropFirst().first, app.debugDescription)
        app.row(first).select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        Thread.sleep(forTimeInterval: 2)

        app.typeKey(.downArrow, modifierFlags: [])
        waitForTitle(second)
        XCTAssertTrue(app.row(second).isSelected, "↓ did not select \(second)\n\(app.debugDescription)")
        XCTAssertTrue(preview.exists, "↓ closed the preview\n\(app.debugDescription)")
        attachShot(of: preview, named: "ql-arrow-down-\(second)")

        app.typeKey(.upArrow, modifierFlags: [])
        waitForTitle(first)
        XCTAssertTrue(app.row(first).isSelected, "↑ did not select \(first)\n\(app.debugDescription)")
        XCTAssertTrue(preview.exists, "↑ closed the preview\n\(app.debugDescription)")

        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)
    }

    /// A multi-selection pages with → and ←, "2 of 2" in the title; the table's selection stays.
    func testPagingAMultiSelection() throws {
        try openTypesArchive()
        let before = windowCount
        app.row("Budget.csv").select()
        XCUIElement.perform(withKeyModifiers: .command) { app.row("Notes.txt").select() }
        XCTAssertTrue(app.row("Budget.csv").isSelected && app.row("Notes.txt").isSelected, app.debugDescription)
        // Previewed in the table's order.
        let names = app.visibleRowNames
        let first = try XCTUnwrap(names.first { $0 == "Budget.csv" || $0 == "Notes.txt" })
        let second = first == "Budget.csv" ? "Notes.txt" : "Budget.csv"
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        waitForTitle("\(first) — 1 of 2")

        app.typeKey(.rightArrow, modifierFlags: [])
        waitForTitle("\(second) — 2 of 2")
        attachShot(of: preview, named: "ql-page-2-of-2")
        // Past the end nothing moves.
        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(preview.title, "\(second) — 2 of 2")
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForTitle("\(first) — 1 of 2")
        XCTAssertTrue(app.row("Budget.csv").isSelected && app.row("Notes.txt").isSelected,
                      "paging changed the selection\n\(app.debugDescription)")

        app.typeKey(.escape, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)
    }

    /// Esc closes the preview from the preview's side; the window forgets its preview, so the
    /// next Space in the table opens it again instead of only "closing" it.
    func testEscapeThenSpaceReopens() throws {
        try openTypesArchive()
        let before = windowCount
        app.row("Report.docx").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        Thread.sleep(forTimeInterval: 2)
        app.typeKey(.escape, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)

        app.row("Report.docx").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)
    }

    // MARK: - Share and Open With

    /// Share opens the system's share picker for the entry; Esc dismisses it and the preview stays.
    func testSharePickerAppears() throws {
        try openTypesArchive()
        let before = windowCount
        app.row("Budget.csv").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        Thread.sleep(forTimeInterval: 2)

        let share = previewButton("Share", identifier: "preview.share")
        XCTAssertTrue(share.waitForExistence(timeout: 5), "no Share button\n\(app.debugDescription)")
        share.click()
        // Not `app.menus.firstMatch`: that is the menu bar's Apple menu, there all the time. The
        // picker is the menu (or popover) that holds the share services: AirDrop, Edit Extensions….
        let shareItem = NSPredicate(format: "title == %@ OR label == %@ OR title BEGINSWITH %@ OR label BEGINSWITH %@",
                                    "AirDrop", "AirDrop", "Edit Extensions", "Edit Extensions")
        let picker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType == %lu OR elementType == %lu",
                                  XCUIElement.ElementType.menu.rawValue, XCUIElement.ElementType.popover.rawValue))
            .containing(shareItem).firstMatch
        let pickerShown = picker.waitForExistence(timeout: 5)
        // The tree while the picker is open, for the run's record (its element type on this macOS).
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ql-share-picker-tree"
        tree.lifetime = .keepAlways
        add(tree)
        XCTAssertTrue(pickerShown, "no share picker\n\(app.debugDescription)")
        attachShot(of: preview, named: "ql-share-picker")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "the picker stayed\n\(app.debugDescription)")
        XCTAssertTrue(preview.exists, "Esc in the picker closed the preview\n\(app.debugDescription)")

        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)
    }

    /// Open With lists the apps for the entry, the default one first and named so; picking one
    /// opens the entry under its real name (dry run: an alert says what would have opened), never
    /// its stand-in (Budget.csv.txt).
    func testOpenWithListsApps() throws {
        try openTypesArchive()
        let before = windowCount
        app.row("Budget.csv").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        Thread.sleep(forTimeInterval: 2)

        let openWith = previewButton("Open With", identifier: "preview.openWith")
        XCTAssertTrue(openWith.waitForExistence(timeout: 5), "no Open With button\n\(app.debugDescription)")
        XCTAssertTrue(openWith.isEnabled)
        // On macOS 26 the menu toolbar item is two elements: the "Open With" button (opens in the
        // default app) and a MenuButton chevron next to it, which shows the menu.
        let chevron = preview.toolbars.firstMatch.groups
            .containing(NSPredicate(format: "elementType == %lu AND label == %@",
                                    XCUIElement.ElementType.button.rawValue, "Open With"))
            .menuButtons.firstMatch
        XCTAssertTrue(chevron.exists, "no Open With menu chevron\n\(app.debugDescription)")
        chevron.click()
        // Not `app.menus.firstMatch` (the menu bar's Apple menu): the menu with the default app.
        let isDefault = NSPredicate(format: "elementType == %lu AND title ENDSWITH %@",
                                    XCUIElement.ElementType.menuItem.rawValue, " (default)")
        let menu = app.menus.containing(isDefault).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no Open With menu\n\(app.debugDescription)")
        let items = menu.menuItems.allElementsBoundByIndex.filter { !$0.title.isEmpty }
        XCTAssertGreaterThan(items.count, 0, "no apps for Budget.csv\n\(app.debugDescription)")
        let defaultItem = try XCTUnwrap(items.first, app.debugDescription)
        XCTAssertTrue(defaultItem.title.hasSuffix("(default)"), "the first app isn't the default: \(items.map(\.title))")
        XCTAssertEqual(items.filter { $0.title.hasSuffix("(default)") }.count, 1, "\(items.map(\.title))")
        attachShot(of: preview, named: "ql-open-with-menu")
        let appName = String(defaultItem.title.dropLast(" (default)".count))
        defaultItem.click()

        let report = app.text(containing: "Open With dry run")
        XCTAssertTrue(report.waitForExistence(timeout: 10), "nothing was opened\n\(app.debugDescription)")
        let text = (report.value as? String) ?? report.label
        XCTAssertTrue(text.contains("“Budget.csv”"), "not the entry's real file: \(text)")
        XCTAssertFalse(text.contains(".txt"), "the stand-in was opened: \(text)")
        XCTAssertTrue(text.contains("“\(appName)”"), "not the chosen app: \(text)")
        app.buttons["OK"].firstMatch.click()
        XCTAssertTrue(report.waitForNonExistence(timeout: 5), "the dry-run alert stayed\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Closing and switching windows
    // Asserted: which windows exist, the selections, that Kernir keeps running. Whether a spinner
    // got stuck can only be judged from the attached window shots (see the type's comment).

    /// An archive window found by its title (the document's name), not by position: the preview
    /// is a window too.
    private func archiveWindow(_ name: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title BEGINSWITH %@ AND identifier != %@", name, "preview")).firstMatch
    }

    /// The row `name` in `window`'s table.
    private func row(_ name: String, in window: XCUIElement) -> XCUIElement {
        window.outlines.firstMatch.outlineRows.containing(
            NSPredicate(format: "elementType == %lu AND value == %@",
                        XCUIElement.ElementType.staticText.rawValue, name)
        ).firstMatch
    }

    /// The Name text of `window`'s visible rows, top to bottom.
    private func rowNames(in window: XCUIElement) -> [String] {
        window.outlines.firstMatch.outlineRows.allElementsBoundByIndex.compactMap { row in
            row.cells.firstMatch.staticTexts.firstMatch.value as? String
        }
    }

    /// Makes the archive window `name` (its file name, "Alpha.zip") key through the Window menu:
    /// a click in its title bar can land on the floating preview or on a toolbar control. Its
    /// item reads "Alpha.zip (ZIP · 10 KB)"; the preview's item is the entry's name, which never
    /// begins with the archive's file name (the preview is in the Window menu too: it never sets
    /// `isExcludedFromWindowsMenu`). Returns once the window is hittable, i.e. in front: the
    /// menu pick only asks AppKit to bring it there.
    private func activate(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        app.menuBars.menuBarItems["Window"].click()
        let item = app.menuBars.menuItems.matching(NSPredicate(format: "identifier == %@ AND title BEGINSWITH %@",
                                                               "makeKeyAndOrderFront:", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Window menu item for \(name)\n\(app.debugDescription)",
                      file: file, line: line)
        item.click()
        let window = archiveWindow((name as NSString).deletingPathExtension)
        let inFront = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: window)
        XCTAssertEqual(XCTWaiter().wait(for: [inFront], timeout: 10), .completed,
                       "\(name) didn't come to the front\n\(app.debugDescription)", file: file, line: line)
    }

    /// Opens `url` in the Kernir this test already runs, as another window: `open(_:)` quits it
    /// first, and `XCUIApplication.open(_:)` on a running app starts a second Kernir.
    private func openInRunningApp(_ url: URL) throws {
        let running = try XCTUnwrap(Self.ownInstances().first { Self.isAlive($0.processIdentifier) },
                                    "no Kernir of this build is running")
        let bundle = try XCTUnwrap(running.bundleURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        let opened = expectation(description: "opened \(url.lastPathComponent)")
        // Called off the main thread: @Sendable, or Swift 6 makes it main-actor isolated (this
        // class is @MainActor) and it traps there.
        NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: configuration) { @Sendable _, _ in
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        rememberOwnInstances()
    }

    /// ⌘W while the preview is open: whichever window it closes, no preview stays and Kernir keeps
    /// running; the archive window closes cleanly after it.
    func testCommandWWithPreviewOpen() throws {
        try openTypesArchive()
        let archive = archiveWindow("ql-types")
        let before = windowCount
        app.row("Report.docx").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        Thread.sleep(forTimeInterval: 2)
        if preview.exists { attachShot(of: preview, named: "ql-before-cmd-w") }

        app.typeKey("w", modifierFlags: .command)
        waitForWindows("count < %d", before + 1, timeout: 5)
        XCTAssertFalse(preview.exists, "a preview stayed\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground)

        if archive.exists {
            archive.typeKey("w", modifierFlags: .command)
            waitForWindows("count == %d", 0, timeout: 5)
        }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(windowCount, 0, "a window came back\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The archive window's close button while the preview shows: the preview goes with the
    /// window, Kernir keeps running, and nothing reopens.
    func testClosingTheWindowClosesThePreview() throws {
        try openTypesArchive()
        let archive = archiveWindow("ql-types")
        let before = windowCount
        app.row("Sheet.xlsx").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        Thread.sleep(forTimeInterval: 2)

        // The floating preview opens over the archive window and may sit over the close button:
        // drag it by its title bar to the right, clear of the traffic lights.
        let closeButton = archive.buttons[XCUIIdentifierCloseWindow]
        if preview.frame.intersects(closeButton.frame.insetBy(dx: -8, dy: -8)) {
            let titleBar = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
            let dx = closeButton.frame.maxX + 40 - preview.frame.minX
            titleBar.press(forDuration: 0.5, thenDragTo: titleBar.withOffset(CGVector(dx: dx, dy: 0)))
        }
        XCTAssertTrue(closeButton.isHittable, "the preview covers the close button\n\(app.debugDescription)")
        closeButton.click()
        waitForWindows("count == %d", 0, timeout: 5)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(windowCount, 0, "a preview opened after the window closed\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The window closes while its stand-in is still rendering: the render must not open a
    /// preview afterwards. The stand-in is delayed (`standInDelay`), so the close lands
    /// mid-render.
    func testClosingTheWindowDuringTheRender() throws {
        delayStandIns()
        try openTypesArchive()
        let archive = archiveWindow("ql-types")
        let closeButton = archive.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.exists, app.debugDescription)
        app.row("Deck.pptx").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        // The entry is extracted by now; its stand-in isn't made yet, so no preview shows.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(windowCount, 1, "the preview opened before the delayed stand-in\n\(app.debugDescription)")
        closeButton.click()

        Thread.sleep(forTimeInterval: Self.standInDelay + 2)
        XCTAssertEqual(windowCount, 0, "a preview opened for a closed window\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Alpha shows the preview, then Beta becomes key: Alpha's preview ends. ↓ in Beta
    /// (previewing nothing) never moves Alpha's selection. Beta then previews, ↓ moves Beta's
    /// selection and never Alpha's, and Alpha has forgotten its preview: one Space there opens
    /// the preview again.
    func testSwitchingWindowsWithThePreviewOpen() throws {
        let source = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .appendingPathComponent("QuickLook/ql-types.zip")
        let alphaURL = workDirectory.appendingPathComponent("Alpha.zip")
        let betaURL = workDirectory.appendingPathComponent("Beta.zip")
        try FileManager.default.copyItem(at: source, to: alphaURL)
        try FileManager.default.copyItem(at: source, to: betaURL)
        open(alphaURL)
        let alpha = archiveWindow("Alpha")
        waitForArchive(row("Report.docx", in: alpha))
        try openInRunningApp(betaURL)
        let beta = archiveWindow("Beta")
        waitForArchive(row("Report.docx", in: beta))
        waitForWindows("count == %d", 2, timeout: 10)

        // Alpha previews Report.docx.
        activate("Alpha.zip")
        row("Report.docx", in: alpha).select()
        alpha.outlines.firstMatch.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", 2, timeout: 10)
        Thread.sleep(forTimeInterval: 2)

        // Beta becomes key (and main): Alpha's preview ends.
        activate("Beta.zip")
        waitForWindows("count == %d", 2, timeout: 5)
        XCTAssertFalse(preview.exists, "Alpha's preview stayed over Beta\n\(app.debugDescription)")

        // ↓ in Beta, which previews nothing: Beta's selection moves, Alpha's stays, no preview opens.
        let names = rowNames(in: beta)
        let top = try XCTUnwrap(names.first, app.debugDescription)
        let second = try XCTUnwrap(names.dropFirst().first, app.debugDescription)
        row(top, in: beta).select()
        beta.outlines.firstMatch.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(row(second, in: beta).isSelected, "↓ didn't move Beta's selection\n\(app.debugDescription)")
        XCTAssertTrue(row("Report.docx", in: alpha).isSelected, "↓ in Beta moved Alpha's selection\n\(app.debugDescription)")
        XCTAssertEqual(windowCount, 2, "↓ in Beta opened a preview\n\(app.debugDescription)")

        // Beta previews; ↓ in its preview moves Beta's selection only.
        let start = try XCTUnwrap(names.firstIndex(of: "Sheet.xlsx"), app.debugDescription)
        let next = try XCTUnwrap(names.dropFirst(start + 1).first, "Sheet.xlsx is the last row")
        row("Sheet.xlsx", in: beta).select()
        beta.outlines.firstMatch.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", 2, timeout: 10)
        Thread.sleep(forTimeInterval: 2)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForTitle(next)
        XCTAssertTrue(row(next, in: beta).isSelected, "↓ didn't move Beta's selection to \(next)\n\(app.debugDescription)")
        XCTAssertTrue(row("Report.docx", in: alpha).isSelected, "↓ moved Alpha's selection\n\(app.debugDescription)")
        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", 2, timeout: 5)

        // Alpha forgot its preview: Space opens it (rather than "closing" a stale one).
        activate("Alpha.zip")
        row("Report.docx", in: alpha).select()
        alpha.outlines.firstMatch.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", 2, timeout: 10)
        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", 2, timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Alpha's render is still running when Beta becomes key: the render must not open a preview
    /// for the window the user left. The stand-in is delayed (`standInDelay`), so the
    /// switch lands mid-render.
    func testSwitchingWindowsDuringTheRender() throws {
        delayStandIns()
        let source = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .appendingPathComponent("QuickLook/ql-types.zip")
        let alphaURL = workDirectory.appendingPathComponent("Alpha.zip")
        let betaURL = workDirectory.appendingPathComponent("Beta.zip")
        try FileManager.default.copyItem(at: source, to: alphaURL)
        try FileManager.default.copyItem(at: source, to: betaURL)
        open(alphaURL)
        let alpha = archiveWindow("Alpha")
        waitForArchive(row("Deck.pptx", in: alpha))
        try openInRunningApp(betaURL)
        let beta = archiveWindow("Beta")
        waitForArchive(row("Deck.pptx", in: beta))
        waitForWindows("count == %d", 2, timeout: 10)

        activate("Alpha.zip")
        row("Deck.pptx", in: alpha).select()
        alpha.outlines.firstMatch.typeKey(.space, modifierFlags: [])
        // The entry is extracted by now; its stand-in isn't made yet, so no preview shows.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(windowCount, 2, "the preview opened before the delayed stand-in\n\(app.debugDescription)")
        activate("Beta.zip")
        Thread.sleep(forTimeInterval: Self.standInDelay + 2)
        XCTAssertEqual(windowCount, 2, "a preview opened for a window the user left\n\(app.debugDescription)")

        // Alpha isn't left previewing: Space there opens the preview, and Space closes it.
        activate("Alpha.zip")
        row("Deck.pptx", in: alpha).select()
        alpha.outlines.firstMatch.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", 2, timeout: 10)
        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", 2, timeout: 5)
    }

    // MARK: - Index sheet (batch 3)

    /// Selects `names` (the first by a click, the rest by ⌘-click) and opens the preview on them;
    /// returns them in the table's order, which the preview keeps.
    private func previewMultiSelection(_ names: [String], before: Int) throws -> [String] {
        let first = try XCTUnwrap(names.first)
        app.row(first).select()
        for name in names.dropFirst() {
            XCUIElement.perform(withKeyModifiers: .command) { app.row(name).select() }
        }
        for name in names {
            XCTAssertTrue(app.row(name).isSelected, "\(name) isn't selected\n\(app.debugDescription)")
        }
        let ordered = app.visibleRowNames.filter { names.contains($0) }
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        waitForTitle("\(ordered[0]) — 1 of \(ordered.count)")
        return ordered
    }

    /// The index sheet's cells (`PreviewGridItem`, identifier "preview.grid.cell"): the Cell
    /// only, one per item; the collection view's item Group around it has the identifier too.
    private var gridCells: XCUIElementQuery {
        preview.descendants(matching: .cell).matching(identifier: "preview.grid.cell")
    }

    /// The index-sheet button is there for a multi-selection only.
    func testIndexSheetButtonOnlyForMultiSelection() throws {
        try openTypesArchive()
        let before = windowCount
        app.row("Notes.txt").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        waitForTitle("Notes.txt")
        XCTAssertTrue(previewButton("Share", identifier: "preview.share").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(previewButton("Index Sheet", identifier: "preview.grid").exists,
                       "an index sheet for one item\n\(app.debugDescription)")
        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)

        _ = try previewMultiSelection(["Budget.csv", "Notes.txt"], before: before)
        XCTAssertTrue(previewButton("Index Sheet", identifier: "preview.grid").waitForExistence(timeout: 5),
                      "no index-sheet button for two items\n\(app.debugDescription)")
        app.typeKey(.escape, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)
    }

    /// The index sheet shows one cell per item, titled "3 items"; a click on a cell shows that
    /// item; arrows and Return pick too; Esc goes back to the single view, a second Esc closes.
    func testIndexSheetShowsCellsAndPicks() throws {
        try openTypesArchive()
        let before = windowCount
        let names = try previewMultiSelection(["Budget.csv", "Notes.txt", "Pixel.png"], before: before)
        let grid = previewButton("Index Sheet", identifier: "preview.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: 5), app.debugDescription)

        grid.click()
        waitForTitle("3 items")
        XCTAssertEqual(gridCells.count, 3, "cells: \(gridCells.count)\n\(app.debugDescription)")
        let labels = gridCells.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(labels, names, "not the entries' real names in order")
        Thread.sleep(forTimeInterval: 2)  // thumbnails
        attachShot(of: preview, named: "ql-index-sheet")

        // A click shows that item.
        gridCells.element(boundBy: 1).click()
        waitForTitle("\(names[1]) — 2 of 3")
        XCTAssertEqual(gridCells.count, 0, "the sheet stayed\n\(app.debugDescription)")

        // → then Return: the third item.
        grid.click()
        waitForTitle("3 items")
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        waitForTitle("\(names[2]) — 3 of 3")

        // ← then Space: the second item.
        grid.click()
        waitForTitle("3 items")
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        waitForTitle("\(names[1]) — 2 of 3")

        // Esc in the sheet: back to the single view; Esc again closes the preview.
        grid.click()
        waitForTitle("3 items")
        app.typeKey(.escape, modifierFlags: [])
        waitForTitle("\(names[1]) — 2 of 3")
        XCTAssertTrue(preview.exists, "Esc in the sheet closed the preview\n\(app.debugDescription)")
        app.typeKey(.escape, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)
        XCTAssertTrue(app.row("Budget.csv").isSelected && app.row("Pixel.png").isSelected,
                      "the sheet changed the table's selection\n\(app.debugDescription)")
    }

    // MARK: - Full screen (batch 3)

    /// Whether `window` fills a screen, as it does in full screen (`fillsScreen`).
    private func isFullScreen(_ window: XCUIElement) -> Bool {
        window.exists && fillsScreen(window.frame)
    }

    /// Whether `frame` fills a screen, as a full-screen window does: the screen's full width,
    /// down to its bottom edge, its top no lower than the top strip plus a toolbar. In full
    /// screen the toolbar may move to a window of its own and the top strip isn't counted: on
    /// the 1728x1117 notched screen the frame is (0, 85, 1728, 1032) (run-022908). The strip is
    /// the notch's safe area or, on a screen without one, the menu bar's height. The preview
    /// windowed is far narrower. `frame` has a top-left origin at the main screen's top-left
    /// corner (XCUI and CGWindowList); `NSScreen` frames a bottom-left one at its bottom-left
    /// corner. Runs in the test runner: its screens are the app's.
    private func fillsScreen(_ frame: CGRect) -> Bool {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return false }
        return NSScreen.screens.contains { screen in
            let top = mainHeight - screen.frame.maxY  // the screen's top edge, top-left origin
            let strip = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
            return abs(frame.minX - screen.frame.minX) < 1 && abs(frame.width - screen.frame.width) < 1
                && abs(frame.maxY - (top + screen.frame.height)) < 1
                && frame.minY >= top - 1 && frame.minY - top <= strip + 60
        }
    }

    /// The frames of this build's Kernir windows that fill a screen, on any Space. XCUI sees
    /// only the windows of the Space in front, so a preview left in full screen on its own Space
    /// (or a closed one that took its Space's window with it) never shows in `windowCount`;
    /// CGWindowList with `.optionAll` lists every window the app has, on or off screen. Window
    /// names need Screen Recording, so windows match by owner PID (`ownInstances`), the normal
    /// level and a full-screen frame; ordered-out windows that left full screen are windowed.
    /// This sees windows only: an empty full-screen Space left behind with no window in it
    /// doesn't show here. Nil when no Kernir process of this build is found or the window list
    /// can't be read, so a caller never takes "nothing found" for "no full-screen window".
    private func fullScreenWindowsOnAnySpace() -> [CGRect]? {
        let pids = Set(Self.ownInstances().map(\.processIdentifier).filter(Self.isAlive))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  fillsScreen(frame) else { return nil }
            return frame
        }
    }

    /// Waits until `fullScreenWindowsOnAnySpace` finds exactly `count` windows (an ordered-out
    /// window can linger briefly in the `.optionAll` list), then fails if it still doesn't or the
    /// list can't be read. Windows only, not empty Spaces (see `fullScreenWindowsOnAnySpace`).
    private func expectFullScreenWindowsOnAnySpace(_ count: Int, _ message: String, timeout: TimeInterval = 10,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        var found = fullScreenWindowsOnAnySpace()
        while Date() < deadline, found?.count != count {
            Thread.sleep(forTimeInterval: 0.25)
            found = fullScreenWindowsOnAnySpace()
        }
        guard let found else {
            XCTFail("can't list Kernir's windows: no Kernir process of this build or no window list", file: file, line: line)
            return
        }
        XCTAssertEqual(found.count, count, "\(message): full-screen windows on any Space \(found)", file: file, line: line)
    }

    /// Waits until the preview is (or isn't) in full screen; the transition animates.
    private func waitForFullScreen(_ expected: Bool, timeout: TimeInterval = 10,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isFullScreen(preview) == expected {
                // Let the animation settle before the next key.
                Thread.sleep(forTimeInterval: 1)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("preview full screen: expected \(expected), frame \(preview.exists ? "\(preview.frame)" : "none")\n\(app.debugDescription)",
                file: file, line: line)
    }

    /// Teardown: every Kernir window still in full screen leaves it (⌃⌘F, then Esc, then the
    /// toolbar button), so no Space is left on the test Mac whatever the test did.
    private func leaveFullScreenIfNeeded() {
        guard let app, app.state == .runningForeground || app.state == .runningBackground else { return }
        for attempt in 0..<3 {
            guard let window = allWindows.first(where: isFullScreen) else { return }
            switch attempt {
            case 0: window.typeKey("f", modifierFlags: [.command, .control])
            case 1: window.typeKey(.escape, modifierFlags: [])
            default: previewButton("Exit Full Screen", identifier: "preview.fullScreen").click()
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, isFullScreen(window) {
                Thread.sleep(forTimeInterval: 0.25)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        if allWindows.contains(where: isFullScreen) {
            XCTFail("a Kernir window is still in full screen after teardown\n\(app.debugDescription)")
        }
    }

    /// Full screen three ways, out again: the toolbar button then Esc, ⌃⌘F twice, the green
    /// button then Esc. Esc leaves full screen only: the preview stays open on its item.
    func testFullScreenEnterAndExit() throws {
        try openTypesArchive()
        let before = windowCount
        app.row("Pixel.png").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        waitForTitle("Pixel.png")
        XCTAssertFalse(isFullScreen(preview), app.debugDescription)

        let button = previewButton("Enter Full Screen", identifier: "preview.fullScreen")
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no full-screen button\n\(app.debugDescription)")
        XCTAssertTrue(previewToolbarItem(labeled: "Enter Full Screen").exists,
                      "the full-screen button doesn't read Enter Full Screen\n\(app.debugDescription)")
        button.click()
        waitForFullScreen(true)
        // The button reads as View > Exit Full Screen does now.
        XCTAssertTrue(previewToolbarItem(labeled: "Exit Full Screen").waitForExistence(timeout: 5),
                      "the full-screen button doesn't read Exit Full Screen\n\(app.debugDescription)")
        attachShot(of: preview, named: "ql-full-screen")
        app.typeKey(.escape, modifierFlags: [])
        waitForFullScreen(false)
        XCTAssertTrue(preview.exists, "Esc in full screen closed the preview\n\(app.debugDescription)")
        XCTAssertTrue(previewToolbarItem(labeled: "Enter Full Screen").waitForExistence(timeout: 5),
                      "the full-screen button didn't turn back\n\(app.debugDescription)")
        XCTAssertEqual(preview.title, "Pixel.png")

        preview.typeKey("f", modifierFlags: [.command, .control])
        waitForFullScreen(true)
        preview.typeKey("f", modifierFlags: [.command, .control])
        waitForFullScreen(false)
        XCTAssertTrue(preview.exists, app.debugDescription)

        let green = preview.buttons[XCUIIdentifierFullScreenWindow]
        XCTAssertTrue(green.exists, "no green full-screen button\n\(app.debugDescription)")
        green.click()
        waitForFullScreen(true)
        app.typeKey(.escape, modifierFlags: [])
        waitForFullScreen(false)

        // Out of full screen, Esc closes as before.
        app.typeKey(.escape, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The preview closes while in full screen (Space): it leaves full screen first, so the
    /// archive window is back in front, in its own Space, and a new preview opens windowed.
    func testClosingThePreviewInFullScreen() throws {
        try openTypesArchive()
        let archive = archiveWindow("ql-types")
        let before = windowCount
        app.row("Notes.txt").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        waitForTitle("Notes.txt")
        let button = previewButton("Enter Full Screen", identifier: "preview.fullScreen")
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.click()
        waitForFullScreen(true)
        expectFullScreenWindowsOnAnySpace(1, "the full-screen preview isn't in the window list")

        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 10)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(allWindows.contains(where: isFullScreen),
                       "a window stayed in full screen\n\(app.debugDescription)")
        expectFullScreenWindowsOnAnySpace(0, "a full-screen window stayed on another Space (windows only; an empty Space isn't seen)")
        XCTAssertTrue(archive.isHittable, "the archive window isn't in front\n\(app.debugDescription)")

        app.row("Notes.txt").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        waitForTitle("Notes.txt")
        XCTAssertFalse(isFullScreen(preview), "the next preview opened in full screen\n\(app.debugDescription)")
        app.typeKey(.space, modifierFlags: [])
        waitForWindows("count == %d", before, timeout: 5)
    }

    /// The archive window closes while its preview is in full screen (⌘W there after the user
    /// went back to it through the Window menu): the preview leaves full screen and goes, and
    /// Kernir keeps running with no window and no Space left.
    func testClosingTheArchiveWindowWithThePreviewInFullScreen() throws {
        try openTypesArchive()
        let archive = archiveWindow("ql-types")
        let before = windowCount
        app.row("Notes.txt").select()
        app.archiveOutline.typeKey(.space, modifierFlags: [])
        waitForWindows("count > %d", before, timeout: 10)
        waitForTitle("Notes.txt")
        let button = previewButton("Enter Full Screen", identifier: "preview.fullScreen")
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.click()
        waitForFullScreen(true)
        expectFullScreenWindowsOnAnySpace(1, "the full-screen preview isn't in the window list")

        // Back to the archive window through the Window menu (its Space comes to the front; the
        // preview stays in full screen in its own), then ⌘W there.
        app.menuBars.menuBarItems["Window"].click()
        let item = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "ql-types")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Window menu item for the archive\n\(app.debugDescription)")
        item.click()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !archive.isHittable { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(archive.isHittable, "the archive window didn't come to the front\n\(app.debugDescription)")
        archive.typeKey("w", modifierFlags: .command)
        waitForWindows("count == %d", 0, timeout: 15)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(windowCount, 0, "a window stayed\n\(app.debugDescription)")
        // `windowCount` sees only this Space: the preview's full-screen window on its own Space
        // must be gone too. This checks windows only; an empty Space left behind isn't seen.
        expectFullScreenWindowsOnAnySpace(0, "the preview stayed in full screen on its own Space (windows only; an empty Space isn't seen)")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
