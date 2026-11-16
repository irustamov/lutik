import Foundation
import Testing
import UniformTypeIdentifiers
import KernirCore
import os
@testable import Kernir

/// The row menu's Open With and Share: which rows they take, when they can run, and Open
/// With's apps, with the system's app lookups faked.
struct ArchiveRowMenuTests {
    private static func app(_ name: String) -> URL {
        URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
    }

    private static let textEdit = app("TextEdit")
    private static let bbedit = app("BBEdit")
    private static let preview = app("Preview")
    private static let xcode = app("Xcode")
    private static let safari = app("Safari")
    private static let markdown = UTType(filenameExtension: "md") ?? .data

    /// Text opens in TextEdit (default), BBEdit and Xcode; PDF in Preview (default), Safari and BBEdit;
    /// Markdown in Xcode (default), TextEdit and BBEdit.
    private static func apps(for type: UTType) -> [URL] {
        switch type {
        case .plainText: [xcode, textEdit, bbedit]
        case .pdf: [safari, preview, bbedit]
        case markdown: [textEdit, xcode, bbedit]
        default: []
        }
    }

    private static func defaultApp(for type: UTType) -> URL? {
        switch type {
        case .plainText: textEdit
        case .pdf: preview
        case markdown: xcode
        default: nil
        }
    }

    private static func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    private static func file(_ path: String) -> ArchiveRowMenu.Row { .init(path: path, isDirectory: false) }
    private static func folder(_ path: String) -> ArchiveRowMenu.Row { .init(path: path, isDirectory: true) }

    private static func menu(_ rows: [ArchiveRowMenu.Row], canRun: Bool = true) -> ArchiveRowMenu {
        ArchiveRowMenu(rows: rows, canRun: canRun, appsToOpen: apps(for:), defaultApp: defaultApp(for:), name: name)
    }

    @Test func oneFileListsItsDefaultAppFirstThenTheOthersByName() {
        let menu = Self.menu([Self.file("docs/a.txt")])
        #expect(menu.showsOpenWith)
        #expect(menu.canOpen)
        #expect(menu.openWithPaths == ["docs/a.txt"])
        #expect(menu.defaultApp == Self.textEdit)
        #expect(menu.apps == [Self.textEdit, Self.bbedit, Self.xcode])
        #expect(menu.otherApps == [Self.bbedit, Self.xcode])
        #expect(menu.showsSeparatorAfterDefault)
    }

    @Test func aFolderAloneHasNoOpenWithButCanBeShared() {
        let menu = Self.menu([Self.folder("docs")])
        #expect(!menu.showsOpenWith)
        #expect(menu.openWithPaths.isEmpty)
        #expect(menu.apps.isEmpty)
        #expect(menu.sharePaths == ["docs"])
        #expect(menu.canShare)
    }

    @Test func foldersInASelectionAreSkippedByOpenWith() {
        let menu = Self.menu([Self.folder("docs"), Self.file("a.txt"), Self.file("b.txt")])
        #expect(menu.openWithPaths == ["a.txt", "b.txt"])
        #expect(menu.defaultApp == Self.textEdit)
        #expect(menu.apps == [Self.textEdit, Self.bbedit, Self.xcode])
    }

    @Test func filesOfDifferentKindsListOnlyTheAppsThatOpenThemAll() {
        let menu = Self.menu([Self.file("a.txt"), Self.file("b.pdf")])
        #expect(menu.openWithPaths == ["a.txt", "b.pdf"])
        #expect(menu.apps == [Self.bbedit])
        // Their default apps differ: none leads, and no separator.
        #expect(menu.defaultApp == nil)
        #expect(menu.otherApps == [Self.bbedit])
        #expect(!menu.showsSeparatorAfterDefault)
    }

    @Test func aDefaultAppSharedByEveryKindLeads() {
        let menu = Self.menu([Self.file("a.txt"), Self.file("notes/b.txt")])
        #expect(menu.defaultApp == Self.textEdit)
        #expect(menu.apps.first == Self.textEdit)
    }

    @Test func aDefaultAppThatIsNotEveryFilesDefaultDoesNotLead() {
        // TextEdit and Xcode open both kinds, but each is the default of only one.
        let menu = Self.menu([Self.file("a.txt"), Self.file("b.md")])
        #expect(menu.defaultApp == nil)
        #expect(menu.apps == [Self.bbedit, Self.textEdit, Self.xcode])
    }

    @Test func filesWithNoCommonAppListNoApps() {
        let menu = Self.menu([Self.file("a.txt"), Self.file("b.unknownkind")])
        #expect(menu.showsOpenWith)
        #expect(menu.apps.isEmpty)
        #expect(menu.defaultApp == nil)
        // Other… still lets the user pick one.
        #expect(menu.canOpen)
    }

    @Test func anAppListedTwiceOrUnderAnotherSpellingShowsOnce() {
        let alias = URL(fileURLWithPath: "/Applications/./TextEdit.app", isDirectory: true)
        let menu = ArchiveRowMenu(rows: [Self.file("a.txt")], canRun: true,
                                  appsToOpen: { _ in [Self.textEdit, alias, Self.bbedit, Self.bbedit] },
                                  defaultApp: { _ in Self.textEdit }, name: Self.name)
        #expect(menu.apps == [Self.textEdit, Self.bbedit])
    }

    @Test func shareTakesEveryRowExceptOnesInsideASharedFolder() {
        let menu = Self.menu([Self.folder("docs"), Self.file("docs/a.txt"), Self.file("z.pdf"), Self.file("b.txt")])
        #expect(menu.sharePaths == ["docs", "z.pdf", "b.txt"])
        #expect(menu.canShare)
    }

    @Test func nothingRunsWhileAnOperationRunsButBothStayShown() {
        let menu = Self.menu([Self.file("a.txt")], canRun: false)
        #expect(menu.showsOpenWith)
        #expect(!menu.canOpen)
        #expect(!menu.canShare)
        // The apps are still listed, so the disabled submenu shows what it would offer.
        #expect(menu.apps == [Self.textEdit, Self.bbedit, Self.xcode])
    }

    @Test func noRowsOffersNothing() {
        let menu = Self.menu([])
        #expect(!menu.showsOpenWith)
        #expect(!menu.canOpen)
        #expect(!menu.canShare)
        #expect(menu.sharePaths.isEmpty)
    }

    @Test func eachKindIsLookedUpOnce() {
        var lookups: [UTType] = []
        _ = ArchiveRowMenu(rows: [Self.file("a.txt"), Self.file("b.txt"), Self.file("c.txt")], canRun: true,
                           appsToOpen: { lookups.append($0); return Self.apps(for: $0) },
                           defaultApp: Self.defaultApp(for:), name: Self.name)
        #expect(lookups == [.plainText])
    }

    /// Select All on a large archive: the menu looks up each extension's type once, whatever its case, and
    /// each type's apps once, not once per file.
    @Test func manyFilesLookUpEachExtensionAndTypeOnce() {
        let rows = (0..<30_000).map { index in
            Self.file("folder\(index % 7)/file\(index).\(["txt", "TXT", "pdf", "md"][index % 4])")
        }
        var typeLookups: [String] = []
        var appLookups: [UTType] = []
        var defaultLookups: [UTType] = []
        let menu = ArchiveRowMenu(rows: rows, canRun: true,
                                  type: { typeLookups.append($0); return ArchiveRowMenu.type($0) },
                                  appsToOpen: { appLookups.append($0); return Self.apps(for: $0) },
                                  defaultApp: { defaultLookups.append($0); return Self.defaultApp(for: $0) },
                                  name: Self.name)
        #expect(typeLookups.sorted() == ["md", "pdf", "txt"])
        #expect(appLookups.count == 3)
        #expect(Set(appLookups) == [.plainText, .pdf, Self.markdown])
        // A default is asked for only while every type so far shares one: Markdown's (Xcode) isn't PDF's
        // (Preview), so text's is never asked.
        #expect(defaultLookups == [Self.markdown, .pdf])
        #expect(menu.openWithPaths.count == 30_000)
        #expect(menu.apps == [Self.bbedit])
        #expect(menu.defaultApp == nil)
    }

    /// Once no app and no default is common to the types so far, the rest are not looked up: the system's
    /// lookups are slow.
    @Test func appLookupsStopOnceNoAppOrDefaultIsLeft() {
        var appLookups: [UTType] = []
        var defaultLookups: [UTType] = []
        func menu(_ rows: [ArchiveRowMenu.Row]) -> ArchiveRowMenu {
            ArchiveRowMenu(rows: rows, canRun: true,
                           appsToOpen: { appLookups.append($0); return Self.apps(for: $0) },
                           defaultApp: { defaultLookups.append($0); return Self.defaultApp(for: $0) },
                           name: Self.name)
        }
        // The first type ("", data) has no app and no default: nothing else is asked.
        let first = menu([Self.file("README"), Self.file("a.txt"), Self.file("b.pdf"), Self.file("c.md")])
        #expect(appLookups == [.data])
        #expect(defaultLookups == [.data])
        #expect(first.apps.isEmpty)
        #expect(first.defaultApp == nil)
        #expect(first.showsOpenWith)

        // Midway: Markdown, then a kind no app opens; PDF and text are never asked.
        appLookups = []
        defaultLookups = []
        let unknown = ArchiveRowMenu.type("nokind")
        let midway = menu([Self.file("a.md"), Self.file("b.nokind"), Self.file("c.pdf"), Self.file("d.txt")])
        #expect(appLookups == [Self.markdown, unknown])
        #expect(defaultLookups == [Self.markdown, unknown])
        #expect(midway.apps.isEmpty)
        #expect(midway.defaultApp == nil)
    }

    @Test func aFileWithNoExtensionIsData() {
        #expect(ArchiveRowMenu.type("") == .data)
        #expect(ArchiveRowMenu.type("txt") == .plainText)
    }

    /// Share's picker shows at the first of the menu's rows the table shows.
    @Test func thePickerAnchorsOnTheFirstRowOfTheMenusItems() {
        let rows = ["docs", "docs/a.txt", "b.txt", "c.txt"].map { ArchiveTableDragSelection.Row(path: $0, level: 0) }
        #expect(ArchiveActions.firstRow(of: ["c.txt", "docs/a.txt"], in: rows, rowCount: 4) == 1)
        #expect(ArchiveActions.firstRow(of: ["c.txt"], in: rows, rowCount: 4) == 3)
        // Rows that don't match the table: no row, rather than the wrong one.
        #expect(ArchiveActions.firstRow(of: ["c.txt"], in: rows, rowCount: 5) == nil)
        #expect(ArchiveActions.firstRow(of: ["gone.txt"], in: rows, rowCount: 4) == nil)
    }

    /// The anchor taken when Share was chosen, shown once the items are extracted: kept while it still shows
    /// in the table, the table's visible part once scrolled out of it.
    @Test func thePickerFallsBackToTheVisiblePartWhenItsRowScrolledAway() {
        let visible = NSRect(x: 0, y: 200, width: 400, height: 300)
        let row = NSRect(x: 0, y: 220, width: 400, height: 20)
        #expect(ArchiveActions.shownRect(row, visible: visible) == row)
        let away = NSRect(x: 0, y: 40, width: 400, height: 20)
        #expect(ArchiveActions.shownRect(away, visible: visible) == visible)
        #expect(ArchiveActions.shownRect(.zero, visible: visible) == visible)
    }
}

/// The row menu's Open With and Share on a real `ArchiveActions`: every chosen file goes,
/// extracted through the temporary-file path, with no other app launched and no picker shown.
@Suite(.serialized) @MainActor
struct ArchiveActionsRowMenuTests {
    private static func entry(_ path: String, isDirectory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: isDirectory, size: 1, compressedSize: 1, modificationDate: nil)
    }

    private static let entries = [entry("docs", isDirectory: true), entry("docs/a.txt"), entry("b.txt")]

    private func wait(for condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func withActions(reader: (any ArchiveReading)? = nil,
                             _ body: (ArchiveActions, ArchiveModel) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveActionsRowMenuTests-\(UUID().uuidString)", isDirectory: true)
        let openedFiles = OpenedFiles(in: folder)
        let model = ArchiveModel(reader: reader ?? FakeReader(entries: Self.entries), undoManager: nil,
                                 openedFiles: openedFiles)
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = model
        let actions = ArchiveActions(document: document)
        defer {
            withExtendedLifetime(document) {}
            actions.cancelAll()
            openedFiles.close()
            model.removeTemporaryFiles()
            try? FileManager.default.removeItem(at: folder)
        }
        try await body(actions, model)
    }

    @Test func openWithOpensEveryFileInTheChosenAppAtOnceInTheWindowsOrder() async throws {
        let app = URL(fileURLWithPath: "/Applications/TextEdit.app", isDirectory: true)
        try await withActions { actions, _ in
            try await LaunchRecorder.recording { launched in
                try await PresentedErrors.expectingNone {
                    let menu = actions.rowMenu(for: ["docs", "docs/a.txt", "b.txt"])
                    #expect(menu.openWithPaths == ["b.txt", "docs/a.txt"])
                    await actions.open(menu.openWithPaths, withApplicationAt: app)?.value
                    // One launch for all of them, as Finder opens a selection.
                    #expect(launched.batches.count == 1)
                    #expect(launched.batches.first?.app == app)
                    let contents = try launched.files.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
                    // The folder's file first, as the window shows it.
                    #expect(contents == ["docs/a.txt", "b.txt"])
                }
            }
        }
    }

    /// What an `OpenWithReader` was asked to extract, for assertions while its task waits.
    private final class ExtractionProbe: Sendable {
        private let paths = OSAllocatedUnfairLock(initialState: [String]())
        var started: [String] { paths.withLock { $0 } }
        func start(_ path: String) { paths.withLock { $0.append(path) } }
    }

    private struct OpenFailure: Error {}

    /// A `FakeReader` whose extraction of `failing` paths throws `OpenFailure`, and of `suspending` paths waits
    /// until its task is cancelled (two minutes at most), then throws `CancellationError`.
    private struct OpenWithReader: ArchiveReading {
        let base: FakeReader
        let probe: ExtractionProbe
        var failing: Set<String> = []
        var suspending: Set<String> = []

        var url: URL { base.url }
        var format: ArchiveFormat { base.format }
        var entries: [ArchiveEntry] { base.entries }
        var isEncrypted: Bool { base.isEncrypted }

        func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
            try await base.extract(paths, to: directory, progress: progress)
        }

        func extractToTemporaryFile(_ path: String) async throws -> URL {
            probe.start(path)
            if failing.contains(path) { throw OpenFailure() }
            if suspending.contains(path) {
                try await Task.sleep(for: .seconds(120))
                throw ArchiveError.io("not cancelled")
            }
            return try await base.extractToTemporaryFile(path)
        }
    }

    /// The `Kernir-<UUID>` folders Open With's copies are in.
    private static func copyFolders(of model: ArchiveModel) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: model.openedFiles.parent.path)) ?? []
        return names.filter { $0.hasPrefix("Kernir-") }
    }

    /// A close or `cancelAll()` while Open With copies its files: the copies made go, and nothing opens.
    @Test(.timeLimit(.minutes(1)))
    func openWithCancelledDiscardsItsCopiesAndLaunchesNothing() async throws {
        let app = URL(fileURLWithPath: "/Applications/TextEdit.app", isDirectory: true)
        let probe = ExtractionProbe()
        try await withActions(reader: OpenWithReader(base: FakeReader(entries: Self.entries), probe: probe,
                                                    suspending: ["b.txt"])) { actions, model in
            await LaunchRecorder.recording { launched in
                await PresentedErrors.expectingNone {
                    let task = actions.open(["b.txt", "docs/a.txt"], withApplicationAt: app)
                    // The folder's file was copied first; b.txt's extraction waits.
                    await wait { probe.started.count == 2 }
                    #expect(probe.started == ["docs/a.txt", "b.txt"])
                    #expect(model.openedFiles.files.count == 1)
                    actions.cancelAll()
                    await task?.value
                }
                #expect(launched.batches.isEmpty)
                #expect(model.openedFiles.files.isEmpty)
                #expect(Self.copyFolders(of: model).isEmpty)
            }
        }
    }

    /// A file that can't be copied is left out: the rest open in one launch, then one error shows.
    @Test func openWithLaunchesTheRestThenShowsOneErrorWhenSomeFilesFail() async throws {
        let app = URL(fileURLWithPath: "/Applications/TextEdit.app", isDirectory: true)
        let probe = ExtractionProbe()
        try await withActions(reader: OpenWithReader(base: FakeReader(entries: Self.entries), probe: probe,
                                                    failing: ["docs/a.txt"])) { actions, _ in
            try await LaunchRecorder.recording { launched in
                try await PresentedErrors.collecting { presented in
                    await actions.open(["b.txt", "docs/a.txt"], withApplicationAt: app)?.value
                    #expect(probe.started == ["docs/a.txt", "b.txt"])
                    #expect(launched.batches.count == 1)
                    #expect(launched.batches.first?.app == app)
                    let contents = try launched.files.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
                    #expect(contents == ["b.txt"])
                    #expect(presented.errors.count == 1)
                    _ = try #require(presented.errors.first as? OpenFailure)
                }
            }
        }
    }

    /// Which folders Share deletes once their copies are made: only
    /// `<temporary folder>/Kernir-<UUID>`, holding the archive's own folder extracted at its path.
    @Test func shareDeletesOnlyTheFolderItExtracted() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveActionsRowMenuTests-guard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let extraction = base.appendingPathComponent("Kernir-\(UUID().uuidString)", isDirectory: true)
        func local(_ parts: String...) -> URL {
            parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        }
        func folder(_ local: URL, path: String, isDirectory: Bool = true, isPendingAddition: Bool = false) -> URL? {
            ArchiveActions.extractedFolder(of: local, path: path, isDirectory: isDirectory,
                                           isPendingAddition: isPendingAddition, temporaryDirectory: base)
        }
        let shared = extraction.appendingPathComponent("docs/sub", isDirectory: true)
        let pending = local("Kernir-\(UUID().uuidString)", "docs", "sub")
        let userFolder = local("Users", "someone", "sub")
        let file = local("Kernir-\(UUID().uuidString)", "docs", "a.txt")
        let readerCache = local("Kernir", UUID().uuidString, "docs")
        let nestedClone = local("Kernir-\(UUID().uuidString)", "sub")
        let notKernir = local("Other-\(UUID().uuidString)", "docs")
        let notUUID = local("Kernir-notauuid", "docs")
        let elsewhere = local("elsewhere", "Kernir-\(UUID().uuidString)", "docs")
        for url in [shared, pending, userFolder, readerCache, nestedClone, notKernir, notUUID, elsewhere] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: file)

        #expect(folder(shared, path: "docs/sub")?.path == extraction.path)
        #expect(folder(pending, path: "docs/sub", isPendingAddition: true) == nil)
        #expect(folder(userFolder, path: "sub", isPendingAddition: true) == nil)
        #expect(folder(file, path: "docs/a.txt", isDirectory: false) == nil)
        #expect(folder(readerCache, path: "docs") == nil)
        #expect(folder(nestedClone, path: "docs/sub") == nil)
        #expect(folder(notKernir, path: "docs") == nil)
        #expect(folder(notUUID, path: "docs") == nil)
        #expect(folder(elsewhere, path: "docs") == nil)
        #expect(folder(extraction, path: "") == nil)

        let all: [(URL, String, Bool, Bool)] = [
            (shared, "docs/sub", true, false), (pending, "docs/sub", true, true), (userFolder, "sub", true, true),
            (file, "docs/a.txt", false, false), (readerCache, "docs", true, false),
            (nestedClone, "docs/sub", true, false), (notKernir, "docs", true, false), (notUUID, "docs", true, false),
            (elsewhere, "docs", true, false),
        ]
        let doomed = all.compactMap { folder($0.0, path: $0.1, isDirectory: $0.2, isPendingAddition: $0.3) }
        await ArchiveActions.removeExtractedFolders(doomed).value
        #expect(!FileManager.default.fileExists(atPath: extraction.path))
        for url in [pending, userFolder, file, readerCache, nestedClone, notKernir, notUUID, elsewhere] {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.path) was deleted")
        }
    }

    /// A fake `makeShareCopy`: copies into `copies`, records the names and sources, throws for `failing`
    /// names (`ShareFailure`, or what `failure` gives), and waits at `gate` while it is closed. Its picker
    /// records the files, and is dismissed at once unless `dismissesPicker` is false (`dismissals` then).
    @MainActor
    private final class ShareCopies {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveActionsRowMenuTests-share-\(UUID().uuidString)", isDirectory: true)
        var named: [String] = []
        var sources: [URL] = []
        var shown: [[URL]] = []
        var failing: Set<String> = []
        var failure: any Error = ShareFailure()
        var isGateOpen = true
        var dismissesPicker = true
        var dismissals: [@MainActor () -> Void] = []

        func install(on actions: ArchiveActions) {
            actions.makeShareCopy = { [self] file, name in
                named.append(name)
                sources.append(file)
                // Not cancellable: the job must see its cancellation once the copy returns.
                while !isGateOpen { try? await Task.sleep(for: .milliseconds(5)) }
                if failing.contains(name) { throw failure }
                let target = folder.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: target)
                return target
            }
            actions.showSharePicker = { [self] files, _, dismissed in
                shown.append(files)
                if dismissesPicker { dismissed() } else { dismissals.append(dismissed) }
            }
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private struct ShareFailure: Error {}

    @Test func shareHandsCopiesOfTheTopmostRowsToThePickerInTheWindowsOrder() async throws {
        let copies = ShareCopies()
        defer { copies.remove() }
        try await withActions { actions, _ in
            copies.install(on: actions)
            await PresentedErrors.expectingNone {
                let menu = actions.rowMenu(for: ["docs", "docs/a.txt", "b.txt"])
                #expect(menu.canShare)
                #expect(menu.sharePaths == ["docs", "b.txt"])
                await actions.share(menu.sharePaths)?.value
            }
            // The folder first, as the window shows it (not sorted by name).
            #expect(copies.named == ["docs", "b.txt"])
            #expect(copies.shown.count == 1)
            let files = copies.shown.first ?? []
            #expect(files.map(\.lastPathComponent) == ["docs", "b.txt"])
            let inFolder = files.first?.appendingPathComponent("a.txt")
            #expect(inFolder.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            // The folder's extraction went once its copy was made: repeated Shares leave no pile of them.
            let extracted = try #require(copies.sources.first)
            #expect(!FileManager.default.fileExists(atPath: extracted.path))
            #expect(!FileManager.default.fileExists(atPath: extracted.deletingLastPathComponent().path))
            // A file's extraction (the reader's cache) stays.
            #expect(copies.sources.count == 2)
            let fileExtracted = try #require(copies.sources.last)
            #expect(FileManager.default.fileExists(atPath: fileExtracted.path))
        }
    }

    @Test func cancelAllBeforeThePickerShowsNoPickerAndNoError() async throws {
        let copies = ShareCopies()
        defer { copies.remove() }
        try await withActions { actions, _ in
            copies.install(on: actions)
            copies.isGateOpen = false
            await PresentedErrors.expectingNone {
                let task = actions.share(["b.txt"])
                await wait { !copies.named.isEmpty }
                actions.cancelAll()
                copies.isGateOpen = true
                await task?.value
            }
            #expect(copies.named == ["b.txt"])
            #expect(copies.shown.isEmpty)
            #expect(!actions.isSharing)
        }
    }

    @Test func allItemsFailingShowsTheFirstError() async throws {
        let copies = ShareCopies()
        defer { copies.remove() }
        try await withActions { actions, _ in
            copies.install(on: actions)
            copies.failing = ["docs", "b.txt"]
            try await PresentedErrors.collecting { presented in
                await actions.share(["docs", "b.txt"])?.value
                #expect(copies.named == ["docs", "b.txt"])
                #expect(copies.shown.isEmpty)
                #expect(presented.errors.count == 1)
                _ = try #require(presented.errors.first as? ShareFailure)
            }
        }
    }

    @Test func someItemsFailingShowThePickerWithTheRestThenTheError() async throws {
        let copies = ShareCopies()
        defer { copies.remove() }
        try await withActions { actions, _ in
            copies.install(on: actions)
            copies.failing = ["docs"]
            copies.dismissesPicker = false
            try await PresentedErrors.collecting { presented in
                await actions.share(["docs", "b.txt"])?.value
                #expect(copies.shown.map { $0.map(\.lastPathComponent) } == [["b.txt"]])
                // Not over the picker: the error shows once it is dismissed.
                #expect(presented.errors.isEmpty)
                #expect(copies.dismissals.count == 1)
                for dismissed in copies.dismissals { dismissed() }
                #expect(presented.errors.count == 1)
                _ = try #require(presented.errors.first as? ShareFailure)
            }
        }
    }

    /// `makeShareCopy` throws `CancellationError` once the window closed: nothing shows, not even an error.
    @Test func aCancelledShareCopyPresentsNothing() async throws {
        let copies = ShareCopies()
        defer { copies.remove() }
        try await withActions { actions, _ in
            copies.install(on: actions)
            copies.failing = ["docs", "b.txt"]
            copies.failure = CancellationError()
            await PresentedErrors.expectingNone {
                await actions.share(["docs", "b.txt"])?.value
            }
            #expect(copies.shown.isEmpty)
            #expect(!actions.isSharing)
        }
    }

    /// One Share at a time: while one is prepared, the menu's Share… is disabled and another request is
    /// ignored; once its picker showed, Share runs again.
    @Test func aSecondShareWhileOneRunsIsIgnored() async throws {
        let copies = ShareCopies()
        defer { copies.remove() }
        try await withActions { actions, _ in
            copies.install(on: actions)
            copies.isGateOpen = false
            await PresentedErrors.expectingNone {
                let first = actions.share(["b.txt"])
                #expect(first != nil)
                #expect(actions.isSharing)
                #expect(!actions.rowMenu(for: ["b.txt"]).canShare)
                #expect(actions.share(["docs"]) == nil)
                copies.isGateOpen = true
                await first?.value
                #expect(!actions.isSharing)
                #expect(actions.rowMenu(for: ["b.txt"]).canShare)
                await actions.share(["docs"])?.value
            }
            #expect(copies.named == ["b.txt", "docs"])
            #expect(copies.shown.map { $0.map(\.lastPathComponent) } == [["b.txt"], ["docs"]])
        }
    }
}
