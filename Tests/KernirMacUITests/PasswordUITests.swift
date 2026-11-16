import XCTest

/// Encrypted archives: the password sheet for ZIP and 7z (an encrypted-data RAR is read-only and never prompts).
/// "Remember in Keychain" is never turned on here, so no test leaves a Keychain item behind.
final class PasswordUITests: KernirMacUITestCase {
    var passwordField: XCUIElement { app.sheets.secureTextFields.firstMatch }

    func testAES256ZipWrongThenRightPassword() throws {
        try openFixture("zip/aes256.zip")
        let field = passwordField
        waitForArchive(field)
        XCTAssertTrue(app.text(containing: "“aes256.zip” is password-protected.").exists)
        let remember = app.sheets.checkBoxes["Remember in Keychain"]
        XCTAssertTrue(remember.exists)
        XCTAssertEqual(remember.value as? Int, 0, "Remember in Keychain is off by default")
        let open = app.sheets.buttons["Open"]
        XCTAssertFalse(open.isEnabled, "Open without a password")

        field.click()
        field.typeText("not-kernir")
        open.click()

        // Wrong: the sheet stays, says why, and the field is cleared for another try.
        XCTAssertTrue(app.text(containing: "Wrong password. Try again.").waitForExistence(timeout: 10))
        XCTAssertTrue(field.exists)
        XCTAssertFalse(app.row("hello.txt").exists)
        XCTAssertFalse(open.isEnabled, "the field is cleared after a wrong password")

        field.click()
        field.typeText("kernir")
        open.click()
        waitForArchive(app.row("hello.txt"))
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])
    }

    func testPasswordCancelClosesDocument() throws {
        try openFixture("zip/aes256.zip")
        let field = passwordField
        waitForArchive(field)
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS %@", "aes256.zip"))
            .firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(app.state, .notRunning)
    }

    /// A 7z with encrypted headers asks for its password. From the second wrong try the sheet
    /// adds that the archive may be damaged.
    func testEncryptedHeaders7zWrongThenRightPassword() throws {
        try openFixture("7z/encrypted-headers.7z")
        let field = passwordField
        waitForArchive(field)
        XCTAssertTrue(app.text(containing: "“encrypted-headers.7z” is password-protected.").exists)
        XCTAssertFalse(app.text(containing: "aren't supported yet").exists)
        let open = app.sheets.buttons["Open"]
        let damaged = app.text(containing: "the archive may be damaged")

        field.click()
        field.typeText("not-kernir")
        open.click()
        XCTAssertTrue(app.text(containing: "Wrong password. Try again.").waitForExistence(timeout: 10))
        XCTAssertFalse(damaged.exists, "no damaged hint after the first wrong password")

        field.click()
        field.typeText("not-kernir")
        open.click()
        XCTAssertTrue(damaged.waitForExistence(timeout: 10), "damaged hint after the second wrong password")
        XCTAssertFalse(app.row("hello.txt").exists)

        field.click()
        field.typeText("kernir")
        open.click()
        waitForArchive(app.row("hello.txt"))
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])
    }

    /// A 7z with encrypted data but plain headers asks too (its entries can't be read without
    /// the password), unlike an encrypted-data RAR (read-only, no prompt).
    func testEncryptedData7zAsksForPassword() throws {
        try openFixture("7z/encrypted-data.7z")
        let field = passwordField
        waitForArchive(field)
        XCTAssertTrue(app.text(containing: "“encrypted-data.7z” is password-protected.").exists)
        XCTAssertFalse(app.text(containing: "aren't supported yet").exists)

        field.click()
        field.typeText("kernir")
        app.sheets.buttons["Open"].click()
        waitForArchive(app.row("hello.txt"))
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.visibleRowNames, ["docs", "empty-dir", "empty.txt", "hello.txt"])
        let summary = try XCTUnwrap(app.footer.value as? String)
        XCTAssertTrue(summary.hasSuffix(" · 7z"), summary)
    }
}
