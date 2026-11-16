import XCTest

/// Extract into a folder that already holds items of the same names (X1: never overwrite
/// without asking). EditUITests.testExtractTwiceAsksBeforeReplacing
/// covers a single Stop and Keep Both by names through the Files picker; these check what lands
/// on disk: Replace for All / Keep Both for All over several conflicts, Replace swapping a whole
/// folder, Replace really writing the archive's bytes, mixed answers, and Stop writing nothing.
///
/// The destination comes from the DEBUG-only `-KernirExtractDestination <absolute path>` hook
/// (used as given, like `-KernirOpenFixture`), so the runner seeds the folder and reads it back.
/// The runner and the app both run in the simulator, which shares the Mac's file system.
///
/// zip/deflate.zip has 4 top-level items: docs/ (nested/deep/data.bin 70 000 bytes, notes.txt
/// 20 000, readme.md 52), empty-dir/, empty.txt (0 bytes) and hello.txt ("Hello, Kernir!\n", 15 bytes).
@MainActor
final class ExtractConflictUITests: XCTestCase {
    private let fixture = "zip/deflate.zip"
    private let hello = "Hello, Kernir!\n"
    private let mine = "mine\n"
    private let ask = "Do you want to replace it with the one you’re extracting?"
    private var folder: ExtractFolder!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = try ExtractFolder()
    }

    override func tearDown() {
        folder?.remove()
    }

    // MARK: - Tests

    /// Four conflicts, Replace for All on the first question: every item is the archive's, mine
    /// are gone (docs/mine.txt too: Replace swaps the folder), and nothing else is asked.
    func testReplaceForAllReplacesEveryConflict() throws {
        try seedAllFour()
        let app = launchAndExtract()

        let alert = waitForQuestion(app, about: try XCTUnwrap(firstName(app)), k: 1, of: 4)
        assertButtons(alert, forAll: true)
        alert.buttons["Replace for All"].firstMatch.tap()
        assertNoMoreQuestions(app)

        waitForFolder(["docs", "empty-dir", "empty.txt", "hello.txt"])
        XCTAssertEqual(folder.text("hello.txt"), hello)
        XCTAssertEqual(folder.size("empty.txt"), 0)
        assertArchiveDocs(at: "docs", "Replace kept the old docs' contents")
        XCTAssertTrue(folder.isDirectory("empty-dir"))
        XCTAssertEqual(folder.listing("empty-dir"), [], "Replace kept the old empty-dir's contents")
    }

    /// Four conflicts, Keep Both for All on the first question: mine stay as they were, and the
    /// archive's items come in next to them as "<name> 2".
    func testKeepBothForAllKeepsMineAndAddsCopies() throws {
        try seedAllFour()
        let app = launchAndExtract()

        let alert = waitForQuestion(app, about: try XCTUnwrap(firstName(app)), k: 1, of: 4)
        alert.buttons["Keep Both for All"].firstMatch.tap()
        assertNoMoreQuestions(app)

        waitForFolder(["docs", "empty-dir", "empty.txt", "hello.txt",
                       "docs 2", "empty-dir 2", "empty 2.txt", "hello 2.txt"])
        assertMineUntouched(all: true)
        XCTAssertEqual(folder.text("hello 2.txt"), hello)
        XCTAssertEqual(folder.size("empty 2.txt"), 0)
        assertArchiveDocs(at: "docs 2")
        XCTAssertTrue(folder.isDirectory("empty-dir 2"))
        XCTAssertEqual(folder.listing("empty-dir 2"), [])
    }

    /// A folder conflict alone: one question with no "k of n" and no "for All". Replace swaps the
    /// whole folder (my docs/mine.txt is gone, not merged), and the other items come in as usual.
    func testReplaceSwapsAConflictingFolder() throws {
        try folder.write(mine, to: "docs/mine.txt")
        let app = launchAndExtract()

        let alert = waitForQuestion(app, about: "docs", k: nil, of: nil)
        assertButtons(alert, forAll: false)
        alert.buttons["Replace"].firstMatch.tap()
        assertNoMoreQuestions(app)

        waitForFolder(["docs", "empty-dir", "empty.txt", "hello.txt"])
        assertArchiveDocs(at: "docs", "Replace merged into my docs instead of swapping it")
        XCTAssertEqual(folder.text("hello.txt"), hello)
    }

    /// One file conflict: Stop leaves the folder exactly as it was (no other item, no
    /// "hello 2.txt", no staging); a second Extract asks again, and Replace writes the archive's
    /// bytes over mine.
    func testStopWritesNothingThenReplaceWritesTheArchiveBytes() throws {
        try folder.write(mine, to: "hello.txt")
        let app = launchAndExtract()

        var alert = waitForQuestion(app, about: "hello.txt", k: nil, of: nil)
        assertButtons(alert, forAll: false)
        alert.buttons["Stop"].firstMatch.tap()
        assertNoMoreQuestions(app)
        // Nothing may appear later either.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(folder.listing(), ["hello.txt"], "Stop wrote something")
        XCTAssertEqual(folder.text("hello.txt"), mine, "Stop changed my file")

        app.extractTo()
        alert = waitForQuestion(app, about: "hello.txt", k: nil, of: nil)
        alert.buttons["Replace"].firstMatch.tap()
        assertNoMoreQuestions(app)

        waitForFolder(["docs", "empty-dir", "empty.txt", "hello.txt"])
        XCTAssertEqual(folder.data("hello.txt"), Data(hello.utf8), "Replace did not write the archive's bytes")
    }

    /// Two conflicts answered one by one, whatever order they are asked in: Replace for
    /// hello.txt, Keep Both for docs. The second question has no "for All" (only one is left).
    func testMixedAnswersApplyToTheirOwnItem() throws {
        try folder.write(mine, to: "hello.txt")
        try folder.write(mine, to: "docs/mine.txt")
        let app = launchAndExtract()

        var asked: [String] = []
        for k in 1...2 {
            // The new question's line first, so the name is read from its alert, not the last one.
            XCTAssertTrue(alertText(app, k: k, of: 2).waitForExistence(timeout: 10),
                          "no question \(k) of 2\n\(app.debugDescription)")
            let name = try XCTUnwrap(firstName(app))
            let alert = waitForQuestion(app, about: name, k: k, of: 2)
            assertButtons(alert, forAll: k == 1)
            asked.append(name)
            switch name {
            case "hello.txt": alert.buttons["Replace"].firstMatch.tap()
            case "docs": alert.buttons["Keep Both"].firstMatch.tap()
            default: XCTFail("asked about \(name), which is not in the folder")
            }
            XCTAssertTrue(alertText(app, k: k, of: 2).waitForNonExistence(timeout: 5),
                          "question \(k) stayed up\n\(app.debugDescription)")
        }
        XCTAssertEqual(Set(asked), ["hello.txt", "docs"])
        assertNoMoreQuestions(app)

        waitForFolder(["docs", "docs 2", "empty-dir", "empty.txt", "hello.txt"])
        XCTAssertEqual(folder.text("hello.txt"), hello)
        XCTAssertEqual(folder.listing("docs"), ["mine.txt"], "Keep Both changed my docs")
        XCTAssertEqual(folder.text("docs/mine.txt"), mine)
        assertArchiveDocs(at: "docs 2")
    }

    // MARK: - Seeding and checks

    /// One of mine for each of the archive's 4 top-level items, each different from the
    /// archive's: text files say "mine", the folders hold a mine.txt.
    private func seedAllFour() throws {
        try folder.write(mine, to: "hello.txt")
        try folder.write(mine, to: "empty.txt")
        try folder.write(mine, to: "docs/mine.txt")
        try folder.write(mine, to: "empty-dir/mine.txt")
    }

    private func assertMineUntouched(all: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(folder.text("hello.txt"), mine, file: file, line: line)
        XCTAssertEqual(folder.listing("docs"), ["mine.txt"], file: file, line: line)
        if all {
            XCTAssertEqual(folder.text("empty.txt"), mine, file: file, line: line)
            XCTAssertEqual(folder.listing("empty-dir"), ["mine.txt"], file: file, line: line)
        }
    }

    /// `path` holds exactly the archive's docs/: nested/deep/data.bin, notes.txt and readme.md,
    /// none of mine.
    private func assertArchiveDocs(at path: String, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(folder.listing(path), ["nested", "notes.txt", "readme.md"], message, file: file, line: line)
        XCTAssertEqual(folder.size("\(path)/nested/deep/data.bin"), 70_000, file: file, line: line)
        XCTAssertEqual(folder.size("\(path)/notes.txt"), 20_000, file: file, line: line)
        XCTAssertEqual(folder.size("\(path)/readme.md"), 52, file: file, line: line)
    }

    /// Waits until the folder lists exactly `names` with no `.kernir-*` staging left, which is
    /// when the extraction has finished.
    private func waitForFolder(_ names: Set<String>, timeout: TimeInterval = 20,
                               file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, folder.listing() != names {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertEqual(folder.listing(), names, "the folder after extracting", file: file, line: line)
    }

    // MARK: - The app

    /// Launches on deflate.zip with the destination hook pointed at `folder` and taps Extract To…
    /// with nothing selected (everything).
    private func launchAndExtract(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-KernirExtractDestination", folder.url.path]
        app.launchOpening(fixture: fixture)
        app.waitForArchive(app.row("hello.txt"), file: file, line: line)
        app.extractTo(file: file, line: line)
        return app
    }

    /// The alert asking about `name`. With several conflicts, waits for its "k of n" line: each
    /// question is a new alert, and the old one may still be on screen for a moment.
    @discardableResult
    private func waitForQuestion(_ app: XCUIApplication, about name: String, k: Int?, of n: Int?,
                                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if let k, let n {
            XCTAssertTrue(alertText(app, k: k, of: n).waitForExistence(timeout: 10),
                          "no question \(k) of \(n)\n\(app.debugDescription)", file: file, line: line)
        }
        let title = "An item named “\(name)” already exists in “\(folder.name)”."
        let alert = app.alerts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no alert “\(title)”\n\(app.debugDescription)",
                      file: file, line: line)
        if k == nil {
            XCTAssertTrue(app.alertText(ask, in: alert).exists,
                          "a single conflict shows the question alone\n\(alert.debugDescription)", file: file, line: line)
        }
        return alert
    }

    /// The question with its "k of n" line. XCUITest reports the message's line break as a space,
    /// so match the two ends rather than the whole label.
    private func alertText(_ app: XCUIApplication, k: Int, of n: Int) -> XCUIElement {
        app.alerts.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@",
                                                    ask, " \(k) of \(n)")).firstMatch
    }

    /// The name the alert on screen asks about, from its title.
    private func firstName(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no conflict alert\n\(app.debugDescription)",
                      file: file, line: line)
        let label = alert.label
        guard let open = label.range(of: "An item named “"),
              let close = label.range(of: "” already exists", range: open.upperBound..<label.endIndex)
        else { return nil }
        return String(label[open.upperBound..<close.lowerBound])
    }

    /// Keep Both, Replace and Stop always; the "for All" pair only while 2+ are unanswered.
    private func assertButtons(_ alert: XCUIElement, forAll: Bool,
                               file: StaticString = #filePath, line: UInt = #line) {
        for name in ["Keep Both", "Replace", "Stop"] {
            XCTAssertTrue(alert.buttons[name].firstMatch.exists, "\(name)\n\(alert.debugDescription)", file: file, line: line)
        }
        for name in ["Keep Both for All", "Replace for All"] {
            XCTAssertEqual(alert.buttons[name].firstMatch.exists, forAll, "\(name)\n\(alert.debugDescription)",
                           file: file, line: line)
        }
    }

    private func assertNoMoreQuestions(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let conflict = app.alerts.matching(NSPredicate(format: "label BEGINSWITH %@", "An item named")).firstMatch
        XCTAssertTrue(conflict.waitForNonExistence(timeout: 5), "the conflict alert stayed up", file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3),
                       "an alert after the last answer\n\(app.debugDescription)", file: file, line: line)
    }
}

/// A destination folder on the Mac's disk (the runner's temporary directory), seeded and read
/// back by the runner.
struct ExtractFolder {
    let url: URL
    var name: String { url.lastPathComponent }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractConflict", isDirectory: true)
            .appendingPathComponent("X7-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes `text` to `path`, making the folders on the way.
    func write(_ text: String, to path: String) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
    }

    /// The names in `path` ("" for the folder itself), hidden ones included, so leftover
    /// `.kernir-*` staging shows up.
    func listing(_ path: String = "") -> Set<String> {
        let names = try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent(path).path)
        return Set(names ?? [])
    }

    func data(_ path: String) -> Data? {
        try? Data(contentsOf: url.appendingPathComponent(path))
    }

    func text(_ path: String) -> String? {
        data(path).flatMap { String(data: $0, encoding: .utf8) }
    }

    func size(_ path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path,
                                              isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
