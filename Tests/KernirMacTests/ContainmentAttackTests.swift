import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Archives and folders built to reach outside the folder an extraction works in: names that a case-folding
/// volume folds onto an archive symlink's name (Kelvin sign, ß/SS/ẞ, Ångström sign, NFD), names it doesn't fold
/// (Turkish I, ZWSP, BOM, a trailing dot or space), hard links, links to links, loops, a link to "/" or to the
/// folder itself, and ".." in a link target. Each goes through Extract, drag-out and Extract Here, with a
/// destination that says it is case-sensitive (so `perform` and its folder maker meet the twins) and with the
/// volume's own answer (so the twin question comes first). Whatever is refused or written, nothing outside is
/// created, changed, removed or hard-linked, and nothing appears beside the destination. The folder maker is
/// also run with the fallback open (O_RDONLY) that a volume refusing O_SEARCH takes.
@MainActor
struct ContainmentAttackTests {
    typealias H = HiddenSlashContainmentTests
    typealias P = PerformContainmentTests

    // MARK: - Archives

    /// A tar entry; `hard` is a hard link (type 1) to an earlier entry or a path.
    enum Entry: Sendable {
        case folder(String)
        case file(String, String)
        case link(String, String)
        case hard(String, String)
    }

    /// `entries` as a tar, "@O" in a link target spelled as `world`'s outside, written as `work/evil.tar`.
    /// Built entry by entry with `PerformContainmentTests.tar`, a hard link patched from type 2 to type 1.
    static func archive(_ entries: [Entry], in world: P.World) throws -> URL {
        var data = Data()
        for entry in entries {
            let resolved: P.TarEntry
            var isHard = false
            switch entry {
            case let .folder(path): resolved = .folder(path)
            case let .file(path, text): resolved = .file(path, text)
            case let .link(path, target): resolved = .link(path, target.replacingOccurrences(of: "@O", with: world.outside.path))
            case let .hard(path, target):
                resolved = .link(path, target.replacingOccurrences(of: "@O", with: world.outside.path))
                isHard = true
            }
            let one = P.tar([resolved]).dropLast(1024)
            data += isHard ? hardLinked(Data(one)) : Data(one)
        }
        let url = world.work.appendingPathComponent("evil.tar")
        try (data + Data(count: 1024)).write(to: url)
        return url
    }

    /// Every symlink header (type 2) of `data` made a hard link (type 1), its checksum redone.
    nonisolated static func hardLinked(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        var offset = 0
        while offset + 512 <= bytes.count {
            if bytes[offset + 156] == UInt8(ascii: "2"),
               Array(bytes[(offset + 257)..<(offset + 262)]) == Array("ustar".utf8) {
                bytes[offset + 156] = UInt8(ascii: "1")
                for index in 148..<156 { bytes[offset + index] = 0x20 }
                let sum = Array(String(bytes[offset..<(offset + 512)].reduce(0) { $0 + Int($1) }, radix: 8).utf8)
                let padded = [UInt8](repeating: UInt8(ascii: "0"), count: 6 - sum.count) + sum
                for (index, byte) in padded.enumerated() { bytes[offset + 148 + index] = byte }
                bytes[offset + 154] = 0
                bytes[offset + 155] = 0x20
            }
            offset += 512
        }
        return Data(bytes)
    }

    struct Attack: Sendable, CustomTestStringConvertible {
        let label: String
        let entries: [Entry]
        /// A file of the user's added into `d` under this name (then requested: `d`).
        var added: String?
        var testDescription: String { label }
    }

    nonisolated static let attacks: [Attack] = [
        Attack(label: "Kelvin sign link, plan folder k", entries: [
            .link("\u{212A}", "@O"), .folder("k"), .folder("k/sub"), .file("k/sub/._x", "meta")]),
        Attack(label: "Kelvin sign link, file in k", entries: [.link("\u{212A}", "@O"), .folder("k"), .file("k/x", "payload")]),
        Attack(label: "k link, file in Kelvin sign", entries: [.link("k", "@O"), .file("\u{212A}/x", "payload")]),
        Attack(label: "\u{DF} link, SS and ss", entries: [
            .link("\u{DF}", "@O"), .folder("SS"), .folder("SS/sub"), .file("SS/sub/._x", "meta"), .file("ss/x", "payload")]),
        Attack(label: "Angstrom sign link, A-ring folder", entries: [
            .link("\u{212B}", "@O"), .folder("\u{C5}"), .folder("\u{C5}/sub"), .file("\u{C5}/sub/._x", "meta"),
            .file("\u{C5}/x", "payload")]),
        Attack(label: "A-ring link, Angstrom sign file", entries: [.link("\u{C5}", "@O"), .file("\u{212B}/x", "payload")]),
        Attack(label: "NFD A-ring link, small a-ring", entries: [
            .link("A\u{30A}", "@O"), .folder("\u{E5}/sub"), .file("\u{E5}/sub/._x", "meta"), .file("\u{E5}/x", "payload")]),
        Attack(label: "link to a link", entries: [
            .link("b", "@O"), .link("A", "b"), .folder("a/sub"), .file("a/sub/._x", "meta"), .file("a/x", "payload")]),
        Attack(label: "two-link loop", entries: [
            .link("a", "b"), .link("b", "a"), .folder("A/sub"), .file("A/sub/._x", "meta"), .file("B/x", "payload")]),
        Attack(label: "link to /", entries: [
            .link("Root", "/"), .folder("root/tmp/sub"), .file("root/tmp/sub/._x", "meta"), .file("root/x", "payload")]),
        Attack(label: "dot-dot link target", entries: [
            .link("L", "../../outside"), .folder("l/sub"), .file("l/sub/._x", "meta"), .file("l/x", "payload")]),
        Attack(label: "dot-dot link target in d", entries: [
            .folder("d"), .link("d/L", "../../../outside"), .file("d/l/x", "payload"), .file("d/._z", "meta")]),
        Attack(label: "hard link to outside, absolute", entries: [.hard("h", "@O/x"), .file("f", "payload")]),
        Attack(label: "hard link to outside, dot-dot", entries: [.hard("h", "../../outside/x"), .file("f", "payload")]),
        Attack(label: "hard link to an archive link", entries: [.link("L", "@O/x"), .hard("h", "L"), .file("f", "payload")]),
        Attack(label: "hard link in d to outside, a user file on its name", entries: [
            .folder("d"), .hard("d/h", "@O/x"), .file("d/keep", "payload")], added: "h"),
        Attack(label: "hard link in d, dot-dot, a user file on its name", entries: [
            .folder("d"), .hard("d/h", "../outside/x"), .file("d/keep", "payload")], added: "h"),
        Attack(label: "hard link behind a case-twin link, a user file on its name", entries: [
            .folder("d"), .link("d/Link", "@O"), .file("d/keep", "payload"), .hard("d/link/h", "d/keep")], added: "h"),
        Attack(label: "user file on a link to a folder outside", entries: [
            .folder("d"), .link("d/X", "@O"), .file("d/keep", "payload")], added: "x"),
    ]

    /// Which answer the destination gives about case: case-sensitive (injected) or the volume's own.
    enum Volume: String, CaseIterable, Sendable { case caseSensitive, live }

    /// Every item under `url` (lstat): its type, inode and link count, so a new hard link shows.
    static func inodes(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.subpathsOfDirectory(atPath: url.path) {
            var status = stat()
            guard lstat(url.appendingPathComponent(name).path, &status) == 0 else { continue }
            result[name] = "\(status.st_mode & S_IFMT) \(status.st_ino) \(status.st_nlink)"
        }
        return result
    }

    /// Each attack, each route, each volume answer: outside unchanged to the inode, nothing beside the
    /// destination, no placed file on an outside file's inode. The volume's own answer gets every question
    /// answered Keep Both on Extract (as the dialog would); Extract Here answers it itself.
    @Test(arguments: attacks, P.Route.allCases)
    func anAttackNeverReachesOutside(_ attack: Attack, _ route: P.Route) async throws {
        for volume in Volume.allCases {
            let world = try P.World()
            defer { world.remove() }
            let url = try Self.archive(attack.entries, in: world)
            let before = try H.snapshot(world.outside)
            let beforeInodes = try Self.inodes(world.outside)
            var thrown: (any Error)?
            do {
                let model = volume == .live ? try await P.liveModel(url) : try await P.model(url)
                var paths: [String]?
                if let added = attack.added {
                    let file = world.work.appendingPathComponent(added)
                    try Data("the user's file".utf8).write(to: file)
                    model.add([file], to: "d")
                    paths = ["d"]
                }
                if volume == .live, route == .extract {
                    let conflicts = model.extractionConflicts(paths, in: world.dest)
                    let keepBoth = Dictionary(uniqueKeysWithValues: conflicts.map { ($0, ExtractionConflictResolution.keepBoth) })
                    _ = try await model.extract(paths, to: world.dest, resolutions: keepBoth, progress: nil)
                } else {
                    thrown = await P.run(route, paths, model: model, archive: url, in: world)
                }
            } catch {
                thrown = error
            }
            let label = "\(attack.label), \(route), \(volume): \(String(describing: thrown))"
            #expect(try H.snapshot(world.outside) == before, "CONTAINMENT \(label)")
            #expect(try Self.inodes(world.outside) == beforeInodes, "no new name for an outside item: \(label)")
            #expect(try String(contentsOf: world.outside.appendingPathComponent("x"), encoding: .utf8) == "victim")
            #expect(try world.rootNames() == ["dest", "outside", "work"], "\(label)")
            let outsideInodes = Set(beforeInodes.values.map { $0.split(separator: " ")[1] })
            for name in (try? FileManager.default.subpathsOfDirectory(atPath: world.dest.path)) ?? [] {
                var status = stat()
                if lstat(world.dest.appendingPathComponent(name).path, &status) == 0, status.st_mode & S_IFMT == S_IFREG {
                    #expect(!outsideInodes.contains(Substring(String(status.st_ino))), "\(name) is an outside file: \(label)")
                }
            }
        }
    }

    // MARK: - The folder maker

    struct MakerCase: Sendable, CustomTestStringConvertible {
        /// Links made in the folder first: name, target ("@O" outside, "@D" the folder itself).
        let links: [(String, String)]
        let path: [String]
        let label: String
        var testDescription: String { label }
    }

    /// The folded-name cases: folded or not, the volume decides; every one is refused or ends
    /// in a real folder inside.
    nonisolated static let makerCases: [MakerCase] = [
        MakerCase(links: [("kit", "@O")], path: ["\u{212A}it", "s"], label: "Kelvin sign"),
        MakerCase(links: [("stra\u{DF}e", "@O")], path: ["STRASSE", "s"], label: "\u{DF} vs SS"),
        MakerCase(links: [("stra\u{DF}e", "@O")], path: ["STRA\u{1E9E}E", "s"], label: "\u{DF} vs capital \u{1E9E}"),
        MakerCase(links: [("i", "@O")], path: ["\u{130}", "s"], label: "Turkish dotted I"),
        MakerCase(links: [("\u{131}", "@O")], path: ["I", "s"], label: "Turkish dotless i"),
        MakerCase(links: [("link", "@O")], path: ["li\u{200B}nk", "s"], label: "ZWSP"),
        MakerCase(links: [("link", "@O")], path: ["\u{FEFF}link", "s"], label: "BOM"),
        MakerCase(links: [("link", "@O")], path: ["link.", "s"], label: "trailing dot"),
        MakerCase(links: [("link", "@O")], path: ["link ", "s"], label: "trailing space"),
        MakerCase(links: [("\u{1E9B}\u{323}", "@O")], path: ["\u{1E69}", "s"], label: "long s with dots"),
        MakerCase(links: [("\u{C5}", "@O")], path: ["\u{212B}", "s"], label: "Angstrom sign"),
        MakerCase(links: [("a", "b"), ("b", "@O")], path: ["A", "s"], label: "link to a link"),
        MakerCase(links: [("loop", "loop")], path: ["LOOP", "s"], label: "self loop"),
        MakerCase(links: [("l1", "l2"), ("l2", "l1")], path: ["L1", "s"], label: "two-link loop"),
        MakerCase(links: [("self", "@D")], path: ["Self", "s"], label: "link to the folder itself"),
        MakerCase(links: [("up", "sub/../../outside")], path: ["UP", "s"], label: "dot-dot in a link target"),
        MakerCase(links: [("abs", "/")], path: ["ABS", "s"], label: "link to /"),
        MakerCase(links: [("deep", "@O")], path: ["sub", "..", "deep"], label: "dot-dot, then a link"),
    ]

    /// Each case, with the O_SEARCH opens and with the fallback (O_RDONLY) opens: nothing outside changes,
    /// nothing appears beside the folder, and what is made is real folders resolving inside it; anything else
    /// is `ExtractionContainmentError`.
    @Test(arguments: makerCases, [false, true])
    func theFolderMakerStaysInside(_ c: MakerCase, _ readOnlyOpens: Bool) throws {
        let r = try P.Root()
        defer { r.remove() }
        for (name, target) in c.links {
            try r.link(name, to: target.replacingOccurrences(of: "@O", with: r.outside.path)
                .replacingOccurrences(of: "@D", with: r.dest.path))
        }
        let outside = try H.snapshot(r.outside)
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: r.root.path).sorted()
        var made: URL?
        var thrown: (any Error)?
        do { made = try ArchiveModel.makeFolders(c.path[...], in: r.dest, readOnlyOpens: readOnlyOpens) } catch { thrown = error }

        #expect(try H.snapshot(r.outside) == outside, "CONTAINMENT \(c.label)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.root.path).sorted() == rootNames)
        if let made {
            var url = r.dest
            for component in c.path {
                url = url.appendingPathComponent(component)
                #expect(!H.isSymlink(url), "\(c.label): \(url.path) is a link")
            }
            let real = made.resolvingSymlinksInPath().path
            #expect(real.hasPrefix(r.dest.resolvingSymlinksInPath().path + "/"), "\(c.label): \(real)")
        } else {
            #expect(thrown is ExtractionContainmentError, "\(c.label): \(String(describing: thrown))")
        }
    }

    /// The engine's own link cases (`PerformContainmentTests.throughLinks`) with the fallback opens: still refused,
    /// nothing made anywhere.
    @Test(arguments: P.throughLinks)
    func theFallbackOpenNeverGoesThroughALink(_ c: P.Through) throws {
        let r = try P.Root()
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

    /// The fallback opens still merge real folders and make new ones.
    @Test func theFallbackOpenMakesAndMergesRealFolders() throws {
        let r = try P.Root()
        defer { r.remove() }
        let made = try ArchiveModel.makeFolders(["SUB", "a", "b"][...], in: r.dest, readOnlyOpens: true)
        #expect(made.path == r.dest.appendingPathComponent("SUB/a/b").path)
        #expect(try H.snapshot(r.dest) == [H.scalars("sub"): "dir", H.scalars("sub/a"): "dir",
                                           H.scalars("sub/a/b"): "dir"])
    }
}
