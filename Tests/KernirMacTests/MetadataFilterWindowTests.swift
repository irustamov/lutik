import Testing
import Foundation
@testable import Kernir
import KernirCore

/// The window leaves out what "Exclude Mac metadata" leaves out of the archive, so with
/// the toggle on it shows what will be written, and its item count and size count only that.
/// The engine's rule: additions are filtered by on-disk name at any depth (a
/// `__MACOSX` folder and everything under it, any `._*`, any `.DS_Store`); kept entries of an
/// opened archive by `MacOSMetadata` (`__MACOSX` at any depth, `._*` and `.DS_Store` at
/// any depth). The window matches: `ArchiveModel.isHidden` uses the same `__MACOSX` rule,
/// so a `__MACOSX` nested in an added folder is hidden too.
@MainActor
struct MetadataFilterWindowTests {
    /// Every visible path, depth first.
    private func visiblePaths(_ model: ArchiveModel) -> [String] {
        func walk(_ items: [ArchiveItem]) -> [String] {
            items.flatMap { [$0.path] + walk($0.children ?? []) }
        }
        return walk(model.items)
    }

    /// A fresh folder holding `files` (relative path → contents); the caller removes `root`.
    private func makeFolder(_ files: [(String, String)]) throws -> (root: URL, folder: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataFilterWindowTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return (root, folder)
    }

    @Test func metadataAddedAtTheTopIsNotShownOrCounted() throws {
        let (root, folder) = try makeFolder([(".DS_Store", "finder"), ("._a", "apple double"),
                                             ("__MACOSX/x", "resource fork"), ("a", "abc")])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        model.add([".DS_Store", "._a", "__MACOSX", "a"].map { folder.appendingPathComponent($0) }, to: "")

        #expect(visiblePaths(model) == ["a"])
        #expect(model.itemCount == 1)
        #expect(model.totalSize == 3)
    }

    @Test func metadataInAnAddedFolderIsNotShownOrCounted() throws {
        let (root, folder) = try makeFolder([(".DS_Store", "finder"), ("._a", "apple double"), ("a", "abc")])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        model.add([folder], to: "")

        #expect(visiblePaths(model) == ["folder", "folder/a"])
        #expect(model.itemCount == 2)
        #expect(model.totalSize == 3)
    }

    /// With `excludesMacMetadata` on, `AdditionWalker` drops a `__MACOSX` folder at any depth
    /// of an added folder. `isHidden` hides a `__MACOSX` component at any depth,
    /// whatever the flag, as it hides the root one, so the window never lists it.
    @Test func aMACOSXFolderNestedInAnAddedFolderIsNotShownOrCounted() throws {
        let (root, folder) = try makeFolder([("a", "abc"), ("__MACOSX/x", "resource fork"),
                                             ("sub/b", "bb"), ("sub/__MACOSX/y", "resource fork")])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        model.add([folder], to: "")

        #expect(Set(visiblePaths(model)) == ["folder", "folder/a", "folder/sub", "folder/sub/b"])
        #expect(model.itemCount == 4)
        #expect(model.totalSize == 5)
    }

    /// `pendingEntries` once called `skipDescendants()` after a `.DS_Store` file, which skipped the
    /// next folder the enumerator reached, so its contents were written (`AdditionWalker` only skips
    /// the `.DS_Store` itself) but not shown. Fixed in `ArchiveModel`; this pins the fix.
    @Test func aDSStoreDoesNotHideTheFolderAfterIt() throws {
        let (root, folder) = try makeFolder([(".DS_Store", "finder"), ("sub/y", "data"), ("z", "zz")])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        model.add([folder], to: "")

        #expect(visiblePaths(model) == ["folder", "folder/sub", "folder/sub/y", "folder/z"])
        #expect(model.totalSize == 6)
    }

    @Test func metadataInTheSourceArchiveIsNotShownOrCounted() {
        func file(_ path: String, size: Int64) -> ArchiveEntry {
            ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: size, modificationDate: nil)
        }
        func folder(_ path: String) -> ArchiveEntry {
            ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
        }
        let reader = FakeReader(entries: [
            file("b", size: 5),
            file("._b", size: 100),
            folder("__MACOSX"),
            file("__MACOSX/._b", size: 100),
            folder("dir"),
            file("dir/c", size: 7),
            file("dir/._c", size: 100),
            file("__MACOSX/dir/._c", size: 100),
        ])
        let model = ArchiveModel(reader: reader, undoManager: nil)

        #expect(Set(visiblePaths(model)) == ["b", "dir", "dir/c"])
        #expect(model.itemCount == 3)
        #expect(model.totalSize == 12)
    }
}
