import Testing
import Foundation
@testable import Kernir
import KernirCore

/// `ArchiveModel.isHidden` compares UTF-8 bytes, as KernirCore's `MacOSMetadata.isMetadata` does, never
/// Characters. A combining mark (U+0301) right after "/" or "_" makes one Character with it, so on
/// Characters `._\u{301}x` has no `._` prefix, `a/._\u{301}b` holds no `/._` and `__MACOSX/\u{301}x` has
/// no `__MACOSX/` prefix, though core counts all three as metadata. Each case pins core's answer too,
/// so a change on either side shows here. A `__MACOSX` below the root is metadata to core and
/// hidden by `isHidden` too, which asks core for it.
@MainActor
struct HiddenMetadataScalarTests {
    private nonisolated static func file(_ path: String, size: Int64 = 1) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: size, modificationDate: nil)
    }

    private nonisolated static func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }

    private func makeModel(_ entries: [ArchiveEntry]) -> ArchiveModel {
        ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiddenMetadataScalarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every visible path, depth first.
    private func visiblePaths(_ model: ArchiveModel) -> [String] {
        func walk(_ items: [ArchiveItem]) -> [String] {
            items.flatMap { [$0.path] + walk($0.children ?? []) }
        }
        return walk(model.items)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let path: String
        /// `ArchiveEntry.isMacOSMetadata(path:)`, KernirCore's answer.
        let core: Bool
        let hidden: Bool
        var testDescription: String { path.unicodeScalars.map { $0.isASCII ? "\($0)" : "U+\(String($0.value, radix: 16, uppercase: true))" }.joined() }
    }

    nonisolated static let cases: [Case] = [
        // The `._` prefix check: "_\u{301}" is one Character.
        Case(path: "._\u{301}x", core: true, hidden: true),
        // The `/._` check.
        Case(path: "a/._\u{301}b", core: true, hidden: true),
        // The `__MACOSX/` prefix check: "/\u{301}" is one Character.
        Case(path: "__MACOSX/\u{301}x", core: true, hidden: true),
        // The mark is part of the first component, which is then not `__MACOSX`: shown, as core says.
        Case(path: "__MACOSX\u{301}/x", core: false, hidden: false),
        // The `== "__MACOSX"` check: an entry named `__MACOSX`, even a file.
        Case(path: "__MACOSX", core: true, hidden: true),
        // Below the root: metadata to core and hidden, at any depth.
        Case(path: "a/__MACOSX/b", core: true, hidden: true),
        // Below the root behind a hidden "/": "/\u{301}" is one Character, so a Character split sees no `__MACOSX`.
        Case(path: "a/__MACOSX/\u{301}x", core: true, hidden: true),
    ]

    @Test(arguments: cases)
    func sourceEntryIsHiddenByBytes(_ c: Case) {
        #expect(ArchiveEntry.isMacOSMetadata(path: c.path) == c.core)
        let model = makeModel([Self.file("keep"), Self.file(c.path)])

        #expect((model.item(at: c.path) == nil) == c.hidden)
        #expect(visiblePaths(model).contains("keep"))
        #expect(visiblePaths(model).contains(c.path) == !c.hidden)
    }

    /// The rebuild of pending additions: an added file named `._\u{301}x` is hidden like a source one,
    /// and still packed.
    @Test func addedDotUnderscoreWithACombiningMarkIsHiddenButPacked() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "._\u{301}x"
        let url = dir.appendingPathComponent(name)
        try Data("apple double".utf8).write(to: url)
        let model = makeModel([Self.file("keep")])

        model.add([url], to: "")

        #expect(visiblePaths(model) == ["keep"])
        #expect(model.itemCount == 1)
        #expect(model.changes.additions.count == 1)
    }

    /// Extract's own check: asking for hidden metadata by path writes nothing and throws nothing.
    @Test(arguments: ["__MACOSX/\u{301}x", "._\u{301}x", "a/._\u{301}b"])
    func extractingAHiddenPathIsANoop(_ path: String) async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel([Self.folder("a"), Self.file("a/c"), Self.file(path)])

        try await model.extract([path], to: dir, progress: nil)

        // fileExists as well as the listing: Foundation can hide AppleDouble names from listings.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// `sourceDirectoriesWithMetadata`: a folder holding a `._\u{301}` name is extracted child by child,
    /// so the metadata is left behind.
    @Test(arguments: [["a"], nil] as [[String]?])
    func extractingAFolderLeavesItsDotUnderscoreBehind(_ paths: [String]?) async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel([Self.folder("a"), Self.file("a/c"), Self.file("a/._\u{301}b")])
        #expect(visiblePaths(model) == ["a", "a/c"])

        try await model.extract(paths, to: dir, progress: nil)

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
        }
        #expect(exists("a/c"))
        #expect(!exists("a/._\u{301}b"))
    }
}
