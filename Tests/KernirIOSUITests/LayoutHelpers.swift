import XCTest

/// Width-dependent layout: where the bar's centre items go and how sheets and popovers come up.
extension XCUIApplication {
    /// The app lays out at regular width: true only on iPad launched without the DEBUG
    /// `-KernirCompactWidth` override, which makes every window compact (as in Split View or Slide
    /// Over). Popovers, form sheets and the bar's centre items depend on it, not on the device.
    var isRegularWidth: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && !launchArguments.contains("-KernirCompactWidth")
    }

    /// `name` is a button on the navigation bar itself, tappable without opening "More".
    func isOnBar(_ name: String) -> Bool {
        let item = navigationBars.buttons[name].firstMatch
        return item.exists && item.isHittable
    }

    /// Select and Save a Copy… (the bar's centre items) as this width places them on every
    /// level: on the bar itself at regular width, in "More" at compact width. `level` names the
    /// level in messages and in the screenshot kept for an image check.
    func assertCenterItemsPlaced(level: String, file: StaticString = #filePath, line: UInt = #line) {
        let names = ["Select", "Save a Copy…"]
        if isRegularWidth {
            recordBar("\(level): centre items on the bar", expecting: names, file: file, line: line)
        } else {
            assertInMoreMenu(names, level: level, file: file, line: line)
        }
    }

    /// `names` are not on the bar but in its "More" menu. The menu is opened, recorded and closed again.
    func assertInMoreMenu(_ names: [String], level: String, file: StaticString = #filePath, line: UInt = #line) {
        for name in names {
            XCTAssertFalse(isOnBar(name), "\(level): \(name) is on the bar, not in More", file: file, line: line)
        }
        let more = navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "\(level): no More on the bar\n\(debugDescription)",
                      file: file, line: line)
        more.tap()
        for name in names {
            XCTAssertTrue(buttons[name].firstMatch.waitForExistence(timeout: 5),
                          "\(level): \(name) is not in More\n\(debugDescription)", file: file, line: line)
        }
        attachScreenshot("\(level): More menu")
        // A tap just left of the menu closes it, as in `pickerOffersNewFolder`.
        let first = buttons[names[0]].firstMatch
        let frame = first.frame
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX - 30, dy: frame.midY)).tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5), "\(level): the More menu did not close",
                      file: file, line: line)
    }

    /// `element` (a sheet's bar, say) spans the window's width, within the system's sheet insets:
    /// a sheet at compact width, not a form sheet or popover centred in a regular-width window.
    func assertSpansWindow(_ element: XCUIElement, _ what: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(what) did not come up\n\(debugDescription)",
                      file: file, line: line)
        let window = windows.firstMatch.frame.width
        XCTAssertGreaterThan(element.frame.width, window * 0.9,
                             "\(what) is \(element.frame.width) pt wide in a \(window) pt window: not a compact sheet",
                             file: file, line: line)
    }

    /// Keeps a screenshot named `what`, with `element`'s width against the window's in the
    /// activity's name: for system UI whose layout under the compact override is recorded, not
    /// asserted (the Files picker and the launch browser run out of process).
    func recordWidth(of element: XCUIElement, _ what: String) {
        let window = windows.firstMatch.frame.width
        attachScreenshot("\(what) | \(element.frame.width) pt wide in a \(window) pt window")
    }
}
