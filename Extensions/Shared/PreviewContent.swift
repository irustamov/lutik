import Foundation
import KernirCore

/// Platform-independent result of listing an archive for Quick Look.
struct PreviewListing: Equatable, Sendable {
    let format: ArchiveFormat
    /// Folder tree built from the capped entries.
    let nodes: [ArchiveNode]
    /// All entries in the archive (files and folders).
    let totalCount: Int
    /// Sum of file sizes over all entries; nil when any file's size is unknown (single-stream .gz, .xz…).
    let totalSize: Int64?
    /// Entries not shown because of the cap.
    let hiddenCount: Int

    var isEmpty: Bool { totalCount == 0 }
}

enum PreviewContent: Equatable, Sendable {
    case listing(PreviewListing)
    case passwordProtected(ArchiveFormat?)
    /// The file is one part of a split archive. Quick Look shows a placeholder, never a partial listing.
    /// `openedPart` is the part number opened; 0 is a spanned zip opened at its `.zip` (its last part).
    case volumePart(openedPart: Int)
    /// The archive passes the preview's fixed limits (`ArchiveNestingError` from `previewListing`): entries, name
    /// bytes, folder bytes or ancestor work. Lutik's own limits are higher, so it usually can still open it.
    /// Not a guarantee: `.entryCount` can also come from limits that block `Archive.open` too (more than 4,000,000
    /// headers; a xar with more than 1,024 extended attributes on one file, see PatchedNameRefusal.swift), so for
    /// such crafted or extreme archives "open in Lutik" may not hold.
    case tooLarge
}

extension ArchiveNestingError {
    /// The limits that count the whole archive. The others (depth, one name's length, combining marks) are about a
    /// single path and bind `Archive.open` alike, so for them "open it in Lutik" would be wrong.
    var isPreviewBudget: Bool {
        switch limit {
        case .entryCount, .totalPathBytes, .folderBytes, .ancestorWork: true
        case .depth, .pathLength, .combiningMarks: false
        }
    }
}

enum PreviewLoader {
    static let entryLimit = 5_000

    /// `list` builds the capped listing; by default `Archive.previewListing`, which never materializes
    /// more than `limit` entries.
    static func load(
        _ url: URL,
        limit: Int = entryLimit,
        list: @Sendable (URL, Int) async throws -> PreviewListing = {
            listing(from: try await Archive.previewListing(at: $0, limit: $1))
        }
    ) async throws -> PreviewContent {
        do {
            return .listing(try await list(url, limit))
        } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
            return .passwordProtected(Archive.detectFormat(at: url))
        } catch ArchiveError.unsupportedEncryption(let format) {
            return .passwordProtected(format)
        } catch let error as ArchiveVolumeError {
            return .volumePart(openedPart: error.openedPart)
        } catch let error as ArchiveNestingError where error.isPreviewBudget {
            return .tooLarge
        }
    }

    static func listing(for archive: any ArchiveReading, limit: Int = entryLimit) -> PreviewListing {
        // Drop macOS resource-fork metadata first so counts, sizes and the cap apply only to visible entries.
        let entries = archive.entries.filter { !$0.isMacOSMetadata }
        let capped = cappedEntries(entries, limit: limit)
        let files = entries.filter { !$0.isDirectory }
        let totalSize = files.contains { $0.size == nil } ? nil : files.compactMap(\.size).reduce(0, +)
        return PreviewListing(
            format: archive.format,
            nodes: Archive.tree(from: capped),
            totalCount: entries.count,
            totalSize: totalSize,
            hiddenCount: max(0, entries.count - capped.count)
        )
    }

    /// The capped header entries of `preview`, plus their missing ancestor folders; totals cover the whole archive.
    static func listing(from preview: ArchivePreviewListing) -> PreviewListing {
        let shown = cappedEntries(preview.entries, limit: preview.entries.count)
        // `visibleFileSize` counts unknown sizes as 0, so an unknown size is caught among the entries built
        // (all of them up to the cap; a single-stream archive has one).
        let sizeUnknown = preview.entries.contains { !$0.isDirectory && $0.size == nil }
        return PreviewListing(
            format: preview.format,
            nodes: Archive.tree(from: shown),
            totalCount: preview.visibleEntryCount,
            totalSize: sizeUnknown ? nil : preview.visibleFileSize,
            hiddenCount: max(0, preview.visibleEntryCount - shown.count)
        )
    }

    /// First `limit` entries in archive order, followed by synthesized directory
    /// entries for any ancestor of a kept entry that is not itself kept.
    static func cappedEntries(_ entries: [ArchiveEntry], limit: Int) -> [ArchiveEntry] {
        let kept = Array(entries.prefix(max(0, limit)))
        var present = Set(kept.map(\.path))
        var synthesized: [ArchiveEntry] = []
        for entry in kept {
            var parent = entry.parentPath
            while !parent.isEmpty, present.insert(parent).inserted {
                let ancestor = ArchiveEntry(path: parent, isDirectory: true, size: nil,
                                            compressedSize: nil, modificationDate: nil)
                synthesized.append(ancestor)
                parent = ancestor.parentPath
            }
        }
        return kept + synthesized
    }
}
