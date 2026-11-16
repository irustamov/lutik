import Foundation
import KernirCore

/// Titles the save options show on both apps: the compression method and the volume sizes.
extension KernirFormat {
    /// The Method picker's title. "Store" is an ordinary word, so it is translated; the codec names
    /// (Deflate, BZip2, LZMA, LZMA2, PPMd) are proper names and stay as KernirCore writes them.
    static func methodName(_ method: ArchiveCompressionMethod) -> String {
        switch method {
        case .store:
            String(localized: "Store", table: "Shared", comment: "Save options, Method picker: the ZIP/7z method that stores files without compression.")
        case .deflate, .bzip2, .lzma, .lzma2, .ppmd:
            method.displayName
        }
    }

    /// The split presets' titles: "25 MB", "100 MB", "700 MB", "4 GB (FAT32)". Each size comes from
    /// the preset's own byte count, in the largest unit that holds it (FAT32's 4 GiB − 1 rounds to 4 GB).
    static func volumeSplitPresetName(_ preset: VolumeSplit.Preset) -> String {
        let unit: VolumeSplit.Unit = preset.bytes >= VolumeSplit.Unit.gb.bytes ? .gb : .mb
        let amount = (Double(preset.bytes) / Double(unit.bytes)).rounded()
        let size = volumeSize(Int64(amount), unit)
        return switch preset {
        case .mb25, .mb100, .mb700: size
        case .fat32: fat32Name(size: size)
        }
    }

    /// The volume size unit picker's "MB" and "GB", from the same formatter as the sizes.
    static func volumeUnitName(_ unit: VolumeSplit.Unit) -> String {
        volumeFormatter(unit, includesCount: false).string(fromByteCount: unit.bytes)
    }

    /// "25 MB": a whole number of `unit`s in the current locale. ByteCountFormatter's file style
    /// is decimal, like VolumeSplit (1 MB = 1 000 000 bytes).
    private static func volumeSize(_ amount: Int64, _ unit: VolumeSplit.Unit) -> String {
        volumeFormatter(unit, includesCount: true).string(fromByteCount: amount * unit.bytes)
    }

    private static func fat32Name(size: String) -> String {
        String(localized: "\(size) (FAT32)", table: "Shared",
               comment: "Save options, Split into volumes: the preset for a FAT32 drive's largest file. %@ is a size such as “4 GB”. Keep FAT32 verbatim (a file system name).")
    }

    private static func volumeFormatter(_ unit: VolumeSplit.Unit, includesCount: Bool) -> ByteCountFormatter {
        // ByteCountFormatter isn't Sendable; a fresh instance per call, like `size(_:)`.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.includesCount = includesCount
        formatter.allowedUnits = switch unit {
        case .mb: .useMB
        case .gb: .useGB
        }
        return formatter
    }
}
