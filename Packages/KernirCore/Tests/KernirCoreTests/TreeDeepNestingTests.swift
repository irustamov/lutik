import Foundation
import Testing
@testable import KernirCore

/// A crafted archive can name an entry thousands of folders deep (a zip name holds 64 KB, a tar pax path has no
/// limit). Building, comparing, hashing and releasing that tree must not recurse once per level: app threads
/// other than main have 512 KB stacks, and a recursive builder overflowed even 8 MB at depth 8000 (debug).
/// Every check runs on a 512 KB thread and gives up after a deadline, so a hang fails instead of stalling the run.
@Suite("Tree on deeply nested paths")
struct TreeDeepNestingTests {
    static let smallStack = 512 << 10

    /// One file 20,000 folders deep ("d/d/.../d/f", about 40 KB of path): built, walked and released.
    @Test(.memoryHeavy) func singleDeepPathOnSmallStack() throws {
        let depth = 20_000
        let leaf = String(repeating: "d/", count: depth) + "f"
        let result = try #require(Self.onSmallStack(seconds: 120) { () -> (Int, Int, Int64?, Bool, Double) in
            let clock = ContinuousClock()
            var tree: [ArchiveNode] = []
            let elapsed = clock.measure {
                tree = Archive.tree(from: [ArchiveEntry(path: leaf, isDirectory: false, size: 3, compressedSize: nil,
                                                        modificationDate: nil)])
            }
            let (count, maxDepth) = Self.countAndDepth(tree)
            let leafFound = Self.deepest(tree)?.entry.path == leaf
            let size = tree.first?.totalSize
            tree = []  // released here, on the small stack
            return (count, maxDepth, size, leafFound, Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18)
        }, "tree(from:) did not finish (or crashed) for depth \(depth)")
        #expect(result.0 == depth + 1)
        #expect(result.1 == depth + 1)
        #expect(result.2 == 3)
        #expect(result.3)
        // Linear in the path bytes it has to copy (each synthesized folder holds its full path): about 0.1 s
        // release, 0.5 s debug when quiet. A quadratic step would take minutes.
        #expect(result.4 < 30, "build took \(result.4) s")
    }

    /// Wide and deep together: a 3,000-level trunk, eight 1,000-level branches under its bottom, files beside
    /// every 100th folder, and 1,000 files at the root. Built, checked node by node, and released on the small stack.
    @Test(.memoryHeavy) func wideAndDeepMixOnSmallStack() throws {
        var entries: [ArchiveEntry] = []
        var trunk = ""
        for level in 0..<3_000 {
            trunk += "t/"
            if level % 100 == 0 { entries.append(Self.file(trunk + "x\(level).bin", size: 1)) }
        }
        for b in 0..<8 {
            var path = trunk + "k\(b)/"
            entries.append(ArchiveEntry(path: String(path.dropLast()), isDirectory: true, size: nil,
                                        compressedSize: nil, modificationDate: nil))
            for level in 0..<1_000 {
                path += "b/"
                if level % 100 == 0 { entries.append(Self.file(path + "y.bin", size: 2)) }
            }
            entries.append(Self.file(path + "end.bin", size: 5))
        }
        for f in 0..<1_000 { entries.append(Self.file("root\(f).txt", size: 1)) }
        let expectedTotal: Int64 = 30 * 1 + 8 * (10 * 2 + 5) + 1_000
        let fileCount = entries.count
        let input = entries
        let result = try #require(Self.onSmallStack(seconds: 120) { () -> (Int, Int, Int64, Int, Bool) in
            var tree = Archive.tree(from: input)
            let (count, maxDepth) = Self.countAndDepth(tree)
            let total = tree.reduce(Int64(0)) { $0 + ($1.totalSize ?? 0) }
            var files = 0
            var placed = true
            var stack: [(ArchiveNode, String)] = tree.map { ($0, "") }
            while let (node, parent) = stack.popLast() {
                if !node.entry.isDirectory { files += 1 }
                if Array(node.entry.parentPath.utf8) != Array(parent.utf8) { placed = false }
                stack.append(contentsOf: (node.children ?? []).map { ($0, node.entry.path) })
            }
            tree = []
            return (count, maxDepth, total, files, placed)
        }, "tree(from:) did not finish (or crashed) for the wide and deep mix")
        #expect(result.0 == fileCount - 8 + 3_000 + 8 * 1_000 + 8)
        #expect(result.1 == 3_000 + 1 + 1_000 + 1)
        #expect(result.2 == expectedTotal)
        #expect(result.3 == fileCount - 8)
        #expect(result.4)
    }

    /// `==`, `hash(into:)` and release of a 100,000-level node chain, made directly (short paths, so it is cheap)
    /// and twice, so `==` has to walk both chains to the bottom.
    @Test(.memoryHeavy) func deepChainCompareHashReleaseOnSmallStack() throws {
        let result = try #require(Self.onSmallStack(seconds: 120) { () -> (Bool, Bool, Bool, Bool) in
            var a = Self.chain(depth: 100_000, leafSize: 1)
            var b = Self.chain(depth: 100_000, leafSize: 1)
            var c = Self.chain(depth: 100_000, leafSize: 2)
            let equal = a == b
            let unequal = a != c
            let hashes = a.hashValue == b.hashValue
            // A copy of the children shares storage: releasing the node must leave the copy whole.
            let kids = a.children
            a = Self.chain(depth: 0, leafSize: 1)
            let (count, _) = Self.countAndDepth(kids ?? [])
            b = a
            c = a
            return (equal, unequal, hashes, count == 100_000)
        }, "deep chain compare/hash/release did not finish (or crashed)")
        #expect(result.0)
        #expect(result.1)
        #expect(result.2)
        #expect(result.3)
    }

    /// `children` keeps nil (a file) apart from [] (an empty folder), in `==` as before.
    @Test func nilAndEmptyChildrenStayDistinct() {
        let e = ArchiveEntry(path: "x", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
        var a = ArchiveNode(entry: e, children: nil, totalSize: 0)
        let b = ArchiveNode(entry: e, children: [], totalSize: 0)
        #expect(a != b)
        #expect(a.children == nil)
        #expect(b.children == [])
        a.children = []
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        a.children?.append(b)
        #expect(a.children?.count == 1)
        #expect(a != b)
        #expect(Set([a, b, a]).count == 2)
    }

    /// Crafted sizes whose sum does not fit in Int64 make the folder total unknown instead of trapping.
    @Test func folderTotalPastInt64IsUnknown() {
        let big = Int64.max - 1
        let tree = Archive.tree(from: [Self.file("d/a", size: big), Self.file("d/b", size: big),
                                       Self.file("e/a", size: big), Self.file("e/b", size: 1)])
        #expect(tree.map(\.entry.path) == ["d", "e"])
        #expect(tree[0].totalSize == nil)
        #expect(tree[0].children?.map(\.totalSize) == [big, big])
        #expect(tree[1].totalSize == Int64.max)
    }

    // MARK: - Same tree as the recursive builder for ordinary archives

    /// A few hundred ordinary paths (nested folders, missing parents, empty folders, unknown sizes, duplicates,
    /// NFC/NFD twins, mixed case) give the same tree as the recursive builder this replaced.
    @Test(arguments: [1, 2, 3, 4, 5])
    func sameTreeAsRecursiveBuilder(seed: UInt64) {
        let entries = Self.ordinaryEntries(seed: seed, count: 400)
        let tree = Archive.tree(from: entries)
        let reference = RecursiveReferenceBuilder.build(entries)
        #expect(Self.outline(tree) == Self.outline(reference))
        #expect(tree == reference)
        #expect(tree.hashValue == reference.hashValue)
    }

    /// Degenerate and adversarial paths give the same tree as the recursive builder too: a file that is also a
    /// folder's parent, in both orders; empty, slash-only, trailing and double slashes; combining marks, NUL, BOM,
    /// CR LF, Prepend and regional-indicator scalars next to "/"; twins; unknown sizes with duplicates.
    @Test(arguments: 0..<degenerateSets.count)
    func sameTreeAsRecursiveBuilderOnDegeneratePaths(set: Int) {
        let entries = Self.degenerateSets[set].map { path, isDirectory, size in
            ArchiveEntry(path: path, isDirectory: isDirectory, size: size, compressedSize: nil, modificationDate: nil)
        }
        let tree = Archive.tree(from: entries)
        let reference = RecursiveReferenceBuilder.build(entries)
        #expect(Self.outline(tree) == Self.outline(reference), "set \(set)")
        #expect(tree == reference, "set \(set)")
    }

    static let degenerateSets: [[(String, Bool, Int64?)]] = [
        [("a", false, 1), ("a/b", false, 2)],
        [("a/b", false, 2), ("a", false, 1)],
        [("x", true, nil), ("x", false, 3), ("x/y", false, 1)],
        [("", false, 1), ("", true, nil), ("/", false, 2), ("//", true, nil), ("///x", false, 3)],
        [("a/", true, nil), ("a//b", false, 1), ("a/b/", true, nil), ("a/b//", false, 2)],
        [("a/\u{301}b", false, 1), ("a/\u{301}", false, 2), ("\u{301}/x", false, 3), ("/\u{301}", false, 4)],
        [("\0", false, 1), ("\0/", true, nil), ("a\0/b", false, 2), ("a\0", false, 3)],
        [("caf\u{E9}/x", false, 1), ("cafe\u{301}/x", false, 2), ("Caf\u{E9}/x", false, 3), ("CAFE\u{301}", false, 4)],
        [("d/a", false, nil), ("d/a", false, 5), ("d/b", false, 1), ("e/a", false, 2), ("e/a", false, nil)],
        [(".", false, 1), ("..", true, nil), ("./a", false, 2), ("../b", false, 3), ("a/./b", false, 4)],
        [("\u{1F1E6}/\u{1F1E8}", false, 1), ("\u{1F1E6}\u{1F1E8}", false, 2)],
        [("\u{FEFF}/", true, nil), ("\u{FEFF}/x", false, 1), ("\u{FEFF}", false, 2)],
        [("\r\n/x", false, 1), ("\r/x", false, 2), ("\n/x", false, 3)],
        [("\u{600}/y", false, 1), ("\u{600}", true, nil), ("x\u{600}/z", false, 2)],
        [("img 10", false, 1), ("img 2", false, 2), ("img 1", true, nil), ("img 10/img 2", false, 3)],
    ]

    /// `name` (now found without splitting the whole path) is still the last component of the scalar split.
    @Test func nameIsLastSplitComponent() {
        let paths = ["", "/", "//", "a", "a/", "a//", "/a", "a/b", "a/b/", "a//b", "a/./b", ".", "..", "../",
                     "a/\u{301}b", "d/\u{301}", "\u{600}/x", "x/\u{200D}", "caf\u{E9}/n\u{303}o", "e\u{301}/",
                     "a\0/b", "/\u{301}", "\u{1F600}/\u{1F600}", "a\\b/c\\d", String(repeating: "q/", count: 50)]
        for path in paths {
            let entry = ArchiveEntry(path: path, isDirectory: false, size: nil, compressedSize: nil, modificationDate: nil)
            let expected = EntryPath.split(path).last ?? path
            #expect(Array(entry.name.unicodeScalars) == Array(expected.unicodeScalars), "\(path.debugDescription)")
        }
    }

    /// `name` scans back from the end only, so on a 100 KB path it costs what it costs on "d/f". A whole-path split
    /// (`EntryPath.split(path).last`) is ~10^4 times slower. The best of 5 rounds is compared, so load cannot fake it.
    @Test func nameCostDoesNotGrowWithPathLength() {
        let deep = Self.file(String(repeating: "d/", count: 50_000) + "f", size: nil)
        let short = Self.file("d/f", size: nil)
        func best(_ entry: ArchiveEntry) -> Duration {
            let clock = ContinuousClock()
            var best = Duration.seconds(1_000)
            var sink = 0
            for _ in 0..<5 {
                best = min(best, clock.measure { for _ in 0..<10 { sink &+= entry.name.utf8.count } })
            }
            #expect(sink == 50)
            return best
        }
        let ratio = best(deep) / best(short)
        #expect(ratio < 50, "name on a 100 KB path costs \(ratio)x a short one")
    }

    // MARK: - Helpers

    static func file(_ path: String, size: Int64?) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: nil, modificationDate: nil)
    }

    /// A chain of `depth` folders named "c" over one file.
    static func chain(depth: Int, leafSize: Int64) -> ArchiveNode {
        var node = ArchiveNode(entry: file("f", size: leafSize), children: nil, totalSize: leafSize)
        let folder = ArchiveEntry(path: "c", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
        for _ in 0..<depth { node = ArchiveNode(entry: folder, children: [node], totalSize: leafSize) }
        return node
    }

    /// Node count and deepest level (top level = 1), without recursion.
    static func countAndDepth(_ nodes: [ArchiveNode]) -> (Int, Int) {
        var count = 0, maxDepth = 0
        var stack = nodes.map { ($0, 1) }
        while let (node, depth) = stack.popLast() {
            count += 1
            maxDepth = max(maxDepth, depth)
            stack.append(contentsOf: (node.children ?? []).map { ($0, depth + 1) })
        }
        return (count, maxDepth)
    }

    static func deepest(_ nodes: [ArchiveNode]) -> ArchiveNode? {
        var level = nodes
        var last: ArchiveNode?
        while let first = level.first { last = first; level = first.children ?? [] }
        return last
    }

    struct Line: Equatable {
        let depth: Int
        let path: [UInt8]
        let isDirectory: Bool
        let size: Int64?
        let totalSize: Int64?
        let childCount: Int?
    }

    static func outline(_ nodes: [ArchiveNode]) -> [Line] {
        var out: [Line] = []
        var stack = nodes.reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            out.append(Line(depth: depth, path: Array(node.entry.path.utf8), isDirectory: node.entry.isDirectory,
                            size: node.entry.size, totalSize: node.totalSize, childCount: node.children?.count))
            stack.append(contentsOf: (node.children ?? []).reversed().map { ($0, depth + 1) })
        }
        return out
    }

    /// Deterministic ordinary entries: up to 5 levels from a small name pool, some folders listed, some not.
    static func ordinaryEntries(seed: UInt64, count: Int) -> [ArchiveEntry] {
        var rng = SplitMix(seed: seed)
        let names = ["src", "Src", "docs", "a", "B", "caf\u{E9}", "cafe\u{301}", "img 2", "img 10", "readme.md",
                     "x.txt", "X.txt", "\u{1F600}", "z", "build"]
        var out: [ArchiveEntry] = []
        for _ in 0..<count {
            let depth = Int(rng.next() % 5) + 1
            let path = (0..<depth).map { _ in names[Int(rng.next() % UInt64(names.count))] }.joined(separator: "/")
            switch rng.next() % 6 {
            case 0: out.append(ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil,
                                            modificationDate: nil))
            case 1: out.append(file(path, size: nil))
            default: out.append(file(path, size: Int64(rng.next() % 1_000)))
            }
        }
        return out
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Runs `body` on a thread with a 512 KB stack; nil when it does not finish within `seconds`.
    static func onSmallStack<T>(seconds: Double, _ body: @escaping @Sendable () -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let value = body()
            box.lock.withLock { box.value = value }
            done.signal()
        }
        thread.stackSize = smallStack
        thread.start()
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.lock.withLock { box.value }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    let lock = NSLock()
    var value: T?
}

/// The recursive builder as it was before the iterative rewrite, kept as the oracle for ordinary trees.
/// It names entries as that version did too (the last component of the whole-path split), not with today's `name`.
private enum RecursiveReferenceBuilder {
    static func build(_ entries: [ArchiveEntry]) -> [ArchiveNode] {
        var byPath: [Exact: ArchiveEntry] = [:]
        for entry in entries where !entry.path.isEmpty { byPath[Exact(entry.path)] = entry }
        var grouped: [Exact: [ArchiveEntry]] = [:]
        for entry in Array(byPath.values) {
            var parent = EntryPath.parent(of: entry.path) ?? ""
            grouped[Exact(parent), default: []].append(entry)
            while !parent.isEmpty, byPath[Exact(parent)] == nil {
                let synthesized = ArchiveEntry(path: parent, isDirectory: true, size: nil,
                                               compressedSize: nil, modificationDate: nil)
                byPath[Exact(parent)] = synthesized
                parent = EntryPath.parent(of: parent) ?? ""
                grouped[Exact(parent), default: []].append(synthesized)
            }
        }
        let childrenOf = grouped.mapValues { list in
            list.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                switch (name(a) as NSString).localizedStandardCompare(name(b)) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
                }
            }
        }
        func nodes(under parent: String) -> [ArchiveNode] {
            (childrenOf[Exact(parent)] ?? []).map { entry in
                guard entry.isDirectory else { return ArchiveNode(entry: entry, children: nil, totalSize: entry.size) }
                let kids = nodes(under: entry.path)
                let sizes = kids.map(\.totalSize)
                return ArchiveNode(entry: entry, children: kids,
                                   totalSize: sizes.contains(nil) ? nil : sizes.reduce(0) { $0 + ($1 ?? 0) })
            }
        }
        return nodes(under: "")
    }

    static func name(_ entry: ArchiveEntry) -> String { EntryPath.split(entry.path).last ?? entry.path }

    struct Exact: Hashable {
        let bytes: [UInt8]
        init(_ path: String) { bytes = Array(path.utf8) }
    }
}
