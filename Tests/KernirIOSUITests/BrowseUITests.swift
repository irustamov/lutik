import XCTest

@MainActor
final class BrowseUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLaunchShowsBrowser() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchSkippingWelcome()
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10))
    }

    func testOpensZipAndPushesFolder() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        // Root rows of deflate.zip: folders first, then files.
        let docs = app.row("docs")
        app.waitForArchive(docs)
        XCTAssertTrue(app.row("empty-dir").exists)
        XCTAssertTrue(app.row("hello.txt").exists)

        docs.tap()
        XCTAssertTrue(app.row("docs/nested").waitForExistence(timeout: 5))
        XCTAssertTrue(app.row("docs/notes.txt").exists)
        XCTAssertTrue(app.row("docs/readme.md").exists)
        XCTAssertFalse(app.row("hello.txt").exists)
        let bar = app.navigationBars["docs"]
        XCTAssertTrue(bar.exists)
        XCTAssertTrue(bar.buttons.element(boundBy: 0).isHittable, "back button")
    }

    func testSearchFiltersRows() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"))
        XCTAssertTrue(app.row("empty.txt").exists)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("hello")
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(app.row("empty.txt").waitForNonExistence(timeout: 5))
    }

    func testWrongPasswordReprompts() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/aes256.zip")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        app.waitUntilSettled(field)
        field.tap()
        field.typeText("nope")
        app.buttons["Open"].tap()

        // ArchiveError.wrongPassword's text.
        let wrong = app.staticTexts["The password is incorrect."]
        XCTAssertTrue(wrong.waitForExistence(timeout: 10))
        XCTAssertTrue(field.exists)
        XCTAssertTrue(app.buttons["Cancel"].waitForEnabled(timeout: 5))
        field.tap()
        field.typeText("kernir")
        app.buttons["Open"].tap()

        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 10))
        XCTAssertFalse(field.exists)
    }

    /// The sheet offers to remember the password, off by default. Left off here: the fixture
    /// hook opens a copy at a fixed path, so a saved item would follow later launches.
    func testPasswordSheetHasRememberToggle() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/aes256.zip")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        let remember = app.switches["Remember in Keychain"]
        XCTAssertTrue(remember.waitForExistence(timeout: 5))
        XCTAssertEqual(remember.value as? String, "0")
    }

    func testPasswordCancelReturnsToBrowser() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/aes256.zip")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        // The tap must wait for the sheet to stop moving: one sent while the keyboard pushes it
        // up lands at Cancel's old place and misses.
        let cancel = app.buttons["Cancel"]
        app.waitUntilSettled(cancel)
        cancel.tap()
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10))
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.hasArchiveSearchField)
    }

    /// A 7z with encrypted data but plain headers lists, yet like ZIP it asks for the
    /// password before it opens.
    func testEncryptedData7zPromptsForPassword() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "7z/encrypted-data.7z")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        XCTAssertFalse(app.row("hello.txt").exists)
        app.waitUntilSettled(field)
        field.tap()
        field.typeText("kernir")
        app.buttons["Open"].tap()

        XCTAssertTrue(app.row("docs").waitForExistence(timeout: 10))
        XCTAssertTrue(app.row("hello.txt").exists)
        XCTAssertFalse(field.exists)
    }

    /// A 7z wrong password can repeat even when the password is right (damage in the first
    /// encrypted entry looks the same), so the sheet only shows the error, never retries on its
    /// own, and Cancel always gets the user out. From the second wrong password in a row the
    /// sheet adds that the archive may be damaged.
    func testEncryptedData7zWrongPasswordThenCancel() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "7z/encrypted-data.7z")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        app.waitUntilSettled(field)
        field.tap()
        field.typeText("nope")
        app.buttons["Open"].tap()

        let wrong = app.staticTexts["The password is incorrect."]
        let hint = app.staticTexts["If the password is right, the archive may be damaged."]
        XCTAssertTrue(wrong.waitForExistence(timeout: 10))
        XCTAssertTrue(field.exists)
        XCTAssertFalse(hint.exists)
        let cancel = app.buttons["Cancel"]
        // Enabled again once the sheet has cleared the field after the rejected try.
        XCTAssertTrue(cancel.waitForEnabled(timeout: 5))
        field.tap()
        field.typeText("nope2")
        app.buttons["Open"].tap()

        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        XCTAssertTrue(wrong.exists)
        XCTAssertTrue(field.exists)
        XCTAssertTrue(cancel.waitForEnabled(timeout: 5))
        cancel.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10))
        XCTAssertFalse(app.hasArchiveSearchField)
    }

    /// A 7z with encrypted headers can't list without a password, so it prompts too.
    func testEncryptedHeaders7zPromptsAndRejectsWrongPassword() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "7z/encrypted-headers.7z")
        let field = app.secureTextFields["Password"]
        app.waitForArchive(field)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.waitUntilSettled(field)
        field.tap()
        field.typeText("nope")
        app.buttons["Open"].tap()

        let wrong = app.staticTexts["The password is incorrect."]
        XCTAssertTrue(wrong.waitForExistence(timeout: 10))
        XCTAssertTrue(field.exists)
        XCTAssertTrue(app.buttons["Cancel"].waitForEnabled(timeout: 5))
        field.tap()
        field.typeText("kernir")
        app.buttons["Open"].tap()

        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 10))
        XCTAssertFalse(field.exists)
    }

    /// A RAR with encrypted headers can't be opened, so it shows an alert, no prompt.
    func testEncryptedHeadersRarShowsAlert() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "third-party/rar/rar5-encrypted-headers.rar")
        let alert = app.alerts.firstMatch
        let text = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "aren't supported yet"))
        app.waitForArchive(text.firstMatch)
        XCTAssertFalse(app.secureTextFields["Password"].exists)

        alert.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10))
    }

    /// BUG 2: a single-stream .gz lists one file whose size KernirCore can't know. The row shows
    /// "--" (VoiceOver: "Unknown size"), nothing on screen says "0 KB", and a tap previews the file.
    /// The document is titled "hello.txt" too, so this also checks `row` finds the row, not the bar.
    func testSingleStreamFileShowsNoSizeAndPreviews() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "single/hello.txt.gz")
        let row = app.row("hello.txt")
        app.waitForArchive(row)
        XCTAssertEqual(row.elementType, .button, "found \(row.debugDescription)")
        XCTAssertEqual(row.label, "hello.txt, Unknown size")
        let sizes = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "KB"))
        XCTAssertEqual(sizes.count, 0, "a size is shown\n\(app.debugDescription)")

        row.tap()
        app.assertPreviewShown(title: "hello", timeout: 15)
        app.closePreview()
    }
}

extension XCUIApplication {
    /// A browser row, found by its archive path (the row's accessibility identifier). Navigation
    /// bars are left out: a bar's identifier is its title, and a document or folder can be titled
    /// like a row ("hello.txt.gz" is titled "hello.txt" and holds "hello.txt"; BUG 2).
    func row(_ path: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND elementType != %@", path,
                                  NSNumber(value: XCUIElement.ElementType.navigationBar.rawValue)))
            .firstMatch
    }
}
