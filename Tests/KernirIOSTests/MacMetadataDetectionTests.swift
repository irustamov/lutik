import Foundation
import Testing
import KernirCore
@testable import Kernir

/// `MacMetadataDetection`: whether an archive's source entries hold Mac metadata the save asks about
/// (`__MACOSX` at any depth, `._*`, entries under a `._*` folder; never `.DS_Store` alone). KernirCore only:
/// the same file runs in a macOS SwiftPM mirror.
struct MacMetadataDetectionTests {
    private func entries(_ paths: [String]) -> [ArchiveEntry] {
        paths.map { ArchiveEntry(path: $0, isDirectory: $0.hasSuffix("/"), size: 0, compressedSize: 0,
                                 modificationDate: nil) }
    }

    private func detects(_ paths: [String]) -> Bool {
        MacMetadataDetection.containsMacMetadata(entries(paths))
    }

    @Test(arguments: [
        ["__MACOSX/"],
        ["__MACOSX/._a"],
        ["a", "photos/__MACOSX/img.jpg"],
        ["deep/er/__MACOSX/"],
        ["._a"],
        ["docs/readme.md", "docs/._readme.md"],
        ["a/b/c/._d"],
    ])
    func detectsMacOSXAndAppleDoubleAtAnyDepth(_ paths: [String]) {
        #expect(detects(paths))
    }

    /// `.DS_Store` is Finder view state: alone it never asks (the strip still removes it).
    @Test func ignoresDSStoreOnly() {
        #expect(!detects([".DS_Store", "sub/", "sub/.DS_Store", "sub/nested/.DS_Store", "sub/file"]))
        #expect(!detects([".DS_Store/", ".DS_Store/inside.txt"]))
    }

    /// Only an exact `__MACOSX` component, case-sensitive, and only a `._` name prefix.
    @Test func ignoresLookalikes() {
        #expect(!detects(["__MACOSXfoo/", "__MACOSXfoo/a", "foo__MACOSX", "__macosx/a", "photos/__MACOSX.txt"]))
        #expect(!detects(["a._b", "dir/a._b", "x._y/z", "_.a", "..a", ".", "_", ".localized", "Icon\r"]))
        #expect(!detects([]))
    }

    /// Split on the byte "/" and compared as bytes: a combining mark after "/" or after "._" changes nothing.
    @Test func combiningMarkAfterSlashStillSplits() {
        #expect(detects(["d/._x/\u{301}f"]))
        #expect(detects(["d/._\u{301}x/f"]))
        #expect(detects(["__MACOSX/\u{301}x"]))
        #expect(!detects(["d/\u{301}._x"]))
    }

    /// An entry stored under a `._*` folder, with no entry for the folder itself.
    @Test func entryUnderAppleDoubleFolderCounts() {
        #expect(detects(["._folder/file.txt"]))
        #expect(detects(["a/._b/c/d.txt"]))
        #expect(MacMetadataDetection.isMacMetadata(path: "a/._b/c/d.txt"))
        #expect(!MacMetadataDetection.isMacMetadata(path: "a/b/c/d.txt"))
    }

    /// The real fixtures, read with the engine (nothing is written). `macos-junk.zip` also holds
    /// `.localized` and `Icon\r`: content, never metadata.
    @Test(arguments: [
        ("zip/macos-finder.zip", true),
        ("zip/macos-junk.zip", true),
        ("zip/macos-nested-junk.zip", true),
        ("zip/deflate.zip", false),
    ])
    func fixtures(_ relativePath: String, _ expected: Bool) async throws {
        let reader = try await Archive.open(at: Fixture.root.appendingPathComponent(relativePath))
        #expect(MacMetadataDetection.containsMacMetadata(reader.entries) == expected)
        #expect(!MacMetadataDetection.isMacMetadata(path: ".localized"))
        #expect(!MacMetadataDetection.isMacMetadata(path: "Icon\r"))
    }
}
