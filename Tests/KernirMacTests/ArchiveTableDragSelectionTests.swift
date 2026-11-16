import Foundation
import Testing
@testable import Kernir
import KernirCore

// Which archive path a dragged table row brings (`ArchiveTableDragSelection`): AppKit drags every
// selected row and asks for each one's writer by row; a row brings the path the table shows at that
// row, worked out from the items the Table was handed (`rows(of:expanded:)`), never from the window's
// live model or its selection binding, either of which may be ahead of the table. A row outside the
// selection, rows that don't match the table (count, or a selected row's level), or a row inside
// another selected folder gives none. Slot-free.

/// A drag over `paths`, each at the level its path has, in a table that shows them at those levels
/// (`tableLevels` overrides that) with `rowCount` rows.
private func drag(_ selected: [Int], _ paths: [String], rowCount: Int? = nil,
                  tableLevels: [Int]? = nil) -> ArchiveTableDragSelection {
    let rows = paths.map { ArchiveTableDragSelection.Row(path: $0, level: $0.split(separator: "/").count - 1) }
    let levels = tableLevels ?? rows.map(\.level)
    return ArchiveTableDragSelection(draggedRows: IndexSet(selected), rows: rows, rowCount: rowCount ?? rows.count,
                                     level: { levels.indices.contains($0) ? levels[$0] : -1 })
}

private func file(_ path: String, size: Int64) -> ArchiveItem {
    ArchiveItem(path: path, name: String(path.split(separator: "/").last!), isDirectory: false, size: size,
                kind: "", modificationDate: nil, isPendingAddition: false, children: nil)
}

private func folder(_ path: String, _ children: [ArchiveItem]) -> ArchiveItem {
    ArchiveItem(path: path, name: String(path.split(separator: "/").last!), isDirectory: true,
                size: children.reduce(0) { $0 + ($1.size ?? 0) }, kind: "", modificationDate: nil,
                isPendingAddition: false, children: children)
}

private func entry(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
}

struct ArchiveTableDragSelectionTests {
    @Test(arguments: [
        (0, [0, 2], ["a", "x", "b"], "a"),
        (2, [0, 2], ["a", "x", "b"], "b"),
        (1, [0, 2], ["a", "x", "b"], nil),         // not selected
        (3, [0, 3], ["a", "x", "b"], nil),         // a selected row past the rows: no drag rather than the wrong file
        (-1, [0], ["a"], nil),                     // AppKit's "no row"
        (0, [], [], nil),
    ] as [(Int, [Int], [String], String?)])
    func eachSelectedRowBringsThePathTheTableShowsThere(row: Int, selected: [Int], rows: [String],
                                                        expected: String?) {
        let selection = drag(selected, rows)
        #expect(selection.path(forRow: row) == expected)
    }

    /// Rows that don't match the table's row count (a table not caught up with the window): no drag.
    @Test func rowsThatDontMatchTheTableBringNothing() {
        let selection = drag([0, 1], ["a", "b"], rowCount: 3)
        #expect([0, 1, 2].compactMap(selection.path(forRow:)).isEmpty)
    }

    /// N selected rows give N paths, in table order, none twice.
    @Test func everySelectedRowBringsItsOwnPath() {
        let rows = (0..<12).map { "r\($0)" }
        let selection = drag([1, 4, 6, 9], rows)
        #expect([1, 4, 6, 9].compactMap(selection.path(forRow:)) == ["r1", "r4", "r6", "r9"])
        #expect((0..<12).filter { ![1, 4, 6, 9].contains($0) }.compactMap(selection.path(forRow:)).isEmpty)
    }

    /// The selection moved from one row to another (a click-drag on an unselected row): the drag
    /// brings the new row's path, whatever the window's selection binding still says.
    @Test func aMovedSelectionBringsTheNewRow() {
        let rows = ["docs", "b.pdf", "c.png"]
        let selection = drag([2], rows)
        #expect((0..<3).map(selection.path(forRow:)) == [nil, nil, "c.png"])
    }

    /// A selected row hidden under a closed, selected folder is not a row of the table: the folder's
    /// row still brings the folder (and with it the hidden row), not "no drag".
    @Test func aSelectedRowUnderAClosedFolderDoesntStopTheDrag() {
        // docs closed: its selected docs/a.txt isn't shown, so it isn't one of the rows.
        let selection = drag([0, 2], ["docs", "b.pdf", "c.png"])
        #expect((0..<3).map(selection.path(forRow:)) == ["docs", nil, "c.png"])
    }

    /// A row inside another selected folder, at any depth, stays out: the folder brings it.
    @Test func aRowInsideASelectedFolderBringsNothing() {
        let rows = ["docs", "docs/a.txt", "docs/sub/b.txt", "docs2/c.txt", "doc"]
        let selection = drag(Array(0..<5), rows)
        #expect((0..<5).map(selection.path(forRow:)) == ["docs", nil, nil, "docs2/c.txt", "doc"])
    }

    /// A folder and a row of its own name elsewhere are not nested: only the path's own ancestors count.
    @Test func onlyTheRowsOwnAncestorsCoverIt() {
        let rows = ["a/b", "b", "a/b/c"]
        let selection = drag([0, 1, 2], rows)
        #expect((0..<3).map(selection.path(forRow:)) == ["a/b", "b", nil])
    }

    /// Only selected rows cover: a row under an open folder that isn't selected brings itself.
    @Test func anUnselectedFolderCoversNothing() {
        let rows = ["docs", "docs/a.txt"]
        let selection = drag([1], rows)
        #expect(selection.path(forRow: 1) == "docs/a.txt")
    }

    /// Each drag is its own drop: its rows' promises share its id, and the next drag gets another one,
    /// so a Cancel stops only the rows of its own drop.
    @Test func eachDragHasItsOwnDropID() {
        let first = drag([0, 1], ["a", "b"])
        let second = drag([0, 1], ["a", "b"])
        #expect(first.dropID != second.dropID)
    }

    /// A selected row the table shows at another level than the rows have it (a table not caught up
    /// with an opened or closed folder, at the same row count): no row brings anything.
    @Test func aSelectedRowAtAnotherLevelStopsTheWholeDrag() {
        // The rows have docs open (docs/a.txt at level 1); the table still shows docs closed.
        let stale = drag([0, 1], ["docs", "docs/a.txt", "b.pdf"], tableLevels: [0, 0, 0])
        #expect((0..<3).compactMap(stale.path(forRow:)).isEmpty)
        // Only selected rows are checked: these match.
        let fine = drag([2], ["docs", "docs/a.txt", "b.pdf"], tableLevels: [0, 0, 0])
        #expect((0..<3).map(fine.path(forRow:)) == [nil, nil, "b.pdf"])
    }

    /// The rows are the items the Table was handed, top to bottom: an open folder's contents under
    /// it at the next level, a closed folder's not.
    @Test func theRowsAreTheTablesItemsWithOpenFoldersContents() {
        let items = [folder("docs", [folder("docs/sub", [file("docs/sub/n.txt", size: 1)]), file("docs/a.txt", size: 2)]),
                     folder("pics", [file("pics/p.png", size: 3)]), file("b.pdf", size: 4)]
        let rows = ArchiveTableDragSelection.rows(of: items, expanded: ["docs", "docs/sub"])
        #expect(rows.map(\.path) == ["docs", "docs/sub", "docs/sub/n.txt", "docs/a.txt", "pics", "b.pdf"])
        #expect(rows.map(\.level) == [0, 1, 2, 1, 0, 0])
        // A folder open under a closed one shows nothing.
        #expect(ArchiveTableDragSelection.rows(of: items, expanded: ["docs/sub"]).map(\.path)
                == ["docs", "pics", "b.pdf"])
    }

    /// The window's table items (searched, then sorted Size descending, folders first) with a nested
    /// folder open give the rows in the order the table shows them. The hosted
    /// `theWritersFollowTheOutlinesRows` checks the same fixture against the real outline.
    @Test func theRowsFollowSearchSortAndNestedFolders() {
        let items = [
            folder("a-reports", [file("a-reports/q.txt", size: 15)]),
            folder("docs", [folder("docs/sub", [file("docs/sub/report-long-name.txt", size: 29),
                                                 file("docs/sub/r.txt", size: 14)]),
                            file("docs/report.md", size: 14), file("docs/z-report-extended.md", size: 25),
                            file("docs/x.bin", size: 10)]),
            file("big-report.txt", size: 14), file("readme-report.txt", size: 17), file("a.txt", size: 5),
        ]
        let shown = items.filtered(matching: "report")
            .sorted(using: [KeyPathComparator(\ArchiveItem.sizeSortKey, order: .reverse)])
        let rows = ArchiveTableDragSelection.rows(of: shown, expanded: ["docs", "docs/sub", "a-reports"])
        #expect(rows.map(\.path) == ["docs", "docs/sub", "docs/sub/report-long-name.txt", "docs/z-report-extended.md",
                                     "docs/report.md", "a-reports", "a-reports/q.txt", "readme-report.txt",
                                     "big-report.txt"])
        #expect(rows.map(\.level) == [0, 1, 2, 1, 1, 0, 1, 0, 0])
    }

    /// The drag's rows take the items and the open folders at the same time, when the Table
    /// is handed its items. A folder opened after that (a reopen's main-actor job landing before the
    /// table has redrawn) doesn't add its contents to the rows: they stay the pair the outline shows.
    @MainActor @Test func theRowsKeepTheOpenFoldersTakenWithTheItems() {
        final class Window { var expanded: Set<String> = [] }
        let window = Window()
        let items = [folder("docs", [file("docs/a.txt", size: 1)]), file("b.pdf", size: 2)]
        let rows = ArchiveTableDragSelection.rowsTaken(of: items, expanded: window.expanded)

        window.expanded = ["docs"]

        #expect(rows().map(\.path) == ["docs", "b.pdf"])
        #expect(ArchiveTableDragSelection.rowsTaken(of: items, expanded: window.expanded)().map(\.path)
                == ["docs", "docs/a.txt", "b.pdf"])
    }

    /// The model changed (a rename landed) but the table still shows
    /// the items it was handed. The drag follows those items, so the row the user grabbed brings its
    /// own file; rows from the live model would hand over the next one.
    @MainActor @Test func aRenameTheTableHasntShownYetDoesntChangeTheDrag() {
        let model = ArchiveModel(reader: FakeReader(entries: [entry("a"), entry("b"), entry("c")]), undoManager: nil)
        let order = [KeyPathComparator(\ArchiveItem.name, comparator: .localizedStandard)]
        let handedToTheTable = model.items.sorted(using: order)
        model.didSave(reader: FakeReader(entries: [entry("b"), entry("c"), entry("d")]), renamed: ["a": "d"])
        let live = model.items.sorted(using: order)
        #expect(live.map(\.path) == ["b", "c", "d"])  // same count: the row count can't tell

        // The user grabs "b", row 1 of the table, which still shows a, b, c.
        let tableLevels: (Int) -> Int = { _ in 0 }
        let selection = ArchiveTableDragSelection(
            draggedRows: IndexSet([1]), rows: ArchiveTableDragSelection.rows(of: handedToTheTable, expanded: []),
            rowCount: 3, level: tableLevels)
        #expect((0..<3).map(selection.path(forRow:)) == [nil, "b", nil])
        let fromTheLiveModel = ArchiveTableDragSelection(
            draggedRows: IndexSet([1]), rows: ArchiveTableDragSelection.rows(of: live, expanded: []),
            rowCount: 3, level: tableLevels)
        #expect(fromTheLiveModel.path(forRow: 1) == "c")  // the wrong file the captured items avoid
    }
}
