import Foundation
import KernirCore

/// Which entries of an open archive Lutik opens as an archive of their own (issue #6).
///
/// By name, never by content (`Archive.detectFormat` calls a `.docx`, `.epub` or `.xlsx` a ZIP, and
/// those belong to their own apps) and never by `UTType` conformance (on macOS 26 `jar` conforms to
/// `public.zip-archive`, `docx` does not). The entry's last extension must map to one of
/// `KernirDocumentTypes.identifiers`, compared exactly. So `.tar.gz` counts through its last part
/// `gz`, and the developer packages (`KernirDocumentTypes.packageTypes`: jar, apk, whl, nupkg,
/// vsix, xpi…) don't, which keeps them with their default app.
///
/// The answer doesn't depend on the machine: a static extension table (`identifierByExtension`) is the
/// only source, and the system's `UTType(filenameExtension:)` is never consulted. An extension outside
/// the table (`pax`, which no declaration of the app lists) is not an archive.
enum NestedArchive {
    /// Extension (lowercase) → the identifier of `KernirDocumentTypes.identifiers` it stands for. Covers
    /// only extensions the app or the system declare for those identifiers (the
    /// iOS system doesn't declare iso; no OS declares rar, zst or lha), minus the split-set parts, which
    /// `isVolumePart` rejects first. Tested: every value is in `KernirDocumentTypes.identifiers` and
    /// every identifier but the volume set is reachable.
    static let identifierByExtension: [String: String] = [
        "zip": "public.zip-archive",
        "7z": "org.7-zip.7-zip-archive",
        "rar": "com.rarlab.rar-archive",
        "tar": "public.tar-archive",
        "gtar": "org.gnu.gnu-tar-archive",
        "gz": "org.gnu.gnu-zip-archive", "gzip": "org.gnu.gnu-zip-archive",
        "tgz": "org.gnu.gnu-zip-tar-archive",
        "bz2": "public.bzip2-archive", "bz": "public.bzip2-archive",
        "tbz": "public.tar-bzip2-archive", "tbz2": "public.tar-bzip2-archive",
        "xz": "org.tukaani.xz-archive",
        "txz": "org.tukaani.tar-xz-archive",
        "zst": "com.facebook.zst-archive", "tzst": "com.facebook.zst-archive",
        "iso": "public.iso-image",
        "cpio": "public.cpio-archive",
        "xar": "com.apple.xar-archive",
        "cab": "com.microsoft.cab",
        "lha": "cx.c3.lha-archive", "lzh": "cx.c3.lha-archive",
    ]

    /// A single part of a split set isn't an archive on its own, so it doesn't open: `.001`…, `.z01`…,
    /// old-style RAR `.r00`…`.r99`, `.s00`… (the app's Info.plist imports r00…r99 as rar, which is why
    /// this runs before any type lookup) and `.part2.rar`… (`.part1.rar` and `.part01.rar` are the first
    /// volume and stay; so does a plain `.rar`). Same rules as `ServicesRequest.part(of:)` in App/macOS,
    /// which could reuse this one.
    static func isVolumePart(lowercasedName name: String) -> Bool {
        if let match = name.firstMatch(of: #/\.part(\d+)\.rar$/#), let number = Int(match.output.1) {
            return number >= 2
        }
        return name.firstMatch(of: #/\.(\d{3,}|[r-z]\d{2})$/#) != nil
    }

    /// Whether the entry called `name` opens in Lutik as a nested archive. Callers pass the entry's name
    /// or path (case-insensitive, the last component counts); a trailing "/" marks a folder, never an archive.
    static func isArchiveEntry(name: String) -> Bool {
        guard !name.hasSuffix("/") else { return false }
        let last = (name as NSString).lastPathComponent.lowercased()
        let ext = (last as NSString).pathExtension
        guard !ext.isEmpty, !isVolumePart(lowercasedName: last) else { return false }
        guard let id = identifierByExtension[ext] else { return false }
        return identifiers.contains(id)
    }

    /// Whether `entry` opens in Lutik as a nested archive. Callers holding an `ArchiveEntry` use this
    /// overload: a folder is never an archive, whatever its name (`backup.zip` as a folder has no
    /// trailing "/" in `ArchiveEntry.path`; `isDirectory` flags it). Files follow the name rule.
    static func isArchiveEntry(_ entry: ArchiveEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        return isArchiveEntry(name: entry.path)
    }

    /// The identifiers that count, without the volume set.
    private static let identifiers: Set<String> =
        Set(KernirDocumentTypes.identifiers).subtracting([KernirDocumentTypes.volumeSetIdentifier])
}
