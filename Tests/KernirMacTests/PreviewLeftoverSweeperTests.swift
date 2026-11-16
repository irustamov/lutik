import Foundation
import Testing
@testable import Kernir

/// The launch sweep of leftover Quick Look stand-in roots: only `Kernir-Preview-<UUID>`
/// directories directly in the folder go; lookalikes, symlinks, files, live or held roots and
/// everything else stay. Every test sweeps a fresh folder of its own, never the real temporary
/// folder, and removes only that folder.
struct PreviewLeftoverSweeperTests {
    private let fileManager = FileManager.default

    /// A fresh parent folder of the test's own; removed afterwards.
    private func withParent(_ body: (URL) throws -> Void) throws {
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("PreviewLeftoverSweeperTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: parent) }
        #expect(!PreviewLeftoverSweeper.refuses(parent: parent))
        try body(parent)
    }

    private func rootName(_ uuid: UUID = UUID()) -> String {
        PreviewLeftoverSweeper.prefix + uuid.uuidString
    }

    @discardableResult
    private func makeDirectory(_ relativePath: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFile(_ relativePath: String, in parent: URL, contents: String = "x") throws -> URL {
        let url = parent.appendingPathComponent(relativePath, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// True if something (a symlink itself included) is at `url`.
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func names(_ urls: [URL]) -> [String] {
        urls.map(\.lastPathComponent).sorted()
    }

    @Test("Root names: exactly the prefix plus an uppercase UUID", arguments: [
        ("Kernir-Preview-0F8E2C1A-5B3D-4E7F-9A1B-2C3D4E5F6A7B", true),
        ("Kernir-Preview-0f8e2c1a-5b3d-4e7f-9a1b-2c3d4e5f6a7b", false),
        ("Kernir-Preview-0F8E2C1A-5B3D-4E7F-9A1B-2C3D4E5F6A7B.old", false),
        ("Kernir-Preview-0F8E2C1A-5B3D-4E7F-9A1B-2C3D4E5F6A7", false),
        ("Kernir-Preview-0F8E2C1A5B3D4E7F9A1B2C3D4E5F6A7B", false),
        ("Kernir-Preview-", false),
        ("Kernir-Preview-not-a-uuid", false),
        ("kernir-preview-0F8E2C1A-5B3D-4E7F-9A1B-2C3D4E5F6A7B", false),
        ("Kernir-0F8E2C1A-5B3D-4E7F-9A1B-2C3D4E5F6A7B", false),
        ("Kernir", false),
        (" Kernir-Preview-0F8E2C1A-5B3D-4E7F-9A1B-2C3D4E5F6A7B", false),
    ])
    func rootNames(name: String, isRoot: Bool) {
        #expect(PreviewLeftoverSweeper.isRootName(name) == isRoot)
    }

    @Test("A stand-in store's root name is one the sweeper takes")
    func storeRootNameMatches() {
        #expect(PreviewLeftoverSweeper.isRootName(PreviewLeftoverSweeper.prefix + UUID().uuidString))
    }

    @Test("A leftover root goes with everything in it; a symlink inside doesn't take its target")
    func removesRootWithContents() throws {
        try withParent { parent in
            let outside = try makeFile("outside.txt", in: parent, contents: "keep")
            let root = try makeDirectory(rootName(), in: parent)
            let batch = try makeDirectory("\(UUID().uuidString)/\(UUID().uuidString)", in: root)
            try makeFile("Budget.csv.txt", in: batch)
            try fileManager.createSymbolicLink(at: batch.appendingPathComponent("link"), withDestinationURL: outside)

            let removed = PreviewLeftoverSweeper(parent: parent).sweep()

            #expect(names(removed) == [root.lastPathComponent])
            #expect(!exists(root))
            #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        }
    }

    @Test("Mixed folder: only the valid stale root goes; the lookalikes and the symlink's target stay")
    func onlyValidRootInMixedFolder() throws {
        try withParent { parent in
            let stale = try makeDirectory(rootName(), in: parent)
            try makeFile("a/b.png", in: stale)
            let other = try makeDirectory("Something-Else", in: parent)
            let target = try makeDirectory("target", in: parent)
            let targetFile = try makeFile("inside.txt", in: target)
            let link = parent.appendingPathComponent(rootName())
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            let foreign = try makeDirectory(PreviewLeftoverSweeper.prefix + "1234-not-a-uuid", in: parent)
            try makeFile("data", in: foreign)

            let removed = PreviewLeftoverSweeper(parent: parent).sweep()

            #expect(names(removed) == [stale.lastPathComponent])
            #expect(!exists(stale))
            #expect(exists(other))
            #expect(exists(link))
            #expect(exists(target) && exists(targetFile))
            #expect(exists(foreign.appendingPathComponent("data")))
        }
    }

    @Test("Lookalikes, symlinks, files and nested roots are left alone")
    func skipsLookalikes() throws {
        try withParent { parent in
            let uuid = UUID()
            let target = try makeDirectory("target", in: parent)
            let targetFile = try makeFile("inside.txt", in: target)
            let link = parent.appendingPathComponent(rootName())
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            var kept = [
                try makeDirectory(PreviewLeftoverSweeper.prefix + "not-a-uuid", in: parent),
                try makeDirectory(rootName(uuid) + "x", in: parent),
                try makeDirectory(PreviewLeftoverSweeper.prefix + uuid.uuidString.lowercased(), in: parent),
                try makeDirectory("Kernir-\(UUID().uuidString)", in: parent),
                try makeDirectory("Kernir", in: parent),
                try makeFile(rootName(), in: parent),
            ]
            kept.append(try makeDirectory("Kernir/\(rootName())", in: parent))
            kept.append(try makeDirectory("one/two/\(rootName())", in: parent))
            for folder in kept where folder.hasDirectoryPath {
                try makeFile("keep.txt", in: folder)
            }

            #expect(PreviewLeftoverSweeper(parent: parent).sweep().isEmpty)

            for url in kept { #expect(exists(url), "\(url.lastPathComponent)") }
            #expect(exists(link))
            #expect(exists(targetFile))
        }
    }

    @Test("A root this process uses stays; the stale one beside it goes")
    func skipsLiveRoot() throws {
        try withParent { parent in
            let live = try makeDirectory(rootName(), in: parent)
            let stale = try makeDirectory(rootName(), in: parent)

            let removed = PreviewLeftoverSweeper(parent: parent) { $0.lastPathComponent == live.lastPathComponent }.sweep()

            #expect(names(removed) == [stale.lastPathComponent])
            #expect(exists(live))
            #expect(!exists(stale))
        }
    }

    @Test("A root another holder has locked stays until the lock goes")
    func skipsLockedRoot() throws {
        try withParent { parent in
            let root = try makeDirectory(rootName(), in: parent)
            let lock = try #require(PreviewRootLock(holding: root))

            #expect(PreviewLeftoverSweeper(parent: parent).sweep().isEmpty)
            #expect(exists(root))

            lock.unlock()
            #expect(names(PreviewLeftoverSweeper(parent: parent).sweep()) == [root.lastPathComponent])
        }
    }

    @Test("The lock takes only a real directory, and one holder at a time")
    func lockRules() throws {
        try withParent { parent in
            let root = try makeDirectory(rootName(), in: parent)
            let link = parent.appendingPathComponent(rootName())
            try fileManager.createSymbolicLink(at: link, withDestinationURL: root)
            let file = try makeFile(rootName(), in: parent)

            #expect(PreviewRootLock(holding: link) == nil)
            #expect(PreviewRootLock(holding: file) == nil)
            #expect(PreviewRootLock(holding: parent.appendingPathComponent(rootName())) == nil)

            var first = PreviewRootLock(holding: root)
            #expect(first != nil)
            #expect(PreviewRootLock(holding: root) == nil)
            first = nil
            #expect(PreviewRootLock(holding: root) != nil)
        }
    }

    @Test("A missing folder sweeps nothing and doesn't fail")
    func missingParent() throws {
        try withParent { parent in
            let missing = parent.appendingPathComponent("missing", isDirectory: true)
            #expect(PreviewLeftoverSweeper(parent: missing).sweep().isEmpty)
        }
    }

    /// Checks the guard only; nothing here sweeps the real temporary folder.
    @Test("While tests run, a sweep of the real temporary folder is refused")
    func refusesRealTemporaryFolder() {
        #expect(PreviewLeftoverSweeper.isHostedByTests)
        #expect(PreviewLeftoverSweeper.refuses(parent: fileManager.temporaryDirectory))
    }
}
