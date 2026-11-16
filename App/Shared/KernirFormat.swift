import Foundation
import UniformTypeIdentifiers
import KernirCore
import os

/// Display formatting shared by the macOS and iOS apps.
enum KernirFormat {
    /// File-style byte count. Zero renders as "0 KB" (numeric), not ByteCountFormatter's "Zero KB";
    /// all other values match `ByteCountFormatter.string(fromByteCount:countStyle: .file)`.
    static func size(_ bytes: Int64) -> String {
        // ByteCountFormatter isn't Sendable; a fresh instance per call keeps this lock-free.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        // With nonnumeric wording off, 0 would read "0 bytes"; pin zero to KB for "0 KB".
        if bytes == 0 { formatter.allowedUnits = [.useKB] }
        return formatter.string(fromByteCount: bytes)
    }

    static func kind(forName name: String, isDirectory: Bool) -> String {
        if isDirectory { return String(localized: "Folder", table: "Shared",
                                                   comment: "Kind column of the Mac archive list: the item is a folder.") }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let description = kindByExtension(ext) { return description }
        return String(localized: "Document", table: "Shared",
                                comment: "Kind column of the Mac archive list: a file whose extension has no known kind.")
    }

    /// UTType lookups are slow; cache the description per lowercased extension (nil = unknown).
    private static let kindCache = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])

    private static func kindByExtension(_ ext: String) -> String? {
        if let cached = kindCache.withLock({ $0[ext] }) { return cached }
        let description = UTType(filenameExtension: ext)?.localizedDescription
        kindCache.withLock { $0[ext] = .some(description) }
        return description
    }

    static func date(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }

    /// "12 items · 4.2 MB, 1.8 MB compressed · ZIP". Without a compressed size the total is labelled
    /// as the uncompressed total ("10 items · 1.6 MB uncompressed · ZIP") so it isn't mistaken for the file's size on disk.
    /// An unknown total (single-stream .gz, .xz…) is left out: "1 item · GZ", not "0 KB".
    /// `compact` (iPhone subtitle at compact width) drops the "uncompressed" label so the line fits:
    /// "14 items · 415 KB".
    static func summary(itemCount: Int, size: Int64?, compressedSize: Int64?, format: ArchiveFormat?,
                        compact: Bool = false) -> String {
        let count = String(localized: "\(itemCount) items", table: "Shared")
        let total: String? = size.map { size in
            let total = Self.size(size)
            guard let compressedSize else {
                if compact { return total }
                return String(localized: "\(total) uncompressed", table: "Shared")
            }
            return String(localized: "\(total), \(Self.size(compressedSize)) compressed", table: "Shared")
        }
        // One key per shape, so a translation owns the order and the separator.
        switch (total, format?.displayName) {
        case let (total?, formatName?):
            return String(localized: "\(count) · \(total) · \(formatName)", table: "Shared",
                          comment: "Archive footer. %1$@ = item count (e.g. “12 items”), %2$@ = total size (e.g. “4.2 MB, 1.8 MB compressed” or “1.6 MB uncompressed”), %3$@ = archive format (e.g. “ZIP”).")
        case let (detail?, nil), let (nil, detail?):
            return String(localized: "\(count) · \(detail)", table: "Shared",
                          comment: "Archive footer. %1$@ = item count (e.g. “12 items”), %2$@ = either the total size (e.g. “1.6 MB uncompressed”, or a bare size such as “415 KB” at compact width on iPhone) or the archive format (e.g. “GZ”).")
        case (nil, nil):
            return count
        }
    }
}
