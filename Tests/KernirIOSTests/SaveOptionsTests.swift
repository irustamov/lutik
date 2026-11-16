import Foundation
import Testing
import KernirCore
@testable import Kernir

/// The save options form (layout and confirm rule), new archives and Save As Copy.
/// Serialized: `ArchiveDocument.engine` is a process-wide test seam.
@MainActor @Suite(.serialized) final class SaveOptionsTests {
    /// Files and folders a test made; removed after it.
    private var cleanup: [URL] = []

    deinit {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
    }

    private func settings(_ format: ArchiveFormat) -> ArchiveSaveSettings {
        var settings = ArchiveSaveSettings(format: format, options: ArchiveWriteOptions())
        settings.formatDidChange()
        return settings
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveOptionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cleanup.append(folder)
        return folder
    }

    /// Opens a copy of `fixture` through `fake`, ready; the copy is called `name` when one is given,
    /// and it is unlocked with `password` when given.
    private func open(_ fixture: String = "zip/deflate.zip", as name: String? = nil,
                      fake: FakeEngine, password: String? = nil) async throws -> ScreenState {
        let url = try Fixture.copy(fixture, as: name)
        cleanup.append(url.deletingLastPathComponent())
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        if let password { await document.unlock(password: password, remember: false) }
        #expect(document.session.model != nil)
        return ScreenState(document: document)
    }

    /// Waits for UIDocument to count the last edit (the undo group closes at the end of the turn).
    private func waitForUnsavedChanges(_ document: ArchiveDocument) async throws {
        for _ in 0..<100 where !document.hasUnsavedChanges {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(document.hasUnsavedChanges)
    }

    // MARK: - Layout

    @Test func zipShowsLevelEncryptionAndMethods() {
        let zip = ArchiveFormat.zip
        let computed: [SaveOptionsLayout.Section] = [
            .format,
            .level(try! #require(zip.compressionLevelRange)),
            .encryption(zip.supportedEncryptions),
            .metadata,
            .advanced(methods: zip.supportedMethods, solid: zip.supportsSolid),
        ]
        let sections = SaveOptionsLayout.sections(for: settings(.zip))
        #expect(sections == computed)
        // The announced values (KernirCore lists the default method first: Deflate, then Store).
        #expect(sections == [
            .format,
            .level(0...9),
            .encryption([.none, .aes256, .aes128, .zipCrypto]),
            .metadata,
            .advanced(methods: [.deflate, .store], solid: false),
        ])
    }

    @Test func tarHasNoLevelNoEncryptionSection() {
        #expect(ArchiveFormat.tar.compressionLevelRange == nil)
        #expect(ArchiveFormat.tar.supportedEncryptions == [.none])
        #expect(SaveOptionsLayout.sections(for: settings(.tar)) == [.format, .metadata])
    }

    /// Every writable format has the "Exclude Mac metadata" section, once, after encryption
    /// and before Advanced (the Mac's order). Both sheets use this layout.
    @Test(arguments: ArchiveFormat.writable)
    func metadataSectionForEveryWritableFormat(format: ArchiveFormat) throws {
        let sections = SaveOptionsLayout.sections(for: settings(format))
        #expect(sections.filter { $0 == .metadata }.count == 1)
        let metadata = try #require(sections.firstIndex(of: .metadata))
        let encryption = sections.firstIndex { if case .encryption = $0 { true } else { false } }
        let advanced = sections.firstIndex { if case .advanced = $0 { true } else { false } }
        if let encryption { #expect(encryption < metadata) }
        if let advanced { #expect(metadata < advanced) }
        #expect(Set(sections.map(\.kind)).count == sections.count, "kinds stay unique")
    }

    /// The row's label and footer are the Mac's, from the "Shared" table.
    @Test func metadataRowUsesMacStrings() {
        #expect(SaveOptionsLayout.metadataLabel == "Exclude Mac metadata (.DS_Store, __MACOSX, ._ files)")
        #expect(SaveOptionsLayout.metadataFooter == "Resource forks and extended attributes are never stored.")
    }

    /// The toggle keeps its value whatever format the sheet's picker moves to, and back.
    @Test(arguments: [true, false])
    func metadataToggleSurvivesFormatChange(excludes: Bool) {
        for start in ArchiveFormat.writable {
            var settings = settings(start)
            settings.options.excludesMacMetadata = excludes
            for format in ArchiveFormat.writable + [start] {
                SaveOptionsLayout.choose(format, in: &settings)
                #expect(settings.format == format)
                #expect(settings.options.excludesMacMetadata == excludes, "\(start) -> \(format)")
                #expect(SaveOptionsLayout.sections(for: settings).contains(.metadata))
            }
        }
    }

    @Test func sevenZipOffersOnlyAES256() {
        let sections = SaveOptionsLayout.sections(for: settings(.sevenZip))
        #expect(sections.contains(.encryption([.none, .aes256])))
        #expect(SaveOptionsLayout.encryptionChoices(for: .sevenZip) == [.aes256])
        #expect(SaveOptionsLayout.encryptionChoices(for: .zip) == [.aes256, .aes128, .zipCrypto])
    }

    @Test func weakEncryptionIsLabelled() {
        #expect(SaveOptionsLayout.encryptionName(.zipCrypto) == "ZipCrypto (compatible, weak)")
        #expect(SaveOptionsLayout.encryptionName(.aes256) == "AES-256")
    }

    @Test func levelNamesMatchMac() {
        #expect(SaveOptionsLayout.levelName(0, in: 0...9, format: .zip) == "Fastest (0)")
        #expect(SaveOptionsLayout.levelName(6, in: 0...9, format: .zip) == "Normal (6)")
        #expect(SaveOptionsLayout.levelName(9, in: 0...9, format: .zip) == "Best (9)")
        #expect(SaveOptionsLayout.levelName(3, in: 0...9, format: .zip) == "3")
    }

    @Test func saveAsCopyOffersOnlyWritableFormats() async throws {
        let state = try await open("third-party/rar/rar5-solid.rar",
                                   fake: FakeEngine(reader: { url in
                                       FakeReader(entries: FakeReader.sample().entries, format: .rar, url: url)
                                   }))
        #expect(state.canEdit == false)
        state.beginSaveAsCopy()
        let request = try #require(state.saveAsCopyRequest)
        #expect(request.settings.format == ArchiveFormat.writable.first)
        #expect(SaveOptionsLayout.formats == ArchiveFormat.writable)
        #expect(!SaveOptionsLayout.formats.contains(.rar))
        #expect(SaveOptionsSheet.canConfirm(request.settings))
        await state.document.closeOnMain()
    }

    @Test func confirmDisabledWhenProblems() {
        var settings = settings(.zip)
        #expect(SaveOptionsSheet.canConfirm(settings))
        settings.isEncrypting = true
        settings.options.password = "kernir"
        settings.verifyPassword = "kernit"
        #expect(settings.problems.contains(.passwordMismatch))
        #expect(SaveOptionsSheet.canConfirm(settings) == false)
        settings.verifyPassword = "kernir"
        #expect(SaveOptionsSheet.canConfirm(settings))
        settings.options.password = ""
        settings.verifyPassword = ""
        #expect(SaveOptionsSheet.canConfirm(settings) == false)
    }

    // MARK: - New archive

    @Test func newArchiveDefaultsToFirstWritableFormat() {
        let settings = NewArchiveFlow.defaultSettings()
        #expect(settings.format == ArchiveFormat.writable.first)
        #expect(settings.isEncrypting == false)
        #expect(settings.options.method == settings.format.defaultMethod)
        #expect(settings.options.compressionLevel == settings.format.defaultCompressionLevel)
    }

    /// New Archive starts with "Exclude Mac metadata" at the shared default (never a literal),
    /// and unsplit (`formatDidChange` synced `volumeSize`).
    @Test func newArchiveDefaultFollowsStatic() {
        let settings = NewArchiveFlow.defaultSettings()
        #expect(settings.options.excludesMacMetadata == ArchiveSaveSettings.excludesMacMetadataByDefault)
        #expect(settings.split == .none)
        #expect(settings.options.volumeSize == nil)
    }

    @Test func makeEmptyWritesExplicitOptions() async throws {
        let fake = FakeEngine()
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        var settings = settings(.zip)
        settings.isEncrypting = true
        settings.options.password = "kernir"
        settings.verifyPassword = "kernir"
        let url = try temporaryFolder().appendingPathComponent("Untitled.zip")

        try await ArchiveDocument.makeEmpty(at: url, settings: settings)

        let write = try #require(fake.writeCalls.first)
        #expect(fake.writeCalls.count == 1)
        #expect(write.url == url)
        #expect(write.format == .zip)
        #expect(write.changes == ArchiveChangeSet())
        #expect(write.options == settings.options)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Every writable format makes an empty archive the real engine opens again; an encrypted one
    /// opens with its password.
    @Test(arguments: ArchiveFormat.writable)
    func makeEmptyOpensWithLiveEngine(format: ArchiveFormat) async throws {
        ArchiveDocument.engine = .live
        var settings = settings(format)
        let folder = try temporaryFolder()
        let plain = folder.appendingPathComponent(ArchiveSaveSettings.fileName("Untitled", for: format))
        try await ArchiveDocument.makeEmpty(at: plain, settings: settings)
        #expect(try await Archive.open(at: plain).entries.isEmpty)

        guard format.supportedEncryptions.count > 1 else { return }
        settings.isEncrypting = true
        settings.options.password = "kernir"
        settings.verifyPassword = "kernir"
        let encrypted = folder.appendingPathComponent("Encrypted." + format.fileExtension)
        try await ArchiveDocument.makeEmpty(at: encrypted, settings: settings)
        #expect(try await Archive.open(at: encrypted, password: "kernir").entries.isEmpty)
    }

    /// The creation flow writes "Untitled.<ext>" to a temporary folder and remembers the settings
    /// under the URL UIKit moves the file to.
    @Test func createWritesUntitledAndRemembersSettings() async throws {
        let fake = FakeEngine()
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        let settings = settings(.sevenZip)
        let created = try await NewArchiveFlow.create(with: settings)
        cleanup.append(created.deletingLastPathComponent())
        #expect(created.lastPathComponent == "Untitled.7z")
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(ArchiveDocument.newArchiveSettings(for: created) == settings)

        let destination = try temporaryFolder().appendingPathComponent("Untitled 2.7z")
        try FileManager.default.moveItem(at: created, to: destination)
        NewArchiveFlow.didImport(from: created, to: destination)
        #expect(ArchiveDocument.newArchiveSettings(for: created) == nil)
        #expect(ArchiveDocument.newArchiveSettings(for: destination) == settings)
        #expect(!FileManager.default.fileExists(atPath: created.deletingLastPathComponent().path),
                "the empty temporary folder is removed")
        _ = ArchiveDocument.takeNewArchiveSettings(for: destination)
    }

    /// An empty archive carries no detectable encryption, so the first in-place save of
    /// a new encrypted archive must use the creation settings, not nil options.
    @Test func newEncryptedArchiveFirstSaveKeepsEncryption() async throws {
        let fake = FakeEngine(reader: { FakeReader(entries: [], url: $0) })
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        var settings = settings(.zip)
        settings.isEncrypting = true
        settings.options.password = "kernir"
        settings.verifyPassword = "kernir"
        let created = try await NewArchiveFlow.create(with: settings)
        cleanup.append(created.deletingLastPathComponent())
        let destination = try temporaryFolder().appendingPathComponent("Untitled.zip")
        try FileManager.default.moveItem(at: created, to: destination)
        NewArchiveFlow.didImport(from: created, to: destination)

        let document = ArchiveDocument(fileURL: destination)
        #expect(await document.openOnMain())
        let model = try #require(document.session.model)
        #expect(model.saveOptions == settings.options)
        #expect(model.password == "kernir")
        #expect(ArchiveDocument.newArchiveSettings(for: destination) == nil, "applied once, then forgotten")

        let file = try temporaryFolder().appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: file)
        model.add([file], to: "")
        try await waitForUnsavedChanges(document)
        #expect(await document.commitSave())

        let write = try #require(fake.writeCalls.last)
        #expect(fake.writeCalls.count == 2)
        #expect(write.format == .zip)
        #expect(write.options?.encryption == .aes256)
        #expect(write.options?.password == "kernir")
        await document.closeOnMain()
    }

    // MARK: - Save As Copy

    /// A copy's options, its password above all, never reach the open document: an encrypted
    /// source, so a leak into `model.password` or the in-place options would show. Whatever the
    /// app's "Exclude Mac metadata" default (forced both ways): the in-place save keeps the
    /// source's password.
    @Test(arguments: [false, true]) func saveAsCopyLeavesInPlaceSaveOptionsAlone(_ excludesByDefault: Bool) async throws {
        let fake = FakeEngine(password: "kernir", listsWithoutPassword: true)
        let state = try await open(fake: fake, password: "kernir")
        state.document.plainSaveDefaultExcludesMacMetadata = excludesByDefault
        let model = try #require(state.model)
        #expect(model.reader?.encryption == .aes256)
        model.remove(["README.md"])
        try await waitForUnsavedChanges(state.document)

        var settings = ArchiveSaveSettings(model: model)
        settings.format = .sevenZip
        settings.formatDidChange()
        settings.isEncrypting = true
        settings.options.password = "copy-secret"
        settings.verifyPassword = "copy-secret"
        let copy = try await state.saveAsCopy(settings)
        cleanup.append(copy.deletingLastPathComponent())

        // A 7z written with .aes256 asks for the password on open; the options say so.
        let write = try #require(fake.writeCalls.last)
        #expect(write.format == .sevenZip)
        #expect(write.options?.encryption == .aes256)
        #expect(write.options?.password == "copy-secret")
        #expect(write.changes.removedPaths == ["README.md"], "pending edits go into the copy")
        #expect(write.url == copy)
        #expect(copy.lastPathComponent == "deflate copy.7z")
        #expect(FileManager.default.fileExists(atPath: copy.path))

        // The open document is untouched: same format and password, edits pending, no save options.
        #expect(model.saveOptions == nil)
        #expect(model.password == "kernir")
        #expect(model.format == .zip)
        #expect(model.hasChanges)
        #expect(state.document.hasUnsavedChanges)

        // The in-place save writes the plain-save options, none of the copy's: default on, the
        // source's encryption with its own password, stripping; default off, nil.
        #expect(await state.document.commitSave())
        let inPlace = try #require(fake.writeCalls.last)
        #expect(fake.writeCalls.count == 2)
        #expect(inPlace.format == .zip)
        #expect(inPlace.options == (excludesByDefault
            ? ArchiveWriteOptions(encryption: .aes256, password: "kernir", excludesMacMetadata: true) : nil))
        #expect(fake.openCalls.last?.password == "kernir", "the reopen after the save")
        await state.document.closeOnMain()
    }

    /// Save As Copy starts from `ArchiveSaveSettings(model:)`, so "Exclude Mac metadata"
    /// follows the shared default, and the copy is written with it.
    @Test func saveAsCopyDefaultFollowsStatic() async throws {
        let fake = FakeEngine()
        let state = try await open(fake: fake)
        state.beginSaveAsCopy()
        let request = try #require(state.saveAsCopyRequest)
        #expect(request.settings.options.excludesMacMetadata == ArchiveSaveSettings.excludesMacMetadataByDefault)
        #expect(SaveOptionsLayout.sections(for: request.settings).contains(.metadata))

        state.confirmSaveAsCopy(request.settings)
        await state.saveOptionsSheetDidDismiss()
        let write = try #require(fake.writeCalls.last)
        #expect(write.options?.excludesMacMetadata == ArchiveSaveSettings.excludesMacMetadataByDefault)
        let copy = try #require(state.movingCopy)
        cleanup.append(copy.deletingLastPathComponent())
        state.copyMoveDidFinish()
        #expect(state.model?.saveOptions == nil, "the open document keeps nil options")
        await state.document.closeOnMain()
    }

    @Test func copyNameReplacesExtension() async throws {
        let state = try await open(fake: FakeEngine())
        #expect(state.copyName(for: .zip) == "deflate copy.zip")
        #expect(state.copyName(for: .tarGzip) == "deflate copy.tar.gz")
        await state.document.closeOnMain()
    }

    /// A set whose stem is dot-only ("...7z.001" is the set ".."): the copy is named after the
    /// part's own file name, as the dot-only stem falls back to it.
    @Test func copyNameOfADotOnlySetUsesTheFileName() async throws {
        let state = try await open("multivolume/s7.7z.001", as: "...7z.001", fake: FakeEngine(volumeCount: 2))
        #expect(state.copyName(for: .sevenZip) == "...7z.001 copy.7z")
        #expect(state.copyName(for: .zip) == "...7z.001 copy.zip")
        await state.document.closeOnMain()
    }

    /// Save As Copy of a split archive writes one archive, named after the set, into the scratch
    /// folder; the system's file mover then places it. Nothing is written over a part.
    @Test func copyOfASetIsOneArchiveNamedAfterTheSet() async throws {
        let fake = FakeEngine(volumeCount: 2)
        let state = try await open("multivolume/s7.7z.001", fake: fake)
        #expect(state.copyName(for: .sevenZip) == "s7 copy.7z")
        #expect(state.copyName(for: .zip) == "s7 copy.zip")
        let copy = try await state.saveAsCopy(settings(.zip))
        cleanup.append(copy.deletingLastPathComponent())
        #expect(copy.lastPathComponent == "s7 copy.zip")
        #expect(fake.writeCalls.map(\.url) == [copy])
        let parts = try #require(state.document.session.model?.reader?.volumeURLs)
        #expect(parts.count == 2)
        #expect(!parts.contains(copy))
        await state.document.closeOnMain()
    }

    /// Save on the sheet: the write starts once the sheet has gone, and the file mover gets the
    /// copy once the progress sheet has gone.
    @Test func confirmedCopyGoesToFileMover() async throws {
        let fake = FakeEngine()
        let state = try await open(fake: fake)
        state.beginSaveAsCopy()
        let request = try #require(state.saveAsCopyRequest)
        state.confirmSaveAsCopy(request.settings)
        #expect(state.saveAsCopyRequest == nil)
        #expect(fake.writeCalls.isEmpty, "nothing is written while the options sheet goes away")

        await state.saveOptionsSheetDidDismiss()
        #expect(fake.writeCalls.count == 1)
        let copy = try #require(state.movingCopy)
        #expect(copy.lastPathComponent == "deflate copy.zip")
        #expect(FileManager.default.fileExists(atPath: copy.path))

        state.copyMoveDidFinish()
        #expect(state.movingCopy == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path),
                "the temporary copy goes once the file mover is done")
        #expect(state.model?.saveOptions == nil)
        await state.document.closeOnMain()
    }

    @Test func cancelledOptionsWriteNothing() async throws {
        let fake = FakeEngine()
        let state = try await open(fake: fake)
        state.beginSaveAsCopy()
        state.cancelSaveAsCopy()
        #expect(state.saveAsCopyRequest == nil)
        await state.saveOptionsSheetDidDismiss()
        #expect(fake.writeCalls.isEmpty)
        #expect(state.movingCopy == nil)
        await state.document.closeOnMain()
    }

    /// A failed write shows the error alert, leaves the document and its file as they were and
    /// leaves no temporary copy behind.
    @Test func failedCopyShowsAlertAndKeepsDocument() async throws {
        let fake = FakeEngine(writeError: .io("disk full"))
        let state = try await open(fake: fake)
        let model = try #require(state.model)
        model.remove(["README.md"])
        try await waitForUnsavedChanges(state.document)
        let original = try Data(contentsOf: state.document.fileURL)

        state.beginSaveAsCopy()
        state.confirmSaveAsCopy(try #require(state.saveAsCopyRequest).settings)
        await state.saveOptionsSheetDidDismiss()

        #expect(state.movingCopy == nil)
        #expect(state.presentedAlert?.title == "Couldn't save a copy of “deflate”")
        #expect(model.hasChanges)
        #expect(model.saveOptions == nil)
        #expect(try Data(contentsOf: state.document.fileURL) == original)
        let write = try #require(fake.writeCalls.last)
        #expect(!FileManager.default.fileExists(atPath: write.url.deletingLastPathComponent().path))
        await state.document.closeOnMain()
    }

    @Test func saveAsCopyUnavailableWhileSaving() async throws {
        let fake = FakeEngine(writeDelay: .milliseconds(300))
        let state = try await open(fake: fake)
        let model = try #require(state.model)
        model.remove(["README.md"])
        try await waitForUnsavedChanges(state.document)
        let saving = Task { await state.document.commitSave() }
        for _ in 0..<100 where !state.isSaving { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.canSaveAsCopy == false)
        #expect(await saving.value)
        #expect(state.canSaveAsCopy)
        await state.document.closeOnMain()
    }

    /// A new encrypted archive keeps its creation options on every plain save, its "Exclude Mac
    /// metadata" choice included, either way, whatever the app's default (Part B: on): an empty
    /// archive has no detectable encryption, so only those options keep it encrypted.
    @Test(arguments: [false, true]) func newEncryptedArchiveKeepsItsCreationOptions(_ excludes: Bool) async throws {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault, "Part B: iOS default on")
        let fake = FakeEngine(reader: { FakeReader(entries: [], url: $0) })
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        var settings = NewArchiveFlow.defaultSettings()
        settings.format = .zip
        settings.formatDidChange()
        settings.isEncrypting = true
        settings.options.password = "kernir"
        settings.verifyPassword = "kernir"
        settings.options.excludesMacMetadata = excludes
        let created = try await NewArchiveFlow.create(with: settings)
        cleanup.append(created.deletingLastPathComponent())
        #expect(fake.writeCalls.last?.options == settings.options, "the empty archive")
        let destination = try temporaryFolder().appendingPathComponent("Untitled.zip")
        try FileManager.default.moveItem(at: created, to: destination)
        NewArchiveFlow.didImport(from: created, to: destination)

        let document = ArchiveDocument(fileURL: destination)
        #expect(await document.openOnMain())
        let model = try #require(document.session.model)
        #expect(model.saveOptions == settings.options)
        let folder = try temporaryFolder()
        for name in ["a.txt", "b.txt"] {
            let file = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            model.add([file], to: "")
            try await waitForUnsavedChanges(document)
            #expect(await document.commitSave())
            let write = try #require(fake.writeCalls.last)
            #expect(write.format == .zip)
            #expect(write.options == settings.options)
            #expect(write.options?.excludesMacMetadata == excludes)
        }
        #expect(fake.writeCalls.count == 3)
        await document.closeOnMain()
    }

}
