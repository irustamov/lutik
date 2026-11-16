import XCTest

/// Save's Mac metadata question (design v2 §6-7): an explicit Save in an archive with `__MACOSX` or
/// `._*` entries asks once; Keep or Remove saves and is remembered for the archive, Cancel saves
/// nothing. `zip/macos-finder.zip` holds `Project/` and its `__MACOSX/Project/._*` twins. The
/// fixture hook forgets the copy's remembered answer, so each launch asks again.
@MainActor
final class MacMetadataUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Keep saves, the next Save doesn't ask, and the answer is remembered across a reopen: Save As
    /// Copy's "Exclude Mac metadata" switch starts off (unanswered, it starts on, the app's default).
    /// The list never shows `__MACOSX` or `._*` rows (`ArchiveModel.isHidden(path:)`), so what the save
    /// wrote is `PlainSaveChoiceTests`'s to check, not this test's.
    func testKeepSavesAndIsRememberedAcrossAReopen() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/macos-finder.zip")
        let hello = app.deleteInProject("Project/hello.txt")

        let alert = app.saveAndWaitForMacMetadataQuestion()
        alert.buttons["Keep"].firstMatch.tap()
        app.waitForSaveToFinish()
        // The reopened list is up once a sibling is back; only then does hello's absence say something.
        let docs = app.row("Project/docs")
        XCTAssertTrue(docs.waitForExistence(timeout: 5))
        XCTAssertFalse(hello.exists, "the deleted file is back after the save")

        // The answer is remembered: the next Save doesn't ask.
        app.deleteBySwiping(docs)
        XCTAssertTrue(docs.waitForNonExistence(timeout: 5))
        app.assertSaveOnBar()
        app.navigationBars.buttons["Save"].firstMatch.tap()
        XCTAssertFalse(app.macMetadataQuestion.waitForExistence(timeout: 2), "Save asked again after Keep")
        app.waitForSaveToFinish()

        // Hosted coverage: KeepMacMetadataTests choiceIsPerFileAndRememberedOnReopen, revertReadsTheRememberedChoice;
        // DocumentSessionMacMetadataTests saveAsCopyStartsFromTheAnswer.
        guard reopenExpectingIOS27EmptyBrowser(app) else { return }
        app.assertSaveAsCopyExcludesMetadata("0", "Keep is not remembered after the reopen")
    }

    /// Smoke test: Remove saves, and the archive reopens with Save As Copy's switch on. The switch check
    /// can't tell the answer from the default: unanswered it starts on too (`excludesMacMetadataByDefault`
    /// is a `static let`, which no launch argument changes), so a remembered Remove and none look the same.
    /// That the Remove is remembered for the saved file is the hosted `KeepMacMetadataTests`' to check
    /// (`saveAsCopyStartsFromTheAnswerAndRecordsNothing(true)`, `answerRefreshesTheSnapshotAndFollowsTheSavedFile`).
    func testRemoveSavesAndReopens() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/macos-finder.zip")
        let hello = app.deleteInProject("Project/hello.txt")

        let alert = app.saveAndWaitForMacMetadataQuestion()
        alert.buttons["Remove"].firstMatch.tap()
        app.waitForSaveToFinish()
        XCTAssertTrue(app.row("Project/docs").waitForExistence(timeout: 5))
        XCTAssertFalse(hello.exists, "the deleted file is back after the save")

        // Hosted coverage: KeepMacMetadataTests choiceIsPerFileAndRememberedOnReopen, revertReadsTheRememberedChoice;
        // DocumentSessionMacMetadataTests saveAsCopyStartsFromTheAnswer.
        guard reopenExpectingIOS27EmptyBrowser(app) else { return }
        app.assertSaveAsCopyExcludesMetadata("1", "Save As Copy doesn't start from Remove after the reopen")
    }

    func testCancelLeavesTheArchiveUnsaved() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/macos-finder.zip")
        let hello = app.deleteInProject("Project/hello.txt")

        let alert = app.saveAndWaitForMacMetadataQuestion()
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        // Nothing saved: the edit is still pending.
        app.assertSaveOnBar()
        XCTAssertTrue(app.row("Project/docs").waitForExistence(timeout: 5))
        XCTAssertFalse(hello.exists)
        XCTAssertTrue(app.navigationBars.buttons["Undo"].firstMatch.exists)

        // Nothing remembered: the next Save asks again.
        let again = app.saveAndWaitForMacMetadataQuestion()
        again.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(again.waitForNonExistence(timeout: 5))
        app.assertSaveOnBar()
    }

    /// Reopens macos-finder.zip; on iOS 27 only the launch browser's empty-folder failure is expected
    /// (open question, not a confirmed simulator limit). Returns whether the archive is open again, so
    /// the remembered-answer check runs whenever it can. Below iOS 27 a failed reopen fails the test.
    private func reopenExpectingIOS27EmptyBrowser(_ app: XCUIApplication) -> Bool {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("lists the app's folder as empty") }
        options.isEnabled = Self.isIOS27
        options.isStrict = false
        return XCTExpectFailure("iOS 27: launch browser lists Kernir's folder as empty (DocumentManager: "
                                + "'failed to get a cached domain for FILocalAppContainerNode<Kernir>'); Files.app "
                                + "sees the item. Open: verify on a real device. Known iOS 27 launch-browser issue.",
                                options: options, failingBlock: { app.reopenFinderZip() })
    }

    func testNoQuestionForArchiveWithoutMetadata() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        app.deleteBySwiping(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))

        app.assertSaveOnBar()
        app.navigationBars.buttons["Save"].firstMatch.tap()
        XCTAssertFalse(app.macMetadataQuestion.waitForExistence(timeout: 2), "Save asked about Mac metadata")
        app.waitForSaveToFinish()
    }
}

private extension XCUIApplication {
    /// The question's alert, found by its title ("“name” contains Mac metadata").
    var macMetadataQuestion: XCUIElement {
        alerts.matching(NSPredicate(format: "label ENDSWITH %@", "contains Mac metadata")).firstMatch
    }

    /// Opens `Project` in macos-finder.zip and swipe-deletes `path` there; returns its row.
    func deleteInProject(_ path: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let project = row("Project")
        waitForArchive(project, file: file, line: line)
        XCTAssertFalse(navigationBars.buttons["Save"].exists, file: file, line: line)
        project.tap()
        let item = row(path)
        XCTAssertTrue(item.waitForExistence(timeout: 5), file: file, line: line)
        deleteBySwiping(item)
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), file: file, line: line)
        return item
    }

    /// From `Project`, back to the root and to the launch browser (closing the saved document), then
    /// opens the same macos-finder.zip again. No fixture hook this time, so its answer stays remembered.
    /// Returns whether the archive is open; false without waiting if the pick found the folder empty
    /// (`pickInLaunchBrowser` has failed then), so only that one issue is recorded.
    func reopenFinderZip(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(row("Project").waitForExistence(timeout: 5), "back at the root", file: file, line: line)
        navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(waitForLaunchBrowserInFront(timeout: 10), debugDescription, file: file, line: line)
        pickInLaunchBrowser("macos-finder.zip", file: file, line: line)
        if staticTexts["Folder is Empty"].firstMatch.exists { return false }
        waitForArchive(row("Project"), file: file, line: line)
        return row("Project").exists
    }

    /// Opens Save As Copy, checks where its "Exclude Mac metadata" switch starts (the file's answer,
    /// `DocumentSession.saveAsCopySettings(for:)`), and cancels the sheet.
    func assertSaveAsCopyExcludesMetadata(_ value: String, _ message: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        tapSaveAsCopy(file: file, line: line)
        let save = saveOptionsButton("Save")
        XCTAssertTrue(save.waitForExistence(timeout: 10), debugDescription, file: file, line: line)
        XCTAssertTrue(metadataToggle.waitForExistence(timeout: 5), debugDescription, file: file, line: line)
        XCTAssertEqual(metadataToggle.value as? String, value, message, file: file, line: line)
        saveOptionsButton("Cancel").tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), file: file, line: line)
    }

    /// Taps Save on the bar and waits for the question, with its three buttons. iOS 27.2 nests each
    /// button in a twin with the same identifier and label (iPhone 18 Pro simulator), so a bare
    /// `buttons[name].tap()` fails with "Multiple matching elements found": callers tap `.firstMatch`.
    func saveAndWaitForMacMetadataQuestion(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        assertSaveOnBar(file: file, line: line)
        navigationBars.buttons["Save"].firstMatch.tap()
        let alert = macMetadataQuestion
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Save didn't ask about Mac metadata\n\(debugDescription)",
                      file: file, line: line)
        for name in ["Keep", "Remove", "Cancel"] {
            XCTAssertTrue(alert.buttons[name].exists, "the question has no \(name)", file: file, line: line)
        }
        return alert
    }

    /// Waits for Save to leave the bar, with no alert up (a failed save shows one).
    func waitForSaveToFinish(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(navigationBars.buttons["Save"].firstMatch.waitForNonExistence(timeout: 20),
                      "the save did not finish", file: file, line: line)
        XCTAssertFalse(alerts.firstMatch.exists, alerts.firstMatch.debugDescription, file: file, line: line)
    }
}
