import XCTest

/// Extract Here on iPhone and iPad (issue 01, "iOS / iPadOS (reduced)"): the toolbar's Extract
/// menu and the row's context menu put the archive's items next to it. The first time in a folder
/// the Files picker asks for that folder (opening on it); the grant is kept across launches, so
/// later ones are silent. Extract To… still asks for a destination every time.
///
/// Grants go under a test-only key, cleared at each test's first launch and kept across its
/// relaunches (`-KernirFolderAccessGrantsKey`, `-KernirFolderAccessGrantsReset`). The fixture hook
/// copies a uniquely named copy into the app's Documents, where no grant is needed (the
/// own-container skip), so the picker and grant tests turn the skip off with its DEBUG argument.
/// The DEBUG hooks stand in for what a simulator can't give: `-KernirExtractHereGrant <path>` for
/// the first pick of the archive's folder in a launch ("Documents" is the app's Documents), and
/// `-KernirExtractHereReadOnly YES` for a read-only volume, once per launch. The results are read
/// in the app's Documents, found next to this runner's container (simulator only).
/// Each test's doc comment says what it asserts and the mutants it must kill.
@MainActor
final class ExtractHereUITests: XCTestCase {
    /// Made by `open`, each test's first step.
    private var app: XCUIApplication!
    /// The grants' reset token: one per test, kept across its relaunches.
    private var resetToken = ""
    /// What deflate.zip holds at its top level (Extract Here wraps them in a folder named after it).
    private static let items: Set = ["docs", "empty-dir", "empty.txt", "hello.txt"]

    override func setUp() {
        continueAfterFailure = false
    }

    private var grantArguments: [String] {
        ["-KernirFolderAccessGrantsKey", "KernirUITestFolderAccessGrants", "-KernirFolderAccessGrantsReset", resetToken]
    }

    // MARK: - Entry points

    /// Toolbar Extract menu > Extract Here, the app's Documents granted through the hook (the skip
    /// off): the archive's items appear in a folder named after it next to it, with no picker and no
    /// alert, and the archive stays open.
    /// Mutants: the menu item running Extract To…; Extract Here missing from the menu.
    func testExtractHereFromToolbarMenu() throws {
        let archive = try open("xh-menu", arguments: ["-KernirDisableOwnContainerSkip", "YES",
                                                      "-KernirExtractHereGrant", "Documents"])
        let documents = try appDocuments(holding: archive)
        extractHereFromMenu()
        let folder = documents.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
        waitForNames(Self.items, in: folder)
        XCTAssertFalse(app.filesPicker.exists, "a picker came up\n\(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert came up\n\(app.debugDescription)")
        XCTAssertTrue(app.row("hello.txt").exists, "the archive closed")
    }

    /// Row context menu > Extract Here on the "docs" row: only that folder lands next to the
    /// archive. The menu lists Extract Here, Extract To… and Share.
    /// Mutants: extracting everything from a row; no Extract Here in the row menu.
    func testExtractHereFromContextMenu() throws {
        let archive = try open("xh-row")
        let documents = try appDocuments(holding: archive)
        let before = try names(in: documents)
        let extractHere = app.contextMenuButton("Extract Here", on: app.row("docs"))
        XCTAssertTrue(app.collectionViews.buttons["Extract To…"].exists, "no Extract To… in the row menu")
        XCTAssertTrue(app.collectionViews.buttons["Share"].exists, "no Share in the row menu")
        extractHere.tap()
        let added = waitForNewNames(in: documents, besides: before)
        XCTAssertEqual(added.count, 1, "more than the row's folder: \(added)")
        let name = try XCTUnwrap(added.first)
        XCTAssertTrue(name == "docs" || name.hasPrefix("docs "), "not the row's folder: \(name)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert came up\n\(app.debugDescription)")
    }

    // MARK: - Asking for the folder

    /// No grant (the skip off, no hook): Extract Here brings up the Files picker in folder mode
    /// (`pickerOffersNewFolder`); Cancel writes nothing and shows no alert, and Extract Here asks
    /// again next time.
    /// Mutants: extracting without a grant; a file picker instead of a folder picker; the request
    /// left behind by Cancel (Extract Here off).
    func testFirstExtractHereShowsFolderPicker() throws {
        let archive = try open("xh-first", arguments: ["-KernirDisableOwnContainerSkip", "YES"])
        let documents = try appDocuments(holding: archive)
        let before = try names(in: documents)
        extractHereFromMenu()
        XCTAssertTrue(app.pickerOffersNewFolder(), "Extract Here's picker picks a folder\n\(app.debugDescription)")
        app.cancelPicker()
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert after Cancel\n\(app.debugDescription)")
        XCTAssertEqual(try names(in: documents), before)

        extractHereFromMenu()
        XCTAssertTrue(app.filesPicker.waitForExistence(timeout: 10), "no picker the second time")
        app.cancelPicker()
        XCTAssertEqual(try names(in: documents), before)
    }

    /// The pick (the hook's folder) doesn't hold the archive, so the alert "That
    /// folder doesn't contain …" comes; OK brings the Files picker back once the alert has gone.
    /// Cancel there leaves Extract Here on: it asks again.
    /// Mutants: OK asking for the picker while the alert is still going (no picker, and Extract
    /// Here off until the archive is reopened); OK ending the request; granting the wrong folder.
    func testOKOnTheWrongFolderAlertBringsThePickerBack() throws {
        let elsewhere = try makeRunnerFolder("xh-elsewhere")
        let archive = try open("xh-ok", arguments: ["-KernirDisableOwnContainerSkip", "YES",
                                                    "-KernirExtractHereGrant", elsewhere.path])
        let documents = try appDocuments(holding: archive)
        let before = try names(in: documents)
        extractHereFromMenu()
        let alert = app.alerts.matching(NSPredicate(format: "label BEGINSWITH %@", "That folder doesn't contain")).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no wrong-folder alert\n\(app.debugDescription)")
        alert.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(app.pickerOffersNewFolder(), "OK didn't bring the folder picker back\n\(app.debugDescription)")
        app.cancelPicker()
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert after Cancel\n\(app.debugDescription)")

        extractHereFromMenu()
        XCTAssertTrue(app.filesPicker.waitForExistence(timeout: 10), "Extract Here didn't ask again")
        app.cancelPicker()
        XCTAssertEqual(try names(in: documents), before)
        XCTAssertEqual(try names(in: elsewhere), [])
    }

    /// Extract Here into the archive's folder fails as on a read-only volume (hook),
    /// so the alert "“Documents” is on a read-only volume." comes; Choose Another Folder… brings the
    /// Files picker (any folder) once the alert has gone. After Cancel there, Extract Here is on
    /// again and, the hook used up, extracts next to the archive.
    /// Mutants: Choose Another Folder… asking for the picker while the alert is still going;
    /// the generic failure alert; the request left behind by the picker's Cancel.
    func testChooseAnotherFolderOnTheReadOnlyAlertBringsThePicker() throws {
        let archive = try open("xh-readonly", arguments: ["-KernirExtractHereReadOnly", "YES"])
        let documents = try appDocuments(holding: archive)
        extractHereFromMenu()
        let alert = app.alerts.matching(NSPredicate(format: "label ENDSWITH %@", "is on a read-only volume.")).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no read-only alert\n\(app.debugDescription)")
        alert.buttons["Choose Another Folder…"].firstMatch.tap()
        XCTAssertTrue(app.pickerOffersNewFolder(),
                      "Choose Another Folder… didn't bring the folder picker\n\(app.debugDescription)")
        app.cancelPicker()
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert after Cancel\n\(app.debugDescription)")

        extractHereFromMenu()
        waitForNames(Self.items, in: documents.appendingPathComponent(archive.deletingPathExtension().lastPathComponent))
    }

    /// Granted on the first launch (hook, the skip off), relaunched with the same reset token:
    /// Extract Here in the same folder is silent and writes "<name> 2".
    ///
    /// The relaunch passes `-KernirExtractHereGrant Documents` again, and it must: the hook's grant is
    /// a bookmark of a plain path, whose security scope the system won't start, and only the hook's
    /// lenient scope (`ExtractHereEffects.scope(for:onIOS:system:)`, the hook's folder and what's
    /// inside it) opens it. Without the argument the saved grant is passed over and the picker
    /// comes up. So this test can't catch a "grant saved, but its scope won't start" regression
    /// (that needs a real Files pick on a device), and since the hook would also stand in for the
    /// picker, it can't tell a kept grant from a lost one re-picked by the hook: those mutants
    /// (grants not saved to the defaults, the reset token clearing them on every launch) are the
    /// unit tests' (FolderAccessStoreTests, ExtractHereEffectsTests'
    /// `uiTestGrantsLiveUnderTheirOwnKeyAndResetOncePerToken`). What this one asserts is that a
    /// relaunch with a hook grant extracts silently next to the archive.
    /// Mutant: a relaunch that loses the archive's Extract Here (picker or alert).
    func testExtractHereIsSilentAfterGrantAcrossRelaunch() throws {
        let archive = try open("xh-relaunch", arguments: ["-KernirDisableOwnContainerSkip", "YES",
                                                          "-KernirExtractHereGrant", "Documents"])
        let documents = try appDocuments(holding: archive)
        let name = archive.deletingPathExtension().lastPathComponent
        extractHereFromMenu()
        waitForNames(Self.items, in: documents.appendingPathComponent(name))

        app.terminate()
        app.launchArguments = grantArguments + ["-KernirDisableOwnContainerSkip", "YES",
                                                "-KernirExtractHereGrant", "Documents"]
        app.launchOpening(fileAt: archive)
        app.waitForArchive(app.row("hello.txt"))
        extractHereFromMenu()
        waitForNames(Self.items, in: documents.appendingPathComponent("\(name) 2"))
        XCTAssertFalse(app.alerts.firstMatch.exists, "the grant didn't survive\n\(app.debugDescription)")
        XCTAssertFalse(app.filesPicker.exists, "a picker came up\n\(app.debugDescription)")
    }

    /// With a grant for the archive's folder (hook), Extract To… still brings up the Files picker.
    /// Mutant: Extract To… taking the Extract Here path.
    func testExtractToStillAsksForFolder() throws {
        let archive = try open("xh-to", arguments: ["-KernirDisableOwnContainerSkip", "YES",
                                                    "-KernirExtractHereGrant", "Documents"])
        let documents = try appDocuments(holding: archive)
        extractHereFromMenu()
        waitForNames(Self.items, in: documents.appendingPathComponent(archive.deletingPathExtension().lastPathComponent))
        app.extractTo()
        XCTAssertTrue(app.pickerOffersNewFolder(), "Extract To… didn't ask\n\(app.debugDescription)")
        app.cancelPicker()
    }

    /// The fixture in the app's Documents (skip on, no grant, no hook): Extract Here is silent and
    /// writes next to the archive.
    /// Mutant: the app factory not turning the own-container skip on.
    func testExtractHereInOwnDocumentsIsSilent() throws {
        let archive = try open("xh-own")
        let documents = try appDocuments(holding: archive)
        extractHereFromMenu()
        waitForNames(Self.items, in: documents.appendingPathComponent(archive.deletingPathExtension().lastPathComponent))
        XCTAssertFalse(app.filesPicker.exists, "a picker came up\n\(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert came up\n\(app.debugDescription)")
    }

    // MARK: - Helpers

    /// Launches with a new reset token and `arguments` on a fresh, uniquely named copy of deflate.zip
    /// (prefix `prefix`), which the fixture hook copies into the app's Documents and opens. Returns
    /// the runner's copy.
    private func open(_ prefix: String, arguments: [String] = []) throws -> URL {
        let copy = try QAFixtures.freshCopy(of: "zip/deflate.zip", prefix: prefix)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        resetToken = UUID().uuidString
        app = XCUIApplication()
        app.launchArguments += grantArguments + arguments
        app.launchOpening(fileAt: copy)
        app.waitForArchive(app.row("hello.txt"))
        return copy
    }

    /// Toolbar Extract menu > Extract Here, which must be on.
    private func extractHereFromMenu(file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.extractMenu
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no Extract menu\n\(app.debugDescription)", file: file, line: line)
        menu.tap()
        let item = app.buttons["Extract Here"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Extract Here in the menu\n\(app.debugDescription)",
                      file: file, line: line)
        XCTAssertTrue(item.isEnabled, "Extract Here is off\n\(app.debugDescription)", file: file, line: line)
        item.tap()
    }

    /// The app's Documents, on the simulator: the data container next to this runner's whose
    /// Documents holds the fixture hook's copy of `archive`.
    private func appDocuments(holding archive: URL) throws -> URL {
        let containers = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).deletingLastPathComponent()
        for container in try FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            if FileManager.default.fileExists(atPath: documents.appendingPathComponent(archive.lastPathComponent).path) {
                return documents
            }
        }
        XCTFail("no app container holds \(archive.lastPathComponent) next to \(containers.path)")
        throw CocoaError(.fileNoSuchFile)
    }

    /// A fresh folder in this runner's temporary directory (the simulator app can read and write it),
    /// removed after the test.
    private func makeRunnerFolder(_ prefix: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func names(in folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// Waits up to 15 s for `folder` to hold exactly `expected`.
    private func waitForNames(_ expected: Set<String>, in folder: URL,
                              file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        var found: Set<String> = []
        while Date() < deadline {
            found = (try? names(in: folder)) ?? []
            if found == expected { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("\(folder.lastPathComponent) holds \(found.sorted()), not \(expected.sorted())\n\(app.debugDescription)",
                file: file, line: line)
    }

    /// Waits up to 15 s for `folder` to hold visible names besides `before` and no Extract Here
    /// staging folder (`.kernir-…`, hidden, made before the items are placed and removed after)
    /// that wasn't in `before`, and returns the new visible names; fails and returns none at the
    /// deadline. Hidden names never count as new, and no fixed wait follows: the result is read once
    /// the extraction has finished.
    private func waitForNewNames(in folder: URL, besides before: Set<String>,
                                 file: StaticString = #filePath, line: UInt = #line) -> Set<String> {
        let deadline = Date().addingTimeInterval(15)
        var added: Set<String> = []
        while Date() < deadline {
            added = ((try? names(in: folder)) ?? before).subtracting(before)
            let visible = added.filter { !$0.hasPrefix(".") }
            if !visible.isEmpty, !added.contains(where: { $0.hasPrefix(".kernir-") }) { return visible }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("\(folder.lastPathComponent) got \(added.sorted()) besides \(before.sorted())\n\(app.debugDescription)",
                file: file, line: line)
        return []
    }
}
