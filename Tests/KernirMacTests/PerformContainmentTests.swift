import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Nothing an extraction writes into its own folder (staging, the drag-out temporary folder, Extract Here's
/// hidden folder) goes through a symlink there. The reader has just written the archive's entries into that
/// folder, its symlinks too (an absolute target included). The tree is case-sensitive, a case-insensitive
/// volume is not: an archive symlink `Link -> outside` beside a plan folder `link/s` is the same name on disk.
/// Folders made by the plan (a folder holding only Finder metadata, a folder with additions) and the user's
/// added files are made one component at a time, never through a symlink (`ArchiveModel.makeFolders`), so
/// Extract, Extract Here and drag-out neither create folders outside nor delete and replace a file there.
/// The archives are real tar files written here (ustar with pax paths), read by the real core.
@MainActor
struct PerformContainmentTests {
    typealias H = HiddenSlashContainmentTests

    // MARK: - Fixtures

    /// One tar entry. Folders 0755, files 0644: no folder a teardown can't remove.
    enum TarEntry {
        case folder(String)
        case file(String, String)
        case link(String, String)
    }

    /// A ustar archive with a pax header (`path`, `linkpath`) before every entry, so long and non-ASCII
    /// names and absolute link targets in the temporary folder fit.
    nonisolated static func tar(_ entries: [TarEntry]) -> Data {
        func header(name: String, type: UInt8, size: Int, mode: Int) -> Data {
            var block = [UInt8](repeating: 0, count: 512)
            func put(_ string: String, at offset: Int, length: Int) {
                for (index, byte) in string.utf8.prefix(length).enumerated() { block[offset + index] = byte }
            }
            func octal(_ value: Int, at offset: Int, length: Int) {
                put(String(String(value, radix: 8).suffix(length - 1)).leftPadded(to: length - 1), at: offset,
                    length: length - 1)
            }
            put(String(name.utf8.prefix(99).map { Character(Unicode.Scalar($0 < 0x80 ? $0 : 0x5F)) }), at: 0,
                length: 99)
            octal(mode, at: 100, length: 8)
            octal(0, at: 108, length: 8)
            octal(0, at: 116, length: 8)
            octal(size, at: 124, length: 12)
            octal(0, at: 136, length: 12)
            block[156] = type
            put("ustar", at: 257, length: 6)
            put("00", at: 263, length: 2)
            for index in 148..<156 { block[index] = 0x20 }
            let sum = block.reduce(0) { $0 + Int($1) }
            put(String(String(sum, radix: 8)).leftPadded(to: 6), at: 148, length: 6)
            block[154] = 0
            block[155] = 0x20
            return Data(block)
        }
        func padded(_ data: Data) -> Data {
            data + Data(count: (512 - data.count % 512) % 512)
        }
        func record(_ key: String, _ value: String) -> String {
            let body = " \(key)=\(value)\n"
            var length = body.utf8.count + 1
            while String(length).utf8.count + body.utf8.count != length { length = String(length).utf8.count + body.utf8.count }
            return "\(length)\(body)"
        }
        var archive = Data()
        for entry in entries {
            let (path, type, contents, target, mode): (String, UInt8, Data, String?, Int) = switch entry {
            case let .folder(path): (path, UInt8(ascii: "5"), Data(), nil, 0o755)
            case let .file(path, text): (path, UInt8(ascii: "0"), Data(text.utf8), nil, 0o644)
            case let .link(path, target): (path, UInt8(ascii: "2"), Data(), target, 0o755)
            }
            var pax = record("path", path)
            if let target { pax += record("linkpath", target) }
            let paxData = Data(pax.utf8)
            archive += header(name: "PaxHeader", type: UInt8(ascii: "x"), size: paxData.count, mode: 0o644)
            archive += padded(paxData)
            archive += header(name: path, type: type, size: contents.count, mode: mode)
            archive += padded(contents)
        }
        return archive + Data(count: 1024)
    }

    /// A fresh root: `dest` (where the user extracts), `outside` (a victim file `x` and `secret`), `work`
    /// (the archive, the user's files to add). Removed whole by `remove()`.
    struct World {
        let root: URL
        let dest: URL
        let outside: URL
        let work: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PerformContainmentTests-\(UUID().uuidString)", isDirectory: true)
            dest = root.appendingPathComponent("dest", isDirectory: true)
            outside = root.appendingPathComponent("outside", isDirectory: true)
            work = root.appendingPathComponent("work", isDirectory: true)
            for url in [dest, outside, work] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try Data("secret".utf8).write(to: outside.appendingPathComponent("secret"))
            try Data("victim".utf8).write(to: outside.appendingPathComponent("x"))
        }

        /// Writes `entries` as `work/evil.tar`, with "@O" in a link target spelled as `outside`'s path.
        func archive(_ entries: [TarEntry]) throws -> URL {
            let url = work.appendingPathComponent("evil.tar")
            let resolved = entries.map { entry -> TarEntry in
                if case let .link(path, target) = entry {
                    return .link(path, target.replacingOccurrences(of: "@O", with: outside.path))
                }
                return entry
            }
            try PerformContainmentTests.tar(resolved).write(to: url)
            return url
        }

        /// The names beside `dest` and `outside`: nothing new may appear there.
        func rootNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func model(_ archive: URL) async throws -> ArchiveModel {
        let model = ArchiveModel(reader: try await Archive.open(at: archive), undoManager: nil)
        // Never the app's defaults: a token of the test's own, real renames.
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: H.deviceToken) { from, to, flags in
            renamex_np(from, to, flags) == 0 ? 0 : errno
        }
        // A destination that says it is case-sensitive (one that folds case anyway): no case-twin question
        // comes first, so these tests reach `perform` and its folder maker. `liveModel` keeps the volume's own
        // answer.
        model.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true }, supportsCaseSensitiveNames: { _ in true })
        return model
    }

    /// `model(_:)` with the volume's own answer (`.live`): on this case-folding disk the twin question comes first.
    static func liveModel(_ archive: URL) async throws -> ArchiveModel {
        let model = try await model(archive)
        model.caseSensitivity = .live
        return model
    }

    enum Route: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case extract, dragOut, extractHere
        var testDescription: String { rawValue }
    }

    /// Runs `route` for `paths` (nil: everything; drag-out: each top item) and returns what it threw.
    static func run(_ route: Route, _ paths: [String]?, model: ArchiveModel, archive: URL,
                    in world: World) async -> (any Error)? {
        do {
            switch route {
            case .extract:
                try await model.extract(paths, to: world.dest, progress: nil)
            case .dragOut:
                defer { model.removeTemporaryFiles() }
                var firstError: (any Error)?
                for path in paths ?? model.items.map(\.path) {
                    do { _ = try await model.localFileURL(for: path) } catch { firstError = firstError ?? error }
                }
                if let firstError { throw firstError }
            case .extractHere:
                let plan = try #require(ExtractHerePlan.make(paths, in: model, archiveURL: archive))
                _ = try await ExtractHereService.extract(plan, from: model, in: world.dest, progress: nil)
            }
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Archive only

    /// `Link -> outside` and a folder `link/sub` holding only Finder metadata (so the plan makes it): Extract
    /// All made `outside/sub` through the link. Now the folder is refused and nothing appears outside.
    @Test func aCaseTwinLinkInTheArchiveIsNeverFollowedByAPlanFolder() async throws {
        let world = try World()
        defer { world.remove() }
        let archive = try world.archive([
            .link("Link", "@O"), .folder("link"), .folder("link/sub"), .file("link/sub/._x", "meta"),
        ])
        let before = try H.snapshot(world.outside)
        let model = try await Self.model(archive)
        let thrown = await Self.run(.extract, nil, model: model, archive: archive, in: world)
        #expect(try H.snapshot(world.outside) == before, "CONTAINMENT: \(String(describing: thrown))")
        #expect(thrown is ExtractionContainmentError, "\(String(describing: thrown))")
        #expect(try world.rootNames() == ["dest", "outside", "work"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.dest.path).isEmpty, "staging is gone")
    }

    struct Spec: Sendable, CustomTestStringConvertible {
        let entries: [TarEntry]
        let label: String
        var testDescription: String { label }
    }

    nonisolated static let specs: [Spec] = [
        Spec(entries: [.link("Link", "@O"), .folder("link"), .file("link/f", "payload")], label: "twin + clean file"),
        Spec(entries: [.file("link/f", "payload"), .link("Link", "@O")], label: "file first, link second"),
        Spec(entries: [.link("Link", "@O"), .folder("link"), .file("link/._m", "meta"), .file("link/x", "payload")],
             label: "twin dirty + file"),
        Spec(entries: [.link("Link", "@O"), .file("link/a/b/c/._m", "meta")], label: "deep dirty folders"),
        Spec(entries: [.link("d/Link", "@O"), .file("d/._z", "meta"), .file("d/link/s/._m", "meta")],
             label: "inside d"),
    ]

    /// Archive-only case twins, every route: whatever is refused or written, nothing is created, changed or
    /// removed in `outside`, and nothing appears beside the destination.
    @Test(arguments: specs, Route.allCases)
    func archiveCaseTwinsNeverWriteOutside(_ spec: Spec, _ route: Route) async throws {
        let world = try World()
        defer { world.remove() }
        let archive = try world.archive(spec.entries)
        let before = try H.snapshot(world.outside)
        let model = try await Self.model(archive)
        let thrown = await Self.run(route, nil, model: model, archive: archive, in: world)
        let after = try H.snapshot(world.outside)
        let added = after.keys.filter { before[$0] == nil }
            .map { String(String.UnicodeScalarView($0.compactMap(Unicode.Scalar.init))) }.sorted()
        #expect(after == before, "CONTAINMENT \(spec.label) via \(route): new outside \(added), \(String(describing: thrown))")
        #expect(try world.rootNames() == ["dest", "outside", "work"])
    }

    // MARK: - User additions

    /// The archive has `d/Link -> outside`; the user adds a folder `link` holding `x` into `d` (the tree is
    /// case-sensitive, so the add is allowed). Extract `d`, drag-out `d` and Extract Here `d` deleted
    /// `outside/x` and copied the user's `x` there. Now the copy is refused: `outside/x` is untouched.
    @Test(arguments: Route.allCases)
    func aUserAddedCaseTwinNeverDeletesOrWritesOutside(_ route: Route) async throws {
        let world = try World()
        defer { world.remove() }
        let archive = try world.archive([.folder("d"), .link("d/Link", "@O"), .file("d/keep", "payload")])
        let added = world.work.appendingPathComponent("add/link", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try Data("the user's file".utf8).write(to: added.appendingPathComponent("x"))
        let before = try H.snapshot(world.outside)
        let model = try await Self.model(archive)
        model.add([added], to: "d")
        #expect(model.item(at: "d/link/x") != nil)
        let thrown = await Self.run(route, ["d"], model: model, archive: archive, in: world)
        #expect(try H.snapshot(world.outside) == before, "CONTAINMENT via \(route): \(String(describing: thrown))")
        #expect(thrown is ExtractionContainmentError, "\(route): \(String(describing: thrown))")
        if let refused = thrown as? ExtractionContainmentError {
            // Named for the folder the user chose (drag-out: the item dragged), never the hidden one the work
            // happened in.
            if route == .dragOut {
                #expect(refused.destination.lastPathComponent == "d", "\(refused.destination.path)")
            } else {
                #expect(refused.destination.path == world.dest.path, "\(refused.destination.path)")
            }
            let folder = route == .dragOut ? "d" : "dest"
            #expect(refused.localizedDescription == Self.refusal(refused.name, in: folder), "\(route)")
        }
        #expect(try world.rootNames() == ["dest", "outside", "work"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.dest.path).isEmpty, "nothing is placed")
        // The user's own file is never touched.
        #expect(try String(contentsOf: added.appendingPathComponent("x"), encoding: .utf8) == "the user's file")
    }

    /// A user-added file whose name is a case twin of an archive symlink in the same folder replaces the
    /// link in the extraction's own folder (as two items on one name did: the later one is kept), never
    /// the file the link leads to.
    @Test func aUserAddedFileOnALinksNameReplacesTheLinkNotItsTarget() async throws {
        let world = try World()
        defer { world.remove() }
        let archive = try world.archive([.folder("d"), .link("d/X", "@O/x"), .file("d/keep", "payload")])
        let added = world.work.appendingPathComponent("x")
        try Data("the user's file".utf8).write(to: added)
        let before = try H.snapshot(world.outside)
        let model = try await Self.model(archive)
        model.add([added], to: "d")
        let placed = try await model.extract(["d"], to: world.dest, progress: nil)
        #expect(try H.snapshot(world.outside) == before, "CONTAINMENT")
        let folder = try #require(placed.first)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.count == 2 && names.contains("keep"), "\(names)")
        let copy = try #require(names.first { $0.lowercased() == "x" })
        #expect(!H.isSymlink(folder.appendingPathComponent(copy)))
        #expect(try String(contentsOf: folder.appendingPathComponent(copy), encoding: .utf8) == "the user's file")
    }

    /// The same with a dangling link (`d/X -> outside/missing`): the user's `x` replaces the link and
    /// nothing is created at the link's target.
    @Test func aUserAddedFileOnADanglingLinksNameNeverWritesThroughIt() async throws {
        let world = try World()
        defer { world.remove() }
        let archive = try world.archive([.folder("d"), .link("d/X", "@O/missing"), .file("d/keep", "payload")])
        let added = world.work.appendingPathComponent("x")
        try Data("the user's file".utf8).write(to: added)
        let before = try H.snapshot(world.outside)
        let model = try await Self.model(archive)
        model.add([added], to: "d")
        var thrown: (any Error)?
        do { _ = try await model.extract(["d"], to: world.dest, progress: nil) } catch { thrown = error }
        #expect(try H.snapshot(world.outside) == before, "CONTAINMENT: \(String(describing: thrown))")
        #expect(thrown == nil, "\(String(describing: thrown))")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: world.dest.appendingPathComponent("d").path)) ?? []
        let copy = names.first { $0.lowercased() == "x" }
        #expect(copy.map { !H.isSymlink(world.dest.appendingPathComponent("d").appendingPathComponent($0)) } == true,
                "\(names)")
    }

    /// A user-added file requested on its own beside the archive's link it is a case twin of
    /// (`d/Link -> outside`, `d/link/x`): its folder is not a plan folder, and is never made through
    /// the link the reader just wrote.
    @Test(arguments: [Route.extract, Route.extractHere])
    func aUserAddedFileRequestedBesideItsTwinLinkNeverWritesOutside(_ route: Route) async throws {
        let world = try World()
        defer { world.remove() }
        let archive = try world.archive([.folder("d"), .link("d/Link", "@O"), .file("d/keep", "payload")])
        let added = world.work.appendingPathComponent("add/link", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try Data("the user's file".utf8).write(to: added.appendingPathComponent("x"))
        let before = try H.snapshot(world.outside)
        let model = try await Self.model(archive)
        model.add([added], to: "d")
        let thrown = await Self.run(route, ["d/Link", "d/link/x"], model: model, archive: archive, in: world)
        #expect(try H.snapshot(world.outside) == before, "CONTAINMENT via \(route): \(String(describing: thrown))")
        #expect(thrown is ExtractionContainmentError, "\(route): \(String(describing: thrown))")
        #expect(try world.rootNames() == ["dest", "outside", "work"])
    }

    // MARK: - Live case folding

    /// The answer to every question `extractionConflicts` asks; `none` leaves them unanswered.
    enum LiveAnswer: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case none, keepBoth, replace, skip
        var testDescription: String { rawValue }
        var resolution: ExtractionConflictResolution? {
            switch self {
            case .none: nil
            case .keepBoth: .keepBoth
            case .replace: .replace
            case .skip: .skip
            }
        }
    }

    /// Extract with the volume's own answer on this case-folding disk: the twin question comes before any
    /// staging, so unanswered nothing is written. Answered, whatever comes out, nothing goes outside and an
    /// archive link that comes out is still a link.
    @Test(arguments: specs, LiveAnswer.allCases)
    func liveCaseFoldingKeepsArchiveTwinsInside(_ spec: Spec, _ answer: LiveAnswer) async throws {
        let world = try World()
        defer { world.remove() }
        try #require(isCaseInsensitive(world.root))
        let archive = try world.archive(spec.entries)
        let before = try H.snapshot(world.outside)
        let model = try await Self.liveModel(archive)
        let conflicts = model.extractionConflicts(nil, in: world.dest)
        #expect(!conflicts.isEmpty, "\(spec.label): the twins are asked about")
        var resolutions: [String: ExtractionConflictResolution] = [:]
        if let resolution = answer.resolution { for conflict in conflicts { resolutions[conflict] = resolution } }
        var thrown: (any Error)?
        do { _ = try await model.extract(nil, to: world.dest, resolutions: resolutions, progress: nil) } catch { thrown = error }

        #expect(try H.snapshot(world.outside) == before, "CONTAINMENT \(spec.label) \(answer): \(String(describing: thrown))")
        #expect(try world.rootNames() == ["dest", "outside", "work"])
        if answer == .none {
            #expect(thrown is ExtractionConflictError, "\(String(describing: thrown))")
            #expect(try FileManager.default.contentsOfDirectory(atPath: world.dest.path).isEmpty, "nothing written")
        } else {
            #expect(thrown == nil, "\(spec.label) \(answer): \(String(describing: thrown))")
            let placed = try H.snapshot(world.dest).values
            #expect(!placed.contains("secret") && !placed.contains("victim"), "nothing read through a link")
        }
    }

    /// Extract Here with the volume's own answer: it answers Keep Both itself, so each twin comes out on a
    /// name of its own ("link 2"), the archive's link stays a link, and nothing goes outside, for archive-only
    /// twins and for a user-added twin of a link.
    @Test(arguments: specs.map(Optional.some) + [nil])
    func liveExtractHereKeepsTwinsApartAndInside(_ spec: Spec?) async throws {
        let world = try World()
        defer { world.remove() }
        try #require(isCaseInsensitive(world.root))
        let entries = spec?.entries ?? [.folder("d"), .link("d/Link", "@O"), .file("d/keep", "payload")]
        let archive = try world.archive(entries)
        let before = try H.snapshot(world.outside)
        let model = try await Self.liveModel(archive)
        if spec == nil {
            let added = world.work.appendingPathComponent("add/link", isDirectory: true)
            try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
            try Data("the user's file".utf8).write(to: added.appendingPathComponent("x"))
            model.add([added], to: "d")
        }
        let thrown = await Self.run(.extractHere, nil, model: model, archive: archive, in: world)

        #expect(try H.snapshot(world.outside) == before, "CONTAINMENT \(spec?.label ?? "user-added"): \(String(describing: thrown))")
        #expect(try world.rootNames() == ["dest", "outside", "work"])
        #expect(thrown == nil, "\(String(describing: thrown))")
        let placed = try H.snapshot(world.dest)
        #expect(placed.keys.contains { H.scalars(" 2").count <= $0.count && Array($0.suffix(2)) == H.scalars(" 2") },
                "a twin kept on a name of its own")
        #expect(placed.values.contains { $0.hasPrefix("-> ") }, "the archive's link is still a link")
        #expect(!placed.values.contains("secret") && !placed.values.contains("victim"), "nothing read through a link")
    }

    // MARK: - The folder maker

    /// A fresh root holding `outside` and `dest`, the folder the maker works in.
    struct Root {
        let root: URL
        let dest: URL
        let outside: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PerformContainmentTests-\(UUID().uuidString)", isDirectory: true)
            dest = root.appendingPathComponent("dest", isDirectory: true)
            outside = root.appendingPathComponent("outside", isDirectory: true)
            for url in [dest, outside, dest.appendingPathComponent("sub")] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try Data("secret".utf8).write(to: outside.appendingPathComponent("secret"))
        }

        func link(_ name: String, to target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: dest.appendingPathComponent(name).path,
                                                       withDestinationPath: target)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    struct Through: Sendable, CustomTestStringConvertible {
        let link: String
        let target: String
        let path: [String]
        let label: String
        var testDescription: String { label }
    }

    nonisolated static let throughLinks = [
        Through(link: "Link", target: "@O", path: ["link", "s"], label: "case twin"),
        Through(link: "Link", target: "@O", path: ["LINK"], label: "case twin, the link itself"),
        Through(link: "Link", target: "@O", path: ["Link", "s", "t"], label: "same case"),
        Through(link: "caf\u{e9}", target: "@O", path: ["cafe\u{301}", "s"], label: "NFD twin"),
        Through(link: "rel", target: "../outside", path: ["REL", "s"], label: "relative link"),
        Through(link: "in", target: "sub", path: ["In", "s"], label: "a link to a folder inside"),
        Through(link: "dangling", target: "@O/missing", path: ["Dangling", "s"], label: "dangling link"),
    ]

    /// What the user reads when a link is in the way: true wherever the link leads (outside, inside, nowhere).
    static func refusal(_ name: String, in folder: String) -> String {
        String(localized: "“\(name)” wasn't extracted to “\(folder)”: its path has a link where a folder was expected.",
               table: "Shared")
    }

    /// A symlink is never a folder to the maker, whatever its case or normalization or where it leads:
    /// `ExtractionContainmentError`, nothing made anywhere. The text never says where the link leads.
    @Test(arguments: throughLinks)
    func theFolderMakerNeverGoesThroughALink(_ c: Through) throws {
        let r = try Root()
        defer { r.remove() }
        try r.link(c.link, to: c.target.replacingOccurrences(of: "@O", with: r.outside.path))
        let outside = try H.snapshot(r.outside)
        let inside = try H.snapshot(r.dest)
        let error = #expect(throws: ExtractionContainmentError.self) {
            try ArchiveModel.makeFolders(c.path[...], in: r.dest)
        }
        #expect(error?.localizedDescription == Self.refusal(c.path[0], in: "dest"), "\(c.label)")
        #expect(try H.snapshot(r.outside) == outside, "CONTAINMENT \(c.label)")
        #expect(try H.snapshot(r.dest) == inside, "nothing made: \(c.label)")
    }

    /// "." and ".." are never folders to make: the maker never climbs out of its folder.
    @Test(arguments: [["..", "outside", "s"], ["sub", "..", "..", "outside", "s"], [".", "s"]])
    func theFolderMakerRefusesDotNames(_ path: [String]) throws {
        let r = try Root()
        defer { r.remove() }
        let outside = try H.snapshot(r.outside)
        let inside = try H.snapshot(r.dest)
        #expect(throws: ExtractionContainmentError.self) {
            try ArchiveModel.makeFolders(path[...], in: r.dest)
        }
        #expect(try H.snapshot(r.outside) == outside, "CONTAINMENT \(path)")
        #expect(try H.snapshot(r.dest) == inside)
    }

    /// Real folders merge, whatever case the path spells them in; new ones are made one by one. A file in
    /// the way is not a link: its POSIX error, nothing made.
    @Test func theFolderMakerMergesRealFoldersAndStopsAtAFile() throws {
        let r = try Root()
        defer { r.remove() }
        let made = try ArchiveModel.makeFolders(["SUB", "a", "b"][...], in: r.dest)
        #expect(made.path == r.dest.appendingPathComponent("SUB/a/b").path)
        #expect(try H.snapshot(r.dest) == [H.scalars("sub"): "dir", H.scalars("sub/a"): "dir",
                                           H.scalars("sub/a/b"): "dir"])
        #expect(try ArchiveModel.makeFolders([][...], in: r.dest).path == r.dest.path)
        try Data("f".utf8).write(to: r.dest.appendingPathComponent("file"))
        do {
            try ArchiveModel.makeFolders(["File", "s"][...], in: r.dest)
            Issue.record("a file is not a folder")
        } catch let error as POSIXError {
            #expect(error.code == .ENOTDIR || error.code == .EEXIST)
        }
        #expect(!FileManager.default.fileExists(atPath: r.dest.appendingPathComponent("file/s").path))
    }

    // MARK: - Volumes that won't open a folder for search only

    /// SMB, FAT/exFAT or a File Provider may refuse a search-only open (O_SEARCH) with EACCES, EPERM, EINVAL,
    /// ENOTSUP or EOPNOTSUPP (on Darwin a separate number from ENOTSUP): each takes the read-open fallback.
    /// Anything else is the open's own error.
    @Test(arguments: [(EACCES, true), (EPERM, true), (EINVAL, true), (ENOTSUP, true), (EOPNOTSUPP, true),
                      (ENOENT, false), (ENOTDIR, false), (ELOOP, false), (EIO, false)])
    func aRefusedSearchOpenFallsBack(_ code: Int32, _ fallsBack: Bool) {
        #expect(ArchiveModel.searchIsRefused(code) == fallsBack, "errno \(code)")
    }

    /// Through the read-open fallback, real folders still merge and new ones are made one by one.
    @Test func theFallbackOpenMakesAndMergesRealFolders() throws {
        let r = try Root()
        defer { r.remove() }
        let made = try ArchiveModel.makeFolders(["SUB", "a", "b"][...], in: r.dest, readOnlyOpens: true)
        #expect(made.path == r.dest.appendingPathComponent("SUB/a/b").path)
        #expect(try H.snapshot(r.dest) == [H.scalars("sub"): "dir", H.scalars("sub/a"): "dir",
                                           H.scalars("sub/a/b"): "dir"])
    }

    /// Opened for reading, a folder is still never a link: every link shape is refused, nothing made.
    @Test(arguments: throughLinks)
    func theFallbackOpenNeverGoesThroughALink(_ c: Through) throws {
        let r = try Root()
        defer { r.remove() }
        try r.link(c.link, to: c.target.replacingOccurrences(of: "@O", with: r.outside.path))
        let outside = try H.snapshot(r.outside)
        let inside = try H.snapshot(r.dest)
        #expect(throws: ExtractionContainmentError.self) {
            try ArchiveModel.makeFolders(c.path[...], in: r.dest, readOnlyOpens: true)
        }
        #expect(try H.snapshot(r.outside) == outside, "CONTAINMENT \(c.label)")
        #expect(try H.snapshot(r.dest) == inside, "nothing made: \(c.label)")
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
