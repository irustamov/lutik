import XCTest

/// New Archive from the launch browser and Save As Copy, both through the save options sheet.
@MainActor
final class SaveOptionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The launch browser's New Archive asks for the options (ZIP first), and Create opens the
    /// new, empty archive. Each run leaves an "Untitled" archive where the browser saved it.
    func testNewArchiveFromBrowser() {
        let app = XCUIApplication()
        app.launchSkippingWelcome()
        app.tapNewArchive()
        let create = app.saveOptionsButton("Create")
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        app.assertFormat("ZIP")
        app.attachScreenshot("New Archive sheet")

        // The Advanced disclosure opens and shows the method choice.
        app.buttons["Advanced"].firstMatch.tap()
        XCTAssertTrue(app.pickerRow("Method").waitForExistence(timeout: 5), app.debugDescription)
        app.attachScreenshot("New Archive sheet, Advanced")

        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.staticTexts["No Items"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertFalse(create.exists)
    }

    /// The launch view's own New Archive button (on the Lutik art,
    /// or in the legacy title card) starts the same flow as the browser's: a real tap brings
    /// the options sheet.
    func testNewArchiveFromTheLaunchArt() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchSkippingWelcome()
        let button = app.launchNewArchive
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(button.label, "New Archive")
        guard app.waitUntilSettled(button, waitForKeyboard: false) else { return }
        button.tap()
        let create = app.saveOptionsButton("Create")
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        app.attachScreenshot("New Archive sheet from the launch art")
        app.saveOptionsButton("Cancel").tap()
        XCTAssertTrue(create.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// The form follows the format: TAR has no compression level and no encryption; 7z encrypts
    /// with a password, and Create waits for one. Cancel goes back to a working browser.
    func testNewArchiveOptionsFollowFormat() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchSkippingWelcome()
        app.tapNewArchive()
        let create = app.saveOptionsButton("Create")
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.pickerRow("Compression").exists, app.debugDescription)
        XCTAssertTrue(app.encryptToggle.exists, app.debugDescription)

        app.chooseFormat("TAR")
        XCTAssertTrue(app.encryptToggle.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.pickerRow("Compression").exists, app.debugDescription)
        XCTAssertFalse(app.buttons["Advanced"].firstMatch.exists, app.debugDescription)

        app.chooseFormat("7z")
        XCTAssertTrue(app.encryptToggle.waitForExistence(timeout: 5), app.debugDescription)
        // The switch fills the row; its control sits at the trailing end.
        app.encryptToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(app.encryptToggle.value as? String, "1", app.debugDescription)
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.secureTextFields["Verify"].exists)
        XCTAssertTrue(app.staticTexts["Enter a password."].exists, app.debugDescription)
        XCTAssertFalse(create.isEnabled, "Create waits for a password")
        app.attachScreenshot("New Archive sheet, 7z encrypted")

        app.saveOptionsButton("Cancel").tap()
        XCTAssertTrue(create.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    /// New Archive makes the app the launch browser's delegate; an archive picked there must
    /// still open. The fixture hook puts deflate.zip into the app's folder first.
    func testBrowserStillOpensPickedArchive() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"))
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10), app.debugDescription)

        // Open question, not a confirmed simulator limit. Only the pick is expected to fail on
        // iOS 27 (a failed pick makes the `waitForArchive` fail too, inside the same block).
        XCTExpectFailure("iOS 27: launch browser lists Kernir's folder as empty (DocumentManager: "
                         + "'failed to get a cached domain for FILocalAppContainerNode<Kernir>'); Files.app "
                         + "sees the item. Open: verify on a real device. Known iOS 27 launch-browser issue.",
                         enabled: Self.isIOS27, strict: false, failingBlock: {
            app.pickInLaunchBrowser("deflate.zip")
            app.waitForArchive(app.row("hello.txt"))
        })
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
    }

    /// Save As Copy works on a read-only archive: the sheet offers ZIP, and Save hands the copy to
    /// the file mover. Cancelling there leaves the archive open as it was.
    func testSaveAsCopyFromReadOnly() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "third-party/rar/rar5-solid.rar")
        let row = app.row("test.bin")
        app.waitForArchive(row)

        app.tapSaveAsCopy()
        let save = app.saveOptionsButton("Save")
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        app.assertFormat("ZIP")
        app.attachScreenshot("Save As Copy sheet")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.filesPicker.waitForExistence(timeout: 20),
                      "the file mover did not come up\n\(app.debugDescription)")
        app.attachScreenshot("Save As Copy file mover")
        app.cancelPicker()
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertTrue(row.exists)
    }

    /// Save As Copy has the "Exclude Mac metadata" switch, on by default, with the Mac's
    /// footer. It keeps its value when the format changes.
    func testSaveAsCopyShowsMetadataToggle() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        app.tapSaveAsCopy()
        let save = app.saveOptionsButton("Save")
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        let metadata = app.metadataToggle
        XCTAssertTrue(metadata.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(metadata.label, "Exclude Mac metadata (.DS_Store, __MACOSX, ._ files)")
        XCTAssertEqual(metadata.value as? String, "1", "on by default")
        XCTAssertTrue(app.staticTexts["Resource forks and extended attributes are never stored."]
                          .waitForExistence(timeout: 5), app.debugDescription)
        app.attachScreenshot("Save As Copy sheet, metadata")

        // The switch fills the row; its control sits at the trailing end.
        metadata.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(metadata.value as? String, "0", app.debugDescription)
        app.chooseFormat("TAR")
        XCTAssertEqual(metadata.value as? String, "0", "kept across the format change")
        app.chooseFormat("7z")
        XCTAssertEqual(metadata.value as? String, "0", "kept across the format change")
        XCTAssertTrue(save.isEnabled)

        app.saveOptionsButton("Cancel").tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.exists)
    }

    /// New Archive has the same switch, on by default; the Split row is Save As Copy only.
    func testNewArchiveShowsMetadataToggleAndNoSplitRow() throws {
        try skipUnlessLaunchView()
        let app = XCUIApplication()
        app.launchSkippingWelcome()
        app.tapNewArchive()
        let create = app.saveOptionsButton("Create")
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        let metadata = app.metadataToggle
        XCTAssertTrue(metadata.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(metadata.value as? String, "1", "on by default")
        XCTAssertTrue(app.staticTexts["Resource forks and extended attributes are never stored."]
                          .waitForExistence(timeout: 5), app.debugDescription)
        for format in ["7z", "ZIP"] {
            app.chooseFormat(format)
            XCTAssertTrue(metadata.exists, app.debugDescription)
            // The Split row is Save As Copy only.
            XCTAssertFalse(app.descendants(matching: .any)["saveSplit"].exists, "no Split row on New Archive")
        }
        app.attachScreenshot("New Archive sheet, metadata")

        app.saveOptionsButton("Cancel").tap()
        XCTAssertTrue(create.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 5), app.debugDescription)
    }
}

extension XCUIApplication {
    /// The "Exclude Mac metadata" switch (identifier as on the Mac).
    var metadataToggle: XCUIElement { switches["saveExcludeMetadata"].firstMatch }

    /// Save a Copy…, from the bar's More menu (iPhone) or the bar itself (iPad, when there's room).
    func tapSaveAsCopy(file: StaticString = #filePath, line: UInt = #line) {
        let item = buttons["Save a Copy…"].firstMatch
        if !item.exists {
            navigationBars.buttons["More"].firstMatch.tap()
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Save a Copy…\n\(debugDescription)",
                      file: file, line: line)
        item.tap()
    }

    /// A button on the save options sheet's bar: Cancel, Create or Save.
    func saveOptionsButton(_ name: String) -> XCUIElement {
        navigationBars.buttons[name].firstMatch
    }

    var encryptToggle: XCUIElement { switches["Encrypt with password"].firstMatch }

    /// A picker row of the options form: a button labelled "<title>, <value>".
    func pickerRow(_ title: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ", ")).firstMatch
    }

    var formatPicker: XCUIElement { pickerRow("Format") }

    /// The Format picker shows `format`.
    func assertFormat(_ format: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = formatPicker
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no Format picker\n\(debugDescription)",
                      file: file, line: line)
        XCTAssertEqual(picker.label, "Format, \(format)", debugDescription, file: file, line: line)
    }

    /// Opens the Format menu and picks `format`.
    func chooseFormat(_ format: String, file: StaticString = #filePath, line: UInt = #line) {
        formatPicker.tap()
        let option = buttons[format].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "no \(format) in the menu\n\(debugDescription)",
                      file: file, line: line)
        option.tap()
        assertFormat(format, file: file, line: line)
    }

    /// Keeps a screenshot in the result bundle, for review.
    func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(shot) }
    }
}
