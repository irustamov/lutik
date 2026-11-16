import XCTest

/// The launch browser's info button shows the bundled third-party notices.
@MainActor
final class AcknowledgementsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLaunchBrowserShowsAcknowledgements() {
        let app = XCUIApplication()
        app.launchSkippingWelcome()

        // The launch browser's bar runs in another process; on iOS 26.5 its items reach the
        // accessibility tree as "Other" elements, not buttons.
        let info = app.descendants(matching: .any)["Acknowledgements"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 15), "no Acknowledgements button\n\(app.debugDescription)")

        // On iPhone the browser folds the item into its "…" menu, whose More button carries the
        // item's label; the menu lists it last, below the fold, as a real button. The browser
        // starts there as a collapsed card, and a tap may only expand it, so tap until the sheet
        // or the menu shows.
        let license = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Redistribution and use in source and binary forms")).firstMatch
        let menuItem = app.buttons["Acknowledgements"].firstMatch
        for _ in 0..<3 {
            info.tap()
            if license.waitForExistence(timeout: 3) { break }
            if menuItem.waitForExistence(timeout: 2) {
                // tap() scrolls the menu to it; a swipe on the menu would dismiss it.
                menuItem.tap()
                break
            }
        }
        XCTAssertTrue(license.waitForExistence(timeout: 5), "no license text\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars["Acknowledgements"].exists)
        app.attachScreenshot("Acknowledgements")

        app.navigationBars["Acknowledgements"].buttons.firstMatch.tap()
        XCTAssertTrue(license.waitForNonExistence(timeout: 5), "the sheet did not close")
    }
}
