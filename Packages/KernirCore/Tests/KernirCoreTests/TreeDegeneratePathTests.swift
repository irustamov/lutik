import Foundation
import Testing
@testable import KernirCore

/// `Archive.tree(from:)` must finish for every entry path, however odd. The reader only lists normalized paths
/// (`EntryPath.normalize`), but the builder is public and must not depend on that.
///
/// What each path produces: the entry sits under its `parentPath`, and every missing ancestor (each step of
/// `EntryPath.parent` down to "") is synthesized as a folder. Paths are shown as given, never normalized, so
/// `a//` gives `a` > `a/` > `a//`. The one exception is "": its `parentPath` is "" too, so it names the root
/// itself, which is not a node; it is left out, folder or file. Extraction writes none of these as given: it
/// works on normalized paths, where "", "/", "//", ".", "./", "..", "../" are nothing and the rest become
/// `a`, `a`, `a/b`, `a/b`, `\u{301}`, `\u{301}`, `\u{600}`, `\u{200D}`.
@Suite("Tree builder on degenerate paths")
struct TreeDegeneratePathTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let path: String
        /// Node paths from the root down to the entry itself, outermost first; empty when it has no node.
        let chain: [String]
        /// The entry's `name` (what its row shows).
        let name: String?
        var testDescription: String { path.unicodeScalars.map { $0.isASCII ? String($0) : $0.escaped(asASCII: true) }.joined() }
    }

    static let cases: [Case] = [
        Case(path: "", chain: [], name: nil),
        Case(path: "/", chain: ["/"], name: "/"),
        Case(path: "//", chain: ["/", "//"], name: "//"),
        Case(path: ".", chain: ["."], name: "."),
        Case(path: "./", chain: [".", "./"], name: "."),
        Case(path: "..", chain: [".."], name: ".."),
        Case(path: "../", chain: ["..", "../"], name: ".."),
        Case(path: "a//", chain: ["a", "a/", "a//"], name: "a"),
        Case(path: "/a", chain: ["/a"], name: "a"),
        Case(path: "a/./b", chain: ["a", "a/.", "a/./b"], name: "b"),
        Case(path: "a/../b", chain: ["a", "a/..", "a/../b"], name: "b"),
        Case(path: "\u{301}", chain: ["\u{301}"], name: "\u{301}"),
        Case(path: "/\u{301}", chain: ["/\u{301}"], name: "\u{301}"),
        Case(path: "\u{600}/", chain: ["\u{600}", "\u{600}/"], name: "\u{600}"),
        Case(path: "\u{200D}/", chain: ["\u{200D}", "\u{200D}/"], name: "\u{200D}"),
    ]

    @Test(arguments: cases, [true, false])
    func buildsInBoundedTime(_ c: Case, isDirectory: Bool) throws {
        let entry = Self.entry(c.path, isDirectory: isDirectory)
        let other = Self.entry(c.path, isDirectory: !isDirectory)
        // Alone, twice, and after the same path of the other kind (the last one wins).
        for entries in [[entry], [entry, entry], [other, entry]] {
            let tree = try #require(Self.buildWithDeadline(entries), "tree(from:) did not finish for \(c.testDescription)")
            let outline = Self.outline(tree)
            let expected = c.chain.enumerated().map { i, p in
                Line(depth: i, path: p, isDirectory: i < c.chain.count - 1 || isDirectory)
            }
            #expect(outline == expected)
            if let name = c.name, let leaf = outline.last {
                #expect(leaf.name == name)
            }
            Self.checkPlacement(tree, under: "")
        }
    }

    /// Every case together, both kinds, with a normal entry beside them: still finishes, and the normal entry is there.
    @Test func allCasesTogetherFinish() throws {
        var entries = Self.cases.flatMap { [Self.entry($0.path, isDirectory: true), Self.entry($0.path, isDirectory: false)] }
        entries.append(Self.entry("ok.txt", isDirectory: false))
        let tree = try #require(Self.buildWithDeadline(entries))
        #expect(tree.contains { $0.entry.path == "ok.txt" })
        #expect(!Self.outline(tree).contains { $0.path.isEmpty })
        Self.checkPlacement(tree, under: "")
    }

    // MARK: - Helpers

    struct Line: Equatable, CustomStringConvertible {
        let depth: Int
        let path: String
        let isDirectory: Bool
        var name: String = ""
        static func == (a: Line, b: Line) -> Bool {
            a.depth == b.depth && Array(a.path.utf8) == Array(b.path.utf8) && a.isDirectory == b.isDirectory
        }
        var description: String { "\(depth):\(Array(path.unicodeScalars).map { $0.escaped(asASCII: true) }.joined())\(isDirectory ? "[D]" : "[F]")" }
    }

    static func entry(_ path: String, isDirectory: Bool) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: isDirectory, size: isDirectory ? nil : 1, compressedSize: nil,
                     modificationDate: nil)
    }

    static func outline(_ nodes: [ArchiveNode], depth: Int = 0) -> [Line] {
        nodes.flatMap { node in
            [Line(depth: depth, path: node.entry.path, isDirectory: node.entry.isDirectory, name: node.entry.name)]
                + outline(node.children ?? [], depth: depth + 1)
        }
    }

    /// Each node sits under its own `parentPath`, compared by bytes.
    static func checkPlacement(_ nodes: [ArchiveNode], under parent: String) {
        for node in nodes {
            #expect(Array(node.entry.parentPath.utf8) == Array(parent.utf8), "\(node.entry.path) under \(parent)")
            checkPlacement(node.children ?? [], under: node.entry.path)
        }
    }

    /// Builds on its own thread and gives up after `seconds`, so a builder that never returns fails the test
    /// instead of hanging the run.
    static func buildWithDeadline(_ entries: [ArchiveEntry], seconds: Double = 5) -> [ArchiveNode]? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var tree: [ArchiveNode]?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let tree = Archive.tree(from: entries)
            box.lock.withLock { box.tree = tree }
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.lock.withLock { box.tree }
    }
}
