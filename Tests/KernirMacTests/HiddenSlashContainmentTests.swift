import Testing
import Foundation
@testable import Kernir
import KernirCore

/// ArchiveModel splits archive paths on the "/" scalar, never on Characters, and never moves anything out of the
/// folder the user chose. A "/" followed by a combining mark (U+0301) or a ZWJ, or preceded by a Prepend scalar
/// (U+0600), is part of one Character that is not "/". A Character split hid that separator from the conflict
/// check and the folder making above an extracted item, so the final rename followed a symlink already in the
/// chosen folder (`dest/link -> outside` + item `link/\u{301}pwn` landed in `outside`; Replace swapped out a file
/// there, Keep Both put its copy there). `ArchiveModel.checkContained` refuses such a move even when the split
/// misses the separator. Every test uses folders of its own; "outside" is a sibling of the destination whose
/// name starts with the destination's, so a containment check without a "/" boundary lets it through.
@MainActor
struct HiddenSlashContainmentTests {
    nonisolated static let deviceToken = "feedface00000000"

    struct Hidden: Sendable, CustomTestStringConvertible {
        /// The symlink already in the destination, to `outside`.
        let link: String
        /// The archive item that goes through it.
        let item: String
        /// The item's name in `link`.
        let leaf: String
        let label: String
        var testDescription: String { label }
    }

    nonisolated static let hidden = [
        Hidden(link: "link", item: "link/\u{301}pwn", leaf: "\u{301}pwn", label: "combining mark after /"),
        Hidden(link: "link", item: "link/\u{200D}pwn", leaf: "\u{200D}pwn", label: "ZWJ after /"),
        Hidden(link: "link\u{600}", item: "link\u{600}/pwn", leaf: "pwn", label: "Prepend before /"),
    ]

    enum Answer: String, Sendable, CaseIterable, CustomTestStringConvertible {
        /// No answer: the item just moves (the link is the conflict, which throws).
        case move, replace, keepBoth
        var testDescription: String { rawValue }
        var resolution: ExtractionConflictResolution? {
            switch self {
            case .move: nil
            case .replace: .replace
            case .keepBoth: .keepBoth
            }
        }
    }

    /// A fresh root holding `Extracted` (the destination) and `Extracted Outside` with a file of its own.
    struct Layout {
        let root: URL
        let destination: URL
        let outside: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("HiddenSlashContainmentTests-\(UUID().uuidString)", isDirectory: true)
            destination = root.appendingPathComponent("Extracted", isDirectory: true)
            outside = root.appendingPathComponent("Extracted Outside", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: outside.appendingPathComponent("secret"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func model(_ entries: [ArchiveEntry]) -> ArchiveModel {
        let model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
        // Never the app's defaults: a token of the test's own, real renames.
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: deviceToken) { from, to, flags in
            renamex_np(from, to, flags) == 0 ? 0 : errno
        }
        return model
    }

    static func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    static func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }

    /// Every item under `url` (lstat, never following a link), with a file's contents, a folder as "dir", a
    /// symlink as "-> target". Keys are compared on scalars.
    nonisolated static func snapshot(_ url: URL) throws -> [[UInt32]: String] {
        var result: [[UInt32]: String] = [:]
        func walk(_ folder: URL, _ prefix: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                let item = folder.appendingPathComponent(name)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let key = path.unicodeScalars.map(\.value)
                var status = stat()
                guard lstat(item.path, &status) == 0 else { continue }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    result[key] = "dir"
                    try walk(item, path)
                case S_IFLNK:
                    result[key] = "-> " + (try FileManager.default.destinationOfSymbolicLink(atPath: item.path))
                default:
                    result[key] = String(decoding: try Data(contentsOf: item), as: UTF8.self)
                }
            }
        }
        try walk(url, "")
        return result
    }

    nonisolated static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

    nonisolated static func isSymlink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK
    }

    /// `dest/link -> outside` × {mark, ZWJ, Prepend} × {move, Replace, Keep Both}: nothing is created, changed
    /// or removed in `outside`. The link is the conflict, as a plain "/" makes it: a move without an answer
    /// throws it before anything moves, Replace puts the item's folder where the link was, Keep Both puts it
    /// beside. For Replace and Keep Both, `outside` holds a file of the item's name, which Replace would have
    /// swapped out through the link; for a move nothing of that name is there, so nothing is in the way.
    @Test(arguments: hidden, Answer.allCases)
    func nothingGoesThroughALinkInTheDestination(_ c: Hidden, _ answer: Answer) async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try FileManager.default.createSymbolicLink(at: layout.destination.appendingPathComponent(c.link),
                                                   withDestinationURL: layout.outside)
        if answer != .move {
            try Data("victim".utf8).write(to: layout.outside.appendingPathComponent(c.leaf))
        }
        let outsideBefore = try Self.snapshot(layout.outside)
        let model = Self.model([Self.file(c.item)])
        #expect(model.item(at: c.item) != nil)

        let conflicts = model.extractionConflicts([c.item], in: layout.destination)
        #expect(conflicts.map(Self.scalars) == [Self.scalars(c.link)], "the link is the conflict")
        var resolutions: [String: ExtractionConflictResolution] = [:]
        if let resolution = answer.resolution {
            for conflict in conflicts { resolutions[conflict] = resolution }
        }
        var thrown: (any Error)?
        do {
            try await model.extract([c.item], to: layout.destination, resolutions: resolutions, progress: nil)
        } catch {
            thrown = error
        }

        #expect(try Self.snapshot(layout.outside) == outsideBefore, "CONTAINMENT: outside unchanged")
        #expect(!FileManager.default.fileExists(atPath: layout.root.appendingPathComponent(c.leaf).path),
                "CONTAINMENT: nothing beside the destination")
        let link = layout.destination.appendingPathComponent(c.link)
        let placed = link.appendingPathComponent(c.leaf)
        switch answer {
        case .move:
            let conflict = try #require(thrown as? ExtractionConflictError)
            #expect(conflict.paths.map(Self.scalars) == [Self.scalars(c.link)])
            #expect(Self.isSymlink(link))
            #expect(try Self.snapshot(layout.destination).count == 1, "only the link: no staging left")
        case .replace:
            #expect(thrown == nil)
            #expect(!Self.isSymlink(link))
            #expect((try? String(contentsOf: placed, encoding: .utf8)) == c.item)
        case .keepBoth:
            #expect(thrown == nil)
            #expect(Self.isSymlink(link))
            let kept = layout.destination.appendingPathComponent(c.link + " 2").appendingPathComponent(c.leaf)
            #expect((try? String(contentsOf: kept, encoding: .utf8)) == c.item)
        }
    }

    /// The plain "/" was already the link's conflict: still so, and still nothing goes through it.
    @Test(arguments: Answer.allCases)
    func aPlainSlashThroughALinkIsStillTheLinksConflict(_ answer: Answer) async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try FileManager.default.createSymbolicLink(at: layout.destination.appendingPathComponent("link"),
                                                   withDestinationURL: layout.outside)
        try Data("victim".utf8).write(to: layout.outside.appendingPathComponent("pwn"))
        let outsideBefore = try Self.snapshot(layout.outside)
        let model = Self.model([Self.folder("link"), Self.file("link/pwn")])

        #expect(model.extractionConflicts(["link"], in: layout.destination) == ["link"])
        let resolutions = answer.resolution.map { ["link": $0] } ?? [:]
        var thrown: (any Error)?
        do {
            try await model.extract(["link"], to: layout.destination, resolutions: resolutions, progress: nil)
        } catch {
            thrown = error
        }

        #expect(try Self.snapshot(layout.outside) == outsideBefore, "CONTAINMENT: outside unchanged")
        let pwn = layout.destination.appendingPathComponent("link/pwn")
        switch answer {
        case .move:
            #expect(thrown is ExtractionConflictError)
        case .replace:
            #expect(thrown == nil)
            #expect((try? String(contentsOf: pwn, encoding: .utf8)) == "link/pwn")
        case .keepBoth:
            #expect(thrown == nil)
            let kept = layout.destination.appendingPathComponent("link 2/pwn")
            #expect((try? String(contentsOf: kept, encoding: .utf8)) == "link/pwn")
        }
    }

    /// Extracting only an item behind a hidden slash makes the folders above it first, as for a plain "/".
    @Test(arguments: ["d/\u{301}x", "d/\u{200D}x", "d\u{600}/x"])
    func anItemBehindAHiddenSlashGetsItsFolderMade(_ item: String) async throws {
        let layout = try Layout()
        defer { layout.remove() }
        let model = Self.model([Self.file(item)])

        let placed = try await model.extract([item], to: layout.destination, progress: nil)

        let file = layout.destination.appendingPathComponent(item)
        #expect(placed.map(\.path) == [file.path])
        #expect((try? String(contentsOf: file, encoding: .utf8)) == item)
        let folder = Self.scalars(ArchiveEntry.parentPath(of: item))
        #expect(try Self.snapshot(layout.destination) == [folder: "dir", Self.scalars(item): item])
    }

    /// Row 3: Extract All of `d` and `d/\u{301}x`, which a Character-split tree listed side by side, and a request
    /// for both paths (as such a tree's Extract All made it). `d` brings `\u{301}x` along, so the second item is
    /// part of the first move instead of a rename that stopped the extraction part-way (ENOENT).
    @Test func extractAllWithAnItemInsideAnotherCompletes() async throws {
        let layout = try Layout()
        defer { layout.remove() }
        let item = "d/\u{301}x"
        let model = Self.model([Self.folder("d"), Self.file(item)])
        let want = [Self.scalars("d"): "dir", Self.scalars(item): item]

        let all = layout.root.appendingPathComponent("All", isDirectory: true)
        let placedAll = try await model.extract(nil, to: all, progress: nil)
        #expect(placedAll.count == model.items.count)
        #expect(placedAll.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Self.snapshot(all) == want)

        let both = layout.root.appendingPathComponent("Both", isDirectory: true)
        let placed = try await model.extract(["d", item], to: both, progress: nil)
        #expect(placed.map(\.path) == [both.appendingPathComponent("d").path, both.appendingPathComponent(item).path])
        #expect(try Self.snapshot(both) == want)
    }

    /// Deleting `d` hides `d/\u{301}x` too (the writer drops it on save).
    @Test(arguments: ["d/\u{301}x", "d/\u{200D}x", "d/e/\u{301}x"])
    func deletingAFolderHidesAnItemBehindAHiddenSlash(_ item: String) {
        let model = Self.model([Self.folder("d"), Self.file(item), Self.file("other")])
        #expect(model.item(at: item) != nil)

        model.remove(["d"])

        #expect(model.item(at: item) == nil)
        #expect(!model.items.flattened().contains { Self.scalars($0.path) == Self.scalars(item) })
        #expect(model.items.map(\.path) == ["other"])
    }

    /// A pending folder from disk named `d` with `\u{301}x` and `y` in it. Disk names may start with a mark.
    static func pendingFolder() throws -> (URL, ArchiveModel) {
        let disk = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiddenSlashContainmentTests-\(UUID().uuidString)", isDirectory: true)
        let d = disk.appendingPathComponent("d", isDirectory: true)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("e"), withIntermediateDirectories: true)
        for name in ["\u{301}x", "y", "e/\u{301}z", "e/w"] {
            try Data(name.utf8).write(to: d.appendingPathComponent(name))
        }
        let model = Self.model([Self.file("other")])
        model.add([d], to: "")
        return (disk, model)
    }

    /// A deleted child of a pending folder addition is not written, and its siblings still are.
    @Test(arguments: ["d/\u{301}x", "d/e/\u{301}z"])
    func aDeletedChildOfAPendingFolderIsNotWritten(_ deleted: String) throws {
        let (disk, model) = try Self.pendingFolder()
        defer { try? FileManager.default.removeItem(at: disk) }
        #expect(model.item(at: deleted) != nil)

        model.remove([deleted])

        let added = Self.written(model.changes.additions)
        #expect(!added.contains(Self.scalars(deleted)), "the deleted child is not written")
        let all = ["d/\u{301}x", "d/y", "d/e/\u{301}z", "d/e/w"]
        #expect(Set(added) == Set(all.filter { $0 != deleted }.map(Self.scalars)), "the others still are")
    }

    /// Deleting a plain sibling keeps a child whose name starts with a mark (its parent is found on scalars).
    @Test func deletingASiblingKeepsAChildBehindAHiddenSlash() throws {
        let (disk, model) = try Self.pendingFolder()
        defer { try? FileManager.default.removeItem(at: disk) }

        model.remove(["d/y"])

        #expect(Set(Self.written(model.changes.additions))
                == Set(["d/\u{301}x", "d/e/\u{301}z", "d/e/w"].map(Self.scalars)))
    }

    /// The archive paths every addition writes: files only, from disk.
    nonisolated static func written(_ additions: [ArchiveChangeSet.Addition]) -> [[UInt32]] {
        var result: [[UInt32]] = []
        for addition in additions {
            let base = addition.destinationDirectory.isEmpty
                ? addition.sourceURL.lastPathComponent
                : addition.destinationDirectory + "/" + addition.sourceURL.lastPathComponent
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: addition.sourceURL.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                result.append(scalars(base))
                continue
            }
            let enumerator = FileManager.default.enumerator(at: addition.sourceURL, includingPropertiesForKeys: [.isDirectoryKey])
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
                let relative = String(url.path.unicodeScalars.dropFirst(addition.sourceURL.path.unicodeScalars.count + 1))
                result.append(scalars(base + "/" + relative))
            }
        }
        return result
    }
}

/// The model's path helpers give exactly what the Character-based ones gave for ordinary paths, and split on
/// the "/" scalar otherwise.
struct ArchiveModelPathHelperTests {
    static let ordinary = [
        "", "a", "a/b", "a/b/c.txt", "README.md", "src/main.swift", ".hidden/x", "a/.b/._c",
        "caf\u{E9}/men\u{FC}.txt", "cafe\u{301}/menu\u{308}.txt", "e\u{301}", "x/e\u{301}",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}/family", "a b/c d.pdf", "\u{65E5}\u{672C}/\u{8A9E}.txt",
        "Report 2024 2.pdf", "deep/a/b/c/d/e/f", "\u{05D0}\u{05D1}/\u{0627}\u{0644}", "a\\b/c", "..x/y..",
        "\u{1F1FA}\u{1F1F8}/flag", "\u{D55C}\u{AE00}/\u{1100}\u{1161}\u{11A8}", "__MACOSX/._a",
    ]

    static func characterParent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func characterIsCovered(_ path: String, by paths: Set<String>) -> Bool {
        var current = path
        while !current.isEmpty {
            if paths.contains(current) { return true }
            current = characterParent(current)
        }
        return false
    }

    @Test(arguments: ordinary)
    func ordinaryPathsAreUnchanged(_ path: String) {
        #expect(ArchiveModel.parentPath(of: path).unicodeScalars.elementsEqual(Self.characterParent(path).unicodeScalars))
        // Covering sets: every ancestor of the path, a sibling, a name sharing a prefix, NFC/NFD twins.
        var sets: [Set<String>] = [[], ["a"], ["a/b"], ["ab"], ["caf\u{E9}"], ["cafe\u{301}"], ["deep/a/b"], [path]]
        var ancestor = Self.characterParent(path)
        while !ancestor.isEmpty {
            sets.append([ancestor])
            ancestor = Self.characterParent(ancestor)
        }
        for set in sets {
            #expect(ArchiveModel.isCovered(path, by: set) == Self.characterIsCovered(path, by: set), "\(set)")
        }
    }

    @Test(arguments: [("d/\u{301}x", "d"), ("d/\u{200D}x", "d"), ("d\u{600}/x", "d\u{600}"),
                      ("a/\u{301}b/c", "a/\u{301}b")])
    func hiddenSlashesSeparate(_ path: String, _ parent: String) {
        #expect(ArchiveModel.parentPath(of: path).unicodeScalars.elementsEqual(parent.unicodeScalars))
        #expect(ArchiveModel.isCovered(path, by: [parent]))
        #expect(!ArchiveModel.isCovered(parent, by: [path]))
    }

    static func characterCompanion(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard !name.hasPrefix("._") else { return nil }
        let parent = characterParent(path)
        return parent.isEmpty ? "._" + name : parent + "/._" + name
    }

    static func scalars(_ path: String?) -> [UInt32]? { path.map { $0.unicodeScalars.map(\.value) } }

    @Test(arguments: ordinary)
    func ordinaryCompanionsAreUnchanged(_ path: String) {
        #expect(Self.scalars(ArchiveModel.companionPath(of: path)) == Self.scalars(Self.characterCompanion(path)))
    }

    /// The companion sits beside the item: its name and its folder both come from the "/" scalar.
    @Test(arguments: [("a/\u{301}b", "a/._\u{301}b"), ("a/\u{200D}b", "a/._\u{200D}b"), ("a\u{600}/b", "a\u{600}/._b"),
                      ("\u{301}b", "._\u{301}b"), ("b", "._b"), ("a/b", "a/._b")])
    func companionsSplitOnTheSlashScalar(_ path: String, _ companion: String) {
        #expect(Self.scalars(ArchiveModel.companionPath(of: path)) == Self.scalars(companion))
    }

    /// A companion has none of its own, also when a mark or ZWJ follows its "._".
    @Test(arguments: ["a/._\u{301}b", "a/._\u{200D}b", "a\u{600}/._b", "._\u{301}b", "._b", "a/._b"])
    func aCompanionHasNoCompanion(_ path: String) {
        #expect(ArchiveModel.companionPath(of: path) == nil)
    }
}

/// `ArchiveModel.checkContained`: the guard before every rename or swap into a destination folder.
struct ContainmentGuardTests {
    @Test func aTargetWhoseParentResolvesOutsideIsRefused() throws {
        let layout = try HiddenSlashContainmentTests.Layout()
        defer { layout.remove() }
        let destination = layout.destination
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("sub/inner"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("link"),
                                                   withDestinationURL: layout.outside)
        // A sibling whose name extends the destination's: inside only for a check without a "/" boundary.
        try FileManager.default.createSymbolicLink(atPath: destination.appendingPathComponent("rel").path,
                                                   withDestinationPath: "../Extracted Outside")
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("up"),
                                                   withDestinationURL: layout.root)

        for inside in ["x", "sub/x", "sub/inner/x", "new", "sub/missing", "link", "\u{301}x"] {
            #expect(throws: Never.self, "\(inside)") {
                try ArchiveModel.checkContained(destination.appendingPathComponent(inside), in: destination)
            }
        }
        for outside in ["link/x", "link/\u{301}x", "rel/x", "up/x", "up/Extracted Outside/x", "../x",
                        "sub/../../x"] {
            #expect(throws: ExtractionContainmentError.self, "\(outside)") {
                try ArchiveModel.checkContained(destination.appendingPathComponent(outside), in: destination)
            }
        }
        // Through a symlinked destination (as /tmp is): compared after resolving both.
        let alias = layout.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        #expect(throws: Never.self) {
            try ArchiveModel.checkContained(alias.appendingPathComponent("sub/x"), in: alias)
        }
        #expect(throws: ExtractionContainmentError.self) {
            try ArchiveModel.checkContained(alias.appendingPathComponent("link/x"), in: alias)
        }

        // What the user reads: the item's name and the chosen folder's.
        do {
            try ArchiveModel.checkContained(destination.appendingPathComponent("link/\u{301}pwn"), in: destination)
            Issue.record("not refused")
        } catch let error as ExtractionContainmentError {
            #expect(error.name.unicodeScalars.elementsEqual("\u{301}pwn".unicodeScalars))
            #expect(error.localizedDescription == String(
                localized: "“\(error.name)” wasn't extracted to “\("Extracted")”: its path has a link where a folder was expected.",
                table: "Shared"))
        }
    }

    /// Replace without RENAME_SWAP steps the old item aside first: never one that the destination only reaches
    /// through a link, so the user's file outside is neither taken into staging (and deleted) nor replaced.
    @Test(arguments: ["link/\u{301}pwn", "link/pwn"])
    func replaceSteppingAsideNeverReachesThroughALink(_ path: String) throws {
        let layout = try HiddenSlashContainmentTests.Layout()
        defer { layout.remove() }
        let destination = layout.destination
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("link"),
                                                   withDestinationURL: layout.outside)
        let leaf = ArchiveEntry.name(of: path)
        try Data("victim".utf8).write(to: layout.outside.appendingPathComponent(leaf))
        let staging = destination.appendingPathComponent(".kernir-\(HiddenSlashContainmentTests.deviceToken)-1-x",
                                                         isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let staged = staging.appendingPathComponent("new")
        try Data("new".utf8).write(to: staged)
        let before = try HiddenSlashContainmentTests.snapshot(layout.outside)

        #expect(throws: ExtractionContainmentError.self) {
            try ArchiveModel.replaceSteppingAside(destination.appendingPathComponent(path), with: staged, path: path,
                                                  staging: staging, in: destination)
        }
        #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == before, "CONTAINMENT: outside unchanged")
        #expect(FileManager.default.fileExists(atPath: staged.path), "the new item stays in staging")
    }

    /// Extract Here's last move: a name with a hidden slash never goes through a link beside the archive.
    @Test(arguments: ["link/\u{301}pwn", "link/\u{200D}pwn"])
    func uniquePlacementNeverMovesThroughALink(_ name: String) throws {
        let layout = try HiddenSlashContainmentTests.Layout()
        defer { layout.remove() }
        try FileManager.default.createSymbolicLink(at: layout.destination.appendingPathComponent("link"),
                                                   withDestinationURL: layout.outside)
        let source = layout.destination.appendingPathComponent(".kernir-staged")
        try Data("pwn".utf8).write(to: source)
        let before = try HiddenSlashContainmentTests.snapshot(layout.outside)

        #expect(throws: ExtractionContainmentError.self) {
            try UniquePlacement.place(source, named: name, in: layout.destination, isDirectory: false)
        }
        #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == before, "CONTAINMENT: outside unchanged")
        #expect(FileManager.default.fileExists(atPath: source.path), "the source stays where it was")
    }
}
