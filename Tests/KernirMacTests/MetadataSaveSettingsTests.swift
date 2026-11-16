import Testing
import Foundation
@testable import Kernir
import KernirCore

/// "Exclude Mac metadata" in the save options. A panel starts with the default,
/// `model.apply` keeps the choice in `saveOptions`, and every later save uses it, plain ⌘S
/// included: with it on, the engine leaves out metadata already in the archive as well as in the
/// additions (the live check is `LiveMetadataSaveTests`).
@MainActor
struct MetadataSaveSettingsTests {
    private func readerModel() -> ArchiveModel {
        ArchiveModel(reader: FakeReader(entries: SampleArchive().entries), undoManager: nil)
    }

    /// It is on by default, which the engine's metadata filter makes safe. This target is
    /// macOS-only; the iOS default stays off until the iOS side lands.
    @Test func theDefaultIsOn() {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault)
    }

    @Test(arguments: [false, true])
    func aNewDocumentStartsWithTheDefault(_ value: Bool) {
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        #expect(ArchiveSaveSettings(model: model, defaultExcludesMacMetadata: value).options.excludesMacMetadata == value)
        #expect(ArchiveSaveSettings(model: model).options.excludesMacMetadata
            == ArchiveSaveSettings.excludesMacMetadataByDefault)
    }

    @Test(arguments: [false, true])
    func anOpenedArchiveStartsWithTheDefault(_ value: Bool) {
        let model = readerModel()
        #expect(ArchiveSaveSettings(model: model, defaultExcludesMacMetadata: value).options.excludesMacMetadata == value)
        #expect(ArchiveSaveSettings(model: model).options.excludesMacMetadata
            == ArchiveSaveSettings.excludesMacMetadataByDefault)
    }

    /// The choice last saved with wins over the default, either way.
    @Test(arguments: [false, true])
    func savedOptionsKeepTheirChoice(_ saved: Bool) {
        let model = readerModel()
        model.apply(ArchiveSaveSettings(format: .zip, options: ArchiveWriteOptions(excludesMacMetadata: saved)))
        #expect(ArchiveSaveSettings(model: model, defaultExcludesMacMetadata: !saved).options.excludesMacMetadata
            == saved)
    }

    /// It applies to every writable format, so changing the format never touches it.
    @Test(arguments: [false, true])
    func changingTheFormatKeepsIt(_ value: Bool) {
        var settings = ArchiveSaveSettings(format: .zip, options: ArchiveWriteOptions(excludesMacMetadata: value))
        for format in [ArchiveFormat.tarGzip, .sevenZip, .tar, .zip] {
            settings.format = format
            settings.formatDidChange()
            #expect(settings.options.excludesMacMetadata == value)
        }
        #expect(ArchiveFormat.writable.allSatisfy { format in
            var settings = ArchiveSaveSettings(format: format, options: ArchiveWriteOptions(excludesMacMetadata: value))
            settings.formatDidChange()
            return settings.options.excludesMacMetadata == value
        })
    }

    @Test func itIsNeverAProblem() {
        let settings = ArchiveSaveSettings(format: .tar, options: ArchiveWriteOptions(excludesMacMetadata: true))
        #expect(settings.problems.isEmpty)
    }

    /// By design, on in a panel means on for every later save, plain ⌘S included. ⌘S writes
    /// with `model.saveOptions` (`ArchiveDocument.save(to:ofType:for:completionHandler:)`, iOS
    /// `ArchiveDocument`), and the engine then drops metadata already in the archive too.
    @Test func applyKeepsItForEveryLaterSave() {
        let model = readerModel()
        var settings = ArchiveSaveSettings(model: model, defaultExcludesMacMetadata: false)
        settings.options.excludesMacMetadata = true
        model.apply(settings)
        #expect(model.saveOptions?.excludesMacMetadata == true)
        // The next panel starts from it as well.
        #expect(ArchiveSaveSettings(model: model, defaultExcludesMacMetadata: false).options.excludesMacMetadata)

        settings.options.excludesMacMetadata = false
        model.apply(settings)
        #expect(model.saveOptions?.excludesMacMetadata == false)
    }

    /// An archive no panel has saved writes with nil options on ⌘S: the engine's plain save,
    /// which keeps what is in the archive (the setting was never shown, so it isn't on).
    @Test func aModelNoPanelSavedHasNoSaveOptions() {
        #expect(readerModel().saveOptions == nil)
        #expect(ArchiveModel(newArchiveFormat: .zip, undoManager: nil).saveOptions == nil)
    }
}
