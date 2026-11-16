import Foundation

/// Finder metadata: a `__MACOSX` tree at any depth (Finder's zips put one at the root; a nested one comes from a
/// Finder zip extracted by another tool and zipped again) and AppleDouble `._name` files (Finder, ditto, Apple's
/// bsdtar). The engine lists and repacks these like any other entry; only a write with
/// `ArchiveWriteOptions.excludesMacMetadata` leaves them out (`isExcludedOnDisk`, `isExcludedEntry`).
enum MacOSMetadata {
    static let folderName = "__MACOSX"

    /// `ArchiveEntry.isMacOSMetadata`: a `._*` last component, or a `__MACOSX` component anywhere in the path.
    static func isMetadata(path: String) -> Bool {
        isAppleDouble(lastComponent(path)) || hasFolderComponent(path)
    }

    // Paths are split on the byte "/" (0x2F, which in UTF-8 is only ever the scalar "/"), as `EntryPath` splits on
    // scalars, and names are compared as bytes. Never on Characters: "/" followed by a combining mark (U+0301) is one
    // Character that is not "/", so a Character split joins the components on either side of it
    // (`__MACOSX/\u{301}x` would hold no `__MACOSX`), and `"._\u{301}x".hasPrefix("._")` is false (`_\u{301}` is one
    // Character). The targets are ASCII with no canonical equivalent but themselves, so bytes compare as String does.
    private static let slash = UInt8(ascii: "/")

    private static func components(_ path: String) -> [Substring.UTF8View] {
        path.utf8.split(separator: slash)
    }

    private static func lastComponent(_ path: String) -> Substring.UTF8View {
        let u = path.utf8
        var end = u.endIndex
        while end != u.startIndex, u[u.index(before: end)] == slash { end = u.index(before: end) }
        let start = u[..<end].lastIndex(of: slash).map(u.index(after:)) ?? u.startIndex
        return u[start..<end]
    }

    private static func isAppleDouble(_ name: some Collection<UInt8>) -> Bool {
        name.starts(with: "._".utf8)
    }

    private static func isNamed(_ name: some Collection<UInt8>, _ target: String) -> Bool {
        name.elementsEqual(target.utf8)
    }

    /// A path component that is exactly `__MACOSX` (case-sensitive), at any depth: the folder
    /// itself and everything beneath it. As at the root, an entry named `__MACOSX` matches whether it is a folder or
    /// a file (a path has no kind). `__MACOSXfoo`, `foo__MACOSX`, `__macosx` do not match.
    static func hasFolderComponent(_ path: String) -> Bool {
        // Byte scan first: most paths hold no "__MACOSX" at all, and then no component can be one.
        let u = path.utf8
        var i = u.startIndex
        var found = false
        while let j = u[i...].firstIndex(of: 0x5F) {
            if u[j...].starts(with: folderName.utf8) { found = true; break }
            i = u.index(after: j)
        }
        guard found else { return false }
        return components(path).contains { isNamed($0, folderName) }
    }

    /// Additions: a file or folder named `__MACOSX`, `._*` or `.DS_Store` on disk, at any depth. A folder
    /// goes with its contents.
    static func isExcludedOnDisk(name: String) -> Bool {
        isNamed(name.utf8, folderName) || isAppleDouble(name.utf8) || isNamed(name.utf8, ".DS_Store")
    }

    /// Archive paths (kept source entries, and where an addition lands): the path or one of its ancestors is
    /// `ArchiveEntry.isMacOSMetadata` (a `__MACOSX` tree at any depth, a `._*` name) or is named `.DS_Store`.
    /// Whatever lies beneath an excluded folder is excluded with it, so the folder cannot come back as a
    /// synthesized parent.
    static func isExcludedEntry(path: String) -> Bool {
        components(path).contains { isNamed($0, folderName) || isAppleDouble($0) || isNamed($0, ".DS_Store") }
    }

    /// For each path `d/n`: `__MACOSX/d/n` (removing it removes everything beneath), `d/._n` and
    /// `__MACOSX/d/._n`, with `d/` omitted at the top level. Only candidates present in `entries` count.
    /// Only the root `__MACOSX` holds companions: that is where Finder, ditto and Archive Utility put AppleDouble
    /// files, and the only one they read back. A nested `__MACOSX` (a foreign extraction zipped again) is hidden and
    /// stripped as metadata but pairs with nothing.
    static func companions(of paths: [String], in entries: [ArchiveEntry]) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let present = Set(entries.map(\.path))
        var result = Set<String>()
        for raw in paths {
            guard let path = EntryPath.normalize(raw) else { continue }
            let scalars = path.unicodeScalars
            let slash = scalars.lastIndex(of: "/")
            let dirPrefix = slash.map { String(scalars[..<$0]) + "/" } ?? ""
            let name = slash.map { String(scalars[scalars.index(after: $0)...]) } ?? path
            for candidate in ["__MACOSX/" + path, dirPrefix + "._" + name, "__MACOSX/" + dirPrefix + "._" + name]
            where present.contains(candidate) {
                result.insert(candidate)
            }
        }
        return result
    }
}
