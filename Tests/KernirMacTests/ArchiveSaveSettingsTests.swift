import Testing
import Foundation
@testable import Kernir
import KernirCore

@MainActor
struct ArchiveSaveSettingsTests {
    private func zipSettings(_ options: ArchiveWriteOptions, verifyPassword: String = "") -> ArchiveSaveSettings {
        ArchiveSaveSettings(format: .zip, options: options, verifyPassword: verifyPassword)
    }

    @Test func encryptRequiresMatchingNonEmptyPassword() {
        var settings = zipSettings(ArchiveWriteOptions(encryption: .aes256))
        #expect(settings.isEncrypting)
        #expect(settings.problems == [.passwordEmpty])

        settings.options.password = "a"
        settings.verifyPassword = "b"
        #expect(settings.problems == [.passwordMismatch])

        settings.verifyPassword = "a"
        #expect(settings.problems == [])
    }

    @Test func noEncryptionNeedsNoPassword() {
        let settings = zipSettings(ArchiveWriteOptions(encryption: .none, password: "a"), verifyPassword: "b")
        #expect(!settings.isEncrypting)
        #expect(settings.problems == [])
    }

    @Test func encryptionTheFormatCannotDoIsAProblem() throws {
        let format = try #require(ArchiveFormat.writable.first { !$0.supportedEncryptions.contains(.aes256) })
        let settings = ArchiveSaveSettings(format: format,
                                           options: ArchiveWriteOptions(encryption: .aes256, password: "a"),
                                           verifyPassword: "a")
        #expect(settings.problems == [.encryptionUnsupported])
    }

    @Test func switchingToTarDropsEncryptionAndClampsMethod() throws {
        var settings = zipSettings(ArchiveWriteOptions(method: .deflate, compressionLevel: 0, encryption: .aes256,
                                                       password: "pw"), verifyPassword: "pw")
        settings.format = .tarGzip
        settings.formatDidChange()

        let format = ArchiveFormat.tarGzip
        if format.supportedEncryptions.allSatisfy({ $0 == .none }) {
            #expect(settings.options.encryption == .none)
        }
        if format.supportedMethods.isEmpty {
            #expect(settings.options.method == nil)
        } else {
            #expect(format.supportedMethods.contains(try #require(settings.options.method)))
        }
        if let range = format.compressionLevelRange {
            #expect(range.contains(try #require(settings.options.compressionLevel)))
        } else {
            #expect(settings.options.compressionLevel == nil)
        }
        #expect(settings.problems == [])
    }

    @Test func switchingZipCryptoTo7zFallsBackToAES256() {
        var settings = zipSettings(ArchiveWriteOptions(encryption: .zipCrypto, password: "pw"), verifyPassword: "pw")
        settings.format = .sevenZip
        settings.formatDidChange()

        let supported = ArchiveFormat.sevenZip.supportedEncryptions
        let expected: ArchiveEncryption = !supported.contains(.zipCrypto) && supported.contains(.aes256) ? .aes256 : .none
        #expect(settings.options.encryption == expected)
        #expect(settings.options.solid == nil || ArchiveFormat.sevenZip.supportsSolid)
    }

    /// A password typed for a format that can't encrypt is never kept or prefilled later.
    @Test func formatWithoutEncryptionForgetsThePassword() throws {
        let format = try #require(ArchiveFormat.writable.first { $0.supportedEncryptions == [.none] })
        var settings = zipSettings(ArchiveWriteOptions(encryption: .aes256, password: "pw"), verifyPassword: "pw")
        settings.format = format
        settings.formatDidChange()

        #expect(settings.options.encryption == .none)
        #expect(settings.options.password == nil)
        #expect(settings.verifyPassword == "")
    }

    @Test func turningEncryptionOffForgetsThePassword() {
        var settings = zipSettings(ArchiveWriteOptions(encryption: .aes256, password: "pw"), verifyPassword: "pw")
        settings.isEncrypting = false
        #expect(settings.options.encryption == .none)
        #expect(settings.options.password == nil)
        #expect(settings.verifyPassword == "")

        // Turning it on again picks the format's first strong scheme, with an empty password.
        settings.isEncrypting = true
        #expect(settings.options.encryption == ArchiveFormat.zip.supportedEncryptions.first { $0 != .none && !$0.isWeak })
        #expect(settings.problems == [.passwordEmpty])
    }

    @Test func settingsInitFromZipCryptoModel() {
        let reader = FakeReader(entries: SampleArchive().entries, isEncrypted: true, encryption: .zipCrypto,
                                compressionMethod: .store)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        model.password = "pw"

        let settings = ArchiveSaveSettings(model: model)
        #expect(settings.format == .zip)
        #expect(settings.options.encryption == .zipCrypto)
        #expect(settings.options.password == "pw")
        #expect(settings.options.method == .store)
        #expect(settings.verifyPassword == "pw")
        #expect(settings.problems == [])
    }

    @Test func newDocumentGetsFormatDefaults() {
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        let settings = ArchiveSaveSettings(model: model)
        #expect(settings.format == .zip)
        #expect(settings.options == ArchiveWriteOptions(method: ArchiveFormat.zip.defaultMethod,
                                                        compressionLevel: ArchiveFormat.zip.defaultCompressionLevel,
                                                        excludesMacMetadata: ArchiveSaveSettings.excludesMacMetadataByDefault))
        #expect(settings.problems == [])
    }

    @Test func readOnlySourceSavesAsAWritableFormat() {
        let model = ArchiveModel(reader: FakeReader(entries: SampleArchive().entries, format: .rar), undoManager: nil)
        let settings = ArchiveSaveSettings(model: model)
        #expect(settings.format.isWritable)
    }

    @Test func applySetsSaveOptionsAndPassword() {
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        #expect(model.saveOptions == nil)
        let settings = zipSettings(ArchiveWriteOptions(method: .store, compressionLevel: 9, encryption: .aes256,
                                                       password: "pw"), verifyPassword: "pw")

        model.apply(settings)
        #expect(model.saveOptions == settings.options)
        #expect(model.password == "pw")

        // The next Save As starts from what was chosen last.
        #expect(ArchiveSaveSettings(model: model).options == settings.options)

        model.apply(zipSettings(ArchiveWriteOptions(encryption: .none, password: "typed, then switched off")))
        #expect(model.password == nil)
        // A password that won't be used isn't kept in the save options either.
        #expect(model.saveOptions?.password == nil)
    }

    @Test func fileNameReplacesCompoundAliases() {
        #expect(ArchiveSaveSettings.fileName("x.tgz", for: .zip) == "x.zip")
        #expect(ArchiveSaveSettings.fileName("x.tar.gz", for: .zip) == "x.zip")
        #expect(ArchiveSaveSettings.fileName("x.tbz2", for: .zip) == "x.zip")
        #expect(ArchiveSaveSettings.fileName("x.txz", for: .zip) == "x.zip")
        #expect(ArchiveSaveSettings.fileName("x.tzst", for: .zip) == "x.zip")
        #expect(ArchiveSaveSettings.fileName("x.TGZ", for: .tarXz) == "x.tar.xz")
        #expect(ArchiveSaveSettings.fileName("x.txt", for: .zip) == "x.txt.zip")
    }

    @Test func fileNameTakesTheFormatExtension() {
        #expect(ArchiveSaveSettings.fileName("Photos", for: .zip) == "Photos.zip")
        #expect(ArchiveSaveSettings.fileName("Photos.zip", for: .tarGzip) == "Photos.tar.gz")
        #expect(ArchiveSaveSettings.fileName("Photos.tar.gz", for: .sevenZip) == "Photos.7z")
        #expect(ArchiveSaveSettings.fileName("Photos.TAR.BZ2", for: .zip) == "Photos.zip")
        #expect(ArchiveSaveSettings.fileName("Photos.rar", for: .zip) == "Photos.zip")
        #expect(ArchiveSaveSettings.fileName("v1.2 notes", for: .tar) == "v1.2 notes.tar")
    }

    /// The save panel proposes the format's one-part extension
    /// ("tgz", "tbz2", "txz"), so a bare name typed over it gets that one too.
    @Test func savePanelExtensionIsTheOnePartAlias() {
        #expect(ArchiveSaveSettings.savePanelExtension(for: .tarGzip) == "tgz")
        #expect(ArchiveSaveSettings.savePanelExtension(for: .tarBzip2) == "tbz2")
        #expect(ArchiveSaveSettings.savePanelExtension(for: .tarXz) == "txz")
        #expect(ArchiveSaveSettings.savePanelExtension(for: .zip) == "zip")
        #expect(ArchiveSaveSettings.savePanelExtension(for: .sevenZip) == "7z")
        #expect(ArchiveSaveSettings.savePanelExtension(for: .tar) == "tar")
    }

    @Test func savePanelProposalSwapsTheArchiveExtension() {
        #expect(ArchiveSaveSettings.savePanelProposal("s2-plain.tar.gz", for: .tarGzip) == "s2-plain.tgz")
        #expect(ArchiveSaveSettings.savePanelProposal("Untitled.zip", for: .tarGzip) == "Untitled.tgz")
        #expect(ArchiveSaveSettings.savePanelProposal("Untitled.tgz", for: .tarBzip2) == "Untitled.tbz2")
        #expect(ArchiveSaveSettings.savePanelProposal("Photos.TAR.BZ2", for: .tarXz) == "Photos.txz")
        #expect(ArchiveSaveSettings.savePanelProposal("Photos.txz", for: .zip) == "Photos.zip")
        #expect(ArchiveSaveSettings.savePanelProposal("Photos.rar", for: .sevenZip) == "Photos.7z")
        #expect(ArchiveSaveSettings.savePanelProposal("x", for: .tarGzip) == "x.tgz")
        #expect(ArchiveSaveSettings.savePanelProposal("v1.2 notes", for: .tar) == "v1.2 notes.tar")
    }

    /// NSDocument swaps only the last extension, so after saving "s2-plain.tar.gz" its panel
    /// starts at "s2-plain.tar.tgz": the proposal drops every archive extension, so it never reads
    /// ".tar.tar." or ".gz.gz".
    @Test func savePanelProposalDropsStackedExtensions() {
        #expect(ArchiveSaveSettings.savePanelProposal("s2-plain.tar.tgz", for: .tarGzip) == "s2-plain.tgz")
        #expect(ArchiveSaveSettings.savePanelProposal("s2-plain.tar.tgz", for: .zip) == "s2-plain.zip")
        #expect(ArchiveSaveSettings.savePanelProposal("y.TAR.tbz2", for: .tarBzip2) == "y.tbz2")
        #expect(ArchiveSaveSettings.savePanelProposal("s2-plain.tar.gz.gz", for: .tarGzip) == "s2-plain.tgz")
        #expect(ArchiveSaveSettings.savePanelProposal("dump.tar.zip", for: .sevenZip) == "dump.7z")
    }

    /// A copy of a split archive is named after the set, never after the part it was opened at.
    @Test func volumeSetBaseNameDropsThePartSuffix() {
        #expect(ArchiveSaveSettings.volumeSetBaseName("Photos.part1.rar") == "Photos")
        #expect(ArchiveSaveSettings.volumeSetBaseName("Photos.part01.rar") == "Photos")
        #expect(ArchiveSaveSettings.volumeSetBaseName("Photos.PART12.RAR") == "Photos")
        #expect(ArchiveSaveSettings.volumeSetBaseName("Photos.rar") == "Photos")
        #expect(ArchiveSaveSettings.volumeSetBaseName("Photos.r00") == "Photos")
        #expect(ArchiveSaveSettings.volumeSetBaseName("s7.7z.001") == "s7")
        #expect(ArchiveSaveSettings.volumeSetBaseName("Photos.zip.001") == "Photos")
        #expect(ArchiveSaveSettings.volumeSetBaseName("span.zip") == "span")
        #expect(ArchiveSaveSettings.volumeSetBaseName("span.z01") == "span")
        #expect(ArchiveSaveSettings.volumeSetBaseName("v1.2 notes.7z.003") == "v1.2 notes")
        // Only ONE recognized suffix goes, a compound one counting as one.
        #expect(ArchiveSaveSettings.volumeSetBaseName("s2-plain.tar.tgz.001") == "s2-plain.tar")
        // Nothing left but the suffix: the name stays.
        #expect(ArchiveSaveSettings.volumeSetBaseName(".001") == ".001")
    }

    @Test func savePanelProposalOfAVolumeSetIsTheSetName() {
        #expect(ArchiveSaveSettings.savePanelProposal("Photos.part1.rar", for: .zip, isVolumeSet: true) == "Photos.zip")
        #expect(ArchiveSaveSettings.savePanelProposal("Photos.r00", for: .zip, isVolumeSet: true) == "Photos.zip")
        #expect(ArchiveSaveSettings.savePanelProposal("Photos.rar", for: .zip, isVolumeSet: true) == "Photos.zip")
        #expect(ArchiveSaveSettings.savePanelProposal("s7.7z.001", for: .sevenZip, isVolumeSet: true) == "s7.7z")
        #expect(ArchiveSaveSettings.savePanelProposal("Photos.zip.001", for: .zip, isVolumeSet: true) == "Photos.zip")
        #expect(ArchiveSaveSettings.savePanelProposal("span.z01", for: .tarGzip, isVolumeSet: true) == "span.tgz")
        // A single file named like a part keeps its name.
        #expect(ArchiveSaveSettings.savePanelProposal("data.001", for: .zip) == "data.001.zip")
        #expect(ArchiveSaveSettings.fileName("s7.7z.001", for: .sevenZip, isVolumeSet: true) == "s7.7z")
        #expect(ArchiveSaveSettings.fileName("Photos.part1.rar", for: .tarGzip, isVolumeSet: true) == "Photos.tar.gz")
        #expect(ArchiveSaveSettings.fileName("data.001", for: .zip) == "data.001.zip")
    }

    /// Save As refuses a part of the set it reads: the same file by identity (symlinks and case
    /// followed), or the same path when the destination doesn't exist yet.
    @Test func aPartOfTheSetIsRecognisedAsTheSaveDestination() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveSaveSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parts = ["s7.7z.001", "s7.7z.002"].map { folder.appendingPathComponent($0) }
        for part in parts { try Data("part".utf8).write(to: part) }
        let link = folder.appendingPathComponent("link.7z")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parts[1])

        #expect(ArchiveSaveSettings.isVolumePart(parts[0], of: parts))
        #expect(ArchiveSaveSettings.isVolumePart(parts[1], of: parts))
        #expect(ArchiveSaveSettings.isVolumePart(link, of: parts))
        #expect(ArchiveSaveSettings.isVolumePart(folder.appendingPathComponent("sub/../s7.7z.001"), of: parts))
        #expect(!ArchiveSaveSettings.isVolumePart(folder.appendingPathComponent("s7.7z"), of: parts))
        #expect(!ArchiveSaveSettings.isVolumePart(folder.appendingPathComponent("new/s7.7z.001"), of: parts))
        // A single file is no set: saving over it is an ordinary replace.
        #expect(!ArchiveSaveSettings.isVolumePart(parts[0], of: [parts[0]]))
    }
}
