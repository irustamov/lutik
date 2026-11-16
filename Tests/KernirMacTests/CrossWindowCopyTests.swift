import AppKit
import Testing
@testable import Kernir
import KernirCore

// Rows dragged from one archive window onto another's table are copied into that archive
// (`ArchiveActions.canCopyIn/copyIn`, `ArchiveTableDragAnchor.validateMove/acceptMove`): the source's model
// extracts them (`ArchiveClipboard.export`), the target adds them as one "Add" step. Hosted run.

private func file(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
}

/// The export folders (`<UUID>`) left in this process's `Kernir-Clipboard-<process>` parent in `directory`
/// (`ArchiveClipboard.exportParent(in:)`): the parent itself is held until quit, and stays.
private func exports(in directory: URL) -> [String] {
    let parent = ArchiveClipboard.exportParent(in: directory)
    return ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
        .filter { UUID(uuidString: $0) != nil }
}

/// What a test's export seam was asked, and what the replace alert was asked.
@MainActor
private final class CopyCalls {
    var exported: [[String]] = []
    var asked: [[String]] = []
    var onExport: (() -> Void)?
    /// Runs the real export outside the copy's task, as a reader that ignores its cancellation.
    var exportIgnoresCancellation = false
}

/// Two archive windows' worlds over real ZIPs built by hand (a few bytes): the source (docs/a.txt,
/// docs/sub/d.txt, README) and the target (inbox/README, keep.txt), its copies exported into `exports`.
@MainActor
private final class TwoArchives {
    static let sourceEntries: [(path: String, contents: String?)] = [
        ("docs/", nil), ("docs/a.txt", "a"), ("docs/sub/", nil), ("docs/sub/d.txt", "d"), ("README", "readme"),
    ]
    static let targetEntries: [(path: String, contents: String?)] = [
        ("inbox/", nil), ("inbox/README", "old readme"), ("keep.txt", "keep"),
    ]

    let directory: URL
    let exports: URL
    let sourceDocument: ArchiveDocument
    let source: ArchiveActions
    let sourceModel: ArchiveModel
    let targetDocument: ArchiveDocument
    let target: ArchiveActions
    let targetModel: ArchiveModel
    let targetReader: any ArchiveReading
    let undoManager: UndoManager
    let calls = CopyCalls()
    private let defaults: UserDefaults
    private let suite: String

    /// `password`: the source is an AES-256 ZIP of `secret.txt` ("hidden"), opened with it, instead.
    init(password: String? = nil) async throws {
        (defaults, suite) = makeTestDefaults("CrossWindowCopyTests")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossWindowCopyTests-\(UUID().uuidString)", isDirectory: true)
        exports = directory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        let sourceURL = directory.appendingPathComponent("source.zip")
        if let password {
            let secret = directory.appendingPathComponent("secret.txt")
            try Data("hidden".utf8).write(to: secret)
            try await ArchiveEngine.live.write(nil, ArchiveChangeSet(additions: [.init(sourceURL: secret,
                                                                                       destinationDirectory: "")]),
                                               .zip, sourceURL, ArchiveWriteOptions(encryption: .aes256,
                                                                                    password: password), nil)
        } else {
            try LiveMetadataSaveTests.storedZip(Self.sourceEntries).write(to: sourceURL)
        }
        sourceDocument = try ArchiveDocument(type: "public.zip-archive")
        sourceModel = ArchiveModel(reader: try await ArchiveEngine.live.open(sourceURL, password), undoManager: nil)
        sourceModel.password = password
        sourceModel.nameEncodingStore = ArchiveNameEncodingStore(defaults: defaults)
        sourceDocument.state.model = sourceModel
        source = ArchiveActions(document: sourceDocument)
        sourceDocument.actions = source

        let targetURL = directory.appendingPathComponent("target.zip")
        try LiveMetadataSaveTests.storedZip(Self.targetEntries).write(to: targetURL)
        targetReader = try await ArchiveEngine.live.open(targetURL, nil)
        // The document's own manager grouping by event, as in a window: the add runs late, from a task.
        targetDocument = try ArchiveDocument(type: "public.zip-archive")
        undoManager = try #require(targetDocument.undoManager)
        undoManager.groupsByEvent = true
        targetModel = ArchiveModel(reader: targetReader, undoManager: undoManager)
        targetModel.nameEncodingStore = ArchiveNameEncodingStore(defaults: defaults)
        targetDocument.state.model = targetModel
        target = ArchiveActions(document: targetDocument)
        targetDocument.actions = target
        let (exports, calls) = (exports, calls)
        target.copier.export = { paths, model, progress in
            calls.exported.append(paths)
            calls.onExport?()
            if calls.exportIgnoresCancellation {
                // An unstructured task does not inherit the copy task's cancellation.
                return try await Task { @MainActor in
                    try await ArchiveClipboard.export(paths, from: model, in: exports, progress: progress)
                }.value
            }
            return try await ArchiveClipboard.export(paths, from: model, in: exports, progress: progress)
        }
    }

    func close() {
        while undoManager.groupingLevel > 0 { undoManager.endUndoGrouping() }
        sourceModel.removeTemporaryFiles()
        targetModel.removeTemporaryFiles()
        // Releases the export parent this process holds in `exports` (its lock) before the folder goes.
        ArchiveClipboard.removeAllExports(in: exports)
        removeTestDefaults(defaults, suite: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The target's changes saved to a new ZIP and reopened: its file contents by path.
    func savedContents() async throws -> [String: String] {
        #expect(targetModel.saveProblem(as: .zip, split: false) == nil)
        let savedURL = directory.appendingPathComponent("saved-\(UUID().uuidString).zip")
        try await ArchiveEngine.live.write(targetReader, targetModel.saveChanges(as: .zip), .zip, savedURL,
                                           targetModel.saveOptions, nil)
        let saved = try await ArchiveEngine.live.open(savedURL, nil)
        let out = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await saved.extract(nil, to: out, progress: nil)
        var contents: [String: String] = [:]
        for entry in saved.entries where !entry.isDirectory {
            contents[entry.path] = (try? Data(contentsOf: out.appendingPathComponent(entry.path)))
                .map { String(decoding: $0, as: UTF8.self) }
        }
        return contents
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct CrossWindowCopyTests {
    private var addActionName: String { String(localized: "Add", table: "Shared") }

    @Test func onlyFromAnotherWindowIntoAnEditableFolderOfThisOne() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        let (source, target) = (world.source, world.target)

        #expect(ArchiveActions.forMoveToken(source.moveToken) === source)
        #expect(ArchiveActions.forMoveToken(UUID().uuidString) == nil)
        #expect(target.canCopyIn(from: source, paths: ["docs", "README"], into: "inbox"))
        #expect(target.canCopyIn(from: source, paths: ["README"], into: ""))
        #expect(target.canCopyIn(["README"], fromMoveToken: source.moveToken, into: "inbox"))
        // A drag inside one window moves; never a copy from itself.
        #expect(!target.canCopyIn(from: target, paths: ["keep.txt"], into: "inbox"))
        #expect(!target.canCopyIn(["keep.txt"], fromMoveToken: target.moveToken, into: "inbox"))
        // A window gone, an item gone, a folder that isn't one.
        #expect(!target.canCopyIn(["README"], fromMoveToken: UUID().uuidString, into: "inbox"))
        #expect(!target.canCopyIn(from: source, paths: ["missing"], into: "inbox"))
        #expect(!target.canCopyIn(from: source, paths: [], into: "inbox"))
        #expect(!target.canCopyIn(from: source, paths: ["README"], into: "keep.txt"))
        #expect(!target.canCopyIn(from: source, paths: ["README"], into: "nowhere"))
        // A source window closed (`ArchiveDocument.close` sets `isClosed`), and a job in either window.
        let closedDocument = try ArchiveDocument(type: "public.zip-archive")
        closedDocument.state.model = ArchiveModel(reader: FakeReader(entries: [file("README")]), undoManager: nil)
        let closed = ArchiveActions(document: closedDocument)
        closedDocument.actions = closed
        #expect(target.canCopyIn(from: closed, paths: ["README"], into: "inbox"))
        closedDocument.close()
        #expect(!target.canCopyIn(from: closed, paths: ["README"], into: "inbox"))
        world.sourceDocument.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        #expect(!target.canCopyIn(from: source, paths: ["README"], into: "inbox"))
        world.sourceDocument.state.progress = nil
        world.targetDocument.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        #expect(!target.canCopyIn(from: source, paths: ["README"], into: "inbox"))
        #expect(target.copyIn(from: source, paths: ["README"], into: "inbox") == nil)
        world.targetDocument.state.progress = nil
        #expect(world.calls.exported.isEmpty)
    }

    @Test func notIntoAReadOnlyArchive() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = ArchiveModel(reader: FakeReader(entries: [file("x")], format: .rar), undoManager: nil)
        let readOnly = ArchiveActions(document: document)
        defer { withExtendedLifetime(document) {} }

        #expect(!readOnly.canCopyIn(from: world.source, paths: ["README"], into: ""))
        #expect(readOnly.copyIn(from: world.source, paths: ["README"], into: "") == nil)
        #expect(!readOnly.copyIn(["README"], fromMoveToken: world.source.moveToken, into: ""))
        #expect(document.state.progress == nil)
    }

    @Test func aCopyLandsInTheTargetFolderAsOneAddStep() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        let (model, undoManager) = (world.targetModel, world.undoManager)

        let task = try #require(world.target.copyIn(from: world.source, paths: ["docs", "docs/a.txt"], into: "inbox"))
        #expect(world.targetDocument.state.progress?.title == ArchiveClipboard.progressTitle)
        await PresentedErrors.expectingNone { await task.value }

        #expect(world.targetDocument.state.progress == nil)
        // Ancestor wins: docs/a.txt goes with docs, not again beside it.
        #expect(world.calls.exported == [["docs", "docs/a.txt"]])
        #expect(model.item(at: "inbox/docs/a.txt") != nil && model.item(at: "inbox/docs/sub/d.txt") != nil)
        #expect(model.item(at: "inbox/a.txt") == nil && model.item(at: "docs") == nil)
        #expect(world.sourceModel.changes.isEmpty)
        #expect(undoManager.groupingLevel <= 1)
        #expect(undoManager.undoActionName == addActionName)

        // One Undo takes the whole copy back.
        undoManager.undo()
        #expect(model.item(at: "inbox/docs") == nil)
        #expect(model.changes.isEmpty)
        #expect(!undoManager.canUndo)

        undoManager.redo()
        let saved = try await world.savedContents()
        #expect(saved["inbox/docs/a.txt"] == "a")
        #expect(saved["inbox/docs/sub/d.txt"] == "d")
        #expect(saved["inbox/README"] == "old readme")
        #expect(saved["keep.txt"] == "keep")
    }

    @Test func replaceOnAConflictAddsTheCopy() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        let calls = world.calls
        world.target.copier.confirmReplace = { conflicts, answer in
            calls.asked.append(conflicts)
            answer(true)
        }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["README"], into: "inbox"))
        await PresentedErrors.expectingNone { await task.value }

        #expect(calls.asked == [["inbox/README"]])
        #expect(world.undoManager.undoActionName == addActionName)
        let saved = try await world.savedContents()
        #expect(saved["inbox/README"] == "readme")
    }

    @Test func stopOnAConflictAddsNothingAndRemovesTheCopies() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        let calls = world.calls
        world.target.copier.confirmReplace = { conflicts, answer in
            calls.asked.append(conflicts)
            answer(false)
        }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["README", "docs"], into: "inbox"))
        await PresentedErrors.expectingNone { await task.value }

        #expect(calls.asked == [["inbox/README"]])
        #expect(world.targetModel.changes.isEmpty)
        #expect(world.targetModel.item(at: "inbox/docs") == nil)
        #expect(exports(in: world.exports).isEmpty)
    }

    @Test func theSourceClosingMidCopySaysSoAddsNothingAndRemovesTheCopies() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        // The source window closes (`ArchiveDocument.close` cancels its actions) as the copy starts.
        world.calls.onExport = { [source = world.source] in source.cancelAll() }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["docs"], into: "inbox"))
        await PresentedErrors.collecting { presented in
            await task.value
            #expect(presented.errors.count == 1)
            #expect(presented.errors.first is ArchiveActions.CopySourceClosed)
        }

        #expect(world.calls.exported == [["docs"]])
        #expect(world.targetDocument.state.progress == nil)
        #expect(world.targetModel.changes.isEmpty)
        #expect(exports(in: world.exports).isEmpty)
        #expect(!world.target.hasRunningTasks)
    }

    @Test func theSourceClosingWhileTheExportFinishesSaysSoAddsNothingAndRemovesTheCopies() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        world.calls.exportIgnoresCancellation = true
        world.calls.onExport = { [source = world.source] in source.cancelAll() }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["docs"], into: "inbox"))
        await PresentedErrors.collecting { presented in
            await task.value
            #expect(presented.errors.count == 1)
            #expect(presented.errors.first is ArchiveActions.CopySourceClosed)
        }

        #expect(world.calls.exported == [["docs"]])
        #expect(world.targetDocument.state.progress == nil)
        #expect(world.targetModel.changes.isEmpty)
        #expect(exports(in: world.exports).isEmpty)
        #expect(!world.target.hasRunningTasks)
    }

    @Test func noSourceClosedAlertWhenTheTargetIsClosingToo() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        // Quit or Close All: the source closes, then this window (`ArchiveDocument.close`) while the copy runs.
        world.calls.onExport = { [source = world.source, document = world.targetDocument] in
            source.cancelAll()
            document.close()
        }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["docs"], into: "inbox"))
        await PresentedErrors.expectingNone { await task.value }

        #expect(world.calls.exported == [["docs"]])
        #expect(world.targetModel.changes.isEmpty)
        #expect(exports(in: world.exports).isEmpty)
    }

    @Test func theTargetClosingMidCopyIsSilentAndRemovesTheCopies() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        // The target window closes (`ArchiveDocument.close` cancels its actions) as the copy starts.
        world.calls.onExport = { [target = world.target] in target.cancelAll() }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["docs"], into: "inbox"))
        await PresentedErrors.expectingNone { await task.value }

        #expect(world.calls.exported == [["docs"]])
        #expect(world.targetDocument.state.progress == nil)
        #expect(world.targetModel.changes.isEmpty)
        #expect(exports(in: world.exports).isEmpty)
        #expect(!world.source.hasRunningTasks)
    }

    @Test func theSourceCountsTheCopyAsItsJobAndASaveThereDropsIt() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        let (source, sourceModel, sourceDocument) = (world.source, world.sourceModel, world.sourceDocument)
        var sawRunning = false
        // As the copy starts the source runs a job (Text Encoding waits for it), then adopts a save: as Copy
        // (`copyItems`), the copies are dropped without a word.
        world.calls.onExport = {
            sawRunning = source.hasRunningTasks && !sourceDocument.canChooseNameEncoding
            if let reader = sourceModel.reader { sourceModel.didSave(reader: reader) }
        }

        let task = try #require(world.target.copyIn(from: source, paths: ["docs"], into: "inbox"))
        #expect(source.hasRunningTasks)
        await PresentedErrors.expectingNone { await task.value }

        #expect(sawRunning)
        #expect(!source.hasRunningTasks)
        #expect(world.targetDocument.state.progress == nil)
        #expect(world.targetModel.changes.isEmpty)
        #expect(exports(in: world.exports).isEmpty)
    }

    @Test func aSheetThatReplacedTheTargetsKeepsItAndAddsNothing() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        // A save in the target puts its own sheet over the copy's as the copy starts.
        let saving = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        world.calls.onExport = { [state = world.targetDocument.state] in state.progress = saving }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["docs"], into: "inbox"))
        await PresentedErrors.expectingNone { await task.value }

        #expect(world.targetDocument.state.progress?.id == saving.id)
        #expect(world.targetModel.changes.isEmpty)
        #expect(exports(in: world.exports).isEmpty)
    }

    @Test func anEncryptedSourceCopiesWithItsPassword() async throws {
        let world = try await TwoArchives(password: "secret")
        defer { world.close() }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["secret.txt"], into: "inbox"))
        await PresentedErrors.expectingNone { await task.value }

        #expect(world.targetModel.item(at: "inbox/secret.txt") != nil)
        let saved = try await world.savedContents()
        #expect(saved["inbox/secret.txt"] == "hidden")
    }

    @Test func aReleasedWindowsTokenNoLongerResolves() throws {
        let document = try ArchiveDocument(type: "public.zip-archive")
        var token = ""
        autoreleasepool {
            let actions = ArchiveActions(document: document)
            token = actions.moveToken
            #expect(ArchiveActions.forMoveToken(token) === actions)
        }
        #expect(ArchiveActions.forMoveToken(token) == nil)
    }

    @Test func cancelIsSilentAndAddsNothing() async throws {
        let world = try await TwoArchives()
        defer { world.close() }
        // Cancel on the target's progress sheet as the copy starts.
        world.calls.onExport = { [state = world.targetDocument.state] in state.progress?.cancel?() }

        let task = try #require(world.target.copyIn(from: world.source, paths: ["docs"], into: "inbox"))
        await PresentedErrors.expectingNone { await task.value }

        #expect(world.targetDocument.state.progress == nil)
        #expect(world.targetModel.changes.isEmpty)
        #expect(exports(in: world.exports).isEmpty)
    }
}

/// One dragged row, as `ArchiveFilePromiseProvider` writes it.
private func rowItem(_ path: String, token: String) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setPropertyList(["path": path, "token": token], forType: ArchiveFilePromiseProvider.moveType)
    return item
}

/// The hook over a hosted window's table (the target: docs/, docs/a.txt, docs/sub/, b.pdf, c.png), and a second
/// window's actions (the source, not hosted: README) its drags come from.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct CrossWindowCopyDropTests {
    private static let entries = ["docs/", "docs/a.txt", "docs/sub/", "b.pdf", "c.png"]

    private func validate(_ drop: FakeDrop, _ outline: NSOutlineView, row: Int?) -> UInt? {
        let item = row.map { outline.item(atRow: $0) as AnyObject? } ?? nil
        return outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: item,
                                                proposedChildIndex: NSOutlineViewDropOnItemIndex).rawValue
    }

    private func accept(_ drop: FakeDrop, _ outline: NSOutlineView, row: Int?) -> Bool? {
        let item = row.map { outline.item(atRow: $0) as AnyObject? } ?? nil
        return outline.dataSource?.outlineView?(outline, acceptDrop: drop, item: item,
                                                childIndex: NSOutlineViewDropOnItemIndex)
    }

    @Test func aDropFromAnotherWindowCopiesAndOneInsideTheWindowStillOnlyMoves() async throws {
        let hosted = try await RegressionHosted(.hooked, entries: Self.entries)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        try #require(theHookAnswersAccept(outline))
        let sourceDocument = try ArchiveDocument(type: "public.zip-archive")
        sourceDocument.state.model = ArchiveModel(reader: FakeReader(entries: [file("README")]), undoManager: nil)
        let source = ArchiveActions(document: sourceDocument)
        defer { withExtendedLifetime((sourceDocument, source)) {} }
        let calls = CopyCalls()
        hosted.actions.copier.export = { paths, _, _ in
            calls.exported.append(paths)
            calls.onExport?()
            return (FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString)"), [])
        }
        let local: NSDragOperation = [.move, .copy]
        let own = hosted.actions.moveToken
        let otherTable = NSView()

        // Inside the window: a move; Option-dragged (copy only), refused.
        let inside = FakeDrop(writers: [rowItem("b.pdf", token: own)], location: .zero, window: hosted.window,
                              source: outline, mask: local)
        let option = FakeDrop(writers: [rowItem("b.pdf", token: own)], location: .zero, window: hosted.window,
                              source: outline, mask: .copy)
        // From elsewhere: a window gone, rows of two windows, no copy in the mask.
        let gone = FakeDrop(writers: [rowItem("README", token: UUID().uuidString)], location: .zero,
                            window: hosted.window, source: otherTable, mask: local)
        let mixed = FakeDrop(writers: [rowItem("README", token: source.moveToken), rowItem("b.pdf", token: own)],
                             location: .zero, window: hosted.window, source: otherTable, mask: local)
        let moveOnly = FakeDrop(writers: [rowItem("README", token: source.moveToken)], location: .zero,
                                window: hosted.window, source: otherTable, mask: .move)
        defer { for drop in [inside, option, gone, mixed, moveOnly] { drop.end() } }

        #expect(validate(inside, outline, row: 0) == NSDragOperation.move.rawValue)
        #expect(validate(option, outline, row: 0) == 0)
        #expect(accept(option, outline, row: 0) == false)
        for drop in [gone, mixed, moveOnly] {
            #expect(validate(drop, outline, row: 0) == 0)
            #expect(accept(drop, outline, row: 0) == false)
        }
        #expect(hosted.document.state.progress == nil)

        // From another window, plain or Option-dragged: a copy, onto the folder row; accept starts it.
        let other = FakeDrop(writers: [rowItem("README", token: source.moveToken)], location: .zero,
                             window: hosted.window, source: otherTable, mask: local)
        let otherOption = FakeDrop(writers: [rowItem("README", token: source.moveToken)], location: .zero,
                                   window: hosted.window, source: otherTable, mask: .copy)
        defer { other.end(); otherOption.end() }
        #expect(validate(otherOption, outline, row: 0) == NSDragOperation.copy.rawValue)
        #expect(validate(other, outline, row: 0) == NSDragOperation.copy.rawValue)
        #expect(calls.exported.isEmpty)
        #expect(accept(other, outline, row: 0) == true)
        #expect(hosted.document.state.progress?.title == ArchiveClipboard.progressTitle)
        // The copy runs as a task, after the drop's callback returned.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            calls.onExport = { done.resume() }
        }
        #expect(calls.exported == [["README"]])
    }
}
