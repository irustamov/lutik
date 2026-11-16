import Foundation
import KernirCore

/// Where Compress writes and what it calls the archive, the way Finder names its own:
/// one item keeps its whole name ("report.pdf" → "report.pdf.zip", "Photos" → "Photos.zip"),
/// several make "Archive.zip", and a taken name gets a number before the extension
/// ("Archive 2.zip"). Pure: the caller lists the folder.
enum CompressPlan {
    struct Destination: Equatable, Sendable {
        let directory: URL
        let name: String
    }

    /// The longest name APFS takes: 255 UTF-8 bytes. HFS+ instead takes 255 UTF-16 units of the
    /// decomposed name, which a name within 255 UTF-8 bytes can exceed ("ǖ" is 2 UTF-8 bytes but
    /// 3 UTF-16 units decomposed); such a name fails cleanly there with a "name too long" error.
    static let maxNameBytes = 255

    /// The archive for `items` in `format`, beside them: in the first item's folder (Q-E: items
    /// from different folders, which only non-Finder callers send, go with the first). When that
    /// folder is a selected item or inside one (Finder's list view can select a folder and an item
    /// in it), the archive goes beside the outermost such item instead, so it is never written into
    /// something it archives. `existingNames` are the names already in that folder. nil when there
    /// is nothing to compress.
    static func destination(for items: [URL], format: ArchiveFormat,
                            existingNames: Set<String>) -> Destination? {
        guard let first = items.first else { return nil }
        let base = items.count == 1 ? first.lastPathComponent : defaultBase
        var directory = first.deletingLastPathComponent()
        let itemPaths = items.map { folded($0.standardizedFileURL.path) }
        func isWithinAnItem(_ url: URL) -> Bool {
            let path = folded(url.standardizedFileURL.path)
            return itemPaths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        while isWithinAnItem(directory), directory.standardizedFileURL.path != "/" {
            directory = directory.standardizedFileURL.deletingLastPathComponent()
        }
        return Destination(directory: directory,
                           name: uniqueName(base, extension: format.fileExtension, existingNames: existingNames))
    }

    /// The name of an archive of several items, before its extension: "Archive", as Finder's own
    /// Compress names it.
    static var defaultBase: String {
        String(localized: "Archive", table: "Shared",
               comment: "File name, without its extension, of the archive that Finder's “Compress with Lutik” makes from several items (“Archive.zip”, then “Archive 2.zip”…), as Finder's own Compress names it. A file name: no “/” or “:”, and it must not start with “.”.")
    }

    /// "base.ext", or the first free "base 2.ext", "base 3.ext"…, in NFC. Names compare as the
    /// default volumes do: ignoring case and Unicode normalization. A base too long for
    /// `maxNameBytes` with its number and extension loses whole characters (graphemes) from its
    /// end, and then any dot or space left dangling there ("report." would make "report..zip").
    /// When not even its first character fits, the base is "Archive", never an empty (hidden) ".zip".
    static func uniqueName(_ base: String, extension ext: String, existingNames: Set<String>) -> String {
        let base = base.precomposedStringWithCanonicalMapping
        let taken = Set(existingNames.map(folded))
        var number = 1
        while true {
            let suffix = (number == 1 ? "" : " \(number)") + "." + ext  // l10n-lint: not-plural (free-name suffix)
            let head = trimmed(base, toBytes: maxNameBytes - suffix.utf8.count)
            let name = (head.isEmpty ? defaultBase : head) + suffix
            if !taken.contains(folded(name)) { return name }
            number += 1
        }
    }

    /// `base`, or its longest run of leading characters within `bytes` UTF-8 bytes, without
    /// trailing dots and spaces (unless that would leave nothing).
    private static func trimmed(_ base: String, toBytes bytes: Int) -> String {
        guard base.utf8.count > bytes else { return base }
        var used = 0
        var head = base.prefix { character in
            used += character.utf8.count
            return used <= bytes
        }
        while head.count > 1, let last = head.last, last == "." || last == " " { head = head.dropLast() }
        return String(head)
    }

    private static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
