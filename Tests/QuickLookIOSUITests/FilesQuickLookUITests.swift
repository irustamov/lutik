import XCTest

/// Drives the Files app: opens each fixture in "On My iPhone" and looks for Kernir's list in
/// Quick Look. Run by the Quick Look iOS test script after it copies t.zip and rar5-stored.rar into the
/// simulator's "On My iPhone" folder.
///
/// Both tests expect the assertion to fail: on iOS 26.5 Quick Look sends every type that
/// conforms to public.archive to its built-in preview before it looks for an extension, so
/// Kernir's extension is never used for these files. If a
/// future iOS lets it through, the strict expected failure reports an unexpected pass.
@MainActor
final class FilesQuickLookUITests: XCTestCase {
    private let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")

    override func setUp() {
        continueAfterFailure = false
    }

    // Kernir's header is PreviewFormatting.summary: "<format> archive · <n> item(s) · <size>".
    func testZipPreviewShowsKernirList() throws {
        try assertKernirPreview(of: "t.zip", builtInPageLabel: "Preview Content", headerPrefix: "ZIP archive · 1 item")
    }

    func testRarPreviewShowsKernirList() throws {
        try assertKernirPreview(of: "rar5-stored.rar", builtInPageLabel: "Preview Content", headerPrefix: "RAR archive · 1 item")
    }

    /// `builtInPageLabel` is a label of the system page Quick Look shows today (the same archive page
    /// for zip and rar). Asserting it proves the preview opened for this file,
    /// so the expected failure below cannot hide a crash or a dismissed preview.
    private func assertKernirPreview(of name: String, builtInPageLabel: String, headerPrefix: String) throws {
        files.openOnMyIPhone()
        let close = files.quickLookDoneButton

        // A tap on a zip extracts it and a tap on the name starts a rename, so open the
        // preview from the context menu of the cell instead.
        let file = files.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), "\(name) not found in On My iPhone")
        file.press(forDuration: 1.5)
        let quickLook = files.buttons["Quick Look"].firstMatch
        XCTAssertTrue(quickLook.waitForExistence(timeout: 10), "No Quick Look item in the menu for \(name)")
        quickLook.tap()

        let header = files.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", headerPrefix)).firstMatch
        let builtIn = files.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", builtInPageLabel)).firstMatch
        // Wait for the preview to settle, then keep the evidence before asserting anything.
        let found = header.waitForExistence(timeout: 10)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "quicklook-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
        // A preview must have opened at all (built-in page or Kernir's header); this is not
        // the expected failure, so a crash or dismissed preview still fails the test.
        XCTAssertTrue(builtIn.waitForExistence(timeout: 10) || header.exists,
                      "No preview opened for \(name) (neither '\(builtInPageLabel)' nor '\(headerPrefix)')")
        if close.exists { close.tap() }
        XCTExpectFailure("iOS 26.5 routes public.archive types to the built-in preview, never to the extension") {
            XCTAssertTrue(found, "No static text beginning '\(headerPrefix)' for \(name)")
        }
    }
}

/// Files navigation shared by the Quick Look and thumbnail UI tests (taps only, no typing).
@MainActor
extension XCUIApplication {
    /// The Done button of a Quick Look preview.
    var quickLookDoneButton: XCUIElement { buttons["QLOverlayDoneButtonAccessibilityIdentifier"] }

    /// Relaunches Files and opens Browse › On My iPhone.
    func openOnMyIPhone() {
        terminate()
        launch()
        XCTAssertTrue(wait(for: .runningForeground, timeout: 20))

        // Files restores the last state: close a leftover preview first.
        let close = quickLookDoneButton
        if close.waitForExistence(timeout: 3) { close.tap() }

        // Files may reopen in the last folder; navigate to the root "Browse" tab first.
        let onMyPhone = staticTexts["On My iPhone"].firstMatch
        if !onMyPhone.waitForExistence(timeout: 10) {
            let browse = tabBars.buttons["Browse"]
            if browse.exists { browse.tap() }
            if browse.exists { browse.tap() }
        }
        XCTAssertTrue(onMyPhone.waitForExistence(timeout: 15), "On My iPhone not found")
        onMyPhone.tap()
    }
}
