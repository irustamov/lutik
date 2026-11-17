import XCTest

/// The App Store screenshot gallery: every feature the
/// iOS description claims, on one appearance per run. Each test starts a fresh app on a store
/// fixture and captures one or more shots, named `ios-<iphone|ipad>-<shot>-<light|dark>.png`:
///
/// - `browse`, `folder`, `search`, `select`, `share`, `menu` (row context menu), `add` (Add
///   menu), `edited` (a removed file, Undo and Save on the bar), `extract` (the folder picker),
///   `title-menu` (the document's title menu), `new` (the New Archive options sheet), `files`
///   (the launch browser)
/// - `preview-photo`, `preview-image`, `preview-pdf`, `preview-markdown`, `preview-text`,
///   `preview-csv`
/// - `password` (ZIP, empty), `password-wrong`, `unlocked` (the archive after the password),
///   `password-7z` (a 7z with encrypted names) and `unlocked-7z`. A typed password can't be
///   shown: iOS leaves secure text out of screenshots.
///
/// Each shot is attached (`.keepAlways`) with the app's element tree as a `.txt` next to it,
/// and written to `SCREENSHOT_DIR`. The whole class skips unless `SCREENSHOT_DIR` is set, so a
/// normal suite run spends no time here. `xcodebuild` passes a `TEST_RUNNER_<NAME>` variable
/// to the test runner as `<NAME>`; a plain `SCREENSHOT_DIR=…` does not reach it.
///
/// The appearance is set on the simulator, not by the test: `XCUIDevice.shared.appearance` set
/// before launch left the app light on iOS 26. `SCREENSHOT_APPEARANCE` (light or dark) names
/// the files and is checked against the screen's brightness. The screenshot script
/// erases and boots a simulator, sets the 9:41 status bar and the appearance, and runs this
/// class once per appearance, on iPhone 17 Pro (1206×2622) and iPad Pro 13-inch (M5)
/// (2064×2752); iPhone 17 Pro Max (1320×2868) only for the optional 6.9" set. The PNGs are
/// redrawn opaque (App Store Connect refuses alpha).
///
/// The fixtures, `Screenshots/Project.zip`, `Screenshots/Contracts.zip` and
/// `Screenshots/Contracts.7z` (password `kernir`), come from `Screenshots/make-fixtures.sh`.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var appearance = "light"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SCREENSHOT_DIR"]?.isEmpty == false else {
            throw XCTSkip("store screenshots only: set TEST_RUNNER_SCREENSHOT_DIR (and TEST_RUNNER_SCREENSHOT_APPEARANCE)")
        }
        continueAfterFailure = false
        appearance = env["SCREENSHOT_APPEARANCE"] == "dark" ? "dark" : "light"
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Browsing

    func testBrowseFolderSearch() throws {
        let docs = try openProject()
        XCTAssertTrue(app.row("Photos").exists)
        XCTAssertTrue(app.row("README.md").exists)
        capture("browse")

        docs.tap()
        let roadmap = app.row("Docs/Roadmap.md")
        XCTAssertTrue(roadmap.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.navigationBars["Docs"].waitForExistence(timeout: 5), app.debugDescription)
        settle(on: roadmap)
        capture("folder")

        // search: filters the open folder (not its subfolders), so ".md" in Docs keeps the two
        // Markdown files and hides Budget.csv.
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 3) {
            app.buttons["Search"].firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(".md\n")
        let notes = app.row("Docs/Meeting Notes.md")
        XCTAssertTrue(notes.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.row("Docs/Budget.csv").waitForNonExistence(timeout: 5), app.debugDescription)
        settle(on: notes, keyboard: false)
        capture("search")
    }

    func testSelectAndShare() throws {
        _ = try openProject()
        let photos = app.row("Photos")
        photos.tap()
        let lake = app.row("Photos/Mountain Lake.jpg")
        let coast = app.row("Photos/Coastline.jpg")
        XCTAssertTrue(lake.waitForExistence(timeout: 5), app.debugDescription)
        settle(on: lake)
        app.startSelecting()
        lake.tap()
        coast.tap()
        let share = app.toolbars.buttons["Share"]
        XCTAssertTrue(share.waitForEnabled(timeout: 5), app.debugDescription)
        settle(on: share)
        capture("select")
        // ios-screenshots.sh --no-share: while the host's share sheet hangs (the simulators
        // block on a host-wide airport preferences read), keep the select shot only.
        if ProcessInfo.processInfo.environment["SCREENSHOT_SHARE"] == "0" { return }

        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "the share sheet did not come up\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 2.5)
        capture("share")
    }

    func testContextMenu() throws {
        _ = try openProject()
        let readme = app.row("README.md")
        settle(on: readme)
        readme.press(forDuration: 1.2)
        let preview = app.collectionViews.buttons["Preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "no context menu\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1.5)
        capture("menu")
    }

    func testAddMenu() throws {
        _ = try openProject()
        let add = app.toolbars.buttons["Add"]
        settle(on: add)
        add.tap()
        let files = app.buttons["Choose Files…"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "the Add menu did not open\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1.5)
        capture("add")
    }

    func testEdited() throws {
        _ = try openProject()
        let checklist = app.row("Checklist.txt")
        settle(on: checklist)
        app.deleteBySwiping(checklist)
        XCTAssertTrue(checklist.waitForNonExistence(timeout: 5), app.debugDescription)
        app.assertSaveOnBar()
        settle(on: app.row("README.md"))
        capture("edited")
    }

    func testExtractPicker() throws {
        _ = try openProject()
        settle(on: app.extractMenu)
        app.extractTo()
        XCTAssertTrue(app.pickerOffersNewFolder(), "Extract's picker picks a folder\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 2)
        capture("extract")
    }

    func testTitleMenu() throws {
        _ = try openProject()
        let title = app.buttons["Project, Actions Menu"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no title menu\n\(app.debugDescription)")
        title.tap()
        Thread.sleep(forTimeInterval: 2)
        capture("title-menu")
    }

    /// The launch browser's New Archive options sheet (ZIP). Cancel, not Create: a new
    /// "Untitled" archive would show up in the `files` shot.
    func testNewArchive() throws {
        app = Self.makeApp()
        app.launch()
        app.tapNewArchive()
        let create = app.saveOptionsButton("Create")
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        app.assertFormat("ZIP")
        settle(on: create)
        capture("new")
        app.saveOptionsButton("Cancel").tap()
        XCTAssertTrue(create.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    /// Runs last (`Z`): by then Documents holds the store fixtures, so the browser lists them.
    func testZFilesBrowser() throws {
        try skipUnlessLaunchView()
        app = Self.makeApp()
        app.launch()
        XCTAssertTrue(app.waitForLaunchBrowserInFront(timeout: 15), app.debugDescription)
        // The browser opens on Recents, which a fresh simulator can't list ("Content
        // Unavailable"); Browse > On My iPhone > Lutik shows the archives in Documents. On
        // iPhone Browse is in a tab bar; on iPad it's a segment in the browser's bar.
        var browse = app.tabBars["DOC.browsingModeTabBar"].buttons["Browse"]
        if !browse.waitForExistence(timeout: 5) {
            browse = app.buttons.matching(NSPredicate(format: "label == %@", "Browse")).firstMatch
        }
        XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
        browse.tap()
        let project = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", "Project")).firstMatch
        if !project.waitForExistence(timeout: 3) {
            let local = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", "On My")).firstMatch
            if local.waitForExistence(timeout: 3) { local.tap() }
            let folder = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", app.appFolderName)).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5), "no Lutik folder\n\(app.debugDescription)")
            folder.tap()
        }
        XCTAssertTrue(project.waitForExistence(timeout: 10), "Documents isn't listed\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 3)
        capture("files")
    }

    // MARK: - Preview

    func testPreviewPhoto() throws {
        try preview("Photos", "Photos/Mountain Lake.jpg", title: "Mountain Lake", shot: "preview-photo", image: true)
    }

    func testPreviewImage() throws {
        try preview("Design", "Design/Logo Concept.png", title: "Logo Concept", shot: "preview-image", image: true)
    }

    func testPreviewPDF() throws {
        try preview("Design", "Design/Wireframe.pdf", title: "Wireframe", shot: "preview-pdf", image: false)
    }

    func testPreviewMarkdown() throws {
        try preview(nil, "README.md", title: "README", shot: "preview-markdown", image: false)
    }

    func testPreviewText() throws {
        try preview(nil, "Checklist.txt", title: "Checklist", shot: "preview-text", image: false)
    }

    func testPreviewCSV() throws {
        // Quick Look lays the table out at desktop width, tiny in a corner. On iPhone a double tap
        // on it zooms the web view to the table; on iPad a double tap does nothing, so the web view
        // is pinched instead (about 1.3x per pinch, whatever scale is asked; a pinch on the table
        // itself is refused) until the table spans most of the width, then dragged back to its
        // top-left corner. Never swipe down here: that dismisses the preview.
        try preview("Docs", "Docs/Budget.csv", title: "Budget", shot: "preview-csv", image: false) { preview in
            let header = preview.staticTexts["Item"].firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 5), "no table\n\(self.app.debugDescription)")
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                header.doubleTap()
                Thread.sleep(forTimeInterval: 1.5)
                return
            }
            let web = preview.webViews.firstMatch
            // The table is about 14x as wide as the header's text is tall (1032 pt screen: 14 pt
            // text, a 200 pt table); 4.5x that text height puts the table near 90% of the width.
            let target = header.frame.height * 4.5
            for _ in 0..<8 where header.frame.height < target {
                web.pinch(withScale: 3, velocity: 2)
                Thread.sleep(forTimeInterval: 1.5)
            }
            // Each pinch zooms about the centre, pushing the table up and left: drag the content
            // down and right (slowly, holding at the end so nothing flings) until it stops moving
            // at its top-left edge.
            for _ in 0..<8 {
                let before = header.frame
                let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2))
                let to = web.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.9))
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 1500, thenHoldForDuration: 0.3)
                Thread.sleep(forTimeInterval: 1)
                if header.frame == before { break }
            }
            let last = preview.staticTexts["10140"].firstMatch
            XCTAssertGreaterThanOrEqual(header.frame.height, target, "the table did not zoom\n\(self.app.debugDescription)")
            XCTAssertTrue(header.frame.minX > 0 && header.frame.minY > 0 && last.frame.maxX < web.frame.maxX,
                          "the table is not at the top left\n\(self.app.debugDescription)")
        }
    }

    // MARK: - Password

    func testPasswordZip() throws {
        let field = try openLocked("Contracts.zip")
        XCTAssertFalse(app.buttons["Open"].isEnabled, "the field should be empty\n\(app.debugDescription)")
        capture("password")

        // password-wrong: a wrong password, then the error under the field.
        field.tap()
        field.typeText("contract")
        app.buttons["Open"].tap()
        let wrong = app.staticTexts["The password is incorrect."]
        XCTAssertTrue(wrong.waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.5)
        capture("password-wrong")

        // unlocked: the right password opens the archive.
        let retry = app.passwordField
        retry.tap()
        retry.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "kernir")
        app.buttons["Open"].tap()
        let notes = app.row("Notes.txt")
        app.waitForArchive(notes)
        settle(on: notes)
        capture("unlocked")
    }

    func testPassword7z() throws {
        let field = try openLocked("Contracts.7z")
        capture("password-7z")

        // unlocked-7z: the names are encrypted too, so the list appears only after the password.
        field.tap()
        field.typeText("kernir")
        app.buttons["Open"].tap()
        let notes = app.row("Notes.txt")
        app.waitForArchive(notes)
        settle(on: notes)
        capture("unlocked-7z")
    }

    // MARK: - Steps

    /// Opens Project.zip and returns its Docs row once the root is listed and still.
    private func openProject() throws -> XCUIElement {
        app = Self.makeApp()
        app.launchOpening(fileAt: Self.fixture("Project.zip"))
        let docs = app.row("Docs")
        app.waitForArchive(docs)
        settle(on: docs)
        checkAppearance()
        return docs
    }

    /// Opens an encrypted fixture and returns the password field once its sheet has settled.
    private func openLocked(_ name: String) throws -> XCUIElement {
        app = Self.makeApp()
        app.launchOpening(fileAt: Self.fixture(name))
        let field = app.passwordField
        app.waitForArchive(field)
        // The sheet focuses the field as it appears, so the keyboard comes up with it.
        app.waitForSheetToSettle(field)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(app.staticTexts["The password is incorrect."].exists, app.debugDescription)
        return field
    }

    /// Opens `path` (inside `folder`, if any) in the preview and captures it with its bar shown.
    private func preview(_ folder: String?, _ path: String, title: String, shot: String, image: Bool,
                         adjust: ((XCUIElement) -> Void)? = nil) throws {
        _ = try openProject()
        if let folder {
            app.row(folder).tap()
        }
        let file = app.row(path)
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        settle(on: file)
        file.tap()
        let preview = app.previewController
        XCTAssertTrue(preview.waitForExistence(timeout: 15), "the preview did not come up\n\(app.debugDescription)")
        if image {
            // The image view's identifier is the markup one on iOS 26 and the plain one on iOS 27.
            let canvas = preview.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", [
                "QLMarkupImageItemViewControllerMarkupImageViewAccessibilityIdentifier",
                "QLImageItemViewControllerImageViewAccessibilityIdentifier",
            ])).firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 10), "the image did not load\n\(app.debugDescription)")
        }
        // An image preview opens with its bars hidden; one tap shows them (title, Done, share).
        let bar = app.previewBar(title)
        if !bar.waitForExistence(timeout: 3) {
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the preview's bar did not come up\n\(app.debugDescription)")
        // Settle on Done: on iPad the bar's title sits at the left, so the bar's centre is empty.
        settle(on: app.previewDoneButton)
        adjust?(preview)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(bar.exists, "the preview's bar hid again\n\(app.debugDescription)")
        capture(shot)
    }

    // MARK: - Helpers

    /// Checks the screen's mean brightness against `SCREENSHOT_APPEARANCE` (the browse screen is
    /// mostly background), so a light simulator never produces "dark" files.
    private func checkAppearance(file: StaticString = #filePath, line: UInt = #line) {
        let dark = appearance == "dark"
        let luma = Self.meanLuma(XCUIScreen.main.screenshot().image)
        let matches = dark ? luma < 0.35 : luma > 0.65
        XCTAssertTrue(matches, "the screen's mean luma is \(String(format: "%.2f", luma)), not \(appearance): "
            + "set it with `xcrun simctl ui <id> appearance \(appearance)` before this run", file: file, line: line)
    }

    /// The mean Rec. 709 luma (0...1) of `image`, from a 32×64 downscale.
    private static func meanLuma(_ image: UIImage) -> Double {
        let (width, height) = (32, 64)
        guard let cg = image.cgImage,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return -1 }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        var sum = 0.0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            sum += 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])
        }
        return sum / Double(width * height) / 255
    }

    /// A fresh app in UTC. The fixtures' dates are 09:30 UTC (make-fixtures.sh runs under
    /// TZ=UTC): the zips keep that as DOS local time, the 7z as UTC, so only in UTC do both
    /// show 9:30 AM.
    private static func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TZ"] = "UTC"
        app.skipWelcomeSheet()
        return app
    }

    /// A store fixture next to this file, in `Screenshots/`.
    private static func fixture(_ name: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("Screenshots").appendingPathComponent(name)
    }

    /// Waits until the screen is still: no progress sheet (and no keyboard, unless `keyboard`
    /// is false), `element` hittable and no longer moving, then a moment for transitions to fade.
    private func settle(on element: XCUIElement, keyboard: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        let preparing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Preparing")).firstMatch
        XCTAssertTrue(preparing.waitForNonExistence(timeout: 15), "the progress sheet stayed up\n\(app.debugDescription)",
                      file: file, line: line)
        if keyboard {
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                          "the keyboard is up\n\(app.debugDescription)", file: file, line: line)
        }
        let deadline = Date().addingTimeInterval(5)
        var last = element.frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let now = element.frame
            if now == last, element.isHittable { break }
            last = now
        }
        XCTAssertTrue(element.isHittable, "\(element) is not hittable\n\(app.debugDescription)", file: file, line: line)
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Attaches the full-screen shot as `ios-<idiom>-<shot>-<appearance>.png` and the element
    /// tree as `….txt`, and writes the PNG to `SCREENSHOT_DIR`.
    private func capture(_ shot: String, file: StaticString = #filePath, line: UInt = #line) {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let name = "ios-\(idiom)-\(shot)-\(appearance)"
        let png = Self.opaquePNG(XCUIScreen.main.screenshot().image)

        XCTContext.runActivity(named: name) { activity in
            let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            image.name = "\(name).png"
            image.lifetime = .keepAlways
            activity.add(image)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(name).txt"
            tree.lifetime = .keepAlways
            activity.add(tree)
        }

        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true),
                         file: file, line: line)
        XCTAssertNoThrow(try png.write(to: folder.appendingPathComponent("\(name).png"), options: .atomic),
                         file: file, line: line)
    }

    /// `image` redrawn into an opaque 8-bit sRGB bitmap at its own scale (so the full pixel
    /// size), as PNG data without an alpha channel.
    private static func opaquePNG(_ image: UIImage) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = image.scale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(at: .zero)
        }
    }
}
