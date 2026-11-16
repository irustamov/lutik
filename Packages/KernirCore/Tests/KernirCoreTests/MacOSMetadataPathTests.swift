import Foundation
import Testing
@testable import KernirCore

/// The Mac metadata rules split a path on the scalar "/" (UTF-8 0x2F), as `EntryPath` does, never on
/// Characters. "/" followed by a combining mark (U+0301) is one Character that is not "/", so a Character split joins
/// the components on either side of it: `__MACOSX/\u{301}x` would hold no `__MACOSX` component, and the last
/// component of `._d/\u{301}x` would be `._d/\u{301}x`. A Character `hasPrefix("._")` also misses `._` followed by a
/// combining mark (`_\u{301}` is one Character), which is Finder's AppleDouble name for a file whose name starts
/// with one. The component after such a "/" starts with U+0301, so it is never `__MACOSX`, `.DS_Store` or `._*`.
@Suite struct MacOSMetadataPathTests {
    static let mark = "\u{301}"

    static func entry(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: nil, modificationDate: nil)
    }

    /// Metadata by `isMacOSMetadata` (a `__MACOSX` component anywhere, or a `._*` last component); the write-side
    /// rule `isExcludedEntry` agrees on each of these.
    static let metadata = [
        "__MACOSX/\(mark)x", "__MACOSX/\(mark)", "d/__MACOSX/\(mark)x", "a/b/__MACOSX/\(mark)/c",
        "._\(mark)x", "d/._\(mark)x", "__MACOSX/d/._\(mark)x",
        // After a combining "/": the later components are still seen.
        "a/\(mark)b/__MACOSX/c", "\(mark)/__MACOSX", "a/\(mark)/._x", "a/\(mark)b/._x",
        // A Prepend scalar (U+0600) before "/" and a ZWJ after it hide the separator the same way.
        "d\u{600}/__MACOSX/x", "d\u{600}/._x", "a/\u{200D}/._x", "__MACOSX/\u{200D}x",
    ]

    /// Content by both rules: the component after "/\u{301}" starts with U+0301.
    static let content = [
        "d/\(mark)x", "d/\(mark)", "\(mark)x", "d/\(mark)._x", "d/\(mark)__MACOSX/x", "d/\(mark).DS_Store",
        "a/\(mark)b/c",
    ]

    @Test(arguments: metadata)
    func isMetadataSplitsOnScalars(_ path: String) {
        #expect(Self.entry(path).isMacOSMetadata)
        #expect(MacOSMetadata.isExcludedEntry(path: path))
    }

    @Test(arguments: content)
    func contentStaysContent(_ path: String) {
        #expect(!Self.entry(path).isMacOSMetadata)
        #expect(!MacOSMetadata.isExcludedEntry(path: path))
    }

    /// Only the last component counts for `._`: a file inside a folder named `._d` is not metadata itself (the
    /// folder is), though the write-side rule drops it with its excluded ancestor.
    @Test(arguments: ["._d/\(mark)x", "._d/\(mark)", "e/._d/\(mark)x"])
    func appleDoubleFolderChildIsNotMetadataButIsExcluded(_ path: String) {
        #expect(!Self.entry(path).isMacOSMetadata)
        #expect(MacOSMetadata.isExcludedEntry(path: path))
    }

    /// `.DS_Store` (write side) as a component before or after a combining "/".
    @Test(arguments: ["d/.DS_Store/\(mark)x", ".DS_Store/\(mark)", "a/\(mark)b/.DS_Store", "a/\(mark)/.DS_Store"])
    func dsStoreComponentIsExcluded(_ path: String) {
        #expect(MacOSMetadata.isExcludedEntry(path: path))
    }

    // MARK: - `ArchiveEntry.isMacOSMetadata(path:)` (the public predicate)

    /// Every path the instance property is tested on here and in TreeTests, plus ordinary content.
    static let parityPaths = metadata + content + ["._d/\(mark)x", "._d/\(mark)", "e/._d/\(mark)x"] + [
        "__MACOSX", "__MACOSX/d/._a.txt", "d/._a.txt", "d/a.txt", "d/_a.txt", "MACOSX/a", "a/__MACOSX",
        "a/b/__MACOSX/c/d", "_/__MACOSX", "__MACOSXfoo/__MACOSX/z", "__MACOSXfoo", "a/__macosx/x", "a/__MACOSX_old/x",
        "a/x__MACOSX__/y", ".DS_Store", "d/.DS_Store", "", "readme.txt", "caf\u{E9}/._x", "._", "a/._",
    ]

    /// Same answer as the instance property, for a folder and a file alike (a path has no kind).
    @Test(arguments: parityPaths)
    func staticPredicateMatchesTheProperty(_ path: String) {
        for directory in [false, true] {
            let e = ArchiveEntry(path: path, isDirectory: directory, size: nil, compressedSize: nil,
                                 modificationDate: nil)
            #expect(ArchiveEntry.isMacOSMetadata(path: path) == e.isMacOSMetadata, "\(path.debugDescription)")
        }
    }

    /// A directory path with a trailing "/" (or several) is judged by its components.
    @Test(arguments: ["__MACOSX/", "a/__MACOSX/", "__MACOSX/d/", "._x/", "d/._x/", "__MACOSX//", "d/._x//",
                      "__MACOSX/\(mark)x/", "d\u{600}/._x/"])
    func trailingSlashMetadata(_ path: String) {
        #expect(ArchiveEntry.isMacOSMetadata(path: path))
    }

    @Test(arguments: ["d/", "a/b/", "__MACOSXfoo/", "d/_x/", "d/\(mark)._x/", "/", "//"])
    func trailingSlashContent(_ path: String) {
        #expect(!ArchiveEntry.isMacOSMetadata(path: path))
    }

    /// `.DS_Store` is content here; only a write with `excludesMacMetadata` leaves it out.
    @Test(arguments: [".DS_Store", "d/.DS_Store", ".DS_Store/", "a/b/.DS_Store", ".DS_Store/x"])
    func dsStoreIsNotMetadata(_ path: String) {
        #expect(!ArchiveEntry.isMacOSMetadata(path: path))
        #expect(MacOSMetadata.isExcludedEntry(path: path))
    }

    @Test func onDiskAppleDoubleBeforeCombiningMark() {
        #expect(MacOSMetadata.isExcludedOnDisk(name: "._\(Self.mark)x"))
        #expect(!MacOSMetadata.isExcludedOnDisk(name: "\(Self.mark)._x"))
    }

    /// `companions` already splits on scalars; pinned so its root-only pairing stays as it is. Every companion it
    /// returns is metadata by `isMacOSMetadata`.
    @Test func companionsAroundCombiningSlash() {
        let m = Self.mark
        let paths = ["d", "d/\(m)x", "d/._\(m)x", "__MACOSX", "__MACOSX/d", "__MACOSX/d/\(m)x", "__MACOSX/d/._\(m)x",
                     "\(m)y", "._\(m)y", "__MACOSX/._\(m)y", "a/\(m)b/c", "a/\(m)b/._c", "__MACOSX/a/\(m)b/._c",
                     "a/__MACOSX/._\(m)z", "a/\(m)z"]
        let entries = paths.map(Self.entry)
        let cases: [(String, Set<String>)] = [
            ("d/\(m)x", ["d/._\(m)x", "__MACOSX/d/\(m)x", "__MACOSX/d/._\(m)x"]),
            ("\(m)y", ["._\(m)y", "__MACOSX/._\(m)y"]),
            ("a/\(m)b/c", ["a/\(m)b/._c", "__MACOSX/a/\(m)b/._c"]),
            ("a/\(m)z", []),
        ]
        for (path, expected) in cases {
            let found = Archive.macOSCompanions(of: [path], in: entries)
            #expect(found == expected, "\(path)")
            for c in found { #expect(Self.entry(c).isMacOSMetadata, "\(c)") }
        }
    }
}
