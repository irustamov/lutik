import ImageIO
import XCTest

/// App Store window screenshots. CI only, like every macOS UI test. The app's launch-argument
/// hooks (`-KernirWindowFrame`, `-KernirAppearance`) fix the window's frame size and appearance
/// so the runner's own settings can't leak in; both are ignored without the arguments.
///
/// Each test attaches the window as "mac-light" / "mac-dark" (kept always), for the xcresult.
final class ScreenshotUITests: KernirMacUITestCase {
    func testBrowseLight() throws {
        try captureBrowse(appearance: "light", name: "mac-light")
    }

    func testBrowseDark() throws {
        try captureBrowse(appearance: "dark", name: "mac-dark")
    }

    private func captureBrowse(appearance: String, name: String) throws {
        app.launchArguments += ["-KernirAppearance", appearance, "-KernirWindowFrame", "1024x640"]
        try openFixture("showcase/project.zip")
        let src = app.row("src")
        waitForArchive(src)
        // Both hooks travel as launch arguments; if they didn't arrive, the shot would be a
        // cascaded window in the runner's appearance.
        XCTAssertEqual(app.windows.firstMatch.frame.size, CGSize(width: 1024, height: 640),
                       "-KernirWindowFrame did not apply")

        src.expand()
        let main = app.row("main.swift")
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        main.select()
        let selected = NSPredicate(format: "selected == true")
        expectation(for: selected, evaluatedWith: main)
        waitForExpectations(timeout: 5)

        // Park the pointer 24 pt below the (centered) window, so no control shows a hover.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 24)).hover()

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The App Store gallery on the Mac, the same story as
/// the iOS gallery on the same fixtures (`Tests/KernirIOSUITests/Screenshots/`). Local desktop
/// only: it skips unless `SCREENSHOT_APPEARANCE` (light or
/// dark) is set, besides `KERNIR_MAC_UI_TESTS`.
///
/// A shot is the screen region holding Kernir's own windows: the archive window (with any sheet
/// in it), the Quick Look panel, a context menu. Each is attached as `mac-<shot>-<appearance>`:
/// a `.png` of the screen and a `.json` of the frames (points, top-left origin) and the screen
/// scale. The screen capture is masked in memory before it is attached: every pixel outside the
/// frames is black, so nothing of the desktop or another app is ever written to disk.
/// The gallery composer script cuts the frames out as rounded rects and centers
/// them on the store canvas.
final class ScreenshotGalleryUITests: KernirMacUITestCase {
    private var appearance = "light"
    /// The archive window's frame, taken before any panel or menu opens.
    private var windowFrame = CGRect.zero

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["SCREENSHOT_APPEARANCE"], ["light", "dark"].contains(value) else {
            throw XCTSkip("store screenshots only: set TEST_RUNNER_SCREENSHOT_APPEARANCE=light|dark")
        }
        try await super.setUp()
        appearance = value
        app.launchArguments += ["-KernirAppearance", appearance, "-KernirWindowFrame", "1152x720"]
        // The fixtures' dates are 09:30 UTC: the zips keep that as DOS local time, the 7z as UTC,
        // so only in UTC do both show 9:30 AM.
        app.launchEnvironment["TZ"] = "UTC"
    }

    // MARK: - Browsing

    func testBrowse() throws {
        try openProject()
        app.row("Docs").expand()
        let notes = app.row("Meeting Notes.md")
        XCTAssertTrue(notes.waitForExistence(timeout: 5), app.debugDescription)
        notes.select()
        capture("browse")
    }

    func testSearch() throws {
        try openProject()
        let search = app.searchField
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.click()
        // One key at a time: typeText(".md") in one go left ".mdmd" in the toolbar field (light and dark).
        for key in ".md" {
            search.typeText(String(key))
        }
        XCTAssertEqual(search.value as? String, ".md")
        XCTAssertTrue(app.row("Roadmap.md").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.row("Budget.csv").waitForNonExistence(timeout: 5), app.debugDescription)
        capture("search")
    }

    func testContextMenu() throws {
        try openProject()
        let readme = app.row("README.md")
        readme.select()
        readme.cells.firstMatch.staticTexts.firstMatch.rightClick()
        // The row menu hangs off the outline; app.menus.firstMatch finds a menu bar menu.
        let menu = app.outlines.firstMatch.menus.firstMatch
        XCTAssertTrue(menu.menuItems["Quick Look"].waitForExistence(timeout: 5), app.debugDescription)
        capture("menu", extra: [menu])
        app.typeKey(.escape, modifierFlags: [])
    }

    func testEdited() throws {
        try openProject()
        let checklist = app.row("Checklist.txt")
        checklist.select()
        app.archiveOutline.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(checklist.waitForNonExistence(timeout: 5), app.debugDescription)
        app.row("README.md").select()
        capture("edited")
    }

    func testSaveAs() throws {
        // The panel opens on the archive's folder: a "Documents" folder inside the work
        // folder, so "Where:" shows a neutral name instead of "KernirMacUITests-<UUID>".
        try openProject(in: "Documents")
        app.typeKey("s", modifierFlags: [.command, .shift])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no Save As panel\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 2)
        capture("save-as")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testNewArchive() throws {
        try openProject()
        app.typeKey("n", modifierFlags: .command)
        let empty = app.text(containing: "Drag Files Here")
        XCTAssertTrue(empty.waitForExistence(timeout: 10), app.debugDescription)
        let window = app.windows.containing(.staticText, identifier: "Drag Files Here").firstMatch
        windowFrame = window.exists ? window.frame : app.windows.firstMatch.frame
        capture("new")
    }

    func testSettings() throws {
        try openProject()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        windowFrame = settings.frame
        capture("settings")
    }

    // MARK: - Quick Look

    func testQuickLookPhoto() throws { try quickLook("Photos", "Mountain Lake.jpg", shot: "preview-photo") }
    func testQuickLookImage() throws { try quickLook("Design", "Logo Concept.png", shot: "preview-image") }
    func testQuickLookPDF() throws { try quickLook("Design", "Wireframe.pdf", shot: "preview-pdf") }
    func testQuickLookMarkdown() throws { try quickLook(nil, "README.md", shot: "preview-markdown") }
    func testQuickLookText() throws { try quickLook(nil, "Checklist.txt", shot: "preview-text") }
    func testQuickLookCSV() throws { try quickLook("Docs", "Budget.csv", shot: "preview-csv") }

    // MARK: - Password

    func testPasswordZip() throws {
        try openLocked("Contracts.zip")
        capture("password")

        let field = app.sheets.secureTextFields.firstMatch
        field.click()
        field.typeText("contract")
        app.sheets.buttons["Open"].click()
        XCTAssertTrue(app.text(containing: "Wrong password").waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        capture("password-wrong")

        field.click()
        field.typeText("kernir")
        app.sheets.buttons["Open"].click()
        waitForArchive(app.row("Notes.txt"))
        app.row("Notes.txt").select()
        capture("unlocked")
    }

    func testPassword7z() throws {
        try openLocked("Contracts.7z")
        capture("password-7z")
        let field = app.sheets.secureTextFields.firstMatch
        field.click()
        field.typeText("kernir")
        app.sheets.buttons["Open"].click()
        waitForArchive(app.row("Notes.txt"))
        capture("unlocked-7z")
    }

    // MARK: - Steps

    /// The store fixtures, shared with the iOS gallery.
    private static let storeFixtures = fixturesDirectory.deletingLastPathComponent()
        .appendingPathComponent("Tests/KernirIOSUITests/Screenshots", isDirectory: true)

    private func openStoreFixture(_ name: String, in folder: String? = nil) throws {
        var directory: URL = workDirectory
        if let folder {
            directory = workDirectory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let copy = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.storeFixtures.appendingPathComponent(name), to: copy)
        open(copy)
    }

    private func openProject(in folder: String? = nil) throws {
        try openStoreFixture("Project.zip", in: folder)
        waitForArchive(app.row("Docs"))
        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame.size, CGSize(width: 1152, height: 720), "-KernirWindowFrame did not apply")
        windowFrame = window.frame
    }

    private func openLocked(_ name: String) throws {
        try openStoreFixture(name)
        let field = app.sheets.secureTextFields.firstMatch
        waitForArchive(field)
        windowFrame = app.windows.firstMatch.frame
        Thread.sleep(forTimeInterval: 1)
    }

    private func quickLook(_ folder: String?, _ name: String, shot: String) throws {
        try openProject()
        if let folder { app.row(folder).expand() }
        let file = app.row(name)
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        file.select()
        let before = app.windows.count
        app.archiveOutline.typeKey(" ", modifierFlags: [])
        // The panel is one more window of the app, beside the archive window.
        let opened = expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: app.windows)
        wait(for: [opened], timeout: 10)
        Thread.sleep(forTimeInterval: 2.5)
        let panel = try XCTUnwrap(app.windows.allElementsBoundByIndex.first { $0.frame != windowFrame },
                                  "no Quick Look panel\n\(app.debugDescription)")
        capture(shot, extra: [panel])
        app.typeKey(" ", modifierFlags: [])
    }

    // MARK: - Capture

    /// Attaches the full screen and the frames of the archive window and `extra` (panels,
    /// menus) as `mac-<shot>-<appearance>.png` / `.json`.
    private func capture(_ shot: String, extra: [XCUIElement] = []) {
        // Park the pointer below the window, so no control shows a hover.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 40)).hover()
        Thread.sleep(forTimeInterval: 1)
        let name = "mac-\(shot)-\(appearance)"
        let frames = [windowFrame] + extra.map(\.frame)
        // XCUIScreen.main is the menu-bar display. Its NSImage reports pixels as points, so the
        // scale comes from that display's size in points (NSScreen.screens.first).
        let display = try! XCTUnwrap(NSScreen.screens.first).frame
        for frame in frames {
            XCTAssertTrue(CGRect(origin: .zero, size: display.size).contains(frame),
                          "\(name): \(frame) is off the captured display \(display.size)")
        }
        let screen = try! XCTUnwrap(XCUIScreen.main.screenshot().image
            .cgImage(forProposedRect: nil, context: nil, hints: nil), "\(name): no screen image")
        let scale = CGFloat(screen.width) / display.width
        let layout: [String: Any] = [
            "scale": scale,
            "kinds": ["window"] + extra.map { $0.elementType == .menu ? "menu" : "panel" },
            "frames": frames.map { [$0.minX, $0.minY, $0.width, $0.height] },
        ]
        XCTContext.runActivity(named: name) { activity in
            let png = XCTAttachment(data: Self.maskedPNG(screen, keeping: frames, scale: scale),
                                    uniformTypeIdentifier: "public.png")
            png.name = "\(name).png"
            png.lifetime = .keepAlways
            activity.add(png)
            let json = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: layout),
                                     uniformTypeIdentifier: "public.json")
            json.name = "\(name).json"
            json.lifetime = .keepAlways
            activity.add(json)
        }
    }

    /// `screen` as PNG data with every pixel outside `frames` (points, top-left origin) black.
    /// Each frame is widened to whole pixels and the screen's color space is kept, so the
    /// composer's crops see the same pixels as in the unmasked screen.
    private static func maskedPNG(_ screen: CGImage, keeping frames: [CGRect], scale: CGFloat) -> Data {
        let width = screen.width, height = screen.height
        let space = screen.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try! XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: space,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                               | CGBitmapInfo.byteOrder32Little.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(bounds)
        // Points, top-left origin → pixels, bottom-left origin.
        ctx.clip(to: frames.map { frame in
            CGRect(x: frame.minX * scale, y: CGFloat(height) - frame.maxY * scale,
                   width: frame.width * scale, height: frame.height * scale).integral
        })
        ctx.draw(screen, in: bounds)
        let masked = try! XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let destination = try! XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, masked, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "PNG encoding failed")
        return data as Data
    }
}
