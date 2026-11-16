import XCTest

extension XCTestCase {
    /// iOS 27 or later: the launch browser's expected failures apply.
    static var isIOS27: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    /// iOS 18 or later: the window's root is the stock launch view (iOS 17, the deployment
    /// target: the full-screen browser, with no launch view's New Archive button).
    static var hasLaunchView: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18 }

    /// Tests that use the launch view's helpers (`launchNewArchiveButtons`, `launchNewArchive`,
    /// `waitForLaunchBrowserInFront`, `frontLaunchNewArchive`) start with this; tests that run on
    /// iOS 17 too use `waitForBrowserInFront`.
    func skipUnlessLaunchView() throws {
        try XCTSkipUnless(Self.hasLaunchView, "launch view is iOS 18+")
    }
}

extension XCUIApplication {
    /// Launches the app and has the DEBUG-only `-KernirOpenFixture` hook open `Fixtures/<fixture>`.
    func launchOpening(fixture: String, file: StaticString = #filePath) {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = repoRoot.appendingPathComponent("Fixtures").appendingPathComponent(fixture).path
        launchArguments += ["-KernirOpenFixture", path]
        skipWelcomeSheet()
        launch()
    }

    /// The one-time Welcome sheet counts as seen for this launch: `-KernirWelcomeSeen YES` is the
    /// argument domain over the app's defaults, so the sheet doesn't cover the browser (a launch
    /// with a file doesn't show it either, but other windows iPad restores would). Every UI test
    /// launch has it but WelcomeUITests', whose `-KernirWelcomeReset` launches keep the sheet.
    func skipWelcomeSheet() {
        guard !launchArguments.contains("-KernirWelcomeSeen"), !launchArguments.contains("-KernirWelcomeReset") else {
            return
        }
        launchArguments += ["-KernirWelcomeSeen", "YES"]
    }

    /// `launch()` past the Welcome sheet (`skipWelcomeSheet`).
    func launchSkippingWelcome() {
        skipWelcomeSheet()
        launch()
    }
}

extension XCUIApplication {
    /// Taps `name` in the launch browser, which shows the app's folder (where the fixture hook
    /// copies files). The browser lists only the cells on screen, and the folder may hold other
    /// tests' files too.
    func pickInLaunchBrowser(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let cell = cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "\(name),")).firstMatch
        let files = collectionViews["File View"].firstMatch
        // The location the browser shows: "DOC.browsingRoot Source: <source>, Title: <title>".
        // On My iPad / iPhone and its folders are the LocalStorage source.
        let onDevice = otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                          "DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage"))
            .firstMatch
        _ = files.waitForExistence(timeout: 5)
        if !onDevice.exists {
            // A fresh install's browser opens at Recents. Up to iOS 26 that showed "Content
            // Unavailable" and no "File View"; on iOS 27 it has a "File View" with "No Recents"
            // or other tests' files, so the location, not the list, decides. Go to On My iPad /
            // iPhone under Browse.
            let device = cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sidebar.item.On My"))
                .firstMatch
            let browse = buttons["Browse"].firstMatch
            if !device.exists, browse.exists {
                browse.tap()
            }
            if device.waitForExistence(timeout: 5) {
                device.tap()
            }
            XCTAssertTrue(onDevice.waitForExistence(timeout: 10),
                          "The browser didn't go to On My iPad / iPhone\n\(debugDescription)", file: file, line: line)
        }
        // iOS 27.2 simulators (2026-11-11) reached the app's folder (Title: Kernir) but
        // showed "Folder is Empty" and no "File View" while the fixture was in Documents; going up
        // and back in ~1 s later showed it empty too, so there is no retry. Name that state rather
        // than "No folder in the browser" or "<name> is not in the browser". The cause is unproven.
        let empty = staticTexts["Folder is Empty"].firstMatch
        func failIfEmpty() -> Bool {
            guard !files.exists, empty.exists else { return false }
            let root = otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.browsingRoot"))
                .firstMatch
            let title = root.exists
                ? root.identifier.range(of: "Title: ").map { String(root.identifier[$0.upperBound...]) } ?? root.identifier
                : "none"
            XCTFail("The launch browser lists the app's folder as empty (title: \(title)) although the fixture "
                    + "copied \(name) into Documents (cause unproven)\n\(debugDescription)",
                    file: file, line: line)
            return true
        }
        let listed = files.waitForExistence(timeout: 10)
        if !listed, failIfEmpty() { return }
        XCTAssertTrue(listed, "No folder in the browser\n\(debugDescription)", file: file, line: line)
        // iPad can show the device's top level, with the app's folder as a cell: go into it.
        let appFolder = cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "\(appFolderName),")).firstMatch
        if !cell.exists, appFolder.exists {
            appFolder.tap()
            _ = cell.waitForExistence(timeout: 5)
            if !cell.exists, failIfEmpty() { return }
        }
        for _ in 0..<15 where !(cell.exists && cell.isHittable) {
            files.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(cell.exists, "\(name) is not in the browser\n\(debugDescription)", file: file, line: line)
        XCTAssertTrue(cell.isHittable, "\(name) is not on screen in the browser\n\(debugDescription)",
                      file: file, line: line)
        cell.tap()
    }

    /// Waits for `element`. Fails at once if the app shows the stub engine's alert ("This
    /// feature isn't available yet."): KernirCore's real reader is on main, so that is a regression.
    func waitForArchive(_ element: XCUIElement, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) {
        let stub = alerts.staticTexts["This feature isn't available yet."]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return }
            if stub.exists {
                XCTFail("The app shows the stub engine's alert; KernirCore's real reader should open this archive.",
                        file: file, line: line)
                return
            }
            _ = element.waitForExistence(timeout: 0.5)
        }
        XCTFail("\(element) did not appear", file: file, line: line)
    }

    /// Waits until the password sheet has finished moving, so a tap lands on `element`.
    /// The sheet presents at its medium detent and its field takes focus; when the keyboard comes
    /// up (on a freshly booted simulator ~0.8 s later) the sheet moves up by ~330 pt. XCUITest
    /// reads an element's frame before it sends the tap, so a tap in that window lands where the
    /// element was and misses it. Waits for the keyboard (unless `waitForKeyboard` is false, where
    /// none is expected), then for `element` to be hittable and in the same place on three reads
    /// 0.2 s apart. With `waitForKeyboard: false` it also guards the launch browser's New Archive
    /// button (see `tapNewArchive`). Mirrors `waitForSheetToSettle`. Fails and returns false if it doesn't settle.
    @discardableResult
    func waitUntilSettled(_ element: XCUIElement, timeout: TimeInterval = 5, waitForKeyboard: Bool = true,
                          file: StaticString = #filePath, line: UInt = #line) -> Bool {
        // With the simulator's hardware keyboard connected no keyboard appears and the sheet
        // doesn't move for it; the frame check still applies.
        if waitForKeyboard {
            _ = keyboards.firstMatch.waitForExistence(timeout: timeout)
        }
        if waitForStableFrame(element, timeout: timeout, hittable: true) { return true }
        XCTFail("\(element) kept moving or never became hittable\n\(element.debugDescription)", file: file, line: line)
        return false
    }

    /// Reads `element.frame` every 0.2 s until it is the same on three reads in a row (and, with
    /// `hittable`, the element is hittable on each), or `timeout` passes. Returns whether it settled.
    private func waitForStableFrame(_ element: XCUIElement, timeout: TimeInterval = 5, hittable: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.frame
        var stableReads = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            let now = element.frame
            stableReads = now == last && (!hittable || element.isHittable) ? stableReads + 1 : 0
            if stableReads >= 2 { return true }
            last = now
        }
        return false
    }

    /// Taps the launch browser's New Archive button (the launch view's primary action) once the
    /// browser has finished coming in. A tap ~20 ms after the button exists, during the browser's
    /// entrance transition, hits {-1,-1} and brings no sheet. So this
    /// waits for the browser's mode tab bar to stop moving, then for the button itself to settle,
    /// and fails without tapping if either doesn't.
    /// iPad has no `DOC.browsingModeTabBar` (its browser has a sidebar, and Browse is a segment in
    /// the bar; see `ScreenshotTests.testZFilesBrowser`): at regular width (`isRegularWidth`) the
    /// tab bar gets a 0.5 s look, at compact width (iPhone, or iPad with `-KernirCompactWidth`) 5 s.
    /// Wherever the tab bar doesn't show up in that time, only the button's own frame + hittable
    /// check applies.
    func tapNewArchive(file: StaticString = #filePath, line: UInt = #line) {
        let button = buttons["New Archive"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no New Archive button\n\(debugDescription)",
                      file: file, line: line)
        let tabBar = tabBars["DOC.browsingModeTabBar"].firstMatch
        let expectTabBar = !isRegularWidth
        if tabBar.waitForExistence(timeout: expectTabBar ? 5 : 0.5) {
            guard waitForStableFrame(tabBar, hittable: false) else {
                XCTFail("The browser's tab bar kept moving; New Archive not tapped\n\(debugDescription)",
                        file: file, line: line)
                return
            }
        }
        guard waitUntilSettled(button, waitForKeyboard: false, file: file, line: line) else { return }
        button.tap()
    }
}
