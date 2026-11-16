import Testing
import Foundation
@testable import Kernir
import KernirCore

private func sampleItems() -> [ArchiveItem] {
    ArchiveItem.items(from: Archive.tree(from: SampleArchive().entries), pendingPaths: [])
}

@Test func itemsCarryFolderTotals() throws {
    let src = try #require(sampleItems().first { $0.name == "src" })
    #expect(src.size == 6_144)
    #expect(src.kind == "Folder")
    #expect(src.children?.map(\.name) == ["main.swift", "utils.swift"])
}

@Test func pendingPathsAreFlagged() {
    let items = ArchiveItem.items(from: Archive.tree(from: SampleArchive().entries), pendingPaths: ["src/main.swift"])
    let flagged = items.flattened().filter(\.isPendingAddition).map(\.path)
    #expect(flagged == ["src/main.swift"])
}

@Test func sortBySizeDescendingKeepsFoldersFirst() {
    let sorted = sampleItems().sorted(using: [KeyPathComparator(\.sizeSortKey, order: .reverse)])
    #expect(sorted.map(\.name) == ["assets", "src", "brief.pdf", "README.md"])
}

@Test func sortIsRecursive() throws {
    let sorted = sampleItems().sorted(using: [KeyPathComparator(\.name, comparator: .localizedStandard, order: .reverse)])
    let src = try #require(sorted.first { $0.name == "src" })
    #expect(src.children?.map(\.name) == ["utils.swift", "main.swift"])
}

@Test func searchKeepsAncestors() {
    let result = sampleItems().filtered(matching: "main")
    #expect(result.map(\.name) == ["src"])
    #expect(result.first?.children?.map(\.name) == ["main.swift"])
}

@Test func matchingFolderKeepsFullSubtree() {
    let result = sampleItems().filtered(matching: "src")
    #expect(result.map(\.name) == ["src"])
    #expect(result.first?.children?.map(\.name) == ["main.swift", "utils.swift"])
}

@Test func searchMatchesNFDAgainstNFC() {
    func file(_ name: String) -> ArchiveItem {
        ArchiveItem(path: name, name: name, isDirectory: false, size: 1, kind: "Document",
                    modificationDate: nil, isPendingAddition: false, children: nil)
    }
    #expect([file("Cafe\u{301}.txt")].filtered(matching: "Caf\u{E9}").count == 1)
    #expect([file("Caf\u{E9}.txt")].filtered(matching: "Cafe\u{301}").count == 1)
}

@Test func emptyQueryReturnsAll() {
    let items = sampleItems()
    #expect(items.filtered(matching: "") == items)
    #expect(items.filtered(matching: "   ") == items)
}

@Test func directoryIDsAndFlattened() {
    let items = sampleItems()
    #expect(items.directoryIDs == ["src", "assets"])
    #expect(items.flattened().count == SampleArchive().entries.count)
}

@Test func fiftyThousandEntriesSortAndFilterFast() {
    // 500 folders x (1 folder + 99 files) = 50 000 entries, built through KernirCore's tree.
    var entries: [ArchiveEntry] = []
    for d in 0..<500 {
        entries.append(ArchiveEntry(path: "dir\(d)", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil))
        for f in 0..<99 {
            entries.append(ArchiveEntry(path: "dir\(d)/file\(f).txt", isDirectory: false, size: Int64(f),
                                        compressedSize: nil, modificationDate: Date(timeIntervalSince1970: Double(f))))
        }
    }
    #expect(entries.count == 50_000)

    var found = 0
    let elapsed = ContinuousClock().measure {
        let nodes = Archive.tree(from: entries)
        let items = ArchiveItem.items(from: nodes, pendingPaths: [])
        let sorted = items.sorted(using: [KeyPathComparator(\.sizeSortKey, order: .reverse)])
        found = sorted.filtered(matching: "file42").flattened().count
    }
    #expect(found == 500 * 2)
    // CI runners are 2-3x slower; the regressions this catches took 10-70 s.
    #expect(elapsed < .seconds(5))
}
