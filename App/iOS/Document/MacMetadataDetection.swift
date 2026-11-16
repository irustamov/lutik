import KernirCore

/// Whether an archive holds Finder metadata a plain save would ask about: a
/// `__MACOSX` tree at any depth, `._*` files, and anything stored under a `._*` folder. KernirCore only, no
/// UIKit, so a SwiftPM package on macOS can test it.
///
/// `.DS_Store` alone doesn't count: it is Finder view state with no user content, so a `.DS_Store`-only
/// archive is never asked about. A strip still removes it (`ArchiveWriteOptions.excludesMacMetadata`), and
/// the question's text says so. Pass the source entries only (`model.reader?.entries`): additions keep their
/// originals on disk, so stripping them loses nothing.
enum MacMetadataDetection {
    /// True when an entry is Finder metadata a strip would remove for being `__MACOSX` or AppleDouble, not
    /// counting `.DS_Store`.
    static func containsMacMetadata(_ entries: [ArchiveEntry]) -> Bool {
        entries.contains { isMacMetadata(path: $0.path) }
    }

    /// `ArchiveEntry.isMacOSMetadata(path:)` (a `__MACOSX` component anywhere, a `._*` last component), or a
    /// `._*` folder above the entry, as the engine's strip and the model's hiding treat it.
    static func isMacMetadata(path: String) -> Bool {
        ArchiveEntry.isMacOSMetadata(path: path) || hasAppleDoubleComponent(path)
    }

    /// A component starting with `._`, at any depth. Split on the UTF-8 byte "/" and compared as bytes, never
    /// as Characters: `"._\u{301}x".hasPrefix("._")` is false (`_\u{301}` is one Character), and "/" followed
    /// by a combining mark is one Character that isn't "/" (see KernirCore's `MacOSMetadata`).
    private static func hasAppleDoubleComponent(_ path: String) -> Bool {
        path.utf8.split(separator: UInt8(ascii: "/")).contains { $0.starts(with: "._".utf8) }
    }
}
