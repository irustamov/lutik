import XCTest

/// Search across folders, the empty states, and formats other than ZIP and 7z.
@MainActor
final class QABrowseUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Search

    /// Search filters the whole tree: from the root, "data" keeps only the folders that lead to
    /// docs/nested/deep/data.bin, and following them reaches the file.
    func testSearchFindsFileInNestedFolderFromRoot() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"))

        search(app, for: "data")
        XCTAssertTrue(app.row("hello.txt").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.row("docs").exists, "docs leads to the match, so it stays")
        XCTAssertFalse(app.row("empty-dir").exists)
        XCTAssertFalse(app.row("empty.txt").exists)

        app.row("docs").tap()
        XCTAssertTrue(app.row("docs/nested").waitForExistence(timeout: 5))
        XCTAssertFalse(app.row("docs/notes.txt").exists)
        XCTAssertFalse(app.row("docs/readme.md").exists)

        app.row("docs/nested").tap()
        XCTAssertTrue(app.row("docs/nested/deep").waitForExistence(timeout: 5))
        app.row("docs/nested/deep").tap()
        XCTAssertTrue(app.row("docs/nested/deep/data.bin").waitForExistence(timeout: 5))
    }

    /// A query that matches nothing shows the search empty state and no rows.
    func testSearchWithoutMatchesShowsNoResults() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/deflate.zip")
        app.waitForArchive(app.row("hello.txt"))

        search(app, for: "qqzzxx")
        let noResults = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No Results")).firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 5))
        for path in ["docs", "empty-dir", "empty.txt", "hello.txt"] {
            XCTAssertFalse(app.row(path).exists, "\(path) should be filtered out")
        }
    }

    // MARK: - Empty archive

    /// zip/empty.zip (no entries) opens to the "No Items" state, not an error, and stays open.
    func testEmptyArchiveShowsEmptyState() {
        let app = XCUIApplication()
        app.launchOpening(fixture: "zip/empty.zip")
        let empty = app.staticTexts["No Items"]
        app.waitForArchive(empty)
        // The archive is open (search only shows on a listed archive), not back at the browser.
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: - Other formats

    func testTarGzListsRootEntries() throws {
        try assertListsRootEntries(of: "tar/basic.tar.gz")
    }

    func testTarXzListsRootEntries() throws {
        try assertListsRootEntries(of: "tar/basic.tar.xz")
    }

    func testRar4ListsRootEntries() throws {
        try assertListsRootEntries(of: "third-party/rar/rar4-basic.rar")
    }

    func testRar5ListsRootEntries() throws {
        try assertListsRootEntries(of: "third-party/rar/rar5-symlink.rar")
    }

    func testIsoListsRootEntries() throws {
        try assertListsRootEntries(of: "iso/basic.iso")
    }

    // MARK: - Helpers

    private func search(_ app: XCUIApplication, for text: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field", file: file, line: line)
        field.tap()
        field.typeText(text)
    }

    /// Opens `fixture` and checks that the root level lists exactly the manifest's root entries.
    private func assertListsRootEntries(of fixture: String,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let roots = try QAFixtures.rootEntries(of: fixture, file: file, line: line)
        let app = XCUIApplication()
        app.launchOpening(fixture: fixture)
        app.waitForArchive(app.row(roots[0]), file: file, line: line)
        XCTAssertFalse(app.openFailedAlert.exists, file: file, line: line)
        XCTAssertFalse(app.passwordField.exists, file: file, line: line)
        for path in roots {
            XCTAssertTrue(app.row(path).waitForExistence(timeout: 5), "\(fixture): \(path)", file: file, line: line)
        }
        // Nothing beyond the root level shows at the root.
        let identified = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "/"))
        let nested = identified.allElementsBoundByIndex.map(\.identifier).filter { id in
            !id.hasPrefix("/") && roots.contains { id.hasPrefix($0 + "/") }
        }
        XCTAssertEqual(nested, [], "\(fixture): nested entries at the root", file: file, line: line)
    }
}
