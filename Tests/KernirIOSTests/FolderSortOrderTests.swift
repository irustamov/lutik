import Foundation
import SwiftUI
import Testing
import KernirCore
@testable import Kernir

/// More > Sort By: the order of a folder list's rows, and how it is kept in the defaults.
struct FolderSortOrderTests {
    private static func file(_ name: String, size: Int64? = nil, date: TimeInterval? = nil,
                             kind: String = "Document", path: String? = nil) -> ArchiveItem {
        ArchiveItem(path: path ?? name, name: name, isDirectory: false, size: size, kind: kind,
                    modificationDate: date.map(Date.init(timeIntervalSince1970:)), isPendingAddition: false,
                    children: nil)
    }

    private static func folder(_ name: String, objects: Int = 0, size: Int64? = nil,
                               date: TimeInterval? = nil) -> ArchiveItem {
        let children = (0..<objects).map { file("f\($0)", path: "\(name)/f\($0)") }
        return ArchiveItem(path: name, name: name, isDirectory: true, size: size, kind: "Folder",
                           modificationDate: date.map(Date.init(timeIntervalSince1970:)), isPendingAddition: false,
                           children: children)
    }

    private static func names(_ order: FolderSortOrder, _ items: [ArchiveItem]) -> [String] {
        order.sorted(items).map(\.name)
    }

    @Test func defaultIsNameAscending() {
        #expect(FolderSortOrder.default == FolderSortOrder(key: .name, ascending: true))
    }

    /// Finder's order, as the list had before it could be sorted: folders first, then names as Finder
    /// compares them ("file2" before "file10"), names it finds equal by path bytes, as `ArchiveModel`
    /// orders them.
    @Test func nameAscendingIsFinderOrderWithFoldersFirst() {
        let items = [Self.file("file10"), Self.folder("zeta"), Self.file("file2"), Self.folder("alpha"),
                     Self.file("twin", path: "p-2"), Self.file("twin", path: "p-1")]
        #expect(FolderSortOrder.default.sorted(items).map(\.path) == ["alpha", "zeta", "file2", "file10", "p-1", "p-2"])
    }

    @Test func nameDescendingReversesWithinFoldersAndFiles() {
        let items = [Self.file("file2"), Self.folder("zeta"), Self.file("file10"), Self.folder("alpha")]
        #expect(Self.names(FolderSortOrder(key: .name, ascending: false), items) == ["zeta", "alpha", "file10", "file2"])
    }

    /// Unknown dates count as the oldest; equal dates go by name.
    @Test func dateSortsByModificationDate() {
        let items = [Self.file("new", date: 300), Self.file("unknown"), Self.file("old", date: 100),
                     Self.file("b-mid", date: 200), Self.file("a-mid", date: 200), Self.folder("dir", date: 50)]
        #expect(Self.names(FolderSortOrder(key: .date, ascending: true), items)
                == ["dir", "unknown", "old", "a-mid", "b-mid", "new"])
        #expect(Self.names(FolderSortOrder(key: .date, ascending: false), items)
                == ["dir", "new", "a-mid", "b-mid", "old", "unknown"])
    }

    /// Files by size (unknown lowest); folders by what their row shows, the number of objects in them.
    @Test func sizeSortsFilesBySizeAndFoldersByObjectCount() {
        let items = [Self.file("big", size: 3000), Self.file("unknown"), Self.file("small", size: 10),
                     Self.folder("many", objects: 3, size: 1), Self.folder("few", objects: 1, size: 9000)]
        #expect(Self.names(FolderSortOrder(key: .size, ascending: true), items)
                == ["few", "many", "unknown", "small", "big"])
        #expect(Self.names(FolderSortOrder(key: .size, ascending: false), items)
                == ["many", "few", "big", "small", "unknown"])
    }

    /// The Kind the Mac's column shows (`ArchiveItem.kind`); one kind goes by name.
    @Test func kindSortsByKindThenName() {
        let items = [Self.file("b.png", kind: "PNG image"), Self.file("z.txt", kind: "Plain Text"),
                     Self.file("a.png", kind: "PNG image"), Self.file("c.zip", kind: "ZIP archive")]
        #expect(Self.names(FolderSortOrder(key: .kind, ascending: true), items)
                == ["z.txt", "a.png", "b.png", "c.zip"])
        #expect(Self.names(FolderSortOrder(key: .kind, ascending: false), items)
                == ["c.zip", "a.png", "b.png", "z.txt"])
    }

    /// Equal names in descending order: the path tie-break stays ascending, as the model's.
    @Test func nameDescendingKeepsPathTieBreakAscending() {
        let items = [Self.file("twin", path: "p-2"), Self.file("a"), Self.file("twin", path: "p-1")]
        #expect(FolderSortOrder(key: .name, ascending: false).sorted(items).map(\.path) == ["p-1", "p-2", "a"])
    }

    /// Folders that tie on date or size go by name, in either direction.
    @Test func foldersTiedOnDateOrSizeFallBackToName() {
        let dates = [Self.folder("b", date: 10), Self.folder("a", date: 10), Self.folder("c", date: 5)]
        #expect(Self.names(FolderSortOrder(key: .date, ascending: true), dates) == ["c", "a", "b"])
        #expect(Self.names(FolderSortOrder(key: .date, ascending: false), dates) == ["a", "b", "c"])
        let sizes = [Self.folder("b", objects: 2), Self.folder("a", objects: 2), Self.folder("c", objects: 1)]
        #expect(Self.names(FolderSortOrder(key: .size, ascending: true), sizes) == ["c", "a", "b"])
        #expect(Self.names(FolderSortOrder(key: .size, ascending: false), sizes) == ["a", "b", "c"])
    }

    private static func entry(_ path: String, isDirectory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: isDirectory, size: isDirectory ? nil : 1,
                     compressedSize: isDirectory ? nil : 1, modificationDate: nil)
    }

    private static let mixedEntries = [
        entry("zeta", isDirectory: true), entry("alpha", isDirectory: true), entry("alpha/file10"),
        entry("alpha/File2"), entry("alpha/file2"), entry("file10"), entry("file2"), entry("a"), entry("A"),
        entry("B"), entry("\u{E9}"), entry("e\u{301}"), entry("Zed.txt"), entry("zeta/b"), entry("zeta/a"),
    ]

    /// The default order is the model's own, so the list can skip sorting for it: the sort changes
    /// nothing on every level of a mixed tree (folders, "file2" / "file10", "a" / "A"). The NFC / NFD pair
    /// ("\u{E9}" / "e\u{301}") stays among the entries, but the model merges it into one item.
    @MainActor @Test func defaultOrderEqualsTheModelsOrder() {
        let model = ArchiveModel(reader: FakeReader(entries: Self.mixedEntries), undoManager: nil)
        func check(_ level: [ArchiveItem]) {
            #expect(FolderSortOrder.default.sorted(level).map(\.path) == level.map(\.path))
            for item in level { check(item.children ?? []) }
        }
        #expect(!model.items.isEmpty)
        check(model.items)
    }

    /// The list's cache: the default order returns the model's level as is; another sorts it once and
    /// keeps the result until the order, level, search or the model's items change.
    @MainActor @Test func levelCacheFollowsOrderSearchAndEdits() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let model = ArchiveModel(reader: FakeReader(entries: Self.mixedEntries), undoManager: undoManager)
        let cache = SortedLevelCache()
        let byNameDescending = FolderSortOrder(key: .name, ascending: false)
        #expect(cache.rows(of: model, path: "", searchText: "", order: .default).map(\.path)
                == model.items.map(\.path))
        let descending = cache.rows(of: model, path: "", searchText: "", order: byNameDescending).map(\.path)
        #expect(descending == byNameDescending.sorted(model.items).map(\.path))
        #expect(cache.rows(of: model, path: "", searchText: "", order: byNameDescending).map(\.path) == descending)
        let inAlpha = cache.rows(of: model, path: "alpha", searchText: "", order: byNameDescending)
        // The cache hands out the order's own rows for that level. "File2" / "file2" sit among the names, so
        // where they land relative to "file10" is the platform's compare; "file10" and "file2" (one case)
        // are Finder's numeric order, reversed here.
        #expect(inAlpha.map(\.path) == byNameDescending.sorted(model.children(of: "alpha")).map(\.path))
        let alphaNames = inAlpha.map(\.name)
        #expect(alphaNames.count == 3 && Set(alphaNames) == ["file10", "File2", "file2"])
        #expect((alphaNames.firstIndex(of: "file10") ?? .max) < (alphaNames.firstIndex(of: "file2") ?? .min))
        #expect(cache.rows(of: model, path: "", searchText: "zeta", order: .default).map(\.path) == ["zeta"])
        // An edit rebuilds the items: the next call shows it.
        let before = model.itemsRevision
        undoManager.beginUndoGrouping()
        model.remove(["B"])
        undoManager.endUndoGrouping()
        #expect(model.itemsRevision != before)
        let after = cache.rows(of: model, path: "", searchText: "", order: byNameDescending).map(\.path)
        #expect(after.count == descending.count - 1 && !after.contains("B"))
        // Undo rebuilds them again.
        #expect(undoManager.canUndo)
        undoManager.undo()
        let undone = cache.rows(of: model, path: "", searchText: "", order: byNameDescending).map(\.path)
        #expect(undone == descending)
        // Another model at the same revision, path, search and order gets its own rows.
        let first = ArchiveModel(reader: FakeReader(entries: [Self.entry("one.txt")]), undoManager: nil)
        let second = ArchiveModel(reader: FakeReader(entries: [Self.entry("two.txt")]), undoManager: nil)
        #expect(first.itemsRevision == second.itemsRevision)
        let twins = SortedLevelCache()
        #expect(twins.rows(of: first, path: "", searchText: "", order: byNameDescending).map(\.path) == ["one.txt"])
        #expect(twins.rows(of: second, path: "", searchText: "", order: byNameDescending).map(\.path) == ["two.txt"])
        #expect(twins.rows(of: first, path: "", searchText: "", order: byNameDescending).map(\.path) == ["one.txt"])
    }

    @Test(arguments: FolderSortOrder.Key.allCases, [true, false])
    func rawValueRoundTrips(key: FolderSortOrder.Key, ascending: Bool) {
        let order = FolderSortOrder(key: key, ascending: ascending)
        #expect(FolderSortOrder(rawValue: order.rawValue) == order)
    }

    @Test(arguments: ["", "name", "name.up", "colour.ascending", "name.ascending.extra"])
    func unknownRawValueIsRefused(raw: String) {
        #expect(FolderSortOrder(rawValue: raw) == nil)
    }

    /// The list's `@AppStorage` reads what an earlier launch stored, and falls back to the default
    /// for nothing or a value it doesn't know.
    @Test func appStorageKeepsTheOrderAcrossLaunches() {
        let (defaults, suite) = makeTestDefaults("FolderSortOrderTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        func stored() -> FolderSortOrder {
            AppStorage(wrappedValue: FolderSortOrder.default, FolderSortOrder.defaultsKey, store: defaults).wrappedValue
        }
        #expect(stored() == .default)
        let chosen = FolderSortOrder(key: .size, ascending: false)
        defaults.set(chosen.rawValue, forKey: FolderSortOrder.defaultsKey)
        #expect(stored() == chosen)
        defaults.set("colour.ascending", forKey: FolderSortOrder.defaultsKey)
        #expect(stored() == .default)
    }
}
