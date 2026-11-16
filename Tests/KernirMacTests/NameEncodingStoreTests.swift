import Testing
import Foundation
@testable import Kernir
import KernirCore

// App/Shared only (no AppKit): the per-archive name encoding store and `ArchiveModel.reopen(nameEncoding:)`.

/// A store in defaults of its own (`makeTestDefaults`: its plist stays in the temporary folder);
/// `cleanUp()` removes them.
private struct TestStore {
    let suiteName: String
    let defaults: UserDefaults
    let store: ArchiveNameEncodingStore

    init(capacity: Int = ArchiveNameEncodingStore.defaultCapacity) {
        let made = makeTestDefaults("NameEncodingStoreTests")
        defaults = made.0
        suiteName = made.1
        store = ArchiveNameEncodingStore(defaults: defaults, capacity: capacity)
    }

    /// Another store on the same defaults, as after relaunching the app.
    func reloaded() -> ArchiveNameEncodingStore {
        ArchiveNameEncodingStore(defaults: UserDefaults(suiteName: suiteName)!, capacity: store.capacity)
    }

    func cleanUp() {
        removeTestDefaults(defaults, suite: suiteName)
    }
}

/// Fresh empty directory; the caller removes it.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NameEncodingStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeFile(_ name: String, in directory: URL, contents: String = "zip") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

private func fileID(_ url: URL) throws -> UInt64? {
    try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier
}

private let cp1251 = String.Encoding.windowsCP1251
private let cp866 = String.Encoding.testCP866

/// A CP1251 zip with an ASCII folder and a Cyrillic one, each holding a Cyrillic-named file.
private let cyrillicPaths = ["Docs/", "Docs/Отчёт.txt", "Папка/", "Папка/Отчёт за май.txt"]

/// `path` as a CP866 reader shows the CP1251 bytes of `path`.
private func cp866Reading(of path: String) -> String {
    String(data: path.data(using: cp1251)!, encoding: cp866)!.precomposedStringWithCanonicalMapping
}

// MARK: - Store

@Test func rememberedChoiceIsReadBackAndSurvivesRelaunch() throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeFile("a.zip", in: dir)
    let other = try makeFile("b.zip", in: dir)

    #expect(test.store.nameEncoding(for: archive) == .automatic)
    test.store.remember(.specific(cp866), for: archive)

    #expect(test.store.nameEncoding(for: archive) == .specific(cp866))
    #expect(test.reloaded().nameEncoding(for: archive) == .specific(cp866))
    #expect(test.store.nameEncoding(for: other) == .automatic)
    // The same file however its path is spelled.
    let dotted = dir.appendingPathComponent("sub/../a.zip")
    #expect(test.store.nameEncoding(for: dotted) == .specific(cp866))
}

@Test func automaticForgetsTheChoice() throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeFile("a.zip", in: dir)
    test.store.remember(.specific(cp866), for: archive)

    test.store.remember(.automatic, for: archive)

    #expect(test.store.nameEncoding(for: archive) == .automatic)
    #expect(test.reloaded().nameEncoding(for: archive) == .automatic)
    // Nothing is left behind.
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)
}

/// A safe save swaps a new file in (new file ID) and keeps the creation date: still the same archive.
@Test func choiceSurvivesASafeSaveReplacingTheFile() throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeFile("a.zip", in: dir, contents: "before")
    test.store.remember(.specific(cp1251), for: archive)
    let before = try fileID(archive)

    let written = try makeFile("written.zip", in: dir, contents: "after")
    _ = try FileManager.default.replaceItemAt(archive, withItemAt: written)

    #expect(try fileID(archive) != before)
    #expect(test.store.nameEncoding(for: archive) == .specific(cp1251))
}

/// A write in place keeps the file ID.
@Test func choiceSurvivesAWriteInPlace() throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeFile("a.zip", in: dir)
    test.store.remember(.specific(cp1251), for: archive)

    let handle = try FileHandle(forWritingTo: archive)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("more".utf8))
    try handle.close()

    #expect(test.store.nameEncoding(for: archive) == .specific(cp1251))
}

/// Another archive later saved under the same name (new file ID, new creation date) isn't read with the
/// old one's choice, and the stale record goes.
@Test func anotherFileAtTheSamePathDoesNotGetTheChoice() throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeFile("a.zip", in: dir)
    test.store.remember(.specific(cp1251), for: archive)

    try FileManager.default.removeItem(at: archive)
    Thread.sleep(forTimeInterval: 0.01)
    _ = try makeFile("a.zip", in: dir, contents: "another archive")

    #expect(test.store.nameEncoding(for: archive) == .automatic)
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)
}

/// The choice is keyed by path, so a file renamed or moved loses it (accepted
/// for v1). Moved back, the same file has it again.
@Test func movedFileLosesItsChoice() throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeFile("a.zip", in: dir)
    test.store.remember(.specific(cp1251), for: archive)
    let sub = dir.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

    for moved in [dir.appendingPathComponent("renamed.zip"), sub.appendingPathComponent("a.zip")] {
        try FileManager.default.moveItem(at: archive, to: moved)
        #expect(test.store.nameEncoding(for: moved) == .automatic)
        try FileManager.default.moveItem(at: moved, to: archive)
    }
    #expect(test.store.nameEncoding(for: archive) == .specific(cp1251))
}

// MARK: - After a save

/// Opens `url` after a save the way both apps do: `ArchiveModel.openSaved`, with an `open` that decodes
/// names as told and reads no store, so nothing depends on the engine and the model sharing one.
/// Counts the opens.
@MainActor private func openSaved(_ url: URL, by model: ArchiveModel, store: ArchiveNameEncodingStore,
                                  opens: inout Int) async throws -> any ArchiveReading {
    var count = 0
    defer { opens = count }
    return try await model.openSaved(url) { url, encoding in
        count += 1
        return try await Archive.open(at: url, nameEncoding: encoding)
    }
}

/// A model showing the CP866 zip `zip` read with CP866, the choice remembered for it.
@MainActor private func cp866Model(_ zip: URL, store: ArchiveNameEncodingStore) async throws -> ArchiveModel {
    store.remember(.specific(cp866), for: zip)
    let model = ArchiveModel(reader: try await store.open(zip, password: nil), undoManager: nil)
    model.nameEncodingStore = store
    #expect(model.reader?.nameEncoding == .specific(cp866))
    #expect(model.item(at: "Папка/Отчёт за май.txt") != nil)
    return model
}

/// Saved as tar, a CP866 zip's names are all written as UTF-8 (another container
/// family; a non-ASCII name added to a tar does the same). Read with the remembered CP866 they would be
/// mojibake: the written file forgets the choice and keeps the automatic reading.
@MainActor @Test func saveThatWroteEveryNameAsUTF8ForgetsTheManualChoice() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp866)
    let dir = zip.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = try await cp866Model(zip, store: test.store)
    let added = try makeFile("Новый.txt", in: dir, contents: "new")
    let tar = dir.appendingPathComponent("saved.tar")
    try await ArchiveWriter.write(source: model.reader, changes: ArchiveChangeSet(additions: [
        .init(sourceURL: added, destinationDirectory: "Папка")]), format: .tar, to: tar)

    var opens = 0
    let reader = try await openSaved(tar, by: model, store: test.store, opens: &opens)

    #expect(reader.nameEncoding == .automatic)
    let paths = Set(reader.entries.map(\.path))
    #expect(paths.isSuperset(of: ["Docs/Отчёт.txt", "Папка/Отчёт за май.txt", "Папка/Новый.txt"]))
    #expect(test.store.nameEncoding(for: tar) == .automatic)
    #expect(opens == 1)
    // The source keeps its own choice.
    #expect(test.store.nameEncoding(for: zip) == .specific(cp866))
}

/// A zip saved as zip keeps its entries' stored bytes: the written file, a Save As
/// copy or the original replaced in place, keeps the manual choice and is read with it.
@MainActor @Test func saveThatKeptTheStoredNamesKeepsTheManualChoice() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp866)
    let dir = zip.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = try await cp866Model(zip, store: test.store)
    let removal = ArchiveChangeSet(removedPaths: ["Docs/Отчёт.txt"])

    // Save As.
    let copy = dir.appendingPathComponent("copy.zip")
    try await ArchiveWriter.write(source: model.reader, changes: removal, format: .zip, to: copy)
    var opens = 0
    let reader = try await openSaved(copy, by: model, store: test.store, opens: &opens)
    #expect(reader.nameEncoding == .specific(cp866))
    #expect(reader.entries.contains { $0.path == "Папка/Отчёт за май.txt" })
    #expect(!reader.entries.contains { $0.path == "Docs/Отчёт.txt" })
    #expect(test.store.nameEncoding(for: copy) == .specific(cp866))
    #expect(opens == 2)

    // A save replacing the file: a new file takes the path, with nothing in common with the old one.
    let written = dir.appendingPathComponent("written.zip")
    try await ArchiveWriter.write(source: model.reader, changes: removal, format: .zip, to: written)
    try FileManager.default.removeItem(at: zip)
    try await Task.sleep(for: .milliseconds(10))
    try FileManager.default.moveItem(at: written, to: zip)
    #expect(test.store.nameEncoding(for: zip) == .automatic)
    let replaced = try await openSaved(zip, by: model, store: test.store, opens: &opens)
    #expect(replaced.nameEncoding == .specific(cp866))
    #expect(test.store.nameEncoding(for: zip) == .specific(cp866))
}

/// The second open, with the manual choice, fails (the file changed meanwhile, an I/O
/// error). The automatic reading already in hand is kept, and the file has no choice, as that reading shows.
@MainActor @Test func failedSecondOpenKeepsTheAutomaticReading() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp866)
    let dir = zip.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = try await cp866Model(zip, store: test.store)
    let copy = dir.appendingPathComponent("copy.zip")
    try await ArchiveWriter.write(source: model.reader, changes: ArchiveChangeSet(), format: .zip, to: copy)

    var asked: [ArchiveNameEncoding] = []
    let reader = try await model.openSaved(copy) { url, encoding in
        asked.append(encoding)
        guard encoding == .automatic else { throw ArchiveError.io("gone") }
        return try await Archive.open(at: url, nameEncoding: encoding)
    }

    #expect(asked == [.automatic, .specific(cp866)])
    #expect(reader.nameEncoding == .automatic)
    #expect(reader.entries.count == model.reader?.entries.count)
    #expect(test.store.nameEncoding(for: copy) == .automatic)
}

/// An automatic model's save opens once and forgets a choice left for the path.
@MainActor @Test func automaticSaveOpensOnceAndForgetsAStaleChoice() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp1251)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
    let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: nil)
    model.nameEncodingStore = test.store
    test.store.remember(.specific(cp866), for: zip)

    var opens = 0
    let reader = try await openSaved(zip, by: model, store: test.store, opens: &opens)

    #expect(reader.nameEncoding == .automatic)
    #expect(reader.entries.contains { $0.path == "Папка/Отчёт за май.txt" })
    #expect(test.store.nameEncoding(for: zip) == .automatic)
    #expect(opens == 1)
}

@Test func leastRecentlyUsedChoiceGoesBeyondTheCap() throws {
    #expect(ArchiveNameEncodingStore.defaultCapacity == 200)
    let test = TestStore(capacity: 3)
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = try (0..<5).map { try makeFile("\($0).zip", in: dir) }
    for file in files.prefix(3) { test.store.remember(.specific(cp866), for: file) }

    // Reading 0 makes it the most recently used, so adding 3 drops 1, the least recently used.
    #expect(test.store.nameEncoding(for: files[0]) == .specific(cp866))
    test.store.remember(.specific(cp1251), for: files[3])

    #expect(test.store.nameEncoding(for: files[1]) == .automatic)
    #expect(test.store.nameEncoding(for: files[0]) == .specific(cp866))
    #expect(test.store.nameEncoding(for: files[2]) == .specific(cp866))
    #expect(test.store.nameEncoding(for: files[3]) == .specific(cp1251))

    // Choosing again for a remembered file doesn't grow the store.
    test.store.remember(.specific(cp1251), for: files[0])
    test.store.remember(.specific(cp866), for: files[4])
    #expect(test.store.nameEncoding(for: files[0]) == .specific(cp1251))
    #expect(test.store.nameEncoding(for: files[4]) == .specific(cp866))
    #expect(test.store.nameEncoding(for: files[2]) == .automatic)
}

/// Looking up the most recently used record writes nothing; another one moves to
/// the front. The test marks the stored data (trailing whitespace, still valid JSON): a write re-encodes it.
@Test func lookingUpTheMostRecentChoiceWritesNothing() throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let older = try makeFile("older.zip", in: dir)
    let newer = try makeFile("newer.zip", in: dir)
    test.store.remember(.specific(cp1251), for: older)
    test.store.remember(.specific(cp866), for: newer)
    let stored = try #require(test.defaults.data(forKey: ArchiveNameEncodingStore.defaultsKey))
    let marked = stored + Data(" ".utf8)
    test.defaults.set(marked, forKey: ArchiveNameEncodingStore.defaultsKey)

    #expect(test.store.nameEncoding(for: newer) == .specific(cp866))
    #expect(test.defaults.data(forKey: ArchiveNameEncodingStore.defaultsKey) == marked)

    #expect(test.store.nameEncoding(for: older) == .specific(cp1251))
    let moved = try #require(test.defaults.data(forKey: ArchiveNameEncodingStore.defaultsKey))
    #expect(moved != marked)
    #expect(moved.count == stored.count)
}

@Test func unreadableOrUnknownRecordsReadAsAutomatic() throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeFile("a.zip", in: dir)

    test.defaults.set(Data("not json".utf8), forKey: ArchiveNameEncodingStore.defaultsKey)
    #expect(test.store.nameEncoding(for: archive) == .automatic)

    // An encoding that isn't one of the menu's choices (here UTF-16) is never applied.
    test.store.remember(.specific(cp866), for: archive)
    let data = try #require(test.defaults.data(forKey: ArchiveNameEncodingStore.defaultsKey))
    let json = String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\"encoding\":\(cp866.rawValue)",
                              with: "\"encoding\":\(String.Encoding.utf16.rawValue)")
    test.defaults.set(Data(json.utf8), forKey: ArchiveNameEncodingStore.defaultsKey)
    #expect(test.store.nameEncoding(for: archive) == .automatic)

    // A missing file has no choice, and remembering one for it keeps nothing.
    let missing = dir.appendingPathComponent("missing.zip")
    test.store.remember(.specific(cp866), for: missing)
    #expect(test.store.nameEncoding(for: missing) == .automatic)
}

/// The open path both apps use applies the remembered choice; Quick Look doesn't use it.
@Test func storeOpensWithTheRememberedChoice() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp1251)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

    let automatic = try await test.store.open(zip, password: nil)
    #expect(automatic.nameEncoding == .automatic)
    #expect(automatic.legacyNameEncoding == cp1251)
    #expect(automatic.entries.contains { $0.path == "Папка/Отчёт за май.txt" })

    test.store.remember(.specific(cp866), for: zip)
    let manual = try await test.store.open(zip, password: nil)
    #expect(manual.nameEncoding == .specific(cp866))
    #expect(manual.legacyNameEncoding == cp866)
    #expect(manual.entries.contains { $0.path == cp866Reading(of: "Папка/Отчёт за май.txt") })
}

// MARK: - Reopen

@MainActor @Test func reopenRelistsKeepsListedFoldersAndRemembers() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp1251)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
    let undoManager = UndoManager()
    let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: undoManager)
    model.nameEncodingStore = test.store
    #expect(model.item(at: "Папка/Отчёт за май.txt") != nil)
    #expect(model.listedFolders(among: ["Docs", "Папка", "Docs/Отчёт.txt", "gone"]) == ["Docs", "Папка"])
    // An edit undone: nothing unsaved, but the redo step refers to the old listing.
    model.remove(["Docs"])
    undoManager.undo()
    #expect(!model.hasChanges)
    #expect(undoManager.canRedo)

    try await model.reopen(nameEncoding: .specific(cp866))

    #expect(model.reader?.nameEncoding == .specific(cp866))
    #expect(model.reader?.legacyNameEncoding == cp866)
    #expect(model.item(at: "Папка") == nil)
    #expect(model.item(at: cp866Reading(of: "Папка/Отчёт за май.txt")) != nil)
    #expect(model.item(at: "Docs/" + cp866Reading(of: "Отчёт.txt")) != nil)
    #expect(model.children(of: "").map(\.name).sorted() == ["Docs", cp866Reading(of: "Папка")].sorted())
    // The expanded "Docs" stays expanded; "Папка" is listed under another name now.
    #expect(model.listedFolders(among: ["Docs", "Папка"]) == ["Docs"])
    #expect(!model.hasChanges)
    #expect(!undoManager.canRedo && !undoManager.canUndo)
    #expect(test.store.nameEncoding(for: zip) == .specific(cp866))

    try await model.reopen(nameEncoding: .automatic)

    #expect(model.reader?.nameEncoding == .automatic)
    #expect(model.item(at: "Папка/Отчёт за май.txt") != nil)
    #expect(test.store.nameEncoding(for: zip) == .automatic)
}

@MainActor @Test func failedReopenChangesNothing() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp1251)
    let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: nil)
    model.nameEncodingStore = test.store
    try FileManager.default.removeItem(at: zip.deletingLastPathComponent())

    await #expect(throws: (any Error).self) {
        try await model.reopen(nameEncoding: .specific(cp866))
    }

    #expect(model.reader?.nameEncoding == .automatic)
    #expect(model.item(at: "Папка/Отчёт за май.txt") != nil)
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)
}

/// Holds `ArchiveModel.reopen`'s open until the test lets it go, so the test can act while it runs.
private struct HeldOpen {
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releasedContinuation: AsyncStream<Void>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
        (released, releasedContinuation) = AsyncStream<Void>.makeStream()
    }

    func open(_ url: URL, _ password: String?, _ encoding: ArchiveNameEncoding) async throws -> any ArchiveReading {
        startedContinuation.yield()
        for await _ in released { break }
        return try await Archive.open(at: url, password: password, nameEncoding: encoding)
    }

    func waitUntilStarted() async {
        for await _ in started { break }
    }

    func release() {
        releasedContinuation.yield()
    }
}

/// An edit made while the reopen reads the file wins: adopting the new listing would
/// silently drop it, so the reopen applies and remembers nothing.
@MainActor @Test func reopenAppliesNothingWhenTheArchiveChangedMeanwhile() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp1251)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
    let undoManager = UndoManager()
    let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: undoManager)
    model.nameEncodingStore = test.store
    let held = HeldOpen()

    let reopen = Task { try await model.reopen(nameEncoding: .specific(cp866), open: held.open) }
    await held.waitUntilStarted()
    model.remove(["Docs"])
    held.release()

    await #expect(throws: CancellationError.self) { try await reopen.value }
    #expect(model.reader?.nameEncoding == .automatic)
    #expect(model.item(at: "Docs") == nil)
    #expect(model.item(at: "Папка/Отчёт за май.txt") != nil)
    #expect(model.hasChanges)
    #expect(undoManager.canUndo)
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)

    // Undone, and a save adopted meanwhile: the model changed too.
    undoManager.undo()
    #expect(!model.hasChanges)
    let again = HeldOpen()
    let second = Task { try await model.reopen(nameEncoding: .specific(cp866), open: again.open) }
    await again.waitUntilStarted()
    model.didSave(reader: try await Archive.open(at: zip))
    again.release()

    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(model.reader?.nameEncoding == .automatic)
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)
}

/// A rename or a New Folder made while the reopen reads the file is an edit like any other (it is in
/// `changes`: `renamedPaths`, the staged folder's addition), so the reopen drops it and the edit stays.
@MainActor @Test func reopenAppliesNothingAfterARenameOrNewFolderMeanwhile() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp1251)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
    let undoManager = UndoManager()
    let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: undoManager)
    defer { model.removeTemporaryFiles() }
    model.nameEncodingStore = test.store
    let held = HeldOpen()

    let reopen = Task { try await model.reopen(nameEncoding: .specific(cp866), open: held.open) }
    await held.waitUntilStarted()
    #expect(model.rename("Docs", to: "Papers") == .success("Papers"))
    held.release()

    await #expect(throws: CancellationError.self) { try await reopen.value }
    #expect(model.reader?.nameEncoding == .automatic)
    #expect(model.item(at: "Docs") == nil)
    #expect(model.item(at: "Papers/Отчёт.txt") != nil)
    #expect(!model.changes.renamedPaths.isEmpty)
    #expect(undoManager.canUndo)
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)

    undoManager.undo()
    #expect(!model.hasChanges)
    let again = HeldOpen()
    let second = Task { try await model.reopen(nameEncoding: .specific(cp866), open: again.open) }
    await again.waitUntilStarted()
    let folder = try model.newFolder(in: "")
    again.release()

    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(model.reader?.nameEncoding == .automatic)
    #expect(model.item(at: folder)?.isPendingAddition == true)
    #expect(model.item(at: "Папка/Отчёт за май.txt") != nil)
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)
}

/// Cancelled while it reads (the progress sheet's Cancel, or the document closing): nothing changes.
@MainActor @Test func cancelledReopenAppliesNothing() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let zip = try LegacyZip.write(cyrillicPaths, as: cp1251)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
    let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: nil)
    model.nameEncodingStore = test.store
    let held = HeldOpen()

    let reopen = Task { try await model.reopen(nameEncoding: .specific(cp866), open: held.open) }
    await held.waitUntilStarted()
    reopen.cancel()
    held.release()

    await #expect(throws: (any Error).self) { try await reopen.value }
    #expect(model.reader?.nameEncoding == .automatic)
    #expect(model.item(at: "Папка/Отчёт за май.txt") != nil)
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)
}

@MainActor @Test func reopenWithoutAFileDoesNothing() async throws {
    let test = TestStore()
    defer { test.cleanUp() }
    let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
    model.nameEncodingStore = test.store

    try await model.reopen(nameEncoding: .specific(cp866))

    #expect(model.reader == nil)
    #expect(test.defaults.object(forKey: ArchiveNameEncodingStore.defaultsKey) == nil)
}
