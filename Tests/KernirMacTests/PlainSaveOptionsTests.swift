import Testing
import Foundation
@testable import Kernir
import KernirCore

/// A plain save, with no panel settings, follows
/// the app's "Exclude Mac metadata" default, for metadata already in the archive and for added
/// files, even when no panel has ever saved the document (`saveOptions == nil`). The panel's
/// options win over everything; options a panel saved keep their choice. Mac and iOS both
/// write with `ArchiveSaveSettings.writeOptions(for:panelOptions:defaultExcludesMacMetadata:)`.
@MainActor
struct PlainSaveOptionsTests {
    private func readerModel(encryption: ArchiveEncryption = .none,
                             method: ArchiveCompressionMethod? = .deflate,
                             password: String? = nil) -> ArchiveModel {
        let reader = FakeReader(entries: SampleArchive().entries, isEncrypted: encryption != .none,
                                encryption: encryption, compressionMethod: method)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        model.password = password
        return model
    }

    private static let panelOptions = ArchiveWriteOptions(method: .store, compressionLevel: 3,
                                                          encryption: .aes256, password: "panel",
                                                          excludesMacMetadata: false)

    // MARK: - The panel wins

    /// A save from the panel writes with the panel's options as they are, whatever the model
    /// saved before and whatever the default says.
    @Test(arguments: [false, true], [false, true])
    func thePanelsOptionsWinOverEverything(_ defaultOn: Bool, _ panelSavedBefore: Bool) {
        let model = readerModel()
        if panelSavedBefore {
            model.apply(ArchiveSaveSettings(format: .zip, options: ArchiveWriteOptions(excludesMacMetadata: !defaultOn)))
        }
        for panel in [Self.panelOptions, ArchiveWriteOptions(excludesMacMetadata: true)] {
            #expect(ArchiveSaveSettings.writeOptions(for: model, panelOptions: panel,
                                                     defaultExcludesMacMetadata: defaultOn) == panel)
        }
    }

    // MARK: - Options a panel saved

    /// Once a panel saved the document, a plain save keeps that choice either way,
    /// with every other option it saved.
    @Test(arguments: [false, true])
    func savedOptionsKeepTheirChoice(_ saved: Bool) throws {
        let model = readerModel()
        model.apply(ArchiveSaveSettings(format: .zip, options: ArchiveWriteOptions(method: .store,
                                                                                   excludesMacMetadata: saved)))
        let expected = try #require(model.saveOptions)
        for defaultOn in [false, true] {
            #expect(ArchiveSaveSettings.writeOptions(for: model, defaultExcludesMacMetadata: defaultOn) == expected)
        }
        #expect(ArchiveSaveSettings.writeOptions(for: model) == expected)
    }

    // MARK: - No panel ever saved (`saveOptions == nil`)

    /// Default off: nil, today's plain save, which keeps the source's settings and never strips
    /// (a byte-identical round trip).
    @Test func noSavedOptionsAndTheDefaultOffKeepTheSourcesSettings() {
        let model = readerModel(encryption: .aes256, password: "secret")
        #expect(model.saveOptions == nil)
        #expect(ArchiveSaveSettings.writeOptions(for: model, defaultExcludesMacMetadata: false) == nil)
        #expect(ArchiveSaveSettings.writeOptions(for: ArchiveModel(newArchiveFormat: .zip, undoManager: nil),
                                                 defaultExcludesMacMetadata: false) == nil)
    }

    /// Default on: explicit options that strip and otherwise say what nil options would resolve
    /// to: the source's method, encryption and password; no level, solid or volume size.
    @Test func noSavedOptionsAndTheDefaultOnStripWithTheSourcesSettings() throws {
        let model = readerModel(encryption: .aes256, method: .deflate, password: "secret")
        let options = try #require(ArchiveSaveSettings.writeOptions(for: model, defaultExcludesMacMetadata: true))
        #expect(options == ArchiveWriteOptions(method: .deflate, encryption: .aes256, password: "secret",
                                               excludesMacMetadata: true))
        #expect(options.compressionLevel == nil)
        #expect(options.solid == nil)
        #expect(options.volumeSize == nil)
    }

    /// An archive that isn't encrypted carries no password, even one the document holds.
    @Test func anUnencryptedSourceCarriesNoPassword() throws {
        let model = readerModel(encryption: .none, method: nil, password: "stale")
        let options = try #require(ArchiveSaveSettings.writeOptions(for: model, defaultExcludesMacMetadata: true))
        #expect(options == ArchiveWriteOptions(excludesMacMetadata: true))
    }

    /// A document with no source archive (a new one) strips with the format's defaults.
    @Test func aNewArchiveWithTheDefaultOnStrips() {
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        #expect(ArchiveSaveSettings.writeOptions(for: model, defaultExcludesMacMetadata: true)
            == ArchiveWriteOptions(excludesMacMetadata: true))
    }

    // MARK: - Saved into another format (`targetFormat`)

    /// A format that can't carry the source's encryption but has AES-256 gets AES-256, as nil
    /// options would give it: a ZipCrypto zip saved as 7z, with the document's password, still
    /// stripping.
    @Test(arguments: [ArchiveEncryption.zipCrypto, .aes128])
    func aWeakZipSavedAs7zGetsAES256(_ encryption: ArchiveEncryption) throws {
        let model = readerModel(encryption: encryption, method: .deflate, password: "secret")
        let options = try #require(ArchiveSaveSettings.writeOptions(for: model, targetFormat: .sevenZip,
                                                                    defaultExcludesMacMetadata: true))
        #expect(options == ArchiveWriteOptions(method: .deflate, encryption: .aes256, password: "secret",
                                               excludesMacMetadata: true))
    }

    /// A format with no encryption at all keeps the source's, so the engine refuses
    /// (`unsupportedEncryption`) where nil options would write a plaintext tar.
    @Test(arguments: [ArchiveEncryption.zipCrypto, .aes128, .aes256])
    func anEncryptedZipSavedAsTarKeepsItsEncryption(_ encryption: ArchiveEncryption) throws {
        let model = readerModel(encryption: encryption, password: "secret")
        let options = try #require(ArchiveSaveSettings.writeOptions(for: model, targetFormat: .tar,
                                                                    defaultExcludesMacMetadata: true))
        #expect(options.encryption == encryption)
        #expect(options.password == "secret")
    }

    /// An encryption the target carries stays as it is, the source's own format (nil) included.
    @Test func anEncryptionTheTargetCarriesStays() throws {
        let zipCrypto = readerModel(encryption: .zipCrypto, password: "secret")
        for target in [nil, ArchiveFormat.zip] {
            let options = ArchiveSaveSettings.writeOptions(for: zipCrypto, targetFormat: target,
                                                           defaultExcludesMacMetadata: true)
            #expect(options?.encryption == .zipCrypto)
        }
        let aes = readerModel(encryption: .aes256, password: "secret")
        #expect(ArchiveSaveSettings.writeOptions(for: aes, targetFormat: .sevenZip,
                                                 defaultExcludesMacMetadata: true)?.encryption == .aes256)
        let plain = readerModel()
        #expect(ArchiveSaveSettings.writeOptions(for: plain, targetFormat: .tar, defaultExcludesMacMetadata: true)
            == ArchiveWriteOptions(method: .deflate, excludesMacMetadata: true))
    }

    /// No default passed: the app's own (`excludesMacMetadataByDefault`, on for macOS).
    @Test func withoutADefaultItFollowsTheApps() {
        let model = readerModel()
        let options = ArchiveSaveSettings.writeOptions(for: model)
        #expect(options == ArchiveSaveSettings.writeOptions(
            for: model, defaultExcludesMacMetadata: ArchiveSaveSettings.excludesMacMetadataByDefault))
        #if os(macOS)
        #expect(options?.excludesMacMetadata == true)
        #endif
    }
}

/// The same through the real engine (`ArchiveEngine.live`), no UI: what a plain ⌘S of a document
/// no panel has saved writes, with the default on and off.
struct LivePlainSaveOptionsTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePlainSaveOptionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Files in a folder `name` of `directory`, each added on its own: `<file>` and `._<file>` at the
    /// top, and `._<file>` again into a top `__MACOSX` folder. (Foundation never lists a `._*` file
    /// inside an added folder, so each is added by itself; `.DS_Store` is always skipped.)
    private func additions(_ name: String, file: String, in directory: URL) throws -> ArchiveChangeSet {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = folder.appendingPathComponent(file)
        let appleDouble = folder.appendingPathComponent("._" + file)
        try Data(file.utf8).write(to: plain)
        try Data("apple double".utf8).write(to: appleDouble)
        return ArchiveChangeSet(additions: [.init(sourceURL: plain, destinationDirectory: ""),
                                            .init(sourceURL: appleDouble, destinationDirectory: ""),
                                            .init(sourceURL: appleDouble, destinationDirectory: "__MACOSX")])
    }

    private static let sourcePaths: Set<String> = ["hello.txt", "._hello.txt", "__MACOSX/._hello.txt"]
    private static let addedPaths: Set<String> = ["a.txt", "._a.txt", "__MACOSX/._a.txt"]

    /// `source.zip`, written by the engine with the metadata in it; encrypted with `encryption` when
    /// `password` is set.
    private func makeSource(in directory: URL, password: String? = nil,
                            encryption: ArchiveEncryption = .aes256) async throws -> URL {
        let url = directory.appendingPathComponent("source.zip")
        let options = ArchiveWriteOptions(encryption: password == nil ? .none : encryption, password: password)
        try await ArchiveEngine.live.write(nil, try additions("source-files", file: "hello.txt", in: directory),
                                           .zip, url, options, nil)
        return url
    }

    /// What a plain save of a never-panel-saved document writes as `format`: the options come from
    /// its model.
    private func plainSave(of reader: any ArchiveReading, password: String?, defaultOn: Bool,
                           changes: ArchiveChangeSet, to url: URL, as format: ArchiveFormat = .zip) async throws {
        let options = await MainActor.run {
            let model = ArchiveModel(reader: reader, undoManager: nil)
            model.password = password
            return ArchiveSaveSettings.writeOptions(for: model, targetFormat: format,
                                                    defaultExcludesMacMetadata: defaultOn)
        }
        try await ArchiveEngine.live.write(reader, changes, format, url, options, nil)
    }

    private func files(in url: URL, password: String? = nil) async throws -> Set<String> {
        Set(try await ArchiveEngine.live.open(url, password).entries.filter { !$0.isDirectory }.map(\.path))
    }

    @Test func theSourceHoldsItsMetadata() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await files(in: try await makeSource(in: directory)) == Self.sourcePaths)
    }

    /// Default on: metadata goes from the archive and from the added files, with no panel ever shown.
    @Test func aPlainSaveWithTheDefaultOnStripsTheArchiveAndTheAdditions() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await ArchiveEngine.live.open(try await makeSource(in: directory), nil)
        let changes = try additions("added", file: "a.txt", in: directory)
        let saved = directory.appendingPathComponent("saved.zip")

        try await plainSave(of: reader, password: nil, defaultOn: true, changes: changes, to: saved)
        #expect(try await files(in: saved) == ["hello.txt", "a.txt"])
    }

    /// Default off: exactly today's nil-options save, which keeps every bit of metadata.
    @Test func aPlainSaveWithTheDefaultOffKeepsMetadata() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await ArchiveEngine.live.open(try await makeSource(in: directory), nil)
        let changes = try additions("added", file: "a.txt", in: directory)
        let saved = directory.appendingPathComponent("saved.zip")
        let reference = directory.appendingPathComponent("reference.zip")

        try await plainSave(of: reader, password: nil, defaultOn: false, changes: changes, to: saved)
        try await ArchiveEngine.live.write(reader, changes, .zip, reference, nil, nil)
        #expect(try await files(in: saved) == Self.sourcePaths.union(Self.addedPaths))
        #expect(try await files(in: reference) == Self.sourcePaths.union(Self.addedPaths))
    }

    /// An encrypted source stays encrypted with its password, as a nil-options save keeps it.
    @Test func aPlainSaveWithTheDefaultOnKeepsTheSourcesEncryption() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await ArchiveEngine.live.open(try await makeSource(in: directory, password: "secret"),
                                                       "secret")
        #expect(reader.encryption == .aes256)
        let saved = directory.appendingPathComponent("saved.zip")

        try await plainSave(of: reader, password: "secret", defaultOn: true, changes: ArchiveChangeSet(), to: saved)
        let reopened = try await ArchiveEngine.live.open(saved, "secret")
        #expect(reopened.encryption == .aes256)
        #expect(try await files(in: saved, password: "secret") == ["hello.txt"])
    }

    /// A ZipCrypto zip saved as 7z (a zip named "x.7z": the Mac takes the format from the
    /// extension) comes out AES-256 with its password, as a nil-options save does, and stripped.
    @Test func aZipCryptoZipSavedAs7zIsAES256() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeSource(in: directory, password: "secret", encryption: .zipCrypto)
        let reader = try await ArchiveEngine.live.open(source, "secret")
        #expect(reader.encryption == .zipCrypto)
        let saved = directory.appendingPathComponent("saved.7z")
        let reference = directory.appendingPathComponent("reference.7z")

        try await plainSave(of: reader, password: "secret", defaultOn: true, changes: ArchiveChangeSet(),
                            to: saved, as: .sevenZip)
        try await ArchiveEngine.live.write(reader, ArchiveChangeSet(), .sevenZip, reference, nil, nil)
        #expect(try await ArchiveEngine.live.open(saved, "secret").encryption == .aes256)
        #expect(try await ArchiveEngine.live.open(reference, "secret").encryption == .aes256)
        #expect(try await files(in: saved, password: "secret") == ["hello.txt"])
    }

    /// An encrypted zip saved as tar still refuses and writes nothing: never a plaintext copy,
    /// which a nil-options save would write.
    @Test func anEncryptedZipSavedAsTarRefuses() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeSource(in: directory, password: "secret", encryption: .zipCrypto)
        let reader = try await ArchiveEngine.live.open(source, "secret")
        let saved = directory.appendingPathComponent("saved.tar")

        await #expect(throws: ArchiveError.unsupportedEncryption(.tar)) {
            try await plainSave(of: reader, password: "secret", defaultOn: true, changes: ArchiveChangeSet(),
                                to: saved, as: .tar)
        }
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }
}
