import Foundation
import KernirCore

/// What the Move To… sheet shows for one move: the archive's folders as a tree under a root row named after the
/// archive (the top level, path ""), and which of them the items can move into. Taken once, when the sheet
/// opens: while it is up `ArchiveActions.canMove` refuses everything (a sheet is attached), and the move asks
/// again once the sheet is gone.
struct MoveToFolders: Identifiable {
    /// Why a row is disabled, for its VoiceOver hint.
    enum DisabledReason: Hashable {
        /// The items are all in it already.
        case alreadyThere
        /// It is one of the moved folders, or beneath one.
        case intoItself
    }

    /// One row: a folder of the archive, or the root.
    struct Folder: Identifiable, Hashable {
        /// The folder's path in the archive; "" for the root.
        let id: String
        let name: String
        /// The items can move into it: not one of them, not inside one, not where they all already are, and
        /// whatever else `canMove` refuses.
        let isEnabled: Bool
        /// Why it is disabled, when that is one of the reasons the sheet can name; nil when it is enabled, and
        /// when `canMove` refuses it for something no folder changes (say, a name field showing).
        let disabledReason: DisabledReason?
        /// Its subfolders by name, Finder order; nil when it has none.
        let children: [Folder]?
    }

    /// The folder-dependent part of `canMove` for one move, taken once from its paths, so that asking it of
    /// every folder costs O(the folder's depth) each, not O(paths): the same answer as
    /// `MovePlanning.roots(paths, into: folder)` succeeding with something to move.
    struct Targets {
        /// The items that move: the given paths no other given path holds (`MovePlanning.topLevel`), in order.
        let moved: [String]
        /// The moved items' NFC keys, and the keys of the folders they are in now.
        private let movedKeys: Set<String>
        private let parentKeys: Set<String>

        init(paths: [String]) {
            moved = MovePlanning.topLevel(paths)
            let keys = moved.map(Self.key)
            movedKeys = Set(keys)
            parentKeys = Set(keys.map { ArchiveEntry.parentPath(of: $0) })
        }

        /// `folder` is one of the moved items (its subtree can't take them either).
        func isMoved(_ folder: String) -> Bool { movedKeys.contains(Self.key(folder)) }

        /// The items are all in `folder` ("" the top level) already.
        func isWhereTheyAre(_ folder: String) -> Bool { !moved.isEmpty && parentKeys == [Self.key(folder)] }

        /// The items can move into `folder` ("" the top level): it is no moved item nor beneath one, and they
        /// are not all in it already.
        func takes(_ folder: String) -> Bool {
            let target = Self.key(folder)
            var current = target
            while !current.isEmpty {
                if movedKeys.contains(current) { return false }
                current = ArchiveEntry.parentPath(of: current)
            }
            return !moved.isEmpty && !isWhereTheyAre(folder)
        }

        /// Paths compare after NFC, as in `MovePlanning`.
        private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }
    }

    /// Tells this sheet from the next one (`sheet(item:)`).
    let id = UUID()
    /// The items to move, as given.
    let paths: [String]
    /// The items that move: `paths` without those another one holds (`MovePlanning.topLevel`). Selecting
    /// "docs" and "docs/a.txt" moves one item, "docs".
    let movedItems: [String]
    let root: Folder
    /// The rows to show open: the root and every folder above a moved item, so the sheet opens on where the
    /// items are now (as Finder's does) and the folders next to them are in reach.
    let initiallyExpanded: Set<String>
    /// The row the sheet scrolls to as it opens: the folder the first moved item is in now ("" the root), the
    /// deepest of `initiallyExpanded` above it, so on a big archive that folder is on screen. Nil when nothing
    /// moves.
    let initialScrollTarget: String?

    /// How many items move (`movedItems`), for the sheet's wording.
    var movedCount: Int { movedItems.count }
    /// The name of the one item that moves; nil when more than one do.
    var singleMovedName: String? {
        movedItems.count == 1 ? movedItems.first.map { ArchiveEntry.name(of: $0) } : nil
    }

    /// `canMove(paths, folder)` answers for each folder (`ArchiveActions.canMove` outside tests), but for the
    /// moved items and the folders inside them: those are disabled without asking.
    init(paths: [String], items: [ArchiveItem], archiveName: String, canMove: ([String], String) -> Bool) {
        self.paths = paths
        let targets = Targets(paths: paths)
        movedItems = targets.moved
        func reason(_ folder: String, isEnabled: Bool, moved: Bool) -> DisabledReason? {
            if isEnabled { return nil }
            if moved { return .intoItself }
            return targets.isWhereTheyAre(folder) ? .alreadyThere : nil
        }
        func folders(_ items: [ArchiveItem], insideMoved: Bool) -> [Folder]? {
            let found = items.filter(\.isDirectory)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { item -> Folder in
                    let moved = insideMoved || targets.isMoved(item.path)
                    let isEnabled = !moved && canMove(paths, item.path)
                    return Folder(id: item.path, name: item.name, isEnabled: isEnabled,
                                  disabledReason: reason(item.path, isEnabled: isEnabled, moved: moved),
                                  children: folders(item.children ?? [], insideMoved: moved))
                }
            return found.isEmpty ? nil : found
        }
        let rootEnabled = canMove(paths, "")
        root = Folder(id: "", name: archiveName, isEnabled: rootEnabled,
                      disabledReason: reason("", isEnabled: rootEnabled, moved: false),
                      children: folders(items, insideMoved: false))
        var expanded: Set<String> = [""]
        for path in movedItems {
            var folder = ArchiveEntry.parentPath(of: path)
            while !folder.isEmpty, expanded.insert(folder).inserted {
                folder = ArchiveEntry.parentPath(of: folder)
            }
        }
        initiallyExpanded = expanded
        initialScrollTarget = movedItems.first.map { ArchiveEntry.parentPath(of: $0) }
    }

    /// Some folder of `items`, or the top level, takes `paths`: `hasTarget` of the sheet's tree without building
    /// it. Stops at the first such folder, and never walks into a moved item.
    static func hasTarget(paths: [String], items: [ArchiveItem], canMove: ([String], String) -> Bool) -> Bool {
        let targets = Targets(paths: paths)
        func any(_ items: [ArchiveItem]) -> Bool {
            items.contains { item in
                item.isDirectory && !targets.isMoved(item.path)
                    && (canMove(paths, item.path) || any(item.children ?? []))
            }
        }
        return canMove(paths, "") || any(items)
    }

    /// Whether `path` is a row the items can move into.
    func isEnabled(_ path: String) -> Bool { folder(at: path)?.isEnabled ?? false }

    /// Why the row at `path` is disabled (`Folder.disabledReason`); nil for no such row.
    func disabledReason(_ path: String) -> DisabledReason? { folder(at: path)?.disabledReason }

    /// The row at `path`, "" the root.
    private func folder(at path: String) -> Folder? {
        func find(_ folder: Folder) -> Folder? {
            if folder.id == path { return folder }
            return folder.children?.lazy.compactMap(find).first
        }
        return find(root)
    }

    /// Some row takes the items: Move To… is worth offering.
    var hasTarget: Bool {
        func any(_ folder: Folder) -> Bool { folder.isEnabled || (folder.children ?? []).contains(where: any) }
        return any(root)
    }
}
