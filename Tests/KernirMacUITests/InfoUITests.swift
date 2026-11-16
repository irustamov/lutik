import XCTest

/// The Info popover (File > Get Info ⌘I, the toolbar's Info button) and its comment field.
final class InfoUITests: KernirMacUITestCase {
    private var popover: XCUIElement { app.popovers.firstMatch }

    /// ⌘I shows the popover whether or not the toolbar is: at the Info button, else at the footer. Esc closes it,
    /// and the next ⌘I opens it again with one press.
    func testGetInfoShowsThePopoverWithAndWithoutTheToolbar() throws {
        continueAfterFailure = true
        try openFixture("zip/comment-utf8.zip")
        waitForArchive(app.footer)

        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "no popover with the toolbar shown\n\(app.debugDescription)")
        keepWindowShot("toolbar-visible")
        closeAndReopen("toolbar shown")

        app.toolbars.buttons["Info"].firstMatch.click()
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "the Info button showed no popover")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5))

        app.openMenu("View", item: "Hide Toolbar").click()
        XCTAssertTrue(app.toolbars.buttons["Info"].firstMatch.waitForNonExistence(timeout: 5), "the toolbar is still shown")
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "no popover with the toolbar hidden\n\(app.debugDescription)")
        keepWindowShot("toolbar-hidden")
        closeAndReopen("toolbar hidden")
        app.openMenu("View", item: "Show Toolbar").click()
    }

    /// The narrowest window: the popover shows, at the Info button or (in the overflow menu) at the footer.
    func testGetInfoShowsThePopoverInANarrowWindow() throws {
        continueAfterFailure = true
        app.launchArguments += ["-KernirWindowFrame", "600x360"]
        try openFixture("zip/comment-utf8.zip")
        waitForArchive(app.footer)
        let info = app.toolbars.buttons["Info"].firstMatch
        XCTContext.runActivity(named: "Info button exists \(info.exists), hittable \(info.exists && info.isHittable)") { _ in }
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "no popover in a narrow window\n\(app.debugDescription)")
        keepWindowShot("narrow")
        closeAndReopen("narrow")
    }

    /// Typing in the comment is one "Edit Comment" undo step of the document: ⌘Z in the open popover does
    /// nothing, ⌘Z after it closed takes all of the typing back at once, and the next ⌘Z has no comment step left.
    func testCommentTypingIsOneUndoStep() throws {
        continueAfterFailure = true
        try openFixture("zip/comment-utf8.zip")
        waitForArchive(app.footer)

        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        let field = popover.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no comment field\n\(app.debugDescription)")
        let original = field.value as? String ?? ""
        field.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        field.typeText("xyz")
        XCTAssertEqual(field.value as? String, original + "xyz")

        // ⌘Z in the open popover does nothing: the field's own undo is off (the window hands it an empty manager
        // while the popover is open); the document's "Edit Comment" step takes the typing back once it closes.
        app.typeKey("z", modifierFlags: .command)
        note("after ⌘Z in the popover: \(String(reflecting: field.value as? String))")
        XCTAssertEqual(field.value as? String, original + "xyz")

        // Typed on, then closed: Edit > Undo names the comment edit and takes all of it back.
        field.typeText("!")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
        XCTAssertEqual(undoMenuTitle(), "Undo Edit Comment")
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        note("after one ⌘Z: \(String(reflecting: popover.textViews.firstMatch.value as? String))")
        XCTAssertEqual(popover.textViews.firstMatch.value as? String, original)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
        let title = undoMenuTitle()
        note("Edit > Undo after one ⌘Z: \(title)")
        XCTAssertFalse(title.contains("Comment") || title.contains("Typing"), title)
    }

    /// The comment round trip: type a comment in Info, take it back with ⌘Z (sent after the popover closed, as
    /// ⌘Z in it does nothing), type another, ⌘S, reopen from disk ⇒ Info and the footer's Comment button show it.
    func testCommentEditedUndoneSavedAndReopened() throws {
        continueAfterFailure = true
        let archive = try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))
        let before = try Self.sha256(of: archive)
        XCTAssertFalse(footerCommentButton.exists, "a Comment button on an archive without a comment")

        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        var field = popover.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no comment field\n\(app.debugDescription)")
        XCTAssertEqual(field.value as? String, "")
        field.click()
        field.typeText("Draft")
        XCTAssertEqual(field.value as? String, "Draft")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
        XCTAssertEqual(undoMenuTitle(), "Undo Edit Comment")
        app.typeKey("z", modifierFlags: .command)

        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        field = popover.textViews.firstMatch
        XCTAssertEqual(field.value as? String, "", "⌘Z left the typed comment")
        field.click()
        field.typeText("Kept by Kernir")
        XCTAssertEqual(field.value as? String, "Kept by Kernir")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
        app.typeKey("s", modifierFlags: .command)

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, try Self.sha256(of: archive) == before {
            XCTAssertNotEqual(app.state, .notRunning, "the app crashed while saving")
            _ = app.text(containing: "could not be saved").waitForExistence(timeout: 0.5)
        }
        XCTAssertNotEqual(try Self.sha256(of: archive), before, "the save did not write the archive")
        XCTAssertFalse(app.text(containing: "could not be saved").exists)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDirectory.path),
                       [archive.lastPathComponent], "leftovers next to the archive")

        // Reopen from disk (open(_:) quits the running app first).
        open(archive)
        waitForArchive(app.row("hello.txt"))
        XCTAssertTrue(footerCommentButton.waitForExistence(timeout: 5), "no Comment button after the save")
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        XCTAssertEqual(popover.textViews.firstMatch.value as? String, "Kept by Kernir")
        keepWindowShot("comment-reopened")
    }

    /// With the popover open, a click on the button it shows at closes it; a click on the other
    /// button (the toolbar's Info, the footer's Comment) leaves it open, moved to that button.
    /// The window isn't pinned: `-KernirWindowFrame` centres it on screen, where a system alert left there took the
    /// clicks on the Info button. A window too short for the popover to leave the other button free
    /// skips the test instead of failing it.
    func testInfoButtonsWithThePopoverOpen() throws {
        continueAfterFailure = true
        try openFixture("zip/comment-utf8.zip")
        waitForArchive(app.footer)
        let info = app.toolbars.buttons["Info"].firstMatch
        XCTAssertTrue(footerCommentButton.waitForExistence(timeout: 5), "no Comment button in the footer")

        // ⌘I with the toolbar shown opens the popover at the Info button.
        let cases: [(opener: String, anchor: String, target: String)] = [
            ("⌘I", "Info", "Info"), ("⌘I", "Info", "Comment"),
            ("Comment", "Comment", "Comment"), ("Comment", "Comment", "Info"),
        ]
        for step in cases {
            if popover.exists {
                app.typeKey(.escape, modifierFlags: [])
                _ = popover.waitForNonExistence(timeout: 5)
            }
            if step.opener == "⌘I" { app.typeKey("i", modifierFlags: .command) } else { footerCommentButton.click() }
            guard popover.waitForExistence(timeout: 5) else {
                XCTFail("\(step.opener) opened no popover")
                continue
            }
            let opened = popover.frame
            let target = step.target == "Info" ? info : footerCommentButton
            let context = "opened by \(step.opener) at \(opened), click on \(step.target) at \(target.frame)"
            if opened.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) {
                throw XCTSkip("the popover covers the button to click (the window is too short): \(context)")
            }
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            if step.target == step.anchor {
                XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "the popover stayed open: \(context)")
            } else {
                let moved = wait(5) {
                    let frame = self.popover.frame
                    return self.popover.exists && frame != opened
                        && frame.minX <= target.frame.midX && target.frame.midX <= frame.maxX
                }
                XCTAssertTrue(moved, "the popover isn't open at \(step.target): \(context); "
                              + "now \(popover.exists ? "open at \(popover.frame)" : "closed")")
                if !moved { keepWindowShot("\(step.opener)-then-\(step.target)") }
            }
        }
    }

    /// The Save As panel's note on a comment it won't write: 7z and TAR have no comment; a split ZIP can't hold
    /// one. The fixture's comment is the comment set. Each note shows inside the sheet, and the panel's accessory
    /// grows and shrinks with it: the Format row stays where ZIP has it, never sliding up under the panel's header
    /// (a fixed-size accessory centred its taller content, cutting off the split note).
    /// Assumes the panel opens collapsed (the system's saved state; the app can't set it) and so grows down
    /// from the window's title bar; the window is pinned, not an autosaved frame, so the sheet fits the screen.
    func testSaveAsNotesTheDroppedComment() throws {
        continueAfterFailure = true
        app.launchArguments += ["-KernirWindowFrame", "820x520"]
        try openFixture("zip/comment-utf8.zip")
        waitForArchive(app.footer)
        app.typeKey("s", modifierFlags: [.command, .shift])
        let format = app.popUpButtons["saveFormat"].firstMatch
        guard format.waitForExistence(timeout: 30) else {
            XCTFail("no format picker in the Save As panel\n\(app.debugDescription)")
            return
        }
        let formatNote = app.text(containing: "archives can’t have a comment")
        let splitNote = app.text(containing: "A split archive can’t have a comment.")
        XCTAssertFalse(formatNote.exists || splitNote.exists, "a note for a ZIP that keeps its comment")
        // The underscores show as typed, not eaten as Markdown.
        let metadataLabel = savePanel.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Exclude Mac metadata'"))
            .firstMatch
        XCTAssertEqual(metadataLabel.value as? String, "Exclude Mac metadata (.DS_Store, __MACOSX, ._ files)")
        let formatTop = format.frame.minY - savePanel.frame.minY

        for name in ["7z", "TAR"] {
            choose(name, in: format)
            XCTAssertTrue(formatNote.waitForExistence(timeout: 5), "no note for \(name)\n\(app.debugDescription)")
            expectShown(formatNote, name, formatTop: formatTop, format: format)
        }

        choose("ZIP", in: format)
        XCTAssertTrue(formatNote.waitForNonExistence(timeout: 5), "the format note stayed for ZIP")
        let split = app.popUpButtons["saveSplit"].firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 5), "no split picker for ZIP")
        choose("25 MB", in: split)
        XCTAssertTrue(splitNote.waitForExistence(timeout: 5), "no note for a split ZIP\n\(app.debugDescription)")
        expectShown(splitNote, "split ZIP", formatTop: formatTop, format: format)
        keepPanelShot("split-zip") // kept: the split note's layout is only seen in a shot

        // The sheet's own Cancel: app-wide, "Cancel" also matches a Touch Bar button XCUITest can't click.
        savePanel.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(format.waitForNonExistence(timeout: 10), "the Save As panel stayed open")
    }

    // MARK: - Helpers

    /// The footer's Comment button (shown when the archive has a comment); the popover's field is a text view.
    private var footerCommentButton: XCUIElement {
        app.windows.firstMatch.buttons.matching(NSPredicate(format: "label == 'Comment'")).firstMatch
    }

    /// The Save panel's sheet on the archive window.
    private var savePanel: XCUIElement { app.sheets["save-panel"].firstMatch }

    /// Whether `condition` holds within `seconds`, checked as the run loop turns.
    private func wait(_ seconds: TimeInterval, until condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed
    }

    /// `element` (a note) shows whole inside the Save panel, and the Format row is still `formatTop` below the sheet's top.
    private func expectShown(_ element: XCUIElement, _ name: String, formatTop: CGFloat, format: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        let sheet = savePanel.frame
        let context = "\(name): note at \(element.frame), Format at \(format.frame), sheet at \(sheet)"
        note(context)
        var shown = element.exists && !element.frame.isEmpty && sheet.contains(element.frame)
        XCTAssertTrue(shown, "the note isn't inside the sheet: \(context)", file: file, line: line)
        let top = format.frame.minY - sheet.minY
        XCTAssertEqual(top, formatTop, accuracy: 1, "the Format row moved in the sheet: \(context)", file: file, line: line)
        shown = shown && abs(top - formatTop) <= 1
        if !shown { keepPanelShot(name) }
    }

    /// Picks `item` in the pop-up button `picker`.
    private func choose(_ item: String, in picker: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        picker.click()
        let menuItem = picker.menuItems[item].firstMatch
        guard menuItem.waitForExistence(timeout: 5) else {
            XCTFail("no \(item) in \(picker)\n\(app.debugDescription)", file: file, line: line)
            app.typeKey(.escape, modifierFlags: [])
            return
        }
        menuItem.click()
    }

    /// A shot of the Save panel only (the sheet on the archive window), kept in the result bundle.
    private func keepPanelShot(_ name: String) {
        let attachment = XCTAttachment(screenshot: savePanel.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Esc closes the popover; one ⌘I opens it again, then Esc closes it.
    private func closeAndReopen(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "Esc left the popover open (\(context))", file: file, line: line)
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "one ⌘I didn't reopen the popover (\(context))",
                      file: file, line: line)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), file: file, line: line)
    }

    /// The Edit menu's first item, its title as the menu shows it now ("Undo Edit Comment", "Undo").
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
        print("INFOUI \(text)")
    }

    /// A shot of the archive window only (never the whole screen), kept in the result bundle.
    private func keepWindowShot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
