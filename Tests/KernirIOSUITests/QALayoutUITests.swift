import XCTest

/// Open and browse under layouts other than the default: an accessibility text size,
/// landscape, and whatever device the suite runs on (run it on an iPhone and an iPad).
@MainActor
final class QALayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// The smoke path on this device: open, see every root entry, push a folder, go back. It
    /// overlaps BrowseUITests.testOpensZipAndPushesFolder on purpose: it's the portrait
    /// baseline for the landscape test below.
    func testOpenAndBrowseSmoke() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        assertBrowses(app)
    }

    /// Accessibility XL text: the archive opens, the rows are hittable, and a folder still pushes.
    func testAccessibilityTextSizeKeepsRowsHittable() {
        // Baseline at the default size, so the test proves the larger size took effect.
        let baseline = XCUIApplication()
        baseline.launchOpening(fixture: "zip/deflate.zip")
        baseline.waitForArchive(baseline.row("docs"))
        let defaultHeight = baseline.staticTexts["docs"].firstMatch.frame.height
        baseline.terminate()

        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("docs"))
        let name = app.staticTexts["docs"].firstMatch
        XCTAssertTrue(name.exists, "the row's name is visible text")
        XCTAssertGreaterThan(name.frame.height, defaultHeight * 1.5,
                             "the name should be drawn at the accessibility size")
        XCTAssertTrue(app.row("docs").isHittable)
        XCTAssertTrue(app.row("hello.txt").exists)
        if !app.row("hello.txt").isHittable { app.swipeUp() }
        XCTAssertTrue(app.row("hello.txt").isHittable, "hello.txt can be scrolled to")
        XCTAssertTrue(app.staticTexts["hello.txt"].firstMatch.exists)

        if !app.row("docs").isHittable { app.swipeDown() }
        app.row("docs").tap()
        XCTAssertTrue(app.row("docs/notes.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["docs"].exists)
    }

    /// The smoke path in landscape.
    func testOpenAndBrowseInLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("docs"))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "not in landscape")
        assertBrowses(app)
    }

    // MARK: - Helpers

    private func assertBrowses(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let docs = app.row("docs")
        app.waitForArchive(docs, file: file, line: line)
        for path in ["empty-dir", "empty.txt", "hello.txt"] {
            XCTAssertTrue(app.row(path).exists, path, file: file, line: line)
        }
        XCTAssertTrue(docs.isHittable, file: file, line: line)

        docs.tap()
        XCTAssertTrue(app.row("docs/nested").waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.row("docs/notes.txt").exists, file: file, line: line)
        XCTAssertTrue(app.row("docs/readme.md").exists, file: file, line: line)
        let bar = app.navigationBars["docs"]
        XCTAssertTrue(bar.exists, file: file, line: line)

        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.row("hello.txt").waitForExistence(timeout: 5), "back at the root", file: file, line: line)
        XCTAssertTrue(app.row("docs/notes.txt").waitForNonExistence(timeout: 5), file: file, line: line)
    }
}
