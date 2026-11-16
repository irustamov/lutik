import Testing
import Foundation
@testable import Kernir
import KernirCore

// MARK: - Helpers

@MainActor
private func makeModel(_ entries: [ArchiveEntry] = SampleArchive().entries, format: ArchiveFormat = .zip,
                       undoManager: UndoManager? = nil) -> ArchiveModel {
    ArchiveModel(reader: FakeReader(entries: entries, format: format), undoManager: undoManager)
}

/// Fresh empty directory; the caller removes it.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveModelTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes `contents` at `relativePath` under `directory`, creating folders as needed.
@discardableResult
private func makeFile(_ relativePath: String, in directory: URL, contents: String = "hello") throws -> URL {
    let url = directory.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
}

private func contents(of url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

private func file(_ path: String, size: Int64 = 1) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: size, modificationDate: nil)
}

private func folder(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
}

// MARK: - Merge

@MainActor @Test func mergedTreeShowsPendingAddition() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let model = makeModel()

    model.add([notes], to: "assets")

    #expect(model.item(at: "assets/notes.txt")?.isPendingAddition == true)
    #expect(model.item(at: "assets/notes.txt")?.size == 5)
    #expect(model.item(at: "assets")?.isPendingAddition == false)
    #expect(model.children(of: "assets").map(\.name) == ["cover.png", "notes.txt"])
    #expect(model.changes.additions.count == 1)
    #expect(model.changes.additions.first?.destinationDirectory == "assets")
    #expect(model.changes.removedPaths.isEmpty)
    #expect(model.hasChanges)
}

@MainActor @Test func removeSourceFolderHidesDescendants() {
    let model = makeModel()

    model.remove(["src"])

    #expect(model.item(at: "src/main.swift") == nil)
    #expect(model.item(at: "src") == nil)
    #expect(model.changes.removedPaths == ["src"])
    #expect(model.items.map(\.name) == ["assets", "brief.pdf", "README.md"])
}

@MainActor @Test func replaceExistingFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let readme = try makeFile("README.md", in: dir, contents: "new readme")
    let model = makeModel()

    #expect(model.conflicts(adding: [readme], to: "") == ["README.md"])
    model.add([readme], to: "")

    #expect(model.changes.removedPaths.contains("README.md"))
    let item = try #require(model.item(at: "README.md"))
    #expect(item.isPendingAddition)
    #expect(item.size == 10)
    #expect(model.items.filter { $0.name == "README.md" }.count == 1)
    #expect(model.conflicts(adding: [readme], to: "") == ["README.md"])
}

@MainActor @Test func replaceWithNFDNameFromDisk() throws {
    let nfc = "Caf\u{E9}.txt"
    let nfd = "Cafe\u{301}.txt"
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let disk = try makeFile(nfd, in: dir)
    let model = makeModel([file(nfc)])

    let conflicts = model.conflicts(adding: [disk], to: "")
    #expect(conflicts.map { Array($0.unicodeScalars) } == [Array(nfc.unicodeScalars)])

    model.add([disk], to: "")

    #expect(model.changes.removedPaths.map { Array($0.unicodeScalars) } == [Array(nfc.unicodeScalars)])
    #expect(model.items.count == 1)
    let item = try #require(model.items.first)
    #expect(Array(item.path.unicodeScalars) == Array(nfc.unicodeScalars))
    #expect(item.isPendingAddition)
    #expect(model.item(at: nfd)?.path == item.path)
}

/// A `.DS_Store` file must not hide the folder listed after it. The walker used to call
/// `skipDescendants()` on it, and on a file that skips the next folder's contents, which the writer
/// still saved. Enumeration order is the file system's, so every level holds several sibling
/// folders with contents and a `.DS_Store`: whichever folder follows it would lose its children.
@MainActor @Test func dsStoreDoesNotHideTheNextFoldersContents() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var want: Set<String> = ["proj"]
    try makeFile("proj/.DS_Store", in: dir)
    for top in ["a", "b", "c", "d", "e", "f"] {
        try makeFile("proj/\(top)/.DS_Store", in: dir)
        want.insert("proj/\(top)")
        for sub in ["x", "y", "z"] {
            try makeFile("proj/\(top)/\(sub)/file.txt", in: dir)
            try makeFile("proj/\(top)/\(sub)/.DS_Store", in: dir)
            try makeFile("proj/\(top)/\(sub)/deep/leaf.txt", in: dir)
            want.formUnion(["proj/\(top)/\(sub)", "proj/\(top)/\(sub)/file.txt",
                            "proj/\(top)/\(sub)/deep", "proj/\(top)/\(sub)/deep/leaf.txt"])
        }
    }
    let model = makeModel([])

    model.add([dir.appendingPathComponent("proj")], to: "")

    let listed = Set(model.items.flattened().map(\.path))
    #expect(want.subtracting(listed).isEmpty, "missing: \(want.subtracting(listed).sorted())")
    #expect(listed.subtracting(want).isEmpty, "extra: \(listed.subtracting(want).sorted())")
    #expect(!listed.contains { $0.hasSuffix(".DS_Store") })
    // What the writer saves (KernirCore's AdditionWalker) is what the add window lists.
    let archive = dir.appendingPathComponent("out.zip")
    try await ArchiveWriter.write(source: nil, changes: model.changes, format: .zip, to: archive)
    let written = Set(try await Archive.open(at: archive).entries.map {
        $0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path
    })
    #expect(written == listed,
            "written only: \(written.subtracting(listed).sorted()), listed only: \(listed.subtracting(written).sorted())")
}

/// A folder named `.DS_Store` is not skipped by the writer (without the Mac metadata option), so its
/// contents are listed, under their own paths and not a sibling's.
@MainActor @Test func dsStoreFolderContentsAreListedWhereTheyAreWritten() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for path in ["proj/a/one.txt", "proj/.DS_Store/inner.txt", "proj/.DS_Store/sub/deeper.txt", "proj/z/two.txt"] {
        try makeFile(path, in: dir)
    }
    let model = makeModel([])

    model.add([dir.appendingPathComponent("proj")], to: "")

    let listed = Set(model.items.flattened().map(\.path))
    #expect(listed == ["proj", "proj/a", "proj/a/one.txt", "proj/.DS_Store", "proj/.DS_Store/inner.txt",
                       "proj/.DS_Store/sub", "proj/.DS_Store/sub/deeper.txt", "proj/z", "proj/z/two.txt"],
            "\(listed.sorted())")
    let archive = dir.appendingPathComponent("out.zip")
    try await ArchiveWriter.write(source: nil, changes: model.changes, format: .zip, to: archive)
    let written = Set(try await Archive.open(at: archive).entries.map {
        $0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path
    })
    #expect(written == listed, "\(written.sorted())")
}

// MARK: - Nested edits

@MainActor @Test func removeInsidePendingFolder() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = try makeFile("docs/a.txt", in: dir)
    try makeFile("docs/b/c.txt", in: dir)
    let d = try makeFile("docs/b/d.txt", in: dir)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(undoManager: undoManager)

    undoManager.beginUndoGrouping()
    model.add([dir.appendingPathComponent("docs")], to: "")
    undoManager.endUndoGrouping()
    let afterAdd = model.items
    #expect(model.children(of: "docs").flattened().map(\.path)
            == ["docs/b", "docs/b/c.txt", "docs/b/d.txt", "docs/a.txt"])

    undoManager.beginUndoGrouping()
    model.remove(["docs/b/c.txt"])
    undoManager.endUndoGrouping()

    #expect(model.item(at: "docs/b/c.txt") == nil)
    #expect(model.children(of: "docs").flattened().map(\.path) == ["docs/b", "docs/b/d.txt", "docs/a.txt"])
    #expect(model.item(at: "docs")?.isPendingAddition == true)
    #expect(model.item(at: "docs/b")?.isPendingAddition == true)
    let additions = model.changes.additions
    #expect(additions.map { "\($0.destinationDirectory): \($0.sourceURL.lastPathComponent)" }
            == ["docs: a.txt", "docs/b: d.txt"])
    #expect(additions.map { $0.sourceURL.resolvingSymlinksInPath().path }
            == [a, d].map { $0.resolvingSymlinksInPath().path })
    #expect(model.changes.removedPaths.isEmpty)

    undoManager.undo()
    #expect(model.items == afterAdd)
    #expect(model.changes.additions.map(\.sourceURL.lastPathComponent) == ["docs"])
}

@MainActor @Test func removeInsidePendingFolderDropsFinderCompanion() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeFile("dir/a.txt", in: dir)
    let companion = try makeFile("dir/._a.txt", in: dir)
    let b = try makeFile("dir/b.txt", in: dir)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(undoManager: undoManager)
    undoManager.beginUndoGrouping()
    model.add([dir.appendingPathComponent("dir")], to: "")
    undoManager.endUndoGrouping()
    let afterAdd = model.changes

    undoManager.beginUndoGrouping()
    model.remove(["dir/a.txt"])
    undoManager.endUndoGrouping()

    let sources = model.changes.additions.map { $0.sourceURL.resolvingSymlinksInPath().path }
    #expect(sources.contains(b.resolvingSymlinksInPath().path))
    #expect(!sources.contains(companion.resolvingSymlinksInPath().path))
    #expect(sources.count == 1)

    undoManager.undo()
    #expect(model.changes == afterAdd)
    // Re-applying the removal gives the same result, so undo restored the companion's entry too.
    undoManager.beginUndoGrouping()
    model.remove(["dir/a.txt"])
    undoManager.endUndoGrouping()
    #expect(model.changes.additions.count == 1)
}

@MainActor @Test func removePendingSubfolderDropsItsCompanion() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeFile("dir/sub/x.txt", in: dir)
    let companion = try makeFile("dir/._sub", in: dir)
    let b = try makeFile("dir/b.txt", in: dir)
    let model = makeModel()
    model.add([dir.appendingPathComponent("dir")], to: "")

    model.remove(["dir/sub"])

    let sources = model.changes.additions.map { $0.sourceURL.resolvingSymlinksInPath().path }
    #expect(sources == [b.resolvingSymlinksInPath().path])
    #expect(!sources.contains(companion.resolvingSymlinksInPath().path))
}

@MainActor @Test func removePendingTopLevelDropsAddition() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    try makeFile("docs/a.txt", in: dir)
    let model = makeModel()
    let initial = model.items

    model.add([notes, dir.appendingPathComponent("docs")], to: "")
    #expect(model.changes.additions.count == 2)
    model.remove(["notes.txt", "docs"])

    #expect(model.changes.additions.isEmpty)
    #expect(model.changes.removedPaths.isEmpty)
    #expect(model.hasChanges == false)
    #expect(model.items == initial)
}

@MainActor @Test func removeSourceFolderDropsAdditionsInside() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let model = makeModel()

    model.add([notes], to: "assets")
    model.remove(["assets"])

    // Writer removals apply to source entries only, so the addition must go too.
    #expect(model.changes.additions.isEmpty)
    #expect(model.changes.removedPaths == ["assets"])
    #expect(model.item(at: "assets") == nil)
}

// MARK: - Undo

@MainActor @Test func undoRedoRoundTrip() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(undoManager: undoManager)
    let initial = model.items

    undoManager.beginUndoGrouping()
    model.add([notes], to: "assets")
    undoManager.endUndoGrouping()
    #expect(undoManager.undoActionName == String(localized: "Add", table: "Shared"))
    let afterAdd = (changes: model.changes, items: model.items)

    undoManager.beginUndoGrouping()
    model.remove(["src"])
    undoManager.endUndoGrouping()
    #expect(undoManager.undoActionName == String(localized: "Delete", table: "Shared"))
    let afterRemove = (changes: model.changes, items: model.items)

    undoManager.undo()
    #expect(model.changes == afterAdd.changes)
    #expect(model.items == afterAdd.items)
    undoManager.undo()
    #expect(model.changes.isEmpty)
    #expect(model.items == initial)
    #expect(undoManager.canUndo == false)

    undoManager.redo()
    #expect(model.changes == afterAdd.changes)
    #expect(model.items == afterAdd.items)
    undoManager.redo()
    #expect(model.changes == afterRemove.changes)
    #expect(model.items == afterRemove.items)
    #expect(undoManager.canRedo == false)
    #expect(undoManager.undoActionName == String(localized: "Delete", table: "Shared"))
}

@MainActor @Test func readOnlyIgnoresEdits() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let undoManager = UndoManager()
    let model = makeModel(format: .rar, undoManager: undoManager)

    model.add([notes], to: "")
    model.remove(["src"])

    #expect(model.isEditable == false)
    #expect(model.changes.isEmpty)
    #expect(model.hasChanges == false)
    #expect(model.item(at: "src") != nil)
    #expect(undoManager.canUndo == false)
}

@MainActor
@Test func aMultiVolumeSetIsNotEditableEvenWhenItsFormatIsWritable() {
    let parts = [URL(fileURLWithPath: "/tmp/a.7z.001"), URL(fileURLWithPath: "/tmp/a.7z.002")]
    for format in [ArchiveFormat.sevenZip, .zip] {
        let single = ArchiveModel(reader: FakeReader(entries: SampleArchive().entries, format: format), undoManager: nil)
        #expect(single.isEditable)
        let set = ArchiveModel(reader: FakeReader(entries: SampleArchive().entries, format: format, url: parts[0],
                                                  volumeURLs: parts), undoManager: nil)
        #expect(set.isEditable == false, "\(format)")
    }
}

// MARK: - Totals

@MainActor @Test func unknownFileSizeMakesTheTotalUnknown() {
    // A single-stream archive's one entry has no recorded size.
    let unknown = ArchiveEntry(path: "notes.txt", isDirectory: false, size: nil, compressedSize: nil,
                               modificationDate: nil)
    #expect(makeModel([unknown], format: .gzip).totalSize == nil)
    #expect(makeModel([file("a.txt", size: 5), unknown]).totalSize == nil)
    // Folders have no size of their own; they don't make the total unknown.
    #expect(makeModel([folder("empty"), file("a.txt", size: 5)]).totalSize == 5)
}

@MainActor @Test func totalsAndCompressedSize() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let model = makeModel()

    #expect(model.itemCount == 7)
    #expect(model.itemCount == model.items.flattened().count)
    #expect(model.totalSize == 1_547_168)
    #expect(model.compressedSize == 1_452_800)

    model.add([notes], to: "assets")

    #expect(model.itemCount == 8)
    #expect(model.totalSize == 1_547_173)
    #expect(model.compressedSize == nil)
}

// MARK: - Extract and preview

@MainActor @Test func extractMixesSourceAndPending() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let model = makeModel()
    model.add([notes], to: "assets")

    try await model.extract(["README.md", "assets/notes.txt"], to: output, progress: nil)

    #expect(try contents(of: output.appendingPathComponent("README.md")) == "README.md")
    #expect(try contents(of: output.appendingPathComponent("assets/notes.txt")) == "hello")
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("assets/cover.png").path))
}

@MainActor @Test func extractEverythingFollowsMergedTree() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let model = makeModel()
    model.add([notes], to: "assets")
    model.remove(["src/main.swift"])

    try await model.extract(nil, to: output, progress: nil)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: output.appendingPathComponent(path).path)
    }
    #expect(exists("src/utils.swift"))
    #expect(!exists("src/main.swift"))
    #expect(exists("assets/cover.png"))
    #expect(try contents(of: output.appendingPathComponent("assets/notes.txt")) == "hello")
    #expect(exists("brief.pdf"))
    #expect(exists("README.md"))
}

@MainActor @Test func localFileURLForPendingAndSource() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let model = makeModel()
    model.add([notes], to: "assets")

    #expect(try await model.localFileURL(for: "assets/notes.txt") == notes)
    let readme = try await model.localFileURL(for: "README.md")
    defer { try? FileManager.default.removeItem(at: readme.deletingLastPathComponent()) }
    #expect(readme.lastPathComponent == "README.md")
    #expect(try contents(of: readme) == "README.md")
    let assets = try await model.localFileURL(for: "assets")
    defer { try? FileManager.default.removeItem(at: assets.deletingLastPathComponent()) }
    #expect(assets.lastPathComponent == "assets")
    #expect(try contents(of: assets.appendingPathComponent("notes.txt")) == "hello")
    #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("cover.png").path))
    await #expect(throws: ArchiveError.entryNotFound("missing")) {
        try await model.localFileURL(for: "missing")
    }
}

@MainActor @Test func removeTemporaryFilesDeletesFolderExtractions() async throws {
    let model = makeModel()
    let assets = try await model.localFileURL(for: "assets")
    let directory = assets.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(directory.deletingLastPathComponent().resolvingSymlinksInPath()
        == FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
    #expect(directory.lastPathComponent.hasPrefix("Kernir-"))
    #expect(FileManager.default.fileExists(atPath: directory.path))

    model.removeTemporaryFiles()

    #expect(!FileManager.default.fileExists(atPath: directory.path))
    // Forgotten: a second call has nothing left to do.
    model.removeTemporaryFiles()
}

// MARK: - Save

@MainActor @Test func didSaveResetsState() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(undoManager: undoManager)
    undoManager.beginUndoGrouping()
    model.add([notes], to: "assets")
    undoManager.endUndoGrouping()
    #expect(undoManager.canUndo)

    model.didSave(reader: FakeReader(entries: SampleArchive().entries + [file("assets/notes.txt", size: 5)]))

    #expect(model.hasChanges == false)
    #expect(undoManager.canUndo == false)
    #expect(model.item(at: "assets/notes.txt")?.isPendingAddition == false)
    #expect(model.compressedSize == 1_452_805)
}

// MARK: - Scale

@MainActor @Test func fiftyThousandEntryRemoveIsFast() {
    // 500 folders x (1 folder + 99 files) = 50 000 entries.
    var entries: [ArchiveEntry] = []
    for d in 0..<500 {
        entries.append(folder("dir\(d)"))
        for f in 0..<99 { entries.append(file("dir\(d)/file\(f).txt", size: Int64(f))) }
    }
    #expect(entries.count == 50_000)
    let model = makeModel(entries)
    #expect(model.itemCount == 50_000)

    let elapsed = ContinuousClock().measure {
        model.remove(["dir42"])
    }

    #expect(model.itemCount == 49_900)
    #expect(model.item(at: "dir42/file1.txt") == nil)
    #expect(model.item(at: "dir43/file1.txt") != nil)
    // CI runners are 2-3x slower; the regressions this catches took 10-70 s.
    #expect(elapsed < .seconds(5))
}

@MainActor @Test func removingManyFilesInsideAPendingFolderIsFast() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for index in 0..<5_000 { try makeFile("bulk/file\(index).txt", in: dir) }
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(undoManager: undoManager)
    undoManager.beginUndoGrouping()
    model.add([dir.appendingPathComponent("bulk")], to: "")
    undoManager.endUndoGrouping()
    let afterAdd = model.changes
    let removed = Set((0..<5_000).filter { $0 % 2 == 0 }.map { "bulk/file\($0).txt" })
    #expect(removed.count == 2_500)

    undoManager.beginUndoGrouping()
    let elapsed = ContinuousClock().measure {
        model.remove(removed)
    }
    undoManager.endUndoGrouping()

    let kept = Set(model.changes.additions.map(\.sourceURL.lastPathComponent))
    let expected = Set((0..<5_000).filter { $0 % 2 == 1 }.map { "file\($0).txt" })
    #expect(model.changes.additions.count == 2_500)
    #expect(kept == expected)
    let inBulk = model.changes.additions.allSatisfy { $0.destinationDirectory == "bulk" }
    #expect(inBulk)
    #expect(model.item(at: "bulk/file0.txt") == nil)
    #expect(model.item(at: "bulk/file1.txt") != nil)
    // The quadratic version split and filtered everything once per path (minutes at this size).
    #expect(elapsed < .seconds(5))

    undoManager.undo()
    #expect(model.changes == afterAdd)
}

/// One delete that splits a pending folder and drops an addition nested in it: the split must
/// not bring the dropped addition back as a child of the folder (it would be saved unseen).
@MainActor @Test func removingANestedAdditionAlongWithASplitDropsIt() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeFile("F/a/x.txt", in: dir)
    try makeFile("F/a/y.txt", in: dir)
    try makeFile("F/b.txt", in: dir)
    let n = try makeFile("n.txt", in: dir)
    let model = makeModel()
    model.add([dir.appendingPathComponent("F")], to: "")
    model.add([n], to: "F")
    #expect(model.changes.additions.count == 2)

    model.remove(["F/a/x.txt", "F/n.txt"])

    #expect(model.item(at: "F/n.txt") == nil)
    #expect(model.item(at: "F/a/x.txt") == nil)
    #expect(model.item(at: "F/a/y.txt") != nil)
    let sources = model.changes.additions.map(\.sourceURL.lastPathComponent)
    #expect(Set(sources) == ["b.txt", "y.txt"])
    #expect(sources.count == 2)
}

// MARK: - Navigation

@MainActor @Test func childrenOfFolderAndScopedSearch() {
    let model = makeModel()

    #expect(model.children(of: "").map(\.name) == ["assets", "src", "brief.pdf", "README.md"])
    #expect(model.children(of: "src").map(\.name) == ["main.swift", "utils.swift"])
    #expect(model.children(of: "src", matching: "util").map(\.name) == ["utils.swift"])
    #expect(model.children(of: "", matching: "main").map(\.name) == ["src"])
    #expect(model.item(at: "src")?.children?.count == 2)
    #expect(model.children(of: "README.md").isEmpty)
}

// MARK: - macOS metadata

private func metadataEntries() -> [ArchiveEntry] {
    [file("README.md", size: 10), file("._README.md", size: 4),
     folder("__MACOSX"), file("__MACOSX/README.md", size: 4), file("__MACOSX/._README.md", size: 4)]
}

@MainActor @Test func macOSMetadataHiddenAndRemovedWithItsItem() {
    let model = makeModel(metadataEntries())

    #expect(model.items.map(\.path) == ["README.md"])
    #expect(model.itemCount == 1)
    #expect(model.totalSize == 10)
    #expect(model.compressedSize == 10)
    #expect(model.item(at: "._README.md") == nil)
    #expect(model.item(at: "__MACOSX/README.md") == nil)
    #expect(model.changes.removedPaths.isEmpty)

    model.remove(["README.md"])
    #expect(model.changes.removedPaths == ["README.md", "._README.md", "__MACOSX/README.md", "__MACOSX/._README.md"])
    #expect(model.items.isEmpty)
}

/// Finder metadata goes with the item it describes: removed with it, or with the file that replaces it.
@MainActor @Test func removingAnItemRemovesItsFinderMetadata() throws {
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(nestedMetadataEntries(), undoManager: undoManager)

    undoManager.beginUndoGrouping()
    model.remove(["src/main.swift"])
    undoManager.endUndoGrouping()
    #expect(model.changes.removedPaths == ["src/main.swift", "src/._main.swift", "__MACOSX/src/._main.swift"])

    undoManager.undo()
    #expect(model.changes.isEmpty)

    // A folder's own metadata; what is inside it goes with the folder.
    undoManager.beginUndoGrouping()
    model.remove(["src"])
    undoManager.endUndoGrouping()
    #expect(model.changes.removedPaths == ["src", "__MACOSX/src"])

    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let readme = try makeFile("README.md", in: dir)
    undoManager.beginUndoGrouping()
    model.add([readme], to: "")
    undoManager.endUndoGrouping()
    #expect(model.changes.removedPaths == ["src", "__MACOSX/src", "README.md", "._README.md"])
}

@MainActor @Test func extractAllSkipsMetadata() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(metadataEntries())

    try await model.extract(nil, to: dir, progress: nil)

    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names == ["README.md"])
}

private func nestedMetadataEntries() -> [ArchiveEntry] {
    [file("README.md", size: 10), file("._README.md", size: 4), folder("src"),
     file("src/main.swift", size: 20), file("src/._main.swift", size: 4),
     folder("__MACOSX"), folder("__MACOSX/src"), file("__MACOSX/src/._main.swift", size: 4)]
}

@MainActor @Test(arguments: [["src"], nil] as [[String]?])
func extractFolderSkipsNestedDotUnderscore(paths: [String]?) async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(nestedMetadataEntries())

    try await model.extract(paths, to: dir, progress: nil)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
    }
    #expect(exists("src/main.swift"))
    #expect(!exists("src/._main.swift"))
    #expect(!exists("__MACOSX"))
    #expect(model.changes.removedPaths.isEmpty)
}

@MainActor @Test(arguments: [["x"], nil] as [[String]?])
func folderWithOnlyMetadataExtractsEmpty(paths: [String]?) async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel([folder("x"), file("x/._a"), file("__MACOSX/x/._a")])
    #expect(model.items.map(\.path) == ["x"])

    try await model.extract(paths, to: dir, progress: nil)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
    }
    #expect(exists("x"))
    #expect(!exists("x/._a"))
    #expect(!exists("__MACOSX"))
}

@MainActor @Test func extractSelectedMetadataPathIsNoop() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(nestedMetadataEntries())

    try await model.extract(["._README.md"], to: dir, progress: nil)

    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@MainActor @Test func localFileURLForSourceFolderHasNoMetadata() async throws {
    let model = makeModel(nestedMetadataEntries())

    let url = try await model.localFileURL(for: "src")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    // fileExists, not a listing: Foundation can hide AppleDouble names from directory listings.
    #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("main.swift").path))
    #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("._main.swift").path))
}

@MainActor @Test func extractNFDFolderSkipsDotUnderscore() async throws {
    let nfd = "Cafe\u{301}"
    let model = makeModel([folder(nfd), file("\(nfd)/main.swift", size: 20), file("\(nfd)/._main.swift", size: 4)])
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    try await model.extract([nfd], to: dir, progress: nil)

    func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }
    #expect(exists("\(nfd)/main.swift", in: dir))
    #expect(!exists("\(nfd)/._main.swift", in: dir))

    let url = try await model.localFileURL(for: nfd)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(exists("main.swift", in: url))
    #expect(!exists("._main.swift", in: url))
}

@MainActor @Test func searchIgnoresMetadata() {
    let model = makeModel(metadataEntries())

    #expect(model.children(of: "", matching: "README").map(\.path) == ["README.md"])
}

// MARK: - Destination spelling and guards

@MainActor @Test func addIntoNFDFolderUsesArchiveSpelling() throws {
    let nfc = "Caf\u{E9}"
    let nfd = "Cafe\u{301}"
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let x = try makeFile("x.txt", in: dir)
    let model = makeModel([folder(nfd), file("\(nfd)/a.txt")])

    model.add([x], to: nfc)
    model.add([x], to: nfc + "/new")

    let destinations = model.changes.additions.map { Array($0.destinationDirectory.unicodeScalars) }
    #expect(destinations == [Array(nfd.unicodeScalars), Array((nfd + "/new").unicodeScalars)])
    #expect(model.item(at: nfc + "/x.txt")?.isPendingAddition == true)
    #expect(model.items.filter(\.isDirectory).count == 1)
}

@MainActor @Test func addUnderFileIsIgnored() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let x = try makeFile("x.txt", in: dir)
    let model = makeModel()

    model.add([x], to: "README.md/sub")

    #expect(model.changes.isEmpty)
    #expect(model.item(at: "README.md/sub") == nil)
}

@MainActor @Test func removeInsidePendingFolderRedo() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeFile("docs/a.txt", in: dir)
    try makeFile("docs/b/c.txt", in: dir)
    try makeFile("docs/b/d.txt", in: dir)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(undoManager: undoManager)
    undoManager.beginUndoGrouping()
    model.add([dir.appendingPathComponent("docs")], to: "")
    undoManager.endUndoGrouping()
    undoManager.beginUndoGrouping()
    model.remove(["docs/b/c.txt"])
    undoManager.endUndoGrouping()
    let afterSplit = (changes: model.changes, items: model.items)

    undoManager.undo()
    #expect(model.changes.additions.count == 1)
    undoManager.redo()

    #expect(model.changes == afterSplit.changes)
    #expect(model.items == afterSplit.items)
    #expect(model.item(at: "docs/b/c.txt") == nil)
}

@MainActor @Test func replaceUndoRedo() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let readme = try makeFile("README.md", in: dir, contents: "new readme")
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(undoManager: undoManager)
    let original = model.item(at: "README.md")

    undoManager.beginUndoGrouping()
    model.add([readme], to: "")
    undoManager.endUndoGrouping()
    let replaced = (changes: model.changes, items: model.items)
    #expect(model.item(at: "README.md")?.isPendingAddition == true)

    undoManager.undo()
    #expect(model.changes.isEmpty)
    #expect(model.item(at: "README.md") == original)

    undoManager.redo()
    #expect(model.changes == replaced.changes)
    #expect(model.items == replaced.items)
}

@MainActor @Test func undoActionNamesInEnglish() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let x = try makeFile("x.txt", in: dir)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let model = makeModel(undoManager: undoManager)

    undoManager.beginUndoGrouping()
    model.add([x], to: "")
    undoManager.endUndoGrouping()
    #expect(undoManager.undoActionName == "Add")

    undoManager.beginUndoGrouping()
    model.remove(["src"])
    undoManager.endUndoGrouping()
    #expect(undoManager.undoActionName == "Delete")
}

// MARK: - Determinism, hidden pending, spelling, counts

@MainActor @Test func equalNamesHaveStableOrder() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let upper = try makeFile("u/A", in: dir)
    let lowerA = try makeFile("l/a", in: dir)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false

    // Source "a" plus pending "A": 20 add/undo cycles give the same order every time.
    let model = makeModel([file("a")], undoManager: undoManager)
    var seen = Set<[String]>()
    for _ in 0..<20 {
        undoManager.beginUndoGrouping()
        model.add([upper], to: "")
        undoManager.endUndoGrouping()
        seen.insert(model.items.map(\.path))
        undoManager.undo()
        #expect(model.changes.isEmpty)
    }
    #expect(seen == [["a", "A"]])

    // Both pending, in either input order.
    var pendingOrders = Set<[String]>()
    for urls in [[upper, lowerA], [lowerA, upper]] {
        let fresh = makeModel([])
        fresh.add(urls, to: "")
        pendingOrders.insert(fresh.items.map(\.path))
    }
    #expect(pendingOrders == [["a", "A"]])

    // NFC/NFD twins are one item; the first in reader order wins, whatever the process.
    let nfc = "Caf\u{E9}"
    let nfd = "Cafe\u{301}"
    for entries in [[file(nfc), file(nfd)], [file(nfd), file(nfc)]] {
        let items = makeModel(entries).items
        #expect(items.count == 1)
        #expect(items.map { Array($0.path.utf8) } == [Array(entries[0].path.utf8)])
    }
}

@MainActor @Test func userAddedDotUnderscoreHiddenButPacked() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let hidden = try makeFile("._x", in: dir)
    let model = makeModel()
    let count = model.itemCount

    model.add([hidden], to: "")

    #expect(model.item(at: "._x") == nil)
    #expect(model.itemCount == count)
    #expect(model.changes.additions.map(\.sourceURL.lastPathComponent) == ["._x"])
}

@MainActor @Test func addIntoImplicitNFDFolderUsesArchiveSpelling() throws {
    let nfd = "Cafe\u{301}"
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let x = try makeFile("x.txt", in: dir)
    let model = makeModel([file("\(nfd)/f.txt")])

    model.add([x], to: "Caf\u{E9}")

    #expect(model.changes.additions.map { Array($0.destinationDirectory.unicodeScalars) } == [Array(nfd.unicodeScalars)])
    #expect(model.items.filter(\.isDirectory).count == 1)
}

@MainActor @Test func pendingItemsInNFDFolderShareItsSpelling() async throws {
    let nfc = "Caf\u{E9}"
    let nfd = "Cafe\u{301}"
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let x = try makeFile("x.txt", in: dir)
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let model = makeModel([folder(nfd), file("\(nfd)/a.txt")])

    model.add([x], to: nfc + "/new")

    let added = try #require(model.item(at: nfc + "/new/x.txt"))
    #expect(Array(added.path.utf8) == Array("\(nfd)/new/x.txt".utf8))
    #expect(model.children(of: nfc).map(\.name) == ["new", "a.txt"])
    try await model.extract([nfc], to: output, progress: nil)
    #expect(try contents(of: output.appendingPathComponent("\(nfd)/a.txt")) == "\(nfd)/a.txt")
    #expect(try contents(of: output.appendingPathComponent("\(nfd)/new/x.txt")) == "hello")
}

@MainActor @Test func replaceNFDFolderWithFolderFromDiskShowsOneFolder() throws {
    let nfc = "Caf\u{E9}"
    let nfd = "Cafe\u{301}"
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeFile("\(nfc)/b.txt", in: dir)
    let model = makeModel([folder(nfd), file("\(nfd)/a.txt")])

    model.add([dir.appendingPathComponent(nfc)], to: "")

    #expect(model.items.count == 1)
    #expect(model.children(of: nfc).map(\.name) == ["b.txt"])
    #expect(model.item(at: nfc + "/b.txt")?.isPendingAddition == true)
}

@MainActor @Test func itemCountMatchesDisplayedTree() {
    // Duplicate path and a missing parent: count follows the deduped, synthesized tree.
    let model = makeModel([file("a/b.txt", size: 2), file("a/b.txt", size: 3), file("x/y/z.txt", size: 4)])

    #expect(model.itemCount == model.items.flattened().count)
    #expect(model.itemCount == 5)
    #expect(model.totalSize == 6)  // first duplicate wins
}

// MARK: - One folder spelled both NFC and NFD

private let nfcCafe = "Caf\u{E9}"
private let nfdCafe = "Cafe\u{301}"

/// What a mixed-normalization tool writes: one folder, spelled NFC for a.txt and NFD for b.txt.
/// (A reader that tells the spellings apart lists each folder spelling, like KernirCore's synthesized folders.)
private func mixedSpellingEntries() -> [ArchiveEntry] {
    [folder(nfcCafe), file(nfcCafe + "/a.txt"), folder(nfdCafe), file(nfdCafe + "/b.txt")]
}

private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

@MainActor @Test func mixedSpellingFolderIsOneFolder() {
    let model = makeModel(mixedSpellingEntries())

    #expect(model.items.map { bytes($0.path) } == [bytes(nfcCafe)])
    #expect(model.children(of: nfdCafe).map(\.name) == ["a.txt", "b.txt"])
    #expect(model.itemCount == 3)
    let ids = model.items.flattened().map(\.id)
    #expect(Set(ids).count == ids.count)
}

@MainActor @Test func extractAllReachesEverySpellingOfAMixedFolder() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let model = makeModel(mixedSpellingEntries())

    try await model.extract(nil, to: output, progress: nil)

    // The fake writes each entry's own path as its contents: each file came from its own spelling.
    #expect(try bytes(contents(of: output.appendingPathComponent(nfcCafe + "/a.txt"))) == bytes(nfcCafe + "/a.txt"))
    #expect(try bytes(contents(of: output.appendingPathComponent(nfcCafe + "/b.txt"))) == bytes(nfdCafe + "/b.txt"))
}

@MainActor @Test func mixedFolderAndItsNFDChildReachTheReader() async throws {
    let model = makeModel(mixedSpellingEntries())

    let folderOutput = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folderOutput) }
    try await model.extract([nfdCafe], to: folderOutput, progress: nil)
    #expect(try bytes(contents(of: folderOutput.appendingPathComponent(nfcCafe + "/a.txt"))) == bytes(nfcCafe + "/a.txt"))
    #expect(try bytes(contents(of: folderOutput.appendingPathComponent(nfcCafe + "/b.txt"))) == bytes(nfdCafe + "/b.txt"))

    let childOutput = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: childOutput) }
    try await model.extract([nfcCafe + "/b.txt"], to: childOutput, progress: nil)
    #expect(try bytes(contents(of: childOutput.appendingPathComponent(nfcCafe + "/b.txt"))) == bytes(nfdCafe + "/b.txt"))
    #expect(!FileManager.default.fileExists(atPath: childOutput.appendingPathComponent(nfcCafe + "/a.txt").path))

    let child = try await model.localFileURL(for: nfcCafe + "/b.txt")
    defer { try? FileManager.default.removeItem(at: child.deletingLastPathComponent()) }
    #expect(try bytes(contents(of: child)) == bytes(nfdCafe + "/b.txt"))

    let opened = try await model.localFileURL(for: nfcCafe)
    defer { try? FileManager.default.removeItem(at: opened.deletingLastPathComponent()) }
    #expect(try bytes(contents(of: opened.appendingPathComponent("a.txt"))) == bytes(nfcCafe + "/a.txt"))
    #expect(try bytes(contents(of: opened.appendingPathComponent("b.txt"))) == bytes(nfdCafe + "/b.txt"))
}

@MainActor @Test func removingAMixedFolderRemovesEveryChild() async throws {
    let model = makeModel(mixedSpellingEntries())

    model.remove([nfcCafe + "/b.txt"])
    #expect(model.changes.removedPaths.map(bytes) == [bytes(nfdCafe + "/b.txt")])
    #expect(model.children(of: nfcCafe).map(\.name) == ["a.txt"])

    model.remove([nfdCafe])
    #expect(model.items.isEmpty)
    #expect(model.itemCount == 0)
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try await model.extract(nil, to: output, progress: nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
}

@MainActor @Test func folderInsideAMixedFolderStaysInsideIt() async throws {
    // "sub" exists only under the NFD spelling of its parent.
    let model = makeModel([folder(nfcCafe), file(nfcCafe + "/x.txt"),
                           folder(nfdCafe), folder(nfdCafe + "/sub"), file(nfdCafe + "/sub/y.txt")])
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let added = try makeFile("added.txt", in: dir)

    #expect(model.items.count == 1)
    #expect(model.children(of: nfcCafe).map(\.name) == ["sub", "x.txt"])
    model.add([added], to: nfcCafe + "/sub")
    #expect(model.items.count == 1)
    #expect(model.children(of: nfcCafe + "/sub").map(\.name) == ["added.txt", "y.txt"])

    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try await model.extract(nil, to: output, progress: nil)
    #expect(try bytes(contents(of: output.appendingPathComponent(nfcCafe + "/x.txt"))) == bytes(nfcCafe + "/x.txt"))
    #expect(try bytes(contents(of: output.appendingPathComponent(nfcCafe + "/sub/y.txt"))) == bytes(nfdCafe + "/sub/y.txt"))
    #expect(try contents(of: output.appendingPathComponent(nfcCafe + "/sub/added.txt")) == "hello")
}

// MARK: - Extract never overwrites

/// Every item under `directory`, hidden ones too: relative path -> "dir", "link:<destination>" or
/// the file's contents.
private func snapshot(_ directory: URL) throws -> [String: String] {
    let fileManager = FileManager.default
    var result: [String: String] = [:]
    for relative in try fileManager.subpathsOfDirectory(atPath: directory.path) {
        let url = directory.appendingPathComponent(relative)
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            result[relative] = "link:" + destination
            continue
        }
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        result[relative] = isDirectory.boolValue ? "dir" : try contents(of: url)
    }
    return result
}

/// Staging folders left in `directory`.
private func stagingFolders(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".kernir-") }
}

private func makeFolder(_ relativePath: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory.appendingPathComponent(relativePath, isDirectory: true),
                                            withIntermediateDirectories: true)
}

/// FakeReader that runs `afterWrite` once everything is written, before returning.
private struct GatedReader: ArchiveReading {
    let base: FakeReader
    let afterWrite: @Sendable () async throws -> Void

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }
    var compressionMethod: ArchiveCompressionMethod? { base.compressionMethod }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await base.extract(paths, to: directory, progress: progress)
        try await afterWrite()
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}

@MainActor @Test func extractionConflictsListsTakenTopLevelItemsInOrder() throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let model = makeModel()
    #expect(model.extractionConflicts(nil, in: output).isEmpty)

    try makeFile("README.md", in: output, contents: "mine")
    try makeFolder("assets", in: output)
    // A dangling symlink is still in the way.
    try FileManager.default.createSymbolicLink(atPath: output.appendingPathComponent("brief.pdf").path,
                                               withDestinationPath: "/nonexistent/kernir")

    #expect(model.extractionConflicts(nil, in: output) == ["assets", "brief.pdf", "README.md"])
    #expect(model.extractionConflicts(["README.md", "src"], in: output) == ["README.md"])
    // A nested selection conflicts only on the item itself; its folders merge.
    #expect(model.extractionConflicts(["assets/cover.png"], in: output).isEmpty)
    try makeFile("assets/cover.png", in: output, contents: "mine")
    #expect(model.extractionConflicts(["assets/cover.png"], in: output) == ["assets/cover.png"])
}

@MainActor @Test func extractWithoutAnAnswerThrowsAndChangesNothing() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let before = try snapshot(output)
    let model = makeModel()

    await #expect(throws: ExtractionConflictError(paths: ["README.md"])) {
        try await model.extract(nil, to: output, progress: nil)
    }
    #expect(try snapshot(output) == before)
}

@MainActor @Test func keepBothFileTakesTheNextFinderName() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    try makeFile("README 2.md", in: output, contents: "mine 2")
    let model = makeModel()

    let written = try await model.extract(["README.md", "brief.pdf"], to: output,
                                          resolutions: ["README.md": .keepBoth], progress: nil)

    #expect(try contents(of: output.appendingPathComponent("README.md")) == "mine")
    #expect(try contents(of: output.appendingPathComponent("README 2.md")) == "mine 2")
    #expect(try contents(of: output.appendingPathComponent("README 3.md")) == "README.md")
    #expect(written.map(\.lastPathComponent) == ["README 3.md", "brief.pdf"])
    #expect(try stagingFolders(in: output).isEmpty)
}

@MainActor @Test func keepBothSkipsNamesTheSameExtractionWrites() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("a.txt", in: output, contents: "mine")
    let model = makeModel([file("a.txt"), file("a 2.txt")])

    try await model.extract(nil, to: output, resolutions: ["a.txt": .keepBoth], progress: nil)

    #expect(try contents(of: output.appendingPathComponent("a.txt")) == "mine")
    #expect(try contents(of: output.appendingPathComponent("a 2.txt")) == "a 2.txt")
    #expect(try contents(of: output.appendingPathComponent("a 3.txt")) == "a.txt")
}

@MainActor @Test func keepBothFolderLeavesTheOldOneAlone() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("assets/mine.txt", in: output, contents: "mine")
    let model = makeModel()

    try await model.extract(["assets"], to: output, resolutions: ["assets": .keepBoth], progress: nil)

    #expect(try snapshot(output) == ["assets": "dir", "assets/mine.txt": "mine",
                                     "assets 2": "dir", "assets 2/cover.png": "assets/cover.png"])
}

@MainActor @Test func replaceSwapsFilesAndFoldersWhole() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    try makeFile("assets/old.txt", in: output, contents: "old")
    try makeFile("src", in: output, contents: "a file where the archive has a folder")
    try makeFile("brief.pdf/inner.txt", in: output, contents: "a folder where the archive has a file")
    let model = makeModel()
    let all: [String: ExtractionConflictResolution] = ["README.md": .replace, "assets": .replace,
                                                       "src": .replace, "brief.pdf": .replace]

    try await model.extract(nil, to: output, resolutions: all, progress: nil)

    // No mixture: the old folder's contents are gone with it, as in Finder.
    #expect(try snapshot(output) == ["README.md": "README.md", "brief.pdf": "brief.pdf",
                                     "assets": "dir", "assets/cover.png": "assets/cover.png",
                                     "src": "dir", "src/main.swift": "src/main.swift",
                                     "src/utils.swift": "src/utils.swift"])
}

@MainActor @Test func replaceNeverWritesThroughASymlink() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let elsewhere = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let outside = try makeFile("outside.txt", in: elsewhere, contents: "outside")
    try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("README.md"),
                                               withDestinationURL: outside)
    let model = makeModel()

    try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)

    #expect(try snapshot(output) == ["README.md": "README.md"])
    #expect(try contents(of: outside) == "outside")
}

@MainActor @Test func skipLeavesTheItemAndExtractsTheRest() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let model = makeModel()

    let written = try await model.extract(["README.md", "brief.pdf"], to: output,
                                          resolutions: ["README.md": .skip], progress: nil)

    #expect(try snapshot(output) == ["README.md": "mine", "brief.pdf": "brief.pdf"])
    #expect(written.map(\.lastPathComponent) == ["brief.pdf"])
}

@MainActor @Test func pendingAdditionsNeverOverwriteEither() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = try makeFile("notes.txt", in: dir)
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("notes.txt", in: output, contents: "mine")
    try makeFile("assets/notes.txt", in: output, contents: "mine too")
    let model = makeModel()
    model.add([notes], to: "")
    model.add([notes], to: "assets")
    #expect(model.extractionConflicts(["notes.txt", "assets/notes.txt"], in: output)
            == ["notes.txt", "assets/notes.txt"])
    let before = try snapshot(output)

    await #expect(throws: ExtractionConflictError(paths: ["notes.txt"])) {
        try await model.extract(["notes.txt"], to: output, progress: nil)
    }
    #expect(try snapshot(output) == before)

    try await model.extract(["notes.txt", "assets/notes.txt"], to: output,
                            resolutions: ["notes.txt": .keepBoth, "assets/notes.txt": .replace], progress: nil)
    #expect(try contents(of: output.appendingPathComponent("notes.txt")) == "mine")
    #expect(try contents(of: output.appendingPathComponent("notes 2.txt")) == "hello")
    #expect(try contents(of: output.appendingPathComponent("assets/notes.txt")) == "hello")
}

@MainActor @Test func nestedSelectionMergesIntoExistingFolders() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("assets/mine.txt", in: output, contents: "mine")
    let model = makeModel()

    try await model.extract(["assets/cover.png"], to: output, progress: nil)

    #expect(try snapshot(output) == ["assets": "dir", "assets/mine.txt": "mine",
                                     "assets/cover.png": "assets/cover.png"])
}

@MainActor @Test func cancelledExtractionLeavesTheFolderAsItWas() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    try makeFile("assets/old.txt", in: output, contents: "old")
    let before = try snapshot(output)
    // The reader writes everything, then the user cancels before it returns.
    let (written, wroteAll) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let reader = GatedReader(base: FakeReader(entries: SampleArchive().entries)) {
        wroteAll.yield()
        for await _ in released { break }
    }
    let model = ArchiveModel(reader: reader, undoManager: nil)
    let resolutions: [String: ExtractionConflictResolution] = ["README.md": .replace, "assets": .replace]

    let task = Task { try await model.extract(nil, to: output, resolutions: resolutions, progress: nil) }
    for await _ in written { break }
    task.cancel()
    release.yield()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try snapshot(output) == before)
}

@MainActor @Test func failedExtractionLeavesTheFolderAsItWas() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let before = try snapshot(output)
    let reader = GatedReader(base: FakeReader(entries: SampleArchive().entries)) {
        throw ArchiveError.corrupted("bad block")
    }
    let model = ArchiveModel(reader: reader, undoManager: nil)

    await #expect(throws: ArchiveError.corrupted("bad block")) {
        try await model.extract(nil, to: output, resolutions: ["README.md": .replace], progress: nil)
    }
    #expect(try snapshot(output) == before)
}

@MainActor @Test func anItemThatAppearsDuringExtractionIsNeverOverwritten() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let reader = GatedReader(base: FakeReader(entries: SampleArchive().entries)) {
        try makeFile("README.md", in: output, contents: "arrived meanwhile")
    }
    let model = ArchiveModel(reader: reader, undoManager: nil)

    await #expect(throws: ExtractionConflictError(paths: ["README.md"])) {
        try await model.extract(["README.md"], to: output, progress: nil)
    }
    #expect(try snapshot(output) == ["README.md": "arrived meanwhile"])
}

@MainActor @Test func staleStagingFoldersOfThisDeviceAndDeadProcessesAreSwept() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let token = testDeviceToken
    // pid 99999999 and below it are above macOS's pid limit, so those processes can't be running.
    let dead = ".kernir-\(token)-99999999-\(UUID().uuidString)"
    let deadButRecent = ".kernir-\(token)-99999998-\(UUID().uuidString)"
    let ours = ".kernir-\(token)-\(getpid())-\(UUID().uuidString)"
    let liveOtherProcess = ".kernir-\(token)-\(getppid())-\(UUID().uuidString)"
    let otherDevice = ".kernir-0123456789abcdef-99999999-\(UUID().uuidString)"
    let oldFormat = ".kernir-99999999-\(UUID().uuidString)"
    let usersOwn = ".kernir-12-notes"
    let notAUUID = ".kernir-\(token)-99999999-notes"
    // Holds a user's item that Replace couldn't put back.
    let marked = ".kernir-\(token)-99999997-\(UUID().uuidString)"
    let names = [dead, deadButRecent, ours, liveOtherProcess, otherDevice, oldFormat, usersOwn, notAUUID, marked]
    for name in names { try makeFile(name + "/partial.txt", in: output) }
    try makeFile(marked + "/.kernir-keep", in: output, contents: "")
    // A file, not a folder, named like staging.
    let aFile = ".kernir-\(token)-99999996-\(UUID().uuidString)"
    try makeFile(aFile, in: output)
    for name in names + [aFile] where name != deadButRecent {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: output.appendingPathComponent(name).path)
    }
    let model = makeModel()
    model.extractionFileSystem.deviceToken = token

    try await model.extract(["README.md"], to: output, progress: nil)

    #expect(try Set(stagingFolders(in: output)) == Set(names + [aFile]).subtracting([dead]))
}

// N-10: a recovered item keeps its staging even when the marker is missing (its lstat failed when written).
@MainActor @Test func staleStagingHoldingARecoveredItemIsKeptWithoutTheMarker() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let token = testDeviceToken
    let holding = ".kernir-\(token)-99999999-\(UUID().uuidString)"
    let empty = ".kernir-\(token)-99999998-\(UUID().uuidString)"
    let legacy = ".kernir-\(token)-99999997-\(UUID().uuidString)"  // a pre-rename build's
    try makeFile(holding + "/Lutik Recovered \(UUID().uuidString)/README.md", in: output, contents: "mine")
    try makeFolder(empty + "/Lutik Recovered \(UUID().uuidString)", in: output)
    try makeFile(legacy + "/Kernir Recovered \(UUID().uuidString)/README.md", in: output, contents: "mine")
    for name in [holding, empty, legacy] {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: output.appendingPathComponent(name).path)
    }
    let model = makeModel()
    model.extractionFileSystem.deviceToken = token

    try await model.extract(["README.md"], to: output, progress: nil)

    #expect(try Set(stagingFolders(in: output)) == [holding, legacy])
}

@Test func theDeviceTokenIsMadeOnceAndKept() throws {
    // A defaults domain of the test's own, never the test runner's.
    let (defaults, suite) = makeTestDefaults("KernirTests")
    defer { removeTestDefaults(defaults, suite: suite) }

    let token = ExtractionFileSystem.deviceToken(in: defaults)
    #expect(token.count == 16)
    #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(defaults.string(forKey: "KernirStagingDeviceToken") == token)
    #expect(ExtractionFileSystem.deviceToken(in: defaults) == token)
    // A stored value that isn't a token is replaced.
    defaults.set("not-a-token", forKey: "KernirStagingDeviceToken")
    let replaced = ExtractionFileSystem.deviceToken(in: defaults)
    #expect(ExtractionFileSystem.isDeviceToken(replaced))
    #expect(defaults.string(forKey: "KernirStagingDeviceToken") == replaced)
}

@Test func stagingNameFieldsAreReadStrictly() throws {
    // Built the way extract builds the staging name.
    let uuid = UUID()
    let name = "\(ArchiveModel.stagingPrefix)\(testDeviceToken)-\(getpid())-\(uuid.uuidString)"
    let fields = try #require(ArchiveModel.stagingNameFields(name))
    #expect(fields.deviceToken == testDeviceToken)
    #expect(fields.pid == getpid())
    #expect(fields.uuid == uuid)

    let prefix = ArchiveModel.stagingPrefix
    let id = UUID().uuidString
    for other in [".kernir-keep",
                  "\(prefix)\(testDeviceToken)-0-\(id)",          // pid 0
                  "\(prefix)\(testDeviceToken)--5-\(id)",         // empty pid
                  "\(prefix)\(testDeviceToken)-0123-\(id)",       // leading zero
                  "\(prefix)\(testDeviceToken)-+123-\(id)",       // sign
                  "\(prefix)\(testDeviceToken)-99999999999-\(id)", // beyond pid_t
                  "\(prefix)-123-\(id)",                          // empty token
                  "\(prefix)FEEDFACE00000000-123-\(id)",          // not a device token
                  "\(prefix)feedface-123-\(id)",                  // too short for one
                  "\(prefix)\(testDeviceToken)-123-notes"] {      // not a UUID
        #expect(ArchiveModel.stagingNameFields(other) == nil, "\(other)")
    }
}

@MainActor @Test func stagingIsNamedWithTheDeviceTokenPidAndAUUID() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let renames = FakeRenames()
    let model = makeModel()
    model.extractionFileSystem = renames.fileSystem()

    try await model.extract(["README.md"], to: output, progress: nil)

    let staging = try #require(renames.sources.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
    let prefix = ".kernir-\(testDeviceToken)-\(getpid())-"
    #expect(staging.lastPathComponent.hasPrefix(prefix))
    #expect(UUID(uuidString: String(staging.lastPathComponent.dropFirst(prefix.count))) != nil)
}

@Test func extractionConflictErrorReadsLikeFinder() {
    let one = ExtractionConflictError(paths: ["docs/a.txt"])
    #expect(one.localizedDescription == String(localized: "“\("a.txt")” already exists.", table: "Shared"))
    let two = ExtractionConflictError(paths: ["a.txt", "b.txt"])
    #expect(two.localizedDescription == String(localized: "\(2) items already exist.", table: "Shared"))
}

/// CSPLIT row 24: the conflict text names the item by its last component after the "/" scalar. A "/" followed by
/// a combining mark or a ZWJ, or preceded by a Prepend scalar, is part of one Character that is not "/", so a
/// Character split named the whole path ("d/́x").
@Test(arguments: [
    ("d/\u{301}x", "\u{301}x"),
    ("d/\u{200D}x", "\u{200D}x"),
    ("d\u{600}/x", "x"),
])
func extractionConflictErrorNamesTheScalarLastComponent(path: String, leaf: String) {
    let error = ExtractionConflictError(paths: [path])
    #expect(ArchiveEntry.name(of: path) == leaf)
    #expect(error.localizedDescription == String(localized: "“\(leaf)” already exists.", table: "Shared"))
    #expect(error.failureReason == String(localized: "“\(leaf)” already exists.", table: "Shared"))
}

@Test func replaceWithoutSwapSupportStepsAsideAndNeverLosesTheOldItem() throws {
    let staging = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    try makeFile("assets/old.txt", in: output, contents: "old")
    let staged = try makeFile("README.md", in: staging, contents: "new")
    try makeFile("assets/cover.png", in: staging, contents: "cover")

    try ArchiveModel.replaceSteppingAside(output.appendingPathComponent("README.md"), with: staged,
                                          path: "README.md", staging: staging, in: output)
    try ArchiveModel.replaceSteppingAside(output.appendingPathComponent("assets"),
                                          with: staging.appendingPathComponent("assets"), path: "assets",
                                          staging: staging, in: output)
    #expect(try snapshot(output) == ["README.md": "new", "assets": "dir", "assets/cover.png": "cover"])
    // The replaced items went with their recovered folders once the new ones were in; the marker stays.
    #expect(try snapshot(staging).keys.filter { $0.hasPrefix("Lutik Recovered") }.isEmpty)
    #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent(".kernir-keep").path))

    // The new item can't move in (gone): the old one comes back to its name.
    #expect(throws: (any Error).self) {
        try ArchiveModel.replaceSteppingAside(output.appendingPathComponent("README.md"),
                                              with: staging.appendingPathComponent("missing"), path: "README.md",
                                              staging: staging, in: output)
    }
    #expect(try snapshot(output) == ["README.md": "new", "assets": "dir", "assets/cover.png": "cover"])
}

// MARK: - Extract: leftover cases

private let testDeviceToken = "feedface00000000"

/// Renames that go through `rule` first: it returns nil for the real renamex_np(2), or an error number
/// to fail without touching anything. Records every rename's source path.
private final class FakeRenames: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let rule: @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32?

    init(rule: @escaping @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32? = { _, _, _ in nil }) {
        self.rule = rule
    }

    var sources: [String] { lock.withLock { log } }

    func fileSystem() -> ExtractionFileSystem {
        ExtractionFileSystem(deviceToken: testDeviceToken) { from, to, flags in
            self.lock.withLock { self.log.append(from) }
            return self.rule(from, to, flags) ?? ExtractionFileSystem.system.rename(from, to, flags)
        }
    }
}

/// A value shared with `@Sendable` closures.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

/// The parent folder's name of `path`.
private func parentName(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
}

/// Rules for a Replace of README.md in `output` on a file system without RENAME_SWAP, where something
/// takes the name while the new item moves in. `asideMove` answers the old item's way back and its
/// "name 2" move, `recoveredMove` the recovered folder's move out of staging (nil = the real rename).
private func replaceRaceRules(in output: URL, asideMove: Int32?, recoveredMove: Int32?)
    -> @Sendable (String, String, UInt32) -> Int32? {
    let target = output.appendingPathComponent("README.md").path
    return { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        if to == target, parentName(from).hasPrefix(".kernir-") {
            try? makeFile("README.md", in: output, contents: "arrived meanwhile")
            return EEXIST
        }
        if parentName(from).hasPrefix("Lutik Recovered ") { return asideMove }
        if URL(fileURLWithPath: from).lastPathComponent.hasPrefix("Lutik Recovered ") { return recoveredMove }
        return nil
    }
}

@MainActor @Test func replaceThatCantPutTheOldItemBackRenamesItAndSaysSo() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let model = makeModel()
    model.extractionFileSystem = FakeRenames(rule: replaceRaceRules(in: output, asideMove: nil, recoveredMove: nil))
        .fileSystem()

    let error = await #expect(throws: ExtractionRecoveryError.self) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(error?.name == "README.md")
    #expect(error?.kind == .renamed)
    #expect(error?.kept == output.appendingPathComponent("README 2.md", isDirectory: false))
    #expect(error?.underlying as? ExtractionConflictError == ExtractionConflictError(paths: ["README.md"]))
    #expect(try snapshot(output) == ["README.md": "arrived meanwhile", "README 2.md": "mine"])
}

@MainActor @Test func replaceThatCantPutTheOldItemAnywhereKeepsItVisibleInARecoveredFolder() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let model = makeModel()
    model.extractionFileSystem = FakeRenames(rule: replaceRaceRules(in: output, asideMove: EIO, recoveredMove: nil))
        .fileSystem()

    let error = await #expect(throws: ExtractionRecoveryError.self) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(error?.name == "README.md")
    #expect(error?.kind == .inFolder)
    #expect(error?.kept == output.appendingPathComponent("Lutik Recovered", isDirectory: true))
    #expect(error?.kept.hasDirectoryPath == true)
    #expect(error?.underlying as? ExtractionConflictError == ExtractionConflictError(paths: ["README.md"]))
    // Under its own name, not hidden, and nothing else of the extraction with it.
    #expect(try snapshot(output) == ["README.md": "arrived meanwhile", "Lutik Recovered": "dir",
                                     "Lutik Recovered/README.md": "mine"])
}

@MainActor @Test func replaceThatCantEvenMoveTheRecoveredFolderKeepsTheMarkedStaging() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    // Whether the marker was there when the recovered folder tried to move out.
    let markedBeforeMove = LockedValue<Bool?>(nil)
    let rules = replaceRaceRules(in: output, asideMove: EIO, recoveredMove: EIO)
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { from, to, flags in
        if URL(fileURLWithPath: from).lastPathComponent.hasPrefix("Lutik Recovered ") {
            let marker = URL(fileURLWithPath: from).deletingLastPathComponent().appendingPathComponent(".kernir-keep")
            markedBeforeMove.withLock { $0 = FileManager.default.fileExists(atPath: marker.path) }
        }
        return rules(from, to, flags)
    }.fileSystem()

    let error = await #expect(throws: ExtractionRecoveryError.self) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(markedBeforeMove.withLock { $0 } == true)
    let staging = try #require(try stagingFolders(in: output).first)
    #expect(error?.kind == .inFolder)
    #expect(error?.kept.deletingLastPathComponent().lastPathComponent == staging)
    #expect(error?.kept.lastPathComponent.hasPrefix("Lutik Recovered ") == true)
    if let kept = error?.kept {
        #expect(try contents(of: kept.appendingPathComponent("README.md")) == "mine")
        #expect(error?.localizedDescription == "“README.md” couldn't be replaced. The original is in "
                + "“\(kept.lastPathComponent)”, inside the hidden folder “\(staging)”.")
    }
    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(staging + "/.kernir-keep").path))
    #expect(try contents(of: output.appendingPathComponent("README.md")) == "arrived meanwhile")
}

@MainActor @Test func replaceFallsThroughWhenTheTargetVanishesBeforeTheSwap() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let target = output.appendingPathComponent("README.md")
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { _, _, flags in
        guard flags == UInt32(RENAME_SWAP) else { return nil }
        try? FileManager.default.removeItem(at: target)
        return ENOENT
    }.fileSystem()

    try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)

    #expect(try snapshot(output) == ["README.md": "README.md"])
}

@MainActor @Test func aFileInTheWayOfANestedItemsFolderIsTheConflict() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("assets", in: output, contents: "a file")
    let model = makeModel()
    // As the engine reports it: the item in the way, which the user can answer about.
    #expect(model.extractionConflicts(["assets/cover.png"], in: output) == ["assets"])
    let before = try snapshot(output)
    await #expect(throws: ExtractionConflictError(paths: ["assets"])) {
        try await model.extract(["assets/cover.png"], to: output, progress: nil)
    }
    #expect(try snapshot(output) == before)

    let kept = try await model.extract(["assets/cover.png"], to: output, resolutions: ["assets": .keepBoth],
                                       progress: nil)
    #expect(kept == [output.appendingPathComponent("assets 2/cover.png", isDirectory: false)])
    #expect(try snapshot(output) == ["assets": "a file", "assets 2": "dir", "assets 2/cover.png": "assets/cover.png"])

    let replaced = try await model.extract(["assets/cover.png"], to: output, resolutions: ["assets": .replace],
                                           progress: nil)
    #expect(replaced == [output.appendingPathComponent("assets/cover.png", isDirectory: false)])
    #expect(try snapshot(output) == ["assets": "dir", "assets/cover.png": "assets/cover.png",
                                     "assets 2": "dir", "assets 2/cover.png": "assets/cover.png"])
}

@MainActor @Test func aSymlinkInTheWayOfANestedItemsFolderIsNeverFollowed() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let elsewhere = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("assets"),
                                               withDestinationURL: elsewhere)
    let model = makeModel()
    #expect(model.extractionConflicts(["assets/cover.png"], in: output) == ["assets"])
    let before = try snapshot(output)

    await #expect(throws: ExtractionConflictError(paths: ["assets"])) {
        try await model.extract(["assets/cover.png"], to: output, progress: nil)
    }
    let skipped = try await model.extract(["assets/cover.png"], to: output, resolutions: ["assets": .skip],
                                          progress: nil)
    #expect(skipped.isEmpty)
    #expect(try snapshot(output) == before)
    #expect(try snapshot(elsewhere).isEmpty)

    try await model.extract(["assets/cover.png"], to: output, resolutions: ["assets": .replace], progress: nil)
    #expect(try snapshot(output) == ["assets": "dir", "assets/cover.png": "assets/cover.png"])
    #expect(try snapshot(elsewhere).isEmpty)
}

@MainActor @Test func conflictsIgnoreCaseAndNormalizationAsTheVolumeDoes() async throws {
    // The harness runs on APFS, which compares names case- and normalization-insensitively.
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    try makeFile(nfdCafe + ".txt", in: output, contents: "mine too")
    let model = makeModel([file("readme.md"), file(nfcCafe + ".txt")])
    let before = try snapshot(output)

    #expect(model.extractionConflicts(nil, in: output) == [nfcCafe + ".txt", "readme.md"])
    await #expect(throws: ExtractionConflictError(paths: [nfcCafe + ".txt", "readme.md"])) {
        try await model.extract(nil, to: output, progress: nil)
    }
    #expect(try snapshot(output) == before)

    let written = try await model.extract(nil, to: output, resolutions: [nfcCafe + ".txt": .keepBoth,
                                                                         "readme.md": .keepBoth], progress: nil)
    #expect(written.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping }
            == [nfcCafe + " 2.txt", "readme 2.md"])
    #expect(try contents(of: output.appendingPathComponent("README.md")) == "mine")
    #expect(try contents(of: output.appendingPathComponent(nfdCafe + ".txt")) == "mine too")
    #expect(try contents(of: output.appendingPathComponent("readme 2.md")) == "readme.md")
}

@MainActor @Test func keepBothReservesNamesAcrossCase() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("A.txt", in: output, contents: "mine")
    let model = makeModel([file("A.txt"), file("a 2.txt")])

    try await model.extract(nil, to: output, resolutions: ["A.txt": .keepBoth], progress: nil)

    #expect(try snapshot(output) == ["A.txt": "mine", "a 2.txt": "a 2.txt", "A 3.txt": "A.txt"])
}

@MainActor @Test func keepBothOfANumberedNameCountsOnLikeFinder() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("notes 2.txt", in: output, contents: "mine")
    try makeFile("drafts 2/a.txt", in: output, contents: "mine")
    let model = makeModel([file("notes 2.txt"), folder("drafts 2"), file("drafts 2/b.txt")])

    let written = try await model.extract(nil, to: output, resolutions: ["notes 2.txt": .keepBoth,
                                                                         "drafts 2": .keepBoth], progress: nil)

    #expect(Set(written.map(\.lastPathComponent)) == ["notes 3.txt", "drafts 3"])
}

@MainActor @Test func stagedItemsMoveByTheSpellingTheReaderWrote() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let renames = FakeRenames()
    let model = makeModel(mixedSpellingEntries())
    model.extractionFileSystem = renames.fileSystem()

    // The tree spells it NFC (its folder's first spelling); the reader knows it, and writes it, as NFD.
    try await model.extract([nfcCafe + "/b.txt"], to: output, progress: nil)

    #expect(renames.sources.count == 1)
    #expect(renames.sources.first.map { bytes($0).reversed().starts(with: bytes("/" + nfdCafe + "/b.txt").reversed()) }
            == true)
}

@MainActor @Test func aStagedItemThatIsMissingFailsBeforeAnythingMoves() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    // The reader says it is done but README.md isn't there.
    let reader = GatedReader(base: FakeReader(entries: SampleArchive().entries)) {
        for name in try stagingFolders(in: output) {
            try FileManager.default.removeItem(at: output.appendingPathComponent(name + "/README.md"))
        }
    }
    let model = ArchiveModel(reader: reader, undoManager: nil)

    await #expect(throws: ArchiveError.entryNotFound("README.md")) {
        try await model.extract(["brief.pdf", "README.md"], to: output, progress: nil)
    }
    #expect(try snapshot(output).isEmpty)
}

@MainActor @Test func replaceReturnsWhereTheItemsWent() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    try makeFile("assets/cover.png", in: output, contents: "mine")
    try makeFile("src", in: output, contents: "a file where the archive has a folder")
    let model = makeModel()

    let written = try await model.extract(["README.md", "assets/cover.png", "src"], to: output,
                                          resolutions: ["README.md": .replace, "assets/cover.png": .replace,
                                                        "src": .replace], progress: nil)

    #expect(written == [output.appendingPathComponent("README.md", isDirectory: false),
                        output.appendingPathComponent("assets/cover.png", isDirectory: false),
                        output.appendingPathComponent("src", isDirectory: true)])
    #expect(written.map(\.hasDirectoryPath) == [false, false, true])
    #expect(try contents(of: output.appendingPathComponent("assets/cover.png")) == "assets/cover.png")
}

@Test func extractionRecoveryErrorSaysWhereTheOriginalIs() {
    let renamed = ExtractionRecoveryError(name: "Report.docx", kept: URL(fileURLWithPath: "/x/Report 2.docx"),
                                          kind: .renamed, underlying: POSIXError(.EIO))
    #expect(renamed.localizedDescription == String(
        localized: "“\("Report.docx")” couldn't be replaced. The original is now named “\("Report 2.docx")”.",
        table: "Shared"))
    let inFolder = ExtractionRecoveryError(name: "Report.docx",
                                           kept: URL(fileURLWithPath: "/x/Lutik Recovered", isDirectory: true),
                                           kind: .inFolder, underlying: POSIXError(.EIO))
    #expect(inFolder.localizedDescription == String(
        localized: "“\("Report.docx")” couldn't be replaced. The original is in “\("Lutik Recovered")”.",
        table: "Shared"))
    #expect(inFolder.localizedDescription == "“Report.docx” couldn't be replaced. The original is in “Lutik Recovered”.")
    // Inside staging (or any hidden folder) the text names the hidden folder too: iOS can't reveal it.
    let hidden = ExtractionRecoveryError(name: "Report.docx",
                                         kept: URL(fileURLWithPath: "/x/.kernir-abc/Lutik Recovered 1", isDirectory: true),
                                         kind: .inFolder, underlying: POSIXError(.EIO))
    #expect(hidden.localizedDescription == String(
        localized: "“\("Report.docx")” couldn't be replaced. The original is in “\("Lutik Recovered 1")”, inside the hidden folder “\(".kernir-abc")”.",
        table: "Shared"))
    #expect(hidden.localizedDescription
            == "“Report.docx” couldn't be replaced. The original is in “Lutik Recovered 1”, inside the hidden folder “.kernir-abc”.")
}

/// Rules for a Replace of README.md in `output` on a file system without RENAME_SWAP, where the old
/// item's step aside takes effect but reports ENOENT (an SMB/NFS request replayed after a reconnect).
/// `meanwhile`, when set, is then written to README.md, as something taking the name.
private func misreportedStepAsideRules(in output: URL, meanwhile: String?)
    -> @Sendable (String, String, UInt32) -> Int32? {
    let target = output.appendingPathComponent("README.md").path
    return { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        guard from == target, flags == 0 else { return nil }
        guard renamex_np(from, to, flags) == 0 else { return errno }
        if let meanwhile { try? makeFile("README.md", in: output, contents: meanwhile) }
        return ENOENT
    }
}

@MainActor @Test func aStepAsideThatTookEffectButReportedFailurePutsTheOldItemBack() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let model = makeModel()
    model.extractionFileSystem = FakeRenames(rule: misreportedStepAsideRules(in: output, meanwhile: nil))
        .fileSystem()

    await #expect(throws: POSIXError(.ENOENT)) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(try snapshot(output) == ["README.md": "mine"])
}

@MainActor @Test func aStepAsideThatTookEffectButReportedFailureKeepsTheOldItemBesideATakenName() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let model = makeModel()
    model.extractionFileSystem = FakeRenames(rule: misreportedStepAsideRules(in: output, meanwhile: "arrived meanwhile"))
        .fileSystem()

    let error = await #expect(throws: ExtractionRecoveryError.self) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(error?.kind == .renamed)
    #expect(error?.kept == output.appendingPathComponent("README 2.md", isDirectory: false))
    #expect(error?.underlying as? POSIXError == POSIXError(.ENOENT))
    #expect(try snapshot(output) == ["README.md": "arrived meanwhile", "README 2.md": "mine"])
}

@MainActor @Test func replaceWhoseNewItemCantMoveInPutsTheOldItemBackAndSaysWhy() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let target = output.appendingPathComponent("README.md").path
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        return to == target && parentName(from).hasPrefix(".kernir-") ? EIO : nil
    }.fileSystem()

    await #expect(throws: POSIXError(.EIO)) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(try snapshot(output) == ["README.md": "mine"])
}

/// No RENAME_SWAP: ENOTSUP, or EOPNOTSUPP (a separate number on Darwin, which some volumes may give).
@MainActor @Test(arguments: [ENOTSUP, EOPNOTSUPP])
func aCompletedStepAsideLeavesNoStaging(_ code: Int32) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { _, _, flags in
        flags == UInt32(RENAME_SWAP) ? code : nil
    }.fileSystem()

    try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)

    #expect(try snapshot(output) == ["README.md": "README.md"])
}

/// No RENAME_EXCL (ENOTSUP, or EOPNOTSUPP): checked, then a plain rename; the item still arrives.
@MainActor @Test(arguments: [ENOTSUP, EOPNOTSUPP])
func withoutExclusiveRenamesTheItemStillArrives(_ code: Int32) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { _, _, flags in
        flags == UInt32(RENAME_EXCL) ? code : nil
    }.fileSystem()

    try await model.extract(["README.md"], to: output, progress: nil)

    #expect(try snapshot(output) == ["README.md": "README.md"])
}

@MainActor @Test func stagingStillHoldingARecoveredItemIsNeverDeleted() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let target = output.appendingPathComponent("README.md").path
    let left = "Lutik Recovered \(UUID().uuidString)/README.md"
    let model = makeModel()
    // A recovered item some path left in the marked staging.
    model.extractionFileSystem = FakeRenames { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        if to == target, parentName(from).hasPrefix(".kernir-") {
            try? makeFile(left, in: URL(fileURLWithPath: from).deletingLastPathComponent(), contents: "left behind")
        }
        return nil
    }.fileSystem()

    try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)

    let staging = try #require(try stagingFolders(in: output).first)
    #expect(try contents(of: output.appendingPathComponent(staging + "/" + left)) == "left behind")
    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(staging + "/.kernir-keep").path))
    #expect(try contents(of: output.appendingPathComponent("README.md")) == "README.md")
}

// N-8: the marker's lstat can fail on a flaky volume (EIO on an SMB reconnect) and look like no marker;
// a recovered item alone keeps staging, so an unmarked staging stands in for that failure.
@MainActor @Test func stagingHoldingARecoveredItemIsKeptEvenWithoutTheMarker() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let target = output.appendingPathComponent("README.md").path
    let left = "Lutik Recovered \(UUID().uuidString)/README.md"
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { from, to, _ in
        if to == target, parentName(from).hasPrefix(".kernir-") {
            try? makeFile(left, in: URL(fileURLWithPath: from).deletingLastPathComponent(), contents: "left behind")
        }
        return nil
    }.fileSystem()

    try await model.extract(["README.md"], to: output, progress: nil)

    let staging = try #require(try stagingFolders(in: output).first)
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent(staging + "/.kernir-keep").path))
    #expect(try contents(of: output.appendingPathComponent(staging + "/" + left)) == "left behind")
    #expect(try contents(of: output.appendingPathComponent("README.md")) == "README.md")
}

/// Does the real rename, then reports `code`: a move that took effect but reported failure.
private func misreport(_ from: String, _ to: String, _ flags: UInt32, _ code: Int32) -> Int32 {
    renamex_np(from, to, flags) == 0 ? code : errno
}

// N-6: a restore move that took effect but reported failure must not point at an empty folder.
@MainActor @Test func aMisreportedMoveBackStillSaysTheOldItemIsBack() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let target = output.appendingPathComponent("README.md").path
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        if from == target { return misreport(from, to, flags, ENOENT) }
        if to == target, parentName(from).hasPrefix("Lutik Recovered ") { return misreport(from, to, flags, EIO) }
        return nil
    }.fileSystem()

    await #expect(throws: POSIXError(.ENOENT)) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(try snapshot(output) == ["README.md": "mine"])
}

@MainActor @Test func aMisreportedKeepBothMoveStillSaysWhereTheOldItemIs() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try makeFile("README.md", in: output, contents: "mine")
    let target = output.appendingPathComponent("README.md").path
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        // The new item can't move in, and the old one can't go back: it goes to "README 2.md".
        if to == target, parentName(from).hasPrefix(".kernir-") || parentName(from).hasPrefix("Lutik Recovered ") {
            return EIO
        }
        if parentName(from).hasPrefix("Lutik Recovered ") { return misreport(from, to, flags, EIO) }
        return nil
    }.fileSystem()

    let error = await #expect(throws: ExtractionRecoveryError.self) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(error?.kind == .renamed)
    #expect(error?.kept == output.appendingPathComponent("README 2.md", isDirectory: false))
    #expect(error?.underlying as? POSIXError == POSIXError(.EIO))
    #expect(try snapshot(output) == ["README 2.md": "mine"])
}

/// Makes every folder under `directory` searchable again after a test took the permissions away.
private func unlockFolders(in directory: URL) {
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
        let url = directory.appendingPathComponent(name)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
        chmod(url.path, 0o755)
        unlockFolders(in: url)
    }
}

// N-9: an lstat of the old item that fails for another reason than ENOENT (here EACCES; on SMB an EIO
// during a reconnect) doesn't mean it moved back: the racing item at README.md stays, the old one is kept.
@MainActor @Test(.enabled(if: geteuid() != 0, "root ignores the folder permissions"))
func aFailedLookAtTheOldItemIsNotReadAsMovedBack() async throws {
    let output = try makeTempDirectory()
    defer {
        unlockFolders(in: output)
        try? FileManager.default.removeItem(at: output)
    }
    try makeFile("README.md", in: output, contents: "mine")
    let target = output.appendingPathComponent("README.md").path
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        if to == target, parentName(from).hasPrefix(".kernir-") {
            try? makeFile("README.md", in: output, contents: "arrived meanwhile")
            return EEXIST
        }
        if to == target, parentName(from).hasPrefix("Lutik Recovered ") {
            chmod(URL(fileURLWithPath: from).deletingLastPathComponent().path, 0)
            return EIO
        }
        return nil
    }.fileSystem()

    let error = await #expect(throws: ExtractionRecoveryError.self) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }
    unlockFolders(in: output)

    #expect(error?.kind == .inFolder)
    #expect(try snapshot(output)["README.md"] == "arrived meanwhile")
    let kept = try #require(error?.kept)
    #expect(try String(contentsOf: kept.appendingPathComponent("README.md"), encoding: .utf8) == "mine")
}

// N-9: the old item gone for sure (ENOENT) and at neither name we tried: the plain error, no empty folder.
@MainActor @Test func anOldItemGoneElsewhereGivesThePlainError() async throws {
    let output = try makeTempDirectory()
    let elsewhere = try makeTempDirectory()
    defer {
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    try makeFile("README.md", in: output, contents: "mine")
    let target = output.appendingPathComponent("README.md").path
    let model = makeModel()
    model.extractionFileSystem = FakeRenames { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        if to == target, parentName(from).hasPrefix(".kernir-") { return EIO }
        if to == target, parentName(from).hasPrefix("Lutik Recovered ") {
            // Someone else moved it away meanwhile.
            _ = renamex_np(from, elsewhere.appendingPathComponent("README.md").path, 0)
            return EIO
        }
        return nil
    }.fileSystem()

    await #expect(throws: POSIXError(.EIO)) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    #expect(try snapshot(output).isEmpty)
    #expect(try snapshot(elsewhere) == ["README.md": "mine"])
}

// N-2: only a Finder copy number (" 2"… " 999", no leading zero) counts on; any other number is part of the name.
@MainActor @Test func keepBothCountsOnOnlyFromACopyNumber() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let names = ["Report 2024.pdf", "Chapter 1.txt", "Take 02.wav", "Track 0.mp3", "notes 5.txt", "name 2.txt",
                 "Take 999.wav", "Mix 1000.wav", ".profile", ".env 2"]
    for name in names { try makeFile(name, in: output, contents: "mine") }
    let model = makeModel(names.map { file($0) })

    let written = try await model.extract(nil, to: output, resolutions: Dictionary(uniqueKeysWithValues: names.map {
        ($0, ExtractionConflictResolution.keepBoth)
    }), progress: nil)

    #expect(written.map(\.lastPathComponent).sorted() == [".env 3", ".profile 2", "Chapter 1 2.txt", "Mix 1000 2.wav",
                                                          "Report 2024 2.pdf", "Take 02 2.wav", "Take 1000.wav",
                                                          "Track 0 2.mp3", "name 3.txt", "notes 6.txt"])
}

// MARK: - Quarantine

#if os(macOS)
/// The download event `url`'s quarantine names, nil when it names none. Not the agent: in the sandboxed
/// host the sandbox records Lutik as the agent of every quarantine Lutik sets, and quarantines every file
/// it creates in its temporary folder (0086, with no event).
func quarantineEvent(of url: URL) throws -> String? {
    var url = url
    url.removeAllCachedResourceValues()
    let properties = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    return properties?["LSQuarantineEventIdentifier"] as? String
}

/// The download event of `writeQuarantineSample`'s quarantined archive.
let sampleQuarantineEvent = "9A1B2C3D-0000-4000-8000-0000000000AB"

/// A zip of `proj/a.txt` and `proj/sub/b.txt` in `dir`, quarantined as Safari's download when `quarantined`.
/// Internal: ExtractHereServiceTests and ArchiveDocumentTests use it too.
@MainActor
func writeQuarantineSample(in dir: URL, quarantined: Bool) async throws -> URL {
    let source = dir.appendingPathComponent("src", isDirectory: true)
    try makeFile("proj/a.txt", in: source)
    try makeFile("proj/sub/b.txt", in: source)
    let adder = makeModel([])
    adder.add([source.appendingPathComponent("proj")], to: "")
    var archive = dir.appendingPathComponent("download.zip")
    try await ArchiveWriter.write(source: nil, changes: adder.changes, format: .zip, to: archive)
    if quarantined {
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineAgentName": "Safari",
                                       "LSQuarantineType": "LSQuarantineTypeWebDownload",
                                       "LSQuarantineEventIdentifier": sampleQuarantineEvent]
        try archive.setResourceValues(values)
        archive.removeAllCachedResourceValues()
        #expect(try quarantineEvent(of: archive) == sampleQuarantineEvent)
    }
    return archive
}

/// Extracting a downloaded (quarantined) archive quarantines every extracted item, as Archive Utility
/// does: with `files.user-selected.executable` the sandbox no longer quarantines what the app
/// writes, so Lutik must carry the source's quarantine over itself (no Gatekeeper bypass).
@MainActor @Test func extractingAQuarantinedArchiveQuarantinesEveryItem() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try await writeQuarantineSample(in: dir, quarantined: true)
    let model = ArchiveModel(reader: try await Archive.open(at: archive), undoManager: nil)
    let output = dir.appendingPathComponent("out", isDirectory: true)

    try await model.extract(nil, to: output, progress: nil)

    for path in ["proj", "proj/a.txt", "proj/sub", "proj/sub/b.txt"] {
        #expect(try quarantineEvent(of: output.appendingPathComponent(path)) == sampleQuarantineEvent, "\(path)")
    }
}

/// A clean archive's items stay clean: Lutik never adds a quarantine of its own.
@MainActor @Test func extractingACleanArchiveLeavesItemsUnquarantined() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try await writeQuarantineSample(in: dir, quarantined: false)
    let model = ArchiveModel(reader: try await Archive.open(at: archive), undoManager: nil)
    let output = dir.appendingPathComponent("out", isDirectory: true)

    try await model.extract(["proj/sub"], to: output, progress: nil)

    // Extracted under the archive path (proj/sub, not sub). No quarantine at all, except, in the sandboxed
    // host, the sandbox's own mark on what Lutik writes in its container (`isOwnSandboxMark`): no download
    // event, nothing Lutik carried over. Unsandboxed (shared harness) nobody marks them.
    let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    for path in ["proj/sub", "proj/sub/b.txt"] {
        let item = output.appendingPathComponent(path)
        #expect(FileManager.default.fileExists(atPath: item.path), "\(path)")
        #expect(try quarantineEvent(of: item) == nil, "\(path)")
        if let marked = QuarantinePropagation.quarantineProperties(of: item) {
            #expect(sandboxed && QuarantinePropagation.isOwnSandboxMark(marked), "\(path): \(marked)")
        }
    }
    // In the sandboxed host the archive has the sandbox's own mark (Lutik wrote it in its container):
    // nothing to carry over.
    #expect(QuarantinePropagation.properties(of: model.quarantineSources) == nil)
}

/// The folders an extraction makes above a requested item are quarantined too, with all they hold
/// (`Evil.app/Contents` comes out in a new `Evil.app`, which Gatekeeper checks); a folder the user
/// already had there is left as it is, with what was in it.
@MainActor @Test func extractingAnItemQuarantinesTheFoldersMadeAboveIt() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try await writeQuarantineSample(in: dir, quarantined: true)
    let model = ArchiveModel(reader: try await Archive.open(at: archive), undoManager: nil)
    let output = dir.appendingPathComponent("out", isDirectory: true)

    try await model.extract(["proj/sub"], to: output, progress: nil)

    for path in ["proj", "proj/sub", "proj/sub/b.txt"] {
        #expect(try quarantineEvent(of: output.appendingPathComponent(path)) == sampleQuarantineEvent, "\(path)")
    }
    #expect(try quarantineEvent(of: output) == nil)

    // The user's own `proj` (and their file in it) stays unmarked; only what came out of the archive is.
    let own = dir.appendingPathComponent("own", isDirectory: true)
    try makeFile("proj/mine.txt", in: own)
    try await model.extract(["proj/sub"], to: own, progress: nil)
    #expect(try quarantineEvent(of: own.appendingPathComponent("proj")) == nil)
    #expect(try quarantineEvent(of: own.appendingPathComponent("proj/mine.txt")) == nil)
    for path in ["proj/sub", "proj/sub/b.txt"] {
        #expect(try quarantineEvent(of: own.appendingPathComponent(path)) == sampleQuarantineEvent, "\(path)")
    }
}

/// A move that fails partway leaves what already moved in place, quarantined: the staging is marked
/// before anything moves, and what moved (the folders made for it included) is marked again on the way out.
@MainActor @Test func aMoveThatFailsPartwayLeavesWhatMovedQuarantined() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try await writeQuarantineSample(in: dir, quarantined: true)
    let model = ArchiveModel(reader: try await Archive.open(at: archive), undoManager: nil)
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: "0a0b0c0d0e0f0a0b") { from, to, flags in
        if to.hasSuffix("/proj/sub") { return EIO }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    let output = dir.appendingPathComponent("out", isDirectory: true)

    await #expect(throws: (any Error).self) {
        try await model.extract(["proj/a.txt", "proj/sub"], to: output, progress: nil)
    }

    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("proj/a.txt").path))
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("proj/sub").path))
    for path in ["proj", "proj/a.txt"] {
        #expect(try quarantineEvent(of: output.appendingPathComponent(path)) == sampleQuarantineEvent, "\(path)")
    }
}

/// Marking a tree stops early once the task is cancelled only where the caller allows it (the staging,
/// which a cancel then removes); marking what is already in place never stops.
@Test func quarantineMarkingStopsOnACancelOnlyWhenAllowed() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tree = dir.appendingPathComponent("tree", isDirectory: true)
    for index in 0..<600 { try makeFile("f\(index).txt", in: tree) }
    let properties: [String: Any] = ["LSQuarantineAgentName": "Safari",
                                     "LSQuarantineEventIdentifier": sampleQuarantineEvent]
    let mark = QuarantinePropagation.Mark(properties: properties)
    let counts = await Task { () -> (stopping: Int, whole: Int) in
        withUnsafeCurrentTask { $0?.cancel() }
        return (mark.apply(to: [tree], stopsWhenCancelled: true), mark.apply(to: [tree]))
    }.value
    #expect(counts.stopping == 0)
    #expect(counts.whole == 601)
    #expect(try quarantineEvent(of: tree.appendingPathComponent("f599.txt")) == sampleQuarantineEvent)
}
#endif

#if os(macOS)
/// The sandbox quarantines every file Lutik writes in its container (0086, agent Lutik, no event): an
/// archive Lutik made there, such as an inner archive of a clean one, isn't a download, and that mark is
/// never carried over (Gatekeeper would refuse what comes out of it). A download's mark always is, also
/// once Lutik set it (agent Lutik, the event kept), and so is another app's.
@Test func lutiksOwnSandboxQuarantineIsNeverCarriedOver() throws {
    let own: Set<String> = ["Lutik", "com.kernir.app"]
    #expect(QuarantinePropagation.isOwnSandboxMark(["LSQuarantineAgentName": "Lutik"], agents: own))
    #expect(QuarantinePropagation.isOwnSandboxMark(["LSQuarantineAgentName": "Lutik",
                                                    "LSQuarantineAgentBundleIdentifier": "com.kernir.app"], agents: own))
    #expect(!QuarantinePropagation.isOwnSandboxMark(["LSQuarantineAgentName": "Lutik",
                                                     "LSQuarantineEventIdentifier": sampleQuarantineEvent], agents: own))
    #expect(!QuarantinePropagation.isOwnSandboxMark(["LSQuarantineAgentName": "Lutik",
                                                     "LSQuarantineOriginURL": "https://example.com"], agents: own))
    #expect(!QuarantinePropagation.isOwnSandboxMark(["LSQuarantineAgentName": "Safari"], agents: own))
    #expect(!QuarantinePropagation.isOwnSandboxMark([:], agents: own))

    // A file this process writes in its temporary folder: in the sandboxed host the sandbox quarantines it.
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("made.zip")
    try Data("PK".utf8).write(to: file)
    let marked = QuarantinePropagation.quarantineProperties(of: file)
    if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
        #expect(marked != nil, "the sandbox no longer quarantines what Lutik writes in its container")
    }
    if let marked {
        #expect(QuarantinePropagation.isOwnSandboxMark(marked), "\(marked) vs \(QuarantinePropagation.ownAgentNames)")
    }
    #expect(QuarantinePropagation.properties(of: [file]) == nil)
    #expect(QuarantinePropagation.propagate(from: [file], to: [file], recursive: false) == 0)
}
#endif
