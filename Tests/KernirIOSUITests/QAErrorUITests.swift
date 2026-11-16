import XCTest

/// Damaged files show the open-failed alert, never crash, and OK returns to a working browser.
@MainActor
final class QAErrorUITests: XCTestCase {
    /// `ArchiveError.unsupportedFormat`'s text (App/Shared/ArchiveError+Localized.swift).
    private let notAnArchive = "This file isn't a supported archive."

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Not an archive (manifest: open = unsupportedFormat)

    func testZeroByteZipShowsNotAnArchiveAlert() throws {
        try skipUnlessLaunchView()
        assertOpenFails("corrupt/zero-bytes.zip", message: notAnArchive)
    }

    func testRandomBytesZipShowsNotAnArchiveAlert() throws {
        try skipUnlessLaunchView()
        assertOpenFails("corrupt/random.zip", message: notAnArchive)
    }

    func testTextFileNamedZipShowsNotAnArchiveAlert() throws {
        try skipUnlessLaunchView()
        assertOpenFails("corrupt/text.zip", message: notAnArchive)
    }

    // MARK: - Truncated (manifest: open = any; an error or a partial listing are both fine)

    func testTruncatedZipShowsAlertOrPartialListing() throws {
        try skipUnlessLaunchView()
        assertOpenFailsOrLists("corrupt/truncated.zip")
    }

    func testTruncated7zShowsAlertOrPartialListing() throws {
        try skipUnlessLaunchView()
        assertOpenFailsOrLists("corrupt/truncated.7z")
    }

    func testTruncatedTarGzShowsAlertOrPartialListing() throws {
        try skipUnlessLaunchView()
        assertOpenFailsOrLists("corrupt/truncated.tar.gz")
    }

    func testTruncatedTarXzShowsAlertOrPartialListing() throws {
        try skipUnlessLaunchView()
        assertOpenFailsOrLists("corrupt/truncated.tar.xz")
    }

    // MARK: - Helpers

    /// For `open == any`: either the open-failed alert (then the same checks as
    /// `assertOpenFails`), or a partial listing of the source fixture's root entries with no
    /// alert. A crash or a hang fails either way.
    private func assertOpenFailsOrLists(_ fixture: String, file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchOpening(fixture: fixture)
        // The truncated fixtures are cut from deflate.zip, lzma2.7z and basic.tar.*, which share these roots.
        let rows = ["docs", "empty-dir", "empty.txt", "hello.txt"].map { app.row($0) }
        let found = app.waitForAny([app.openFailedAlert] + rows, timeout: 15)
        XCTAssertNotNil(found, "\(fixture): neither an alert nor a listing\n\(app.debugDescription)", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        if found == 0 {
            assertAlertDismissesToBrowser(app, fixture: fixture, message: nil, file: file, line: line)
        } else {
            XCTAssertFalse(app.alerts.firstMatch.exists, file: file, line: line)
        }
    }

    /// Opens `fixture`, expects the "Couldn't open" alert (with `message` when the app has a
    /// stable one), taps OK, and checks the app is back at a working launch browser.
    private func assertOpenFails(_ fixture: String, message: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchOpening(fixture: fixture)
        app.waitForArchive(app.openFailedAlert, file: file, line: line)
        assertAlertDismissesToBrowser(app, fixture: fixture, message: message, file: file, line: line)
    }

    /// With the open-failed alert up: checks `message`, taps OK, and checks the app is back at
    /// a working launch browser.
    private func assertAlertDismissesToBrowser(_ app: XCUIApplication, fixture: String, message: String?,
                                               file: StaticString, line: UInt) {
        let alert = app.openFailedAlert
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        XCTAssertFalse(app.passwordField.exists, file: file, line: line)
        if let message {
            XCTAssertTrue(app.alertText(message, in: alert).exists,
                          "\(fixture): expected “\(message)” in \(alert.debugDescription)", file: file, line: line)
        }

        alert.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10), file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, file: file, line: line)

        // The browser still responds. The check is that the tap doesn't time out: XCTest waits for
        // the app to idle before and after it, so a hung main thread fails here. Browse is already
        // selected on iPad, not on iPhone, so the selection itself isn't asserted.
        let browse = app.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5), "launch browser's Browse button", file: file, line: line)
        browse.tap()
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        // On iPad (portrait) Browse brings up the browser's sidebar over its list, which dims the
        // list: then the sidebar's locations are in front, not the location anchor (iPad 26.5).
        let sidebarItem = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sidebar.item."))
            .firstMatch
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 5) || sidebarItem.isInFront,
                      "launch browser after Browse\n\(app.debugDescription)", file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, file: file, line: line)
    }
}
