import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Rename and New Folder as undoable model edits (engine contract: `renamedPaths` keys are the
/// reader's exact source paths, pending additions are renamed through `Addition.archiveName`).
@MainActor @Suite struct ArchiveModelRenameTests {
    private static func file(_ path: String, size: Int64 = 1) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: size, modificationDate: nil)
    }

    private static func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }

    private static let entries = [
        folder("docs"), file("docs/a.txt"), file("docs/c.txt"), folder("docs/sub"), file("docs/sub/d.txt"),
        file("README"), file("notes"),
    ]

    private func makeModel(_ entries: [ArchiveEntry] = entries, format: ArchiveFormat = .zip,
                           undoManager: UndoManager? = nil) -> ArchiveModel {
        ArchiveModel(reader: FakeReader(entries: entries, format: format), undoManager: undoManager)
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

    /// A fresh folder holding a file `name`; the caller removes the folder.
    private func makeFile(_ name: String, contents: String = "hello") throws -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelRenameTests-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return (folder, file)
    }

    private func isSameSpelling(_ a: String?, _ b: String) -> Bool {
        a.map { $0.unicodeScalars.elementsEqual(b.unicodeScalars) } ?? false
    }

    private var renameActionName: String { String(localized: "Rename", table: "Shared") }
    private var newFolderActionName: String { String(localized: "New Folder", table: "Shared") }

    // MARK: - Source items

    @Test func renameSourceFile() {
        let model = makeModel()

        let result = model.rename("docs/a.txt", to: "b.txt")

        #expect(result == .success("docs/b.txt"))
        #expect(model.item(at: "docs/b.txt") != nil)
        #expect(model.item(at: "docs/a.txt") == nil)
        #expect(model.changes.renamedPaths == ["docs/a.txt": "docs/b.txt"])
        #expect(model.changes.removedPaths.isEmpty)
        #expect(model.changes.additions.isEmpty)
        #expect(model.hasChanges)
        #expect(model.children(of: "docs").map(\.name) == ["sub", "b.txt", "c.txt"])
    }

    @Test func renameBackClearsEdit() {
        let model = makeModel()

        _ = model.rename("docs/a.txt", to: "b.txt")
        _ = model.rename("docs/b.txt", to: "a.txt")

        #expect(model.changes.isEmpty)
        #expect(!model.hasChanges)
        #expect(model.item(at: "docs/a.txt") != nil)
    }

    @Test func chainCollapsesToTheSourceKey() {
        let model = makeModel()

        _ = model.rename("docs/a.txt", to: "b.txt")
        _ = model.rename("docs/b.txt", to: "e.txt")

        #expect(model.changes.renamedPaths == ["docs/a.txt": "docs/e.txt"])
    }

    @Test func renameFolderMovesChildren() {
        let model = makeModel()

        #expect(model.rename("docs", to: "papers") == .success("papers"))

        #expect(model.changes.renamedPaths == ["docs": "papers"])
        #expect(model.item(at: "docs") == nil)
        #expect(model.item(at: "docs/a.txt") == nil)
        for path in ["papers", "papers/a.txt", "papers/c.txt", "papers/sub", "papers/sub/d.txt"] {
            #expect(model.item(at: path) != nil, "\(path)")
        }
        #expect(model.item(at: "papers")?.isPendingAddition == false)
    }

    /// The folder's own rename and a child's fold into one map; renaming the folder back keeps the child's.
    @Test func renameChildOfRenamedFolderThenFolderBack() {
        let model = makeModel()

        _ = model.rename("docs", to: "papers")
        _ = model.rename("papers/a.txt", to: "b.txt")
        _ = model.rename("papers", to: "docs")

        #expect(model.changes.renamedPaths == ["docs/a.txt": "docs/b.txt"])
        #expect(model.item(at: "docs/b.txt") != nil)
    }

    /// A folder then a child, or a child then its folder: either order gives the same map and tree.
    @Test func nestedRenamesInEitherOrder() {
        let folderFirst = makeModel()
        #expect(folderFirst.rename("docs", to: "papers") == .success("papers"))
        #expect(folderFirst.rename("papers/a.txt", to: "b.txt") == .success("papers/b.txt"))
        #expect(folderFirst.rename("papers/sub", to: "inner") == .success("papers/inner"))

        let childFirst = makeModel()
        #expect(childFirst.rename("docs/sub", to: "inner") == .success("docs/inner"))
        #expect(childFirst.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))
        #expect(childFirst.rename("docs", to: "papers") == .success("papers"))

        let expected = ["docs": "papers", "docs/a.txt": "papers/b.txt", "docs/sub": "papers/inner"]
        for model in [folderFirst, childFirst] {
            #expect(model.changes.renamedPaths == expected)
            for path in ["papers/b.txt", "papers/c.txt", "papers/inner", "papers/inner/d.txt"] {
                #expect(model.item(at: path) != nil, "\(path)")
            }
            for path in ["docs", "papers/a.txt", "papers/sub", "docs/b.txt", "docs/inner"] {
                #expect(model.item(at: path) == nil, "\(path)")
            }
        }
        #expect(folderFirst.items == childFirst.items)
    }

    /// Keys are the reader's exact source paths, never normalized.
    @Test func keyIsTheSourceSpelling() {
        let nfd = "Cafe\u{301}.txt"
        let model = makeModel([Self.file(nfd)])

        #expect(model.rename("Café.txt", to: "menu.txt") == .success("menu.txt"))

        #expect(model.changes.renamedPaths.count == 1)
        #expect(isSameSpelling(model.changes.renamedPaths.keys.first, nfd))
        #expect(model.changes.renamedPaths.values.first == "menu.txt")
    }

    /// A folder the archive spells both NFC and NFD is one item; one key (the tree's spelling) moves both
    /// spellings, as it does in the writer, where they are one key (and one to a Swift dictionary).
    @Test func folderSpelledTwoWaysMovesBothSpellings() {
        let model = makeModel([Self.file("Cafe\u{301}/a"), Self.file("Caf\u{e9}/b")])

        #expect(model.rename("Café", to: "Menu") == .success("Menu"))

        #expect(model.changes.renamedPaths.count == 1)
        #expect(isSameSpelling(model.changes.renamedPaths.keys.first, "Cafe\u{301}"))
        #expect(model.changes.renamedPaths.values.first == "Menu")
        #expect(model.item(at: "Menu/a") != nil)
        #expect(model.item(at: "Menu/b") != nil)
        #expect(model.items.map(\.name) == ["Menu"])
    }

    @Test func caseOnlySiblingAllowed() {
        let model = makeModel()

        #expect(model.rename("notes", to: "Readme") == .success("Readme"))

        #expect(model.item(at: "README") != nil)
        #expect(model.item(at: "Readme") != nil)
        #expect(model.changes.renamedPaths == ["notes": "Readme"])
    }

    @Test func caseOnlySelfRename() {
        let model = makeModel()

        #expect(model.rename("notes", to: "NOTES") == .success("NOTES"))

        #expect(model.item(at: "NOTES")?.name == "NOTES")
        #expect(model.changes.renamedPaths == ["notes": "NOTES"])
    }

    @Test func leadingDotNameAllowed() {
        let model = makeModel()

        #expect(model.rename("notes", to: ".notes") == .success(".notes"))
        #expect(model.item(at: ".notes") != nil)
    }

    @Test func takenNameRefused() {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)

        let result = step(undoManager) { model.rename("docs/a.txt", to: "c.txt") }

        #expect(result == .failure(.taken("c.txt")))
        #expect(model.changes.isEmpty)
        // Nothing registered (the empty group counts for `canUndo`, so check the step's name).
        #expect(undoManager.undoActionName.isEmpty)
    }

    @Test func invalidNamesRefused() {
        let model = makeModel()

        #expect(model.rename("notes", to: "") == .failure(.empty))
        #expect(model.rename("notes", to: "..") == .failure(.reserved))
        #expect(model.rename("notes", to: ".") == .failure(.reserved))
        #expect(model.rename("notes", to: "a/b") == .failure(.containsSlash))
        #expect(model.rename("notes", to: "._notes") == .failure(.hiddenMetadata))
        #expect(model.rename("notes", to: "__MACOSX") == .failure(.hiddenMetadata))
        #expect(model.rename("notes", to: ".DS_Store") == .failure(.hiddenMetadata))
        #expect(model.changes.isEmpty)
    }

    @Test func unchangedNameIsNoEdit() {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)

        let result = step(undoManager) { model.rename("notes", to: "notes") }

        #expect(result == .success("notes"))
        #expect(model.check(renaming: "notes", to: "notes") == .unchanged)
        #expect(model.changes.isEmpty)
        // Nothing registered (the empty group counts for `canUndo`, so check the step's name).
        #expect(undoManager.undoActionName.isEmpty)
    }

    @Test func missingItemRefused() {
        let model = makeModel()

        #expect(model.rename("nope", to: "x") == .failure(.unavailable))
        #expect(model.changes.isEmpty)
    }

    @Test func checkSeesSiblingsOfTheItemsFolder() {
        let model = makeModel()

        #expect(model.check(renaming: "docs/a.txt", to: "c.txt") == .invalid(.taken("c.txt")))
        // "README" is a top-level name, not a sibling in docs.
        #expect(model.check(renaming: "docs/a.txt", to: "README") == .valid("README"))
    }

    /// A folder holding only Finder metadata is hidden, but its kept entries still end up at that path: with
    /// metadata kept on save the writer would put the renamed item and `x/._y` on one path and fail.
    @Test func nameOfAHiddenOnlyFolderIsTaken() {
        let model = makeModel([Self.file("a"), Self.file("x/._y")])
        #expect(model.item(at: "x") == nil)

        #expect(model.check(renaming: "a", to: "x") == .invalid(.taken("x")))
        #expect(model.rename("a", to: "x") == .failure(.taken("x")))
        #expect(model.changes.isEmpty)
    }

    /// The same behind a hidden "/": the only entry below `x` starts with a combining mark, so "/" and the
    /// mark are one Character. Inside is on the "/" scalar, so `x` is still taken.
    @Test func nameOfAHiddenOnlyFolderIsTakenBehindAHiddenSlash() {
        let model = makeModel([Self.file("a"), Self.file("x/\u{301}y/._z")])
        #expect(model.item(at: "x") == nil)

        #expect(model.check(renaming: "a", to: "x") == .invalid(.taken("x")))
        #expect(model.rename("a", to: "x") == .failure(.taken("x")))
        #expect(model.changes.isEmpty)
    }

    /// The hidden folder moves with its parent's rename, so the old path is free and the new one taken.
    @Test func hiddenOnlyFolderNameFollowsItsParentsRename() {
        let model = makeModel([Self.folder("d"), Self.file("d/a"), Self.file("d/x/._y")])

        _ = model.rename("d", to: "e")

        #expect(model.check(renaming: "e/a", to: "x") == .invalid(.taken("x")))
        #expect(model.check(renaming: "e", to: "d") == .valid("d"))
    }

    /// A removed item's name is free again, and so is that of a hidden-only folder inside a removed folder.
    @Test func removedSourceNamesAreFree() {
        let model = makeModel(Self.entries + [Self.file("docs/x/._y")])

        model.remove(["docs/c.txt"])
        #expect(model.check(renaming: "docs/a.txt", to: "c.txt") == .valid("c.txt"))
        model.remove(["docs"])
        #expect(model.check(renaming: "notes", to: "docs") == .valid("docs"))
    }

    @Test func companionsFollow() {
        let model = makeModel(Self.entries + [Self.file("docs/._a.txt"), Self.folder("__MACOSX"),
                                              Self.folder("__MACOSX/docs"), Self.file("__MACOSX/docs/._a.txt")])

        _ = model.rename("docs/a.txt", to: "b.txt")

        #expect(model.changes.renamedPaths == [
            "docs/a.txt": "docs/b.txt",
            "docs/._a.txt": "docs/._b.txt",
            "__MACOSX/docs/._a.txt": "__MACOSX/docs/._b.txt",
        ])
        #expect(model.item(at: "docs/._b.txt") == nil)
    }

    /// The target name has an orphan companion (`._new`, kept, with no `new` beside it): the rename goes ahead,
    /// a companion move onto the orphan is skipped (the writer refuses two entries on one path), so `._old` stays
    /// and `new` pairs with the orphan's fork; a companion with a free target still moves.
    @Test func companionMoveOntoAnOrphanCompanionIsSkipped() {
        let entries = [Self.file("old"), Self.file("._old"), Self.file("__MACOSX/._old"), Self.file("._new")]
        let model = makeModel(entries)

        #expect(model.rename("old", to: "new") == .success("new"))

        #expect(model.changes.renamedPaths == ["old": "new", "__MACOSX/._old": "__MACOSX/._new"])
        let finalPaths = entries.map { model.changes.renamedPaths[$0.path] ?? $0.path }
        #expect(Set(finalPaths).count == entries.count)
    }

    /// A folder's companions follow too, including a `__MACOSX` folder the archive stores only implicitly.
    @Test func folderCompanionsFollow() {
        let model = makeModel(Self.entries + [Self.file("__MACOSX/docs/._a.txt"), Self.file("._docs")])

        _ = model.rename("docs", to: "papers")

        #expect(model.changes.renamedPaths == [
            "docs": "papers", "__MACOSX/docs": "__MACOSX/papers", "._docs": "._papers",
        ])
        // The child's companion stays beneath its folder's: renaming the child folds into the folder's move.
        _ = model.rename("papers/a.txt", to: "b.txt")
        #expect(model.changes.renamedPaths["__MACOSX/docs/._a.txt"] == "__MACOSX/papers/._b.txt")
    }

    @Test func deleteRenamedItemRemovesItsSource() {
        let model = makeModel()

        _ = model.rename("docs/a.txt", to: "b.txt")
        model.remove(["docs/b.txt"])

        #expect(model.changes.removedPaths == ["docs/a.txt"])
        #expect(model.changes.renamedPaths.isEmpty)
        #expect(model.item(at: "docs/b.txt") == nil)
        #expect(model.item(at: "docs/a.txt") == nil)
    }

    @Test func deleteChildOfRenamedFolderRemovesItsSource() {
        let model = makeModel()

        _ = model.rename("docs", to: "papers")
        model.remove(["papers/a.txt"])

        #expect(model.changes.removedPaths == ["docs/a.txt"])
        #expect(model.changes.renamedPaths == ["docs": "papers"])
        #expect(model.item(at: "papers/a.txt") == nil)
        #expect(model.item(at: "papers/c.txt") != nil)
    }

    /// The old name is free after a rename: adding a file there must not remove the renamed source entry.
    @Test func addingAtTheOldNameKeepsTheRenamedItem() throws {
        let (dir, newFile) = try makeFile("a.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()

        _ = model.rename("docs/a.txt", to: "b.txt")
        model.add([newFile], to: "docs")

        #expect(model.changes.removedPaths.isEmpty)
        #expect(model.changes.renamedPaths == ["docs/a.txt": "docs/b.txt"])
        #expect(model.item(at: "docs/a.txt")?.isPendingAddition == true)
        #expect(model.item(at: "docs/b.txt")?.isPendingAddition == false)
    }

    /// Replacing a renamed item by adding a file at its new name removes the item's source entry.
    @Test func addingAtTheNewNameReplacesTheRenamedItem() throws {
        let (dir, newFile) = try makeFile("b.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()

        _ = model.rename("docs/a.txt", to: "b.txt")
        model.add([newFile], to: "docs")

        #expect(model.changes.removedPaths == ["docs/a.txt"])
        #expect(model.changes.renamedPaths.isEmpty)
        #expect(model.item(at: "docs/b.txt")?.isPendingAddition == true)
    }

    /// `readerPath` maps a renamed item back to its source entry.
    @Test func renamedFileReadsItsSourceEntry() async throws {
        let model = makeModel()
        _ = model.rename("docs/a.txt", to: "b.txt")

        let url = try await model.localFileURL(for: "docs/b.txt")

        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "docs/a.txt")
    }

    // MARK: - Pending items

    @Test func renamePendingFile() throws {
        let (dir, oldFile) = try makeFile("old.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        model.add([oldFile], to: "")

        #expect(model.rename("old.txt", to: "new.txt") == .success("new.txt"))

        #expect(model.changes.renamedPaths.isEmpty)
        #expect(model.changes.additions.count == 1)
        #expect(model.changes.additions.first?.archiveName == "new.txt")
        #expect(model.changes.additions.first?.destinationDirectory == "")
        #expect(model.item(at: "new.txt")?.isPendingAddition == true)
        #expect(model.item(at: "old.txt") == nil)
    }

    @Test func renamePendingFileBackClearsArchiveName() throws {
        let (dir, oldFile) = try makeFile("old.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        model.add([oldFile], to: "")

        _ = model.rename("old.txt", to: "new.txt")
        _ = model.rename("new.txt", to: "old.txt")

        #expect(model.changes.additions.first?.archiveName == nil)
    }

    @Test func renameFolderMovesPendingAdditions() throws {
        let (dir, newFile) = try makeFile("x.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        model.add([newFile], to: "docs/sub")

        _ = model.rename("docs", to: "papers")

        #expect(model.changes.additions.first?.destinationDirectory == "papers/sub")
        #expect(model.item(at: "papers/sub/x.txt")?.isPendingAddition == true)
        #expect(model.item(at: "docs/sub/x.txt") == nil)
        #expect(model.changes.renamedPaths == ["docs": "papers"])
    }

    /// Pending additions in a folder whose name starts with a combining mark move with a renamed folder above:
    /// split on the "/" scalar, never on Characters.
    @Test func renameFolderMovesPendingAdditionsBehindAHiddenSlash() throws {
        let (dir, newFile) = try makeFile("x.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel([Self.folder("docs"), Self.folder("docs/\u{301}sub"), Self.file("docs/\u{301}sub/d.txt")])
        model.add([newFile], to: "docs/\u{301}sub")

        _ = model.rename("docs", to: "papers")

        #expect(isSameSpelling(model.changes.additions.first?.destinationDirectory, "papers/\u{301}sub"))
        #expect(model.item(at: "papers/\u{301}sub/x.txt")?.isPendingAddition == true)
        #expect(model.item(at: "docs/\u{301}sub/x.txt") == nil)
    }

    /// Selection and expansion follow a rename beneath a hidden "/" too, byte for byte.
    @Test func remapFollowsPathsBehindAHiddenSlash() {
        let remapped = ArchiveModel.remap(["d", "d/\u{301}x", "d/\u{301}x/y", "dx", "e/d"], from: "d", to: "f")
        #expect(Set(remapped.map { Array($0.utf8) }) ==
                Set(["f", "f/\u{301}x", "f/\u{301}x/y", "dx", "e/d"].map { Array($0.utf8) }))
    }

    @Test func renameFileInsideAddedFolder() throws {
        let (dir, _) = try makeFile("a.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("bb".utf8).write(to: dir.appendingPathComponent("b.txt"))
        let model = makeModel()
        model.add([dir], to: "")
        let top = dir.lastPathComponent

        #expect(model.rename("\(top)/a.txt", to: "z.txt") == .success("\(top)/z.txt"))

        #expect(model.item(at: "\(top)/z.txt")?.isPendingAddition == true)
        #expect(model.item(at: "\(top)/a.txt") == nil)
        #expect(model.item(at: "\(top)/b.txt")?.isPendingAddition == true)
        #expect(model.changes.renamedPaths.isEmpty)
        let renamed = model.changes.additions.first { $0.archiveName == "z.txt" }
        #expect(renamed?.sourceURL.lastPathComponent == "a.txt")
        #expect(renamed?.destinationDirectory == top)
        // The folder's other child still goes in, and nothing goes in twice.
        #expect(model.changes.additions.filter { $0.sourceURL.lastPathComponent == "b.txt" }.count == 1)
        #expect(!model.changes.additions.contains { $0.sourceURL.lastPathComponent == top })
    }

    // MARK: - Undo

    @Test func undoRedoRename() {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)
        let initial = model.items

        step(undoManager) { _ = model.rename("docs/a.txt", to: "b.txt") }
        #expect(undoManager.undoActionName == renameActionName)
        let renamed = (changes: model.changes, items: model.items)

        undoManager.undo()
        #expect(model.changes.isEmpty)
        #expect(model.items == initial)

        undoManager.redo()
        #expect(model.changes == renamed.changes)
        #expect(model.items == renamed.items)
    }

    /// New Folder, a source rename and a rename of the new folder are three steps: undone in reverse order
    /// back to the opened archive, redone in order back to the same tree, change set and staged folder.
    @Test func undoRedoNewFolderAndRenames() throws {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)
        defer { model.removeTemporaryFiles() }
        let initial = model.items

        let folder = try step(undoManager) { try model.newFolder(in: "docs") }
        let afterNewFolder = (changes: model.changes, items: model.items)
        _ = step(undoManager) { model.rename("README", to: "READ ME") }
        let afterRename = (changes: model.changes, items: model.items)
        #expect(step(undoManager) { model.rename(folder, to: "Photos") } == .success("docs/Photos"))
        let final = (changes: model.changes, items: model.items)
        let staged = try #require(model.changes.additions.first?.sourceURL)

        undoManager.undo()
        #expect(model.changes == afterRename.changes)
        #expect(model.items == afterRename.items)
        #expect(undoManager.undoActionName == renameActionName)
        undoManager.undo()
        #expect(model.changes == afterNewFolder.changes)
        #expect(model.items == afterNewFolder.items)
        #expect(undoManager.undoActionName == newFolderActionName)
        undoManager.undo()
        #expect(model.changes.isEmpty)
        #expect(model.items == initial)
        #expect(!undoManager.canUndo)

        undoManager.redo()
        #expect(model.changes == afterNewFolder.changes)
        #expect(model.item(at: "docs/untitled folder")?.isPendingAddition == true)
        undoManager.redo()
        #expect(model.changes == afterRename.changes)
        undoManager.redo()
        #expect(model.changes == final.changes)
        #expect(model.items == final.items)
        #expect(model.changes.renamedPaths == ["README": "READ ME"])
        #expect(model.changes.additions.map(\.archiveName) == ["Photos"])
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(!undoManager.canRedo)
    }

    @Test func undoRenameRestoresSelectionPaths() {
        #expect(ArchiveModel.remap(["docs/a.txt", "x"], from: "docs/a.txt", to: "docs/b.txt") == ["docs/b.txt", "x"])
        #expect(ArchiveModel.remap(["docs", "docs/sub/d.txt", "docsx", "README"], from: "docs", to: "papers")
                == ["papers", "papers/sub/d.txt", "docsx", "README"])
        // Undo maps back the other way.
        #expect(ArchiveModel.remap(["docs/b.txt"], from: "docs/b.txt", to: "docs/a.txt") == ["docs/a.txt"])
    }

    // MARK: - New Folder

    @Test func newFolderNamesAndStages() throws {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)
        defer { model.removeTemporaryFiles() }

        let first = try step(undoManager) { try model.newFolder(in: "") }
        let second = try step(undoManager) { try model.newFolder(in: "") }

        #expect(first == "untitled folder")
        #expect(second == "untitled folder 2")
        for path in [first, second] {
            #expect(model.item(at: path)?.isDirectory == true)
            #expect(model.item(at: path)?.isPendingAddition == true)
            #expect(model.item(at: path)?.children?.isEmpty ?? true)
        }
        #expect(model.changes.renamedPaths.isEmpty)
        #expect(undoManager.undoActionName == newFolderActionName)

        undoManager.undo()
        #expect(model.item(at: second) == nil)
        #expect(model.item(at: first) != nil)
    }

    @Test func newFolderInsideAFolder() throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }

        let path = try model.newFolder(in: "docs")

        #expect(path == "docs/untitled folder")
        #expect(model.changes.additions.first?.destinationDirectory == "docs")
        #expect(model.changes.additions.first?.archiveName == nil)
        #expect(model.changes.additions.first?.sourceURL.lastPathComponent == "untitled folder")
    }

    /// A folder holding only Finder metadata is hidden, but its kept entries still end up at that path (as for
    /// `check(renaming:)`): New Folder never picks its name, nor a case twin of it.
    @Test func newFolderSkipsTheNamesOfHiddenOnlyFolders() throws {
        let model = makeModel([Self.file("a"), Self.file("untitled folder/._y"), Self.file("Untitled Folder 2/._z"),
                               Self.file("a2/untitled folder 3/._q")])
        defer { model.removeTemporaryFiles() }
        #expect(model.item(at: "untitled folder") == nil)

        // One in another folder takes nothing here.
        #expect(try model.newFolder(in: "") == "untitled folder 3")
    }

    /// A hidden-only folder whose only entry's name starts with a combining mark still takes its name: the
    /// name ends at the "/" scalar, not at a Character.
    @Test func newFolderSkipsAHiddenOnlyFolderBehindAHiddenSlash() throws {
        let model = makeModel([Self.file("a"), Self.file("untitled folder/\u{301}z/._y"),
                               Self.file("d/untitled folder/\u{301}z/._y")])
        defer { model.removeTemporaryFiles() }

        #expect(try model.newFolder(in: "") == "untitled folder 2")
    }

    /// A crafted archive with thousands of hidden-only "untitled folder N" folders: New Folder reads the
    /// hidden names once rather than rescanning every entry for each name it tries.
    @Test func newFolderSkipsManyHiddenOnlyFoldersQuickly() throws {
        let count = 2_000
        let hidden = (1...count).map { number in
            Self.file(number == 1 ? "untitled folder/._x" : "Untitled Folder \(number)/._x")
        }
        let model = makeModel([Self.file("a")] + hidden)
        defer { model.removeTemporaryFiles() }

        let clock = ContinuousClock()
        var path = ""
        let elapsed = try clock.measure { path = try model.newFolder(in: "") }

        #expect(path == "untitled folder \(count + 1)")
        #expect(elapsed < .seconds(5), "\(elapsed)")
    }

    /// The hidden folder's name moves with its parent's rename, and a removed one's is free again.
    @Test func newFolderSeesHiddenOnlyFoldersWhereTheyEndUp() throws {
        let model = makeModel([Self.folder("d"), Self.file("d/a"), Self.file("d/untitled folder/._y"),
                               Self.file("untitled folder/x"), Self.file("untitled folder/._x")])
        defer { model.removeTemporaryFiles() }

        _ = model.rename("d", to: "e")
        #expect(try model.newFolder(in: "e") == "e/untitled folder 2")

        // Its companion goes with the removed file, so nothing is left at "untitled folder".
        model.remove(["untitled folder/x"])
        #expect(model.changes.removedPaths == ["untitled folder/x", "untitled folder/._x"])
        #expect(try model.newFolder(in: "") == "untitled folder")
    }

    /// The staged folder is the model's own, empty, and outlives a save (it is removed on close only).
    @Test func newFolderIsStagedOnDiskUntilClose() throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }

        _ = try model.newFolder(in: "")
        let url = try #require(model.changes.additions.first?.sourceURL)
        #expect(url.lastPathComponent == "untitled folder")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            .hasPrefix("Kernir-NewFolders-"))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: url.path)) == [])

        model.didSave(reader: FakeReader(entries: Self.entries))
        #expect(FileManager.default.fileExists(atPath: url.path))

        model.removeTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func newFolderThenRenameIsTwoSteps() throws {
        let undoManager = makeUndoManager()
        let model = makeModel(undoManager: undoManager)
        defer { model.removeTemporaryFiles() }

        let path = try step(undoManager) { try model.newFolder(in: "") }
        let renamed = step(undoManager) { model.rename(path, to: "Photos") }

        #expect(renamed == .success("Photos"))
        #expect(model.changes.additions.first?.archiveName == "Photos")
        #expect(model.changes.renamedPaths.isEmpty)
        #expect(undoManager.undoActionName == renameActionName)

        undoManager.undo()
        #expect(model.item(at: "untitled folder") != nil)
        #expect(model.item(at: "Photos") == nil)
        undoManager.undo()
        #expect(model.item(at: "untitled folder") == nil)
        #expect(model.changes.isEmpty)
    }

    /// A file added into a new folder moves with the folder's rename.
    @Test func renameNewFolderMovesItsAdditions() throws {
        let (dir, newFile) = try makeFile("x.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        defer { model.removeTemporaryFiles() }

        let path = try model.newFolder(in: "")
        model.add([newFile], to: path)
        _ = model.rename(path, to: "Photos")

        #expect(model.item(at: "Photos/x.txt")?.isPendingAddition == true)
        #expect(model.changes.additions.map(\.destinationDirectory) == ["", "Photos"])
    }

    /// New Folder in a renamed source folder goes to its new path and sees the source children that moved
    /// with it; renaming the folder back takes the new folder along.
    @Test func newFolderInsideARenamedFolder() throws {
        let model = makeModel(Self.entries + [Self.folder("docs/untitled folder"), Self.file("docs/untitled folder/x")])
        defer { model.removeTemporaryFiles() }
        _ = model.rename("docs", to: "papers")

        #expect(throws: ArchiveError.entryNotFound("docs")) { try model.newFolder(in: "docs") }
        let path = try model.newFolder(in: "papers")

        #expect(path == "papers/untitled folder 2")
        #expect(model.item(at: path)?.isPendingAddition == true)
        #expect(model.changes.additions.map(\.destinationDirectory) == ["papers"])
        #expect(model.changes.renamedPaths == ["docs": "papers"])

        #expect(model.rename("papers", to: "docs") == .success("docs"))
        #expect(model.changes.renamedPaths.isEmpty)
        #expect(model.changes.additions.map(\.destinationDirectory) == ["docs"])
        #expect(model.item(at: "docs/untitled folder 2")?.isPendingAddition == true)
        #expect(model.item(at: "docs/untitled folder/x") != nil)
    }

    @Test func newFolderInAMissingFolderThrows() {
        let model = makeModel()

        #expect(throws: ArchiveError.entryNotFound("nope")) { try model.newFolder(in: "nope") }
        #expect(throws: ArchiveError.entryNotFound("notes")) { try model.newFolder(in: "notes") }
        #expect(model.changes.isEmpty)
    }

    // MARK: - Not editable

    @Test func notEditableRefuses() {
        let model = makeModel(format: .rar)

        #expect(model.rename("docs/a.txt", to: "b.txt") == .failure(.unavailable))
        #expect(throws: ArchiveError.readOnlyFormat(.rar)) { try model.newFolder(in: "") }
        #expect(model.changes.isEmpty)
        #expect(model.item(at: "docs/a.txt") != nil)
    }

    @Test func multiVolumeRefuses() {
        let parts = [URL(fileURLWithPath: "/tmp/a.zip.001"), URL(fileURLWithPath: "/tmp/a.zip.002")]
        let model = ArchiveModel(reader: FakeReader(entries: Self.entries, volumeURLs: parts), undoManager: nil)

        #expect(model.rename("notes", to: "x") == .failure(.unavailable))
        #expect(throws: ArchiveError.self) { try model.newFolder(in: "") }
        #expect(model.changes.isEmpty)
    }

    /// A split (multi-volume) source is read-only (Save As writes one archive): no rename of a folder or of a
    /// nested item, no New Folder anywhere, and nothing reaches the undo stack or the tree.
    @Test func splitSourceRefusesEveryRenameAndNewFolder() {
        let parts = [URL(fileURLWithPath: "/tmp/a.zip.001"), URL(fileURLWithPath: "/tmp/a.zip.002"),
                     URL(fileURLWithPath: "/tmp/a.zip.003")]
        let undoManager = makeUndoManager()
        let model = ArchiveModel(reader: FakeReader(entries: Self.entries, volumeURLs: parts), undoManager: undoManager)
        let initial = model.items
        #expect(!model.isEditable)

        // No undo grouping around the calls: an explicit empty group would itself count as undoable.
        #expect(model.rename("docs", to: "papers") == .failure(.unavailable))
        #expect(model.rename("docs/sub/d.txt", to: "e.txt") == .failure(.unavailable))
        #expect(throws: ArchiveError.readOnlyFormat(.zip)) { try model.newFolder(in: "") }
        #expect(throws: ArchiveError.readOnlyFormat(.zip)) { try model.newFolder(in: "docs") }

        #expect(model.changes.isEmpty)
        #expect(model.items == initial)
        #expect(!undoManager.canUndo)
    }

    // MARK: - Extract: renamed items in staging, case twins

    /// A fresh empty folder; the caller removes it.
    private func makeOutput() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelRenameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every item under `directory`, by its name on disk (case as stored): relative path -> "dir" or contents
    /// (FakeReader's files hold their archive path).
    private func snapshot(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            result[relative] = isDirectory.boolValue ? "dir" : String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return result
    }

    /// A folder renamed onto another folder's name but for case merges with it on a volume that folds case,
    /// as folder twins in the archive do: nothing asks, nothing is left out.
    @Test func extractRenamedFolderOntoCaseTwinFolderMerges() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try #require(isCaseInsensitive(output))
        let model = makeModel([Self.folder("docs"), Self.file("docs/x.txt"), Self.folder("other"),
                               Self.file("other/y.txt")])
        #expect(model.rename("other", to: "DOCS") == .success("DOCS"))

        #expect(model.extractionConflicts(nil, in: output).isEmpty)
        let placed = try await model.extract(nil, to: output, progress: nil)

        #expect(try snapshot(output) == ["docs": "dir", "docs/x.txt": "docs/x.txt", "docs/y.txt": "other/y.txt"])
        #expect(placed.map(\.lastPathComponent) == ["docs", "docs"])
    }

    /// Folder twins in the archive are written as one folder on a volume that folds case, so a rename that
    /// gives one of them a name of its own can't take its contents out of the other's. Nothing moves, also
    /// when the other is written child by child (its Finder metadata is left out).
    @Test(arguments: [false, true])
    func extractFolderTwinsSplitByARenameMovesNothing(otherWithMetadata: Bool) async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try #require(isCaseInsensitive(output))
        let model = makeModel([Self.folder("docs"), Self.file("docs/x.txt"), Self.folder("DOCS"),
                               Self.file("DOCS/y.txt")] + (otherWithMetadata ? [Self.file("docs/._x.txt")] : []))
        #expect(model.rename("DOCS", to: "manual") == .success("manual"))

        await #expect(throws: ExtractionConflictError(paths: ["manual"])) {
            try await model.extract(nil, to: output, progress: nil)
        }
        #expect(try snapshot(output).isEmpty)
    }

    /// A twin left out of a renamed folder makes it written child by child: its other children still land in
    /// it, under its new name.
    @Test(arguments: [ExtractionConflictResolution.skip, .keepBoth, .replace])
    func extractRenamedFolderWithATwinInside(_ resolution: ExtractionConflictResolution) async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try #require(isCaseInsensitive(output))
        let model = makeModel([Self.folder("other"), Self.file("other/a.txt"), Self.file("other/A.txt"),
                               Self.file("other/y.txt")])
        #expect(model.rename("other", to: "docs") == .success("docs"))

        #expect(model.extractionConflicts(nil, in: output) == ["docs/A.txt"])
        try await model.extract(nil, to: output, resolutions: ["docs/A.txt": resolution], progress: nil)

        let twin: [String: String] = switch resolution {
        case .skip: ["docs/a.txt": "other/a.txt"]
        case .keepBoth: ["docs/a.txt": "other/a.txt", "docs/A 2.txt": "other/A.txt"]
        case .replace: ["docs/A.txt": "other/A.txt"]
        }
        #expect(try snapshot(output) == twin.merging(["docs": "dir", "docs/y.txt": "other/y.txt"]) { $1 })
    }

    /// A file added to a renamed folder makes it written child by child: its archive children land in it too.
    @Test func extractAdditionInRenamedFolderKeepsItsArchiveChildren() async throws {
        let (source, added) = try makeFile("new.txt", contents: "new")
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel([Self.folder("other"), Self.file("other/y.txt")])
        #expect(model.rename("other", to: "docs") == .success("docs"))
        model.add([added], to: "docs")

        try await model.extract(nil, to: output, progress: nil)

        #expect(try snapshot(output) == ["docs": "dir", "docs/new.txt": "new", "docs/y.txt": "other/y.txt"])
    }

    /// Two folders swapping names each come out under the other's name with their own contents, also when one
    /// of them is written child by child.
    @Test(arguments: [false, true])
    func extractSwappedFolders(withAddition: Bool) async throws {
        let (source, added) = try makeFile("new.txt", contents: "new")
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel([Self.folder("a"), Self.file("a/x.txt"), Self.folder("b"), Self.file("b/y.txt")])
        #expect(model.rename("a", to: "t") == .success("t"))
        #expect(model.rename("b", to: "a") == .success("a"))
        #expect(model.rename("t", to: "b") == .success("b"))
        if withAddition { model.add([added], to: "a") }

        try await model.extract(nil, to: output, progress: nil)

        var expected = ["a": "dir", "a/y.txt": "b/y.txt", "b": "dir", "b/x.txt": "a/x.txt"]
        if withAddition { expected["a/new.txt"] = "new" }
        #expect(try snapshot(output) == expected)
    }

    /// A renamed folder dragged out or previewed is written under its new name, where `localFileURL` points.
    @Test func localFileURLOfRenamedFolder() async throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        #expect(model.rename("docs", to: "papers") == .success("papers"))

        let url = try await model.localFileURL(for: "papers")

        #expect(url.lastPathComponent == "papers")
        #expect(try snapshot(url) == ["a.txt": "docs/a.txt", "c.txt": "docs/c.txt", "sub": "dir",
                                      "sub/d.txt": "docs/sub/d.txt"])
    }

    /// A reader that leaves a symlink to `target` at `linked` (in place of the folder the archive has there,
    /// if any), as a crafted archive could.
    private struct LinkingReader: ArchiveReading {
        let base: FakeReader
        let linked: String
        let target: URL
        var url: URL { base.url }
        var format: ArchiveFormat { base.format }
        var entries: [ArchiveEntry] { base.entries }
        var isEncrypted: Bool { false }

        func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
            try await base.extract(paths, to: directory, progress: progress)
            let folder = directory.appendingPathComponent(linked)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: target)
        }

        func extractToTemporaryFile(_ path: String) async throws -> URL {
            try await base.extractToTemporaryFile(path)
        }
    }

    /// A renamed item is never taken from behind a symlink in staging: a folder above its old path that is a
    /// symlink to a folder outside stops the extraction, nothing moves, and the file outside stays where it is.
    @Test func renamedItemBehindASymlinkInStagingMovesNothing() async throws {
        let outside = try makeOutput()
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("y.txt"))
        let (source, added) = try makeFile("new.txt", contents: "new")
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let reader = LinkingReader(base: FakeReader(entries: [Self.folder("other"), Self.file("other/y.txt")]),
                                   linked: "other", target: outside)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        #expect(model.rename("other", to: "docs") == .success("docs"))
        // A file added to it: "docs" is written child by child, so "other/y.txt" moves to "docs/y.txt" in staging.
        model.add([added], to: "docs")

        await #expect(throws: ExtractionConflictError(paths: ["docs/y.txt"])) {
            try await model.extract(nil, to: output, progress: nil)
        }
        #expect(try snapshot(outside) == ["y.txt": "outside"])
        #expect(try snapshot(output).isEmpty)
    }

    /// A symlink in staging on a renamed item's final name is never merged into or written through: the
    /// extraction stops before anything moves, and the folder it points at stays as it was.
    @Test func renamedItemOntoASymlinkInStagingMovesNothing() async throws {
        let outside = try makeOutput()
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("y.txt"))
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let reader = LinkingReader(base: FakeReader(entries: [Self.folder("other"), Self.file("other/y.txt")]),
                                   linked: "docs", target: outside)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        #expect(model.rename("other", to: "docs") == .success("docs"))

        await #expect(throws: ExtractionConflictError(paths: ["docs"])) {
            try await model.extract(nil, to: output, progress: nil)
        }
        #expect(try snapshot(outside) == ["y.txt": "outside"])
        #expect(try snapshot(output).isEmpty)
    }

    /// A renamed folder that staging holds as a symlink moves as a link, never followed; an item requested
    /// inside it too would then sit behind that link, so the extraction stops before anything moves.
    @Test func itemInsideARenamedFolderStagedAsASymlinkMovesNothing() async throws {
        let outside = try makeOutput()
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("b.txt"))
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let reader = LinkingReader(base: FakeReader(entries: [Self.folder("A"), Self.file("A/b.txt")]),
                                   linked: "A", target: outside)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        #expect(model.rename("A", to: "x") == .success("x"))

        await #expect(throws: ExtractionConflictError(paths: ["x/b.txt"])) {
            try await model.extract(["x", "x/b.txt"], to: output, progress: nil)
        }
        #expect(try snapshot(outside) == ["b.txt": "outside"])
        #expect(try snapshot(output).isEmpty)
    }

    /// A renamed folder requested together with an item inside it: the item follows its folder in staging,
    /// so both come out as they do without the rename (the folder moves whole, the item inside it, as
    /// `moveStaged` groups them). Inside is on the "/" scalar: `\u{301}y.txt` starts with a combining mark,
    /// so "/" and the mark are one Character, and the item still follows.
    @Test(arguments: ["y.txt", "\u{301}y.txt"])
    func renamedFolderRequestedWithAnItemInsideIt(_ name: String) async throws {
        let entries = [Self.folder("other"), Self.file("other/" + name)]
        let plain = try makeOutput()
        defer { try? FileManager.default.removeItem(at: plain) }
        _ = try await makeModel(entries).extract(["other", "other/" + name], to: plain, progress: nil)
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel(entries)
        #expect(model.rename("other", to: "docs") == .success("docs"))

        let placed = try await model.extract(["docs", "docs/" + name], to: output, progress: nil)
        #expect(placed.map(\.lastPathComponent) == ["docs", name])
        #expect(try snapshot(plain) == ["other": "dir", "other/" + name: "other/" + name])
        #expect(try snapshot(output) == ["docs": "dir", "docs/" + name: "other/" + name])
    }

    /// Empty, "." and ".." components are never a real folder path in staging.
    @Test(arguments: ["a//b", "./b", "a/../b", "a/b/..", "", "/b"])
    func stagingPathWithEmptyOrDotComponentsIsNotRealFolders(_ path: String) throws {
        let staging = try makeOutput()
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("a/b"),
                                                withIntermediateDirectories: true)

        #expect(!ArchiveModel.hasRealFolders(above: path, in: staging, missingIsFine: true))
        #expect(ArchiveModel.hasRealFolders(above: "a/b/c", in: staging, missingIsFine: false))
        #expect(ArchiveModel.hasRealFolders(above: "a/new/c", in: staging, missingIsFine: true))
    }

    /// A case-only rename of a folder comes out under the new spelling.
    @Test func extractCaseOnlyRenamedFolder() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel([Self.folder("docs"), Self.file("docs/x.txt")])
        #expect(model.rename("docs", to: "Docs") == .success("Docs"))

        try await model.extract(nil, to: output, progress: nil)

        #expect(try snapshot(output) == ["Docs": "dir", "Docs/x.txt": "docs/x.txt"])
    }

    /// A renamed item keeps its source entry's place in archive order, so the later twin is the one written
    /// later, whatever its new name: here `a.txt`. Replace leaves it, as the engine leaves the later twin.
    @Test(arguments: [ExtractionConflictResolution.skip, .keepBoth, .replace])
    func renamedTwinKeepsItsSourcePlaceInArchiveOrder(_ resolution: ExtractionConflictResolution) async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try #require(isCaseInsensitive(output))
        let model = makeModel([Self.file("B.txt"), Self.file("a.txt")])
        #expect(model.rename("B.txt", to: "A.txt") == .success("A.txt"))

        #expect(model.extractionConflicts(nil, in: output) == ["a.txt"])
        try await model.extract(nil, to: output, resolutions: ["a.txt": resolution], progress: nil)

        let expected: [String: String] = switch resolution {
        case .skip: ["A.txt": "B.txt"]
        case .keepBoth: ["A.txt": "B.txt", "a 2.txt": "a.txt"]
        case .replace: ["a.txt": "a.txt"]
        }
        #expect(try snapshot(output) == expected)
    }

    /// The same below a renamed folder: its children keep their source entries' places.
    @Test func renamedFolderChildKeepsItsSourcePlaceInArchiveOrder() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try #require(isCaseInsensitive(output))
        let model = makeModel([Self.folder("other"), Self.file("other/X.txt"), Self.folder("docs"),
                               Self.file("docs/x.txt")])
        #expect(model.rename("other", to: "DOCS") == .success("DOCS"))

        #expect(model.extractionConflicts(nil, in: output) == ["docs/x.txt"])
        try await model.extract(nil, to: output, resolutions: ["docs/x.txt": .replace], progress: nil)

        #expect(try snapshot(output) == ["docs": "dir", "docs/x.txt": "docs/x.txt"])
    }

    /// A renamed item that takes another entry's old name ranks at its own source entry, not that one's.
    @Test func itemRenamedOntoAnotherEntrysOldNameKeepsItsOwnPlace() throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try #require(isCaseInsensitive(output))
        let model = makeModel([Self.file("b.txt"), Self.file("A.txt"), Self.file("a.txt")])
        #expect(model.rename("a.txt", to: "c.txt") == .success("c.txt"))
        #expect(model.rename("b.txt", to: "a.txt") == .success("a.txt"))

        #expect(model.extractionConflicts(nil, in: output) == ["A.txt"])
    }

    /// Two files swapping names, and a third renamed onto one of them but for case: the twin is ranked and
    /// answered by its source entries' places, and the swap still lands each file under the other's name.
    @Test(arguments: [ExtractionConflictResolution.skip, .keepBoth, .replace])
    func swapWithACaseTwin(_ resolution: ExtractionConflictResolution) async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try #require(isCaseInsensitive(output))
        let model = makeModel([Self.file("a.txt"), Self.file("b.txt"), Self.file("C.txt")])
        #expect(model.rename("a.txt", to: "t.txt") == .success("t.txt"))
        #expect(model.rename("b.txt", to: "a.txt") == .success("a.txt"))
        #expect(model.rename("t.txt", to: "b.txt") == .success("b.txt"))
        #expect(model.rename("C.txt", to: "A.txt") == .success("A.txt"))

        // a.txt (was b.txt) is written before A.txt (was C.txt): A.txt is the later twin.
        #expect(model.extractionConflicts(nil, in: output) == ["A.txt"])
        try await model.extract(nil, to: output, resolutions: ["A.txt": resolution], progress: nil)

        let expected: [String: String] = switch resolution {
        case .skip: ["a.txt": "b.txt", "b.txt": "a.txt"]
        case .keepBoth: ["a.txt": "b.txt", "b.txt": "a.txt", "A 2.txt": "C.txt"]
        case .replace: ["A.txt": "C.txt", "b.txt": "a.txt"]
        }
        #expect(try snapshot(output) == expected)
    }

    /// Renamed in the opposite order to the archive's: the twins still rank by the archive.
    @Test(arguments: [ExtractionConflictResolution.skip, .replace])
    func twinsRenamedInTheOppositeOrderRankByTheArchive(_ resolution: ExtractionConflictResolution) async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try #require(isCaseInsensitive(output))
        let model = makeModel([Self.file("x.txt"), Self.file("y.txt")])
        #expect(model.rename("y.txt", to: "A.txt") == .success("A.txt"))
        #expect(model.rename("x.txt", to: "a.txt") == .success("a.txt"))

        #expect(model.extractionConflicts(nil, in: output) == ["A.txt"])
        try await model.extract(nil, to: output, resolutions: ["A.txt": resolution], progress: nil)

        #expect(try snapshot(output) == (resolution == .skip ? ["a.txt": "x.txt"] : ["A.txt": "y.txt"]))
    }

    // MARK: - Which conflicts are case twins, for the questions' wording

    private static let foldsCase = DestinationCaseSensitivity(exists: { _ in true },
                                                              supportsCaseSensitiveNames: { _ in false })
    private static let keepsCase = DestinationCaseSensitivity(exists: { _ in true },
                                                              supportsCaseSensitiveNames: { _ in true })

    /// Each later twin among the conflicts maps to its earlier twin, nested ones and file/folder ones too;
    /// none on a destination that keeps case, and none when only one of the two is requested.
    @Test func extractionScanMapsEachLaterTwinToItsEarlierOne() throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel([Self.file("README"), Self.file("Readme"), Self.file("other.txt"), Self.folder("docs"),
                               Self.file("docs/A.txt"), Self.file("docs/a.txt"), Self.file("d"), Self.folder("D"),
                               Self.file("D/x.txt")])
        model.caseSensitivity = Self.foldsCase

        #expect(Set(model.extractionConflicts(nil, in: output)) == ["Readme", "docs/a.txt", "D"])
        #expect(model.extractionConflictScan(nil, in: output).twins == ["Readme": "README", "docs/a.txt": "docs/A.txt", "D": "d"])
        #expect(model.extractionConflictScan(["docs"], in: output).twins == ["docs/a.txt": "docs/A.txt"])
        #expect(model.extractionConflictScan(["Readme", "other.txt"], in: output).twins.isEmpty)

        model.caseSensitivity = Self.keepsCase
        #expect(model.extractionConflictScan(nil, in: output).twins.isEmpty)
    }

    /// A later twin whose name is already taken on disk is asked about as an item that exists, not as a twin;
    /// it is still a later twin, whose answer moves the name (`earlierTwin`).
    /// This pins the behaviour and cannot go red on its own: `extractionConflictScan` marks a twin as asked
    /// about as a twin only inside the loop that skips paths already in the conflicts, so the on-disk path
    /// keeps it out by construction.
    @Test func twinAlreadyOnDiskIsNotAskedAsATwin() throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        try Data("mine".utf8).write(to: output.appendingPathComponent("Readme"))
        let model = makeModel([Self.file("README"), Self.file("Readme")])
        model.caseSensitivity = Self.foldsCase

        let scan = model.extractionConflictScan(nil, in: output)
        #expect(scan.conflicts.contains("Readme"))
        #expect(scan.twins.isEmpty)
        #expect(scan.laterTwins.map(\.path) == ["Readme"])
        #expect(scan.earlierTwin(of: "Readme", answers: [:]) == nil)
    }

    /// Extract answers each twin on a name against the twin that holds the name at that moment,
    /// so a question names that one: the last earlier twin answered Replace, else the first twin. Skip and
    /// Keep Both leave the name where it was; an answer after the question doesn't count.
    @Test func twinQuestionNamesTheTwinHoldingTheName() throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel([Self.file("README"), Self.file("Readme"), Self.file("readme"), Self.file("rEADME"),
                               Self.file("other.txt")])
        model.caseSensitivity = Self.foldsCase
        let scan = model.extractionConflictScan(nil, in: output)
        #expect(scan.conflicts == ["Readme", "readme", "rEADME"])

        #expect(scan.earlierTwin(of: "Readme", answers: [:]) == "README")
        #expect(scan.earlierTwin(of: "readme", answers: [:]) == "README")
        #expect(scan.earlierTwin(of: "readme", answers: ["Readme": .replace]) == "Readme")
        #expect(scan.earlierTwin(of: "readme", answers: ["Readme": .skip]) == "README")
        #expect(scan.earlierTwin(of: "readme", answers: ["Readme": .keepBoth]) == "README")
        #expect(scan.earlierTwin(of: "rEADME", answers: ["Readme": .replace, "readme": .skip]) == "Readme")
        #expect(scan.earlierTwin(of: "rEADME", answers: ["Readme": .replace, "readme": .keepBoth]) == "Readme")
        #expect(scan.earlierTwin(of: "rEADME", answers: ["Readme": .replace, "readme": .replace]) == "readme")
        #expect(scan.earlierTwin(of: "rEADME", answers: ["Readme": .skip, "readme": .replace]) == "readme")
        #expect(scan.earlierTwin(of: "Readme", answers: ["readme": .replace]) == "README")
        #expect(scan.earlierTwin(of: "other.txt", answers: [:]) == nil)
    }

    /// A twin asked about as an item on disk still moves the name when answered Replace: the next twin's
    /// question names it, as extract replaces it.
    @Test func twinOnDiskAnsweredReplaceHoldsTheName() {
        let scan = ExtractionConflictScan(
            conflicts: ["Readme", "readme"],
            laterTwins: [CaseTwinScan.Twin(path: "Readme", earlierPath: "README", mixesFileAndFolder: false),
                         CaseTwinScan.Twin(path: "readme", earlierPath: "README", mixesFileAndFolder: false)],
            askedAsTwins: ["readme"])
        #expect(scan.earlierTwin(of: "Readme", answers: [:]) == nil)
        #expect(scan.earlierTwin(of: "readme", answers: [:]) == "README")
        #expect(scan.earlierTwin(of: "readme", answers: ["Readme": .replace]) == "Readme")
    }

    /// A renamed twin is paired by the names the user sees, ranked by its source entry's place.
    @Test func renamedTwinMapsToItsEarlierTwin() throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel([Self.file("B.txt"), Self.file("a.txt")])
        #expect(model.rename("B.txt", to: "A.txt") == .success("A.txt"))
        model.caseSensitivity = Self.foldsCase

        #expect(model.extractionConflictScan(nil, in: output).twins == ["a.txt": "A.txt"])
    }

    /// The question names both twins by their names, or by their paths when the names alone read the same.
    @Test func twinNamesFallBackToPathsWhenTheNamesMatch() {
        #expect(ArchiveModel.twinNames(of: "Readme", earlier: "README") == ("Readme", "README"))
        #expect(ArchiveModel.twinNames(of: "docs/a.txt", earlier: "docs/A.txt") == ("a.txt", "A.txt"))
        #expect(ArchiveModel.twinNames(of: "d/X", earlier: "D/x") == ("X", "x"))
        #expect(ArchiveModel.twinNames(of: "d/x", earlier: "D/x") == ("d/x", "D/x"))
    }

    // MARK: - Extract, preview and opened files follow renames

    /// A renamed file extracted on its own comes out under its new name, with its source entry's bytes.
    @Test func extractRenamedFileUsesNewName() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel()
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))

        let placed = try await model.extract(["docs/b.txt"], to: output, progress: nil)

        #expect(try snapshot(output) == ["docs": "dir", "docs/b.txt": "docs/a.txt"])
        #expect(placed.map(\.lastPathComponent) == ["b.txt"])
    }

    /// A renamed folder written child by child (a child renamed too) comes out under its new name, children
    /// and all.
    @Test func extractRenamedFolderChildByChild() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel()
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        #expect(model.rename("papers/sub", to: "inner") == .success("papers/inner"))

        try await model.extract(["papers"], to: output, progress: nil)

        #expect(try snapshot(output) == ["papers": "dir", "papers/a.txt": "docs/a.txt", "papers/c.txt": "docs/c.txt",
                                         "papers/inner": "dir", "papers/inner/d.txt": "docs/sub/d.txt"])
    }

    /// A renamed child of a folder extracted whole comes out under its new name, not the reader's old one.
    @Test func extractFolderWithARenamedChild() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel()
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))

        try await model.extract(["docs"], to: output, progress: nil)

        #expect(try snapshot(output) == ["docs": "dir", "docs/b.txt": "docs/a.txt", "docs/c.txt": "docs/c.txt",
                                         "docs/sub": "dir", "docs/sub/d.txt": "docs/sub/d.txt"])
    }

    /// Children removed inside a renamed folder make it rebuilt, so they aren't extracted.
    @Test func removalInsideARenamedFolderRebuildsIt() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel()
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        model.remove(["papers/a.txt", "papers/sub/d.txt"])

        try await model.extract(["papers"], to: output, progress: nil)

        #expect(try snapshot(output) == ["papers": "dir", "papers/c.txt": "docs/c.txt", "papers/sub": "dir"])
    }

    /// Finder metadata inside a renamed folder is left behind, as it is in a folder that keeps its name.
    @Test func metadataInsideARenamedFolderIsLeftBehind() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel([Self.folder("docs"), Self.file("docs/a.txt"), Self.file("docs/._a.txt")])
        #expect(model.rename("docs", to: "papers") == .success("papers"))

        try await model.extract(["papers"], to: output, progress: nil)

        #expect(try snapshot(output) == ["papers": "dir", "papers/a.txt": "docs/a.txt"])
    }

    /// A renamed folder the archive spells two ways is still written child by child, so both spellings' children
    /// come out under its new name.
    @Test func extractRenamedFolderSpelledTwoWays() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let model = makeModel([Self.file("Cafe\u{301}/a"), Self.file("Caf\u{e9}/b")])
        #expect(model.rename("Café", to: "Menu") == .success("Menu"))

        try await model.extract(["Menu"], to: output, progress: nil)

        #expect(try snapshot(output) == ["Menu": "dir", "Menu/a": "Cafe\u{301}/a", "Menu/b": "Caf\u{e9}/b"])
    }

    /// A renamed file dragged out or previewed is a file under its new name, with its source entry's bytes.
    @Test func localFileURLOfRenamedFile() async throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))

        let url = try await model.localFileURL(for: "docs/b.txt")

        #expect(url.lastPathComponent == "b.txt")
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "docs/a.txt")
    }

    /// A model whose opened copies go into a folder of the test's own; `closeCopies` deletes it.
    private func makeModelWithCopies(_ entries: [ArchiveEntry] = entries,
                                     undoManager: UndoManager? = nil) -> (model: ArchiveModel, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelRenameTests-\(UUID().uuidString)", isDirectory: true)
        let model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: undoManager,
                                 openedFiles: OpenedFiles(in: folder))
        return (model, folder)
    }

    private func closeCopies(_ model: ArchiveModel, in folder: URL) {
        model.openedFiles.close()
        model.removeTemporaryFiles()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Changes the copy as another app's save would: new bytes and a later modification date.
    private func edit(_ url: URL, to contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: url.path)
    }

    /// An opened copy follows its item's rename: reported at the new path, and Update replaces the renamed item
    /// there without asking.
    @Test func openedCopyFollowsRename() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))
        try edit(url, to: "edited")

        let changed = try #require(model.changedOpenedFiles().first)
        #expect(changed.path == "docs/b.txt")
        #expect(!model.wouldReplace(changed))
        #expect(await model.update(from: changed))

        #expect(model.item(at: "docs/b.txt")?.isPendingAddition == true)
        #expect(model.item(at: "docs/a.txt") == nil)
        let added = try await model.localFileURL(for: "docs/b.txt")
        #expect(String(decoding: try Data(contentsOf: added), as: UTF8.self) == "edited")
    }

    /// An opened copy inside a renamed folder follows it, and so does a new item saved next to the copy.
    @Test func openedCopyFollowsItsFoldersRename() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/sub/d.txt")
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        try edit(url, to: "edited")
        try Data("new".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("e.txt"))

        #expect(model.changedOpenedFiles().map(\.path) == ["papers/sub/d.txt", "papers/sub/e.txt"])
    }

    /// Undo and redo of a rename take the opened copy back and forth with its item.
    @Test func openedCopyFollowsUndoAndRedoOfARename() async throws {
        let undoManager = makeUndoManager()
        let (model, folder) = makeModelWithCopies(undoManager: undoManager)
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        _ = step(undoManager) { model.rename("docs", to: "papers") }
        _ = step(undoManager) { model.rename("papers/a.txt", to: "b.txt") }
        try edit(url, to: "edited")
        #expect(model.changedOpenedFiles().map(\.path) == ["papers/b.txt"])

        undoManager.undo()
        #expect(model.changedOpenedFiles().map(\.path) == ["papers/a.txt"])
        undoManager.undo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/a.txt"])
        undoManager.redo()
        undoManager.redo()
        #expect(model.changedOpenedFiles().map(\.path) == ["papers/b.txt"])
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(!model.wouldReplace(changed))
    }

    // MARK: - Undo moves only moved copies, Revert maps copies back, previews

    /// What `path` holds, dragged out or previewed (FakeReader's files hold their archive path).
    private func contents(of path: String, in model: ArchiveModel) async throws -> String {
        String(decoding: try Data(contentsOf: try await model.localFileURL(for: path)), as: UTF8.self)
    }

    /// Undo and redo of a rename move only the copies that moved with it: a copy of the item that had the new
    /// name before (deleted, its name then reused) stays its own item's, so undoing the delete and Update put
    /// its bytes back there, never into the renamed item.
    @Test func undoOfARenameLeavesACopyThatNeverMoved() async throws {
        let undoManager = makeUndoManager()
        let (model, folder) = makeModelWithCopies(undoManager: undoManager)
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/c.txt")
        step(undoManager) { model.remove(["docs/c.txt"]) }
        #expect(step(undoManager) { model.rename("docs/a.txt", to: "c.txt") } == .success("docs/c.txt"))
        try edit(url, to: "edited")

        undoManager.undo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/c.txt"])
        undoManager.redo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/c.txt"])
        undoManager.undo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/c.txt"])
        undoManager.undo()

        let changed = try #require(model.changedOpenedFiles().first)
        #expect(changed.path == "docs/c.txt")
        #expect(!model.wouldReplace(changed))
        undoManager.beginUndoGrouping()
        let updated = await model.update(from: changed)
        undoManager.endUndoGrouping()
        #expect(updated)
        #expect(try await contents(of: "docs/c.txt", in: model) == "edited")
        #expect(try await contents(of: "docs/a.txt", in: model) == "docs/a.txt")
    }

    /// A copy made after a rename, of the renamed file (under its new name, with its source entry's bytes),
    /// follows that rename's undo back to the old name, and its redo forward again.
    @Test func copyMadeAfterARenameFollowsItsUndoAndRedo() async throws {
        let undoManager = makeUndoManager()
        let (model, folder) = makeModelWithCopies(undoManager: undoManager)
        defer { closeCopies(model, in: folder) }
        #expect(step(undoManager) { model.rename("docs/a.txt", to: "b.txt") } == .success("docs/b.txt"))
        let url = try await model.copyForOpening("docs/b.txt")
        #expect(url.lastPathComponent == "b.txt")
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "docs/a.txt")
        try edit(url, to: "edited")

        undoManager.undo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/a.txt"])
        undoManager.redo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/b.txt"])
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(!model.wouldReplace(changed))
    }

    /// A new item another app saved next to a copy, once kept (`markSeen`), follows the copy's folder's rename
    /// and its undo, as the copy does.
    @Test func keptNewItemFollowsUndoOfItsFoldersRename() async throws {
        let undoManager = makeUndoManager()
        let (model, folder) = makeModelWithCopies(undoManager: undoManager)
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        try Data("new".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("e.txt"))
        _ = step(undoManager) { model.rename("docs", to: "papers") }
        let found = try #require(model.changedOpenedFiles().first)
        #expect(found.path == "papers/e.txt")
        model.openedFiles.markSeen(found)
        try edit(found.url, to: "edited")

        undoManager.undo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/e.txt"])
        undoManager.redo()
        #expect(model.changedOpenedFiles().map(\.path) == ["papers/e.txt"])
    }

    /// Revert to Saved (a new model on the document's opened files) drops the unsaved renames, so an opened
    /// copy goes back to its item's saved path: Update replaces that item, never adds the new name.
    @Test func revertTakesAnOpenedCopyBackToItsSavedPath() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        #expect(model.rename("papers/a.txt", to: "b.txt") == .success("papers/b.txt"))

        let reverted = ArchiveModel(reader: FakeReader(entries: Self.entries), undoManager: nil,
                                    openedFiles: model.openedFiles)
        defer { reverted.removeTemporaryFiles() }
        try edit(url, to: "edited")

        let changed = try #require(reverted.changedOpenedFiles().first)
        #expect(changed.path == "docs/a.txt")
        #expect(!reverted.wouldReplace(changed))
        #expect(await reverted.update(from: changed))
        #expect(reverted.item(at: "papers") == nil && reverted.item(at: "docs/b.txt") == nil)
        #expect(try await contents(of: "docs/a.txt", in: reverted) == "edited")
    }

    /// Revert to Saved maps back only the copies an unsaved rename moved, or made under it: a copy of the item
    /// that had the new name before (deleted, its name then reused) stays its own item's, though it looks like
    /// the renamed copy (same size, no date), so Update puts its bytes back there, never into the renamed
    /// item's saved path.
    @Test func revertLeavesACopyThatNeverMoved() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let old = try await model.copyForOpening("docs/c.txt")
        model.remove(["docs/c.txt"])
        #expect(model.rename("docs/a.txt", to: "c.txt") == .success("docs/c.txt"))
        let renamed = try await model.copyForOpening("docs/c.txt")

        let reverted = ArchiveModel(reader: FakeReader(entries: Self.entries), undoManager: nil,
                                    openedFiles: model.openedFiles)
        defer { reverted.removeTemporaryFiles() }
        try edit(old, to: "old edited")
        try edit(renamed, to: "renamed edited")

        let changed = reverted.changedOpenedFiles()
        #expect(changed.map(\.url) == [old, renamed])
        #expect(changed.map(\.path) == ["docs/c.txt", "docs/a.txt"])
        for file in changed {
            #expect(!reverted.wouldReplace(file))
            #expect(await reverted.update(from: file))
        }
        #expect(try await contents(of: "docs/c.txt", in: reverted) == "old edited")
        #expect(try await contents(of: "docs/a.txt", in: reverted) == "renamed edited")
    }

    /// After a rename and `toggles` undos and redos in turn (the rename undone when odd), Revert to Saved finds
    /// the opened copy at its saved path.
    @Test(arguments: [0, 1, 2, 3])
    func revertAfterUndoAndRedoOfARename(toggles: Int) async throws {
        let undoManager = makeUndoManager()
        let (model, folder) = makeModelWithCopies(undoManager: undoManager)
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        _ = step(undoManager) { model.rename("docs/a.txt", to: "b.txt") }
        for toggle in 0..<toggles {
            if toggle.isMultiple(of: 2) { undoManager.undo() } else { undoManager.redo() }
        }
        try edit(url, to: "edited")
        #expect(model.changedOpenedFiles().map(\.path) == [toggles.isMultiple(of: 2) ? "docs/b.txt" : "docs/a.txt"])

        let reverted = ArchiveModel(reader: FakeReader(entries: Self.entries), undoManager: nil,
                                    openedFiles: model.openedFiles)
        #expect(reverted.changedOpenedFiles().map(\.path) == ["docs/a.txt"])
    }

    /// An added file whose name on disk is spelled NFD, never renamed, is previewed as the file itself, not
    /// a clone.
    @Test func localFileURLOfAddedNFDFileIsTheFileItself() async throws {
        let (dir, own) = try makeFile("Cafe\u{301}.txt", contents: "mine")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        model.add([own], to: "")

        let url = try await model.localFileURL(for: "Caf\u{e9}.txt")

        #expect(url.path == own.path)
    }

    /// A model that replaces one after a save wrote its renames (the reopen after the save failed, and the
    /// document read the file again) keeps the copies at the renamed paths the file now has.
    @Test func modelReadAfterASaveKeepsCopiesAtTheSavedNewNames() async throws {
        let (defaults, suite) = makeTestDefaults("ArchiveModelRenameTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        model.nameEncodingStore = ArchiveNameEncodingStore(defaults: defaults)
        let url = try await model.copyForOpening("docs/a.txt")
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))

        let saved = folder.appendingPathComponent("saved.zip")
        await #expect(throws: CocoaError.self) {
            _ = try await model.openSaved(saved) { _, _ in throw CocoaError(.fileReadCorruptFile) }
        }
        let reread = ArchiveModel(reader: FakeReader(entries: Self.entries.map {
            $0.path == "docs/a.txt" ? Self.file("docs/b.txt") : $0
        }), undoManager: nil, openedFiles: model.openedFiles)
        defer { reread.removeTemporaryFiles() }
        try edit(url, to: "edited")

        #expect(reread.changedOpenedFiles().map(\.path) == ["docs/b.txt"])
    }

    // MARK: - Renames while a copy or snapshot is made, new items on Revert, test gaps

    /// The model's opened files after a Revert to Saved: a new model on the same opened files.
    private func reverted(_ model: ArchiveModel) -> ArchiveModel {
        ArchiveModel(reader: FakeReader(entries: Self.entries), undoManager: nil, openedFiles: model.openedFiles)
    }

    /// A rename made while the copy is being made: the copy is tracked at the item's new path,
    /// and Update replaces the renamed item there, never adds a second item beside it.
    @Test func copyFollowsARenameMadeWhileItIsMade() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let held = GatedCopy()
        defer { held.release() }
        model.openedFiles.copyItem = { try held.copy($0, $1) }
        let opening = Task { try await model.copyForOpening("docs/a.txt") }
        try await held.started()
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))
        held.release()
        let url = try await opening.value
        try edit(url, to: "edited")

        let changed = try #require(model.changedOpenedFiles().first)
        #expect(changed.path == "docs/b.txt")
        #expect(!model.wouldReplace(changed))
        #expect(await model.update(from: changed))
        #expect(model.item(at: "docs/a.txt") == nil)
        #expect(try await contents(of: "docs/b.txt", in: model) == "edited")
    }

    /// The undo and redo of a rename made while the copy is being made move it as they move a tracked copy.
    @Test func copyFollowsAnUndoMadeWhileItIsMade() async throws {
        let undoManager = makeUndoManager()
        let (model, folder) = makeModelWithCopies(undoManager: undoManager)
        defer { closeCopies(model, in: folder) }
        _ = step(undoManager) { model.rename("docs", to: "papers") }
        let held = GatedCopy()
        defer { held.release() }
        model.openedFiles.copyItem = { try held.copy($0, $1) }
        let opening = Task { try await model.copyForOpening("papers/a.txt") }
        try await held.started()
        undoManager.undo()
        held.release()
        let url = try await opening.value
        try edit(url, to: "edited")

        #expect(model.changedOpenedFiles().map(\.path) == ["docs/a.txt"])
        undoManager.redo()
        #expect(model.changedOpenedFiles().map(\.path) == ["papers/a.txt"])
        undoManager.undo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/a.txt"])
    }

    /// Revert to Saved finds a copy made during a rename at its item's saved path.
    @Test func revertTakesACopyMadeDuringARenameBack() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let held = GatedCopy()
        defer { held.release() }
        model.openedFiles.copyItem = { try held.copy($0, $1) }
        let opening = Task { try await model.copyForOpening("docs/sub/d.txt") }
        try await held.started()
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        held.release()
        let url = try await opening.value
        try edit(url, to: "edited")
        #expect(model.changedOpenedFiles().map(\.path) == ["papers/sub/d.txt"])

        let reverted = reverted(model)
        defer { reverted.removeTemporaryFiles() }
        #expect(reverted.changedOpenedFiles().map(\.path) == ["docs/sub/d.txt"])
    }

    /// A rename made while Update snapshots the copy: the snapshot goes in at the item's new
    /// path, and the copy stays there.
    @Test(arguments: [("docs/a.txt", "b.txt", "docs/b.txt"), ("docs", "papers", "papers/a.txt")])
    func updateFollowsARenameMadeDuringTheSnapshot(renamed: String, to name: String, expected: String)
        async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        let held = GatedCopy()
        defer { held.release() }
        model.openedFiles.copyItem = { try held.copy($0, $1) }
        let updating = Task { await model.update(from: changed) }
        try await held.started()
        #expect(model.rename(renamed, to: name) == .success(expected == "docs/b.txt" ? expected : "papers"))
        held.release()

        #expect(await updating.value)
        #expect(model.item(at: "docs/a.txt") == nil && model.item(at: "papers/b.txt") == nil)
        #expect(model.item(at: expected)?.isPendingAddition == true)
        #expect(try await contents(of: expected, in: model) == "edited")
        #expect(model.changedOpenedFiles().isEmpty)
        try edit(url, to: "again")
        #expect(model.changedOpenedFiles().map(\.path) == [expected])
        // The copy and the snapshot that went in; the one made before the rename is gone.
        #expect(cloneFolders(in: folder) == 2)
    }

    /// Don't Update with what was reported before a rename: the copy, and a new item next to it,
    /// stay at the paths the rename gave them.
    @Test func dontUpdateKeepsThePathARenameGaveSince() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        try edit(url, to: "edited")
        let export = url.deletingLastPathComponent().appendingPathComponent("e.txt")
        try Data("new".utf8).write(to: export)
        let reported = model.changedOpenedFiles()
        #expect(reported.map(\.path) == ["docs/a.txt", "docs/e.txt"])
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        for file in reported { model.markSeen(file) }
        #expect(model.changedOpenedFiles().isEmpty)

        try edit(url, to: "again")
        try edit(export, to: "again")
        #expect(model.changedOpenedFiles().map(\.path) == ["papers/a.txt", "papers/e.txt"])
    }

    /// A new item named like a renamed file's new name (an export "b.txt" after a.txt → b.txt) stays at its
    /// own path on Revert, never moves to "a.txt" and onto that item; one in a renamed folder
    /// goes back with the folder.
    @Test func revertMovesANewItemOnlyWithItsFolder() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/sub/d.txt")
        #expect(model.rename("docs/sub/d.txt", to: "b.txt") == .success("docs/sub/b.txt"))
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        let exports = ["b.txt", "e.txt"].map { url.deletingLastPathComponent().appendingPathComponent($0) }
        for export in exports { try Data("new".utf8).write(to: export) }
        let found = model.changedOpenedFiles()
        #expect(found.map(\.path) == ["papers/sub/b.txt", "papers/sub/e.txt"])
        for file in found { model.markSeen(file) }

        let reverted = reverted(model)
        defer { reverted.removeTemporaryFiles() }
        try edit(url, to: "edited")
        for export in exports { try edit(export, to: "edited") }
        let changed = reverted.changedOpenedFiles()
        #expect(changed.map(\.path) == ["docs/sub/d.txt", "docs/sub/b.txt", "docs/sub/e.txt"])
        #expect(changed.map { reverted.wouldReplace($0) } == [false, false, false])
    }

    /// A copy of a file in a folder the archive spells NFD follows the folder's rename typed NFC, opened by
    /// either spelling, also in a folder spelled both ways.
    @Test func copiesInAnNFDFolderFollowItsRenameTypedNFC() async throws {
        let (model, folder) = makeModelWithCopies([Self.file("Cafe\u{301}/a"), Self.file("Caf\u{e9}/b"),
                                                   Self.file("Cafe\u{301}x/c")])
        defer { closeCopies(model, in: folder) }
        let urls = [try await model.copyForOpening("Cafe\u{301}/a"), try await model.copyForOpening("Caf\u{e9}/b"),
                    try await model.copyForOpening("Cafe\u{301}x/c")]
        #expect(model.rename("Caf\u{e9}", to: "Menu") == .success("Menu"))
        for url in urls { try edit(url, to: "edited") }

        #expect(model.changedOpenedFiles().map(\.path) == ["Menu/a", "Menu/b", "Cafe\u{301}x/c"])
        #expect(model.changedOpenedFiles().allSatisfy { !model.wouldReplace($0) })
    }

    /// A folder rename moves the copies inside it only, never those in a sibling whose name starts with it.
    @Test func folderRenameLeavesCopiesInASiblingWithItsNameAsPrefix() async throws {
        let undoManager = makeUndoManager()
        let (model, folder) = makeModelWithCopies([Self.file("docs/a"), Self.file("docs2/b"), Self.file("docs.txt")],
                                                  undoManager: undoManager)
        defer { closeCopies(model, in: folder) }
        let urls = [try await model.copyForOpening("docs/a"), try await model.copyForOpening("docs2/b"),
                    try await model.copyForOpening("docs.txt")]
        _ = step(undoManager) { model.rename("docs", to: "papers") }
        for url in urls { try edit(url, to: "edited") }

        #expect(model.changedOpenedFiles().map(\.path) == ["papers/a", "docs2/b", "docs.txt"])
        undoManager.undo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/a", "docs2/b", "docs.txt"])
    }

    /// Revert ignores renames a model already replaced reports (`noteUnsavedRenames`): a copy the new model
    /// made at a stale rename's new name stays there on the next Revert.
    @Test func revertIgnoresRenamesOfAReplacedModel() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let current = reverted(model)
        defer { current.removeTemporaryFiles() }
        model.remove(["notes"])
        #expect(model.rename("README", to: "notes") == .success("notes"))
        let url = try await current.copyForOpening("notes")
        try edit(url, to: "edited")

        let again = reverted(current)
        defer { again.removeTemporaryFiles() }
        #expect(again.changedOpenedFiles().map(\.path) == ["notes"])
    }

    // MARK: - Renames while a copy is made

    /// A rename while the item is extracted for its copy (`localFileURL(for:)`, before the copy is made): the
    /// copy is tracked at the item's new path, and Update replaces the renamed item there.
    @Test func copyFollowsARenameMadeDuringTheExtraction() async throws {
        let held = GatedCopy()
        defer { held.release() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelRenameTests-\(UUID().uuidString)", isDirectory: true)
        let model = ArchiveModel(reader: GatedReader(base: FakeReader(entries: Self.entries), gate: held),
                                 undoManager: nil, openedFiles: OpenedFiles(in: folder))
        defer { closeCopies(model, in: folder) }
        let opening = Task { try await model.copyForOpening("docs/a.txt") }
        try await held.started()
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))
        held.release()
        let url = try await opening.value
        try edit(url, to: "edited")

        let changed = try #require(model.changedOpenedFiles().first)
        #expect(changed.path == "docs/b.txt")
        #expect(!model.wouldReplace(changed))
        #expect(await model.update(from: changed))
        #expect(model.item(at: "docs/a.txt") == nil)
        #expect(try await contents(of: "docs/b.txt", in: model) == "edited")
    }

    /// A second rename while Update makes the snapshot again puts nothing in (the loop's bound): the copy is
    /// still reported, at the path the last rename gave it.
    @Test func updateGivesUpAfterASecondRenameDuringTheSnapshot() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        let held = GatedCopy()
        defer { held.release() }
        model.openedFiles.copyItem = { try held.copy($0, $1) }
        let updating = Task { await model.update(from: changed) }
        try await held.started()
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))
        held.releaseNext()
        try await held.started(2)
        #expect(model.rename("docs/b.txt", to: "e.txt") == .success("docs/e.txt"))
        held.release()

        #expect(await updating.value == false)
        #expect(model.item(at: "docs/e.txt")?.isPendingAddition == false)
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/e.txt"])
        #expect(cloneFolders(in: folder) == 1)
    }

    /// Another file added at the item's path while Update makes the snapshot: nothing replaces it unasked, the
    /// copy is still reported, and the snapshot is deleted rather than kept until the close.
    @Test func updateRefusedAfterTheSnapshotDeletesIt() async throws {
        let (model, folder) = makeModelWithCopies()
        let own = URL(fileURLWithPath: folder.path + "-own", isDirectory: true)
        defer {
            closeCopies(model, in: folder)
            try? FileManager.default.removeItem(at: own)
        }
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let mine = own.appendingPathComponent("a.txt")
        try Data("mine".utf8).write(to: mine)
        let url = try await model.copyForOpening("docs/a.txt")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        let held = GatedCopy()
        defer { held.release() }
        model.openedFiles.copyItem = { try held.copy($0, $1) }
        let updating = Task { await model.update(from: changed) }
        try await held.started()
        model.add([mine], to: "docs")
        held.release()

        #expect(await updating.value == false)
        #expect(try await contents(of: "docs/a.txt", in: model) == "mine")
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/a.txt"])
        #expect(cloneFolders(in: folder) == 1)
    }

    /// The `Kernir-<UUID>` folders `OpenedFiles(in: folder)` holds: copies and snapshots.
    private func cloneFolders(in folder: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("Kernir-") }
            .count
    }

    /// A kept new item named like a renamed file's new name (an export "b.txt" after a.txt → b.txt, then Don't
    /// Update) stays at its own path when the rename is undone, never moves onto a.txt with the copy.
    @Test func undoOfAFileRenameLeavesAKeptNewItemWithItsName() async throws {
        let undoManager = makeUndoManager()
        let (model, folder) = makeModelWithCopies(undoManager: undoManager)
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        #expect(step(undoManager) { model.rename("docs/a.txt", to: "b.txt") } == .success("docs/b.txt"))
        let export = url.deletingLastPathComponent().appendingPathComponent("b.txt")
        try Data("new".utf8).write(to: export)
        let found = try #require(model.changedOpenedFiles().first)
        #expect(found.url == export && found.path == "docs/b.txt")
        model.markSeen(found)

        undoManager.undo()
        try edit(url, to: "edited")
        try edit(export, to: "edited")
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/a.txt", "docs/b.txt"])
        undoManager.redo()
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/b.txt", "docs/b.txt"])
    }

    /// A later rename of the file a kept new item is named like moves the copy only, never the new item.
    @Test func laterFileRenameLeavesAKeptNewItemWithItsName() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))
        let export = url.deletingLastPathComponent().appendingPathComponent("b.txt")
        try Data("new".utf8).write(to: export)
        model.markSeen(try #require(model.changedOpenedFiles().first))

        #expect(model.rename("docs/b.txt", to: "e.txt") == .success("docs/e.txt"))
        try edit(url, to: "edited")
        try edit(export, to: "edited")
        let changed = model.changedOpenedFiles()
        #expect(changed.map(\.path) == ["docs/e.txt", "docs/b.txt"])
        #expect(changed.map { model.wouldReplace($0) } == [false, false])
    }

    /// A new item once Updated is the archive's item at its path, so it follows that item's renames as a copy
    /// does, also after it was first kept without an Update.
    @Test func updatedNewItemFollowsItsItemsRename() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        let export = url.deletingLastPathComponent().appendingPathComponent("e.txt")
        try Data("new".utf8).write(to: export)
        model.markSeen(try #require(model.changedOpenedFiles().first))
        try edit(export, to: "edited")
        #expect(await model.update(from: try #require(model.changedOpenedFiles().first)))

        #expect(model.rename("docs/e.txt", to: "f.txt") == .success("docs/f.txt"))
        try edit(export, to: "again")
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(changed.path == "docs/f.txt")
        #expect(!model.wouldReplace(changed))
    }

    /// `wouldReplace` looks at the path the file goes back in at now: a rename since it was reported (during an
    /// earlier item's Update, say) took its copy off the reported path, and a different item took that path.
    @Test func wouldReplaceLooksAtThePathARenameGaveSince() async throws {
        let (model, folder) = makeModelWithCopies([Self.folder("docs"), Self.file("docs/a.txt", size: 1),
                                                   Self.file("docs/c.txt", size: 2)])
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        try edit(url, to: "edited")
        let reported = try #require(model.changedOpenedFiles().first)
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))
        #expect(model.rename("docs/c.txt", to: "a.txt") == .success("docs/a.txt"))

        #expect(!model.wouldReplace(reported))
        #expect(await model.update(from: reported))
        #expect(try await contents(of: "docs/b.txt", in: model) == "edited")
        #expect(try await contents(of: "docs/a.txt", in: model) == "docs/c.txt")
    }

    /// A save while Update makes the snapshot gives the copy its items anew (`rebaseItems`); Update keeps
    /// those, never the ones the copy was reported with.
    @Test func updateKeepsTheItemsASaveDuringTheSnapshotGave() async throws {
        let (model, folder) = makeModelWithCopies()
        defer { closeCopies(model, in: folder) }
        let url = try await model.copyForOpening("docs/a.txt")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        let held = GatedCopy()
        defer { held.release() }
        model.openedFiles.copyItem = { try held.copy($0, $1) }
        let updating = Task { await model.update(from: changed) }
        try await held.started()
        // The item as the save wrote it, and (FakeReader's model reads no save) as the model still has it.
        let saved = OpenedItemIdentity.saved(size: 7, modified: nil, isDirectory: false)
        model.openedFiles.rebaseItems { $0.itsItems + [saved] }
        held.release()

        #expect(await updating.value)
        #expect(model.openedFiles.files.first?.itsItems.contains(saved) == true)
    }

    /// `GatedCopy.started()` fails a test whose copy never starts, never hangs it.
    @Test func gatedCopyStartedTimesOut() async {
        await #expect(throws: GatedCopy.NotStarted.self) {
            try await GatedCopy().started(within: .milliseconds(50))
        }
    }

    /// A renamed pending addition is previewed and dragged out under its new name, with the user's file's
    /// bytes; the user's file keeps its own name.
    @Test func localFileURLOfRenamedPendingFile() async throws {
        let (dir, own) = try makeFile("old.txt", contents: "mine")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        model.add([own], to: "")
        #expect(model.rename("old.txt", to: "new.txt") == .success("new.txt"))

        let url = try await model.localFileURL(for: "new.txt")

        #expect(url.lastPathComponent == "new.txt")
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "mine")
        #expect(FileManager.default.fileExists(atPath: own.path))
        model.removeTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: own.path))
    }

    /// A file renamed only in case is previewed under its new spelling, with its source entry's bytes.
    @Test func localFileURLOfCaseOnlyRenamedFile() async throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        #expect(model.rename("docs/a.txt", to: "A.txt") == .success("docs/A.txt"))

        let url = try await model.localFileURL(for: "docs/A.txt")

        #expect(url.lastPathComponent == "A.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["A.txt"])
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "docs/a.txt")
    }

    /// Previewing a renamed file again reuses the file extracted the first time, until another name or a
    /// removal of the temporary files.
    @Test func renamedFilePreviewIsExtractedOnce() async throws {
        let model = makeModel()
        defer { model.removeTemporaryFiles() }
        #expect(model.rename("docs/a.txt", to: "b.txt") == .success("docs/b.txt"))

        let first = try await model.localFileURL(for: "docs/b.txt")
        #expect(try await model.localFileURL(for: "docs/b.txt") == first)
        #expect(model.rename("docs/b.txt", to: "e.txt") == .success("docs/e.txt"))
        let renamed = try await model.localFileURL(for: "docs/e.txt")
        #expect(renamed != first && renamed.lastPathComponent == "e.txt")
        model.removeTemporaryFiles()
        let again = try await model.localFileURL(for: "docs/e.txt")
        #expect(again != renamed && FileManager.default.fileExists(atPath: again.path))
    }

    // MARK: - __MACOSX at any depth

    /// A `__MACOSX` path component at any depth is Finder metadata, hidden like the root one;
    /// a name that only starts with it is not.
    @Test func nestedMACOSXIsHidden() {
        let model = makeModel([Self.folder("a"), Self.file("a/__MACOSX/b"), Self.file("a/__MACOSXfoo"),
                               Self.file("a/x")])

        #expect(model.item(at: "a/__MACOSX/b") == nil)
        #expect(model.item(at: "a/__MACOSX") == nil)
        #expect(model.item(at: "a/__MACOSXfoo") != nil)
        #expect(model.children(of: "a").map(\.name) == ["__MACOSXfoo", "x"])
    }
}

/// Holds `OpenedFiles.copyItem` (or an async step, `pass()`) until released, then copies: a test acts
/// while a copy or snapshot is made. Copies are held in the order they start; `releaseNext()` lets the
/// first one still held go on, `release()` all of them, now and later.
final class GatedCopy: @unchecked Sendable {
    struct NotStarted: Error {}
    private let lock = NSCondition()
    private var startedCount = 0
    private var releasedCount = 0
    private var waiter: (id: UUID, count: Int, continuation: CheckedContinuation<Void, any Error>)?
    private var held: [(index: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func copy(_ source: URL, _ destination: URL) throws {
        let index = enter()
        lock.withLock {
            while releasedCount < index { lock.wait() }
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Holds an async step, such as an extraction, as `copy` holds a copy.
    func pass() async {
        let index = enter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isReleased = lock.withLock {
                if releasedCount < index { held.append((index, continuation)) }
                return releasedCount >= index
            }
            if isReleased { continuation.resume() }
        }
    }

    /// Returns once `count` copies have started; throws `NotStarted` when they haven't within `timeout`,
    /// so a copy that never starts fails the test instead of hanging it.
    func started(_ count: Int = 1, within timeout: Duration = .seconds(10)) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let isStarted = lock.withLock {
                if startedCount < count { waiter = (id, count, continuation) }
                return startedCount >= count
            }
            if isStarted { return continuation.resume() }
            Task.detached {
                try? await Task.sleep(for: timeout)
                let late = self.lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                    guard let waiter = self.waiter, waiter.id == id else { return nil }
                    self.waiter = nil
                    return waiter.continuation
                }
                late?.resume(throwing: NotStarted())
            }
        }
    }

    func releaseNext() {
        release { $0 == .max ? .max : $0 + 1 }
    }

    func release() {
        release { _ in .max }
    }

    private func enter() -> Int {
        let (index, ready) = lock.withLock { () -> (Int, CheckedContinuation<Void, any Error>?) in
            startedCount += 1
            guard let waiter, startedCount >= waiter.count else { return (startedCount, nil) }
            self.waiter = nil
            return (startedCount, waiter.continuation)
        }
        ready?.resume()
        return index
    }

    private func release(_ count: (Int) -> Int) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            releasedCount = count(releasedCount)
            lock.broadcast()
            let ready = held.filter { $0.index <= releasedCount }.map(\.continuation)
            held.removeAll { $0.index <= releasedCount }
            return ready
        }
        for continuation in ready { continuation.resume() }
    }
}

/// A `FakeReader` whose single-file extraction (`extractToTemporaryFile`) waits at `gate.pass()`: a test acts
/// while an item is extracted for its copy.
private struct GatedReader: ArchiveReading {
    let base: FakeReader
    let gate: GatedCopy
    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await base.extract(paths, to: directory, progress: progress)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        await gate.pass()
        return try await base.extractToTemporaryFile(path)
    }
}
