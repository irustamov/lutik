import Foundation
import KernirCore

/// An archive's base name: the one place Extract and split-save take a default folder name from.
/// As Archive Utility and The Unarchiver do it: drop one recognized archive suffix,
/// a compound one ("tar.gz") counting as one. "x.tar.gz" → "x", "notes.txt.gz" → "notes.txt",
/// "x.tar.gz.gz" → "x.tar.gz", "notes.txt" stays. A result of "", "." or ".." would name the
/// archive's folder or the one above it, so the archive's own file name is the base name instead.
enum ArchiveBaseName {
    /// The archive extensions Lutik opens (each format's own, the other names its types carry, the
    /// developer packages Lutik views) plus a few common compound tar names, longest first so
    /// "tar.gz" wins over "gz".
    /// Part suffixes ("001", "r00", "z01") are not here: a set is told by its volumes.
    static let suffixes: [String] = {
        let others = [
            "gtar", "gzip", "bz", "pax",
            "tar.bz", "tar.lz4", "tar.z",
            "jar", "war", "ear", "apk", "aab", "xpi", "whl", "nupkg", "vsix",
        ]
        let own = ArchiveFormat.allCases.flatMap { [$0.fileExtension] + alternateExtensions(of: $0) }
        return Set(own + others).sorted { $0.count > $1.count }
    }()

    /// Other extensions a format is known by, besides its preferred `fileExtension`.
    static func alternateExtensions(of format: ArchiveFormat) -> [String] {
        switch format {
        case .tarGzip: ["tgz", "taz"]
        case .tarBzip2: ["tbz2", "tbz", "tb2"]
        case .tarXz: ["txz"]
        case .tarZstd: ["tzst"]
        case .lha: ["lzh"]
        default: []
        }
    }

    /// `fileName` without one recognized suffix, ignoring case; any other extension stays.
    /// A part of a split archive (`isVolumeSet`, told by the reader's volumes) first loses its
    /// part suffix: "Photos.part1.rar", "Photos.r00", "Photos.zip.001", "span.z01" → "Photos", "span".
    /// A suffix with nothing before it stays (".zip", ".001"). "..zip" and "...part1.rar" stay too:
    /// their bases are dot names. "a..zip" → "a.", "....zip" → "...".
    static func of(_ fileName: String, isVolumeSet: Bool) -> String {
        let name = droppingSuffix(isVolumeSet ? droppingPartSuffix(fileName) : fileName)
        return ["", ".", ".."].contains(name) ? fileName : name
    }

    /// `name` without the longest recognized suffix that has something before it.
    private static func droppingSuffix(_ name: String) -> String {
        for suffix in suffixes {
            if let range = name.range(of: "." + suffix, options: [.caseInsensitive, .anchored, .backwards]),
               range.lowerBound > name.startIndex {
                return String(name[..<range.lowerBound])
            }
        }
        return name
    }

    /// `name` without a part suffix (".part1.rar", ".001", ".r00", ".z01"), the first that matches.
    /// Part numbers are ASCII digits only.
    private static func droppingPartSuffix(_ name: String) -> String {
        let patterns = [#/\.part[0-9]+\.rar$/#.ignoresCase(), #/\.[0-9]{3}$/#, #/\.[rz][0-9]{2}$/#.ignoresCase()]
        for pattern in patterns {
            if let match = name.firstMatch(of: pattern), match.range.lowerBound > name.startIndex {
                return String(name[..<match.range.lowerBound])
            }
        }
        return name
    }
}
