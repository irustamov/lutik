import Foundation
import Testing
import KernirCore
@testable import Kernir

/// `PlainSaveChoice`: the per-file Mac metadata choice over the shared plain-save options. Each case
/// expects concrete options, never the shared helper's output, so a helper that ignores the choice,
/// or only half applies it, goes red. No document or engine seam: runs in parallel. The same file
/// runs in a macOS SwiftPM mirror (App/Shared + PlainSaveChoice.swift).
@MainActor struct PlainSaveChoiceTests {
    private static let stripEncrypted = ArchiveWriteOptions(encryption: .aes256, password: "kernir",
                                                            excludesMacMetadata: true)

    private func plainModel() -> ArchiveModel {
        ArchiveModel(reader: FakeReader.sample(), undoManager: nil)
    }

    private func encryptedSevenZipModel() -> ArchiveModel {
        let reader = FakeReader(entries: FakeReader.sample().entries, format: .sevenZip, isEncrypted: true)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        model.password = "kernir"
        return model
    }

    /// A new encrypted archive: an empty listing, so only its creation options keep it encrypted.
    private func newArchiveModel(excludes: Bool) -> (ArchiveModel, ArchiveWriteOptions) {
        let model = ArchiveModel(reader: FakeReader(entries: []), undoManager: nil)
        let saved = ArchiveWriteOptions(method: .deflate, encryption: .aes256, password: "kernir",
                                        excludesMacMetadata: excludes)
        model.apply(ArchiveSaveSettings(format: .zip, options: saved))
        return (model, saved)
    }

    // MARK: - Keep (choice false)

    /// Keep, no saved options: nil, the source's settings, nothing stripped, whatever the default.
    @Test(arguments: [false, true]) func keepWritesNilOptionsForAnOpenedArchive(_ defaultExcludes: Bool) {
        #expect(PlainSaveChoice.plainSaveOptions(for: plainModel(), choice: false, default: defaultExcludes) == nil)
    }

    /// The same for an unlocked encrypted 7z: nil keeps its encryption and password (the reader's).
    /// Strip: its encryption with the password that unlocked it.
    @Test(arguments: [false, true]) func keepOnAnEncryptedSevenZipWritesNilOptions(_ defaultExcludes: Bool) {
        let model = encryptedSevenZipModel()
        #expect(PlainSaveChoice.plainSaveOptions(for: model, choice: false, default: defaultExcludes) == nil)
        #expect(PlainSaveChoice.plainSaveOptions(for: model, choice: true, default: defaultExcludes)
            == Self.stripEncrypted)
    }

    // MARK: - Strip (choice true)

    /// Strip, no saved options: explicit options that strip, with the source's settings, even with
    /// the app's default off.
    @Test(arguments: [false, true]) func stripWritesTheSourcesSettingsWhateverTheDefault(_ defaultExcludes: Bool) {
        #expect(PlainSaveChoice.plainSaveOptions(for: plainModel(), choice: true, default: defaultExcludes)
            == ArchiveWriteOptions(excludesMacMetadata: true))
    }

    // MARK: - Saved options (a new archive's)

    /// The choice beats the creation flag either way; method, encryption and password stay.
    @Test(arguments: [false, true]) func choiceOverridesNewArchiveCreationFlag(_ excludes: Bool) {
        let (model, saved) = newArchiveModel(excludes: excludes)
        var flipped = saved
        flipped.excludesMacMetadata = !excludes
        for defaultExcludes in [false, true] {
            #expect(PlainSaveChoice.plainSaveOptions(for: model, choice: !excludes, default: defaultExcludes)
                == flipped)
            #expect(PlainSaveChoice.plainSaveOptions(for: model, choice: excludes, default: defaultExcludes)
                == saved)
            #expect(PlainSaveChoice.effectiveExcludes(for: model, choice: !excludes, default: defaultExcludes)
                == !excludes)
        }
        #expect(model.saveOptions == saved, "the choice never changes the model's saved options")
    }

    // MARK: - No choice (nil)

    /// No choice: unchanged from the shared plain save. Saved options as they are, else the default.
    @Test(arguments: [false, true]) func noChoiceFollowsSavedOptionsElseTheDefault(_ excludes: Bool) {
        let (model, saved) = newArchiveModel(excludes: excludes)
        for defaultExcludes in [false, true] {
            #expect(PlainSaveChoice.plainSaveOptions(for: model, choice: nil, default: defaultExcludes) == saved)
            #expect(PlainSaveChoice.effectiveExcludes(for: model, choice: nil, default: defaultExcludes) == excludes)
        }
        #expect(PlainSaveChoice.plainSaveOptions(for: encryptedSevenZipModel(), choice: nil, default: true)
            == Self.stripEncrypted)
        #expect(PlainSaveChoice.plainSaveOptions(for: encryptedSevenZipModel(), choice: nil, default: false) == nil)
    }

    // MARK: - Effective value

    /// What a save would do, as a Bool: the choice when set, else the default; nil options never strip.
    @Test func effectiveExcludesIsWhatTheSaveWrites() {
        let model = plainModel()
        for defaultExcludes in [false, true] {
            #expect(PlainSaveChoice.effectiveExcludes(for: model, choice: false, default: defaultExcludes) == false)
            #expect(PlainSaveChoice.effectiveExcludes(for: model, choice: true, default: defaultExcludes) == true)
            #expect(PlainSaveChoice.effectiveExcludes(for: model, choice: nil, default: defaultExcludes)
                == defaultExcludes)
        }
    }

    // MARK: - Live engine

    /// End to end with the real engine on `Fixtures/zip/macos-finder.zip` plus a `.DS_Store`: one
    /// ordinary file removed and saved. Keep leaves the `__MACOSX` tree, the `._*` files and the
    /// `.DS_Store` in the archive; strip, or no choice with the default on, takes them out.
    @Test(arguments: [false, true]) func keepLeavesExistingMacMetadataInTheArchive(_ keeps: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainSaveChoiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await Self.finderZipWithDSStore(in: folder)
        let before = try await Archive.open(at: source).entries.map(\.path)
        #expect(before.contains("Project/.DS_Store"))
        #expect(before.contains("__MACOSX/Project/docs/._readme.md"))

        for choice in [!keeps, nil] as [Bool?] {
            let model = ArchiveModel(reader: try await Archive.open(at: source), undoManager: nil)
            model.remove(["Project/hello.txt"])
            let options = PlainSaveChoice.plainSaveOptions(for: model, choice: choice, default: true)
            let saved = folder.appendingPathComponent("saved-\(UUID().uuidString).zip")
            try await ArchiveWriter.write(source: model.reader, changes: model.changes, format: model.format,
                                          to: saved, options: options)
            let paths = try await Archive.open(at: saved).entries.map(\.path)
            let kept = choice == false
            #expect(paths.contains("Project/docs/readme.md"))
            #expect(!paths.contains("Project/hello.txt"))
            #expect(paths.contains("Project/.DS_Store") == kept, "choice \(String(describing: choice))")
            #expect(paths.contains("__MACOSX/Project/docs/._readme.md") == kept, "choice \(String(describing: choice))")
            #expect(paths.contains("__MACOSX/Project/._docs") == kept, "choice \(String(describing: choice))")
            #expect(paths.contains { $0.hasPrefix("__MACOSX") } == kept, "choice \(String(describing: choice))")
        }
    }

    /// A copy of macos-finder.zip (`__MACOSX` and `._*`, no `.DS_Store`) with `Project/.DS_Store`
    /// added. The engine skips a `.DS_Store` by its name on disk, so the file goes in under another
    /// name and takes `.DS_Store` as its archive name; nil options never strip.
    private static func finderZipWithDSStore(in folder: URL) async throws -> URL {
        let fixture = try Fixture.copy("zip/macos-finder.zip")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let dsStore = folder.appendingPathComponent("DS_Store-source")
        try Data([0x00, 0x00, 0x00, 0x01, 0x42, 0x75, 0x64, 0x31]).write(to: dsStore)
        let result = folder.appendingPathComponent("macos-finder-ds.zip")
        let changes = ArchiveChangeSet(additions: [
            .init(sourceURL: dsStore, destinationDirectory: "Project", archiveName: ".DS_Store"),
        ])
        try await ArchiveWriter.write(source: try await Archive.open(at: fixture), changes: changes,
                                      format: .zip, to: result, options: nil)
        return result
    }
}
