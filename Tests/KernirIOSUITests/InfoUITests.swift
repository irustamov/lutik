import XCTest

/// The Info sheet shows a ZIP's archive comment; an edit there marks the document changed, and Save
/// writes it into the file. Hosted coverage: ScreenStateTests (ScreenStateInfoTests.swift).
@MainActor
final class InfoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testInfoShowsEditsAndSavesTheComment() throws {
        let copy = try QAFixtures.freshCopy(of: "zip/comment-utf8.zip", prefix: "InfoComment")
        let app = XCUIApplication()
        app.launchOpening(fileAt: copy)
        let readme = app.row("readme.txt")
        app.waitForArchive(readme)
        XCTAssertFalse(app.navigationBars.buttons["Save"].firstMatch.exists)

        app.tapInfo()
        let comment = app.textViews["Comment"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 5), app.debugDescription)
        let shown = comment.value as? String ?? ""
        XCTAssertTrue(shown.hasPrefix("Привет из Kernir"), "comment shows \(shown.debugDescription)")
        XCTAssertTrue(app.infoRow("Format", value: "ZIP").exists, "no Format row\n\(app.debugDescription)")
        app.attachScreenshot("Info sheet")

        app.tapForTyping(comment)
        comment.typeText("Edited on iOS. ")
        XCTAssertTrue((comment.value as? String ?? "").contains("Edited on iOS. "), app.debugDescription)
        let done = app.navigationBars["Info"].buttons["Done"].firstMatch
        XCTAssertTrue(done.exists, app.debugDescription)
        done.tap()
        XCTAssertTrue(comment.waitForNonExistence(timeout: 5), "the Info sheet did not close")

        // The edit is the document's: Save comes up, and writes the comment.
        app.assertSaveOnBar()
        app.navigationBars.buttons["Save"].firstMatch.tap()
        // An archive with Mac metadata would ask first; this one has none, but answer Keep if asked.
        let keep = app.alerts.firstMatch.buttons["Keep"].firstMatch
        if keep.waitForExistence(timeout: 2) { keep.tap() }
        XCTAssertTrue(app.navigationBars.buttons["Save"].firstMatch.waitForNonExistence(timeout: 20),
                      "the save did not finish")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)

        // The fixture hook opened (and Save wrote) its own copy in the app's Documents, not the runner's `copy`.
        // A ZIP's archive comment ends the file, after the end-of-central-directory record.
        let saved = try appCopy(of: copy)
        XCTAssertTrue(waitForTail(of: saved, toContain: "Edited on iOS. "),
                      "the saved file has no edited comment\n\(fileFacts(saved))\nrunner's copy: \(fileFacts(copy))")

        // Info again shows the saved comment.
        app.tapInfo()
        XCTAssertTrue(comment.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue((comment.value as? String ?? "").contains("Edited on iOS. "), app.debugDescription)
    }

    /// The typing is one undo step of the document, and the field's own typing registers none: after Done, one
    /// Undo on the bar takes all of it back, and nothing is left to save.
    func testOneUndoTakesTheCommentTypingBack() throws {
        let copy = try QAFixtures.freshCopy(of: "zip/comment-utf8.zip", prefix: "InfoUndo")
        let app = XCUIApplication()
        app.launchOpening(fileAt: copy)
        app.waitForArchive(app.row("readme.txt"))

        app.tapInfo()
        let comment = app.textViews["Comment"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 5), app.debugDescription)
        let original = comment.value as? String ?? ""
        app.tapForTyping(comment)
        comment.typeText("One. ")
        comment.typeText("Two. ")
        app.navigationBars["Info"].buttons["Done"].firstMatch.tap()
        XCTAssertTrue(comment.waitForNonExistence(timeout: 5), "the Info sheet did not close")
        app.assertSaveOnBar()

        app.undoFromBar()
        XCTAssertTrue(app.navigationBars.buttons["Save"].firstMatch.waitForNonExistence(timeout: 5),
                      "Save is still there after one Undo: more than one undo step\n\(app.debugDescription)")
        app.tapInfo()
        XCTAssertTrue(comment.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(comment.value as? String, original)
    }

    // MARK: - The app's copy

    /// The fixture hook's copy of `runnerCopy` (`SceneDelegate.fixtureURL`, which copies into the app's Documents
    /// and opens that), on the simulator: in the data container next to this runner's whose Documents holds a
    /// file of its name. The name is unique per run (`QAFixtures.freshCopy`). As ExtractHereUITests'.
    private func appCopy(of runnerCopy: URL) throws -> URL {
        let containers = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).deletingLastPathComponent()
        for container in try FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) {
            let candidate = container.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(runnerCopy.lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("no app container holds \(runnerCopy.lastPathComponent) next to \(containers.path)")
        throw CocoaError(.fileNoSuchFile)
    }

    /// Waits up to 10 s for the last 4 KB of `file`, read as UTF-8, to contain `text`.
    private func waitForTail(of file: URL, toContain text: String) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let data = try? Data(contentsOf: file),
               String(decoding: data.suffix(4096), as: UTF8.self).contains(text) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// Path, size, modification date and the tail (last 200 bytes, UTF-8) of `file`, for a failure message.
    private func fileFacts(_ file: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let modified = (attributes?[.modificationDate] as? Date).map { "\($0)" } ?? "none"
        let tail = (try? Data(contentsOf: file)).map { String(decoding: $0.suffix(200), as: UTF8.self) } ?? "unreadable"
        return "\(file.path): \(size) bytes, modified \(modified), tail \(tail.debugDescription)"
    }
}

extension XCUIApplication {
    /// Info, from the bar's More menu (iPhone) or the bar itself (iPad, when there's room).
    func tapInfo(file: StaticString = #filePath, line: UInt = #line) {
        let item = buttons["Info"].firstMatch
        if !item.exists {
            navigationBars.buttons["More"].firstMatch.tap()
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Info\n\(debugDescription)", file: file, line: line)
        item.tap()
    }

    /// An Info row (a stock `LabeledContent`): exposed as one element labelled "Format, ZIP" (with a
    /// "Format" text inside, but no "ZIP" text of its own), or as separate label and value texts.
    func infoRow(_ label: String, value: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label == %@", "\(label), \(value)", value)).firstMatch
    }

    /// Taps `field` (a text view or field with a label) until it has the keyboard focus (at most twice) so
    /// `typeText` finds a focused element. On the iPhone 18 Pro simulator (iOS 27.2) a single tap on the
    /// Info sheet's comment left nothing focused for 5 s and `typeText` failed. Fails with who holds the
    /// focus, if anyone, and whether a keyboard is up.
    func tapForTyping(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let label = field.label
        let focused = descendants(matching: field.elementType)
            .matching(NSPredicate(format: "label == %@ AND hasKeyboardFocus == true", label)).firstMatch
        field.tap()
        if focused.waitForExistence(timeout: 3) { return }
        // Again near the text's start, away from the middle the first tap took.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        if focused.waitForExistence(timeout: 3) { return }
        let holder = descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        let focus = holder.exists ? holder.debugDescription : "nothing"
        XCTFail("\(label) took no keyboard focus after two taps; focus is on \(focus); keyboard up: "
                + "\(keyboards.firstMatch.exists)\n\(debugDescription)", file: file, line: line)
    }
}
