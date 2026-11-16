import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Extract Here splits archive paths on the "/" scalar, never on Characters. A "/" followed by a combining mark
/// (U+0301) or a ZWJ, or preceded by a Prepend scalar (U+0600), is part of one Character that is not "/". A
/// Character split kept the whole path as a one-item result's name, so the result went into a folder of that name
/// beside the archive instead of beside it. Every test uses a root of its own: `Downloads` holds the archive (so
/// the hidden outer folder and the model's staging stay inside the root), `Downloads Outside` is its sibling.
@MainActor
struct ExtractHereCharSplitTests {
    nonisolated static let deviceToken = "feedface00000000"

    struct Hidden: Sendable, CustomTestStringConvertible {
        /// The folder the Character split sees above the item: what sits beside the archive.
        let folder: String
        /// The archive item.
        let item: String
        /// The item's own name.
        let leaf: String
        let label: String
        var testDescription: String { label }
    }

    nonisolated static let hidden = [
        Hidden(folder: "d", item: "d/\u{301}x", leaf: "\u{301}x", label: "combining mark after /"),
        Hidden(folder: "d", item: "d/\u{200D}x", leaf: "\u{200D}x", label: "ZWJ after /"),
        Hidden(folder: "d\u{600}", item: "d\u{600}/x", leaf: "x", label: "Prepend before /"),
    ]

    /// What is beside the archive under the item's folder name.
    enum Beside: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case realFolder, symlinkOutside, nothing
        var testDescription: String { rawValue }
    }

    /// A fresh root holding `Downloads/archive.zip` and `Downloads Outside` with a file of its own.
    struct Layout {
        let root: URL
        let downloads: URL
        let outside: URL
        let archive: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ExtractHereCharSplitTests-\(UUID().uuidString)", isDirectory: true)
            downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            outside = root.appendingPathComponent("Downloads Outside", isDirectory: true)
            archive = downloads.appendingPathComponent("archive.zip")
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("archive".utf8).write(to: archive)
            try Data("secret".utf8).write(to: outside.appendingPathComponent("secret"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func model(_ entries: [ArchiveEntry], archive: URL) -> ArchiveModel {
        let model = ArchiveModel(reader: FakeReader(entries: entries, url: archive), undoManager: nil)
        // Never the app's defaults: a token of the test's own, real renames.
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: deviceToken,
                                                          rename: ExtractionFileSystem.system.rename)
        return model
    }

    /// Every item under `url` (lstat, never following a link), with a file's contents, a folder as "dir", a
    /// symlink as "-> target". Keys are the paths' scalars.
    nonisolated static func snapshot(_ url: URL) throws -> [[UInt32]: String] {
        var result: [[UInt32]: String] = [:]
        func walk(_ folder: URL, _ prefix: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                let item = folder.appendingPathComponent(name)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                var status = stat()
                guard lstat(item.path, &status) == 0 else { continue }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    result[scalars(path)] = "dir"
                    try walk(item, path)
                case S_IFLNK:
                    result[scalars(path)] = "-> " + (try FileManager.default.destinationOfSymbolicLink(atPath: item.path))
                default:
                    result[scalars(path)] = String(decoding: try Data(contentsOf: item), as: UTF8.self)
                }
            }
        }
        try walk(url, "")
        return result
    }

    nonisolated static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

    /// One item behind a hidden "/" lands beside the archive under its own name, whatever is beside the archive
    /// under its folder's name: a real folder stays empty, a symlink to `Downloads Outside` is not followed (and
    /// nothing outside changes), and no folder there is no error. The hidden outer folder is gone.
    @Test(arguments: hidden, Beside.allCases)
    func aNestedItemBehindAHiddenSlashLandsBesideTheArchive(_ c: Hidden, _ beside: Beside) async throws {
        let layout = try Layout()
        defer { layout.remove() }
        let besideURL = layout.downloads.appendingPathComponent(c.folder)
        switch beside {
        case .realFolder:
            try FileManager.default.createDirectory(at: besideURL, withIntermediateDirectories: false)
        case .symlinkOutside:
            try FileManager.default.createSymbolicLink(at: besideURL, withDestinationURL: layout.outside)
        case .nothing:
            break
        }
        let outsideBefore = try Self.snapshot(layout.outside)
        let downloadsBefore = try Self.snapshot(layout.downloads)
        let model = Self.model([ExtractHereListings.folder(c.folder), ExtractHereListings.file(c.item)],
                               archive: layout.archive)
        #expect(model.item(at: c.item) != nil)

        let plan = try #require(ExtractHerePlan.make([c.item], in: model, archiveURL: layout.archive))
        let placed = try await ExtractHereService.extract(plan, from: model, nextTo: layout.archive, progress: nil)

        #expect(Self.scalars(placed.lastPathComponent) == Self.scalars(c.leaf))
        #expect(placed.deletingLastPathComponent().standardizedFileURL.path
                    == layout.downloads.standardizedFileURL.path)
        #expect(try Self.snapshot(layout.outside) == outsideBefore, "nothing outside changes")
        var expected = downloadsBefore
        expected[Self.scalars(c.leaf)] = c.item
        #expect(try Self.snapshot(layout.downloads) == expected,
                "only the item is new beside the archive (no hidden folder left); the folder beside it stays as it was")
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted()
                    == ["Downloads", "Downloads Outside"])
    }

    /// A split archive whose set name is nothing but dots ("..", "."), so `ArchiveBaseName` gives the part's own name.
    struct DotSet: Sendable, CustomTestStringConvertible {
        let parts: [String]
        var testDescription: String { parts[0] }
    }

    nonisolated static let dotSets = [
        DotSet(parts: ["...part1.rar", "...part2.rar"]),
        DotSet(parts: ["..part1.rar", "..part2.rar"]),
    ]

    /// Several items of a set whose name is a dot name go in a new folder beside the archive, named after the
    /// archive's own file. The first part is in the way, so the folder is that name with " 2". Nothing is placed
    /// loose in the archive's folder, nothing outside it changes, and no hidden folder is left.
    @Test(arguments: dotSets)
    func aVolumeSetNamedWithDotsIsWrappedBesideTheArchive(_ set: DotSet) async throws {
        let layout = try Layout()
        defer { layout.remove() }
        let parts = set.parts.map { layout.downloads.appendingPathComponent($0) }
        for part in parts { try Data("part".utf8).write(to: part) }
        let outsideBefore = try Self.snapshot(layout.outside)
        let downloadsBefore = try Self.snapshot(layout.downloads)
        let reader = FakeReader(entries: [ExtractHereListings.file("a.txt"), ExtractHereListings.file("b.txt")],
                                url: parts[0], volumeURLs: parts)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: Self.deviceToken,
                                                          rename: ExtractionFileSystem.system.rename)

        let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: parts[0]))
        let folder = set.parts[0] + " 2"
        #expect(plan == .wrapped(folderName: set.parts[0], paths: ["a.txt", "b.txt"]))
        var placed: URL?
        do {
            placed = try await ExtractHereService.extract(plan, from: model, nextTo: parts[0], progress: nil)
        } catch {
            Issue.record(error, "Extract Here of the set fails")
        }

        #expect(placed?.lastPathComponent == folder)
        #expect(placed?.deletingLastPathComponent().standardizedFileURL.path
                    == layout.downloads.standardizedFileURL.path)
        #expect(try Self.snapshot(layout.outside) == outsideBefore, "nothing outside changes")
        var expected = downloadsBefore
        expected[Self.scalars(folder)] = "dir"
        expected[Self.scalars(folder + "/a.txt")] = "a.txt"
        expected[Self.scalars(folder + "/b.txt")] = "b.txt"
        #expect(try Self.snapshot(layout.downloads) == expected,
                "only the new folder is beside the archive: nothing loose, no hidden folder left")
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted()
                    == ["Downloads", "Downloads Outside"])
    }
}
