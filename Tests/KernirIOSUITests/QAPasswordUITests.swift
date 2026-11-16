import XCTest

/// "Remember in Keychain" keeps only a password that opened the archive.
///
/// The Keychain account is the opened file's path (KeychainPasswordStore), and the fixture hook
/// copies the file into Documents under its own name. Each test opens a fresh, uniquely named
/// copy, so it starts with nothing remembered and leaves nothing that another test or a later
/// run could pick up (the app offers no way to forget a password).
///
/// Each run leaves two `qa-*-XXXXXXXX.zip` copies in the app's Documents (they show in the
/// launch browser's Kernir folder) and one Keychain item. Erase the simulator
/// (`xcrun simctl erase <UDID>`) before taking store screenshots on it.
@MainActor
final class QAPasswordUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A smoke test: a wrong password typed with Remember on, then a relaunch, still asks, and
    /// the right password still opens the file. Whether the wrong password was saved can't be
    /// seen here: the app hides a stale saved password on purpose (it stays locked with no
    /// error), so "saved wrong" and "saved nothing" look the same. That part is covered by
    /// ArchiveDocumentTests.unlockWithRememberSavesPassword.
    func testWrongPasswordWithRememberStillAsksAfterRelaunch() throws {
        let copy = try QAFixtures.freshCopy(of: "zip/aes256.zip", prefix: "qa-wrong-remember")
        let app = XCUIApplication()
        app.launchOpening(fileAt: copy)
        app.waitForArchive(app.passwordField)
        turnOnRemember(app)
        enterPassword(QAFixtures.wrongPassword, in: app)
        XCTAssertTrue(app.staticTexts["The password is incorrect."].waitForExistence(timeout: 10))

        app.terminate()
        app.launchSkippingWelcome()
        app.waitForArchive(app.passwordField)
        app.waitForSheetToSettle(app.passwordField)
        XCTAssertFalse(app.staticTexts["The password is incorrect."].exists)
        XCTAssertFalse(app.row("hello.txt").exists)

        enterPassword(QAFixtures.password, in: app)
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 10))
        XCTAssertTrue(app.passwordField.waitForNonExistence(timeout: 5))
    }

    /// A right password typed with Remember on is saved, so the relaunch opens the same file
    /// without asking. The only end-to-end check that the toggle's value reaches
    /// `unlock(password:remember:)`.
    func testRightPasswordWithRememberOpensWithoutPromptAfterRelaunch() throws {
        let copy = try QAFixtures.freshCopy(of: "zip/aes256.zip", prefix: "qa-right-remember")
        let app = XCUIApplication()
        app.launchOpening(fileAt: copy)
        app.waitForArchive(app.passwordField)
        turnOnRemember(app)
        enterPassword(QAFixtures.password, in: app)
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 10))

        app.terminate()
        app.launchSkippingWelcome()
        app.waitForArchive(app.row("hello.txt"))
        XCTAssertFalse(app.passwordField.exists)
        XCTAssertFalse(app.navigationBars["Enter Password"].exists)
    }

    // MARK: - Helpers

    private func turnOnRemember(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let remember = app.switches["Remember in Keychain"]
        XCTAssertTrue(remember.waitForExistence(timeout: 5), file: file, line: line)
        // The sheet presents and the keyboard comes up after the field exists; a tap during
        // that lands at the switch's old frame and doesn't flip it.
        app.waitForSheetToSettle(remember, file: file, line: line)
        XCTAssertEqual(remember.value as? String, "0", file: file, line: line)
        // The SwiftUI toggle row's own switch; tapping the row's label doesn't flip it on iOS 26.
        let control = remember.switches.firstMatch.exists ? remember.switches.firstMatch : remember
        control.tap()
        let on = NSPredicate(format: "value == '1'")
        let flipped = XCTNSPredicateExpectation(predicate: on, object: remember)
        XCTAssertEqual(XCTWaiter().wait(for: [flipped], timeout: 5), .completed,
                       "Remember in Keychain did not turn on", file: file, line: line)
    }

    private func enterPassword(_ password: String, in app: XCUIApplication) {
        let field = app.passwordField
        // On a cold boot the keyboard arrives ~0.8 s after the sheet and moves it ~330 pt; a
        // tap at that moment misses the field or lands on the Remember switch.
        app.waitForSheetToSettle(field)
        field.tap()
        field.typeText(password)
        app.buttons["Open"].tap()
    }
}
