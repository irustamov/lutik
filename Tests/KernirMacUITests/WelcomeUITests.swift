import XCTest

/// The Mac Welcome window. Each launch starts
/// from a first-launch state with `-KernirWelcomeReset YES`; "Make … the Default App" runs dry
/// (`-KernirDefaultAppDryRun YES`), so the machine's default apps never change.
@MainActor
final class WelcomeUITests: KernirMacUITestCase {
    override class var suppressesWelcome: Bool { false }

    /// By its identifier, whatever its type: a window with no minimize button reads as a Dialog.
    private var welcome: XCUIElement {
        app.children(matching: .any).matching(identifier: "KernirWelcome").firstMatch
    }

    private var showAtLaunch: XCUIElement {
        welcome.checkBoxes["WelcomeShowAtLaunch"]
    }

    private var openArchive: XCUIElement { welcome.buttons["WelcomeOpenArchive"] }

    /// The hero art: a heading with its VoiceOver label (exposed as text or image by role, so any type).
    private var hero: XCUIElement { welcome.descendants(matching: .any)["WelcomeHero"] }

    private var newArchive: XCUIElement { welcome.buttons["WelcomeNewArchive"] }

    /// The standard Open panel: a window of its own (identifier "open-panel"), not a sheet.
    private var openPanel: XCUIElement {
        app.children(matching: .any).matching(identifier: "open-panel").firstMatch
    }

    private func launchFresh(_ extra: [String] = []) {
        app.launchArguments += ["-KernirWelcomeReset", "YES", "-KernirDefaultAppDryRun", "YES"] + extra
        app.launch()
        rememberOwnInstances()
    }

    func testShowsOnFreshLaunchWithCheckbox() {
        launchFresh()
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(showAtLaunch.exists, welcome.debugDescription)
        XCTAssertEqual(showAtLaunch.value as? Int, 1)
        XCTAssertEqual(openArchive.label, "Open Archive…")
        // "Welcome to <app>" is the hero art's VoiceOver label (and the window's title), not text on it.
        XCTAssertTrue(hero.exists, welcome.debugDescription)
        XCTAssertTrue(hero.label.hasPrefix("Welcome to "), hero.label)
        XCTAssertFalse(welcome.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Welcome to ")).firstMatch.exists,
                       welcome.debugDescription)
        // Esc closes it (WelcomeWindow.cancelOperation), wherever the keyboard focus is.
        welcome.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(welcome.waitForNonExistence(timeout: 5), "Esc didn't close the Welcome window")
    }

    func testCheckboxOffKeepsItClosedNextLaunch() {
        launchFresh()
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        showAtLaunch.click()
        XCTAssertEqual(showAtLaunch.value as? Int, 0)
        app.terminate()
        if let reset = app.launchArguments.firstIndex(of: "-KernirWelcomeReset") {
            app.launchArguments.removeSubrange(reset...reset + 1)
        }
        app.launch()
        rememberOwnInstances()
        XCTAssertTrue(app.menuBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(welcome.waitForExistence(timeout: 3), "the Welcome window showed with its checkbox off")
        // Leave the app's defaults as a first launch leaves them: the checkbox back on.
        app.typeKey("1", modifierFlags: [.command, .shift])
        XCTAssertTrue(welcome.waitForExistence(timeout: 5), "⇧⌘1 didn't open the Welcome window")
        XCTAssertEqual(showAtLaunch.value as? Int, 0)
        showAtLaunch.click()
        XCTAssertEqual(showAtLaunch.value as? Int, 1)
        // Esc closes it with the keyboard focus on a control, too.
        welcome.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(welcome.waitForNonExistence(timeout: 5), "Esc didn't close the Welcome window")
    }

    func testOpenArchiveShowsTheOpenPanel() {
        launchFresh()
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        openArchive.click()
        let panel = openPanel
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "no Open panel\n\(app.debugDescription)")
        panel.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Esc didn't cancel the Open panel")
        XCTAssertTrue(welcome.exists, "cancelling the Open panel closed the Welcome window")
    }

    /// New Archive sits in the hero, centred under the dog, and makes a new archive
    /// like File > New; that document's window closes Welcome.
    func testNewArchiveInTheHeroMakesANewArchive() {
        launchFresh()
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(newArchive.exists, welcome.debugDescription)
        XCTAssertTrue(newArchive.isHittable, welcome.debugDescription)
        XCTAssertEqual(newArchive.label, "New Archive")
        XCTAssertEqual(welcome.buttons.matching(identifier: "WelcomeNewArchive").count, 1)
        XCTAssertEqual(newArchive.frame.midX, hero.frame.midX, accuracy: 1, "New Archive isn't centred under the art")
        XCTAssertGreaterThanOrEqual(newArchive.frame.minY, hero.frame.maxY - 1, "New Archive isn't under the art")
        XCTAssertLessThan(newArchive.frame.maxY, openArchive.frame.minY - 100, "New Archive isn't in the hero")
        newArchive.click()
        XCTAssertTrue(app.text(containing: "Drag Files Here").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(welcome.waitForNonExistence(timeout: 5), "the new archive's window didn't close the Welcome window")
        // Exactly one new archive: one click, one document window.
        let emptyText = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Drag Files Here", "Drag Files Here")
        let documents = app.windows.allElementsBoundByIndex.filter { $0.staticTexts.matching(emptyText).count > 0 }
        XCTAssertEqual(documents.count, 1, app.debugDescription)
    }

    func testMakeDefaultDryRunShowsTheOutcome() {
        launchFresh()
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        // The real Make Default would change this Mac's default apps: click only in a dry run
        // (`-KernirDefaultAppDryRun` is Debug-only; `DefaultAppDryRunMarker`).
        let dryRun = welcome.descendants(matching: .any).matching(identifier: "DefaultAppDryRun").firstMatch
        guard dryRun.exists else {
            XCTFail("no dry-run marker: Make Default would change the real default app\n\(welcome.debugDescription)")
            return
        }
        let button = dryRun.buttons["WelcomeMakeDefault"]
        XCTAssertTrue(button.exists, welcome.debugDescription)
        XCTAssertTrue(button.label.hasSuffix("the Default App for Archives"), button.label)
        button.click()
        let outcome = welcome.descendants(matching: .any).matching(identifier: "WelcomeDefaultOutcome").firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 10), welcome.debugDescription)
        XCTAssertTrue(app.text(containing: "is now the default app for archives.").exists, outcome.debugDescription)
        XCTAssertFalse(button.exists)
    }

    func testWindowMenuReopensIt() {
        launchFresh()
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        welcome.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(welcome.waitForNonExistence(timeout: 5), "⌘W didn't close the Welcome window")
        let item = app.menuBars.menuBarItems["Window"].menus.menuItems
            .matching(NSPredicate(format: "title BEGINSWITH %@", "Welcome to ")).firstMatch
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        XCTAssertTrue(welcome.waitForExistence(timeout: 5), "Window > Welcome didn't reopen it")
    }

    /// After the first launch, a launch that opens a document doesn't show it.
    func testDocumentLaunchAfterFirstDoesNotShow() throws {
        app.launchArguments += ["-KernirWelcomeReset", "YES", "-KernirWelcomeSeen", "YES", "-KernirDefaultAppDryRun", "YES"]
        try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))
        XCTAssertFalse(welcome.waitForExistence(timeout: 3), "the Welcome window showed with a document")
    }

    /// Welcome from ⇧⌘1 with an archive open: bringing that archive's window forward again
    /// (Window menu) leaves Welcome open; only a new document's window closes it.
    func testOpenArchiveWindowDoesNotCloseIt() throws {
        app.launchArguments += ["-KernirWelcomeReset", "YES", "-KernirWelcomeSeen", "YES", "-KernirDefaultAppDryRun", "YES"]
        try openFixture("zip/deflate.zip")
        waitForArchive(app.row("hello.txt"))
        XCTAssertFalse(welcome.exists)
        app.typeKey("1", modifierFlags: [.command, .shift])
        XCTAssertTrue(welcome.waitForExistence(timeout: 5), "⇧⌘1 didn't show the Welcome window")
        let item = app.menuBars.menuBarItems["Window"].menus.menuItems
            .matching(NSPredicate(format: "title CONTAINS %@", "deflate")).firstMatch
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Window menu item for the archive")
        item.click()
        XCTAssertFalse(welcome.waitForNonExistence(timeout: 3), "the archive's window closed the Welcome window")
    }

    func testScreenshotLight() { capture(appearance: "light") }

    func testScreenshotDark() { capture(appearance: "dark") }

    /// The window alone, kept in the xcresult as "mac-welcome-<appearance>" for review.
    private func capture(appearance: String) {
        launchFresh(["-KernirAppearance", appearance])
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(welcome.frame.width, 640, "the Welcome window isn't 640 pt wide")
        // Park the pointer below the window, so no control shows a hover.
        welcome.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 24)).hover()
        let attachment = XCTAttachment(screenshot: welcome.screenshot())
        attachment.name = "mac-welcome-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
