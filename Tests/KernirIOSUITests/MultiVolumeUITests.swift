import XCTest

/// A split archive with a missing part opens to the locked view with Choose Folder…, never a partial list.
@MainActor
final class MultiVolumeUITests: XCTestCase {
    /// `ArchiveVolumeError.missing`'s text for part 2 (App/Shared/ArchiveError+Localized.swift).
    private let missingPart2 = "Part 2 of “s7.7z.001” is missing."

    override func setUp() {
        continueAfterFailure = false
    }

    /// The hook copies only `s7.7z.001` into Documents, so part 2 is missing.
    func testMissingPartShowsChooseFolder() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "multivolume/missing/s7.7z.001")

        XCTAssertTrue(app.staticTexts[missingPart2].waitForExistence(timeout: 10),
                      "The missing part's message did not appear")
        let choose = app.buttons["Choose Folder…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        XCTAssertTrue(choose.isHittable)
        XCTAssertEqual(app.cells.count, 0, "A split archive with a missing part must not list rows")

        // The picker comes up; Cancel returns to the locked view.
        choose.tap()
        // iOS 26.5's picker shows Cancel as an icon of type Other, not Button. Once the picker has
        // opened a folder, that Cancel sits in a hidden bar (hit point {-1, -1}: the tap did
        // nothing and the picker stayed, its file cell counted below). Tap a Cancel that can be
        // hit, else pull the sheet down.
        // iPad: the picker is a form sheet whose bar Cancel is a Button (as in EditUITests'
        // `cancelPicker`), but bound by index from the `.any` query below it never resolves (3
        // retries, then not hittable), and a drag over the sheet's content doesn't dismiss a form
        // sheet. So the hittable Cancel Button goes first, and the iPad fallback pulls the bar.
        let cancels = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Cancel'"))
        XCTAssertTrue(cancels.firstMatch.waitForExistence(timeout: 10), "The folder picker did not appear")
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 2), Self.waitUntilHittable(cancelButton, timeout: 5) {
            cancelButton.tap()
        } else if let cancel = cancels.allElementsBoundByIndex.first(where: \.isHittable) {
            cancel.tap()
        } else if UIDevice.current.userInterfaceIdiom == .pad, app.filesPicker.exists {
            app.filesPicker.swipeDown(velocity: .fast)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(cancels.firstMatch.waitForNonExistence(timeout: 10), "The folder picker stayed open")
        XCTAssertTrue(app.buttons["Choose Folder…"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells.count, 0)
    }

    /// Polls `element.isHittable` until it holds or `timeout` passes (the iPad form sheet is
    /// still sliding in right after Choose Folder… is tapped).
    private static func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return element.exists && element.isHittable
    }
}
