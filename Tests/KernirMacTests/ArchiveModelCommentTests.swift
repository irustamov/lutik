import Testing
import Foundation
import os
import Observation
@testable import Kernir
import KernirCore

/// The ZIP archive comment as an undoable model edit. The edit lives in `changes.comment`
/// (`.keep` / `.set(String)` / `.remove`; the engine writes `.set` text as UTF-8), so undo snapshots cover it.
@MainActor @Suite struct ArchiveModelCommentTests {
    private static func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    private static let entries = [file("README"), file("notes")]

    private static func comment(_ text: String, isWritable: Bool = true) -> ArchiveComment {
        ArchiveComment(bytes: Array(text.utf8), text: text, isWritable: isWritable)
    }

    /// A `FakeReader` that counts how often the model reads `entries`, which `rebuild()` does on every pass.
    private struct CountingReader: ArchiveReading {
        let base: FakeReader
        let reads: OSAllocatedUnfairLock<Int>

        var url: URL { base.url }
        var volumeURLs: [URL] { base.volumeURLs }
        var format: ArchiveFormat { base.format }
        var entries: [ArchiveEntry] {
            reads.withLock { $0 += 1 }
            return base.entries
        }
        var isEncrypted: Bool { base.isEncrypted }
        var comment: ArchiveComment? { base.comment }

        func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
            try await base.extract(paths, to: directory, progress: progress)
        }

        func extractToTemporaryFile(_ path: String) async throws -> URL {
            try await base.extractToTemporaryFile(path)
        }
    }

    private func makeModel(comment: ArchiveComment? = nil, format: ArchiveFormat = .zip,
                           url: URL = URL(fileURLWithPath: "/tmp/fake.zip"), volumeURLs: [URL]? = nil,
                           undoManager: UndoManager? = nil,
                           reads: OSAllocatedUnfairLock<Int>? = nil) -> ArchiveModel {
        let base = FakeReader(entries: Self.entries, format: format, url: url, volumeURLs: volumeURLs,
                              comment: comment)
        let reader: any ArchiveReading = reads.map { CountingReader(base: base, reads: $0) } ?? base
        return ArchiveModel(reader: reader, undoManager: undoManager)
    }

    /// An undo manager whose every call below is its own step.
    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    private func step<T>(_ undoManager: UndoManager, _ body: () throws -> T) rethrows -> T {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try body()
    }

    private var editCommentActionName: String { String(localized: "Edit Comment", table: "Shared") }

    @Test func sourceCommentShown() {
        let model = makeModel(comment: Self.comment("Hello from the archive"))
        #expect(model.showsComment)
        #expect(model.canEditComment)
        #expect(model.commentText == "Hello from the archive")
        #expect(model.changes.comment == .keep)
        #expect(model.commentProblem == nil)
        #expect(!model.hasChanges)

        // A ZIP without a comment shows an empty, editable one.
        let empty = makeModel()
        #expect(empty.showsComment)
        #expect(empty.canEditComment)
        #expect(empty.commentText == "")
    }

    @Test func editMarksChangedAndUndoes() {
        let undoManager = makeUndoManager()
        let model = makeModel(comment: Self.comment("old"), undoManager: undoManager)

        step(undoManager) { model.setComment("new") }
        #expect(model.changes.comment == .set("new"))
        #expect(model.commentText == "new")
        #expect(model.hasChanges)
        #expect(undoManager.undoActionName == editCommentActionName)

        undoManager.undo()
        #expect(model.changes.comment == .keep)
        #expect(model.commentText == "old")
        #expect(!model.hasChanges)

        undoManager.redo()
        #expect(model.changes.comment == .set("new"))
    }

    @Test func editBackToOriginalIsKeep() {
        let undoManager = makeUndoManager()
        let model = makeModel(comment: Self.comment("old"), undoManager: undoManager)
        step(undoManager) { model.setComment("older") }
        step(undoManager) { model.setComment("old") }
        // The original bytes are kept, not rewritten as UTF-8 text.
        #expect(model.changes.comment == .keep)
        #expect(!model.hasChanges)

        // Setting the unchanged text on a fresh model is no edit at all: no undo step.
        let fresh = makeUndoManager()
        let unchanged = makeModel(comment: Self.comment("old"), undoManager: fresh)
        step(fresh) { unchanged.setComment("old") }
        #expect(fresh.undoActionName.isEmpty)
        #expect(unchanged.changes.comment == .keep)
    }

    @Test func clearRemoves() {
        let model = makeModel(comment: Self.comment("old"))
        model.setComment("")
        #expect(model.changes.comment == .remove)
        #expect(model.commentText == "")
        #expect(model.hasChanges)

        // No source comment: clearing a typed one is back to `.keep`.
        let none = makeModel()
        none.setComment("typed")
        #expect(none.changes.comment == .set("typed"))
        none.setComment("")
        #expect(none.changes.comment == .keep)
        #expect(!none.hasChanges)
    }

    @Test func nonASCIIWrittenAsUTF8() throws {
        // Decomposed "é" (e + U+0301) and Cyrillic: the text goes to the engine exactly as typed,
        // scalar for scalar, so its UTF-8 bytes are the typed ones.
        let typed = "Cafe\u{301} Привет ☃"
        let model = makeModel(comment: Self.comment("old"))
        model.setComment(typed)
        guard case .set(let text) = model.changes.comment else {
            Issue.record("expected .set, got \(model.changes.comment)")
            return
        }
        #expect(Array(text.utf8) == Array(typed.utf8))
        #expect(ArchiveCommentText.bytes(for: text) == Array(typed.utf8))
        #expect(model.commentProblem == nil)
    }

    @Test func tooLongOrSignatureTextIsAcceptedButFlagged() {
        let model = makeModel()
        let long = String(repeating: "a", count: ArchiveComment.maximumWritableLength + 1)
        model.setComment(long)
        #expect(model.changes.comment == .set(long))
        #expect(model.commentProblem == ArchiveCommentText.tooLongMessage)

        model.setComment("before PK\u{5}\u{6} after")
        #expect(model.commentProblem == ArchiveCommentText.endRecordSignatureMessage)

        model.setComment("fine")
        #expect(model.commentProblem == nil)
    }

    @Test func notOnSevenZip() {
        let model = makeModel(format: .sevenZip)
        #expect(!model.showsComment)
        #expect(!model.canEditComment)
        model.setComment("text")
        #expect(model.changes.comment == .keep)
        #expect(!model.hasChanges)
    }

    @Test func notEditableOnMultiVolume() {
        let parts = (1...2).map { URL(fileURLWithPath: "/tmp/fake.z0\($0)") } + [URL(fileURLWithPath: "/tmp/fake.zip")]
        let model = makeModel(comment: Self.comment("from the last part", isWritable: false), volumeURLs: parts)
        #expect(model.showsComment)
        #expect(!model.canEditComment)
        #expect(model.commentText == "from the last part")
        model.setComment("changed")
        #expect(model.changes.comment == .keep)

        // A comment the reader says can't be changed stays read-only on a single file too.
        let readOnly = makeModel(comment: Self.comment("locked", isWritable: false))
        #expect(readOnly.showsComment)
        #expect(!readOnly.canEditComment)
    }

    @Test func commentAndRenameUndoInterleave() throws {
        let undoManager = makeUndoManager()
        let model = makeModel(comment: Self.comment("old"), undoManager: undoManager)

        let renamed = step(undoManager) { model.rename("README", to: "READ ME") }
        #expect(try renamed.get() == "READ ME")
        step(undoManager) { model.setComment("new") }
        #expect(model.changes.renamedPaths == ["README": "READ ME"])
        #expect(model.changes.comment == .set("new"))

        undoManager.undo()
        #expect(model.changes.comment == .keep)
        #expect(model.changes.renamedPaths == ["README": "READ ME"])
        #expect(model.item(at: "READ ME") != nil)

        undoManager.undo()
        #expect(model.changes.renamedPaths.isEmpty)
        #expect(model.item(at: "README") != nil)
        #expect(!model.hasChanges)

        undoManager.redo()
        undoManager.redo()
        #expect(model.changes.renamedPaths == ["README": "READ ME"])
        #expect(model.changes.comment == .set("new"))
    }

    /// A split set gets no archive comment.
    @Test func noCommentChangeOnSplitSave() {
        // Split source: nothing to edit, even when the reader calls the comment writable.
        let parts = [URL(fileURLWithPath: "/tmp/fake.z01"), URL(fileURLWithPath: "/tmp/fake.zip")]
        let split = makeModel(comment: Self.comment("old"), volumeURLs: parts)
        #expect(!split.canEditComment)
        split.setComment("new")
        #expect(split.changes.comment == .keep)
        #expect(split.splitSaveProblem == nil)

        // Single file with a pending comment edit: a split save is refused with the engine's message.
        let splitMessage = String(localized: "A split archive can’t have a comment.", table: "Shared")
        let model = makeModel(comment: Self.comment("old"))
        #expect(model.splitSaveProblem == nil)
        model.setComment("new")
        #expect(model.splitSaveProblem == splitMessage)
        #expect(model.saveProblem(as: .zip, split: true) == splitMessage)
        // A split 7z drops the edit, as any 7z does.
        #expect(model.saveProblem(as: .sevenZip, split: true) == nil)
        // Too long as well: the split refusal comes first, since no text would do.
        model.setComment(String(repeating: "a", count: ArchiveComment.maximumWritableLength + 1))
        #expect(model.saveProblem(as: .zip, split: true) == splitMessage)
        // A removed comment is what a split set gets anyway (every split save writes `.keep`, which drops the
        // source's comment): nothing to refuse.
        model.setComment("")
        #expect(model.changes.comment == .remove)
        #expect(model.splitSaveProblem == nil)
        #expect(model.saveProblem(as: .zip, split: true) == nil)
        model.setComment("old")
        #expect(model.splitSaveProblem == nil)
    }

    /// Save As to a format without comments (7z, TAR…) drops a pending comment edit, as converting drops the
    /// source's comment: the engine would throw for `.set` there. Its text's problems don't refuse that save.
    @Test func saveToFormatWithoutCommentsDropsTheEdit() {
        let model = makeModel(comment: Self.comment("old"))
        model.setComment("new")
        #expect(model.saveChanges(as: .zip).comment == .set("new"))
        #expect(model.saveChanges(as: .sevenZip).comment == .keep)
        #expect(model.saveChanges(as: .tar).comment == .keep)

        model.setComment("")
        #expect(model.saveChanges(as: .zip).comment == .remove)
        #expect(model.saveChanges(as: .sevenZip).comment == .keep)

        let long = String(repeating: "a", count: ArchiveComment.maximumWritableLength + 1)
        model.setComment(long)
        #expect(model.saveProblem(as: .zip, split: false) == ArchiveCommentText.tooLongMessage)
        #expect(model.saveProblem(as: .sevenZip, split: false) == nil)
        #expect(model.saveChanges(as: .sevenZip).comment == .keep)
        // The rest of the change set is untouched.
        #expect(model.saveChanges(as: .sevenZip).removedPaths == model.changes.removedPaths)
    }

    /// Typing in the comment field is one undo step, as in any text field: consecutive comment edits coalesce
    /// until `endCommentTyping()`, another edit, an undo or redo.
    @Test func typingCoalescesIntoOneUndoStep() throws {
        let undoManager = makeUndoManager()
        let model = makeModel(comment: Self.comment("old"), undoManager: undoManager)
        step(undoManager) { model.setComment("n") }
        // Joined to that step: nothing registers, so (as with `groupsByEvent`) no group is opened for them.
        model.setComment("ne")
        model.setComment("new")
        #expect(model.changes.comment == .set("new"))
        #expect(undoManager.undoActionName == editCommentActionName)
        undoManager.undo()
        #expect(model.changes.comment == .keep)
        #expect(!undoManager.canUndo)
        undoManager.redo()
        #expect(model.changes.comment == .set("new"))

        // After a redo, typing is a new step.
        step(undoManager) { model.setComment("newer") }
        undoManager.undo()
        #expect(model.changes.comment == .set("new"))

        // Ending the typing (the field closed) starts a new step.
        step(undoManager) { model.setComment("new!") }
        model.endCommentTyping()
        step(undoManager) { model.setComment("new!!") }
        undoManager.undo()
        #expect(model.changes.comment == .set("new!"))

        // Another edit in between ends the typing too.
        let other = makeUndoManager()
        let renaming = makeModel(comment: Self.comment("old"), undoManager: other)
        step(other) { renaming.setComment("a") }
        _ = step(other) { renaming.rename("README", to: "READ ME") }
        step(other) { renaming.setComment("ab") }
        other.undo()
        #expect(renaming.changes.comment == .set("a"))
        #expect(renaming.changes.renamedPaths == ["README": "READ ME"])
    }

    /// Typing the comment back to the text the typing step began with is no edit: the step goes, so nothing is
    /// pending, nothing is left to undo or redo for it, and (`NSDocument` counts undo steps) the document is clean.
    @Test func typingBackToTheSourceLeavesNoChange() {
        let undoManager = makeUndoManager()
        let model = makeModel(comment: Self.comment("old"), undoManager: undoManager)
        step(undoManager) { model.setComment("old!") }
        model.setComment("old!!")
        model.setComment("old!")
        model.setComment("old")
        #expect(model.changes.comment == .keep)
        #expect(!model.hasChanges)
        #expect(!undoManager.canUndo)
        #expect(!undoManager.canRedo)

        // Typing on opens a step of its own.
        step(undoManager) { model.setComment("old?") }
        #expect(model.changes.comment == .set("old?"))
        undoManager.undo()
        #expect(model.changes.comment == .keep)
        #expect(!undoManager.canUndo)

        // Only the typing step goes: an earlier edit stays, and so does an earlier comment edit.
        let other = makeUndoManager()
        let renaming = makeModel(comment: Self.comment("old"), undoManager: other)
        _ = step(other) { renaming.rename("README", to: "READ ME") }
        let renameName = other.undoActionName
        step(other) { renaming.setComment("ol") }
        renaming.setComment("old")
        #expect(renaming.changes.comment == .keep)
        #expect(renaming.changes.renamedPaths == ["README": "READ ME"])
        #expect(other.undoActionName == renameName)
        #expect(!other.canRedo)

        step(other) { renaming.setComment("new") }
        renaming.endCommentTyping()
        step(other) { renaming.setComment("new!") }
        renaming.setComment("new")
        #expect(renaming.changes.comment == .set("new"))
        #expect(other.undoActionName == editCommentActionName)
        other.undo()
        #expect(renaming.changes.comment == .keep)
        #expect(other.undoActionName == renameName)
    }

    /// A save moves `snapshotGeneration` (observably) even when the file size was still loading, nil before and
    /// after: the Info popover keys its size load on it, so a save landing during a load is loaded again.
    @Test func saveMovesTheGenerationTheInfoSizeLoadIsKeyedOn() async throws {
        let model = makeModel(comment: Self.comment("old"))
        let generation = model.snapshotGeneration
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.snapshotGeneration
        } onChange: {
            changed.withLock { $0 = true }
        }
        #expect(model.infoFileSize == nil)
        model.didSave(reader: FakeReader(entries: Self.entries, format: .zip, url: URL(fileURLWithPath: "/tmp/fake.zip")))
        #expect(model.infoFileSize == nil)
        #expect(model.snapshotGeneration != generation)
        #expect(changed.withLock { $0 })
    }

    @Test func infoSummaryMatchesModel() async throws {
        let missing = URL(fileURLWithPath: "/tmp/kernir-comment-\(UUID().uuidString).zip")
        let model = makeModel(comment: Self.comment("old"), url: missing)
        await model.loadInfoFileSize()
        #expect(model.infoSummary == ArchiveInfoSummary(
            format: .zip, itemCount: model.itemCount, size: model.totalSize,
            compressedSize: model.compressedSize, fileSize: nil, encryption: .none))

        // On disk: the file's size.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelCommentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.zip")
        try Data(count: 1234).write(to: file)
        let onDisk = makeModel(url: file)
        // Until it is loaded, off the main actor, the summary has no file size: reading it is file I/O.
        #expect(onDisk.infoSummary == ArchiveInfoSummary(
            format: .zip, itemCount: onDisk.itemCount, size: onDisk.totalSize,
            compressedSize: onDisk.compressedSize, fileSize: nil, encryption: .none))
        await onDisk.loadInfoFileSize()
        #expect(onDisk.infoSummary == ArchiveInfoSummary(
            format: .zip, itemCount: onDisk.itemCount, size: onDisk.totalSize,
            compressedSize: onDisk.compressedSize, fileSize: 1234, encryption: .none))

        // A save replaces the file: its size is loaded again.
        onDisk.didSave(reader: FakeReader(entries: Self.entries, format: .zip, url: file))
        #expect(onDisk.infoSummary == summary(of: onDisk, fileSize: nil))
        try Data(count: 99).write(to: file)
        await onDisk.loadInfoFileSize()
        #expect(onDisk.infoSummary == summary(of: onDisk, fileSize: 99))
    }

    private func summary(of model: ArchiveModel, fileSize: Int64?) -> ArchiveInfoSummary {
        ArchiveInfoSummary(format: .zip, itemCount: model.itemCount, size: model.totalSize,
                           compressedSize: model.compressedSize, fileSize: fileSize, encryption: .none)
    }

    /// A split set's file size is all its parts together (the first part alone would understate it).
    @Test func infoSummarySumsSplitVolumeParts() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelCommentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sizes = [1000, 250, 7]
        let parts = try sizes.enumerated().map { index, size in
            let part = folder.appendingPathComponent("a.zip.00\(index + 1)")
            try Data(count: size).write(to: part)
            return part
        }
        let model = makeModel(url: parts[0], volumeURLs: parts)
        await model.loadInfoFileSize()
        #expect(model.infoSummary == summary(of: model, fileSize: 1257))

        // One unreadable part: no size rather than a partial sum.
        let missing = folder.appendingPathComponent("a.zip.004")
        let broken = makeModel(url: parts[0], volumeURLs: parts + [missing])
        await broken.loadInfoFileSize()
        #expect(broken.infoSummary == summary(of: broken, fileSize: nil))
        #expect(broken.infoSummary != model.infoSummary)
    }

    /// A model over a counting reader, and the number of `entries` reads made so far. `rebuild()` lists the
    /// reader on every pass, so an edit that rebuilt the tree shows as a rise in the count. Observing `items`
    /// would not do: `@Observable` stays silent when a rebuild assigns an equal list.
    private func makeCountingModel(comment: ArchiveComment? = nil, undoManager: UndoManager? = nil)
        -> (model: ArchiveModel, reads: OSAllocatedUnfairLock<Int>) {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        return (makeModel(comment: comment, undoManager: undoManager, reads: reads), reads)
    }

    private func rebuilds(_ reads: OSAllocatedUnfairLock<Int>, during edit: () -> Void) -> Bool {
        let before = reads.withLock { $0 }
        edit()
        return reads.withLock { $0 } > before
    }

    @Test func commentOnlyEditSkipsRebuild() {
        let undoManager = makeUndoManager()
        let (model, reads) = makeCountingModel(comment: Self.comment("old"), undoManager: undoManager)
        let before = model.items
        #expect(!before.isEmpty)
        #expect(reads.withLock { $0 } > 0)

        #expect(!rebuilds(reads) { step(undoManager) { model.setComment("new") } })
        #expect(model.changes.comment == .set("new"))
        #expect(model.items == before)
        #expect(model.items.map(\.id) == before.map(\.id))

        // Undo and redo of the comment edit leave the tree alone too.
        #expect(!rebuilds(reads) { undoManager.undo() })
        #expect(model.changes.comment == .keep)
        #expect(!rebuilds(reads) { undoManager.redo() })
        #expect(model.changes.comment == .set("new"))
        #expect(model.items == before)
    }

    @Test func commentEditWithTreeChangeStillRebuilds() {
        let (model, reads) = makeCountingModel(comment: Self.comment("old"))
        let before = model.items
        #expect(rebuilds(reads) { _ = model.rename("README", to: "READ ME") })
        #expect(model.changes.renamedPaths == ["README": "READ ME"])
        #expect(model.items != before)
        #expect(model.items.contains { $0.path == "READ ME" })

        // A later comment edit leaves the renamed tree as it is.
        let renamed = model.items
        #expect(!rebuilds(reads) { model.setComment("new") })
        #expect(model.items == renamed)
    }
}
