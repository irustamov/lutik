import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Moving items inside the archive (`ArchiveModel.move(_:into:)`), one undo step "Move": source
/// items through `renamedPaths` (a rename across parents), pending ones through their additions.
@MainActor @Suite struct ArchiveModelMoveTests {
    private static func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    private static func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }

    private static let entries = [
        folder("docs"), file("docs/a.txt"), file("docs/c.txt"), folder("docs/sub"), file("docs/sub/d.txt"),
        folder("other"), file("other/b.txt"), file("README"), file("notes"),
    ]

    private func makeModel(_ entries: [ArchiveEntry] = entries, format: ArchiveFormat = .zip,
                           undoManager: UndoManager? = nil) -> ArchiveModel {
        ArchiveModel(reader: FakeReader(entries: entries, format: format), undoManager: undoManager)
    }

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

    /// A fresh folder holding a file `name`; the caller removes the folder.
    private func makeFile(_ name: String) throws -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelMoveTests-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: file)
        return (folder, file)
    }

    private var moveActionName: String { String(localized: "Move", table: "Shared") }

    // MARK: - Source items

    @Test func moveSourceFileToRoot() {
        let model = makeModel()

        #expect(model.move(["docs/a.txt"], into: "") == .success(["docs/a.txt": "a.txt"]))

        #expect(model.changes.renamedPaths == ["docs/a.txt": "a.txt"])
        #expect(model.item(at: "a.txt") != nil)
        #expect(model.item(at: "docs/a.txt") == nil)
        #expect(model.changes.removedPaths.isEmpty && model.changes.additions.isEmpty)
    }

    @Test func moveFolderIntoFolder() {
        let model = makeModel()

        #expect(model.move(["docs"], into: "other") == .success(["docs": "other/docs"]))

        #expect(model.changes.renamedPaths == ["docs": "other/docs"])
        for path in ["other/docs", "other/docs/a.txt", "other/docs/sub/d.txt", "other/b.txt"] {
            #expect(model.item(at: path) != nil, "\(path)")
        }
        #expect(model.item(at: "docs") == nil)
    }

    @Test func moveImplicitFolder() {
        let model = makeModel([Self.file("top/x.txt"), Self.file("top/sub/y.txt"), Self.folder("dest")])

        #expect(model.move(["top"], into: "dest") == .success(["top": "dest/top"]))

        #expect(model.changes.renamedPaths == ["top": "dest/top"])
        #expect(model.item(at: "dest/top/sub/y.txt") != nil)
        #expect(model.item(at: "top") == nil)
    }

    /// Open question (1), default pinned: a folder the reader synthesized stays listed once its last entry moves
    /// out (the saved archive drops it: `liveMoveSurvivesASaveOnZip`).
    @Test func emptiedImplicitFolderStaysListed() {
        let model = makeModel([Self.folder("top"), Self.file("top/x.txt")])

        _ = model.move(["top/x.txt"], into: "")

        #expect(model.item(at: "top")?.isDirectory == true)
        #expect(model.children(of: "top").isEmpty)
        #expect(model.item(at: "x.txt") != nil)
    }

    @Test func moveBackClears() {
        let model = makeModel()

        _ = model.move(["docs/a.txt"], into: "")
        _ = model.move(["a.txt"], into: "docs")

        #expect(model.changes.isEmpty)
        #expect(model.item(at: "docs/a.txt") != nil)
    }

    @Test func companionsFollow() {
        let model = makeModel(Self.entries + [Self.file("docs/._a.txt"), Self.folder("__MACOSX"),
                                              Self.folder("__MACOSX/docs"), Self.file("__MACOSX/docs/._a.txt")])

        _ = model.move(["docs/a.txt"], into: "other")

        #expect(model.changes.renamedPaths == [
            "docs/a.txt": "other/a.txt", "docs/._a.txt": "other/._a.txt",
            "__MACOSX/docs/._a.txt": "__MACOSX/other/._a.txt",
        ])
    }

    // MARK: - Pending items

    @Test func movePendingAddition() throws {
        let (dir, newFile) = try makeFile("x.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        model.add([newFile], to: "")

        #expect(model.move(["x.txt"], into: "docs/sub") == .success(["x.txt": "docs/sub/x.txt"]))

        #expect(model.changes.renamedPaths.isEmpty)
        #expect(model.changes.additions.count == 1)
        #expect(model.changes.additions.first?.destinationDirectory == "docs/sub")
        #expect(model.changes.additions.first?.archiveName == nil)
        #expect(model.item(at: "docs/sub/x.txt")?.isPendingAddition == true)
        #expect(model.item(at: "x.txt") == nil)
    }

    @Test func moveFileOutOfAddedFolder() throws {
        let (dir, _) = try makeFile("a.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("bb".utf8).write(to: dir.appendingPathComponent("b.txt"))
        let model = makeModel()
        model.add([dir], to: "")
        let top = dir.lastPathComponent

        #expect(model.move(["\(top)/a.txt"], into: "other") == .success(["\(top)/a.txt": "other/a.txt"]))

        #expect(model.item(at: "other/a.txt")?.isPendingAddition == true)
        #expect(model.item(at: "\(top)/a.txt") == nil)
        #expect(model.item(at: "\(top)/b.txt")?.isPendingAddition == true)
        let moved = model.changes.additions.first { $0.sourceURL.lastPathComponent == "a.txt" }
        #expect(moved?.destinationDirectory == "other")
    }

    @Test func moveIntoNewFolder() throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        let folder = try model.newFolder(in: "")

        #expect(model.move(["docs/a.txt"], into: folder) == .success(["docs/a.txt": "\(folder)/a.txt"]))

        #expect(model.changes.renamedPaths == ["docs/a.txt": "\(folder)/a.txt"])
        #expect(model.item(at: "\(folder)/a.txt")?.isPendingAddition == false)
    }

    @Test func moveFolderCarriesPendingAdditions() throws {
        let (dir, newFile) = try makeFile("x.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        model.add([newFile], to: "docs/sub")

        _ = model.move(["docs"], into: "other")

        #expect(model.changes.additions.first?.destinationDirectory == "other/docs/sub")
        #expect(model.item(at: "other/docs/sub/x.txt")?.isPendingAddition == true)
        #expect(model.item(at: "docs/sub/x.txt") == nil)
    }

    // MARK: - Collisions

    @Test func conflictsListed() {
        let model = makeModel(Self.entries + [Self.file("other/a.txt")])

        #expect(model.conflicts(moving: ["docs/a.txt", "docs/c.txt"], into: "other") == ["other/a.txt"])
        #expect(model.conflicts(moving: ["docs/c.txt"], into: "other") == [])
        #expect(model.conflicts(moving: ["docs"], into: "docs/sub") == [])
    }

    @Test func replaceRemovesTarget() {
        let undoManager = makeUndoManager()
        let model = makeModel(Self.entries + [Self.folder("other/sub"), Self.file("other/sub/z")],
                              undoManager: undoManager)
        let initial = model.items

        let result = step(undoManager) { model.move(["docs/sub"], into: "other") }

        #expect(result == .success(["docs/sub": "other/sub"]))
        #expect(model.changes.removedPaths == ["other/sub"])
        #expect(model.changes.renamedPaths == ["docs/sub": "other/sub"])
        #expect(model.item(at: "other/sub/z") == nil)
        #expect(model.item(at: "other/sub/d.txt") != nil)
        undoManager.undo()
        #expect(model.changes.isEmpty)
        #expect(model.items == initial)
        #expect(!undoManager.canUndo)
    }

    @Test func duplicateNamesRefused() {
        let model = makeModel(Self.entries + [Self.file("other/a.txt")])

        #expect(model.move(["docs/a.txt", "other/a.txt"], into: "") == .failure(.taken("a.txt")))
        // One of them already there counts too: it would be replaced by the other.
        #expect(model.move(["docs/a.txt", "other/a.txt"], into: "other") == .failure(.taken("a.txt")))
        #expect(model.changes.isEmpty)
    }

    /// An item that holds a moved one can't be replaced by another of them.
    @Test func replacingAnAncestorOfAMovedItemRefused() {
        let model = makeModel(Self.entries + [Self.folder("x"), Self.folder("x/docs")])

        #expect(model.move(["docs/sub", "x/docs"], into: "") == .failure(.taken("docs")))
        #expect(model.changes.isEmpty)
    }

    @Test func hiddenTargetRefused() {
        let model = makeModel(Self.entries + [Self.file("x/._y"), Self.folder("d2"), Self.folder("d2/x")])
        #expect(model.item(at: "x") == nil)

        #expect(model.move(["d2/x"], into: "") == .failure(.taken("x")))
        #expect(model.changes.isEmpty)
    }

    @Test func caseTwinAllowed() {
        let model = makeModel(Self.entries + [Self.file("docs/readme")])

        #expect(model.conflicts(moving: ["docs/readme"], into: "") == [])
        #expect(model.move(["docs/readme"], into: "") == .success(["docs/readme": "readme"]))
        #expect(model.item(at: "README") != nil && model.item(at: "readme") != nil)
    }

    // MARK: - Refusals and no-ops

    @Test func intoItselfOrNotAFolderRefused() {
        let model = makeModel()

        #expect(model.move(["docs"], into: "docs/sub") == .failure(.intoItself))
        #expect(model.move(["docs"], into: "docs") == .failure(.intoItself))
        #expect(model.move(["notes"], into: "README") == .failure(.notAFolder))
        #expect(model.move(["notes"], into: "missing") == .failure(.notAFolder))
        #expect(model.move(["missing"], into: "docs") == .failure(.unavailable))
        #expect(model.changes.isEmpty)
    }

    @Test func noopDropRegistersNothing() {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)

        #expect(model.move(["docs/a.txt", "docs/sub"], into: "docs") == .success([:]))
        #expect(model.move([], into: "docs") == .success([:]))
        #expect(model.changes.isEmpty)
        #expect(!undoManager.canUndo)
    }

    @Test func notEditableRefuses() {
        let rar = makeModel(format: .rar)
        #expect(rar.move(["docs/a.txt"], into: "") == .failure(.unavailable))
        #expect(rar.conflicts(moving: ["docs/a.txt"], into: "") == [])

        let parts = [URL(fileURLWithPath: "/tmp/a.zip.001"), URL(fileURLWithPath: "/tmp/a.zip.002")]
        let undoManager = makeUndoManager()
        let split = ArchiveModel(reader: FakeReader(entries: Self.entries, volumeURLs: parts), undoManager: undoManager)
        #expect(split.move(["docs"], into: "other") == .failure(.unavailable))
        #expect(split.changes.isEmpty)
        #expect(!undoManager.canUndo)
    }

    // MARK: - Several items, undo

    @Test func multiSelectionOneUndo() {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)
        let initial = model.items

        let result = step(undoManager) { model.move(["docs/sub", "docs/sub/d.txt", "README", "other/b.txt"], into: "docs") }

        #expect(result == .success(["README": "docs/README", "other/b.txt": "docs/b.txt"]))
        #expect(model.changes.renamedPaths == ["README": "docs/README", "other/b.txt": "docs/b.txt"])
        #expect(undoManager.undoActionName == moveActionName)
        let moved = (changes: model.changes, items: model.items)

        undoManager.undo()
        #expect(model.changes.isEmpty)
        #expect(model.items == initial)
        undoManager.redo()
        #expect(model.changes == moved.changes)
        #expect(model.items == moved.items)
    }

    @Test func remapMoves() {
        let moves = ["docs/a.txt": "a.txt", "d": "e/d"]
        #expect(ArchiveModel.remap(["docs/a.txt", "d", "d/\u{301}x/y", "dx", "docs", "e"], moves: moves)
                == ["a.txt", "e/d", "e/d/\u{301}x/y", "dx", "docs", "e"])
        #expect(ArchiveModel.remap(["x"], moves: [:]) == ["x"])
    }

    @Test func moveThenRenameThenUndo() {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)

        _ = step(undoManager) { model.move(["docs/a.txt"], into: "") }
        _ = step(undoManager) { model.rename("a.txt", to: "b.txt") }
        #expect(model.changes.renamedPaths == ["docs/a.txt": "b.txt"])
        _ = step(undoManager) { model.move(["b.txt"], into: "other") }
        #expect(model.changes.renamedPaths == ["docs/a.txt": "other/b.txt"])

        undoManager.undo()
        #expect(model.changes.renamedPaths == ["docs/a.txt": "b.txt"])
        undoManager.undo()
        #expect(model.changes.renamedPaths == ["docs/a.txt": "a.txt"])
        undoManager.undo()
        #expect(model.changes.isEmpty)
        undoManager.redo()
        undoManager.redo()
        undoManager.redo()
        #expect(model.changes.renamedPaths == ["docs/a.txt": "other/b.txt"])
    }

    /// The writer keeps an entry renamed out of a removed folder (KernirCore's `removedPaths`), so Delete puts the
    /// folder itself in `removedPaths` and keeps the rename: one "Delete" step.
    @Test func deletingAFolderAnItemWasMovedOutOfKeepsIt() {
        let undoManager = makeUndoManager()
        let model = makeModel([Self.folder("docs"), Self.file("docs/a.txt"), Self.file("docs/c.txt"),
                               Self.file("notes")], undoManager: undoManager)
        _ = step(undoManager) { model.move(["docs/a.txt"], into: "") }

        #expect(step(undoManager) { model.remove(["docs"]) } == nil)

        #expect(model.changes.removedPaths == ["docs"])
        #expect(model.changes.renamedPaths == ["docs/a.txt": "a.txt"])
        #expect(model.item(at: "a.txt") != nil)
        #expect(model.item(at: "docs") == nil && model.item(at: "docs/c.txt") == nil)
        undoManager.undo()
        #expect(model.changes.removedPaths.isEmpty)
        #expect(model.item(at: "docs/c.txt") != nil && model.item(at: "a.txt") != nil)
    }

    /// A folder with no entry of its own goes the same way: what was moved out stays.
    @Test func deletingAnImplicitFolderKeepsWhatWasMovedOut() {
        let model = makeModel([Self.file("top/x.txt"), Self.file("top/y.txt"), Self.file("notes")])
        _ = model.move(["top/x.txt"], into: "")

        #expect(model.remove(["top"]) == nil)

        #expect(model.changes.removedPaths == ["top"])
        #expect(model.changes.renamedPaths == ["top/x.txt": "x.txt"])
        #expect(model.item(at: "x.txt") != nil)
        #expect(model.item(at: "top/y.txt") == nil && model.item(at: "top") == nil)
    }

    /// An item moved out of a subfolder of the deleted folder stays too; it can be renamed and deleted after.
    @Test func deletingAFolderKeepsAnItemMovedOutOfItsSubfolder() {
        let model = makeModel()
        _ = model.move(["docs/sub/d.txt"], into: "")

        #expect(model.remove(["docs"]) == nil)

        #expect(model.changes.removedPaths == ["docs"])
        #expect(model.changes.renamedPaths == ["docs/sub/d.txt": "d.txt"])
        #expect(model.item(at: "d.txt") != nil && model.item(at: "docs") == nil)
        #expect(model.rename("d.txt", to: "e.txt") == .success("e.txt"))
        #expect(model.changes.renamedPaths == ["docs/sub/d.txt": "e.txt"])
        #expect(model.remove(["e.txt"]) == nil)
        #expect(model.changes.renamedPaths.isEmpty)
        #expect(model.item(at: "e.txt") == nil)
    }

    /// d/a.txt to e, Delete d, then e renamed d: the writer would drop d/a.txt (now at d/a.txt, beneath the
    /// deleted folder's path). Refused with the save-first problem, nothing changes, no undo step.
    @Test func renamingOntoADeletedFolderAnItemWasMovedOutOfRefused() {
        let undoManager = makeUndoManager()
        let model = makeModel([Self.folder("d"), Self.file("d/a.txt"), Self.file("d/b.txt"), Self.folder("e")],
                              undoManager: undoManager)
        _ = step(undoManager) { model.move(["d/a.txt"], into: "e") }
        _ = step(undoManager) { model.remove(["d"]) }
        let before = model.changes

        // Outside an undo group: an empty group would be an undo step of its own.
        #expect(model.rename("e", to: "d") == .failure(.holdsMovedOutItems("d")))

        #expect(model.changes == before)
        #expect(model.item(at: "e/a.txt") != nil && model.item(at: "d") == nil)
        #expect(undoManager.undoActionName == String(localized: "Delete", table: "Shared"))
        undoManager.undo()
        undoManager.undo()
        #expect(model.changes.isEmpty)
        #expect(!undoManager.canUndo)
    }

    /// The same through a move: x/d (holding d/a.txt) moved to the top level, onto the deleted d's path.
    @Test func movingOntoADeletedFolderAnItemWasMovedOutOfRefused() {
        let undoManager = makeUndoManager()
        let model = makeModel([Self.folder("d"), Self.file("d/a.txt"), Self.file("d/b.txt"), Self.folder("x"),
                               Self.folder("x/d")], undoManager: undoManager)
        _ = step(undoManager) { model.move(["d/a.txt"], into: "x/d") }
        _ = step(undoManager) { model.remove(["d"]) }
        let before = model.changes

        #expect(model.move(["x/d"], into: "") == .failure(.holdsMovedOutItems("d")))

        #expect(model.changes == before)
        #expect(model.item(at: "x/d/a.txt") != nil && model.item(at: "d") == nil)
        undoManager.undo()
        undoManager.undo()
        #expect(model.changes.isEmpty)
        #expect(!undoManager.canUndo)
    }

    /// d/a moved into e over e/a (Replace), then Delete d: the governing key d/a escapes d, so the writer keeps its
    /// whole subtree at e/a (KernirCore's `RepackCopier`, removekeep2), nested items too; the replaced e/a's own
    /// items go. Undo and redo give back each step.
    @Test func deletingAFolderAMovedFolderReplacedIntoKeepsItsSubtree() {
        let undoManager = makeUndoManager()
        let model = makeModel([Self.folder("d"), Self.folder("d/a"), Self.file("d/a/x.txt"), Self.folder("d/a/b"),
                               Self.file("d/a/b/z.txt"), Self.file("d/b.txt"), Self.folder("e"), Self.folder("e/a"),
                               Self.file("e/a/y.txt")], undoManager: undoManager)
        #expect(model.conflicts(moving: ["d/a"], into: "e") == ["e/a"])
        #expect(step(undoManager) { model.move(["d/a"], into: "e") } == .success(["d/a": "e/a"]))
        let moved = model.changes

        #expect(step(undoManager) { model.remove(["d"]) } == nil)

        let deleted = model.changes
        #expect(deleted.removedPaths == ["d", "e/a"])
        #expect(deleted.renamedPaths == ["d/a": "e/a"])
        #expect(model.item(at: "e/a/x.txt") != nil && model.item(at: "e/a/b/z.txt") != nil)
        #expect(model.item(at: "e/a/y.txt") == nil && model.item(at: "d") == nil && model.item(at: "d/b.txt") == nil)
        #expect(undoManager.undoActionName == String(localized: "Delete", table: "Shared"))
        undoManager.undo()
        #expect(model.changes == moved)
        #expect(model.item(at: "d/b.txt") != nil && model.item(at: "e/a/x.txt") != nil)
        undoManager.redo()
        #expect(model.changes == deleted)
        #expect(model.item(at: "e/a/b/z.txt") != nil && model.item(at: "d") == nil)
        undoManager.undo()
        undoManager.undo()
        #expect(model.changes.isEmpty)
        #expect(model.item(at: "e/a/y.txt") != nil && model.item(at: "d/a/x.txt") != nil)
    }

    /// Delete a, d/a moved to the top level (taking the freed name), then Delete d: the moved folder keeps its
    /// subtree at a, the deleted a's own items stay deleted. Undo and redo the Delete.
    @Test func deletingAFolderAMovedFolderTookADeletedNameFromKeepsItsSubtree() {
        let undoManager = makeUndoManager()
        let model = makeModel([Self.folder("a"), Self.file("a/z.txt"), Self.folder("d"), Self.folder("d/a"),
                               Self.file("d/a/x.txt"), Self.folder("d/a/b"), Self.file("d/a/b/y.txt"),
                               Self.file("d/b.txt")], undoManager: undoManager)
        #expect(step(undoManager) { model.remove(["a"]) } == nil)
        #expect(step(undoManager) { model.move(["d/a"], into: "") } == .success(["d/a": "a"]))
        let moved = model.changes

        #expect(step(undoManager) { model.remove(["d"]) } == nil)

        let deleted = model.changes
        #expect(deleted.removedPaths == ["a", "d"])
        #expect(deleted.renamedPaths == ["d/a": "a"])
        #expect(model.item(at: "a/x.txt") != nil && model.item(at: "a/b/y.txt") != nil)
        #expect(model.item(at: "a/z.txt") == nil && model.item(at: "d") == nil)
        undoManager.undo()
        #expect(model.changes == moved)
        #expect(model.item(at: "d/b.txt") != nil && model.item(at: "a/x.txt") != nil)
        undoManager.redo()
        #expect(model.changes == deleted)
        #expect(model.item(at: "a/b/y.txt") != nil && model.item(at: "d/b.txt") == nil)
    }

    /// The way out before a save: move the files out of the moved folder first; Delete d then keeps them.
    @Test func movingTheFilesOutFirstLetsTheDeleteThrough() {
        let model = makeModel([Self.folder("d"), Self.folder("d/a"), Self.file("d/a/x.txt"), Self.file("d/b.txt"),
                               Self.folder("e"), Self.folder("e/a"), Self.file("e/a/y.txt")])
        _ = model.move(["d/a"], into: "e")
        #expect(model.move(["e/a/x.txt"], into: "e") == .success(["e/a/x.txt": "e/x.txt"]))

        #expect(model.remove(["d"]) == nil)

        #expect(model.item(at: "e/x.txt") != nil && model.item(at: "e/a") != nil)
        #expect(model.item(at: "d") == nil && model.item(at: "e/a/y.txt") == nil)
    }

    /// A refused move stages no folder for a pending folder it would have emptied.
    @Test func refusedMoveStagesNoFolder() throws {
        let (dir, _) = try makeFile("p.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel([Self.folder("d"), Self.file("d/a.txt"), Self.file("d/b.txt"), Self.folder("x"),
                               Self.folder("x/d")])
        defer { model.removeTemporaryFiles() }
        model.add([dir], to: "")
        let top = dir.lastPathComponent
        _ = model.move(["d/a.txt"], into: "x/d")
        _ = model.remove(["d"])
        let before = model.changes

        #expect(model.move(["\(top)/p.txt", "x/d"], into: "") == .failure(.holdsMovedOutItems("d")))
        #expect(model.changes == before)

        // New Folder makes the staging folder; a refused move's leftover would sit beside its own.
        let path = try model.newFolder(in: "")
        let staged = try #require(model.changes.additions.last?.sourceURL)
        #expect(staged.lastPathComponent == path)
        let root = staged.deletingLastPathComponent().deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test func movedInItemIsDeletedWithItsFolder() {
        let model = makeModel()
        _ = model.move(["README"], into: "docs")

        #expect(model.remove(["docs"]) == nil)

        #expect(model.changes.removedPaths == ["docs", "README"])
        #expect(model.changes.renamedPaths.isEmpty)
        #expect(model.item(at: "docs/README") == nil && model.item(at: "README") == nil)
    }

    @Test func movedInItemIsDeletedWithItsNewFolder() throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        let folder = try model.newFolder(in: "")
        _ = model.move(["docs/a.txt"], into: folder)

        #expect(model.remove([folder]) == nil)

        #expect(model.changes.removedPaths == ["docs/a.txt"])
        #expect(model.changes.renamedPaths.isEmpty && model.changes.additions.isEmpty)
        #expect(model.item(at: folder) == nil && model.item(at: "docs/a.txt") == nil)
        #expect(model.item(at: "docs/c.txt") != nil)
    }

    /// A pending folder renamed or moved takes along what was moved into it.
    @Test func renamingANewFolderMovesWhatWasMovedIn() throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        let folder = try model.newFolder(in: "")
        _ = model.move(["docs/a.txt"], into: folder)

        #expect(model.rename(folder, to: "Photos") == .success("Photos"))

        #expect(model.changes.renamedPaths == ["docs/a.txt": "Photos/a.txt"])
        #expect(model.item(at: "Photos/a.txt")?.isPendingAddition == false)

        #expect(model.move(["Photos"], into: "other") == .success(["Photos": "other/Photos"]))
        #expect(model.changes.renamedPaths == ["docs/a.txt": "other/Photos/a.txt"])
        #expect(model.item(at: "other/Photos/a.txt") != nil)
    }

    /// Replace takes the replaced item's Finder metadata away, so the mover's own takes its place.
    @Test func replaceMovesTheCompanion() {
        let model = makeModel(Self.entries + [Self.file("docs/._a.txt"), Self.file("other/a.txt"),
                                              Self.file("other/._a.txt")])

        #expect(model.move(["docs/a.txt"], into: "other") == .success(["docs/a.txt": "other/a.txt"]))

        #expect(model.changes.removedPaths == ["other/a.txt", "other/._a.txt"])
        #expect(model.changes.renamedPaths == ["docs/a.txt": "other/a.txt", "docs/._a.txt": "other/._a.txt"])
    }

    /// As in Finder, a folder added from disk stays when its last item moves out.
    @Test func emptiedPendingFolderStays() throws {
        let (dir, _) = try makeFile("a.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        model.add([dir], to: "")
        let top = dir.lastPathComponent

        #expect(model.move(["\(top)/a.txt"], into: "other") == .success(["\(top)/a.txt": "other/a.txt"]))

        #expect(model.item(at: top)?.isDirectory == true)
        #expect(model.item(at: top)?.isPendingAddition == true)
        #expect(model.children(of: top).isEmpty)
        #expect(model.item(at: "other/a.txt")?.isPendingAddition == true)
    }

    /// a/a went to z/a, then a to y/a: replacing y/a (source a) with z/a would drop the mover itself.
    @Test func replacingTheMoversOldFolderRefused() {
        let model = makeModel([Self.folder("a"), Self.file("a/a"), Self.folder("y"), Self.folder("z")])
        _ = model.move(["a/a"], into: "z")
        _ = model.move(["a"], into: "y")
        let before = model.changes

        #expect(model.conflicts(moving: ["z/a"], into: "y") == [])
        #expect(model.move(["z/a"], into: "y") == .failure(.taken("a")))
        #expect(model.changes == before)
    }

    /// Replace over a folder an item was moved out of keeps that item.
    @Test func replacingAFolderAnItemWasMovedOutOfKeepsIt() {
        let model = makeModel([Self.folder("docs"), Self.file("docs/a.txt"), Self.folder("x"),
                               Self.folder("x/docs"), Self.file("x/docs/q")])
        _ = model.move(["docs/a.txt"], into: "")

        #expect(model.conflicts(moving: ["x/docs"], into: "") == ["docs"])
        #expect(model.move(["x/docs"], into: "") == .success(["x/docs": "docs"]))

        #expect(model.changes.removedPaths == ["docs"])
        #expect(model.changes.renamedPaths == ["docs/a.txt": "a.txt", "x/docs": "docs"])
        #expect(model.item(at: "a.txt") != nil && model.item(at: "docs/q") != nil)
    }

    /// By design `move` alone does Replace, as one "Move" step; undo brings back both.
    @Test func replaceIsOneMoveStep() {
        let undoManager = makeUndoManager()
        let model = makeModel(Self.entries + [Self.file("other/a.txt")], undoManager: undoManager)
        let initial = model.items

        #expect(model.conflicts(moving: ["docs/a.txt"], into: "other") == ["other/a.txt"])
        #expect(step(undoManager) { model.move(["docs/a.txt"], into: "other") } == .success(["docs/a.txt": "other/a.txt"]))
        #expect(undoManager.undoActionName == moveActionName)

        undoManager.undo()
        #expect(model.changes.isEmpty)
        #expect(model.items == initial)
        #expect(model.item(at: "docs/a.txt") != nil && model.item(at: "other/a.txt") != nil)
        #expect(!undoManager.canUndo)
    }

    /// Delete after a move out: undo, then redo, gives back both removals and the kept rename.
    @Test func deleteAfterAMoveRedoes() {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)
        _ = step(undoManager) { model.move(["docs/a.txt"], into: "") }
        #expect(step(undoManager) { model.remove(["docs"]) } == nil)
        let deleted = model.changes

        undoManager.undo()
        #expect(model.changes.removedPaths.isEmpty)
        #expect(model.changes.renamedPaths == ["docs/a.txt": "a.txt"])
        #expect(model.item(at: "docs/c.txt") != nil)

        undoManager.redo()
        #expect(model.changes == deleted)
        #expect(model.changes.removedPaths == ["docs"])
        #expect(model.changes.renamedPaths == ["docs/a.txt": "a.txt"])
        #expect(model.item(at: "a.txt") != nil && model.item(at: "docs") == nil)
        #expect(undoManager.undoActionName == String(localized: "Delete", table: "Shared"))
    }

    /// Replace: undo, then redo, replaces again as one "Move" step.
    @Test func replaceRedoes() {
        let undoManager = makeUndoManager()
        let model = makeModel(Self.entries + [Self.file("other/a.txt")], undoManager: undoManager)
        _ = step(undoManager) { model.move(["docs/a.txt"], into: "other") }
        let replaced = model.changes
        let items = model.items

        undoManager.undo()
        #expect(model.changes.isEmpty)
        undoManager.redo()

        #expect(model.changes == replaced)
        #expect(model.changes.removedPaths == ["other/a.txt"])
        #expect(model.changes.renamedPaths == ["docs/a.txt": "other/a.txt"])
        #expect(model.items == items)
        #expect(model.item(at: "docs/a.txt") == nil && model.item(at: "other/a.txt") != nil)
        #expect(undoManager.undoActionName == moveActionName)
    }

    // MARK: - Opened copies

    @Test func openedCopyFollows() async throws {
        let undoManager = makeUndoManager()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelMoveTests-\(UUID().uuidString)", isDirectory: true)
        let model = ArchiveModel(reader: FakeReader(entries: Self.entries), undoManager: undoManager,
                                 openedFiles: OpenedFiles(in: folder))
        defer {
            model.openedFiles.close()
            model.removeTemporaryFiles()
            try? FileManager.default.removeItem(at: folder)
        }
        let a = try await model.copyForOpening("docs/a.txt")
        let b = try await model.copyForOpening("other/b.txt")
        _ = step(undoManager) { model.move(["docs/a.txt", "other/b.txt"], into: "docs/sub") }
        for url in [a, b] {
            try Data("edited".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                                  ofItemAtPath: url.path)
        }
        #expect(Set(model.changedOpenedFiles().map(\.path)) == ["docs/sub/a.txt", "docs/sub/b.txt"])

        undoManager.undo()
        #expect(Set(model.changedOpenedFiles().map(\.path)) == ["docs/a.txt", "other/b.txt"])
        undoManager.redo()
        #expect(Set(model.changedOpenedFiles().map(\.path)) == ["docs/sub/a.txt", "docs/sub/b.txt"])
    }

    // MARK: - Live save (real engine, zip)

    /// A zip with no folder entry for `top` (the reader synthesizes it): move, save, reopen.
    @Test func liveMoveSurvivesASaveOnZip() async throws {
        let url = try LegacyZip.write(["docs/", "docs/a.txt", "docs/sub/", "docs/sub/d.txt", "top/x.txt", "notes"],
                                      as: .utf8)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await Archive.open(at: url)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }

        #expect(model.move(["docs/a.txt", "top/x.txt"], into: "") == .success(["docs/a.txt": "a.txt", "top/x.txt": "x.txt"]))
        #expect(model.move(["docs/sub"], into: "") == .success(["docs/sub": "sub"]))
        #expect(model.move(["notes"], into: "docs") == .success(["notes": "docs/notes"]))
        #expect(model.item(at: "top") != nil)

        #expect(model.saveProblem(as: .zip, split: false) == nil)
        let savedURL = directory.appendingPathComponent("saved.zip")
        try await ArchiveWriter.write(source: reader, changes: model.saveChanges(as: .zip), format: .zip,
                                      to: savedURL, options: model.saveOptions)
        let saved = try await Archive.open(at: savedURL)
        let files = Set(saved.entries.filter { !$0.isDirectory }.map(\.path))
        #expect(files == ["a.txt", "x.txt", "sub/d.txt", "docs/notes"])
        // The emptied synthesized folder is gone from the saved archive (open question 1).
        #expect(!saved.entries.contains { $0.path == "top" })
        #expect(saved.entries.contains { $0.path == "docs" && $0.isDirectory })

        let out = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await saved.extract(nil, to: out, progress: nil)
        for (path, original) in ["a.txt": "docs/a.txt", "x.txt": "top/x.txt", "sub/d.txt": "docs/sub/d.txt",
                                 "docs/notes": "notes"] {
            let bytes = try Data(contentsOf: out.appendingPathComponent(path))
            #expect(String(decoding: bytes, as: UTF8.self) == original, "\(path)")
        }
    }

    /// Replace over a folder holding an item moved into it: the moved-in item goes with the folder.
    @Test func liveReplaceOverAFolderHoldingAMovedInItem() async throws {
        let url = try LegacyZip.write(["a/b.txt", "t/keep.txt", "src/t/new.txt"], as: .utf8)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await Archive.open(at: url)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }

        #expect(model.move(["a/b.txt"], into: "t") == .success(["a/b.txt": "t/b.txt"]))
        #expect(model.conflicts(moving: ["src/t"], into: "") == ["t"])
        #expect(model.move(["src/t"], into: "") == .success(["src/t": "t"]))

        let saved = try await save(model, reader: reader, in: directory)
        #expect(Set(saved.entries.filter { !$0.isDirectory }.map(\.path)) == ["t/new.txt"])
    }

    /// Deleting a folder with no entry of its own after moving an item out of it keeps that item.
    @Test func liveImplicitDeleteAfterAMoveOut() async throws {
        let url = try LegacyZip.write(["top/x.txt", "top/y.txt", "keep"], as: .utf8)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await Archive.open(at: url)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }

        _ = model.move(["top/x.txt"], into: "")
        #expect(model.remove(["top"]) == nil)

        let saved = try await save(model, reader: reader, in: directory)
        #expect(Set(saved.entries.filter { !$0.isDirectory }.map(\.path)) == ["x.txt", "keep"])
        let out = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await saved.extract(nil, to: out, progress: nil)
        #expect(String(decoding: try Data(contentsOf: out.appendingPathComponent("x.txt")), as: UTF8.self) == "top/x.txt")
    }

    /// A folder entry the zip stores, deleted after an item (or one in a subfolder) was moved out: the save keeps
    /// exactly what was moved out, with its bytes; Replace over such a folder too.
    @Test(arguments: [
        (["docs/", "docs/a.txt", "docs/c.txt"], "docs/a.txt", nil as String?),
        (["docs/", "docs/x/", "docs/x/a.txt", "docs/c.txt"], "docs/x/a.txt", nil),
        (["docs/", "docs/a.txt", "docs/c.txt", "y/", "y/docs/", "y/docs/q"], "docs/a.txt", "y/docs"),
    ])
    func liveStoredFolderDeleteKeepsWhatWasMovedOut(paths: [String], moved: String, replacer: String?) async throws {
        let url = try LegacyZip.write(paths, as: .utf8)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await Archive.open(at: url)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }

        #expect(model.move([moved], into: "") == .success([moved: "a.txt"]))
        if let replacer {
            #expect(model.move([replacer], into: "") == .success([replacer: "docs"]))
        } else {
            #expect(model.remove(["docs"]) == nil)
        }

        let saved = try await save(model, reader: reader, in: directory)
        let files = Set(saved.entries.filter { !$0.isDirectory }.map(\.path))
        #expect(files == (replacer == nil ? ["a.txt"] : ["a.txt", "docs/q"]))
        if replacer == nil { #expect(!saved.entries.contains { $0.path == "docs" }) }
        let out = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await saved.extract(nil, to: out, progress: nil)
        #expect(String(decoding: try Data(contentsOf: out.appendingPathComponent("a.txt")), as: UTF8.self) == moved)
    }

    /// d/a moved into e over e/a, then Delete d, through a real save and reopen: the moved folder keeps its subtree
    /// with its bytes, nothing else survives (zip here; 7z and TAR in `ArchiveModelMoveLiveTests`).
    @Test func liveDeleteKeepsAMovedFolderReplacedInto() async throws {
        try await Self.expectDeleteKeepsAMovedFolderReplacedInto(.zip)
    }

    /// KernirCore's refill edge (e/d removed, e/d/a renamed e keeps e/d/a/d/y.txt at e/d/y.txt) needs no `e`
    /// entry, but the reader synthesizes one and the tree keeps it listed once emptied: after e/d/a moved to the
    /// top level and Delete e/d, the name e is taken; with e deleted too the rename would drop the moved folder
    /// (its key's final is the deleted e's), so it is refused. The app never produces the edge; tree and save agree.
    @Test func liveMovedFolderCannotRefillTheDeletedFoldersName() async throws {
        let url = try LegacyZip.write(["e/d/", "e/d/a/", "e/d/a/d/", "e/d/a/d/y.txt", "e/d/b.txt"], as: .utf8)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await Archive.open(at: url)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }

        #expect(model.move(["e/d/a"], into: "") == .success(["e/d/a": "a"]))
        #expect(model.remove(["e/d"]) == nil)
        #expect(model.item(at: "e")?.isDirectory == true)
        #expect(model.rename("a", to: "e") == .failure(.taken("e")))
        #expect(model.remove(["e"]) == nil)
        let before = model.changes
        #expect(model.rename("a", to: "e") == .failure(.holdsMovedOutItems("e")))

        #expect(model.changes == before)
        #expect(model.changes.renamedPaths == ["e/d/a": "a"])
        let shown = Set(model.items.flattened().filter { !$0.isDirectory }.map(\.path))
        #expect(shown == ["a/d/y.txt"])
        let saved = try await save(model, reader: reader, in: directory)
        #expect(Set(saved.entries.filter { !$0.isDirectory }.map(\.path)) == shown)
        let out = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await saved.extract(nil, to: out, progress: nil)
        #expect(String(decoding: try Data(contentsOf: out.appendingPathComponent("a/d/y.txt")), as: UTF8.self)
                == "e/d/a/d/y.txt")
    }

    /// The zip `paths` (`LegacyZip`, each file holding its own path), converted to `format` when that is not zip.
    static func liveArchive(_ paths: [String], as format: ArchiveFormat) async throws
        -> (reader: any ArchiveReading, directory: URL) {
        let url = try LegacyZip.write(paths, as: .utf8)
        let directory = url.deletingLastPathComponent()
        let zip = try await Archive.open(at: url)
        guard format != .zip else { return (zip, directory) }
        let converted = directory.appendingPathComponent("source-\(UUID().uuidString)")
        try await ArchiveWriter.write(source: zip, changes: ArchiveChangeSet(), format: format, to: converted)
        return (try await Archive.open(at: converted), directory)
    }

    /// d/a moved into e over e/a, then Delete d, saved as `format` and reopened: e/a/x.txt and e/a/b/z.txt with
    /// their bytes, e/c.txt, and nothing of d or the replaced e/a.
    static func expectDeleteKeepsAMovedFolderReplacedInto(_ format: ArchiveFormat) async throws {
        let (reader, directory) = try await liveArchive(["d/", "d/a/", "d/a/x.txt", "d/a/b/", "d/a/b/z.txt", "d/b.txt",
                                                         "e/", "e/a/", "e/a/y.txt", "e/c.txt"], as: format)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }

        #expect(model.move(["d/a"], into: "e") == .success(["d/a": "e/a"]))
        #expect(model.remove(["d"]) == nil)
        let shown = Set(model.items.flattened().filter { !$0.isDirectory }.map(\.path))
        #expect(shown == ["e/a/x.txt", "e/a/b/z.txt", "e/c.txt"])

        #expect(model.saveProblem(as: format, split: false) == nil)
        let savedURL = directory.appendingPathComponent("saved-\(UUID().uuidString)")
        try await ArchiveWriter.write(source: reader, changes: model.saveChanges(as: format), format: format,
                                      to: savedURL, options: model.saveOptions)
        let saved = try await Archive.open(at: savedURL)
        #expect(Set(saved.entries.filter { !$0.isDirectory }.map(\.path)) == shown)
        #expect(!saved.entries.contains { $0.path == "d" || $0.path.hasPrefix("d/") })
        let out = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await saved.extract(nil, to: out, progress: nil)
        for (path, original) in ["e/a/x.txt": "d/a/x.txt", "e/a/b/z.txt": "d/a/b/z.txt", "e/c.txt": "e/c.txt"] {
            #expect(String(decoding: try Data(contentsOf: out.appendingPathComponent(path)), as: UTF8.self)
                    == original, "\(path)")
        }
    }

    private func save(_ model: ArchiveModel, reader: any ArchiveReading, in directory: URL) async throws -> any ArchiveReading {
        #expect(model.saveProblem(as: .zip, split: false) == nil)
        let savedURL = directory.appendingPathComponent("saved-\(UUID().uuidString).zip")
        try await ArchiveWriter.write(source: reader, changes: model.saveChanges(as: .zip), format: .zip,
                                      to: savedURL, options: model.saveOptions)
        return try await Archive.open(at: savedURL)
    }
}

/// The same Delete through a real save on the 7z and TAR fixtures: `docs` is an entry of the archive.
@MainActor @Suite(.enabled(if: Fixture.isReadable))
struct ArchiveModelMoveLiveTests {
    @Test(arguments: [("7z/lzma2.7z", ArchiveFormat.sevenZip), ("tar/basic.tar", ArchiveFormat.tar)])
    func deletingAFolderKeepsWhatWasMovedOut(file: String, format: ArchiveFormat) async throws {
        let url = try Fixture.copy(file)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await Archive.open(at: url)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }
        #expect(reader.entries.contains { $0.path == "docs" && $0.isDirectory })

        _ = model.move(["docs/notes.txt", "docs/nested/deep/data.bin"], into: "")
        #expect(model.remove(["docs"]) == nil)

        #expect(model.saveProblem(as: format, split: false) == nil)
        let savedURL = directory.appendingPathComponent("saved-\(UUID().uuidString)")
        try await ArchiveWriter.write(source: reader, changes: model.saveChanges(as: format), format: format,
                                      to: savedURL, options: model.saveOptions)
        let saved = try await Archive.open(at: savedURL)
        var sizes: [String: Int64] = [:]
        for entry in saved.entries where !entry.isDirectory { sizes[entry.path] = entry.size ?? -1 }
        #expect(sizes == ["notes.txt": 20000, "data.bin": 70000, "empty.txt": 0, "hello.txt": 15])
        #expect(Set(saved.entries.filter(\.isDirectory).map(\.path)) == ["empty-dir"])
    }
}

/// The moved-folder Delete through a real save as 7z and TAR (sources converted from a zip).
@MainActor @Suite struct ArchiveModelMoveFolderLiveTests {
    @Test(arguments: [ArchiveFormat.sevenZip, .tar])
    func deleteKeepsAMovedFolderReplacedInto(_ format: ArchiveFormat) async throws {
        try await ArchiveModelMoveTests.expectDeleteKeepsAMovedFolderReplacedInto(format)
    }
}
