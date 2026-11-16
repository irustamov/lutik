import Testing
import AppKit
@testable import Kernir
import KernirCore

/// Takes AppKit's answer to `canClose(withDelegate:shouldClose:contextInfo:)`.
@MainActor
private final class CloseAnswers: NSObject {
    var answers: [Bool] = []

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        answers.append(shouldClose)
    }
}

/// Holds `OpenedFiles.copyItem` until released, then throws `CancellationError`: the open stops there,
/// so no file ever reaches another app.
private final class HeldCopy: @unchecked Sendable {
    private let lock = NSCondition()
    private var isStarted = false
    private var isReleased = false

    var started: Bool { lock.withLock { isStarted } }

    func copy(_ source: URL, _ destination: URL) throws {
        lock.withLock {
            isStarted = true
            while !isReleased { lock.wait() }
        }
        throw CancellationError()
    }

    func release() {
        lock.withLock {
            isReleased = true
            lock.broadcast()
        }
    }
}

/// A name encoding store in defaults of its own (`makeTestDefaults`), removed with it.
private final class ScratchStore {
    let suiteName: String
    private let defaults: UserDefaults
    let store: ArchiveNameEncodingStore

    init() {
        let made = makeTestDefaults("TextEncodingMenuTests")
        defaults = made.0
        suiteName = made.1
        store = ArchiveNameEncodingStore(defaults: defaults)
    }

    deinit {
        removeTestDefaults(defaults, suite: suiteName)
    }
}

/// View > Text Encoding. The documents read real legacy zips through KernirCore; none of them
/// uses `ArchiveDocument.engine`, which other suites swap. Errors are collected through
/// `PresentedErrors.collecting`, which holds the `ArchiveActions.presentError` seam across suites.
@Suite(.serialized) @MainActor
struct TextEncodingMenuTests {
    private let cp1251 = String.Encoding.windowsCP1251
    private let cp866 = String.Encoding.testCP866
    /// An ASCII folder and a Cyrillic one, each holding a Cyrillic-named file, stored as CP1251.
    private let paths = ["Docs/", "Docs/Отчёт.txt", "Папка/", "Папка/Отчёт за май.txt"]
    private let scratch = ScratchStore()

    private var action: Selector { #selector(ArchiveDocument.selectNameEncoding(_:)) }

    /// The 11 menu encodings, in this order: UTF-8, Windows Cyrillic (CP1251), DOS Russian
    /// (CP866), KOI8-R, Japanese (CP932), Simplified Chinese (GB 18030), Traditional Chinese (Big5), Korean
    /// (CP949), Western Windows (CP1252), DOS Latin US (CP437), Central European Windows (CP1250).
    private static let rulingOrder: [String.Encoding] = [
        .utf8, .windowsCP1251, cf(.dosRussian), cf(.KOI8_R), cf(.dosJapanese), cf(.GB_18030_2000), cf(.big5),
        cf(.dosKorean), .windowsCP1252, cf(.dosLatinUS), .windowsCP1250,
    ]

    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    /// A document showing `zip` read with `encoding`, keeping choices in the scratch store.
    private func makeDocument(_ zip: URL, _ encoding: ArchiveNameEncoding = .automatic) async throws
        -> ArchiveDocument {
        let document = ArchiveDocument()
        let model = ArchiveModel(reader: try await Archive.open(at: zip, nameEncoding: encoding),
                                 undoManager: document.undoManager)
        model.nameEncodingStore = scratch.store
        document.state.model = model
        return document
    }

    /// `path` as a CP866 reader shows the CP1251 bytes of `path`.
    private func cp866Reading(of path: String) -> String {
        String(data: path.data(using: cp1251)!, encoding: cp866)!.precomposedStringWithCanonicalMapping
    }

    private func makeZip() throws -> URL {
        try LegacyZip.write(paths, as: cp1251)
    }

    /// The submenu's items other than the separator.
    private func encodingItems() -> [NSMenuItem] {
        MainMenu.textEncodingMenu().items.filter { !$0.isSeparatorItem }
    }

    private func item(for encoding: ArchiveNameEncoding) throws -> NSMenuItem {
        try #require(encodingItems().first { ArchiveDocument.nameEncoding(of: $0) == encoding })
    }

    /// Validates every item; returns whether each is enabled and which ones are checked.
    private func validate(in document: ArchiveDocument) -> (enabled: [Bool], checked: [ArchiveNameEncoding]) {
        let items = encodingItems()
        let enabled = items.map { document.validateMenuItem($0) }
        return (enabled, items.filter { $0.state == .on }.map { ArchiveDocument.nameEncoding(of: $0) })
    }

    // MARK: - Menu

    @Test func submenuListsAutomaticThenTheChoices() {
        let menu = MainMenu.textEncodingMenu()

        #expect(menu.title == String(localized: "Text Encoding", table: "Shared"))
        #expect(menu.items.count == 2 + ArchiveNameEncoding.choices.count)
        #expect(menu.items[0].title == String(localized: "Automatic", table: "Shared"))
        #expect(menu.items[0].representedObject == nil)
        #expect(menu.items[1].isSeparatorItem)
        let choices = Array(menu.items.dropFirst(2))
        #expect(choices.map(\.title) == ArchiveNameEncodingTitleTests.expectedTitles)
        #expect(choices.map { ($0.representedObject as? NSNumber)?.uintValue }
            == ArchiveNameEncoding.choices.map(\.rawValue))
        // The 11 menu encodings, in their fixed order, stated here independently.
        #expect(ArchiveNameEncoding.choices == Self.rulingOrder)
        #expect(choices.map { ($0.representedObject as? NSNumber)?.uintValue } == Self.rulingOrder.map(\.rawValue))
        for item in [menu.items[0]] + choices {
            #expect(item.action == action)
            #expect(item.target == nil)
            #expect(item.keyEquivalent.isEmpty)
        }
        #expect(ArchiveDocument.nameEncoding(of: menu.items[0]) == .automatic)
        #expect(choices.map(ArchiveDocument.nameEncoding(of:)) == ArchiveNameEncoding.choices.map { .specific($0) })
    }

    @Test func viewMenuHasTheSubmenuBetweenToolbarAndFullScreen() throws {
        let menu = MainMenu.viewMenu()
        let index = try #require(menu.items.firstIndex { $0.submenu?.title == String(localized: "Text Encoding",
                                                                                        table: "Shared") })
        let item = menu.items[index]
        #expect(item.title == String(localized: "Text Encoding", table: "Shared"))
        // Not wired to a command of its own: in a running app AppKit gives a submenu's item `submenuAction:`.
        #expect(item.action == nil || item.action == #selector(NSMenu.submenuAction(_:)))
        #expect(menu.items[index - 1].isSeparatorItem && menu.items[index + 1].isSeparatorItem)
        #expect(menu.items.first?.action == #selector(NSWindow.toggleToolbarShown(_:)))
        #expect(menu.items.last?.action == #selector(NSWindow.toggleFullScreen(_:)))
    }

    // MARK: - Validation

    /// Nothing to reinterpret: no model, a new archive, or an archive without undeclared names.
    @Test func itemsAreDisabledWithoutLegacyNames() async throws {
        let locked = ArchiveDocument()
        let new = try ArchiveDocument(type: "public.zip-archive")
        let declared = ArchiveDocument()
        declared.state.model = ArchiveModel(reader: FakeReader(entries: SampleArchive().entries),
                                            undoManager: declared.undoManager)
        #expect(declared.model?.reader?.legacyNameEncoding == nil)

        for document in [locked, new, declared] {
            let (enabled, checked) = validate(in: document)
            #expect(enabled.allSatisfy { !$0 })
            #expect(checked == [.automatic])
            #expect(!document.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
    }

    /// Never while the document has unsaved changes.
    @Test func itemsAreDisabledWithUnsavedChanges() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = try await makeDocument(zip)
        #expect(validate(in: document).enabled.allSatisfy { $0 })

        document.updateChangeCount(.changeDone)
        #expect(document.isDocumentEdited)
        #expect(validate(in: document).enabled.allSatisfy { !$0 })
        #expect(!document.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))

        document.updateChangeCount(.changeCleared)
        #expect(validate(in: document).enabled.allSatisfy { $0 })
    }

    /// Nor while another operation's progress sheet is up, such as a save's.
    @Test func itemsAreDisabledWhileASaveRuns() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = try await makeDocument(zip)
        #expect(validate(in: document).enabled.allSatisfy { $0 })

        // As `save(to:ofType:for:completionHandler:)` puts it up.
        document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        #expect(validate(in: document).enabled.allSatisfy { !$0 })
        #expect(!document.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        document.selectNameEncoding(try item(for: .specific(cp866)))
        #expect(document.nameEncodingTask == nil)

        document.state.progress = nil
        #expect(validate(in: document).enabled.allSatisfy { $0 })
    }

    @Test func checkmarkIsOnTheRequestedEncoding() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        let automatic = try await makeDocument(zip)
        #expect(automatic.model?.reader?.legacyNameEncoding == cp1251)
        #expect(validate(in: automatic).checked == [.automatic])

        let manual = try await makeDocument(zip, .specific(cp866))
        #expect(validate(in: manual).checked == [.specific(cp866)])
    }

    // MARK: - Choosing

    /// The reopen renames entries, so a preview of the old listing ends with it; it would
    /// keep paths that name nothing now (Open With silently off, Share sharing the old name).
    @Test func choosingAnEncodingEndsThePreview() async throws {
        try await PresentedErrors.expectingNone {
            let zip = try makeZip()
            defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
            let document = try await makeDocument(zip)
            let actions = ArchiveActions(document: document)
            document.actions = actions
            let file = "Docs/Отчёт.txt"
            let extracted = zip.deletingLastPathComponent().appendingPathComponent("Отчёт.txt")
            document.state.previewEntries = [PreviewEntry(path: file, url: extracted)]
            document.state.previewURL = extracted
            #expect(actions.canToggleQuickLook)

            document.selectNameEncoding(try item(for: .specific(cp866)))
            await document.nameEncodingTask?.value

            #expect(document.model?.reader?.nameEncoding == .specific(cp866))
            #expect(document.state.previewURL == nil)
            #expect(!actions.hasRunningTasks)
        }
    }

    @Test func choosingAnEncodingRelistsKeepsExpandedFoldersAndClearsTheSelection() async throws {
        try await PresentedErrors.expectingNone {
            let zip = try makeZip()
            defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
            let document = try await makeDocument(zip)
            document.state.expanded = ["Docs", "Папка"]
            document.state.selection = ["Docs/Отчёт.txt"]

            document.selectNameEncoding(try item(for: .specific(cp866)))
            // One reopen at a time.
            #expect(validate(in: document).enabled.allSatisfy { !$0 })
            await document.nameEncodingTask?.value

            let model = try #require(document.model)
            #expect(model.reader?.nameEncoding == .specific(cp866))
            let folder = String(data: "Папка".data(using: cp1251)!, encoding: cp866)!.precomposedStringWithCanonicalMapping
            #expect(Set(model.children(of: "").map(\.name)) == ["Docs", folder])
            #expect(document.state.expanded == ["Docs"])
            #expect(document.state.selection.isEmpty)
            #expect(scratch.store.nameEncoding(for: zip) == .specific(cp866))
            #expect(document.nameEncodingTask == nil)
            #expect(validate(in: document).enabled.allSatisfy { $0 })
            #expect(validate(in: document).checked == [.specific(cp866)])

            // Automatic forgets the choice.
            document.selectNameEncoding(try item(for: .automatic))
            await document.nameEncodingTask?.value
            #expect(document.model?.reader?.nameEncoding == .automatic)
            #expect(document.model?.item(at: "Папка/Отчёт за май.txt") != nil)
            #expect(scratch.store.nameEncoding(for: zip) == .automatic)
        }
    }

    /// The reopen adopts a new listing, so nothing may change the archive while it
    /// runs. The progress sheet is up: adding, deleting, undo and redo are refused, and so is Save. Then the
    /// listing is the reopened one, with no edit and no undo step left over.
    @Test func editingAndSavingAreRefusedWhileTheReopenRuns() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let added = zip.deletingLastPathComponent().appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: added)
        let document = try await makeDocument(zip)
        // Opened from the file, as in the app.
        document.fileURL = zip
        document.fileType = "public.zip-archive"
        let controller = ArchiveWindowController(document: document, windowFrame: nil)
        // A window left open could show up in other suites' window checks.
        defer { controller.close() }
        let window = try #require(controller.window)
        let actions = try #require(document.actions)
        let saves = [#selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:))]
        func canSave(_ action: Selector) -> Bool {
            document.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        #expect(actions.canAdd)
        #expect(saves.allSatisfy(canSave))
        #expect(controller.windowWillReturnUndoManager(window) === document.undoManager)

        document.selectNameEncoding(try item(for: .specific(cp866)))

        #expect(document.state.progress != nil)
        #expect(!actions.canAdd && !actions.canRemove(["Docs"]))
        actions.add([added], to: "")
        actions.remove(["Docs"])
        #expect(document.model?.hasChanges == false)
        #expect(controller.windowWillReturnUndoManager(window) !== document.undoManager)
        #expect(!saves.contains(where: canSave))

        await document.nameEncodingTask?.value

        #expect(document.state.progress == nil)
        let model = try #require(document.model)
        #expect(model.reader?.nameEncoding == .specific(cp866))
        #expect(model.item(at: "Docs/" + cp866Reading(of: "Отчёт.txt")) != nil)
        #expect(!model.hasChanges && !document.isDocumentEdited)
        #expect(document.undoManager?.canUndo == false)
        #expect(actions.canAdd)
        #expect(controller.windowWillReturnUndoManager(window) === document.undoManager)
        #expect(saves.allSatisfy(canSave))
    }

    /// Extract waits for the reopen too. Started meanwhile, it would take over the progress
    /// sheet (the reopen's Cancel gone), and its end would let edits in while the reopen still reads; a
    /// queued folder panel would extract the selection's paths from before the reopen.
    @Test func extractingIsRefusedWhileTheReopenRuns() async throws {
        try await PresentedErrors.expectingNone {
            let zip = try makeZip()
            let folder = zip.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: folder) }
            let document = try await makeDocument(zip)
            document.fileURL = zip
            // No window: Extract next to the archive needs none.
            let actions = ArchiveActions(document: document)
            document.actions = actions
            let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(actions.canExtract)

            document.selectNameEncoding(try item(for: .specific(cp866)))
            let reopen = try #require(document.state.progress)
            #expect(!actions.canExtract)
            actions.extract(nextToArchive: true)

            #expect(document.state.progress?.id == reopen.id)
            #expect(!actions.hasRunningTasks)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == before)
            await document.nameEncodingTask?.value
            #expect(document.model?.reader?.nameEncoding == .specific(cp866))
            #expect(actions.canExtract)
        }
    }

    /// Nor do Open and Quick Look. A copy made from the listing before the reopen would be
    /// tracked under a name the reopen took away, as the copy of no item, and Update would add a duplicate.
    @Test func openingIsRefusedWhileTheReopenRuns() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = try await makeDocument(zip)
        let actions = ArchiveActions(document: document)
        document.actions = actions
        let model = try #require(document.model)
        // Should the gate fail, the open stops at the copy: no file reaches another app. Nor does
        // one get past it: `launch` only records, so TextEdit never opens for real.
        model.openedFiles.copyItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        // The launch lock comes before the PresentedErrors one (see LaunchRecorder).
        try await LaunchRecorder.recording { launched in
            let file = "Docs/Отчёт.txt"
            document.state.selection = [file]
            #expect(actions.canOpen([file]) && actions.canOpenSelection && actions.canToggleQuickLook)
            #expect(actions.canOpenFile(file))

            try await PresentedErrors.expectingNone {
                document.selectNameEncoding(try item(for: .specific(cp866)))
                #expect(document.state.progress != nil)
                #expect(!actions.canOpen([file]) && !actions.canOpenSelection && !actions.canToggleQuickLook)
                actions.open([file])
                actions.quickLook([file])
                // Nor the preview window's Open With, or Share's re-extract.
                #expect(!actions.canOpenFile(file))
                actions.openFile(file)
                actions.openFile(file, withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
                await #expect(throws: CancellationError.self) { try await actions.localFileURL(for: file) }
                #expect(!actions.hasRunningTasks)
                await document.nameEncodingTask?.value
            }

            #expect(model.reader?.nameEncoding == .specific(cp866))
            #expect(model.openedFiles.files.isEmpty)
            #expect(launched.files.isEmpty)
            #expect(document.state.previewURL == nil)
            let reread = "Docs/" + cp866Reading(of: "Отчёт.txt")
            #expect(actions.canOpen([reread]))
            #expect(actions.canOpenFile(reread))
        }
    }

    /// View > Text Encoding waits for a file being opened in another
    /// app. A reopen finishing before its copy is tracked would leave the copy under its old name.
    @Test func itemsAreDisabledWhileAFileIsBeingOpened() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = try await makeDocument(zip)
        let actions = ArchiveActions(document: document)
        document.actions = actions
        let model = try #require(document.model)
        let held = HeldCopy()
        // A throw before the release below would leave the copy thread waiting forever.
        defer { held.release() }
        model.openedFiles.copyItem = { try held.copy($0, $1) }
        #expect(validate(in: document).enabled.allSatisfy { $0 })

        try await PresentedErrors.expectingNone {
            actions.open(["Docs/Отчёт.txt"])
            for _ in 0..<1_000 where !held.started {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(held.started)
            #expect(actions.hasRunningTasks)
            #expect(validate(in: document).enabled.allSatisfy { !$0 })
            #expect(!document.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
            document.selectNameEncoding(try item(for: .specific(cp866)))
            #expect(document.nameEncodingTask == nil)
            #expect(document.state.progress == nil)

            held.release()
            for _ in 0..<1_000 where actions.hasRunningTasks {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        #expect(!actions.hasRunningTasks)
        #expect(model.openedFiles.files.isEmpty)
        #expect(model.reader?.nameEncoding == .automatic)
        #expect(validate(in: document).enabled.allSatisfy { $0 })
    }

    /// Closing during the reopen: `canClose` stops it first, so the
    /// opened files' review, and the save it may start, see the listing as it is; `close()` stops it too.
    /// Either way nothing is applied or remembered, and the close goes on.
    @Test(arguments: [false, true])
    func closingDuringTheReopenAppliesAndRemembersNothing(closesOutright: Bool) async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = try await makeDocument(zip)
        // AppKit doesn't retain the delegate, and may answer after `canClose` returns:
        // the catcher lives until the answer came or the wait gave up.
        let answers = CloseAnswers()
        defer { withExtendedLifetime(answers) {} }

        let presented = try await PresentedErrors.collecting { presented in
            document.selectNameEncoding(try item(for: .specific(cp866)))
            let task = try #require(document.nameEncodingTask)
            if closesOutright {
                document.close()
            } else {
                document.canClose(withDelegate: answers,
                                  shouldClose: #selector(CloseAnswers.document(_:shouldClose:contextInfo:)),
                                  contextInfo: nil)
            }
            #expect(task.isCancelled)
            await task.value
            if !closesOutright {
                // About two seconds at most.
                for _ in 0..<400 where answers.answers.isEmpty {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                #expect(answers.answers == [true])
                // Still no answer: one that comes later must not reach a freed catcher and crash the run.
                if answers.answers.isEmpty { _ = Unmanaged.passRetained(answers) }
            }
            return presented
        }

        #expect(presented.errors.isEmpty)
        #expect(document.model?.reader?.nameEncoding == .automatic)
        #expect(document.model?.item(at: "Папка/Отчёт за май.txt") != nil)
        #expect(scratch.store.nameEncoding(for: zip) == .automatic)
        #expect(document.state.progress == nil)
        #expect(document.nameEncodingTask == nil)
    }

    /// The progress sheet's Cancel stops the reopen: the listing stays, nothing is remembered or reported.
    @Test func cancellingTheReopenKeepsTheListing() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = try await makeDocument(zip)

        let presented = try await PresentedErrors.collecting { presented in
            document.selectNameEncoding(try item(for: .specific(cp866)))
            let cancel = try #require(document.state.progress?.cancel)
            cancel()
            await document.nameEncodingTask?.value
            return presented
        }

        #expect(presented.errors.isEmpty)
        #expect(document.state.progress == nil)
        #expect(document.model?.reader?.nameEncoding == .automatic)
        #expect(document.model?.item(at: "Папка/Отчёт за май.txt") != nil)
        #expect(scratch.store.nameEncoding(for: zip) == .automatic)
    }

    @Test func choosingTheCurrentEncodingDoesNothing() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = try await makeDocument(zip)
        document.state.selection = ["Docs/Отчёт.txt"]

        document.selectNameEncoding(try item(for: .automatic))

        #expect(document.nameEncodingTask == nil)
        #expect(document.state.selection == ["Docs/Отчёт.txt"])
    }

    @Test func choosingWithUnsavedChangesDoesNothing() async throws {
        let zip = try makeZip()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = try await makeDocument(zip)
        document.updateChangeCount(.changeDone)

        document.selectNameEncoding(try item(for: .specific(cp866)))

        #expect(document.nameEncodingTask == nil)
        #expect(document.model?.reader?.nameEncoding == .automatic)
    }

    /// The archive can't be read again: the listing stays, nothing is remembered, the error is shown.
    @Test func failedReopenKeepsTheListingAndReportsTheError() async throws {
        let zip = try makeZip()
        let document = try await makeDocument(zip)
        document.state.selection = ["Docs/Отчёт.txt"]
        try FileManager.default.removeItem(at: zip.deletingLastPathComponent())

        let presented = try await PresentedErrors.collecting { presented in
            document.selectNameEncoding(try item(for: .specific(cp866)))
            await document.nameEncodingTask?.value
            return presented
        }

        #expect(presented.errors.count == 1)
        #expect(document.model?.reader?.nameEncoding == .automatic)
        #expect(document.model?.item(at: "Папка/Отчёт за май.txt") != nil)
        #expect(document.state.selection == ["Docs/Отчёт.txt"])
        #expect(scratch.store.nameEncoding(for: zip) == .automatic)
    }
}
