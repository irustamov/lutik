import AppKit
import Carbon
import CryptoKit
import XCTest

/// Base class for the macOS window tests. Every test works on copies of `Fixtures/` in a fresh
/// temporary folder, never on the fixtures themselves.
///
/// Archives open through LaunchServices (`XCUIApplication.open(_:)`), like a double-click in
/// Finder, so the sandboxed app gets access to the file without any test hook in the app.
/// Always through `open(_:)`, which keeps one Lutik per test.
@MainActor
class KernirMacUITestCase: XCTestCase {
    var app: XCUIApplication!
    /// Holds this test's fixture copies; removed in tear down.
    var workDirectory: URL!

    override func setUp() async throws {
        // CI only: these tests take over the keyboard and mouse. Never run them on a desktop
        // someone is using.
        guard ProcessInfo.processInfo.environment["KERNIR_MAC_UI_TESTS"] == "1" else {
            throw XCTSkip("macOS UI tests run in CI only (set TEST_RUNNER_KERNIR_MAC_UI_TESTS=1).")
        }
        // XCUITest turns typed characters into key codes through the current keyboard layout.
        // Under a Russian layout ⌘S and ⌘Z are never sent ("Error 61: The key "s" does not exist
        // in the current keyboard layout") and ⌘, arrives as ⇧⌘6, while clicks still work: 13
        // keyboard tests failed that way in local runs.
        if let layout = Self.currentKeyboardLayoutID, !Self.supportedKeyboardLayoutIDs.contains(layout) {
            throw UnsupportedKeyboardLayout(id: layout)
        }
        continueAfterFailure = false
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernirMacUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
        // No windows restored from an earlier run: each test sees only the archive it opens.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // No Welcome window: it would cover the archive windows these tests use (WelcomeUITests opts out).
        if Self.suppressesWelcome { app.launchArguments += Self.welcomeSuppressionArguments }
    }

    /// Launch arguments that keep the Welcome window closed (argument-domain defaults).
    static let welcomeSuppressionArguments = ["-KernirWelcomeSeen", "YES", "-KernirWelcomeShowAtLaunch", "NO"]

    /// Whether `setUp` adds `welcomeSuppressionArguments`.
    class var suppressesWelcome: Bool { true }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
        // A Lutik of this build still running is one this test launched that `app` no longer
        // tracks. Quit it by PID, so no stray Lutik stays on the machine or gets picked up by
        // the next test (CI run 42721544029: the full-disk test clicked the Russian test's
        // leftover window). runningApplications updates asynchronously and can still list the
        // app terminate() just quit, so each PID is checked at the process level too.
        rememberOwnInstances()
        let strays = Self.ownInstances().filter {
            launchedPIDs.contains($0.processIdentifier) && Self.isAlive($0.processIdentifier)
        }
        for stray in strays where !stray.forceTerminate() {
            kill(stray.processIdentifier, SIGKILL)
        }
        if !strays.isEmpty {
            XCTFail("The test left \(strays.count) more Lutik running (PIDs \(strays.map(\.processIdentifier))); "
                    + "open archives with open(_:), which quits the running app first.")
        }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    // MARK: - Launching

    /// Every PID of this build's Lutik seen while the test ran.
    private var launchedPIDs: Set<pid_t> = []

    /// Opens `url` in a fresh Lutik. `XCUIApplication.open(_:)` on a running app launches a
    /// second instance and leaves the first one untracked, so the running one is quit first.
    func open(_ url: URL) {
        if app.state != .notRunning { app.terminate() }
        app.open(url)
        rememberOwnInstances()
    }

    func rememberOwnInstances() {
        launchedPIDs.formUnion(Self.ownInstances().map(\.processIdentifier))
    }

    /// Whether `pid` still exists (EPERM: it exists, but the sandboxed runner may not signal it).
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Running Lutik apps from this build's products folder (next to the test runner), never
    /// another copy of Lutik on the machine.
    static func ownInstances() -> [NSRunningApplication] {
        let products = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        return NSWorkspace.shared.runningApplications.filter {
            guard let bundle = $0.bundleURL?.standardizedFileURL else { return false }
            return bundle.deletingLastPathComponent() == products
                && bundle != Bundle.main.bundleURL.standardizedFileURL
                && bundle.pathExtension == "app"
                && !bundle.lastPathComponent.hasSuffix("-Runner.app")
        }
    }

    // MARK: - Keyboard layout

    static let supportedKeyboardLayoutIDs: Set<String> = ["com.apple.keylayout.US", "com.apple.keylayout.ABC"]

    /// The current keyboard layout's input source ID, e.g. "com.apple.keylayout.Russian";
    /// nil if Text Input Sources doesn't answer (then the tests run as before).
    static var currentKeyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }

    struct UnsupportedKeyboardLayout: LocalizedError {
        let id: String
        var errorDescription: String? {
            "The keyboard input source is \(id); switch it to U.S. or ABC before running the macOS "
                + "UI tests, or keyboard shortcuts and typing never reach Lutik."
        }
    }

    // MARK: - Fixtures

    static let fixturesDirectory = URL(fileURLWithPath: "\(#filePath)")
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// Copies `Fixtures/<fixture>` into the work folder and returns the copy.
    func copyFixture(_ fixture: String) throws -> URL {
        let source = Self.fixturesDirectory.appendingPathComponent(fixture)
        let copy = workDirectory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// Copies `Fixtures/<fixture>` and opens the copy in Lutik.
    @discardableResult
    func openFixture(_ fixture: String) throws -> URL {
        let copy = try copyFixture(fixture)
        open(copy)
        return copy
    }

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Waiting

    /// The stub engine's error text. KernirCore's real reader is on main, so it must never
    /// appear where a real result is expected.
    static let stubText = "This feature isn't available yet."

    /// Waits for `element`. Fails at once if the app shows the stub engine's alert.
    func waitForArchive(_ element: XCUIElement, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) {
        let stub = app.text(containing: Self.stubText)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return }
            if stub.exists {
                XCTFail("The app shows the stub engine's alert (\"\(Self.stubText)\"); "
                        + "KernirCore's real reader should open this archive.", file: file, line: line)
                return
            }
            _ = element.waitForExistence(timeout: 0.5)
        }
        XCTFail("\(element) did not appear.\n\(app.debugDescription)", file: file, line: line)
    }

    // MARK: - Split archives

    /// On a split archive's locked window, clicks Grant Access…, then confirms the folder panel. The
    /// panel opens on the folder that holds the parts, which is the only folder the app accepts.
    func grantAccess(file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["Grant Access…"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Grant Access… button\n\(app.debugDescription)",
                      file: file, line: line)
        button.click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "no folder panel\n\(app.debugDescription)",
                      file: file, line: line)
        let confirm = panel.buttons["Grant Access"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isEnabled,
                      "no enabled Grant Access button in the panel\n\(panel.debugDescription)", file: file, line: line)
        confirm.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "the folder panel stayed open\n\(app.debugDescription)",
                      file: file, line: line)
    }
}

extension XCUIApplication {
    /// The archive window's outline (SwiftUI `Table` with disclosure rows).
    var archiveOutline: XCUIElement { outlines.firstMatch }

    /// The visible row whose Name cell reads `name`. Rows carry no identifier, so this matches
    /// the name text; names are unique in the fixtures these tests use.
    func row(_ name: String) -> XCUIElement {
        archiveOutline.outlineRows.containing(
            NSPredicate(format: "elementType == %lu AND value == %@",
                        XCUIElement.ElementType.staticText.rawValue, name)
        ).firstMatch
    }

    /// The Name text of every visible row, top to bottom.
    var visibleRowNames: [String] {
        archiveOutline.outlineRows.allElementsBoundByIndex.compactMap { row in
            row.cells.firstMatch.staticTexts.firstMatch.value as? String
        }
    }

    /// Any static text (window, sheet or alert) whose value or label contains `text`.
    func text(containing text: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
    }

    /// The toolbar's ＋ and － and Extract buttons.
    var addButton: XCUIElement { toolbars.buttons["Add"].firstMatch }
    var deleteButton: XCUIElement { toolbars.buttons["Delete"].firstMatch }
    var searchField: XCUIElement { toolbars.searchFields.firstMatch }

    /// The window's footer: "9 items · 90 KB · 71 KB compressed · ZIP".
    var footer: XCUIElement { text(containing: " items · ") }

    /// A menu bar item, e.g. `menuItem("Edit", "Delete")`.
    func menuItem(_ menu: String, _ item: String) -> XCUIElement {
        menuBars.menuBarItems[menu].menus.menuItems[item]
    }

    /// Opens `menu` in the menu bar, so its items validate, and returns `item` in it.
    func openMenu(_ menu: String, item: String) -> XCUIElement {
        menuBars.menuBarItems[menu].click()
        return menuItem(menu, item)
    }
}

extension XCUIElement {
    /// Expands a folder row with its disclosure triangle.
    func expand() {
        let triangle = disclosureTriangles.firstMatch
        if (triangle.value as? Int) != 1 { triangle.click() }
    }

    /// Selects a row with a click on its Name text. XCUITest on macOS 26 calls SwiftUI Table rows
    /// "not hittable" even when they are fully on screen (CI run 42703735301), so this clicks a
    /// coordinate, which skips the hittability check.
    func select() {
        let name = cells.firstMatch.staticTexts.firstMatch
        (name.exists ? name : self).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
