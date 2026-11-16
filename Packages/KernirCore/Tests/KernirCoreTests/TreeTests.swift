import Foundation
import Testing
@testable import KernirCore

@Test func sampleTreeHasFoldersFirst() {
    let tree = Archive.tree(from: SampleArchive().entries)
    #expect(tree.map(\.entry.name) == ["assets", "src", "brief.pdf", "README.md"])
    #expect(tree.first?.children?.count == 1)
}

@Test(.memoryHeavy) func treeOf100kEntriesIsFast() {
    var entries: [ArchiveEntry] = []
    for d in 0..<1_000 {
        entries.append(.init(path: "dir\(d)", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil))
        for f in 0..<100 {
            entries.append(.init(path: "dir\(d)/file\(f).txt", isDirectory: false, size: 10, compressedSize: nil, modificationDate: nil))
        }
    }
    let clock = ContinuousClock()
    var tree: [ArchiveNode] = []
    // Thread CPU time ignores load from parallel suites; the quadratic builder took minutes. 3 s leaves room for
    // slower CI cores (GitHub macos-26 runner: 1.59 s; local ~0.85 s) and still catches that. The child
    // sort runs on concurrentPerform, so this thread's time undercounts it: a wall-clock backstop catches
    // a catastrophic regression there.
    let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    var elapsed = clock.measure { tree = Archive.tree(from: entries) }
    let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9
    #expect(tree.count == 1_000)
    #expect(tree[0].children?.count == 100)
    #expect(tree[0].totalSize == 1_000)
    #expect(cpu <= 3.0, "thread CPU \(cpu) s")
    // Parallel suites stretch wall time (6.4 s seen against ~0.85 s quiet), but only in bursts; a real
    // regression is slow every time. So the best of up to three builds must stay under 10 s (~12× quiet).
    for _ in 1..<3 where elapsed >= .seconds(10) {
        elapsed = min(elapsed, clock.measure { _ = Archive.tree(from: entries) })
    }
    #expect(elapsed < .seconds(10), "best wall \(elapsed)")
}

@Test func treeTreatsBridgedAndNativePathsAlike() {
    // A Foundation-bridged path is not contiguous UTF-8; equal bytes must still be one path.
    let native = "dir/caf\u{E9}.txt"
    let utf16 = Array(native.utf16)
    let bridged = NSString(characters: utf16, length: utf16.count) as String
    #expect(bridged.utf8.withContiguousStorageIfAvailable { _ in true } == nil)
    let a = ArchiveEntry(path: native, isDirectory: false, size: 1, compressedSize: nil, modificationDate: nil)
    let b = ArchiveEntry(path: bridged, isDirectory: false, size: 2, compressedSize: nil, modificationDate: nil)
    for (list, size) in [([a, b], Int64(2)), ([b, a], 1)] {
        let tree = Archive.tree(from: list)
        #expect(tree.count == 1)
        #expect(tree.first?.children?.count == 1)
        #expect(tree.first?.children?.first?.entry.size == size)
    }
}

@Test func treeSynthesizesMissingParents() {
    let c = ArchiveEntry(path: "a/b/c.txt", isDirectory: false, size: 7, compressedSize: nil, modificationDate: nil)
    let tree = Archive.tree(from: [c])
    #expect(tree.map(\.entry.path) == ["a"])
    #expect(tree[0].entry.isDirectory)
    #expect(tree[0].children?.map(\.entry.path) == ["a/b"])
    #expect(tree[0].children?[0].children?.map(\.entry.path) == ["a/b/c.txt"])
    #expect(tree[0].totalSize == 7)
}

/// A folder's size is a sum only when every file under it has a known size; one unknown file makes the
/// folder's size unknown (nil), not a smaller number or 0. Empty folders are 0.
@Test func folderSizeIsUnknownWhenAnyFileSizeIsUnknown() {
    func file(_ p: String, _ size: Int64?) -> ArchiveEntry {
        .init(path: p, isDirectory: false, size: size, compressedSize: nil, modificationDate: nil)
    }
    let empty = ArchiveEntry(path: "empty", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    let tree = Archive.tree(from: [
        file("all/a", nil), file("all/b", nil),
        file("some/a", 5), file("some/deep/b", nil),
        file("known/a", 5), file("known/deep/b", 6), empty,
    ])
    func size(_ name: String) -> Int64? { tree.first { $0.entry.name == name }?.totalSize }
    #expect(size("all") == nil)
    #expect(size("some") == nil)
    #expect(size("known") == 11)
    #expect(size("empty") == 0)
}

@Test func treeDuplicatePathsLastWins() {
    let one = ArchiveEntry(path: "x.txt", isDirectory: false, size: 1, compressedSize: nil, modificationDate: nil)
    let two = ArchiveEntry(path: "x.txt", isDirectory: false, size: 2, compressedSize: nil, modificationDate: nil)
    let tree = Archive.tree(from: [one, two])
    #expect(tree.count == 1)
    #expect(tree[0].totalSize == 2)
}

@Test func macOSMetadataDetection() {
    func e(_ p: String) -> ArchiveEntry { .init(path: p, isDirectory: false, size: 1, compressedSize: nil, modificationDate: nil) }
    for p in ["__MACOSX", "__MACOSX/d/._a.txt", "d/._a.txt"] { #expect(e(p).isMacOSMetadata) }
    for p in ["d/a.txt", "d/_a.txt", "MACOSX/a"] { #expect(!e(p).isMacOSMetadata) }
}

/// A `__MACOSX` path component is metadata at any depth, as at the root. Whole component, case-
/// sensitive; a file or a folder named `__MACOSX` matches alike (as the root rule does: it has no kind to look at).
/// `isExcludedEntry`, the write-side rule, agrees on every path.
@Test(arguments: [false, true])
func nestedMACOSXIsMetadata(_ isDirectory: Bool) {
    func e(_ p: String) -> ArchiveEntry {
        .init(path: p, isDirectory: isDirectory, size: 1, compressedSize: nil, modificationDate: nil)
    }
    // The last three put a `_` or a look-alike before the real component: the cheap byte scan must not stop at the
    // first `_` it sees.
    for p in ["a/__MACOSX", "a/__MACOSX/x", "a/b/__MACOSX/._x", "a/b/__MACOSX/c/d", "__MACOSX", "__MACOSX/x",
              "a_b/__MACOSX/x", "_/__MACOSX", "__MACOSXfoo/__MACOSX/z"] {
        #expect(e(p).isMacOSMetadata, "\(p)")
        #expect(MacOSMetadata.isExcludedEntry(path: p), "\(p)")
    }
    for p in ["__MACOSXfoo", "__MACOSXfoo/x", "a/__MACOSXfoo", "a/__MACOSXfoo/x", "foo__MACOSX/x", "a/foo__MACOSX",
              "a/foo__MACOSX/x", "a/__macosx/x", "a/__MacOSX", "a/__MACOSX_old/x", "a/__MACOSX copy/x", "a/MACOSX/x",
              "a/_MACOSX/x", "a/x__MACOSX__/y"] {
        #expect(!e(p).isMacOSMetadata, "\(p)")
        #expect(!MacOSMetadata.isExcludedEntry(path: p), "\(p)")
    }
}

/// Siblings that localizedStandardCompare calls equal ("A"/"a", NFC/NFD twins) are ordered by their UTF-8
/// bytes, so the tree is the same whatever order the entries come in, and twins never merge.
@Test func treeTiebreakIsIndependentOfInputOrder() {
    let names = ["A", "a", "\u{E9}.txt", "e\u{301}.txt"]
    func permutations(_ a: [String]) -> [[String]] {
        a.count <= 1 ? [a] : a.indices.flatMap { i in
            permutations(Array(a[..<i] + a[(i + 1)...])).map { [a[i]] + $0 }
        }
    }
    let orders = Set(permutations(names).map { order in
        Archive.tree(from: order.map {
            ArchiveEntry(path: $0, isDirectory: false, size: 1, compressedSize: nil, modificationDate: nil)
        }).map { Array($0.entry.path.utf8) }
    })
    #expect(orders.count == 1)
    #expect(orders.first?.count == 4)
}
