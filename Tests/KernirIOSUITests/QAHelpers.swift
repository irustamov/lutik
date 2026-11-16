import XCTest

/// The fixture corpus on disk and its manifest.
enum QAFixtures {
    /// The manifest's `password` and `wrongPassword`.
    static let password = "kernir"
    static let wrongPassword = "not-kernir"

    /// The repository checkout. The UI test runner runs in the simulator, which shares the
    /// Mac's file system, so `#filePath` resolves to the real checkout.
    static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func url(_ fixture: String) -> URL {
        repoRoot().appendingPathComponent("Fixtures").appendingPathComponent(fixture)
    }

    /// The paths at the top level of `fixture`, from `Fixtures/manifest.json`.
    static func rootEntries(of fixture: String, file: StaticString = #filePath,
                            line: UInt = #line) throws -> [String] {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("Fixtures/manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let entry = try XCTUnwrap(manifest.fixtures.first { $0.file == fixture },
                                  "\(fixture) is not in the manifest", file: file, line: line)
        let roots = (entry.entries ?? []).map(\.path).filter { !$0.contains("/") }
        XCTAssertFalse(roots.isEmpty, "\(fixture) lists no root entries in the manifest", file: file, line: line)
        return roots
    }

    /// Copies `fixture` to the runner's temporary directory under a name used by no other test
    /// or run, so state the app keys by file path (the Keychain account) starts empty.
    static func freshCopy(of fixture: String, prefix: String) throws -> URL {
        let source = url(fixture)
        let name = "\(prefix)-\(UUID().uuidString.prefix(8)).\(source.pathExtension)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QAFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private struct Manifest: Decodable {
        struct Fixture: Decodable {
            let file: String
            let entries: [Entry]?
        }
        struct Entry: Decodable {
            let path: String
        }
        let fixtures: [Fixture]
    }
}

extension XCUIApplication {
    /// Launches with the DEBUG `-KernirOpenFixture` hook pointed at any file, such as a fresh copy.
    func launchOpening(fileAt url: URL) {
        launchArguments += ["-KernirOpenFixture", url.path]
        skipWelcomeSheet()
        launch()
    }

    /// The launch view's marker (iOS 18+, no document open): its New Archive button, in either
    /// look (`LaunchLook`). On the Lutik art it is ours,
    /// `LaunchNewArchiveView`, by its identifier; in UIKit's legacy title card
    /// it is the card's stock button for our action, by its label (UIKit may not
    /// carry the action's identifier onto it). The out-of-process browser's own buttons ("DOC.")
    /// don't count. Hidden in iPhone landscape, where the stock view leaves it no room. iOS 17 has
    /// no launch view: tests using it and the helpers below start with `try skipUnlessLaunchView()`,
    /// or use `waitForBrowserInFront`.
    var launchNewArchiveButtons: XCUIElementQuery { buttons.matching(Self.launchNewArchivePredicate) }

    /// Matches the launch view's New Archive button in either look (`launchNewArchiveButtons`).
    static let launchNewArchivePredicate = NSPredicate(
        format: "identifier == %@ OR (label == %@ AND NOT (identifier BEGINSWITH %@))",
        "LaunchNewArchive", "New Archive", "DOC.")

    /// The launch browser (no document open), by its New Archive button.
    var launchNewArchive: XCUIElement { launchNewArchiveButtons.firstMatch }

    /// Note: the marker is hidden in iPhone landscape, so `waitForLaunchBrowserInFront`,
    /// `frontLaunchNewArchive` and `SceneUITests`' count of 2 assume iPad or iPhone portrait.
    ///
    /// Waits until some window's launch view is in front. With two windows at their launch views
    /// `launchNewArchive` (the first match) can be the background window's button, so this
    /// checks every one. A `timeout` of 0 checks once.
    func waitForLaunchBrowserInFront(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if frontLaunchNewArchive() != nil { return true }
            if Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        } while Date() < deadline
        return false
    }

    /// The hittable New Archive button of the launch view in front, if any.
    func frontLaunchNewArchive() -> XCUIElement? {
        launchNewArchiveButtons.allElementsBoundByIndex.first { $0.isInFront }
    }

    /// Waits until the browser shown with no document open is in front: the launch view on
    /// iOS 18+ (`waitForLaunchBrowserInFront`), the full-screen system browser on iOS 17.
    func waitForBrowserInFront(timeout: TimeInterval) -> Bool {
        guard XCTestCase.hasLaunchView else {
            let browser = launchBrowsers.firstMatch
            return browser.waitForExistence(timeout: timeout) && browser.waitUntilHittable(timeout: 5)
        }
        return waitForLaunchBrowserInFront(timeout: timeout)
    }

    /// The system browsers' location anchors: "DOC.browsingRoot Source: <source>, Title: <title>"
    /// (the browser runs out of process).
    var launchBrowsers: XCUIElementQuery {
        otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.browsingRoot"))
    }

    /// The app's folder in On My iPad / iPhone, named after the app's display name, which is the
    /// application element's label (the name is due to change: no literal).
    var appFolderName: String { label }

    /// An archive's search field is in the tree. The launch view's browser may have its own,
    /// so only search fields outside every browser count.
    var hasArchiveSearchField: Bool {
        searchFields.count > launchBrowsers.descendants(matching: .searchField).count
    }

    /// The alert shown when an archive can't be opened: "Couldn't open “name”".
    var openFailedAlert: XCUIElement {
        alerts.matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn't open")).firstMatch
    }

    /// The password sheet's field.
    var passwordField: XCUIElement { secureTextFields["Password"] }

    /// The message text of `alert`, if it shows `message`.
    func alertText(_ message: String, in alert: XCUIElement) -> XCUIElement {
        alert.staticTexts.matching(NSPredicate(format: "label == %@", message)).firstMatch
    }

    /// Waits until a sheet with a focused text field has finished presenting: the keyboard is
    /// up, and `element` has stopped moving (two frame reads 0.2 s apart agree) and is hittable.
    /// A tap during the presentation can land at the old frame, which is the cause of the
    /// known Cancel flake in BrowseUITests.testPasswordCancelReturnsToBrowser.
    func waitForSheetToSettle(_ element: XCUIElement, timeout: TimeInterval = 5,
                              file: StaticString = #filePath, line: UInt = #line) {
        // With the simulator's hardware keyboard connected no keyboard appears, so this wait
        // doesn't fail; the frame check below still applies.
        _ = keyboards.firstMatch.waitForExistence(timeout: 2)
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            let now = element.frame
            if now == last, element.isHittable { return }
            last = now
        }
        XCTFail("\(element) kept moving or never became hittable", file: file, line: line)
    }

    /// Waits until one of `elements` exists and returns its index, or nil on timeout.
    func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval = 10) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let index = elements.firstIndex(where: \.exists) { return index }
            _ = elements[0].waitForExistence(timeout: 0.25)
        } while Date() < deadline
        return elements.firstIndex(where: \.exists)
    }
}
