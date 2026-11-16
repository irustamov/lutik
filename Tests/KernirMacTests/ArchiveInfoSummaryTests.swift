import Testing
@testable import Kernir
import KernirCore

@Suite struct ArchiveInfoSummaryTests {
    private typealias Row = ArchiveInfoSummary.Row

    private static let format = String(localized: "Format", table: "Shared")
    private static let size = String(localized: "Size", table: "Shared")
    private static let items = String(localized: "Items", table: "Shared")
    private static let encryption = String(localized: "Encryption", table: "Shared")

    @Test func sevenZipAESHasAllFourRows() {
        let summary = ArchiveInfoSummary(format: .sevenZip, itemCount: 12, size: 4_200_000,
                                         compressedSize: 1_800_000, fileSize: 1_900_000, encryption: .aes256)
        let onDisk = KernirFormat.size(1_900_000)
        let total = KernirFormat.size(4_200_000)
        #expect(summary.rows == [
            Row(label: Self.format, value: "7z"),
            Row(label: Self.size, value: String(localized: "\(onDisk) (\(total) uncompressed)", table: "Shared")),
            Row(label: Self.items, value: String(localized: "\(12) items", table: "Shared")),
            Row(label: Self.encryption, value: "AES-256"),
        ])
    }

    @Test func noEncryptionRowWhenNotEncrypted() {
        let summary = ArchiveInfoSummary(format: .zip, itemCount: 3, size: 10, compressedSize: 8,
                                         fileSize: 200, encryption: .none)
        #expect(summary.rows.map(\.label) == [Self.format, Self.size, Self.items])
    }

    @Test func zipCryptoIsNamed() {
        let summary = ArchiveInfoSummary(format: .zip, itemCount: 1, size: 1, compressedSize: 1,
                                         fileSize: 100, encryption: .zipCrypto)
        #expect(summary.rows.last == Row(label: Self.encryption, value: "ZipCrypto"))
    }

    @Test func unknownTotalShowsOnlyTheFileSize() {
        // Single-stream .gz: the entry's size isn't recorded; don't claim "0 KB uncompressed".
        let summary = ArchiveInfoSummary(format: .gzip, itemCount: 1, size: nil, compressedSize: nil,
                                         fileSize: 5_000, encryption: .none)
        #expect(summary.rows[1] == Row(label: Self.size, value: KernirFormat.size(5_000)))
    }

    @Test func withoutAFileSizeTheTotalIsLabelledUncompressed() {
        // A document not yet on disk: only the content total is known.
        let summary = ArchiveInfoSummary(format: .zip, itemCount: 2, size: 1_600_000, compressedSize: nil,
                                         fileSize: nil, encryption: .none)
        let total = KernirFormat.size(1_600_000)
        #expect(summary.rows[1] == Row(label: Self.size,
                                       value: String(localized: "\(total) uncompressed", table: "Shared")))
    }

    @Test func noSizeRowWhenNothingIsKnown() {
        let summary = ArchiveInfoSummary(format: .gzip, itemCount: 1, size: nil, compressedSize: nil,
                                         fileSize: nil, encryption: .none)
        #expect(summary.rows.map(\.label) == [Self.format, Self.items])
    }

    @Test func noFormatRowWhenUnknown() {
        let summary = ArchiveInfoSummary(format: nil, itemCount: 0, size: 0, compressedSize: 0,
                                         fileSize: 22, encryption: .none)
        #expect(summary.rows.first?.label == Self.size)
    }
}
