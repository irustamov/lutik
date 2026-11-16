import Foundation

/// The archive paths one drag out of the table brings, by row. AppKit drags every selected row (or,
/// for a drag that starts outside the selection, that row alone) and asks for each one's pasteboard
/// writer by row; a row brings the path the table shows there, read against the dragged rows. The
/// rows come from the items this table was handed (`rows(of:expanded:)`), never from the window's
/// live model, which may be ahead of the table (a rename landed, the table not reloaded yet), and
/// never from the window's selection binding: on a click-drag AppKit may start the drag before that
/// has caught up with the click. Made once per drag: the rows are worked out once, not once per
/// row, and the drag gets one drop id.
struct ArchiveTableDragSelection {
    /// One row of the table: its archive path and its outline level (0 at the top).
    struct Row: Equatable {
        let path: String
        let level: Int
    }

    /// This drag's drop: every row's promise is tagged with it, so a Cancel stops the rows of this
    /// drop only (`ArchiveFilePromiseDrop`).
    let dropID = UUID()
    /// The dragged rows: the table's selected rows, or the one row a drag starting outside them brings.
    let draggedRows: IndexSet
    /// The table's rows top to bottom, or [] when they don't match the table.
    let rows: [Row]
    private let selectedPaths: Set<String>

    /// `rows` as worked out from the table's items, `rowCount` and `level` (by row) as the table has
    /// them: when the counts differ, or a selected row is at another level in the table (a table not
    /// caught up with its items), no row brings anything rather than the wrong file.
    init(draggedRows: IndexSet, rows: [Row], rowCount: Int, level: (Int) -> Int) {
        self.draggedRows = draggedRows
        let matches = rows.count == rowCount
            && draggedRows.allSatisfy { !rows.indices.contains($0) || level($0) == rows[$0].level }
        let rows = matches ? rows : []
        self.rows = rows
        selectedPaths = Set(draggedRows.filter { rows.indices.contains($0) }.map { rows[$0].path })
    }

    /// The path `row` brings, or nil: a row outside the dragged rows; any row when a selected row is
    /// past the rows; a row inside another selected folder (the folder brings it).
    func path(forRow row: Int) -> String? {
        guard draggedRows.contains(row), let last = draggedRows.last, rows.indices.contains(last),
              rows.indices.contains(row) else { return nil }
        let path = rows[row].path
        return ArchiveModel.isCovered(ArchiveModel.parentPath(of: path), by: selectedPaths) ? nil : path
    }

    /// The drag's rows for `items` and `expanded` as they are now, taken together: the
    /// table view hands both over in the same pass as it hands the Table its items. A folder opened
    /// or closed later (a main-actor job landing before the next redraw) reaches the rows only with
    /// the redraw that shows it, never ahead of the outline.
    static func rowsTaken(of items: [ArchiveItem], expanded: Set<String>) -> @MainActor () -> [Row] {
        { rows(of: items, expanded: expanded) }
    }

    /// The rows the Table shows for `items` (`ArchiveTableRows`): each item, and under an open
    /// folder (`expanded`) its children one level down; a closed folder's stay out, at any depth.
    static func rows(of items: [ArchiveItem], expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func append(_ items: [ArchiveItem], level: Int) {
            for item in items {
                rows.append(Row(path: item.path, level: level))
                if let children = item.children, expanded.contains(item.id) { append(children, level: level + 1) }
            }
        }
        append(items, level: 0)
        return rows
    }
}
