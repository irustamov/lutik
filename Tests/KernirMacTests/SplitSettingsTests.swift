import Testing
import Foundation
import KernirCore
@testable import Kernir

/// The split choice in the save settings. `split` drives `options.volumeSize` for a
/// format that can split (7z, ZIP), a split is never remembered from an earlier save, and a split
/// that can't be written is a problem after any encryption problem.
@MainActor
struct SplitSettingsTests {
    private func zipSettings(_ options: ArchiveWriteOptions = ArchiveWriteOptions()) -> ArchiveSaveSettings {
        ArchiveSaveSettings(format: .zip, options: options)
    }

    /// A typed amount in the current locale: "0.5" or "0,5".
    private func decimal(_ whole: Int, _ fraction: Int) -> String {
        "\(whole)\(Locale.current.decimalSeparator ?? ".")\(fraction)"
    }

    private func model(entries: [ArchiveEntry]) -> ArchiveModel {
        ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
    }

    private func file(_ path: String, size: Int64?, compressedSize: Int64?) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: compressedSize, modificationDate: nil)
    }

    // MARK: - volumeSize follows split

    @Test func volumeSizeMirrorsTheSplit() {
        var settings = zipSettings()
        #expect(settings.split == .none)
        #expect(settings.options.volumeSize == nil)
        for preset in VolumeSplit.Preset.allCases {
            settings.split = .preset(preset)
            #expect(settings.options.volumeSize == preset.bytes)
        }
        settings.split = .custom(amount: "2", unit: .mb)
        #expect(settings.options.volumeSize == 2_000_000)
        settings.split = .custom(amount: "3", unit: .gb)
        #expect(settings.options.volumeSize == 3_000_000_000)
        settings.split = .custom(amount: "abc", unit: .mb)
        #expect(settings.options.volumeSize == nil)
        settings.split = .preset(.mb100)
        settings.split = .none
        #expect(settings.options.volumeSize == nil)
    }

    /// A format that can't split never gets a volume size, whatever `split` says.
    @Test func aFormatThatCannotSplitGetsNoVolumeSize() {
        var settings = ArchiveSaveSettings(format: .tar, options: ArchiveWriteOptions())
        settings.split = .preset(.mb25)
        #expect(settings.options.volumeSize == nil)
        #expect(settings.problems.isEmpty)
    }

    /// A split a format can't write is no problem, even one that would be (under 1 MB), and even
    /// before `formatDidChange()` has dropped it: `problems` checks the format itself.
    @Test func aFormatThatCannotSplitHasNoSplitProblem() {
        var settings = ArchiveSaveSettings(format: .tar, options: ArchiveWriteOptions())
        settings.split = .custom(amount: decimal(0, 5), unit: .mb)
        #expect(settings.split != .none)
        #expect(settings.problems == [])
    }

    // MARK: - Format changes

    /// The memberwise init takes `options` as given, a `volumeSize` with `split == .none`
    /// included; `formatDidChange()` brings `volumeSize` back in line with `split`.
    @Test func formatDidChangeClearsAVolumeSizeTheSplitDoesNotHave() {
        var settings = zipSettings(ArchiveWriteOptions(volumeSize: 5_000_000))
        #expect(settings.split == .none)
        settings.formatDidChange()
        #expect(settings.options.volumeSize == nil)
    }

    @Test func switchingToAFormatThatCannotSplitClearsIt() {
        let others = ArchiveFormat.writable.filter { !$0.supportsVolumes }
        #expect(others.contains(.tar))
        for format in others {
            var settings = zipSettings()
            settings.split = .preset(.mb700)
            settings.format = format
            settings.formatDidChange()
            #expect(settings.split == .none)
            #expect(settings.options.volumeSize == nil)
        }
    }

    @Test func sevenZipAndZipKeepIt() {
        #expect(ArchiveFormat.sevenZip.supportsVolumes && ArchiveFormat.zip.supportsVolumes)
        var settings = zipSettings()
        settings.split = .custom(amount: "5", unit: .mb)
        for format in [ArchiveFormat.sevenZip, .zip, .sevenZip] {
            settings.format = format
            settings.formatDidChange()
            #expect(settings.split == .custom(amount: "5", unit: .mb))
            #expect(settings.options.volumeSize == 5_000_000)
        }
    }

    // MARK: - Never remembered

    @Test func savedOptionsWithAVolumeSizeNeverPrefill() {
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        model.apply(zipSettings(ArchiveWriteOptions(method: .store, volumeSize: 5_000_000)))
        let settings = ArchiveSaveSettings(model: model)
        #expect(settings.split == .none)
        #expect(settings.options.volumeSize == nil)
        // The rest of the saved choice still prefills.
        #expect(settings.options.method == .store)
    }

    @Test func anOpenedArchiveStartsUnsplit() {
        let settings = ArchiveSaveSettings(model: model(entries: SampleArchive().entries))
        #expect(settings.split == .none)
        #expect(settings.options.volumeSize == nil)
    }

    // MARK: - Estimated size

    @Test func theEstimateIsTheCompressedSize() {
        // SampleArchive's compressed sizes: 1 500 + 800 + 1 150 000 + 300 000 + 500.
        #expect(ArchiveSaveSettings(model: model(entries: SampleArchive().entries)).estimatedSize == 1_452_800)
    }

    @Test func theEstimateFallsBackToTheTotalSize() {
        let entries = [file("a", size: 3_000, compressedSize: nil), file("b", size: 2_000, compressedSize: 1_000)]
        #expect(ArchiveSaveSettings(model: model(entries: entries)).estimatedSize == 5_000)
    }

    @Test func theEstimateIsUnknownWithoutEitherSize() {
        let entries = [file("a", size: nil, compressedSize: nil)]
        #expect(ArchiveSaveSettings(model: model(entries: entries)).estimatedSize == nil)
    }

    @Test func aMemberwiseSettingsHasNoEstimate() {
        #expect(zipSettings().estimatedSize == nil)
    }

    // MARK: - Problems

    @Test func aVolumeUnderOneMegabyteIsAProblem() {
        var settings = zipSettings()
        settings.split = .custom(amount: decimal(0, 5), unit: .mb)
        #expect(settings.problems == [.volumeTooSmall])
        settings.split = .custom(amount: "1", unit: .mb)
        #expect(settings.problems == [])
    }

    @Test(arguments: ["", "abc", "-3", "0"])
    func anInvalidCustomSizeIsAProblem(_ amount: String) {
        var settings = zipSettings()
        settings.split = .custom(amount: amount, unit: .gb)
        #expect(settings.problems == [.volumeSizeInvalid])
    }

    @Test func moreThan999VolumesIsAProblem() {
        var settings = zipSettings()
        settings.split = .custom(amount: "1", unit: .mb)
        settings.estimatedSize = 999_000_000
        #expect(settings.problems == [])
        settings.estimatedSize = 999_000_001
        #expect(settings.problems == [.tooManyVolumes])
        settings.split = .custom(amount: "2", unit: .mb)
        #expect(settings.problems == [])
        settings.split = .custom(amount: "1", unit: .mb)
        settings.estimatedSize = nil
        #expect(settings.problems == [])
    }

    @Test func tooManyVolumesUsesTheModelsEstimate() {
        let entries = [file("big", size: 2_000_000_000, compressedSize: 1_000_000_000)]
        var settings = ArchiveSaveSettings(model: model(entries: entries))
        settings.split = .custom(amount: "1", unit: .mb)
        #expect(settings.problems == [.tooManyVolumes])
        settings.split = .preset(.mb25)
        #expect(settings.problems == [])
    }

    @Test func encryptionProblemsComeFirst() {
        var settings = zipSettings()
        settings.isEncrypting = true
        settings.split = .custom(amount: decimal(0, 5), unit: .mb)
        #expect(settings.problems == [.passwordEmpty, .volumeTooSmall])
        settings.options.password = "pw"
        #expect(settings.problems == [.passwordMismatch, .volumeTooSmall])
        settings.verifyPassword = "pw"
        #expect(settings.problems == [.volumeTooSmall])
    }

    @Test func noSplitIsNeverAProblem() {
        var settings = zipSettings()
        settings.estimatedSize = .max
        #expect(settings.problems == [])
    }

    @Test(.enabled(if: Bundle.main.preferredLocalizations.first == "en", "the literals are the English strings"))
    func splitProblemsHaveTheirMessages() {
        #expect(ArchiveSaveSettings.Problem.volumeTooSmall.message == "Volumes must be at least 1 MB.")
        #expect(ArchiveSaveSettings.Problem.volumeSizeInvalid.message
            == String(localized: "Enter a volume size greater than zero.", table: "Shared"))
        #expect(ArchiveSaveSettings.Problem.tooManyVolumes.message
            == String(localized: "Too many volumes. Choose a larger volume size.", table: "Shared"))
    }
}
