import XCTest

/// Extract Here: File > Extract Here puts the archive's items next to it. The sandboxed
/// app asks once per folder tree with a stock open panel ("Allow") and remembers the grant across
/// launches. Each test works in its own fresh work folder, which no earlier grant covers (only
/// folders inside the work folders are ever granted here), so the first Extract Here always asks.
///
/// A run touches nothing outside its work folder (`ExtractHereLaunchArguments`, Debug builds):
/// no Finder window (`-KernirSuppressReveal`), grants under a test-only key cleared at each test's
/// first launch and kept across its relaunches (`-KernirFolderAccessGrantsKey`, `-Reset`), and the
/// Trash tests' archives go to a folder of their own (`-KernirTrashDirectory`).
///
/// Written ahead of the feature: it runs once the menu item and the actions are in (the skip in `setUp`
/// comes out then).
final class ExtractHereUITests: KernirMacUITestCase {
    private static let menuItem = "Extract Here"
    private static let allow = "Allow"
    private static let keptLine = "The archive was kept because it has unsaved changes."

    override func setUp() async throws {
        throw XCTSkip("Needs the Extract Here menu item (remove this skip once it exists).")
        try await super.setUp()
        app.launchArguments += [
            "-KernirSuppressReveal", "YES",
            "-KernirFolderAccessGrantsKey", "KernirUITestFolderAccessGrants",
            "-KernirFolderAccessGrantsReset", UUID().uuidString,
        ]
    }

    // MARK: - Asking once

    /// First Extract Here in a folder asks once; Allow extracts project.zip's many items into
    /// "project" next to it. A second one in the same window asks nothing and gives "project 2".
    func testFirstExtractHereAsksOnceThenExtracts() throws {
        let folder = try makeFolder("first")
        let archive = try copy("showcase/project.zip", into: folder)
        open(archive)
        waitForArchive(app.row("README.md"))

        extractHere()
        allowInPanel()
        waitForItem("project/README.md", in: folder)
        XCTAssertTrue(exists("project/src/main.swift", in: folder))

        extractHere()
        expectNoPanel()
        waitForItem("project 2/README.md", in: folder)
        XCTAssertEqual(try visibleNames(in: folder), ["project", "project 2", "project.zip"],
                       "nothing else, no hidden staging, next to the archive")
    }

    /// Owner, 2026-11-10: a Python wheel (a ZIP) is extracted like any ZIP, and ⌥⌘E is File >
    /// Extract Here's visible shortcut. project.zip renamed "tool-1.0-py3-none-any.whl" comes out as
    /// "tool-1.0-py3-none-any" next to it.
    func testOptionCommandEExtractsAWheelHere() throws {
        let folder = try makeFolder("wheel")
        let archive = try copy("showcase/project.zip", into: folder, as: "tool-1.0-py3-none-any.whl")
        open(archive)
        waitForArchive(app.row("README.md"))

        let item = app.openMenu("File", item: Self.menuItem)
        XCTAssertTrue(item.waitForExistence(timeout: 5) && item.isEnabled, "no enabled File > Extract Here for a .whl")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("e", modifierFlags: [.command, .option])
        allowInPanel()
        waitForItem("tool-1.0-py3-none-any/README.md", in: folder)
        XCTAssertEqual(try visibleNames(in: folder), ["tool-1.0-py3-none-any", "tool-1.0-py3-none-any.whl"])
    }

    /// After a relaunch, Extract Here in the granted folder and in a subfolder of it is silent.
    func testGrantSurvivesARelaunchAndCoversSubfolders() throws {
        let folder = try makeFolder("granted")
        let archive = try copy("showcase/project.zip", into: folder)
        open(archive)
        waitForArchive(app.row("README.md"))
        extractHere()
        allowInPanel()
        waitForItem("project/README.md", in: folder)

        // open(_:) quits the running Kernir first: a fresh launch.
        open(archive)
        waitForArchive(app.row("README.md"))
        extractHere()
        expectNoPanel()
        waitForItem("project 2/README.md", in: folder)

        let subfolder = try makeFolder("granted/inner")
        let nested = try copy("zip/macos-finder.zip", into: subfolder)
        open(nested)
        waitForArchive(app.row("Project"))
        extractHere()
        expectNoPanel()
        // One folder plus Finder metadata: the folder comes out as it is, without the metadata.
        waitForItem("Project/hello.txt", in: subfolder)
        XCTAssertEqual(try visibleNames(in: subfolder), ["Project", "macos-finder.zip"])
        XCTAssertFalse(exists("__MACOSX", in: subfolder))
    }

    /// A granted folder moved away and recreated in its place isn't the folder the grant is for:
    /// Extract Here there asks again.
    func testAGrantForAFolderThatMovedAwayAsksAgain() throws {
        let folder = try makeFolder("moving")
        let archive = try copy("single/hello.txt.gz", into: folder)
        open(archive)
        waitForArchive(app.row("hello.txt"))
        extractHere()
        allowInPanel()
        waitForItem("hello.txt", in: folder)
        app.terminate()

        try FileManager.default.moveItem(at: folder, to: workDirectory.appendingPathComponent("moved", isDirectory: true))
        let recreated = try makeFolder("moving")
        let again = try copy("single/hello.txt.gz", into: recreated)
        open(again)
        waitForArchive(app.row("hello.txt"))
        extractHere()
        allowInPanel()
        waitForItem("hello.txt", in: recreated)
    }

    /// Cancel in the panel extracts nothing and leaves nothing behind.
    func testCancelInThePanelExtractsNothing() throws {
        let folder = try makeFolder("cancel")
        let archive = try copy("showcase/project.zip", into: folder)
        open(archive)
        waitForArchive(app.row("README.md"))

        extractHere()
        let panel = waitForPanel()
        panel.buttons["Cancel"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "the panel stayed open\n\(app.debugDescription)")

        // Give a wrongly started extraction time to show up.
        _ = app.text(containing: "Extracting").waitForExistence(timeout: 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["project.zip"])
    }

    // MARK: - Trash

    /// With "Move archive to Trash after Extract Here" on, a complete Extract Here closes the window
    /// and moves the archive to the Trash. Here the Trash step goes to a folder inside the granted
    /// one (`-KernirTrashDirectory`), never the user's Trash; the real step is the same helper
    /// (`ExtractHereEffects.moveToTrash`) without the argument.
    func testTrashOnMovesTheArchiveToTheTrashAndClosesTheWindow() throws {
        let folder = try makeFolder("trash")
        let trash = try makeFolder("trash/Trash")
        app.launchArguments += ["-KernirExtractHereMovesArchiveToTrash", "YES", "-KernirTrashDirectory", trash.path]
        let archive = try copy("showcase/project.zip", into: folder)
        open(archive)
        waitForArchive(app.row("README.md"))

        extractHere()
        allowInPanel()
        waitForItem("project/README.md", in: folder)

        XCTAssertTrue(app.row("README.md").waitForNonExistence(timeout: 10), "the window stayed open")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.exists("project.zip", in: folder) }, "the archive is still there")
        XCTAssertEqual(try visibleNames(in: trash), ["project.zip"], "the archive isn't in the test's Trash folder")
    }

    /// With the Trash on but an unsaved change, the archive is kept and the completion alert says why.
    func testTrashOnWithUnsavedChangesKeepsTheArchiveAndSaysWhy() throws {
        let folder = try makeFolder("unsaved")
        // Should the archive go anyway, it goes here, never to the user's Trash.
        let trash = try makeFolder("unsaved/Trash")
        app.launchArguments += ["-KernirExtractHereMovesArchiveToTrash", "YES", "-KernirTrashDirectory", trash.path]
        let archive = try copy("showcase/project.zip", into: folder)
        open(archive)
        let license = app.row("LICENSE")
        waitForArchive(license)
        license.select()
        app.deleteButton.click()
        XCTAssertTrue(license.waitForNonExistence(timeout: 5))

        extractHere()
        allowInPanel()
        waitForItem("project/README.md", in: folder)

        XCTAssertTrue(app.text(containing: Self.keptLine).waitForExistence(timeout: 10),
                      "no line saying why the archive was kept\n\(app.debugDescription)")
        XCTAssertTrue(exists("project.zip", in: folder))
        XCTAssertEqual(try visibleNames(in: trash), [], "the archive went to the test's Trash folder")
        // What the user saw: the removed item isn't extracted.
        XCTAssertFalse(exists("project/LICENSE", in: folder))
    }

    // MARK: - Helpers

    /// File > Extract Here.
    private func extractHere(file: StaticString = #filePath, line: UInt = #line) {
        let item = app.openMenu("File", item: Self.menuItem)
        XCTAssertTrue(item.waitForExistence(timeout: 5) && item.isEnabled,
                      "no enabled File > Extract Here\n\(app.debugDescription)", file: file, line: line)
        item.click()
    }

    private func waitForPanel(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "no folder access panel\n\(app.debugDescription)",
                      file: file, line: line)
        return panel
    }

    /// Confirms the folder access panel on the folder it opened on, the archive's.
    private func allowInPanel(file: StaticString = #filePath, line: UInt = #line) {
        let panel = waitForPanel(file: file, line: line)
        XCTAssertTrue(panel.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "Lutik needs permission to extract into")).firstMatch.exists,
                      "the panel doesn't say what it is for\n\(panel.debugDescription)", file: file, line: line)
        let allow = panel.buttons[Self.allow]
        XCTAssertTrue(allow.waitForExistence(timeout: 5) && allow.isEnabled,
                      "no enabled Allow button\n\(panel.debugDescription)", file: file, line: line)
        allow.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "the panel stayed open\n\(app.debugDescription)",
                      file: file, line: line)
    }

    private func expectNoPanel(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3),
                       "Extract Here asked again in a granted folder\n\(app.debugDescription)", file: file, line: line)
    }

    /// A new folder `relativePath` in the work folder.
    private func makeFolder(_ relativePath: String) throws -> URL {
        let url = workDirectory.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies `Fixtures/<fixture>` into `folder`.
    private func copy(_ fixture: String, into folder: URL, as name: String? = nil) throws -> URL {
        let source = Self.fixturesDirectory.appendingPathComponent(fixture)
        let copy = folder.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func exists(_ relativePath: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(relativePath).path)
    }

    /// Names in `folder` that Finder shows (no dotfiles: a staging folder would be one).
    private func visibleNames(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private func waitForItem(_ relativePath: String, in folder: URL, timeout: TimeInterval = 20,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil(timeout: timeout) { self.exists(relativePath, in: folder) },
                      "\(relativePath) did not appear next to the archive\n\(app.debugDescription)",
                      file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            XCTAssertNotEqual(app.state, .notRunning, "the app quit")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
