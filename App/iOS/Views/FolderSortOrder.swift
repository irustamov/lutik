import Foundation
import SwiftUI

/// How folder lists order their rows: More > Sort By. One choice for every level and every archive,
/// kept across launches in the app's defaults (`defaultsKey`, through `@AppStorage`).
struct FolderSortOrder: Equatable, Sendable, RawRepresentable {
    /// The Mac table's columns.
    enum Key: String, CaseIterable, Sendable {
        case name, date, size, kind

        var title: String {
            switch self {
            case .name:
                String(localized: "Name", comment: "Placeholder of the text field in the Rename and New Folder alerts, where the item's new name is typed. Also a choice in More > Sort By: order the list by name.")
            case .date:
                String(localized: "Date Modified", comment: "A choice in More > Sort By: order the list by the items' modification dates.")
            case .size:
                String(localized: "Size", comment: "A choice in More > Sort By: order the list by size. Files go by their size; folders by the number of objects in them (the count their row shows), not by the total size of their contents as on the Mac.")
            case .kind:
                String(localized: "Kind", comment: "A choice in More > Sort By: order the list by the items' kinds (PNG image, Folder…).")
            }
        }
    }

    static let defaultsKey = "KernirFolderSortOrder"
    /// Finder's order, the list's only one before it could be sorted.
    static let `default` = FolderSortOrder(key: .name, ascending: true)

    var key: Key
    var ascending: Bool

    init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// "name.ascending", "size.descending"…
    init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let key = Key(rawValue: String(parts[0])) else { return nil }
        switch parts[1] {
        case "ascending": self.init(key: key, ascending: true)
        case "descending": self.init(key: key, ascending: false)
        default: return nil
        }
    }

    var rawValue: String {
        "\(key.rawValue).\(ascending ? "ascending" : "descending")"
    }

    /// One level's rows (not their children): folders first, as on the Mac and in the list before it
    /// could be sorted, then by `key` in the chosen direction. Rows that `key` finds equal go by name
    /// (Finder's way), then by path bytes, the way `ArchiveModel` orders equal names.
    func sorted(_ items: [ArchiveItem]) -> [ArchiveItem] {
        items.sorted(by: areInIncreasingOrder)
    }

    func areInIncreasingOrder(_ a: ArchiveItem, _ b: ArchiveItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let primary = compare(a, b, by: key)
        if primary != .orderedSame {
            return (primary == .orderedAscending) == ascending
        }
        if key != .name {
            let byName = compare(a, b, by: .name)
            if byName != .orderedSame { return byName == .orderedAscending }
        }
        return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
    }

    private func compare(_ a: ArchiveItem, _ b: ArchiveItem, by key: Key) -> ComparisonResult {
        switch key {
        case .name: a.name.localizedStandardCompare(b.name)
        case .date: Self.compare(a.dateSortKey, b.dateSortKey)
        case .size: Self.compare(Self.sizeKey(a), Self.sizeKey(b))
        case .kind: a.kind.localizedStandardCompare(b.kind)
        }
    }

    /// What the row shows: a folder's number of objects, a file's size (unknown lowest). The Mac sorts
    /// folders by their total size; here the order follows the row's text, so it always looks sorted.
    private static func sizeKey(_ item: ArchiveItem) -> Int64 {
        item.isDirectory ? Int64(item.children?.count ?? 0) : item.sizeSortKey
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (b < a ? .orderedDescending : .orderedSame)
    }
}

/// A folder level's sorted rows, kept until what they come from changes, so a body rebuild that doesn't
/// change them (a selection tap, say) doesn't sort again. Held in `@State` and not observed: filling it
/// inside `body` changes no view state. It holds the model weakly and compares it by identity: an
/// `ObjectIdentifier` of a freed model can be reused by a fresh one, which starts at the same revision.
@MainActor final class SortedLevelCache {
    private struct Key: Equatable {
        var revision: Int
        var path: String
        var searchText: String
        var order: FolderSortOrder
    }

    private weak var model: ArchiveModel?
    private var key: Key?
    private var rows: [ArchiveItem] = []

    /// `path`'s children matching `searchText`, in `order`. The default order is the model's own
    /// (`ArchiveModel.items`: folders first, Finder's name order, equal names by path), so nothing sorts.
    func rows(of model: ArchiveModel, path: String, searchText: String, order: FolderSortOrder) -> [ArchiveItem] {
        let key = Key(revision: model.itemsRevision, path: path, searchText: searchText, order: order)
        if model === self.model, key == self.key { return rows }
        let level = model.children(of: path, matching: searchText)
        rows = order == .default ? level : order.sorted(level)
        self.model = model
        self.key = key
        return rows
    }
}

/// More > Sort By: the key, then the direction, each a list of choices with a checkmark (as in Files).
struct FolderSortMenu: View {
    @Binding var order: FolderSortOrder

    var body: some View {
        Menu("Sort By", systemImage: "arrow.up.arrow.down") {
            Picker("Sort By", selection: $order.key) {
                ForEach(FolderSortOrder.Key.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Picker("Sort Order", selection: $order.ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
