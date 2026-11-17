import Foundation
import Testing
import KernirCore
@testable import Kernir

/// `DocumentSession`'s Mac metadata choice: what a plain save
/// writes with before and after the user answers, added files included, and what is remembered for the file. Each case expects
/// concrete options. No document or engine seam: runs in parallel, and the same file runs in a
/// macOS SwiftPM mirror (App/Shared + the UIKit-free iOS document files). `ArchiveDocument`'s wiring of it
/// is `KeepMacMetadataTests` (hosted).
@MainActor struct DocumentSessionMacMetadataTests {
    private static func entry(_ path: String, isDirectory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: isDirectory, size: isDirectory ? nil : 1,
                     compressedSize: isDirectory ? nil : 1, modificationDate: nil)
    }

    /// As Finder zips a folder: the files plus a `__MACOSX` tree of `._*` companions.
    private static let finderEntries = FakeReader.sample().entries + [
        entry("__MACOSX", isDirectory: true),
        entry("__MACOSX/._README.md"),
    ]

    /// Only Finder view state: no `__MACOSX`, no `._*`.
    private static let dsStoreOnlyEntries = FakeReader.sample().entries + [
        entry(".DS_Store"),
        entry("src/.DS_Store"),
    ]

    /// A session with a ready model over `entries`, detected as a document does on open.
    private func openSession(_ entries: [ArchiveEntry]) -> (DocumentSession, ArchiveModel) {
        let session = DocumentSession()
        let model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
        session.phase = .ready(model)
        session.detectMacMetadata(in: model.reader)
        return (session, model)
    }

    /// A new archive (Part B): an empty listing and the options its sheet saved.
    private func newArchiveSession(excludes: Bool) -> (DocumentSession, ArchiveModel, ArchiveWriteOptions) {
        let (session, model) = openSession([])
        let saved = ArchiveWriteOptions(method: .deflate, encryption: .aes256, password: "kernir",
                                        excludesMacMetadata: excludes)
        model.apply(ArchiveSaveSettings(format: .zip, options: saved))
        return (session, model, saved)
    }

    // MARK: - Detection

    @Test func detectionFollowsTheReader() {
        let (session, _) = openSession(Self.finderEntries)
        #expect(session.sourceHasMacMetadata)
        // The reader after a save that removed it (or a revert to a clean file).
        session.detectMacMetadata(in: FakeReader.sample())
        #expect(!session.sourceHasMacMetadata)
        session.detectMacMetadata(in: FakeReader(entries: Self.finderEntries))
        #expect(session.sourceHasMacMetadata)
        session.detectMacMetadata(in: nil)
        #expect(!session.sourceHasMacMetadata)
    }

    /// Q-c4: `.DS_Store` alone is not Mac metadata to ask about.
    @Test func dsStoreOnlyIsNotDetected() {
        let (session, _) = openSession(Self.dsStoreOnlyEntries)
        #expect(!session.sourceHasMacMetadata)
    }

    // MARK: - Unanswered (Q-c3)

    /// Unanswered, the source holds Mac metadata: a save that can't ask (close, background) keeps it:
    /// nil options, nothing stripped, whatever the app's default.
    @Test(arguments: [false, true]) func unansweredSourceWithMacMetadataKeeps(_ defaultExcludes: Bool) {
        let (session, model) = openSession(Self.finderEntries)
        #expect(session.macMetadataChoice == nil)
        #expect(session.plainSaveChoice(for: model) == false)
        #expect(session.plainSaveOptions(for: model, default: defaultExcludes) == nil)
    }

    /// Unanswered, no Mac metadata in the source: the app's default, as before (c): strip on, so added
    /// metadata is left out; off, nil.
    @Test(arguments: [false, true]) func unansweredWithoutMetadataFollowsTheDefault(_ defaultExcludes: Bool) {
        let (session, model) = openSession(FakeReader.sample().entries)
        #expect(session.plainSaveChoice(for: model) == nil)
        #expect(session.plainSaveOptions(for: model, default: defaultExcludes)
            == (defaultExcludes ? ArchiveWriteOptions(excludesMacMetadata: true) : nil))
    }

    /// Q-c4: a `.DS_Store`-only archive asks nothing and follows the default, which strips its `.DS_Store`.
    @Test func dsStoreOnlyArchiveFollowsTheDefaultStrip() {
        let (session, model) = openSession(Self.dsStoreOnlyEntries)
        #expect(session.plainSaveChoice(for: model) == nil)
        #expect(session.plainSaveOptions(for: model, default: true) == ArchiveWriteOptions(excludesMacMetadata: true))
    }

    /// A new archive: its sheet's flag is the answer, even should its listing hold Mac metadata.
    @Test(arguments: [false, true]) func newArchiveFollowsItsCreationFlag(_ excludes: Bool) {
        let (session, model, saved) = newArchiveSession(excludes: excludes)
        session.sourceHasMacMetadata = true
        #expect(session.plainSaveChoice(for: model) == nil)
        for defaultExcludes in [false, true] {
            #expect(session.plainSaveOptions(for: model, default: defaultExcludes) == saved)
        }
    }

    // MARK: - Answered

    /// An answer beats the implicit keep: Remove strips with the source's settings; Keep writes nil.
    @Test func answerBeatsTheImplicitKeep() throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let (session, model) = openSession(Self.finderEntries)

        session.answerMacMetadataQuestion(strips: true, for: test.archive, in: test.store)
        #expect(session.macMetadataChoice == true)
        #expect(session.plainSaveOptions(for: model, default: false) == ArchiveWriteOptions(excludesMacMetadata: true))

        session.answerMacMetadataQuestion(strips: false, for: test.archive, in: test.store)
        #expect(session.macMetadataChoice == false)
        #expect(session.plainSaveOptions(for: model, default: true) == nil)
    }

    /// A remembered answer beats a new archive's creation flag; method, encryption and password stay.
    @Test(arguments: [false, true]) func answerOverridesTheCreationFlag(_ excludes: Bool) {
        let (session, model, saved) = newArchiveSession(excludes: excludes)
        session.adoptRememberedMacMetadataChoice(!excludes)
        var flipped = saved
        flipped.excludesMacMetadata = !excludes
        #expect(session.plainSaveOptions(for: model, default: excludes) == flipped)
    }

    /// The answer is remembered for the file, so it holds after the archive is closed and reopened.
    @Test(arguments: [false, true]) func answerIsRememberedForTheFile(_ strips: Bool) throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let (session, _) = openSession(Self.finderEntries)

        session.answerMacMetadataQuestion(strips: strips, for: test.archive, in: test.store)

        #expect(test.store.choice(for: test.archive) == strips)
        #expect(test.reloaded().choice(for: test.archive) == strips)
    }

    /// A remembered Remove is honored on saves that can't ask.
    @Test func rememberedRemoveIsHonored() {
        let (session, model) = openSession(Self.finderEntries)
        session.adoptRememberedMacMetadataChoice(true)
        #expect(session.plainSaveChoice(for: model) == true)
        #expect(session.plainSaveOptions(for: model, default: false) == ArchiveWriteOptions(excludesMacMetadata: true))
    }

    /// A read of the file that finds nothing remembered (the store rejected the record: another file has
    /// the path; or never kept it: no file ID) drops this session's Remove and keeps its Keep; one
    /// that finds an answer takes it. `MacMetadataRevertTests` has the reverts themselves.
    @Test func readKeepsAKeepAndDropsARemoveUnlessOneIsRemembered() throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let (session, model) = openSession(Self.finderEntries)
        session.answerMacMetadataQuestion(strips: true, for: test.archive, in: test.store)

        session.adoptMacMetadataChoice(readWithFile: true)
        #expect(session.macMetadataChoice == true)
        session.adoptMacMetadataChoice(readWithFile: nil)
        #expect(session.macMetadataChoice == nil)
        #expect(session.needsMacMetadataAnswer(for: model))

        session.answerMacMetadataQuestion(strips: false, for: test.archive, in: test.store)
        session.adoptMacMetadataChoice(readWithFile: nil)
        #expect(session.macMetadataChoice == false)
        session.adoptMacMetadataChoice(readWithFile: true)
        #expect(session.macMetadataChoice == true)
    }

    // MARK: - Added files (Q-c7)

    /// The Mac metadata `addedFinderZip(in:)` adds; `Added/notes.txt` is its ordinary file.
    private static let addedMetadata = ["Added/._notes.txt", "Added/__MACOSX/meta.txt"]

    /// The real engine on a copy of `Fixtures/zip/macos-finder.zip` (`__MACOSX` and `._*`), opened and
    /// detected as a document does, with additions from disk: a folder `Added` holding `notes.txt` and a
    /// `__MACOSX` folder, then `._notes.txt` added into it on its own (Foundation's folder walk never lists a
    /// nested `._*` file, `AdditionWalker`). The copy and the files live in `test.directory`.
    private func addedFinderZip(in test: ChoiceStoreFixture) async throws -> (DocumentSession, ArchiveModel) {
        let fixture = try Fixture.copy("zip/macos-finder.zip")
        let source = test.directory.appendingPathComponent("source.zip")
        try FileManager.default.copyItem(at: fixture, to: source)
        try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
        let added = test.directory.appendingPathComponent("Added", isDirectory: true)
        let loose = test.directory.appendingPathComponent("Loose", isDirectory: true)
        for folder in [added.appendingPathComponent("__MACOSX", isDirectory: true), loose] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let appleDouble = loose.appendingPathComponent("._notes.txt")
        for file in [added.appendingPathComponent("notes.txt"), added.appendingPathComponent("__MACOSX/meta.txt"),
                     appleDouble] {
            try Data(file.lastPathComponent.utf8).write(to: file)
        }
        let session = DocumentSession()
        let model = ArchiveModel(reader: try await Archive.open(at: source), undoManager: nil)
        session.phase = .ready(model)
        session.detectMacMetadata(in: model.reader)
        #expect(session.sourceHasMacMetadata)
        model.add([added], to: "")
        model.add([appleDouble], to: "Added")
        #expect(model.changes.additions.count == 2)
        return (session, model)
    }

    /// Writes `model` with `options` as a plain save does and lists the result.
    private func save(_ model: ArchiveModel, options: ArchiveWriteOptions?,
                      in test: ChoiceStoreFixture) async throws -> [String] {
        let saved = test.directory.appendingPathComponent("saved-\(UUID().uuidString).zip")
        try await ArchiveWriter.write(source: model.reader, changes: model.changes, format: model.format,
                                      to: saved, options: options)
        return try await Archive.open(at: saved).entries.map(\.path)
    }

    /// Q-c7 (a): until the Save answer, the whole-archive keep covers added files too. A save that can't
    /// ask (close, background) writes nil options even with the app's default on, so the added `._*` and
    /// `__MACOSX` stay next to the source's: no per-entry strip.
    @Test func unansweredKeepCoversAddedFiles() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let (session, model) = try await addedFinderZip(in: test)
        #expect(session.macMetadataChoice == nil)

        let options = session.plainSaveOptions(for: model, default: true)
        #expect(options == nil)

        let paths = try await save(model, options: options, in: test)
        #expect(paths.contains("Added/notes.txt"))
        for path in Self.addedMetadata { #expect(paths.contains(path), "\(path) kept") }
        #expect(paths.contains("__MACOSX/Project/docs/._readme.md"))
    }

    /// Q-c7 (b): after Remove, a plain save strips the added files' Mac metadata too, not only the source's.
    @Test func removeStripsAddedFilesToo() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let (session, model) = try await addedFinderZip(in: test)

        session.answerMacMetadataQuestion(strips: true, for: test.archive, in: test.store)
        let options = session.plainSaveOptions(for: model, default: false)
        // The source's settings (a Deflate zip), stripping.
        #expect(options == ArchiveWriteOptions(method: .deflate, excludesMacMetadata: true))

        let paths = try await save(model, options: options, in: test)
        #expect(paths.contains("Added/notes.txt"))
        #expect(paths.contains("Project/docs/readme.md"))
        for path in Self.addedMetadata { #expect(!paths.contains(path), "\(path) stripped") }
        #expect(!paths.contains { $0.contains("__MACOSX") || $0.split(separator: "/").contains { $0.hasPrefix("._") } })
    }

    // MARK: - After a save

    /// A safe save gives the file a new ID, the written file's (the swap keeps it): remembering again after
    /// it keeps a Remove matching, and remembers the answer the file has (a Keep stays a Keep).
    @Test(arguments: [false, true]) func rememberingAfterASaveFollowsTheNewFile(_ strips: Bool) throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let (session, _) = openSession(Self.finderEntries)
        session.answerMacMetadataQuestion(strips: strips, for: test.archive, in: test.store)
        let answeredFileID = test.store.fileID(of: test.archive)

        let savedFileID = try test.safeSave()
        #expect(savedFileID != nil && savedFileID != answeredFileID)
        #expect(test.store.fileID(of: test.archive) == savedFileID)
        session.rememberMacMetadataChoiceAfterSave(of: test.archive, savedFileID: savedFileID, in: test.store)

        #expect(session.macMetadataChoice == strips)
        #expect(test.reloaded().choice(for: test.archive) == strips)
    }

    /// iCloud or another app swaps in a file of its own after the save's swap, before the remember: a Remove
    /// isn't stored for that file (stripping it would delete entries unasked), and the session's goes,
    /// so the next save keeps the Mac metadata and the next Save asks. A Keep stays, and is remembered.
    @Test(arguments: [false, true]) func rememberingAfterAReplaceFromOutside(_ strips: Bool) throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let (session, model) = openSession(Self.finderEntries)
        session.answerMacMetadataQuestion(strips: strips, for: test.archive, in: test.store)
        let savedFileID = try test.safeSave()

        try test.safeSave()
        #expect(test.store.fileID(of: test.archive) != savedFileID)
        session.rememberMacMetadataChoiceAfterSave(of: test.archive, savedFileID: savedFileID, in: test.store)

        if strips {
            #expect(session.macMetadataChoice == nil)
            #expect(session.needsMacMetadataAnswer(for: model))
            #expect(session.plainSaveOptions(for: model, default: true) == nil)
            #expect(test.isEmpty)
        } else {
            #expect(session.macMetadataChoice == false)
            #expect(!session.needsMacMetadataAnswer(for: model))
            #expect(test.reloaded().choice(for: test.archive) == false)
        }
    }

    /// Unanswered, a save records nothing: the implicit keep is not an answer, so the next Save asks.
    @Test func implicitKeepIsNeverRemembered() throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let (session, model) = openSession(Self.finderEntries)
        #expect(session.plainSaveOptions(for: model, default: true) == nil)

        let savedFileID = try test.safeSave()
        session.rememberMacMetadataChoiceAfterSave(of: test.archive, savedFileID: savedFileID, in: test.store)

        #expect(test.isEmpty)
        #expect(test.store.choice(for: test.archive) == nil)
    }

    // MARK: - Save As Copy (Q-c5a)

    /// Save As Copy's existing "Exclude Mac metadata" toggle starts from the file's answer; unanswered,
    /// from `ArchiveSaveSettings(model:)` (the implicit keep is no answer, so the app's default applies).
    @Test(arguments: [false, true]) func saveAsCopyStartsFromTheAnswer(_ strips: Bool) {
        let (session, model) = openSession(Self.finderEntries)
        let unanswered = ArchiveSaveSettings(model: model)
        #expect(session.saveAsCopySettings(for: model) == unanswered)
        #expect(unanswered.options.excludesMacMetadata == ArchiveSaveSettings.excludesMacMetadataByDefault)

        session.adoptRememberedMacMetadataChoice(strips)
        var answered = unanswered
        answered.options.excludesMacMetadata = strips
        #expect(session.saveAsCopySettings(for: model) == answered)
    }

    /// The answer beats a new archive's creation flag in the copy's toggle too; the rest of its saved
    /// options (method, encryption, password) stay.
    @Test(arguments: [false, true]) func saveAsCopyAnswerOverridesTheCreationFlag(_ excludes: Bool) {
        let (session, model, saved) = newArchiveSession(excludes: excludes)
        let unanswered = ArchiveSaveSettings(model: model)
        #expect(session.saveAsCopySettings(for: model) == unanswered)
        #expect(unanswered.options.excludesMacMetadata == excludes)

        session.adoptRememberedMacMetadataChoice(!excludes)
        var flipped = unanswered
        flipped.options.excludesMacMetadata = !excludes
        #expect(session.saveAsCopySettings(for: model) == flipped)
        #expect(flipped.options.encryption == saved.encryption && flipped.options.password == saved.password)
    }
}

/// A choice store in defaults of its own (`makeTestDefaults`: the plist stays in the temporary folder)
/// and an archive file in a folder of its own. `cleanUp()` removes both.
struct ChoiceStoreFixture {
    let suiteName: String
    let defaults: UserDefaults
    let store: MacMetadataChoiceStore
    let directory: URL
    let archive: URL

    init() throws {
        (defaults, suiteName) = makeTestDefaults("DocumentSessionMacMetadataTests")
        store = MacMetadataChoiceStore(defaults: defaults)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentSessionMacMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        archive = directory.appendingPathComponent("finder.zip")
        try Data("zip".utf8).write(to: archive)
    }

    /// Another store on the same defaults, as after relaunching the app.
    func reloaded() -> MacMetadataChoiceStore {
        MacMetadataChoiceStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    var isEmpty: Bool { defaults.object(forKey: MacMetadataChoiceStore.defaultsKey) == nil }

    /// The paths the store keeps a record for, read from its defaults entry (JSON), in its spelling:
    /// standardized, symbolic links resolved.
    var recordedPaths: [String] {
        guard let data = defaults.data(forKey: MacMetadataChoiceStore.defaultsKey),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return records.compactMap { $0["path"] as? String }
    }

    /// `archive` as the store spells it.
    var archivePath: String { archive.standardizedFileURL.resolvingSymlinksInPath().path }

    /// A safe save, as UIDocument does: a new file swapped in (new file ID, same creation date). Returns
    /// the written file's ID, read before the swap, as `ArchiveDocument.writeContents` reads it.
    @discardableResult
    func safeSave() throws -> UInt64? {
        let written = directory.appendingPathComponent("written-\(UUID().uuidString).zip")
        try Data("saved".utf8).write(to: written)
        let writtenFileID = store.fileID(of: written)
        _ = try FileManager.default.replaceItemAt(archive, withItemAt: written)
        return writtenFileID
    }

    func cleanUp() {
        removeTestDefaults(defaults, suite: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
