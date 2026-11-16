import Testing
import Foundation
@testable import Kernir
import KernirCore

/// No export hands another app a symbolic link that leads out of the item it is in
/// (`ExportLinkSweep`): Copy's files (`ArchiveClipboard.export`), drag-out and preview (`ArchiveModel.localFileURL`),
/// Finder's file promise (`ArchiveDragOut.write`), and the sweep itself on folders made by hand. Every test works
/// in a temporary folder of its own; "outside" is a sibling folder there, never one of the user's.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ExportLinkSweepTests {
    /// A test device token, so staging never reads or writes the standard defaults (`.system` does).
    private static let testDeviceToken = "5eec5eec5eec5eec"
    private static let foldsCase = DestinationCaseSensitivity(exists: { _ in true },
                                                              supportsCaseSensitiveNames: { _ in false })
    private static let secretText = "the user's own secret"

    /// The test's folders: `work` (archives), `temporary` (exports), `destination` (drops) and `outside` with
    /// `secret` in it, the file a crafted link reaches for.
    struct World {
        let root: URL
        var work: URL { root.appendingPathComponent("work", isDirectory: true) }
        var temporary: URL { root.appendingPathComponent("temporary", isDirectory: true) }
        var destination: URL { root.appendingPathComponent("destination", isDirectory: true) }
        var outside: URL { root.appendingPathComponent("outside", isDirectory: true) }
        var secret: URL { outside.appendingPathComponent("secret") }
    }

    private func makeWorld() throws -> World {
        let world = World(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLinkSweepTests-\(UUID().uuidString)", isDirectory: true))
        for folder in [world.work, world.temporary, world.destination, world.outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(Self.secretText.utf8).write(to: world.secret)
        return world
    }

    /// Releases this process's export parent in the world's temporary folder and removes the world.
    private func discard(_ world: World) {
        ArchiveClipboard.removeAllExports(in: world.temporary)
        try? FileManager.default.removeItem(at: world.root)
    }

    /// Nothing outside changed: only `secret`, with its text, one link, not a symlink.
    private func expectOutsideUntouched(_ world: World) throws {
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.outside.path) == ["secret"])
        var status = stat()
        try #require(lstat(world.secret.path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFREG)
        #expect(status.st_nlink == 1)
        #expect(String(decoding: try Data(contentsOf: world.secret), as: UTF8.self) == Self.secretText)
    }

    private func makeModel(_ archive: URL) async throws -> ArchiveModel {
        let model = ArchiveModel(reader: try await Archive.open(at: archive), undoManager: nil)
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: Self.testDeviceToken) { from, to, flags in
            renamex_np(from, to, flags) == 0 ? 0 : errno
        }
        model.caseSensitivity = Self.foldsCase
        return model
    }

    // MARK: - Tar archives

    enum Entry {
        case folder(String)
        case file(String, String)
        case link(String, String)
        case hard(String, String)
    }

    /// `entries` as a ustar archive (type 5, 0, 2 and 1), "@O" in a link target spelled as the world's
    /// outside folder, written into `work`.
    private func archive(_ entries: [Entry], in world: World) throws -> URL {
        var data = Data()
        for entry in entries {
            let (name, flag, target, body): (String, Character, String, Data) = switch entry {
            case let .folder(path): (path + "/", "5", "", Data())
            case let .file(path, text): (path, "0", "", Data(text.utf8))
            case let .link(path, to): (path, "2", to, Data())
            case let .hard(path, to): (path, "1", to, Data())
            }
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int) {
                for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte }
            }
            put(name, at: 0)
            put(flag == "5" ? "0000755" : "0000644", at: 100)
            put("0000000", at: 108)
            put("0000000", at: 116)
            put(String(format: "%011o", body.count), at: 124)
            put("00000000000", at: 136)
            header[156] = flag.asciiValue!
            put(target.replacingOccurrences(of: "@O", with: world.outside.path), at: 157)
            put("ustar", at: 257)
            put("00", at: 263)
            put("        ", at: 148)
            put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148)
            header[154] = 0
            data += header + body + Data(count: (512 - body.count % 512) % 512)
        }
        let url = world.work.appendingPathComponent("evil-\(UUID().uuidString).tar")
        try (data + Data(count: 1024)).write(to: url)
        return url
    }

    // MARK: - Checks

    /// Every symlink below `item` (lstat, nothing followed), by path relative to it, with its target.
    private func links(in item: URL) throws -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ folder: String, _ relative: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder) {
                let path = folder + "/" + name
                var status = stat()
                try #require(lstat(path, &status) == 0)
                if status.st_mode & S_IFMT == S_IFDIR { try walk(path, relative + name + "/") }
                if status.st_mode & S_IFMT == S_IFLNK {
                    found[relative + name] = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                }
            }
        }
        try walk(item.path, "")
        return found
    }

    /// No symlink in `item` resolves outside it; `item` itself is no symlink.
    private func expectNoEscape(_ item: URL) throws {
        var status = stat()
        try #require(lstat(item.path, &status) == 0)
        #expect(status.st_mode & S_IFMT != S_IFLNK)
        guard status.st_mode & S_IFMT == S_IFDIR else { return }
        let root = try #require(realpath(item.path, nil).map { defer { free($0) }; return String(cString: $0) })
        for link in try links(in: item).keys {
            let resolved = realpath(item.appendingPathComponent(link).path, nil).map {
                defer { free($0) }
                return String(cString: $0)
            }
            #expect(resolved == root || resolved?.hasPrefix(root + "/") == true, "\(link) -> \(resolved ?? "nil")")
        }
    }

    private func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    // MARK: - Copy's files

    @Test func topLevelAbsoluteLinkFailsTheCopy() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([.link("photo.jpg", "@O/secret")], in: world))
        defer { model.removeTemporaryFiles() }

        await #expect(throws: ExportedLinksError(names: ["photo.jpg"])) {
            try await ArchiveClipboard.export(["photo.jpg"], from: model, in: world.temporary, progress: nil)
        }
        let parent = ArchiveClipboard.exportParent(in: world.temporary)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] == [])
        try expectOutsideUntouched(world)
    }

    @Test func topLevelDotDotLinkIsLeftOut() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([.link("up", "../../../outside/secret"), .file("a.txt", "A")],
                                                    in: world))
        defer { model.removeTemporaryFiles() }

        let export = try await ArchiveClipboard.export(["up", "a.txt"], from: model, in: world.temporary, progress: nil)

        #expect(export.urls.map(\.lastPathComponent) == ["a.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: export.folder.path) == ["a.txt"])
        try expectOutsideUntouched(world)
    }

    @Test func linksOutOfAFolderAreRemoved() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([
            .folder("d"), .file("d/f", "F"), .folder("d/sub"),
            .link("d/abs", "@O/secret"),
            .link("d/up", "../../../../outside/secret"),
            .link("d/sub/up", "../../secret"),
            .link("d/dangle", "missing"),
        ], in: world))
        defer { model.removeTemporaryFiles() }

        let export = try await ArchiveClipboard.export(["d"], from: model, in: world.temporary, progress: nil)

        #expect(export.urls.map(\.lastPathComponent) == ["d"])
        let d = export.urls[0]
        #expect(try links(in: d) == [:])
        #expect(try String(decoding: Data(contentsOf: d.appendingPathComponent("f")), as: UTF8.self) == "F")
        #expect(exists(d.appendingPathComponent("sub")))
        try expectNoEscape(d)
        try expectOutsideUntouched(world)
    }

    /// Pins today's behavior, which is not final (Copy may come to say so): a folder holding a link out and
    /// a regular file copies without a word. The copy has the file and no link, the export doesn't throw, and
    /// it returns the folder alone (no notice of the removed link anywhere). Change this test if that changes.
    @Test func copyDropsOutwardLinksSilently() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([
            .folder("d"), .file("d/f", "F"), .link("d/out", "@O/secret"),
        ], in: world))
        defer { model.removeTemporaryFiles() }

        let export = try await ArchiveClipboard.export(["d"], from: model, in: world.temporary, progress: nil)

        #expect(export.urls.map(\.lastPathComponent) == ["d"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: export.folder.path) == ["d"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: export.urls[0].path) == ["f"])
        #expect(try String(decoding: Data(contentsOf: export.urls[0].appendingPathComponent("f")), as: UTF8.self)
                == "F")
        try expectOutsideUntouched(world)
    }

    /// `s` -> "." keeps `x` -> "s/../secret" inside on paper, but on disk it reaches the sibling `secret`;
    /// `y` -> "s/../top/f" ends inside but passes through the export folder on the way. `s` itself loops
    /// (it is the item), so it goes too.
    @Test func physicalEscapeThroughALinkIsRemoved() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([
            .folder("top"), .file("top/f", "F"),
            .link("top/s", "."),
            .link("top/x", "s/../secret"),
            .link("top/y", "s/../top/f"),
            .file("secret", "sibling"),
        ], in: world))
        defer { model.removeTemporaryFiles() }

        let export = try await ArchiveClipboard.export(["top", "secret"], from: model, in: world.temporary,
                                                       progress: nil)

        #expect(export.urls.map(\.lastPathComponent) == ["top", "secret"])
        #expect(try links(in: export.urls[0]) == [:])
        try expectNoEscape(export.urls[0])
        try expectOutsideUntouched(world)
    }

    /// A bundle's own links stay: `Versions/Current` -> "A" and the links through it.
    @Test func containedLinksAreKept() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([
            .folder("Fw.framework"), .folder("Fw.framework/Versions"), .folder("Fw.framework/Versions/A"),
            .file("Fw.framework/Versions/A/Fw", "binary"),
            .link("Fw.framework/Versions/Current", "A"),
            .link("Fw.framework/Fw", "Versions/Current/Fw"),
            .link("Fw.framework/Versions/A/Self", "../A/./Fw"),
        ], in: world))
        defer { model.removeTemporaryFiles() }

        let export = try await ArchiveClipboard.export(["Fw.framework"], from: model, in: world.temporary,
                                                       progress: nil)

        let bundle = try #require(export.urls.first)
        #expect(try links(in: bundle) == ["Versions/Current": "A", "Fw": "Versions/Current/Fw",
                                          "Versions/A/Self": "../A/./Fw"])
        #expect(try String(decoding: Data(contentsOf: bundle.appendingPathComponent("Fw")), as: UTF8.self) == "binary")
        try expectNoEscape(bundle)
    }

    /// `d` -> the outside folder and a hard link `h` to "d/secret": the reader refuses a hard link whose target
    /// isn't an entry, so the copy fails, leaves nothing, and the outside file gets no second link.
    @Test func hardLinkThroughAnOutsideLinkTouchesNothingOutside() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([.link("d", "@O"), .hard("h", "d/secret"), .file("a", "A")],
                                                    in: world))
        defer { model.removeTemporaryFiles() }

        let error = await #expect(throws: ArchiveError.self) {
            try await ArchiveClipboard.export(["d", "h", "a"], from: model, in: world.temporary, progress: nil)
        }
        let isCorrupted = if case .corrupted = error { true } else { false }
        #expect(isCorrupted, "\(String(describing: error))")
        let parent = ArchiveClipboard.exportParent(in: world.temporary)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] == [])
        try expectOutsideUntouched(world)
    }

    // MARK: - Drag-out and preview (`localFileURL`)

    @Test func localFolderLosesItsEscapingLinksAndKeepsContainedOnes() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([
            .folder("d"), .folder("d/A"), .file("d/A/f", "F"),
            .link("d/cur", "A"),
            .link("d/abs", "@O/secret"),
            .link("d/up", "../../outside/secret"),
        ], in: world))
        defer { model.removeTemporaryFiles() }

        let url = try await model.localFileURL(for: "d")

        #expect(try links(in: url) == ["cur": "A"])
        #expect(try String(decoding: Data(contentsOf: url.appendingPathComponent("cur/f")), as: UTF8.self) == "F")
        try expectNoEscape(url)
        try expectOutsideUntouched(world)
    }

    /// A renamed link that leads out: the sweep removes it, and the reader won't serve an absolute target, so
    /// nothing comes out (no link out, never the outside file's bytes): it fails as a link, under its new name.
    @Test func renamedEscapingLinkNeverLeadsOut() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([.link("photo.jpg", "@O/secret")], in: world))
        defer { model.removeTemporaryFiles() }
        #expect(model.rename("photo.jpg", to: "cat.jpg") == .success("cat.jpg"))

        await #expect(throws: ExportedLinksError(names: ["cat.jpg"])) {
            try await model.localFileURL(for: "cat.jpg")
        }
        try expectOutsideUntouched(world)
    }

    /// A renamed link to a file in the archive comes out as a regular file with that file's bytes.
    @Test func renamedContainedLinkBecomesTheFile() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([.file("t.txt", "T"), .link("l", "t.txt")], in: world))
        defer { model.removeTemporaryFiles() }
        #expect(model.rename("l", to: "m") == .success("m"))

        let url = try await model.localFileURL(for: "m")

        #expect(url.lastPathComponent == "m")
        var status = stat()
        try #require(lstat(url.path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFREG)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "T")
    }

    // MARK: - Finder's file promise (`ArchiveDragOut.write`)

    @Test func promisedFolderLosesItsEscapingLinks() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([
            .folder("d"), .file("d/f", "F"), .link("d/cur", "f"), .link("d/abs", "@O/secret"),
        ], in: world))
        defer { model.removeTemporaryFiles() }

        let placed = try await ArchiveDragOut.write("d", from: model,
                                                    toPromised: world.destination.appendingPathComponent("d"))

        #expect(try links(in: placed) == ["cur": "f"])
        try expectNoEscape(placed)
        try expectOutsideUntouched(world)
    }

    @Test func promisedLinkFails() async throws {
        let world = try makeWorld()
        defer { discard(world) }
        let model = try await makeModel(try archive([.link("photo.jpg", "@O/secret")], in: world))
        defer { model.removeTemporaryFiles() }

        await #expect(throws: ExportedLinksError(names: ["photo.jpg"])) {
            try await ArchiveDragOut.write("photo.jpg", from: model,
                                           toPromised: world.destination.appendingPathComponent("photo.jpg"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.destination.path) == [])
        try expectOutsideUntouched(world)
    }

    // MARK: - The sweep on folders made by hand

    @Test func hardLinksFromOutsideAreRemoved() throws {
        let world = try makeWorld()
        defer { discard(world) }
        let item = world.work.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try #require(link(world.secret.path, item.appendingPathComponent("h").path) == 0)
        try Data("own".utf8).write(to: item.appendingPathComponent("own"))
        let file = world.work.appendingPathComponent("file")
        try #require(link(world.secret.path, file.path) == 0)

        let kept = try ExportLinkSweep.sanitize([item, file])

        #expect(kept == [item])
        #expect(try FileManager.default.contentsOfDirectory(atPath: item.path) == ["own"])
        #expect(!exists(file))
        try expectOutsideUntouched(world)
    }

    /// Overlapping items (`a` and `a/x`, as a caller may pass): `a/x`, hard-linked from outside, is met twice
    /// (in `a`'s walk and as an item) but counts once, so its two links are still more than the export holds.
    @Test func hardLinkFromOutsideInOverlappingItemsIsRemoved() throws {
        let world = try makeWorld()
        defer { discard(world) }
        let a = world.work.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try Data("own".utf8).write(to: a.appendingPathComponent("own"))
        let x = a.appendingPathComponent("x")
        try #require(link(world.secret.path, x.path) == 0)

        let kept = try ExportLinkSweep.sanitize([a, x])

        #expect(kept == [a])
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.path) == ["own"])
        #expect(!exists(x))
        try expectOutsideUntouched(world)
    }

    @Test func hardLinksInsideTheExportAreKept() throws {
        let world = try makeWorld()
        defer { discard(world) }
        let item = world.work.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        let a = item.appendingPathComponent("a")
        try Data("A".utf8).write(to: a)
        try #require(link(a.path, item.appendingPathComponent("b").path) == 0)
        let top = world.work.appendingPathComponent("top")
        try #require(link(a.path, top.path) == 0)

        let kept = try ExportLinkSweep.sanitize([item, top])

        #expect(kept == [item, top])
        #expect(try FileManager.default.contentsOfDirectory(atPath: item.path).sorted() == ["a", "b"])
    }

    @Test func readOnlyFolderIsSweptAndKeepsItsMode() throws {
        let world = try makeWorld()
        defer {
            chmod(world.work.appendingPathComponent("item/ro").path, 0o755)
            chmod(world.work.appendingPathComponent("item").path, 0o755)
            discard(world)
        }
        let item = world.work.appendingPathComponent("item", isDirectory: true)
        let ro = item.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: ro.appendingPathComponent("x").path,
                                                   withDestinationPath: world.secret.path)
        try FileManager.default.createSymbolicLink(atPath: ro.appendingPathComponent("y").path,
                                                   withDestinationPath: "../ro/f")
        try Data("F".utf8).write(to: ro.appendingPathComponent("f"))
        try #require(chmod(ro.path, 0o555) == 0)
        try #require(chmod(item.path, 0o500) == 0)

        let kept = try ExportLinkSweep.sanitize([item])

        #expect(kept == [item])
        var status = stat()
        try #require(lstat(item.path, &status) == 0)
        #expect(status.st_mode & 0o7777 == 0o500)
        try #require(lstat(ro.path, &status) == 0)
        #expect(status.st_mode & 0o7777 == 0o555)
        #expect(try links(in: item) == ["ro/y": "../ro/f"])
        try expectOutsideUntouched(world)
    }

    /// A pass that removes a link can leave another dangling: passes repeat until one removes nothing.
    @Test func chainsAreSweptToTheEnd() throws {
        let world = try makeWorld()
        defer { discard(world) }
        let item = world.work.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent("a").path,
                                                   withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent("b").path,
                                                   withDestinationPath: "c")
        try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent("c").path,
                                                   withDestinationPath: world.secret.path)
        let loop = item.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")

        #expect(try ExportLinkSweep.sanitize([item]) == [item])
        #expect(try links(in: item) == [:])
    }

    /// An absolute link in the middle of a chain: `b` -> the outside folder goes, and `a` -> "b/secret",
    /// which reaches the outside through it, goes with it.
    @Test func absoluteLinkMidChainIsRemoved() throws {
        let world = try makeWorld()
        defer { discard(world) }
        let item = world.work.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent("a").path,
                                                   withDestinationPath: "b/secret")
        try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent("b").path,
                                                   withDestinationPath: world.outside.path)
        try Data("own".utf8).write(to: item.appendingPathComponent("own"))

        #expect(try ExportLinkSweep.sanitize([item]) == [item])
        #expect(try links(in: item) == [:])
        #expect(try FileManager.default.contentsOfDirectory(atPath: item.path) == ["own"])
        try expectOutsideUntouched(world)
    }

    /// A 0000 folder is opened while it is swept and gets its mode back: its link out goes, its link to its
    /// own file stays. A link into it from outside it can't be followed while it is closed, so it goes too
    /// (fail closed).
    @Test func unreadableFolderIsSweptAndKeepsItsMode() throws {
        let world = try makeWorld()
        let item = world.work.appendingPathComponent("item", isDirectory: true)
        let locked = item.appendingPathComponent("locked", isDirectory: true)
        defer {
            chmod(locked.path, 0o755)
            discard(world)
        }
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("F".utf8).write(to: locked.appendingPathComponent("f"))
        try FileManager.default.createSymbolicLink(atPath: locked.appendingPathComponent("x").path,
                                                   withDestinationPath: world.secret.path)
        try FileManager.default.createSymbolicLink(atPath: locked.appendingPathComponent("y").path,
                                                   withDestinationPath: "f")
        try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent("l").path,
                                                   withDestinationPath: "locked/f")
        try #require(chmod(locked.path, 0) == 0)

        #expect(try ExportLinkSweep.sanitize([item]) == [item])

        var status = stat()
        try #require(lstat(locked.path, &status) == 0)
        #expect(status.st_mode & 0o7777 == 0)
        try #require(chmod(locked.path, 0o755) == 0)
        #expect(try links(in: item) == ["locked/y": "f"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).sorted() == ["f", "y"])
        try expectOutsideUntouched(world)
    }

    /// A link to the item or to a folder it is in would loop for a receiver that follows links: it goes.
    /// A bundle's links to siblings and children stay.
    @Test func loopingLinksAreRemoved() throws {
        let world = try makeWorld()
        defer { discard(world) }
        let item = world.work.appendingPathComponent("Fw.framework", isDirectory: true)
        let a = item.appendingPathComponent("Versions/A", isDirectory: true)
        try FileManager.default.createDirectory(at: a.appendingPathComponent("Headers"),
                                                withIntermediateDirectories: true)
        try Data("h".utf8).write(to: a.appendingPathComponent("Headers/h.h"))
        for (path, target) in [
            ("Versions/Current", "A"), ("Headers", "Versions/Current/Headers"),
            ("s", "."), ("Versions/up", ".."), ("Versions/A/back", "../../Versions"),
            ("Versions/A/self", "../A"), ("Versions/A/Headers/top", "../../../Versions/Current/../.."),
            ("viaCurrent", "Versions/Current/self"),
        ] {
            try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent(path).path,
                                                       withDestinationPath: target)
        }

        #expect(try ExportLinkSweep.sanitize([item]) == [item])
        #expect(try links(in: item) == ["Versions/Current": "A", "Headers": "Versions/Current/Headers"])
        #expect(try String(decoding: Data(contentsOf: item.appendingPathComponent("Headers/h.h")),
                           as: UTF8.self) == "h")
        try expectNoEscape(item)
    }

    @Test func linksErrorNamesTheItemOrSaysItems() {
        #expect(ExportedLinksError(names: ["photo.jpg"]).errorDescription
                == "“photo.jpg” is a link and can’t be copied out of the archive.")
        #expect(ExportedLinksError(names: ["a", "b"]).errorDescription
                == "The selected items are links and can’t be copied out of the archive.")
    }
}
