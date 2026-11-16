import XCTest

/// More > Text Encoding… on an archive whose names are stored in CP1251 without the UTF-8 flag.
@MainActor
final class TextEncodingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        // Other suites rotate the shared simulator; a killed run can leave it in landscape. XCTest
        // calls setUp on the main thread.
        MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// Automatic reads the names as CP1251. Russian (DOS) reads them again as CP866 (mojibake), and
    /// Cyrillic (Windows) brings "Отчёт за май.docx" back. A fresh copy: the app remembers a choice
    /// per file, so a copy another run used could open with that run's choice.
    func testChoosingCyrillicWindowsListsTheRussianNames() throws {
        let app = XCUIApplication()
        app.launchOpening(fileAt: try QAFixtures.freshCopy(of: "zip/legacy-cp1251.zip", prefix: "TextEncoding"))
        let report = app.row("Отчёт за май.docx")
        app.waitForArchive(report)
        XCTAssertTrue(app.row("Фото").exists, app.debugDescription)

        app.chooseTextEncoding("Russian (DOS)", current: "Automatic")
        XCTAssertTrue(app.row("╬Єў╕Є чр ьрщ.docx").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(report.exists)

        app.chooseTextEncoding("Cyrillic (Windows)", current: "Russian (DOS)")
        XCTAssertTrue(report.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.row("Фото").exists, app.debugDescription)
        XCTAssertTrue(app.row("отчет.txt").exists, app.debugDescription)
        XCTAssertFalse(app.row("╬Єў╕Є чр ьрщ.docx").exists)
        // An alert would come up only once the progress sheet has gone.
        app.waitForTextEncodingProgressToGo()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1), app.alerts.firstMatch.debugDescription)
    }

    /// Choosing from inside a folder the new encoding renames ("Фото" reads as "╘юЄю" in CP866): once
    /// the progress sheet has gone, the folder's level goes too, leaving the root with the new names,
    /// and the menu works again (a sheet stuck over the root would cover More).
    func testChoosingInsideARenamedFolderGoesBackToTheRoot() throws {
        let app = XCUIApplication()
        app.launchOpening(fileAt: try QAFixtures.freshCopy(of: "zip/legacy-cp1251.zip", prefix: "TextEncodingFolder"))
        let photos = app.row("Фото")
        app.waitForArchive(photos)
        photos.tap()
        XCTAssertTrue(app.row("Фото/Лето 2024.jpg").waitForExistence(timeout: 5), app.debugDescription)

        app.chooseTextEncoding("Russian (DOS)", current: "Automatic")
        let renamed = app.row("╘юЄю")
        XCTAssertTrue(renamed.waitForExistence(timeout: 10), "not back at the root\n\(app.debugDescription)")
        app.waitForTextEncodingProgressToGo()
        XCTAssertTrue(renamed.isHittable, app.debugDescription)
        XCTAssertTrue(app.row("╬Єў╕Є чр ьрщ.docx").exists, app.debugDescription)
        XCTAssertFalse(app.row("Фото/Лето 2024.jpg").exists, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1), app.alerts.firstMatch.debugDescription)

        app.chooseTextEncoding("Cyrillic (Windows)", current: "Russian (DOS)")
        XCTAssertTrue(photos.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.row("Отчёт за май.docx").exists, app.debugDescription)
        XCTAssertFalse(renamed.exists)
    }

    /// Cancel closes the sheet without a choice: the archive isn't read again (no progress sheet)
    /// and the names stay as Automatic read them.
    func testCancelLeavesTheNamesAsTheyAre() throws {
        let app = XCUIApplication()
        app.launchOpening(fileAt: try QAFixtures.freshCopy(of: "zip/legacy-cp1251.zip", prefix: "TextEncodingCancel"))
        let report = app.row("Отчёт за май.docx")
        app.waitForArchive(report)

        let item = app.textEncodingItem()
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Text Encoding…\n\(app.debugDescription)")
        XCTAssertTrue(item.waitForEnabled(timeout: 5), "Text Encoding… is off\n\(app.debugDescription)")
        item.tap()
        let sheetBar = app.navigationBars["Text Encoding"]
        XCTAssertTrue(sheetBar.waitForExistence(timeout: 5), "no Text Encoding sheet\n\(app.debugDescription)")
        sheetBar.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 5), "the Text Encoding sheet stayed\n\(app.debugDescription)")

        // No reopen: the progress sheet ("Reading “…”…") doesn't come up, and the names are Automatic's.
        let reading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading")).firstMatch
        XCTAssertFalse(reading.waitForExistence(timeout: 2), "Cancel read the archive again\n\(app.debugDescription)")
        XCTAssertTrue(report.exists, app.debugDescription)
        XCTAssertTrue(app.row("Фото").exists, app.debugDescription)
        XCTAssertTrue(app.row("отчет.txt").exists, app.debugDescription)
        XCTAssertFalse(app.row("╬Єў╕Є чр ьрщ.docx").exists, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
    }

    /// With unsaved changes More > Text Encoding… is off, not only ignored when
    /// chosen. It is a plain item, not a submenu, so it shows itself off.
    func testTextEncodingIsOffWithUnsavedChanges() throws {
        let app = XCUIApplication()
        app.launchOpening(fileAt: try QAFixtures.freshCopy(of: "zip/legacy-cp1251.zip", prefix: "TextEncodingEdited"))
        let notes = app.row("отчет.txt")
        app.waitForArchive(notes)
        app.deleteBySwiping(notes)
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5), app.debugDescription)
        app.assertSaveOnBar()

        let item = app.textEncodingItem()
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Text Encoding…\n\(app.debugDescription)")
        XCTAssertFalse(item.isEnabled, "Text Encoding… is on with unsaved changes\n\(app.debugDescription)")
        // Tapping it anyway opens nothing.
        item.tap()
        XCTAssertFalse(app.navigationBars["Text Encoding"].waitForExistence(timeout: 2), app.debugDescription)
    }
}

extension XCUIApplication {
    /// More > Text Encoding…, with More opened when the item isn't in the bar (iPhone: it is in the
    /// More overflow; iPad may show it in the bar).
    func textEncodingItem() -> XCUIElement {
        let item = buttons["Text Encoding…"].firstMatch
        if !item.exists {
            navigationBars.buttons["More"].firstMatch.tap()
        }
        return item
    }

    /// Text Encoding's 12 row titles: Automatic, then `ArchiveNameEncoding.choices` (KernirCore's
    /// NameEncoding.swift) titled as `ArchiveNameEncoding.title(of:)` titles them (App/Shared; this
    /// target links neither). Literals, not `String.localizedName(of:)`, which is "" on iOS for all but
    /// Unicode. Keep the lists in the same order.
    static let textEncodingTitles: [String] = [
        "Automatic", "Unicode (UTF-8)", "Cyrillic (Windows)", "Russian (DOS)", "Cyrillic (KOI8-R)",
        "Japanese (Windows, DOS)", "Chinese (GB 18030)", "Traditional Chinese (Big 5)", "Korean (Windows, DOS)",
        "Western (Windows Latin 1)", "Latin-US (DOS)", "Central European (Windows Latin 2)",
    ]

    /// More > Text Encoding… > `title`, with `current` the row checked when the sheet opens. It first
    /// waits for an earlier choice's progress sheet to go: the item is off until then, and on iPhone
    /// the sheet covers More. Fails when the item or the choice is off, when `current` isn't the
    /// selected row, or when any of the 12 rows is missing its title (rows 3-12 were blank on iOS 26.5:
    /// `String.localizedName(of:)` returns "" there for the 10 non-Unicode encodings). Rows below the fold
    /// (iPad form sheet, iPhone landscape, larger text) are scrolled into view first, with a bounded number
    /// of swipes.
    func chooseTextEncoding(_ title: String, current: String, file: StaticString = #filePath, line: UInt = #line) {
        waitForTextEncodingProgressToGo(file: file, line: line)
        let item = textEncodingItem()
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Text Encoding…\n\(debugDescription)", file: file, line: line)
        XCTAssertTrue(item.waitForEnabled(timeout: 5), "Text Encoding… is off\n\(debugDescription)", file: file, line: line)
        item.tap()
        XCTAssertTrue(navigationBars["Text Encoding"].waitForExistence(timeout: 5),
                      "no Text Encoding sheet\n\(debugDescription)", file: file, line: line)

        // The sheet's list, found by its first row; the checked rows (Automatic, Russian (DOS)) and
        // the chosen ones (Russian (DOS), Cyrillic (Windows)) are rows 1-4, on screen at the top.
        let list = collectionViews.containing(NSPredicate(format: "label == %@", "Automatic")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "no Automatic\n\(debugDescription)", file: file, line: line)
        let titles = Self.textEncodingTitles
        XCTAssertEqual(titles.count, 12, "\(titles)", file: file, line: line)
        XCTAssertTrue(titles.contains(title) && titles.contains(current), "\(title), \(current) not in \(titles)",
                      file: file, line: line)

        // At the top, before any scrolling: the checked row reads as selected (`.isSelected`), and it
        // is the only one; then the screenshot.
        let selected = list.descendants(matching: .any).matching(NSPredicate(format: "selected == true"))
        let selectedTitles = Set(selected.allElementsBoundByIndex.map(\.label).filter { titles.contains($0) })
        XCTAssertEqual(selectedTitles, [current], "Text Encoding's selected row is not \(current)\n\(debugDescription)",
                       file: file, line: line)
        XCTContext.runActivity(named: "Text Encoding sheet | \(list.cells.count) rows") {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "text-encoding-sheet"
            shot.lifetime = .keepAlways
            $0.add(shot)
        }

        // Each of the 12 rows has its title, whatever element type (button, cell or text) carries the
        // label, and can be brought on screen. The titles are in list order, so the list only ever
        // scrolls down; at most `maxSwipes` slow swipes in all. A row drawn blank has no title to
        // find however far the list scrolls.
        let maxSwipes = 6
        var swipes = 0
        for rowTitle in titles {
            let row = list.descendants(matching: .any).matching(NSPredicate(format: "label == %@", rowTitle)).firstMatch
            while !(row.exists && row.isHittable) && swipes < maxSwipes {
                list.swipeUp(velocity: .slow)
                swipes += 1
            }
            XCTAssertTrue(row.exists, "Text Encoding has no row titled \(rowTitle) after \(swipes) swipes\n\(debugDescription)",
                          file: file, line: line)
            XCTAssertTrue(row.isHittable,
                          "Text Encoding's \(rowTitle) is not on screen after \(swipes) swipes\n\(debugDescription)",
                          file: file, line: line)
        }

        // Back up to the choice (also bounded).
        let choice = list.buttons[title].firstMatch
        var swipesBack = 0
        while !(choice.exists && choice.isHittable) && swipesBack < maxSwipes {
            list.swipeDown(velocity: .slow)
            swipesBack += 1
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(title)\n\(debugDescription)", file: file, line: line)
        XCTAssertTrue(choice.isHittable, "\(title) is not on screen\n\(debugDescription)", file: file, line: line)
        XCTAssertTrue(choice.isEnabled, "\(title) is off\n\(debugDescription)", file: file, line: line)
        choice.tap()
        XCTAssertTrue(navigationBars["Text Encoding"].waitForNonExistence(timeout: 5),
                      "the Text Encoding sheet stayed\n\(debugDescription)", file: file, line: line)
    }

    /// Waits for Text Encoding's progress sheet ("Reading “…”…") to go, if it is up.
    func waitForTextEncodingProgressToGo(file: StaticString = #filePath, line: UInt = #line) {
        let reading = staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading")).firstMatch
        XCTAssertTrue(reading.waitForNonExistence(timeout: 10), "the progress sheet stayed\n\(debugDescription)",
                      file: file, line: line)
    }
}
