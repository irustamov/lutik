import Foundation
import KernirCore

/// The label/value rows of the archive Info popover (Mac) and Info sheet (iOS): Format, Size,
/// Items and, only for an encrypted archive, Encryption. Rows whose value is unknown are left out.
struct ArchiveInfoSummary: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    let rows: [Row]

    /// - Parameters:
    ///   - size: total uncompressed size of the contents; nil when unknown (single-stream .gz, .xz…).
    ///   - compressedSize: total compressed size of the contents; stands in for `fileSize` when that is unknown.
    ///   - fileSize: the archive file's size on disk; nil for a document not on disk.
    init(format: ArchiveFormat?, itemCount: Int, size: Int64?, compressedSize: Int64?, fileSize: Int64?,
         encryption: ArchiveEncryption) {
        var rows: [Row] = []
        if let format {
            rows.append(Row(label: String(localized: "Format", table: "Shared"), value: format.displayName))
        }
        if let value = Self.sizeValue(size: size, compressedSize: compressedSize, fileSize: fileSize) {
            rows.append(Row(label: String(localized: "Size", table: "Shared"), value: value))
        }
        rows.append(Row(label: String(localized: "Items", table: "Shared"),
                        value: String(localized: "\(itemCount) items", table: "Shared")))
        if encryption != .none {
            rows.append(Row(label: String(localized: "Encryption", table: "Shared"), value: encryption.displayName))
        }
        self.rows = rows
    }

    /// "1.9 MB (4.2 MB uncompressed)", "5 KB" when the contents' total is unknown,
    /// "1.6 MB uncompressed" when only the total is known, nil when nothing is.
    private static func sizeValue(size: Int64?, compressedSize: Int64?, fileSize: Int64?) -> String? {
        let packed = (fileSize ?? compressedSize).map(KernirFormat.size)
        let total = size.map(KernirFormat.size)
        switch (packed, total) {
        case let (packed?, total?):
            return String(localized: "\(packed) (\(total) uncompressed)", table: "Shared")
        case let (packed?, nil):
            return packed
        case let (nil, total?):
            return String(localized: "\(total) uncompressed", table: "Shared")
        case (nil, nil):
            return nil
        }
    }
}
