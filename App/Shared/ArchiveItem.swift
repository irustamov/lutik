import Foundation
import KernirCore

/// Display row shared by the macOS Table and the iOS List.
struct ArchiveItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    /// Folders: total of descendant file sizes. nil = unknown.
    let size: Int64?
    let kind: String
    let modificationDate: Date?
    let isPendingAddition: Bool
    /// nil for files.
    var children: [ArchiveItem]?

    /// Sort key for the Size column; unknown sizes sort lowest.
    var sizeSortKey: Int64 { size ?? -1 }
    /// Sort key for the Date column; unknown dates sort oldest.
    var dateSortKey: Date { modificationDate ?? .distantPast }

    static func items(from nodes: [ArchiveNode], pendingPaths: Set<String>) -> [ArchiveItem] {
        nodes.map { node in
            let entry = node.entry
            return ArchiveItem(
                path: entry.path,
                name: entry.name,
                isDirectory: entry.isDirectory,
                size: entry.isDirectory ? node.totalSize : entry.size,
                kind: KernirFormat.kind(forName: entry.name, isDirectory: entry.isDirectory),
                modificationDate: entry.modificationDate,
                isPendingAddition: pendingPaths.contains(entry.path),
                children: node.children.map { items(from: $0, pendingPaths: pendingPaths) }
            )
        }
    }
}

extension Array where Element == ArchiveItem {
    /// Sorts every level recursively; folders always come before files and the
    /// comparators only order siblings of the same kind.
    func sorted(using comparators: [KeyPathComparator<ArchiveItem>]) -> [ArchiveItem] {
        // Not `sorted(using:)`: that would resolve to this method and recurse forever.
        func ordered(_ items: [ArchiveItem]) -> [ArchiveItem] {
            items.sorted { a, b in
                for comparator in comparators {
                    switch comparator.compare(a, b) {
                    case .orderedAscending: return true
                    case .orderedDescending: return false
                    case .orderedSame: continue
                    }
                }
                return false
            }
        }
        let folders = ordered(filter(\.isDirectory))
        let files = ordered(filter { !$0.isDirectory })
        return (folders + files).map { item in
            var copy = item
            copy.children = item.children?.sorted(using: comparators)
            return copy
        }
    }

    /// Keeps items whose name matches (case- and diacritic-insensitive). A matching
    /// folder keeps its full subtree unchanged; a non-matching folder is kept only
    /// as an ancestor of matches, with just the paths leading to them.
    func filtered(matching query: String) -> [ArchiveItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        return filteredItems(trimmed)
    }

    private func filteredItems(_ query: String) -> [ArchiveItem] {
        compactMap { item in
            if item.name.localizedStandardContains(query) { return item }
            guard let kept = item.children?.filteredItems(query), !kept.isEmpty else { return nil }
            var copy = item
            copy.children = kept
            return copy
        }
    }

    /// Ids of all folders, recursively (used to expand everything while searching).
    var directoryIDs: Set<String> {
        var ids = Set<String>()
        for item in self where item.isDirectory {
            ids.insert(item.id)
            ids.formUnion(item.children?.directoryIDs ?? [])
        }
        return ids
    }

    /// Depth-first list of every item, for lookup by id.
    func flattened() -> [ArchiveItem] {
        flatMap { [$0] + ($0.children?.flattened() ?? []) }
    }
}
