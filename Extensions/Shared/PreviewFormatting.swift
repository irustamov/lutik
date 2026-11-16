import Foundation
import KernirCore

/// User-visible strings shown by the Quick Look extensions.
///
/// Every string is looked up in `Localizable.xcstrings` next to this file, in `bundle`: the appex's own
/// bundle in the extensions, the test bundle in KernirQuickLookTests (whose `Bundle.main` is the xctest
/// runner, which has no catalog).
enum PreviewFormatting {
    static var bundle: Bundle { Bundle(for: BundleToken.self) }

    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func summary(_ listing: PreviewListing) -> String {
        let format = formatName(listing.format)
        let count = itemCount(listing.totalCount)
        // An unknown total (single-stream .gz, .xz…) is left out, not shown as "Zero KB".
        if !listing.isEmpty, let total = listing.totalSize {
            return String(localized: "\(format) · \(count) · \(size(total))", bundle: bundle,
                          comment: "Quick Look summary line. %1$@ = archive kind (e.g. “ZIP archive”), %2$@ = item count (e.g. “7 items”), %3$@ = total size (e.g. “3.4 MB”).")
        }
        return String(localized: "\(format) · \(count)", bundle: bundle,
                      comment: "Quick Look summary line when the total size is unknown or the archive is empty. %1$@ = archive kind (e.g. “ZIP archive”), %2$@ = item count (e.g. “7 items”).")
    }

    static func moreItems(_ hidden: Int) -> String {
        String(localized: "\(hidden) more items", bundle: bundle,
               comment: "Quick Look: line below a listing capped at 5,000 entries. %lld = number of entries not shown.")
    }

    /// Title of the placeholder for one part of a split archive; part 0 (or below) is a spanned zip's last part.
    static func volumePartTitle(_ openedPart: Int) -> String {
        guard openedPart >= 1 else {
            return String(localized: "Last part of a split archive", bundle: bundle,
                          comment: "Quick Look placeholder title for the last part of a split ZIP (the .zip file itself).")
        }
        return String(localized: "Part \(openedPart) of a split archive", bundle: bundle,
                      comment: "Quick Look placeholder title for one part of a multi-part archive. %lld = the part number opened (1, 2, 3…).")
    }

    static var openInKernirDescription: String {
        String(localized: "Open in Lutik to see everything.", bundle: bundle,
               comment: "Quick Look placeholder description under the split-archive title and under the “Archive too large to preview” title. Lutik is the app name.")
    }

    static var tooLargeTitle: String {
        String(localized: "Archive too large to preview", bundle: bundle,
               comment: "Quick Look placeholder title for an archive with too many items, names or folders to list in a preview. The description under it is “Open in Lutik to see everything.”")
    }

    static var emptyArchiveTitle: String {
        String(localized: "Empty archive", bundle: bundle,
               comment: "Quick Look placeholder title for an archive with no entries.")
    }

    static var passwordProtectedTitle: String {
        String(localized: "Password-protected archive", bundle: bundle,
               comment: "Quick Look placeholder title for an encrypted archive whose contents can't be listed.")
    }

    static func formatName(_ format: ArchiveFormat?) -> String {
        guard let format else {
            return String(localized: "Archive", bundle: bundle,
                          comment: "Quick Look: archive kind when the format is unknown. Shown under “Password-protected archive”.")
        }
        return String(localized: "\(format.displayName) archive", bundle: bundle,
                      comment: "Quick Look: archive kind. %@ = format name, e.g. “ZIP”, “TAR.GZ”, “7Z”.")
    }

    private static func itemCount(_ n: Int) -> String {
        String(localized: "\(n) items", bundle: bundle,
               comment: "Quick Look summary: number of files and folders in the archive. %lld = item count.")
    }

    /// Compiled into whichever binary compiles this file, so `Bundle(for:)` finds that binary's bundle.
    private final class BundleToken {}
}
