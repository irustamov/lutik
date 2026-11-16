import XCTest

/// Damaged and non-archive files: an error, never a crash or a hang.
final class ErrorUITests: KernirMacUITestCase {
    /// Random bytes named .zip: "This file isn't a supported archive."
    func testRandomBytesZipShowsError() throws {
        try openFixture("corrupt/random.zip")
        let message = app.text(containing: "isn't a supported archive")
        waitForArchive(message)
        XCTAssertFalse(app.archiveOutline.exists)

        app.buttons["OK"].firstMatch.click()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(app.state, .notRunning, "the app crashed")
        assertAppStillWorks()
    }

    /// deflate.zip cut at 60%: the central directory is gone. An error or a partial listing
    /// are both acceptable (manifest: open = any); a crash or a hang is not.
    func testTruncatedZipDoesNotCrash() throws {
        try openFixture("corrupt/truncated.zip")
        let alertOK = app.buttons["OK"].firstMatch
        let anyRow = app.archiveOutline.outlineRows.firstMatch
        let cantRead = app.text(containing: "Can’t Read Archive")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !alertOK.exists, !anyRow.exists, !cantRead.exists {
            XCTAssertFalse(app.text(containing: Self.stubText).exists, "stub engine alert")
            XCTAssertNotEqual(app.state, .notRunning, "the app crashed")
            _ = alertOK.waitForExistence(timeout: 0.5)
        }
        XCTAssertTrue(alertOK.exists || anyRow.exists || cantRead.exists,
                      "neither an error nor a listing appeared\n\(app.debugDescription)")
        XCTAssertFalse(app.text(containing: Self.stubText).exists, "stub engine alert")
        if alertOK.exists {
            alertOK.click()
            XCTAssertTrue(alertOK.waitForNonExistence(timeout: 5))
        }
        XCTAssertNotEqual(app.state, .notRunning, "the app crashed")
        assertAppStillWorks()
    }

    /// After an error the app still answers (its File menu opens), and a good archive opens.
    /// The good archive opens in a fresh launch: `XCUIApplication.open(_:)` can't hand a file to
    /// the running app without starting a second Kernir.
    private func assertAppStillWorks(file: StaticString = #filePath, line: UInt = #line) {
        let fileMenu = app.menuBars.menuBarItems["File"]
        fileMenu.click()
        XCTAssertTrue(fileMenu.menus.menuItems.firstMatch.waitForExistence(timeout: 5),
                      "the app stopped answering after the error", file: file, line: line)
        fileMenu.click()
        let good: URL
        do {
            good = try copyFixture("zip/store.zip")
        } catch {
            XCTFail("copy failed: \(error)", file: file, line: line)
            return
        }
        open(good)
        waitForArchive(app.row("hello.txt"), file: file, line: line)
    }
}
