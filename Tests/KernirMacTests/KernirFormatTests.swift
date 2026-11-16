import Testing
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore

@Test func formatsSizeKindDate() {
    #expect(KernirFormat.size(1_200_000) == ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file))
    #expect(KernirFormat.kind(forName: "src", isDirectory: true) == String(localized: "Folder", table: "Shared"))
    #expect(KernirFormat.kind(forName: "cover.png", isDirectory: false) == UTType.png.localizedDescription)
    #expect(KernirFormat.kind(forName: "LICENSE", isDirectory: false) == String(localized: "Document", table: "Shared"))
    #expect(KernirFormat.date(nil) == "")
}

@Test func summaryMatchesMockupShape() {
    // English: "12 items · 4.2 MB, 1.8 MB compressed · ZIP"; compressed part omitted when nil
    let s = KernirFormat.summary(itemCount: 12, size: 4_200_000, compressedSize: 1_800_000, format: .zip)
    #expect(s.hasPrefix("12 items · ")); #expect(s.contains("compressed")); #expect(s.hasSuffix(" · ZIP"))
    #expect(!s.contains("uncompressed"))
    #expect(KernirFormat.summary(itemCount: 1, size: 5, compressedSize: nil, format: nil) == "1 item · \(KernirFormat.size(5)) uncompressed")
}

@Test func summaryLabelsUncompressedTotal() {
    let s = KernirFormat.summary(itemCount: 10, size: 1_600_000, compressedSize: nil, format: .zip)
    #expect(s.hasPrefix("10 items · ")); #expect(s.contains("uncompressed")); #expect(s.hasSuffix(" · ZIP"))
    #expect(KernirFormat.summary(itemCount: 1, size: 5, compressedSize: nil, format: nil).contains("uncompressed"))
    let c = KernirFormat.summary(itemCount: 10, size: 1_600_000, compressedSize: 900_000, format: .zip)
    #expect(c.contains(", ")); #expect(c.contains(" compressed")); #expect(!c.contains("uncompressed"))
}

@Test func compactSummaryDropsUncompressedLabel() {
    // iPhone subtitle (compact width): "14 items · 415 KB"; regular width keeps "uncompressed".
    let size = KernirFormat.size(415_000)
    #expect(KernirFormat.summary(itemCount: 14, size: 415_000, compressedSize: nil, format: nil, compact: true) == "14 items · \(size)")
    #expect(KernirFormat.summary(itemCount: 1, size: 5, compressedSize: nil, format: nil, compact: true) == "1 item · \(KernirFormat.size(5))")
    #expect(KernirFormat.summary(itemCount: 14, size: 415_000, compressedSize: nil, format: nil, compact: false) == "14 items · \(size) uncompressed")
    #expect(KernirFormat.summary(itemCount: 14, size: 415_000, compressedSize: nil, format: nil) == "14 items · \(size) uncompressed")
    #expect(KernirFormat.summary(itemCount: 1, size: nil, compressedSize: nil, format: nil, compact: true) == "1 item")
    // The compressed form is not shortened.
    #expect(KernirFormat.summary(itemCount: 2, size: 10, compressedSize: 5, format: .zip, compact: true) == KernirFormat.summary(itemCount: 2, size: 10, compressedSize: 5, format: .zip, compact: false))
}

@Test func summaryLeavesOutAnUnknownSize() {
    // Single-stream archives (.gz, .xz, ...) don't record their entry's size: say nothing, not "0 KB".
    let one = "1 item"
    #expect(KernirFormat.summary(itemCount: 1, size: nil, compressedSize: nil, format: .gzip) == "\(one) · GZ")
    #expect(KernirFormat.summary(itemCount: 1, size: nil, compressedSize: 100, format: .gzip) == "\(one) · GZ")
    #expect(KernirFormat.summary(itemCount: 1, size: nil, compressedSize: nil, format: nil) == one)
}

@Test func zeroSizeIsNumeric() {
    // Zero keeps ByteCountFormatter's unit (KB) but reads numerically.
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    formatter.allowedUnits = [.useKB]
    #expect(KernirFormat.size(0) == formatter.string(fromByteCount: 0))
    #expect(KernirFormat.size(0).hasPrefix("0"))
    #expect(!KernirFormat.size(0).contains("Zero"))
    #expect(KernirFormat.size(1_600_000) == ByteCountFormatter.string(fromByteCount: 1_600_000, countStyle: .file))
}

@Test func archiveErrorsHaveUserFacingText() {
    let all: [ArchiveError] = [.unsupportedFormat, .passwordRequired, .wrongPassword,
        .unsupportedEncryption(.sevenZip), .readOnlyFormat(.rar), .corrupted("x"),
        .entryNotFound("a"), .io("disk"), .cancelled, .notImplemented]
    for e in all { #expect(!(e.errorDescription ?? "").isEmpty) }
    #expect(ArchiveError.unsupportedEncryption(.sevenZip).errorDescription == "Encrypted 7z archives aren't supported yet.")
    #expect(ArchiveError.unsupportedEncryption(.rar).errorDescription == "Encrypted RAR archives aren't supported yet.")
    #expect(ArchiveError.unsupportedEncryption(.rar).recoverySuggestion == "Decrypt it with another app first, or use a ZIP archive.")
    #expect(ArchiveError.readOnlyFormat(.rar).errorDescription == "RAR archives can only be read.")
    #expect(ArchiveError.readOnlyFormat(.rar).recoverySuggestion == "Use Save As to save a copy as ZIP or 7z.")
}

@Test func volumeErrorText() {
    func make(_ reason: ArchiveVolumeError.Reason, part: Int?) -> ArchiveVolumeError {
        ArchiveVolumeError(reason: reason, part: part, fileName: "Photos.part3.rar", setName: "Photos.part1.rar",
                           folder: URL(fileURLWithPath: "/tmp"), openedPart: 1)
    }
    let recovery = "Put all parts in one folder and open the archive again."
    let withPart = make(.missing, part: 3)
    #expect(withPart.errorDescription == "Part 3 of “Photos.part1.rar” is missing.")
    #expect(withPart.failureReason == "Part 3 of “Photos.part1.rar” is missing.")
    #expect(withPart.recoverySuggestion == recovery)
    let noPart = make(.missing, part: nil)
    #expect(noPart.errorDescription == "The last part of “Photos.part1.rar” is missing.")
    #expect(noPart.failureReason == "The last part of “Photos.part1.rar” is missing.")
    #expect(noPart.recoverySuggestion == recovery)
    let noAccess = make(.noAccess, part: 2)
    #expect(noAccess.errorDescription == "This archive is split into parts.")
    #expect(noAccess.failureReason == "This archive is split into parts.")
    #expect(noAccess.recoverySuggestion == "Lutik needs access to the folder that holds them.")
}

/// KernirCore refuses at open an archive that nests too deeply or whose names are too big
/// (`ArchiveNestingError`). Alerts show `localizedDescription` (iOS) and the failure reason (AppKit's open alert).
@Test func nestingErrorText() {
    let deep = "This archive nests folders too deeply."
    let names = "This archive's file names are too long or too complex to open."
    let many = "This archive has too many files to open."
    let all: [ArchiveNestingError.Limit] = [.depth, .folderBytes, .ancestorWork, .pathLength, .totalPathBytes,
                                            .combiningMarks, .entryCount]
    for limit in all {
        // Exhaustive, so a new limit needs its text chosen here.
        let expected = switch limit {
        case .depth, .folderBytes, .ancestorWork: deep
        case .pathLength, .totalPathBytes, .combiningMarks: names
        case .entryCount: many
        }
        let error: Error = ArchiveNestingError(limit: limit)
        #expect(error.localizedDescription == expected, "\(limit)")
        #expect((error as NSError).localizedFailureReason == expected, "\(limit)")
    }
}

/// In the Method picker only "Store" is a word to translate; the codec names stay
/// KernirCore's.
@Test(.enabled(if: Bundle.main.preferredLocalizations.first == "en", "the literals are the English strings"))
func methodNamesLocalizeOnlyStore() {
    #expect(KernirFormat.methodName(.store) == String(localized: "Store", table: "Shared"))
    #expect(KernirFormat.methodName(.store) == "Store")
    for method in ArchiveCompressionMethod.allCases where method != .store {
        #expect(KernirFormat.methodName(method) == method.displayName, "\(method)")
    }
}

/// l10n E1/E2: the save options' sizes and units come from ByteCountFormatter, in VolumeSplit's
/// decimal units; "FAT32" stays verbatim.
@Test(.enabled(if: Bundle.main.preferredLocalizations.first == "en", "the literals are the English strings"))
func saveOptionSizesComeFromTheByteCountFormatter() {
    #expect(VolumeSplit.Preset.allCases.map(KernirFormat.volumeSplitPresetName)
        == ["25 MB", "100 MB", "700 MB", "4 GB (FAT32)"])
    // Each label follows its preset's stored bytes, so the two can't drift apart.
    let bytesAndLabels: [(VolumeSplit.Preset, Int64, String)] = [
        (.mb25, 25_000_000, "25 MB"), (.mb100, 100_000_000, "100 MB"),
        (.mb700, 700_000_000, "700 MB"), (.fat32, 4_294_967_295, "4 GB (FAT32)"),
    ]
    #expect(bytesAndLabels.map(\.0) == VolumeSplit.Preset.allCases)
    for (preset, bytes, label) in bytesAndLabels {
        #expect(preset.bytes == bytes, "\(preset)")
        #expect(KernirFormat.volumeSplitPresetName(preset) == label, "\(preset)")
    }
    #expect(KernirFormat.volumeUnitName(.mb) == "MB")
    #expect(KernirFormat.volumeUnitName(.gb) == "GB")
    #expect(ArchiveSaveSettings.Problem.volumeTooSmall.message == "Volumes must be at least 1 MB.")
}
