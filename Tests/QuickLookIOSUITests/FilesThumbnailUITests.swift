import XCTest

/// Makes the Files app show each thumbnail fixture in the Icons grid of "On My iPhone"
/// and keeps a screenshot of every cell and of the grid. Run by the Quick Look iOS test script with `--thumbnails`,
/// which copies the fixtures and passes their names in KERNIR_THUMBNAIL_FIXTURES (comma-separated,
/// set as TEST_RUNNER_KERNIR_THUMBNAIL_FIXTURES); without it the test skips, so the default
/// `ql-test-ios.sh` run is unchanged.
///
/// No pixel assertion: a cell exposes nothing that says whose thumbnail it shows. The pass/fail for
/// the art is the script's check of the provider's `art <name> (<rule>)` log lines (category
/// thumbnail); the screenshots are the evidence for a human ("Files shows the badged thumbnail").
@MainActor
final class FilesThumbnailUITests: XCTestCase {
    private let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")

    override func setUp() {
        continueAfterFailure = false
    }

    func testIconsGridShowsThumbnails() throws {
        let names = (ProcessInfo.processInfo.environment["KERNIR_THUMBNAIL_FIXTURES"] ?? "")
            .split(separator: ",").map(String.init)
        guard !names.isEmpty else {
            throw XCTSkip("Run by the Quick Look iOS test script with --thumbnails "
                          + "(set TEST_RUNNER_KERNIR_THUMBNAIL_FIXTURES).")
        }

        files.openOnMyIPhone()
        switchToIcons()

        let grid = files.collectionViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 15), "No file grid in On My iPhone")
        // Files asks Quick Look for thumbnails after the cells appear; give the first batch time to draw.
        settle(seconds: 5)
        for name in names {
            // Only look at the cell: a tap on a zip extracts it and a tap on the name starts a rename.
            let cell = files.cells.containing(.staticText, identifier: name).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 15), "\(name) not found in On My iPhone")
            if !cell.isHittable {
                grid.swipeUp()
                settle(seconds: 2)
            }
            keep(cell.screenshot(), named: "thumb-\(name)")
            keep(grid.screenshot(), named: "thumb-\(name)-grid")
        }
    }

    /// View options live in the navigation bar's "More" menu (iOS 17–18) or its own button; the
    /// menu offers "Icons" and "List". Not finding it is not fatal: the screenshots then show the
    /// current view (List shows thumbnails too) and the script prints the warning.
    private func switchToIcons() {
        let icons = files.buttons["Icons"].firstMatch
        for label in ["More", "View Options", "Show View Options"] {
            let button = files.navigationBars.buttons[label].firstMatch
            guard button.waitForExistence(timeout: label == "More" ? 5 : 1) else { continue }
            button.tap()
            if icons.waitForExistence(timeout: 5) {
                icons.tap()
                settle(seconds: 1)
                return
            }
            button.tap()  // close the menu again
        }
        keep(XCUIScreen.main.screenshot(), named: "thumb-view-menu-missing")
        print("ql-test-ios: WARNING: no Icons item in the Files view menu; the screenshots show the current view")
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func settle(seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }
}
