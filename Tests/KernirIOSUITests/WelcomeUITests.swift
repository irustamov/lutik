import XCTest

/// The one-time Welcome sheet: a first plain launch shows it over the
/// browser, Continue closes it, and it never comes back; a launch to open a file leaves it for a
/// later plain launch. `-KernirWelcomeReset YES` (DEBUG) makes a launch a first one.
@MainActor
final class WelcomeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func sheetTitle(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["WelcomeTitle"].firstMatch
    }

    private func continueButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["WelcomeContinue"].firstMatch
    }

    func testFirstLaunchShowsSheetOnce() {
        let app = XCUIApplication()
        app.launchArguments = ["-KernirWelcomeReset", "YES"]
        app.launch()

        XCTAssertTrue(sheetTitle(app).waitForExistence(timeout: 15), "no Welcome sheet\n\(app.debugDescription)")
        XCTAssertTrue(sheetTitle(app).label.hasPrefix("Welcome to "), sheetTitle(app).label)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "tap Share")).firstMatch.exists,
                      "no Files hint\n\(app.debugDescription)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Welcome sheet"
        shot.lifetime = .keepAlways
        add(shot)

        let button = continueButton(app)
        XCTAssertTrue(button.isHittable, "Continue is not on screen\n\(app.debugDescription)")
        button.tap()
        XCTAssertTrue(sheetTitle(app).waitForNonExistence(timeout: 5), "Continue did not close the sheet")
        XCTAssertTrue(app.waitForBrowserInFront(timeout: 10), "no browser after Continue\n\(app.debugDescription)")

        // Seen: a relaunch goes straight to the browser.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.waitForBrowserInFront(timeout: 15), "no browser\n\(app.debugDescription)")
        XCTAssertFalse(sheetTitle(app).waitForExistence(timeout: 3), "the Welcome sheet came back")
    }

    /// Opening a file shows the archive, not the sheet; the next plain launch shows the sheet.
    func testFileLaunchDefersSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-KernirWelcomeReset", "YES"]
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"), timeout: 15)
        XCTAssertFalse(sheetTitle(app).exists, "the Welcome sheet covers the opened archive")

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(sheetTitle(app).waitForExistence(timeout: 15), "no Welcome sheet on the later plain launch\n\(app.debugDescription)")
        continueButton(app).tap()
        XCTAssertTrue(sheetTitle(app).waitForNonExistence(timeout: 5), "Continue did not close the sheet")
    }

    /// A file URL opened while the sheet is up (as from Files' Open In) takes the sheet away and
    /// shows the archive; once the archive closes, the browser is in front with no sheet left.
    func testOpenURLWhileSheetIsUpDismissesIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-KernirWelcomeReset", "YES"]
        app.launch()
        XCTAssertTrue(sheetTitle(app).waitForExistence(timeout: 15), "no Welcome sheet\n\(app.debugDescription)")

        let file = try QAFixtures.freshCopy(of: "zip/deflate.zip", prefix: "WelcomeOpenURL")
        app.open(file)
        app.waitForArchive(app.row("hello.txt"), timeout: 15)
        XCTAssertTrue(sheetTitle(app).waitForNonExistence(timeout: 5), "the Welcome sheet is still up under the archive")

        // Opened by URL, the browser's title is the back button's label: iPhone names it
        // "BackButton"; iPad shows the label "Documents" without that identifier.
        let back = app.navigationBars.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "BackButton", "Documents")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button on the archive's bar\n\(app.debugDescription)")
        back.tap()
        XCTAssertTrue(app.waitForBrowserInFront(timeout: 10), "no browser after the close\n\(app.debugDescription)")
        XCTAssertFalse(sheetTitle(app).exists, "the Welcome sheet came back after the close")
        XCTAssertFalse(continueButton(app).exists, "the Welcome sheet came back after the close")
    }
}
