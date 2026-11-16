import Testing
import AppKit
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore
import os

// MARK: - Fake engine

/// Scripted `ArchiveEngine` built on `FakeReader`. `open` answers from `behavior`, which a
/// test may change between calls (e.g. after the first read reports a locked archive).
/// `write` answers from `writeBehavior` and records every call in `writes`.
private final class FakeEngine: Sendable {
    enum Behavior: Sendable {
        case succeed
        case fail(ArchiveError)
        /// Encrypted headers: no password → `.passwordRequired`, wrong one → `.wrongPassword`.
        case requirePassword(String, encryption: ArchiveEncryption = .aes256)
        /// Like the real core with an encrypted ZIP: opens without a password (`isEncrypted`),
        /// checks one when given (wrong → `.wrongPassword`).
        case encryptedZip(String)
        /// A non-ZIP archive with encrypted data that still opens without a password (RAR).
        case encryptedReadOnly(ArchiveFormat)
        /// A 7z that is the first of a multi-volume set (two parts).
        case volumeSet
        /// A split archive the engine refuses to read whole.
        case failVolume(ArchiveVolumeError)
        /// Like the real core with a data-encrypted 7z: opens without a password (`isEncrypted`),
        /// checks one when given (wrong → `.wrongPassword`). Once written, it needs one to open:
        /// Kernir always encrypts the 7z header.
        case encrypted7z(String)
        /// A 7z whose every open reports `.wrongPassword` (damage in the first encrypted file).
        case alwaysWrongPassword
    }

    enum WriteBehavior: Sendable {
        /// Writes a placeholder file in the requested format.
        case succeed
        /// Scribbles over the destination, then throws: a writer that fails midway.
        case fail(ArchiveError)
        /// Runs until its task is cancelled, then throws `.cancelled`, like the real writer.
        case runUntilCancelled
    }

    struct WriteCall: Sendable {
        let source: (any ArchiveReading)?
        let changes: ArchiveChangeSet
        let format: ArchiveFormat
        let url: URL
        let options: ArchiveWriteOptions?
    }

    private struct State {
        var behavior: Behavior
        var writeBehavior: WriteBehavior
        var writes: [WriteCall] = []
        var opens = 0
        /// What the file on disk now holds: the format of the last successful write.
        var writtenFormat: ArchiveFormat?
        /// When set, every open waits here first.
        var gate: Gate?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ behavior: Behavior, write writeBehavior: WriteBehavior = .succeed) {
        state = OSAllocatedUnfairLock(initialState: State(behavior: behavior, writeBehavior: writeBehavior))
    }

    var behavior: Behavior {
        get { state.withLock { $0.behavior } }
        set { state.withLock { $0.behavior = newValue } }
    }

    var writes: [WriteCall] { state.withLock { $0.writes } }
    /// How many times `open` ran.
    var opens: Int { state.withLock { $0.opens } }

    /// Holds every open (before it counts in `opens`) until the test opens the gate, so a test can
    /// act while an open is in flight without depending on timing.
    var gate: Gate? {
        get { state.withLock { $0.gate } }
        set { state.withLock { $0.gate = newValue } }
    }

    func open(_ url: URL, password: String?) throws -> any ArchiveReading {
        let format = state.withLock { state in
            state.opens += 1
            return state.writtenFormat
        } ?? .zip
        switch behavior {
        case .succeed:
            return FakeReader(entries: SampleArchive().entries, format: format, url: url)
        case .fail(let error):
            throw error
        case .requirePassword(let expected, let encryption):
            guard let password else { throw ArchiveError.passwordRequired }
            guard password == expected else { throw ArchiveError.wrongPassword }
            return FakeReader(entries: SampleArchive().entries, format: format, url: url, isEncrypted: true,
                              encryption: encryption)
        case .encryptedZip(let expected):
            // The core skips verification for an empty password.
            if let password, !password.isEmpty, password != expected { throw ArchiveError.wrongPassword }
            return FakeReader(entries: SampleArchive().entries, format: .zip, url: url, isEncrypted: true)
        case .volumeSet:
            let second = url.deletingLastPathComponent().appendingPathComponent("part.002")
            return FakeReader(entries: SampleArchive().entries, format: .sevenZip, url: url,
                              volumeURLs: [url, second])
        case .failVolume(let error):
            throw error
        case .encryptedReadOnly(let format):
            return FakeReader(entries: SampleArchive().entries, format: format, url: url, isEncrypted: true)
        case .encrypted7z(let expected):
            if password == nil, state.withLock({ $0.writtenFormat }) != nil { throw ArchiveError.passwordRequired }
            if let password, !password.isEmpty, password != expected { throw ArchiveError.wrongPassword }
            return FakeReader(entries: SampleArchive().entries, format: .sevenZip, url: url, isEncrypted: true,
                              encryption: .aes256)
        case .alwaysWrongPassword:
            guard password != nil else { throw ArchiveError.passwordRequired }
            throw ArchiveError.wrongPassword
        }
    }

    func write(_ call: WriteCall) async throws {
        let behavior = state.withLock { state in
            state.writes.append(call)
            return state.writeBehavior
        }
        switch behavior {
        case .succeed:
            try Data("written \(call.format.rawValue)".utf8).write(to: call.url)
            state.withLock { $0.writtenFormat = call.format }
        case .fail(let error):
            try? Data("partial".utf8).write(to: call.url)
            throw error
        case .runUntilCancelled:
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            throw ArchiveError.cancelled
        }
    }

    var engine: ArchiveEngine {
        ArchiveEngine(
            open: { url, password in
                await self.gate?.pass()
                return try self.open(url, password: password)
            },
            write: { source, changes, format, url, options, progress in
                try await self.write(WriteCall(source: source, changes: changes, format: format, url: url,
                                         options: options))
                progress?(1, nil)
            }
        )
    }
}

/// Blocks whoever calls `pass()` until the test calls `open()`; counts the callers.
private final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var arrivals = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many callers reached the gate (waiting or passed).
    var arrivals: Int { state.withLock { $0.arrivals } }

    func pass() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                state.arrivals += 1
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// `-[NSDocumentController makeDocumentWithContentsOfURL:ofType:error:]` without the SDK's
/// main-actor annotation, so a test can call it from a background thread like AppKit does.
@objc private protocol BackgroundDocumentMaking {
    @objc(makeDocumentWithContentsOfURL:ofType:error:)
    func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument
}

// MARK: - Tests

/// Serialized: the tests swap the process-wide `ArchiveDocument.engine`.
@Suite(.serialized) @MainActor
struct ArchiveDocumentTests {
    /// A real 4-byte file so the document can read its on-disk size; the caller removes it.
    private func makeArchiveFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).zip")
        try Data("PK\u{3}\u{4}".utf8).write(to: url)
        return url
    }

    /// NSDocument isn't Sendable, but NSDocumentController hands it to a background thread
    /// for concurrent reads; this test does the same.
    private struct UncheckedDocument: @unchecked Sendable {
        let document: ArchiveDocument
    }

    /// Reads off the main thread, like a concurrent NSDocumentController read.
    private nonisolated static func readDetached(_ box: UncheckedDocument, from url: URL) async throws {
        try await Task.detached {
            try box.document.read(from: url, ofType: "public.zip-archive")
        }.value
    }

    private struct UncheckedController: @unchecked Sendable {
        let controller: NSDocumentController
    }

    /// Makes a document on a background thread through NSDocumentController, the way its
    /// concurrent open does (it never registers the document or adds it to Open Recent).
    private static func makeDetached(from url: URL) async throws -> UncheckedDocument {
        let box = UncheckedController(controller: NSDocumentController.shared)
        return try await Task.detached {
            // The SDK marks this main-actor, but AppKit calls it off the main thread itself.
            let maker = unsafeBitCast(box.controller, to: BackgroundDocumentMaking.self)
            let document = try maker.makeDocument(withContentsOf: url, ofType: "public.zip-archive")
            return UncheckedDocument(document: try #require(document as? ArchiveDocument))
        }.value
    }

    /// Runs `body` with `fake` installed, then restores the live engine.
    private func withEngine<T>(_ fake: FakeEngine, _ body: () async throws -> T) async rethrows -> T {
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        return try await body()
    }

    @Test func readBuildsModel() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            #expect(document.model?.itemCount == 7)
            #expect(document.model?.format == .zip)
            #expect(document.state.isLocked == false)
            #expect(document.state.fileSize == 4)
        }
    }

    @Test func passwordRequiredOpensLocked() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.fail(.passwordRequired))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            #expect(document.state.isLocked == true)
            #expect(document.model == nil)

            fake.behavior = .succeed
            try await document.unlock(password: "x")
            #expect(document.state.isLocked == false)
            #expect(document.state.passwordError == nil)
            #expect(document.model?.itemCount == 7)
        }
    }

    @Test func wrongPasswordKeepsLockedWithMessage() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.requirePassword("right"))) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            #expect(document.state.isLocked == true)

            try await document.unlock(password: "wrong")
            #expect(document.state.isLocked == true)
            #expect(document.state.passwordError != nil)
            #expect(document.model == nil)

            // The user can try again.
            try await document.unlock(password: "right")
            #expect(document.state.isLocked == false)
            #expect(document.state.passwordError == nil)
            #expect(document.model?.itemCount == 7)
        }
    }

    /// Runs `body` with remembered passwords in a test-only Keychain service, then restores it.
    private func withKeychainService<T>(_ body: (String) async throws -> T) async rethrows -> T {
        let service = "com.kernir.app.tests.document-password"
        ArchiveDocument.keychainService = service
        defer { ArchiveDocument.keychainService = KeychainPasswordStore.service }
        return try await body(service)
    }

    @Test func encryptedZipWithoutPasswordOpensLocked() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encryptedZip("pw"))) {
            try await withKeychainService { _ in
                let document = ArchiveDocument()
                try document.read(from: url, ofType: "public.zip-archive")
                #expect(document.state.isLocked == true)
                #expect(document.state.passwordError == nil)
                #expect(document.model == nil)

                try await document.unlock(password: "pw")
                #expect(document.state.isLocked == false)
                #expect(document.model?.password == "pw")
            }
        }
    }

    @Test func encryptedZipOpensWithRememberedPassword() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encryptedZip("pw"))) {
            try await withKeychainService { service in
                KeychainPasswordStore.save("pw", for: url, service: service)
                defer { KeychainPasswordStore.remove(for: url, service: service) }
                let document = ArchiveDocument()
                try document.read(from: url, ofType: "public.zip-archive")
                #expect(document.state.isLocked == false)
                #expect(document.model?.password == "pw")
                #expect(document.model?.itemCount == 7)
                #expect(KeychainPasswordStore.password(for: url, service: service) == "pw")
            }
        }
    }

    @Test func encryptedZipWithStaleRememberedPasswordOpensLocked() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encryptedZip("pw"))) {
            try await withKeychainService { service in
                KeychainPasswordStore.save("old", for: url, service: service)
                defer { KeychainPasswordStore.remove(for: url, service: service) }
                let document = ArchiveDocument()
                try document.read(from: url, ofType: "public.zip-archive")
                #expect(document.state.isLocked == true)
                #expect(document.model == nil)
            }
        }
    }

    /// A remembered password that no longer opens the archive is forgotten, so it isn't tried
    /// on every open; the window asks instead.
    @Test func wrongRememberedPasswordIsRemovedFromTheKeychain() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        for behavior in [FakeEngine.Behavior.encryptedZip("pw"), .requirePassword("pw")] {
            try await withEngine(FakeEngine(behavior)) {
                try await withKeychainService { service in
                    KeychainPasswordStore.save("old", for: url, service: service)
                    defer { KeychainPasswordStore.remove(for: url, service: service) }
                    let document = ArchiveDocument()
                    try document.read(from: url, ofType: "public.zip-archive")
                    #expect(document.state.isLocked == true)
                    #expect(KeychainPasswordStore.password(for: url, service: service) == nil)
                }
            }
        }
    }

    /// For RAR the encryption can't be decrypted, so the archive opens read-only
    /// and never asks the Keychain.
    @Test func encryptedRarOpensUnlockedWithoutKeychainLookup() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encryptedReadOnly(.rar))) {
            try await withKeychainService { service in
                KeychainPasswordStore.save("pw", for: url, service: service)
                defer { KeychainPasswordStore.remove(for: url, service: service) }
                let document = ArchiveDocument()
                try document.read(from: url, ofType: "com.rarlab.rar-archive")
                #expect(document.state.isLocked == false)
                #expect(document.state.passwordError == nil)
                #expect(document.model?.itemCount == 7)
                // A lookup would have installed the saved password.
                #expect(document.model?.password == nil)
            }
        }
    }

    @Test func encryptedSevenZipOpensLocked() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encrypted7z("pw"))) {
            try await withKeychainService { service in
                defer { KeychainPasswordStore.remove(for: url, service: service) }
                let document = ArchiveDocument()
                try document.read(from: url, ofType: "org.7-zip.7-zip-archive")
                #expect(document.state.isLocked == true)
                #expect(document.model == nil)

                // A remembered password unlocks it on open.
                KeychainPasswordStore.save("pw", for: url, service: service)
                let remembered = ArchiveDocument()
                try remembered.read(from: url, ofType: "org.7-zip.7-zip-archive")
                #expect(remembered.state.isLocked == false)
                #expect(remembered.model?.password == "pw")
            }
        }
    }

    @Test func encryptedSevenZipUnlockChecksThePassword() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encrypted7z("pw"))) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "org.7-zip.7-zip-archive")

            try await document.unlock(password: "nope")
            #expect(document.state.isLocked == true)
            #expect(document.state.passwordError != nil)
            try await document.unlock(password: "")
            #expect(document.state.isLocked == true)
            #expect(document.model == nil)

            try await document.unlock(password: "pw")
            #expect(document.state.isLocked == false)
            #expect(document.state.passwordError == nil)
            #expect(document.model?.password == "pw")
        }
    }

    /// An unlocked encrypted 7z is editable: ⌘S writes 7z AES with its password.
    @Test func unlockedEncryptedSevenZipIsEditable() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encrypted7z("pw"))) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "org.7-zip.7-zip-archive")
            try await document.unlock(password: "pw")
            let actions = ArchiveActions(document: document)
            #expect(document.model?.isEditable == true)
            #expect(actions.canAdd)
            document.state.selection = ["src"]
            #expect(actions.canRemoveSelection)
            #expect(actions.canExtract)
        }
    }

    /// A plain ⌘S of a data-only encrypted 7z comes back header-encrypted, so the reopen after
    /// the save needs the password: the document keeps listing, with its password.
    @Test func savedEncryptedSevenZipKeepsItsPassword() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let added = try makeFileToAdd()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: added)
            }
            let fake = FakeEngine(.encrypted7z("pw"))
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "org.7-zip.7-zip-archive")
                #expect(document.state.isLocked == true)
                try await document.unlock(password: "pw")
                document.model?.add([added], to: "")

                try await document.save(to: url, ofType: "org.7-zip.7-zip-archive", for: .saveOperation)

                let call = try #require(fake.writes.last)
                #expect(call.format == .sevenZip)
                // No panel saved it: the source's encryption and password, stripping by default.
                #expect(call.options == ArchiveWriteOptions(encryption: .aes256, password: "pw", excludesMacMetadata: true))
                #expect(document.state.loadError == nil)
                #expect(document.state.isLocked == false)
                #expect(document.model?.password == "pw")
                #expect(document.model?.reader?.isEncrypted == true)
                #expect(document.model?.hasChanges == false)
                // The written file needs its password now.
                #expect(throws: ArchiveError.passwordRequired) { try fake.open(url, password: nil) }
            }
        }
    }

    @Test func plainSevenZipAndNewArchiveStayEditable() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = FakeReader(entries: SampleArchive().entries, format: .sevenZip, url: url)
        #expect(ArchiveModel(reader: reader, undoManager: nil).isEditable)
        #expect(ArchiveModel(newArchiveFormat: .sevenZip, undoManager: nil).isEditable)
        #expect(ArchiveModel(newArchiveFormat: .zip, undoManager: nil).isEditable)
    }

    @Test func aVolumeSetCannotBeSavedInPlaceButCanBeSavedAs() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let own = KernirDocumentTypes.utType(for: .sevenZip).identifier
        let all = KernirDocumentTypes.writable.map(\.identifier)
        try await withEngine(FakeEngine(.volumeSet)) {
            let set = ArchiveDocument()
            try set.read(from: url, ofType: own)
            #expect(set.model?.isEditable == false)
            let inPlace = set.writableTypes(for: .saveOperation)
            #expect(!inPlace.contains(own))
            #expect(inPlace == all.filter { $0 != own })
            #expect(set.writableTypes(for: .saveAsOperation) == all)
            #expect(set.writableTypes(for: .saveToOperation) == all)
        }
        try await withEngine(FakeEngine(.succeed)) {
            let single = ArchiveDocument()
            try single.read(from: url, ofType: own)
            #expect(single.writableTypes(for: .saveOperation) == all)
            #expect(single.writableTypes(for: .saveAsOperation) == all)
        }
        // A new document has no reader: unchanged.
        #expect(try ArchiveDocument(type: own).writableTypes(for: .saveOperation) == all)
    }

    /// NSDocument writes to a temporary file and swaps it in, so the engine never sees the part:
    /// the document refuses a destination that is one of the set's parts and writes nothing.
    @Test func saveAsOntoAPartOfTheSetFailsAndLeavesItUntouched() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let own = KernirDocumentTypes.utType(for: .sevenZip).identifier
        let fake = FakeEngine(.volumeSet)
        try await withEngine(fake) {
            let document = try ArchiveDocument(contentsOf: url, ofType: own)
            let parts = try #require(document.model?.reader?.volumeURLs)
            #expect(parts.count == 2)
            // The opened part, and a part that isn't on disk (FakeEngine's second part).
            for part in parts {
                await #expect(throws: SaveOntoVolumePartError.self) {
                    try await document.save(to: part, ofType: own, for: .saveAsOperation)
                }
            }
            await #expect(throws: SaveOntoVolumePartError.self) {
                try await document.save(to: url, ofType: "public.zip-archive", for: .saveToOperation)
            }
            #expect(fake.writes.isEmpty)
            #expect(try Data(contentsOf: url) == original)
            #expect(document.fileURL == url)
            #expect(document.model?.reader?.volumeURLs.count == 2)
            #expect(document.state.progress == nil)
        }
    }

    /// Save As of a set writes one ordinary archive; the document moves to it and can be edited.
    @Test func saveAsOfASetMakesTheDocumentEditable() async throws {
        let url = try makeArchiveFile()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).7z")
        defer {
            for file in [url, destination] { try? FileManager.default.removeItem(at: file) }
        }
        let own = KernirDocumentTypes.utType(for: .sevenZip).identifier
        let all = KernirDocumentTypes.writable.map(\.identifier)
        let fake = FakeEngine(.volumeSet)
        try await withEngine(fake) {
            let document = try ArchiveDocument(contentsOf: url, ofType: own)
            #expect(document.model?.isEditable == false)
            // The written file is one archive.
            fake.behavior = .succeed
            try await document.save(to: destination, ofType: own, for: .saveAsOperation)
            #expect(fake.writes.count == 1)
            #expect(document.fileURL == destination)
            #expect(document.model?.reader?.volumeURLs.count == 1)
            #expect(document.model?.isEditable == true)
            #expect(document.writableTypes(for: .saveOperation) == all)
        }
    }

    /// The save panel of a set refuses its parts (the panel stays open with the message) and
    /// proposes the set's name, not the part's.
    @Test func savePanelOfASetRefusesItsPartsAndProposesTheSetName() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("s7.7z.001")
        try Data("7z".utf8).write(to: url)
        let own = KernirDocumentTypes.utType(for: .sevenZip).identifier
        try await withEngine(FakeEngine(.volumeSet)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: own)
            let panel = NSSavePanel()
            _ = document.prepareSavePanel(panel)
            let options = try #require(document.savePanelOptions)
            #expect(panel.nameFieldStringValue == "s7.7z")
            #expect(throws: SaveOntoVolumePartError.self) { try options.panel(panel, validate: url) }
            let message = SaveOntoVolumePartError(name: "s7.7z.001").localizedDescription
            #expect(message == "“s7.7z.001” is a part of this archive. Choose another name.")
            try options.panel(panel, validate: folder.appendingPathComponent("s7.7z"))
        }
    }

    private func volumeError(_ reason: ArchiveVolumeError.Reason, part: Int, in url: URL) -> ArchiveVolumeError {
        ArchiveVolumeError(reason: reason, part: part, fileName: "set.part\(part)", setName: "set.part1",
                           folder: url.deletingLastPathComponent(), openedPart: 1)
    }

    @Test func aVolumeErrorOpensTheWindowLockedInsteadOfFailing() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let error = volumeError(.noAccess, part: 2, in: url)
        try await withEngine(FakeEngine(.failVolume(error))) {
            let document = ArchiveDocument()
            // A throw here would be NSDocument's open-failure alert and no window.
            try document.read(from: url, ofType: "public.zip-archive")
            #expect(document.state.volumeError == error)
            #expect(document.model == nil)
            #expect(document.state.isLocked == false)
            #expect(document.state.loadError == nil)
        }
    }

    @Test func retryAfterGrantingAccessInstallsTheSetReadOnly() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let own = KernirDocumentTypes.utType(for: .sevenZip).identifier
        let all = KernirDocumentTypes.writable.map(\.identifier)
        let fake = FakeEngine(.failVolume(volumeError(.noAccess, part: 2, in: url)))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: own)
            fake.behavior = .volumeSet
            // Opened: nothing is still unreadable.
            #expect(await document.retryVolumeOpen() == nil)
            #expect(document.state.volumeError == nil)
            #expect(document.state.loadError == nil)
            #expect(document.state.isLocked == false)
            #expect(document.model?.itemCount == 7)
            #expect(document.model?.isEditable == false)
            #expect(document.writableTypes(for: .saveOperation) == all.filter { $0 != own })
        }
    }

    @Test func retryThatFindsAnotherMissingPartUpdatesTheError() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.failVolume(volumeError(.noAccess, part: 2, in: url)))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            let missing = volumeError(.missing, part: 3, in: url)
            fake.behavior = .failVolume(missing)
            // Another part: a new error the locked view shows by itself, no "still" alert.
            #expect(await document.retryVolumeOpen() == nil)
            #expect(document.state.volumeError == missing)
            #expect(document.model == nil)
        }
    }

    /// Grant Access to the right folder, and the reopen fails on the same part again: the retry
    /// returns that error, so Grant Access can say it's still unreadable instead of nothing.
    @Test func retryThatFailsOnTheSamePartReturnsTheError() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let error = volumeError(.noAccess, part: 2, in: url)
        let fake = FakeEngine(.failVolume(error))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            #expect(await document.retryVolumeOpen() == error)
            #expect(fake.opens == 2)
            #expect(document.state.volumeError == error)
            #expect(document.state.loadError == nil)
            #expect(document.state.isRetrying == false)
            #expect(document.model == nil)
            // The same part, now found missing: still the same failure, and the new error is returned.
            let missing = volumeError(.missing, part: 2, in: url)
            fake.behavior = .failVolume(missing)
            #expect(await document.retryVolumeOpen() == missing)
            #expect(fake.opens == 3)
            #expect(document.state.volumeError == missing)
        }
    }

    /// A retry that starts from a failed retry (a load error, no volume error) has no failure to
    /// repeat: a volume error then is new and returns nil.
    @Test func retryAfterAFailedRetryHasNothingToRepeat() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let error = volumeError(.missing, part: 2, in: url)
        let fake = FakeEngine(.failVolume(error))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            fake.behavior = .fail(.corrupted(""))
            #expect(await document.retryVolumeOpen() == nil)
            #expect(document.state.loadError != nil)
            fake.behavior = .failVolume(error)
            #expect(await document.retryVolumeOpen() == nil)
            #expect(fake.opens == 3)
            #expect(document.state.volumeError == error)
        }
    }

    @Test func retryOfAnEncryptedSetAsksForThePassword() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.failVolume(volumeError(.noAccess, part: 2, in: url)))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            fake.behavior = .requirePassword("secret")
            await document.retryVolumeOpen()
            #expect(document.state.volumeError == nil)
            #expect(document.state.isLocked == true)
            #expect(document.model == nil)
            try await document.unlock(password: "secret")
            #expect(document.state.isLocked == false)
            #expect(document.model != nil)
        }
    }

    @Test func retryThatFailsOtherwiseShowsTheLoadError() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.failVolume(volumeError(.noAccess, part: 2, in: url)))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            fake.behavior = .fail(.corrupted(""))
            await document.retryVolumeOpen()
            #expect(document.state.volumeError == nil)
            #expect(document.state.loadError != nil)
            #expect(document.model == nil)
        }
    }

    @Test func openingAnAlreadyOpenDocumentWithAVolumeErrorReadsItAgain() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.failVolume(volumeError(.missing, part: 2, in: url)))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            // The first showing (no window on screen yet; a restored window never gets one): no retry.
            #expect(document.noteWindowsShown(reopened: false) == nil)
            #expect(fake.opens == 1)
            // The user put the parts in one folder and opened the file again.
            fake.behavior = .volumeSet
            await document.noteWindowsShown(reopened: true)?.value
            #expect(fake.opens == 2)
            #expect(document.state.volumeError == nil)
            #expect(document.model?.itemCount == 7)
            // Opening it again without a volume error reads nothing.
            #expect(document.noteWindowsShown(reopened: true) == nil)
            #expect(fake.opens == 2)
        }
    }

    @Test(.timeLimit(.minutes(1))) func retryReturnsAtOnceWhileAnotherRetryRuns() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.failVolume(volumeError(.noAccess, part: 2, in: url)))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            fake.behavior = .volumeSet
            let gate = Gate()
            fake.gate = gate
            let first = Task { await document.retryVolumeOpen() }
            // The first retry is inside the engine, held by the gate.
            try await waitUntil { gate.arrivals == 1 }
            #expect(document.state.isRetrying)
            // A second retry returns without opening anything.
            #expect(await document.retryVolumeOpen() == nil)
            #expect(gate.arrivals == 1)
            #expect(fake.opens == 1)
            #expect(document.state.isRetrying)
            gate.open()
            #expect(await first.value == nil)
            #expect(fake.opens == 2)
            #expect(gate.arrivals == 1)
            #expect(document.state.isRetrying == false)
            #expect(document.model?.itemCount == 7)
        }
    }

    /// A retry that ends after the document closed shows nothing: no model is left behind.
    @Test func retryAfterCloseAppliesNothing() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let error = volumeError(.noAccess, part: 2, in: url)
        let fake = FakeEngine(.failVolume(error))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            fake.behavior = .volumeSet
            let gate = Gate()
            fake.gate = gate
            let retry = Task { await document.retryVolumeOpen() }
            try await waitUntil { gate.arrivals == 1 }
            document.close()
            gate.open()
            // Closed: nothing to say either.
            #expect(await retry.value == nil)
            #expect(fake.opens == 2)
            #expect(document.model == nil)
            #expect(document.state.volumeError == error)
            #expect(document.state.isRetrying == false)
        }
    }

    /// Without a volume error there is nothing to retry: a retry from a panel that stayed open
    /// while a reopen already read the set doesn't rebuild the model.
    @Test func retryWithoutAVolumeErrorDoesNothing() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.volumeSet)
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            let model = document.model
            await document.retryVolumeOpen()
            #expect(fake.opens == 1)
            #expect(document.model === model)
        }
    }

    /// A retry that failed otherwise (a part still being copied reads as damaged) can be retried
    /// by opening the file again; a load error that never followed a volume error can't.
    @Test func openingAgainRetriesAFailedRetry() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.failVolume(volumeError(.missing, part: 2, in: url)))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            fake.behavior = .fail(.corrupted(""))
            await document.retryVolumeOpen()
            #expect(document.state.loadError != nil)
            #expect(document.state.volumeError == nil)
            fake.behavior = .volumeSet
            await document.noteWindowsShown(reopened: true)?.value
            #expect(fake.opens == 3)
            #expect(document.state.loadError == nil)
            #expect(document.model?.itemCount == 7)
            // Read and shown: nothing more to retry.
            #expect(document.noteWindowsShown(reopened: true) == nil)
        }
        try await withEngine(FakeEngine(.succeed)) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            document.state.model = nil
            document.state.loadError = "Couldn't open it again."
            #expect(document.noteWindowsShown(reopened: true) == nil)
        }
    }

    /// The retry reads the file's size off the main thread and keeps the old one when it fails.
    @Test func retryUpdatesTheFileSizeOnlyWhenItOpens() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.failVolume(volumeError(.noAccess, part: 2, in: url)))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            #expect(document.state.fileSize == 4)
            try Data("PK\u{3}\u{4}more".utf8).write(to: url)
            fake.behavior = .fail(.corrupted(""))
            await document.retryVolumeOpen()
            #expect(document.state.fileSize == 4)
            fake.behavior = .volumeSet
            await document.noteWindowsShown(reopened: true)?.value
            #expect(document.state.fileSize == 8)
        }
    }

    /// The disabled ＋ and － say why: a split archive is read-only whatever its format.
    @Test func readOnlyHelpNamesTheReason() {
        let url = URL(fileURLWithPath: "/tmp/s7.7z.001")
        let entries = SampleArchive().entries
        #expect(ArchiveWindowView.readOnlyHelp(nil) == nil)
        #expect(ArchiveWindowView.readOnlyHelp(
            ArchiveModel(reader: FakeReader(entries: entries, format: .sevenZip, url: url), undoManager: nil)) == nil)
        #expect(ArchiveWindowView.readOnlyHelp(
            ArchiveModel(reader: FakeReader(entries: entries, format: .rar, url: url), undoManager: nil))
            == "RAR can only be read. Save As ZIP or 7z to edit.")
        let set = FakeReader(entries: entries, format: .sevenZip, url: url,
                             volumeURLs: [url, url.deletingPathExtension().appendingPathExtension("002")])
        #expect(ArchiveWindowView.readOnlyHelp(ArchiveModel(reader: set, undoManager: nil))
            == "Split archives can only be read. Save As to edit.")
    }

    @Test func newDocumentUsesTheRequestedWritableType() throws {
        #expect(try ArchiveDocument(type: "public.zip-archive").model?.format == .zip)
        let sevenZip = KernirDocumentTypes.utType(for: .sevenZip).identifier
        let seven = try ArchiveDocument(type: sevenZip)
        #expect(seven.model?.format == .sevenZip)
        #expect(seven.fileType == sevenZip)
        // Read-only formats fall back to ZIP.
        let rar = try ArchiveDocument(type: KernirDocumentTypes.utType(for: .rar).identifier)
        #expect(rar.model?.format == .zip)
        #expect(rar.fileType == "public.zip-archive")
    }

    @Test func unlockedEncryptedZipStaysEditable() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encryptedZip("pw"))) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            try await document.unlock(password: "pw")
            #expect(document.model?.isEditable == true)
            #expect(ArchiveActions(document: document).canAdd)
        }
    }

    /// 7zAES can't tell damage from a wrong password, so the same error may repeat
    /// with the right password. Each unlock opens once; nothing retries or re-prompts.
    @Test func passwordSheetNeverLoops() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.alwaysWrongPassword)
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "org.7-zip.7-zip-archive")
            #expect(document.state.isLocked == true)
            let opensAfterRead = fake.opens

            try await document.unlock(password: "a")
            try await document.unlock(password: "b")
            #expect(fake.opens == opensAfterRead + 2)
            #expect(document.state.passwordError != nil)
            #expect(document.state.isLocked == true)
            #expect(document.model == nil)

            // Cancel (resets the counter, then closes the document) works with the error up.
            ArchiveActions(document: document).cancelUnlock()
            #expect(document.state.wrongPasswordCount == 0)
            #expect(fake.opens == opensAfterRead + 2)
        }
    }

    @Test func damagedHintAppearsOnTheSecondWrongSevenZipPassword() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encrypted7z("pw"))) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "org.7-zip.7-zip-archive")
            #expect(!document.state.showsDamagedHint)
            try await document.unlock(password: "x")
            #expect(!document.state.showsDamagedHint)
            try await document.unlock(password: "y")
            #expect(document.state.showsDamagedHint)
            #expect(document.state.wrongPasswordCount == 2)

            // Cancel resets it.
            ArchiveActions(document: document).cancelUnlock()
            #expect(!document.state.showsDamagedHint)
        }
    }

    @Test func rightPasswordAfterAWrongSevenZipOneResetsTheCounter() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encrypted7z("pw"))) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "org.7-zip.7-zip-archive")
            try await document.unlock(password: "x")
            #expect(document.state.wrongPasswordCount == 1)
            try await document.unlock(password: "pw")
            #expect(document.state.isLocked == false)
            #expect(document.state.wrongPasswordCount == 0)
            #expect(!document.state.showsDamagedHint)
        }
    }

    @Test func zipNeverShowsTheDamagedHint() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encryptedZip("pw"))) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            try await document.unlock(password: "x")
            try await document.unlock(password: "y")
            #expect(document.state.passwordError != nil)
            #expect(!document.state.showsDamagedHint)
        }
    }

    @Test func unlockRememberSavesOnlyAPasswordThatWorks() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encryptedZip("pw"))) {
            try await withKeychainService { service in
                defer { KeychainPasswordStore.remove(for: url, service: service) }
                let document = ArchiveDocument()
                try document.read(from: url, ofType: "public.zip-archive")
                #expect(document.state.isLocked == true)

                try await document.unlock(password: "nope", remember: true)
                #expect(document.state.isLocked == true)
                #expect(KeychainPasswordStore.password(for: url, service: service) == nil)

                try await document.unlock(password: "pw", remember: true)
                #expect(document.state.isLocked == false)
                #expect(KeychainPasswordStore.password(for: url, service: service) == "pw")
            }
        }
    }

    /// The core doesn't verify an empty password, so an encrypted ZIP must not open with one.
    @Test func emptyPasswordKeepsAnEncryptedZipLocked() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.encryptedZip("pw"))) {
            try await withKeychainService { service in
                defer { KeychainPasswordStore.remove(for: url, service: service) }
                let document = ArchiveDocument()
                try document.read(from: url, ofType: "public.zip-archive")

                try await document.unlock(password: "", remember: true)
                #expect(document.state.isLocked == true)
                #expect(document.model == nil)
                #expect(document.state.passwordError != nil)
                #expect(KeychainPasswordStore.password(for: url, service: service) == nil)
            }
        }
    }

    /// Another password won't fix a damaged archive: unlock throws so the window can close it.
    @Test func unlockThrowsErrorsOtherThanWrongPassword() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.fail(.passwordRequired))
        try await withEngine(fake) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")

            fake.behavior = .fail(.corrupted("bad header"))
            await #expect(throws: ArchiveError.corrupted("bad header")) {
                try await document.unlock(password: "x")
            }
            #expect(document.state.passwordError == nil)
            #expect(document.model == nil)
        }
    }

    /// Without a window the error goes to the seam (the app-modal alert), after the document closes.
    @Test func unlockFailureWithoutWindowPresentsTheError() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.fail(.passwordRequired))
        try await PresentedErrors.collecting { presented in
            try await withEngine(fake) {
                let document = ArchiveDocument()
                try document.read(from: url, ofType: "public.zip-archive")
                let actions = ArchiveActions(document: document)

                fake.behavior = .fail(.corrupted("x"))
                await actions.unlock(password: "p", remember: false)

                #expect(presented.errors.count == 1)
                #expect(presented.errors.first as? ArchiveError == .corrupted("x"))
                #expect(document.model == nil)
            }
        }
    }

    @Test func unsupportedEncryptionThrows() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        await withEngine(FakeEngine(.fail(.unsupportedEncryption(.sevenZip)))) {
            let document = ArchiveDocument()
            #expect(throws: ArchiveError.unsupportedEncryption(.sevenZip)) {
                try document.read(from: url, ofType: "org.7-zip.7-zip-archive")
            }
            #expect(document.state.isLocked == false)
            #expect(document.model == nil)
        }
    }

    /// NSDocumentController's open alert reads "The document “x” could not be opened." plus the
    /// error's failure reason and recovery suggestion, so the reason carries our message.
    @Test func openAlertExplainsTheError() {
        let error = ArchiveError.unsupportedEncryption(.sevenZip) as NSError
        #expect(error.localizedFailureReason == ArchiveError.unsupportedEncryption(.sevenZip).errorDescription)
        #expect(error.localizedFailureReason?.isEmpty == false)
        #expect(error.localizedRecoverySuggestion != nil)
    }

    @Test func otherReadErrorsAreThrownAsIs() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        await withEngine(FakeEngine(.fail(.corrupted("bad header")))) {
            let document = ArchiveDocument()
            #expect(throws: ArchiveError.corrupted("bad header")) {
                try document.read(from: url, ofType: "public.zip-archive")
            }
            #expect(document.state.isLocked == false)
        }
    }

    @Test func unlockStoresPasswordInModel() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.requirePassword("pw"))) {
            let document = ArchiveDocument()
            try document.read(from: url, ofType: "public.zip-archive")
            try await document.unlock(password: "pw")
            #expect(document.model?.password == "pw")
        }
    }

    @Test func readBuildsModelOffTheMainThread() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = ArchiveDocument()
            // NSDocumentController reads concurrently on a background thread.
            try await Self.readDetached(UncheckedDocument(document: document), from: url)
            #expect(document.model?.itemCount == 7)
            #expect(document.model?.undoManager === document.undoManager)
        }
    }

    /// With concurrent reading, NSDocumentController creates the document itself on a background
    /// thread (`init(contentsOf:ofType:)` → `init()` → `read`), so neither may assume the main actor.
    @Test func documentCanBeCreatedOffTheMainThread() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let box = try await Self.makeDetached(from: url)
            #expect(box.document.model?.itemCount == 7)
            #expect(box.document.fileURL == url)
            #expect(box.document.state.fileSize == 4)
        }
    }

    @Test func newDocumentIsEmptyZip() throws {
        let document = try ArchiveDocument(type: "public.zip-archive")
        #expect(document.model?.format == .zip)
        #expect(document.model?.itemCount == 0)
        #expect(document.fileType == "public.zip-archive")
        #expect(document.state.isLocked == false)
        #expect(document.state.fileSize == nil)
    }

    @Test func writableTypesExcludeRar() {
        let document = ArchiveDocument()
        for operation in [NSDocument.SaveOperationType.saveOperation, .saveAsOperation, .saveToOperation] {
            let types = document.writableTypes(for: operation)
            #expect(types == KernirDocumentTypes.writable.map(\.identifier))
            #expect(!types.contains("com.rarlab.rar-archive"))
            #expect(types.contains("public.zip-archive"))
        }
    }

    @Test func packageTypesAreZipBasedViewers() throws {
        let packages = KernirDocumentTypes.packageTypes
        #expect(packages.count == 9)
        for type in packages {
            #expect(type.conforms(to: .zip), "\(type.identifier) is not a ZIP archive")
            #expect(!KernirDocumentTypes.writable.contains(type))
        }

        let documentTypes = try #require(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        for type in packages {
            let entry = documentTypes.first {
                ($0["LSItemContentTypes"] as? [String])?.contains(type.identifier) == true
            }
            #expect(entry?["CFBundleTypeRole"] as? String == "Viewer", "\(type.identifier)")
            #expect(entry?["LSHandlerRank"] as? String == "Alternate", "\(type.identifier)")
        }
    }

    @Test func infoPlistDeclaresEveryReadableType() throws {
        let declared = try #require(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        // The Dock drop type ("File or Folder", rank None, no class) is no archive type:
        // DropTypeHostedTests checks it.
        let documentTypes = declared.filter { $0["LSHandlerRank"] as? String != "None" }
        #expect(declared.count == documentTypes.count + 1)
        let writable = Set(KernirDocumentTypes.writable.map(\.identifier))
        for identifier in KernirDocumentTypes.identifiers {
            let entry = documentTypes.first {
                ($0["LSItemContentTypes"] as? [String])?.contains(identifier) == true
            }
            #expect(entry?["CFBundleTypeRole"] as? String == (writable.contains(identifier) ? "Editor" : "Viewer"),
                    "\(identifier)")
            // A split archive's part (.001 … .999, .z01 … .z99) shares its extension with unrelated
            // files, so Kernir only offers itself for it. RAR's .r00 … .r99 are
            // tags of the RAR type and keep its Default rank.
            let rank = identifier == KernirDocumentTypes.volumeSetIdentifier ? "Alternate" : "Default"
            #expect(entry?["LSHandlerRank"] as? String == rank, "\(identifier)")
        }
        let volume = try #require(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?.contains(KernirDocumentTypes.volumeSetIdentifier) == true
        })
        #expect(volume["LSItemContentTypes"] as? [String] == [KernirDocumentTypes.volumeSetIdentifier])
        #expect(volume["CFBundleTypeName"] as? String == "Split Archive Part")
        #expect(volume["CFBundleTypeRole"] as? String == "Viewer")
        #expect(volume["LSHandlerRank"] as? String == "Alternate")
        #expect(documentTypes.count == KernirDocumentTypes.identifiers.count + KernirDocumentTypes.packageTypes.count)
        for entry in documentTypes {
            let className = try #require(entry["NSDocumentClass"] as? String)
            #expect(NSClassFromString(className) === ArchiveDocument.self, "\(className)")
        }
        // App Store Connect rejects a document type without a name (ITMS-90243).
        let names = documentTypes.compactMap { $0["CFBundleTypeName"] as? String }.filter { !$0.isEmpty }
        #expect(names.count == documentTypes.count)
        #expect(Set(names).count == names.count)
        #expect(NSDocumentController.shared.documentClass(forType: "public.zip-archive") === ArchiveDocument.self)
        #expect(NSDocumentController.shared.defaultType == "public.zip-archive")
    }

    @Test func importedPackageTypesAreDeclared() throws {
        let imported = try #require(Bundle.main.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]])
        let importedIdentifiers = Set(imported.compactMap { $0["UTTypeIdentifier"] as? String })
        #expect(imported.count == importedIdentifiers.count)
        #expect(importedIdentifiers == [
            "com.rarlab.rar-archive", "com.kernir.archive-volume", "com.facebook.zst-archive", "cx.c3.lha-archive",
            "com.sun.enterprise-archive", "com.android.package-archive", "com.android.app-bundle",
            "org.mozilla.xpinstall", "org.python.wheel", "org.nuget.package", "com.microsoft.vsix",
        ])
        // The type of a split archive's parts: 7z/zip/… .001 … .999 and spanned zip .z01 … .z99.
        let volume = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "com.kernir.archive-volume" })
        #expect(volume["UTTypeDescription"] as? String == "Split Archive Part")
        #expect(volume["UTTypeConformsTo"] as? [String] == ["public.data", "public.archive"])
        let volumeTags = volume["UTTypeTagSpecification"] as? [String: Any]
        #expect(volumeTags?["public.filename-extension"] as? [String]
            == (1...999).map { String(format: "%03d", $0) } + (1...99).map { String(format: "z%02d", $0) })
        let apk = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "com.android.package-archive" })
        let tags = apk["UTTypeTagSpecification"] as? [String: Any]
        #expect(tags?["public.filename-extension"] as? [String] == ["apk"])
        #expect(tags?["public.mime-type"] as? [String] == ["application/vnd.android.package-archive"])
        let ear = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "com.sun.enterprise-archive" })
        #expect((ear["UTTypeConformsTo"] as? [String])?.contains("com.sun.java-archive") == true)
        #expect(UTType(filenameExtension: "whl")?.conforms(to: .zip) == true)
    }

    @Test func privacyManifestShipsInTheAppBundle() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        let accessed = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for entry in accessed {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            reasons[category] = Set(entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        }
        #expect(accessed.count == 3)
        #expect(reasons == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
        ])
    }

    // MARK: - Saving

    /// A real file to add to an archive; the caller removes it.
    private func makeFileToAdd() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentTests-added-\(UUID().uuidString).txt")
        try Data("added".utf8).write(to: url)
        return url
    }

    /// With the real engine: the unlocked reader's password reaches the writer, so a plain
    /// save of a ZipCrypto ZIP keeps every entry (including the added one) encrypted.
    @Test func plainSaveOfZipCryptoArchiveStaysEncryptedWithTheRealEngine() async throws {
        try await PresentedErrors.expectingNone {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveDocumentTests-live-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = directory.appendingPathComponent("first.txt")
            try Data("first".utf8).write(to: first)
            let added = directory.appendingPathComponent("added.txt")
            try Data("added".utf8).write(to: added)
            let url = directory.appendingPathComponent("source.zip")

            try await withKeychainService { _ in
                ArchiveDocument.engine = .live
                let engine = ArchiveEngine.live
                try await engine.write(nil, ArchiveChangeSet(additions: [.init(sourceURL: first, destinationDirectory: "")]),
                                       .zip, url, ArchiveWriteOptions(encryption: .zipCrypto, password: "pw"), nil)

                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                #expect(document.state.isLocked == true)
                try await document.unlock(password: "pw")
                #expect(document.state.isLocked == false)
                let model = try #require(document.model)
                model.add([added], to: "")
                #expect(model.hasChanges)

                try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)

                let reopened = try await engine.open(url, "pw")
                #expect(Set(reopened.entries.map(\.path)) == ["first.txt", "added.txt"])
                #expect(reopened.encryption == .zipCrypto)
                let everyFileEncrypted = reopened.entries.filter { !$0.isDirectory }.allSatisfy { $0.isEncrypted }
                #expect(everyFileEncrypted)
                let withoutPassword = try await engine.open(url, nil)
                await #expect(throws: ArchiveError.passwordRequired) {
                    _ = try await withoutPassword.extractToTemporaryFile("added.txt")
                }
                #expect(document.model?.hasChanges == false)
            }
        }
    }

    @Test func saveWritesChangesWithSourceAndFormat() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let added = try makeFileToAdd()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: added)
            }
            let fake = FakeEngine(.succeed)
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let model = try #require(document.model)
                model.password = "pw"
                model.add([added], to: "")
                let changes = model.changes
                #expect(!changes.isEmpty)

                try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)

                let call = try #require(fake.writes.last)
                #expect(fake.writes.count == 1)
                #expect(call.changes == changes)
                #expect(call.format == .zip)
                #expect(call.source?.url == url)
                // The app's default (on), and no password for an archive that isn't encrypted.
                #expect(call.options == ArchiveWriteOptions(excludesMacMetadata: true))
                #expect(document.model?.hasChanges == false)
                #expect(document.model?.reader?.url == url)
                #expect(document.isDocumentEdited == false)
                #expect(document.state.progress == nil)
                #expect(try Data(contentsOf: url) == Data("written zip".utf8))
            }
        }
    }

    /// ⌘S must not re-encrypt: it keeps the source's method, encryption and password. With the
    /// app's default on and no panel-saved options, it says so explicitly.
    @Test func plainSaveKeepsSourceEncryption() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let added = try makeFileToAdd()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: added)
            }
            let fake = FakeEngine(.requirePassword("pw", encryption: .zipCrypto))
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                try await document.unlock(password: "pw")
                let model = try #require(document.model)
                #expect(model.reader?.encryption == .zipCrypto)
                model.add([added], to: "")

                try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)

                let call = try #require(fake.writes.last)
                #expect(fake.writes.count == 1)
                #expect(call.options == ArchiveWriteOptions(encryption: .zipCrypto, password: "pw", excludesMacMetadata: true))
            }
        }
    }

    /// ⌘S keeps the source's settings (stripping by the app's default); a save
    /// through the panel passes the panel's settings, and they stay with the document for the next ⌘S.
    @Test func plainSaveKeepsSourceSettings() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let added = try makeFileToAdd()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).zip")
            defer {
                for file in [url, added, destination] { try? FileManager.default.removeItem(at: file) }
            }
            let fake = FakeEngine(.requirePassword("pw"))
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                try await document.unlock(password: "pw")
                let model = try #require(document.model)
                model.add([added], to: "")

                try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)
                #expect(fake.writes.last?.options
                    == ArchiveWriteOptions(encryption: .aes256, password: "pw", excludesMacMetadata: true))

                var settings = ArchiveSaveSettings(model: try #require(document.model))
                settings.options.compressionLevel = 9
                document.savePanelOptions = SavePanelOptions(settings: settings)

                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
                #expect(fake.writes.last?.options == settings.options)
                #expect(document.savePanelOptions == nil)
                #expect(document.model?.saveOptions == settings.options)
                #expect(document.model?.password == "pw")

                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveOperation)
                #expect(fake.writes.count == 3)
                #expect(fake.writes.last?.options == settings.options)
            }
        }
    }

    /// ⌘S after a cancelled Save As must not pick up that panel's options and re-encrypt.
    @Test func plainSaveIgnoresCancelledPanelOptions() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let fake = FakeEngine(.succeed)
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                var settings = ArchiveSaveSettings(model: try #require(document.model))
                settings.options.encryption = .aes256
                settings.options.password = "pw"
                settings.verifyPassword = "pw"
                document.savePanelOptions = SavePanelOptions(settings: settings)

                document.save(withDelegate: nil, didSave: nil, contextInfo: nil)

                try await waitUntil { fake.writes.count == 1 && document.state.progress == nil }
                // The source's settings (no encryption), stripping by the app's default.
                #expect(fake.writes.first?.options == ArchiveWriteOptions(excludesMacMetadata: true))
            }
        }
    }

    /// No model (locked): the panel gets no options, and none are left from an earlier panel.
    @Test func savePanelWithoutModelHasNoOptions() {
        let document = ArchiveDocument()
        document.savePanelOptions = SavePanelOptions(settings: ArchiveSaveSettings(
            format: .zip, options: ArchiveWriteOptions(encryption: .aes256, password: "pw"), verifyPassword: "pw"))

        _ = document.prepareSavePanel(NSSavePanel())

        #expect(document.savePanelOptions == nil)
    }

    /// Our accessory's format popup replaces NSDocument's and decides the saved type.
    @Test func panelFormatDecidesTheSavedType() {
        let document = ArchiveDocument()
        #expect(document.shouldRunSavePanelWithAccessoryView == false)
        document.savePanelOptions = SavePanelOptions(settings: ArchiveSaveSettings(
            format: .tarGzip, options: ArchiveWriteOptions()))
        #expect(document.fileTypeFromLastRunSavePanel == KernirDocumentTypes.utType(for: .tarGzip).identifier)
    }

    /// The panel's split check gets the document and every pending addition, so a split
    /// save never replaces a folder holding either.
    @Test func savePanelKnowsWhatASplitSaveMustNotReplace() async throws {
        let url = try makeArchiveFile()
        let added = try makeFileToAdd()
        defer {
            for file in [url, added] { try? FileManager.default.removeItem(at: file) }
        }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            try #require(document.model).add([added], to: "")

            _ = document.prepareSavePanel(NSSavePanel())

            let sources = try #require(document.savePanelOptions).sourceURLs.map(\.standardizedFileURL.path)
            #expect(sources.contains(url.standardizedFileURL.path))
            #expect(sources.contains(added.standardizedFileURL.path))
        }
    }

    // The split save itself: ArchiveDocumentSplitSaveTests.swift (an extension of this suite).

    /// A save that fails leaves the document's options as they were.
    @Test func failedSaveAsKeepsOptions() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).zip")
            defer {
                for file in [url, destination] { try? FileManager.default.removeItem(at: file) }
            }
            try await withEngine(FakeEngine(.succeed, write: .fail(.io("disk full")))) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                var settings = ArchiveSaveSettings(model: try #require(document.model))
                settings.options.encryption = .aes256
                settings.options.password = "pw"
                settings.verifyPassword = "pw"
                document.savePanelOptions = SavePanelOptions(settings: settings)

                await #expect(throws: (any Error).self) {
                    try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
                }
                #expect(document.savePanelOptions == nil)
                #expect(document.model?.saveOptions == nil)
                #expect(document.model?.password == nil)
            }
        }
    }

    @Test func saveAsChangesFormat() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).7z")
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: destination)
            }
            let fake = FakeEngine(.succeed)
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")

                try await document.save(to: destination, ofType: "org.7-zip.7-zip-archive", for: .saveAsOperation)

                #expect(fake.writes.last?.format == .sevenZip)
                #expect(document.model?.format == .sevenZip)
                #expect(document.fileURL == destination)
                #expect(document.fileType == "org.7-zip.7-zip-archive")
                #expect(try Data(contentsOf: url) == Data("PK\u{3}\u{4}".utf8))
            }
        }
    }

    /// An archive saved from a downloaded one stays quarantined: the sandbox no longer marks what Lutik
    /// writes (`files.user-selected.executable`), so the save carries the original's quarantine over, to a
    /// Save As copy and in place.
    @Test(arguments: [NSDocument.SaveOperationType.saveAsOperation, .saveOperation])
    func savingADownloadedArchiveKeepsItsQuarantine(_ operation: NSDocument.SaveOperationType) async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let destination = operation == .saveOperation ? url : FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).zip")
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: destination)
            }
            var marked = url
            var values = URLResourceValues()
            values.quarantineProperties = ["LSQuarantineAgentName": "Safari",
                                           "LSQuarantineEventIdentifier": sampleQuarantineEvent]
            try marked.setResourceValues(values)
            try await withEngine(FakeEngine(.succeed)) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")

                try await document.save(to: destination, ofType: "public.zip-archive", for: operation)

                #expect(try quarantineEvent(of: destination) == sampleQuarantineEvent)
            }
        }
    }

    /// With the real engine reading a scratch name encoding store.
    /// A save that keeps the entries' stored names (zip to zip) keeps the archive's manual CP866 for the file
    /// it wrote. A Save As to tar writes every name as UTF-8: the copy forgets the choice and shows the names
    /// right, read automatically; the original keeps its choice.
    @Test func saveKeepsTheChosenNameEncodingOnlyWhileTheNamesAreStoredThatWay() async throws {
        try await PresentedErrors.expectingNone {
            let cp866 = String.Encoding.testCP866
            let zip = try LegacyZip.write(["Docs/", "Docs/Отчёт.txt", "Папка/", "Папка/Отчёт за май.txt"], as: cp866)
            let directory = zip.deletingLastPathComponent()
            let tar = directory.appendingPathComponent("saved.tar")
            let (defaults, suiteName) = makeTestDefaults("ArchiveDocumentTests")
            let store = ArchiveNameEncodingStore(defaults: defaults)
            defer {
                try? FileManager.default.removeItem(at: directory)
                removeTestDefaults(defaults, suite: suiteName)
            }
            store.remember(.specific(cp866), for: zip)
            // Opening the document reads the scratch store; the reopen after a save is told the encoding (F-2).
            ArchiveDocument.engine = ArchiveEngine(open: { url, password in try await store.open(url, password: password) },
                                                   openWithNameEncoding: ArchiveEngine.live.openWithNameEncoding,
                                                   write: ArchiveEngine.live.write)
            defer { ArchiveDocument.engine = .live }

            let document = try ArchiveDocument(contentsOf: zip, ofType: "public.zip-archive")
            let model = try #require(document.model)
            model.nameEncodingStore = store
            #expect(model.reader?.nameEncoding == .specific(cp866))
            model.remove(["Docs/Отчёт.txt"])

            try await document.save(to: zip, ofType: "public.zip-archive", for: .saveOperation)

            #expect(document.model?.reader?.nameEncoding == .specific(cp866))
            #expect(document.model?.item(at: "Папка/Отчёт за май.txt") != nil)
            #expect(document.model?.item(at: "Docs/Отчёт.txt") == nil)
            #expect(store.nameEncoding(for: zip) == .specific(cp866))

            try await document.save(to: tar, ofType: "public.tar-archive", for: .saveAsOperation)

            #expect(document.fileURL == tar)
            #expect(document.model?.reader?.format == .tar)
            #expect(document.model?.reader?.nameEncoding == .automatic)
            #expect(document.model?.item(at: "Папка/Отчёт за май.txt") != nil)
            #expect(store.nameEncoding(for: tar) == .automatic)
            #expect(store.nameEncoding(for: zip) == .specific(cp866))
        }
    }

    @Test func failedSaveKeepsChangesAndOriginal() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let added = try makeFileToAdd()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: added)
            }
            let original = try Data(contentsOf: url)
            try await withEngine(FakeEngine(.succeed, write: .fail(.io("disk full")))) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let model = try #require(document.model)
                model.add([added], to: "")
                document.updateChangeCount(.changeDone)
                #expect(document.isDocumentEdited)

                var saveError: (any Error)?
                do {
                    try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)
                } catch {
                    saveError = error
                }

                #expect(saveError != nil)
                #expect(try Data(contentsOf: url) == original)
                #expect(document.model === model)
                #expect(model.hasChanges == true)
                #expect(document.isDocumentEdited == true)
                #expect(document.state.progress == nil)
            }
        }
    }

    /// ⌘S on an encrypted zip named .tar saves as TAR, which has no encryption: the engine's refusal
    /// reaches NSDocument in save words (`SaveEncryptionError`), not the open-side text.
    @Test func plainSaveIntoAFormatWithoutTheEncryptionSaysSo() async throws {
        try await PresentedErrors.expectingNone {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).tar")
            try Data("PK\u{3}\u{4}".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let fake = FakeEngine(.encryptedZip("pw"), write: .fail(.unsupportedEncryption(.tar)))
            try await withEngine(fake) {
                try await withKeychainService { _ in
                    let document = try ArchiveDocument(contentsOf: url, ofType: "public.tar-archive")
                    try await document.unlock(password: "pw")
                    #expect(document.model?.reader?.format == .zip)

                    var saveError: (any Error)?
                    do {
                        try await document.save(to: url, ofType: "public.tar-archive", for: .saveOperation)
                    } catch {
                        saveError = error
                    }

                    #expect(fake.writes.last?.format == .tar)
                    #expect(fake.writes.last?.options?.encryption == .aes256)
                    let error = try #require(saveError) as NSError
                    #expect(error.localizedFailureReason == "TAR archives can't be saved with this encryption.")
                    #expect(error.localizedRecoverySuggestion
                                == "Use Save As to save it as ZIP or 7z, or without a password.")
                }
            }
        }
    }

    @Test func cancelledSaveIsUserCancelled() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let added = try makeFileToAdd()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: added)
            }
            let original = try Data(contentsOf: url)
            try await withEngine(FakeEngine(.succeed, write: .fail(.cancelled))) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let model = try #require(document.model)
                model.add([added], to: "")
                document.updateChangeCount(.changeDone)

                var saveError: (any Error)?
                do {
                    try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)
                } catch {
                    saveError = error
                }

                let cocoaError = try #require(saveError as? CocoaError)
                #expect(cocoaError.code == .userCancelled)
                #expect(try Data(contentsOf: url) == original)
                #expect(document.isDocumentEdited == true)
                #expect(model.hasChanges == true)
                #expect(document.state.progress == nil)
            }
        }
    }

    /// The write succeeded but the new file can't be reread: the edits are in the file now,
    /// so the document must not keep them where a later save would apply them again. The save
    /// itself succeeded: NSDocument is told so, and a separate error explains the reopen.
    @Test func failedReopenLeavesNoStaleChanges() async throws {
        let url = try makeArchiveFile()
        let added = try makeFileToAdd()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: added)
        }
        let fake = FakeEngine(.succeed)
        try await PresentedErrors.collecting { presented in
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                try #require(document.model).add([added], to: "")
                fake.behavior = .fail(.corrupted("unreadable"))

                // No error: the file was written.
                try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)

                #expect(fake.writes.count == 1)
                #expect(try Data(contentsOf: url) == Data("written zip".utf8))
                #expect(document.state.fileSize == Int64("written zip".utf8.count))
                #expect(document.model == nil)
                #expect(document.state.loadError != nil)
                #expect(document.state.progress == nil)
                let reopenError = try #require(presented.errors.first as? ReopenAfterSaveError)
                #expect(presented.errors.count == 1)
                #expect(reopenError.name == url.lastPathComponent)
                #expect(reopenError.underlying as? ArchiveError == .corrupted("unreadable"))
                #expect(reopenError.errorDescription?.contains(url.lastPathComponent) == true)
                #expect(reopenError.recoverySuggestion?.isEmpty == false)

                // A further save has nothing to apply and never reaches the writer.
                await #expect(throws: (any Error).self) {
                    try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)
                }
                #expect(fake.writes.count == 1)
                #expect(try Data(contentsOf: url) == Data("written zip".utf8))
            }
        }
    }

    /// The model a failed reopen drops leaves no undo steps behind: undoing one would edit, and move opened
    /// copies for, a model the document no longer shows.
    @Test func failedReopenLeavesNoUndoSteps() async throws {
        let url = try makeArchiveFile()
        let added = try makeFileToAdd()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: added)
        }
        let fake = FakeEngine(.succeed)
        try await PresentedErrors.collecting { presented in
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let undoManager = try #require(document.undoManager)
                undoManager.groupsByEvent = false
                undoManager.beginUndoGrouping()
                try #require(document.model).add([added], to: "")
                undoManager.endUndoGrouping()
                try #require(undoManager.canUndo)
                fake.behavior = .fail(.corrupted("unreadable"))

                try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)

                #expect(document.model == nil)
                #expect(presented.errors.first is ReopenAfterSaveError)
                #expect(!undoManager.canUndo)
                #expect(!undoManager.canRedo)
            }
        }
    }

    /// Shows a preview of the archive's `README.md` in `document`'s window, as `quickLook` does; returns
    /// the extracted file it shows.
    private func showPreview(in document: ArchiveDocument) -> URL {
        let extracted = URL(fileURLWithPath: "/tmp/README.md")
        document.state.previewEntries = [PreviewEntry(path: "README.md", url: extracted)]
        document.state.previewURL = extracted
        return extracted
    }

    /// Save and Save As reopen the written file, which replaces the listing and deletes the
    /// reader's extracted files, so a preview of the old listing ends; so does one when the saved file can't
    /// be reread.
    @Test(arguments: [NSDocument.SaveOperationType.saveOperation, .saveAsOperation], [false, true])
    func savingEndsThePreview(operation: NSDocument.SaveOperationType, rereadFails: Bool) async throws {
        try await PresentedErrors.collecting { presented in
            let url = try makeArchiveFile()
            let destination = operation == .saveAsOperation
                ? FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).zip")
                : url
            let added = try makeFileToAdd()
            defer {
                for file in [url, destination, added] { try? FileManager.default.removeItem(at: file) }
            }
            let fake = FakeEngine(.succeed)
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let actions = ArchiveActions(document: document)
                document.actions = actions
                try #require(document.model).add([added], to: "")
                _ = showPreview(in: document)
                if rereadFails { fake.behavior = .fail(.corrupted("unreadable")) }

                try await document.save(to: destination, ofType: "public.zip-archive", for: operation)

                #expect(fake.writes.count == 1)
                #expect(document.fileURL?.standardizedFileURL.path == destination.standardizedFileURL.path)
                #expect((document.model == nil) == rereadFails)
                #expect(document.state.previewURL == nil)
                #expect(document.state.previewEntries.isEmpty)
                #expect(!actions.hasRunningTasks)
            }
            #expect(presented.errors.count == (rereadFails ? 1 : 0))
        }
    }

    /// Revert to Saved reads the file again: a new listing, so the preview of the old one ends too.
    @Test func revertEndsThePreview() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let added = try makeFileToAdd()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: added)
            }
            let fake = FakeEngine(.succeed)
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let actions = ArchiveActions(document: document)
                document.actions = actions
                let model = try #require(document.model)
                model.add([added], to: "")
                document.updateChangeCount(.changeDone)
                _ = showPreview(in: document)

                try document.revert(toContentsOf: url, ofType: "public.zip-archive")

                #expect(fake.opens == 2)
                #expect(document.model !== model)
                #expect(document.state.previewURL == nil)
                #expect(document.state.previewEntries.isEmpty)
                #expect(!actions.hasRunningTasks)
            }
        }
    }

    /// Save To leaves the document on its own file and listing, and a failed save adopts
    /// nothing, so the preview stays open in both. (A split save is Save To too:
    /// `aSplitSaveChangesNothingInTheDocument`.)
    @Test(arguments: [false, true])
    func savingWithoutAReopenKeepsThePreview(writeFails: Bool) async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString).zip")
            let added = try makeFileToAdd()
            defer {
                for file in [url, copy, added] { try? FileManager.default.removeItem(at: file) }
            }
            let fake = FakeEngine(.succeed, write: writeFails ? .fail(.io("disk full")) : .succeed)
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let actions = ArchiveActions(document: document)
                document.actions = actions
                let model = try #require(document.model)
                model.add([added], to: "")
                let extracted = showPreview(in: document)

                if writeFails {
                    await #expect(throws: (any Error).self) {
                        try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)
                    }
                } else {
                    try await document.save(to: copy, ofType: "public.zip-archive", for: .saveToOperation)
                }

                #expect(fake.writes.count == 1)
                #expect(fake.opens == 1)
                #expect(document.model === model)
                #expect(document.state.previewURL == extracted)
                #expect(document.state.previewEntries.map(\.path) == ["README.md"])
            }
        }
    }

    /// The progress sheet's Cancel cancels the running write.
    @Test func progressCancelStopsTheWrite() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let fake = FakeEngine(.succeed, write: .runUntilCancelled)
            try await withEngine(fake) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let saving = Task {
                    try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)
                }
                let deadline = ContinuousClock.now + .seconds(60)
                while fake.writes.isEmpty {
                    try #require(ContinuousClock.now < deadline, "the write never started")
                    await Task.yield()
                }
                let cancel = try #require(document.state.progress?.cancel)
                cancel()

                let result = await saving.result
                #expect(throws: CocoaError.self) { try result.get() }
                if case .failure(let error) = result {
                    #expect((error as? CocoaError)?.code == .userCancelled)
                }
                #expect(document.state.progress == nil)
            }
        }
    }

    private func isEnabled(_ action: Selector, in document: ArchiveDocument) -> Bool {
        document.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    /// With no model (locked, or the file couldn't be reread after a save) there is nothing to save.
    @Test func saveIsDisabledWithoutModel() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.requirePassword("pw"))
        try await withEngine(fake) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            #expect(document.model == nil)
            #expect(!isEnabled(#selector(NSDocument.save(_:)), in: document))
            #expect(!isEnabled(#selector(NSDocument.saveAs(_:)), in: document))

            try await document.unlock(password: "pw")
            #expect(isEnabled(#selector(NSDocument.save(_:)), in: document))
            #expect(isEnabled(#selector(NSDocument.saveAs(_:)), in: document))
        }
    }

    // MARK: - Window

    /// A locked document has no model; the subtitle still names the format, from the file type.
    @Test func lockedSubtitleShowsFormatFromFileType() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.requirePassword("pw"))) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            #expect(document.model == nil)
            let subtitle = ArchiveWindowView.subtitle(format: document.model?.format, fileType: document.fileType,
                                                      fileSize: document.state.fileSize, isEdited: false)
            #expect(subtitle == "ZIP · \(KernirFormat.size(4))")
        }
        #expect(ArchiveWindowView.subtitle(format: nil, fileType: "com.sun.java-archive", fileSize: nil,
                                           isEdited: false) == "ZIP")
        #expect(ArchiveWindowView.subtitle(format: .sevenZip, fileType: "public.zip-archive", fileSize: nil,
                                           isEdited: false) == "7z")
    }

    /// Our subtitle replaces AppKit's, so it says "Edited" itself while there are unsaved changes.
    @Test func subtitleSaysEditedWithUnsavedChanges() {
        let size = KernirFormat.size(4)
        func subtitle(_ format: ArchiveFormat?, _ fileSize: Int64?, isEdited: Bool) -> String {
            ArchiveWindowView.subtitle(format: format, fileType: nil, fileSize: fileSize, isEdited: isEdited)
        }
        #expect(subtitle(.zip, 4, isEdited: false) == "ZIP · \(size)")
        #expect(subtitle(.zip, 4, isEdited: true) == "ZIP · \(size) — Edited")
        #expect(subtitle(.zip, nil, isEdited: true) == "ZIP — Edited")
        #expect(subtitle(nil, nil, isEdited: true) == "Edited")
    }

    /// The window state mirrors NSDocument's edited state through edits, undo, redo, save and revert.
    @Test func editedStateFollowsTheDocument() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            let added = try makeFileToAdd()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: added)
            }
            try await withEngine(FakeEngine(.succeed)) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let model = try #require(document.model)
                let undoManager = try #require(document.undoManager)
                #expect(document.state.isEdited == false)

                // One explicit group: NSDocument counts a change when it closes.
                undoManager.groupsByEvent = false
                undoManager.beginUndoGrouping()
                model.add([added], to: "")
                undoManager.endUndoGrouping()
                #expect(document.isDocumentEdited)
                #expect(document.state.isEdited)

                undoManager.undo()
                #expect(document.isDocumentEdited == false)
                #expect(document.state.isEdited == false)

                undoManager.redo()
                #expect(document.state.isEdited)

                try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)
                #expect(document.isDocumentEdited == false)
                #expect(document.state.isEdited == false)

                // Revert clears the count the same way.
                document.updateChangeCount(.changeDone)
                #expect(document.state.isEdited)
                document.updateChangeCount(.changeCleared)
                #expect(document.state.isEdited == false)
            }
        }
    }

    /// A single-stream archive (.gz) doesn't record its entry's size: the footer leaves it out, not "0 KB".
    @Test func footerLeavesOutAnUnknownSize() {
        let entry = ArchiveEntry(path: "notes.txt", isDirectory: false, size: nil, compressedSize: nil,
                                 modificationDate: nil)
        let model = ArchiveModel(reader: FakeReader(entries: [entry], format: .gzip), undoManager: nil)
        let footer = ArchiveWindowView.footerText(model)
        #expect(footer == "\(String(localized: "\(1) items", table: "Shared")) · GZ")
        #expect(!footer.contains(KernirFormat.size(0)))
    }

    @Test func removeSelectionRemovesAndClearsSelection() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            document.state.selection = ["src"]

            actions.removeSelection()

            #expect(document.model?.changes.removedPaths == ["src"])
            #expect(document.state.selection.isEmpty)
        }
    }

    /// Add Files… puts files into the one selected folder, otherwise at the top level.
    @Test func addFilesTargetsSelectedFolder() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)

            document.state.selection = ["assets"]
            #expect(actions.destinationForAdd() == "assets")
            document.state.selection = ["src", "README.md"]
            #expect(actions.destinationForAdd() == "")
            document.state.selection = ["README.md"]
            #expect(actions.destinationForAdd() == "")
            document.state.selection = []
            #expect(actions.destinationForAdd() == "")
        }
    }

    /// Drops add Finder files, but not the temporary files our own drag-out produced.
    @Test func dropIgnoresOwnTemporaryFiles() async throws {
        let url = try makeArchiveFile()
        let added = try makeFileToAdd()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: added)
        }
        let temporary = FileManager.default.temporaryDirectory
        #expect(ArchiveActions.isOwnTemporaryFile(temporary.appendingPathComponent("Kernir/ABC/src/main.swift")))
        #expect(ArchiveActions.isOwnTemporaryFile(temporary.appendingPathComponent("Kernir-1234/src")))
        #expect(!ArchiveActions.isOwnTemporaryFile(temporary.appendingPathComponent("Other/Kernir/a")))
        #expect(!ArchiveActions.isOwnTemporaryFile(URL(fileURLWithPath: "/Users/someone/Kernir/a")))

        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            let own = temporary.appendingPathComponent("Kernir/\(UUID().uuidString)/main.swift")
            #expect(!actions.addDropped([own], to: "assets"))
            #expect(document.model?.changes.additions.isEmpty == true)

            #expect(actions.addDropped([own, added], to: "assets"))
            #expect(document.model?.changes.additions.map(\.sourceURL) == [added])
            #expect(document.model?.item(at: "assets/\(added.lastPathComponent)") != nil)
        }
    }

    /// Replacing needs the user's OK; with no window to ask in, nothing changes.
    @Test func addNeverReplacesWithoutAsking() async throws {
        let url = try makeArchiveFile()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let readme = folder.appendingPathComponent("README.md")
        try Data("new".utf8).write(to: readme)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: folder)
        }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            actions.add([readme], to: "")
            #expect(document.model?.hasChanges == false)
        }
    }

    /// Option-Extract makes “project”, then “project 2”…, beside the archive.
    @Test func extractionFolderIsNamedLikeFinder() throws {
        #expect(ArchiveActions.extractionFolderName(for: URL(fileURLWithPath: "/a/project.zip")) == "project")
        #expect(ArchiveActions.extractionFolderName(for: URL(fileURLWithPath: "/a/project.tar.gz")) == "project")
        #expect(ArchiveActions.extractionFolderName(for: URL(fileURLWithPath: "/a/v1.2.7z")) == "v1.2")
        // A split archive's folder is named after the set, not the part.
        let part = URL(fileURLWithPath: "/a/Photos.zip.001")
        #expect(ArchiveActions.extractionFolderName(for: part, isVolumeSet: true) == "Photos")
        #expect(ArchiveActions.extractionFolderName(for: URL(fileURLWithPath: "/a/s.part1.rar"), isVolumeSet: true) == "s")
        // A set whose base name would be a dot name ("..") is named after the archive's own file (`ArchiveBaseName`).
        #expect(ArchiveActions.extractionFolderName(for: URL(fileURLWithPath: "/a/...part1.rar"), isVolumeSet: true)
                    == "...part1.rar")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ArchiveActions.uniqueFolder(named: "project", in: folder).lastPathComponent == "project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("project"),
                                                withIntermediateDirectories: false)
        #expect(ArchiveActions.uniqueFolder(named: "project", in: folder).lastPathComponent == "project 2")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("project 2"),
                                                withIntermediateDirectories: false)
        #expect(ArchiveActions.uniqueFolder(named: "project", in: folder).lastPathComponent == "project 3")
    }

    /// Double-click on a folder opens or closes it; the context menu deletes the clicked rows.
    @Test func openTogglesFoldersAndRemoveTakesPaths() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            actions.open(["src"])
            #expect(document.state.expanded == ["src"])
            actions.open(["src"])
            #expect(document.state.expanded.isEmpty)

            document.state.selection = ["src", "README.md"]
            #expect(actions.canRemove(["brief.pdf"]))
            actions.remove(["README.md"])
            #expect(document.model?.changes.removedPaths == ["README.md"])
            #expect(document.state.selection == ["src"])
        }
    }

    /// Toolbar, menus and Delete key share these rules.
    @Test func actionAvailabilityFollowsModelAndSelection() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.requirePassword("pw"))
        try await withEngine(fake) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            // Locked: nothing to act on.
            #expect(!actions.canAdd && !actions.canRemoveSelection && !actions.canExtract)
            #expect(!actions.canOpen(["src"]) && !actions.canToggleQuickLook)
            document.state.selection = ["src"]
            #expect(!actions.canOpenSelection)
            document.state.selection = []

            try await document.unlock(password: "pw")
            #expect(actions.canAdd)
            #expect(actions.canExtract)
            #expect(!actions.canRemoveSelection)
            #expect(!actions.canOpen([]))
            #expect(!actions.canOpenSelection)
            #expect(!actions.canToggleQuickLook)
            document.state.selection = ["src"]
            #expect(actions.canRemoveSelection)
            #expect(actions.canOpen(["src"]))
            #expect(actions.canOpenSelection)
            #expect(actions.canToggleQuickLook)
            // An open preview can always be closed, even with nothing selected.
            document.state.selection = []
            document.state.previewURL = URL(fileURLWithPath: "/tmp/preview.txt")
            #expect(actions.canToggleQuickLook)
        }
    }

    /// Nothing is added or deleted while a save or extraction runs: the model must not change under it.
    @Test func noEditsWhileAnOperationRuns() async throws {
        let url = try makeArchiveFile()
        let added = try makeFileToAdd()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: added)
        }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            document.state.selection = ["src"]
            document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)

            #expect(!actions.canAdd)
            #expect(!actions.canRemoveSelection)
            // Nor a second operation over the save's progress sheet.
            #expect(!actions.canExtract)
            // Nor opening or previewing.
            #expect(!actions.canOpen(["src"]) && !actions.canOpenSelection && !actions.canToggleQuickLook)
            #expect(!actions.addDropped([added], to: ""))
            #expect(!actions.addDropped([added], to: "assets"))
            actions.add([added], to: "")
            actions.removeSelection()
            #expect(document.model?.hasChanges == false)

            document.state.progress = nil
            #expect(actions.canAdd)
            #expect(actions.canExtract)
            #expect(actions.canOpenSelection && actions.canToggleQuickLook)
            #expect(actions.addDropped([added], to: ""))
            #expect(document.model?.hasChanges == true)
        }
    }

    /// Deleting a folder also drops anything selected inside it from the selection.
    @Test func removeDropsSelectedDescendants() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            document.state.selection = ["src/main.swift", "src/utils.swift", "assets/cover.png", "README.md"]
            actions.remove(["src"])
            #expect(document.model?.changes.removedPaths == ["src"])
            #expect(document.state.selection == ["assets/cover.png", "README.md"])
        }
    }

    /// A document whose model reads `entries`, with no file behind it.
    private func makeDocument(entries: [ArchiveEntry], format: ArchiveFormat = .zip) -> ArchiveDocument {
        let document = ArchiveDocument()
        document.state.model = ArchiveModel(reader: FakeReader(entries: entries, format: format),
                                            undoManager: document.undoManager)
        return document
    }

    private func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    private func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }

    /// A selected path stays selected unless it is a removed path or inside one; a shared name
    /// prefix ("a" and "ab") is not "inside".
    @Test func removeKeepsSiblingsWithASharedPrefixSelected() {
        let document = makeDocument(entries: [file("a/x"), file("a/y/z"), file("ab/x"), file("c")])
        let actions = ArchiveActions(document: document)
        document.state.selection = ["a/x", "a/y", "a/y/z", "ab", "ab/x", "c"]

        actions.remove(["a"])

        #expect(document.model?.changes.removedPaths == ["a"])
        #expect(document.state.selection == ["ab", "ab/x", "c"])
    }

    /// A read-only format (RAR) offers neither Add nor Delete, and the commands change nothing.
    @Test func readOnlyArchiveDisablesAddAndDelete() {
        let document = makeDocument(entries: [folder("src"), file("src/a.txt"), file("b.txt")], format: .rar)
        let actions = ArchiveActions(document: document)
        document.state.selection = ["src"]

        #expect(!actions.canAdd)
        #expect(!actions.canRemoveSelection)
        #expect(actions.canExtract)

        actions.removeSelection()
        #expect(document.model?.hasChanges == false)
        #expect(document.state.selection == ["src"])

        let dropped = FileManager.default.temporaryDirectory.appendingPathComponent("dropped.txt")
        #expect(actions.addDropped([dropped], to: "") == false)
        #expect(document.model?.hasChanges == false)
    }

    /// Extraction asks only for the outermost selected paths, sorted.
    @Test func topmostDropsPathsInsideOtherSelectedPaths() {
        #expect(ArchiveActions.topmost(["c/d", "a/b/c", "ab/x", "a", "a/b", "ab"]) == ["a", "ab", "c/d"])
        #expect(ArchiveActions.topmost(["ab/x", "a"]) == ["a", "ab/x"])
        // "" is not a folder that covers anything.
        #expect(ArchiveActions.topmost(["", "a"]) == ["", "a"])
        #expect(ArchiveActions.topmost([]) == [])
    }

    /// ⌘A then Delete or Extract on a flat 50 000-entry archive stays fast on the main thread.
    @Test func fiftyThousandSelectedEntriesRemoveAndExtractFast() {
        let paths = (0..<50_000).map { "file\($0).txt" }
        let document = makeDocument(entries: paths.map(file))
        let actions = ArchiveActions(document: document)
        let all = Set(paths)
        document.state.selection = all

        var topmost: [String] = []
        let extractElapsed = ContinuousClock().measure {
            topmost = ArchiveActions.topmost(all)
        }
        let removeElapsed = ContinuousClock().measure {
            actions.removeSelection()
        }

        #expect(topmost.count == 50_000)
        #expect(document.model?.items.isEmpty == true)
        #expect(document.state.selection.isEmpty)
        // CI runners are 2-3x slower; the regressions these catch took 10-70 s.
        #expect(extractElapsed < .seconds(5))
        #expect(removeElapsed < .seconds(5))
    }

    /// Option-Extract falls back to the panel when the archive's folder can't be written.
    @Test func unwritableLocationErrorsFallBackToThePanel() {
        func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        func cocoa(_ code: CocoaError.Code, underlying: NSError? = nil) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: code.rawValue,
                    userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        #expect(ArchiveActions.isPermissionError(cocoa(.fileWriteNoPermission)))
        #expect(ArchiveActions.isPermissionError(cocoa(.fileWriteVolumeReadOnly)))
        #expect(ArchiveActions.isPermissionError(posix(EPERM)))
        #expect(ArchiveActions.isPermissionError(posix(EACCES)))
        #expect(ArchiveActions.isPermissionError(posix(EROFS)))
        #expect(ArchiveActions.isPermissionError(cocoa(.fileWriteUnknown, underlying: posix(EROFS))))
        #expect(!ArchiveActions.isPermissionError(cocoa(.fileWriteOutOfSpace)))
        #expect(!ArchiveActions.isPermissionError(posix(ENOSPC)))
        #expect(!ArchiveActions.isPermissionError(ArchiveError.cancelled))
    }

    /// Quick Look and Open take items in the window's order, folders first, a folder before its contents.
    @Test func selectionIsOrderedLikeTheWindow() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            let paths: Set = ["README.md", "src/main.swift", "assets", "brief.pdf", "src", "missing"]
            #expect(actions.ordered(paths) == ["assets", "src", "src/main.swift", "brief.pdf", "README.md"])

            document.state.sortOrder = [KeyPathComparator(\.name, comparator: .localizedStandard, order: .reverse)]
            #expect(actions.ordered(paths) == ["src", "src/main.swift", "assets", "README.md", "brief.pdf"])
        }
    }

    // MARK: - Quick Look arrow keys

    /// ↓ (125) and ↑ (126) move the preview, with the function and numeric-pad flags arrow keys
    /// always carry; any other key or a modifier is not a step.
    @Test func previewArrowKeysMoveOneRow() {
        let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
        #expect(ArchiveActions.previewStep(keyCode: 125, modifierFlags: arrowFlags) == 1)
        #expect(ArchiveActions.previewStep(keyCode: 126, modifierFlags: arrowFlags) == -1)
        #expect(ArchiveActions.previewStep(keyCode: 125, modifierFlags: []) == 1)
        #expect(ArchiveActions.previewStep(keyCode: 126, modifierFlags: arrowFlags.union(.capsLock)) == -1)
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            #expect(ArchiveActions.previewStep(keyCode: 125, modifierFlags: arrowFlags.union(modifier)) == nil)
        }
        // ← → Space Return
        for keyCode: UInt16 in [123, 124, 49, 36] {
            #expect(ArchiveActions.previewStep(keyCode: keyCode, modifierFlags: arrowFlags) == nil)
        }
    }

    /// ↓ goes below the last selected row and ↑ above the first; nothing past either end.
    @Test func previewStepFindsTheNextVisibleRow() {
        let rows = ["a", "b", "c"]
        #expect(ArchiveActions.row(movedBy: 1, from: ["a"], in: rows) == "b")
        #expect(ArchiveActions.row(movedBy: -1, from: ["b"], in: rows) == "a")
        #expect(ArchiveActions.row(movedBy: 1, from: ["a", "b"], in: rows) == "c")
        #expect(ArchiveActions.row(movedBy: -1, from: ["b", "c"], in: rows) == "a")
        #expect(ArchiveActions.row(movedBy: 1, from: ["c"], in: rows) == nil)
        #expect(ArchiveActions.row(movedBy: -1, from: ["a"], in: rows) == nil)
        // No visible row selected (e.g. inside a closed folder): start from an end.
        #expect(ArchiveActions.row(movedBy: 1, from: ["hidden"], in: rows) == "a")
        #expect(ArchiveActions.row(movedBy: -1, from: [], in: rows) == "c")
        #expect(ArchiveActions.row(movedBy: 1, from: [], in: []) == nil)
    }

    /// The rows ↑/↓ walk are the table's: sorted, folders first, open folders' contents under
    /// them, and only search results while searching.
    @Test func visibleRowsMatchTheTable() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            let state = document.state
            #expect(actions.visibleRows() == ["assets", "src", "brief.pdf", "README.md"])

            state.expanded = ["src"]
            #expect(actions.visibleRows() == ["assets", "src", "src/main.swift", "src/utils.swift",
                                              "brief.pdf", "README.md"])

            state.sortOrder = [KeyPathComparator(\.name, comparator: .localizedStandard, order: .reverse)]
            #expect(actions.visibleRows() == ["src", "src/utils.swift", "src/main.swift", "assets",
                                              "README.md", "brief.pdf"])

            state.searchText = "main"
            #expect(actions.visibleRows() == ["src", "src/main.swift"])
        }
    }

    /// ↓ in the preview window selects the next row and the open preview follows it; ↑ goes back.
    @Test func previewFollowsTheSelection() async throws {
        try await PresentedErrors.expectingNone {
            let url = try makeArchiveFile()
            defer { try? FileManager.default.removeItem(at: url) }
            try await withEngine(FakeEngine(.succeed)) {
                let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
                let actions = ArchiveActions(document: document)
                let state = document.state
                defer { actions.cancelAll() }

                // Without a preview, selecting never starts one.
                state.selection = ["brief.pdf"]
                actions.selectionDidChange()
                #expect(!actions.hasRunningTasks)
                #expect(state.previewURL == nil)

                actions.toggleQuickLook()
                try await waitUntil { state.previewURL?.lastPathComponent == "brief.pdf" }

                actions.movePreviewSelection(by: 1)
                #expect(state.selection == ["README.md"])
                actions.selectionDidChange()
                try await waitUntil { state.previewURL?.lastPathComponent == "README.md" }
                #expect(state.previewURLs.map(\.lastPathComponent) == ["README.md"])

                // Past the last row nothing moves.
                actions.movePreviewSelection(by: 1)
                #expect(state.selection == ["README.md"])

                actions.movePreviewSelection(by: -1)
                #expect(state.selection == ["brief.pdf"])
            }
        }
    }

    private func makeSheet() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                 backing: .buffered, defer: true)
    }

    /// Sheets attach only to windows on screen; this one is on screen but fully transparent.
    private func attach(_ sheet: NSWindow, to window: NSWindow) async throws {
        window.alphaValue = 0
        window.orderFront(nil)
        window.beginSheet(sheet, completionHandler: nil)
        try await waitUntil { window.attachedSheet === sheet }
    }

    /// Waits for `condition` and returns as soon as it holds; the long limit only ends a hang.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func whenNoSheetAttachedWaitsForTheSheet() async throws {
        let window = makeSheet()
        var ran = false
        window.whenNoSheetAttached { ran = true }
        #expect(ran, "runs at once without a sheet")

        let sheet = makeSheet()
        try await attach(sheet, to: window)
        ran = false
        window.whenNoSheetAttached { ran = true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ran)

        window.endSheet(sheet)
        try await waitUntil { ran }
        window.orderOut(nil)
    }

    /// ⌘⌫ with an alert up deletes nothing: the alert is key and the archive window main,
    /// so the nil-target Edit > Delete reaches the archive window. Its controller disables the item, and
    /// `removeSelection` (also what SwiftUI's `onDeleteCommand` runs) waits for the sheet to end.
    @Test func commandDeleteWaitsForTheSheet() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await withEngine(FakeEngine(.succeed)) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            document.makeWindowControllers()
            defer { document.close() }
            let controller = try #require(document.windowControllers.first as? ArchiveWindowController)
            let window = try #require(controller.window)
            defer { window.orderOut(nil) }
            let delete = NSMenuItem(title: "Delete", action: #selector(ArchiveWindowController.delete(_:)),
                                    keyEquivalent: "")
            document.state.selection = ["src"]
            #expect(controller.validateMenuItem(delete))

            let sheet = makeSheet()
            try await attach(sheet, to: window)
            #expect(!controller.validateMenuItem(delete))
            controller.delete(nil)
            document.actions?.removeSelection()
            #expect(document.model?.changes.removedPaths.isEmpty == true)
            #expect(document.state.selection == ["src"])

            window.endSheet(sheet)
            try await waitUntil { window.attachedSheet == nil }
            #expect(controller.validateMenuItem(delete))
            controller.delete(nil)
            #expect(document.model?.changes.removedPaths == ["src"])
        }
    }

    /// NSDocument presents a save error as a sheet, which AppKit drops while the progress sheet
    /// is still attached: the error is reported only once that sheet has ended.
    @Test func failedSaveReportsAfterTheSheetEnds() async throws {
        let url = try makeArchiveFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeEngine(.succeed, write: .fail(.io("disk full")))
        try await withEngine(fake) {
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.zip-archive")
            document.makeWindowControllers()
            defer { document.close() }
            let window = try #require(document.windowControllers.first?.window)
            // Stands in for SwiftUI's progress sheet, which ends a moment after `progress` clears.
            let sheet = makeSheet()
            try await attach(sheet, to: window)

            var finished = false
            let saving = Task {
                defer { finished = true }
                try await document.save(to: url, ofType: "public.zip-archive", for: .saveOperation)
            }
            try await waitUntil { fake.writes.count == 1 && document.state.progress == nil }
            try await Task.sleep(for: .milliseconds(200))
            #expect(!finished)

            window.endSheet(sheet)
            let result = await saving.result
            #expect(throws: (any Error).self) { try result.get() }
        }
    }

    @Test func autosaveIsOff() {
        #expect(ArchiveDocument.autosavesInPlace == false)
        #expect(ArchiveDocument.preservesVersions == false)
        #expect(ArchiveDocument.canConcurrentlyReadDocuments(ofType: "public.zip-archive"))
    }

    /// While an operation shows the progress sheet, Undo/Redo act on an empty gated
    /// manager (AppKit would swap in its own for nil); the document's undo stack is untouched.
    @Test func undoIsGatedWhileAnOperationRuns() throws {
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? ArchiveWindowController)
        let window = try #require(controller.window)
        let documentManager = try #require(document.undoManager)
        documentManager.beginUndoGrouping()
        documentManager.registerUndo(withTarget: document) { _ in }
        documentManager.endUndoGrouping()
        #expect(documentManager.canUndo)
        #expect(window.undoManager === document.undoManager)

        document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        #expect(window.undoManager !== document.undoManager)
        #expect(window.undoManager?.canUndo == false)
        #expect(window.undoManager?.canRedo == false)
        #expect(documentManager.canUndo)
        // Same gated instance on every call, with registration disabled (not AppKit's fallback manager).
        let gated = window.undoManager
        #expect(window.undoManager === gated)
        // A registration with no group open (as a text view's typing outside an event) neither throws nor
        // keeps anything; the manager still groups by event, as any real key's event needs.
        #expect(gated?.groupsByEvent == true)
        #expect(gated?.groupingLevel == 0)
        gated?.registerUndo(withTarget: document) { _ in }
        #expect(gated?.canUndo == false)

        document.state.progress = nil
        #expect(window.undoManager === document.undoManager)
    }
}
