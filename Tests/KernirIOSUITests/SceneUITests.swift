import XCTest

/// Windows (scenes): a new window starts at the launch browser, an archive is open in one window
/// at most, and a file opened from outside replaces the window's archive. The two-window tests
/// expect the simulator's full-screen windowing, where the newest window is the one in front.
@MainActor
final class SceneUITests: XCTestCase {
    /// `openNewWindow` opened a window that the test hasn't closed again.
    private var extraWindowOpen = false

    override func setUp() {
        continueAfterFailure = false
    }

    /// The DEBUG `-KernirOpenFixture` hook runs for the first window only. File > New Window
    /// (⌘N) opens a second window at the launch browser; the first keeps its archive. Had the hook
    /// run again, the second window would find the fixture open in the first and bring that one
    /// forward instead of showing its browser. Closing the new window (⌘W) brings the first back,
    /// with its archive.
    func testFixtureHookRunsOnceAcrossScenes() throws {
        try skipUnlessLaunchView()
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPhone has one window")
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let row = app.row("hello.txt")
        app.waitForArchive(row)

        openNewWindow(app)
        closeFrontWindow(app, revealing: row)
        XCTAssertTrue(row.waitUntilHittable(timeout: 10),
                      "The first window didn't come back with its archive\n\(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
    }

    /// One archive, one window: picking in a new window's launch browser the archive the first
    /// window shows brings the first window forward, and the new one keeps its browser. The first
    /// window is in `docs` before the pick: a window that opened the archive afresh would be at
    /// its root.
    func testBrowserPickOfArchiveOpenInAnotherWindowBringsThatWindow() throws {
        try skipUnlessLaunchView()
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPhone has one window")
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let docs = app.row("docs")
        app.waitForArchive(docs)
        docs.tap()
        let notes = app.row("docs/notes.txt")
        XCTAssertTrue(notes.waitUntilHittable(timeout: 10), app.debugDescription)

        openNewWindow(app)
        app.pickInLaunchBrowser("deflate.zip")
        XCTAssertTrue(notes.waitUntilHittable(timeout: 10),
                      "The first window, in docs, didn't come forward\n\(app.debugDescription)")
        XCTAssertFalse(docs.exists && docs.isHittable,
                       "A window at the archive's root is in front: the new window opened the archive itself\n\(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)

        // Close the first window's archive. Bringing a window forward leaves the hardware keys
        // with the new window, so tap the first one before ⌘W. With the archive closed no window
        // shows it: the new window kept its browser. The teardown closes the extra window.
        app.navigationBars["docs"].staticTexts["docs"].firstMatch.tap()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(notes.waitUntilGone(timeout: 10) && docs.waitUntilGone(timeout: 5),
                      "⌘W didn't close the first window's archive, or another window shows it too\n\(app.debugDescription)")
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10),
                      "No launch browser in front after closing the archive\n\(app.debugDescription)")
        // Both windows show their launch view: the first one's, after ⌘W, and the new window's own,
        // which it kept through the pick. Each launch view has one New Archive button on its art.
        var launchViews = app.launchNewArchiveButtons.count
        let deadline = Date().addingTimeInterval(5)
        while launchViews != 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            launchViews = app.launchNewArchiveButtons.count
        }
        XCTAssertEqual(launchViews, 2, """
            The new window didn't keep its own browser: \(launchViews) launch-view New Archive buttons, \
            \(app.fullScreenWindowCount) full-screen windows in the tree (one window: the new one left \
            the tree in the background; two: it lost its browser)
            \(app.debugDescription)
            """)
    }

    /// A file URL opened while an archive is open (as from Files) replaces it in the window.
    func testOpenURLWhileOpenSwitchesDocument() throws {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        let hello = app.row("hello.txt")
        app.waitForArchive(hello)

        let other = try QAFixtures.freshCopy(of: "tar/gnu-long-names.tar", prefix: "OpenURL")
        app.open(other)
        app.waitForArchive(app.row("short.txt"))
        XCTAssertFalse(hello.exists, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
    }
}

extension SceneUITests {
    /// File > New Window (⌘N, the system's on iPadOS 26), then waits for the new window's launch
    /// browser in front. Windows (scene sessions) outlive the app, and leftovers change which one
    /// the next launch restores: unless the test closed a window again (`closeFrontWindow`), the
    /// teardown relaunches with the DEBUG `-KernirCloseOtherWindows` hook, which closes every
    /// window but the one it launches into, whatever the test's outcome.
    func openNewWindow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.pressKeyAfterLaunch("n", modifierFlags: .command)
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 10),
                      "⌘N brought no new window with its browser\n\(app.debugDescription)", file: file, line: line)
        extraWindowOpen = true
        addTeardownBlock { @MainActor [weak self] in
            guard self?.extraWindowOpen ?? true else { return }
            let app = XCUIApplication()
            app.terminate()
            app.launchArguments = ["-KernirCloseOtherWindows"]
            app.launchSkippingWelcome()
            _ = app.launchNewArchive.waitForExistence(timeout: 10)
            app.terminate()
        }
    }

    /// ⌘W in a window that shows its launch browser closes the window. The close counts once no
    /// launch browser is in front and `revealed`, the window behind's content, is hittable; only
    /// then is the window no longer the teardown's to close. The simulator can drop ⌘W (fix1e: the
    /// new window stayed in front, its scene leaked into later tests). ⌘W isn't idempotent: it is
    /// pressed once more only while the new window is verifiably still in front (`stillInFront`).
    /// Fails with the tree if the window isn't closed; the teardown then closes it.
    func closeFrontWindow(_ app: XCUIApplication, revealing revealed: XCUIElement,
                          file: StaticString = #filePath, line: UInt = #line) {
        guard app.frontLaunchNewArchive() != nil else {
            XCTFail("No browser in front to close\n\(app.debugDescription)", file: file, line: line)
            return
        }
        // A tap in the front window gives it the hardware keys. Without a spot the log says why.
        neutralSpot(avoiding: revealed, in: app)?.tap()
        app.typeKey("w", modifierFlags: .command)
        var closed = waitForClose(app, revealing: revealed, timeout: 10)
        if !closed, let frame = stillInFront(app, revealing: revealed), let spot = neutralSpot(avoiding: revealed, in: app) {
            spot.tap()
            if app.frontLaunchNewArchive()?.frame == frame, !revealed.isInFront {
                app.typeKey("w", modifierFlags: .command)
                closed = waitForClose(app, revealing: revealed, timeout: 10)
            }
        }
        guard closed else {
            let what = revealed.exists ? "⌘W didn't close the front window"
                : "The first window's content is gone: a ⌘W reached the first window and closed its archive"
            XCTFail("\(what)\n\(app.debugDescription)", file: file, line: line)
            return
        }
        extraWindowOpen = false
    }

    /// Waits until no launch browser is in front and `revealed` is hittable. Returns early once it is.
    private func waitForClose(_ app: XCUIApplication, revealing revealed: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.frontLaunchNewArchive() == nil, revealed.isInFront { return true }
            if Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        } while Date() < deadline
        return false
    }

    /// The front New Archive button's frame if the window is verifiably still in front: a launch
    /// view's New Archive button hittable on two reads 1 s apart with the same frame, and `revealed` not hittable on either.
    /// A close still under way changes one of these.
    private func stillInFront(_ app: XCUIApplication, revealing revealed: XCUIElement) -> CGRect? {
        guard let first = app.frontLaunchNewArchive()?.frame, !revealed.isInFront else { return nil }
        Thread.sleep(forTimeInterval: 1)
        guard let second = app.frontLaunchNewArchive()?.frame, !revealed.isInFront, second == first else { return nil }
        return second
    }

    /// A spot in the front window 10 pt below its launch view's New Archive button, in the gap
    /// above the Files browser (`LaunchHeaderBand.buttonGap`, 20 pt), where the launch view has no
    /// control. A tap there would open a file if the front window went away just before and the
    /// spot lay in the first window's row: the checks below skip such a spot. Nil, with the reason in the
    /// log, if no button is in front, the spot is in `revealed` or in any cell (the launch view above
    /// the Files browser has none, so a cell there is the window behind's), or the cells can't be read.
    private func neutralSpot(avoiding revealed: XCUIElement, in app: XCUIApplication) -> XCUICoordinate? {
        guard let button = app.frontLaunchNewArchive() else {
            let revealedFrame = revealed.exists ? "\(revealed.frame)" : "gone"
            XCTContext.runActivity(named: "No neutral spot: no New Archive in front; revealed \(revealedFrame)") { _ in }
            return nil
        }
        let frame = button.frame
        let point = CGPoint(x: frame.midX, y: frame.maxY + 10)
        // One snapshot for all cells: per-cell queries cost an IPC call each and fail if the list shrinks mid-read.
        func cellFrame(in snapshot: XCUIElementSnapshot) -> CGRect? {
            if snapshot.elementType == .cell, snapshot.frame.contains(point) { return snapshot.frame }
            return snapshot.children.lazy.compactMap(cellFrame(in:)).first
        }
        func skip(_ hit: String) -> XCUICoordinate? {
            XCTContext.runActivity(named: "No neutral spot: \(point) below New Archive \(frame) \(hit)") { _ in }
            return nil
        }
        let revealedFrame = revealed.exists ? revealed.frame : nil
        if let revealedFrame, revealedFrame.contains(point) { return skip("is in revealed row \(revealedFrame)") }
        let snapshot: XCUIElementSnapshot
        do {
            snapshot = try app.snapshot()
        } catch {
            return skip("is unchecked for cells: snapshot failed: \(error)")
        }
        if let cell = cellFrame(in: snapshot) { return skip("is in cell \(cell)") }
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
    }
}

extension XCUIApplication {
    /// `Window` elements as large as the screen: one per window (scene) in the tree.
    var fullScreenWindowCount: Int {
        windows.allElementsBoundByIndex.filter { $0.frame.size == frame.size }.count
    }
}

extension XCUIElement {
    /// On screen and in front: `exists` and `isHittable`.
    var isInFront: Bool { exists && isHittable }

    /// Waits until the element is gone from the accessibility tree.
    func waitUntilGone(timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Waits until the element is on screen and in front (`exists` and `isHittable`).
    func waitUntilHittable(timeout: TimeInterval) -> Bool {
        let inFront = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"),
                                                object: self)
        return XCTWaiter().wait(for: [inFront], timeout: timeout) == .completed
    }
}
