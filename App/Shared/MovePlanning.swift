import Foundation
import KernirCore

/// Why a move inside the archive (`ArchiveModel.move(_:into:)`) is refused.
enum MoveProblem: Error, Equatable, Sendable {
    /// An item is gone, or the archive can't be edited.
    case unavailable
    /// The target is not a visible folder ("" = the top level always is one).
    case notAFolder
    /// The target is a moved item or beneath one.
    case intoItself
    /// Two moved items share a name (NFC), or a hidden kept source entry holds it in the target.
    case taken(String)
    /// Until a save, items moved out of a deleted folder named so can't go back to that name: a rename or move
    /// (or a Delete) would put one at or beneath the deleted folder's path, where the writer drops it.
    case holdsMovedOutItems(String)
}

/// Pure planning for a move inside the archive, on visible paths. Paths split on the "/" scalar (as
/// `ArchiveModel.remap`), never on Characters, and compare after NFC.
enum MovePlanning {
    /// Drops paths beneath another given path (the ancestor moves), refuses when `folder` is a given path or
    /// beneath one, drops items already in `folder` (no-op). [] = nothing to do. In the given order.
    static func roots(_ paths: [String], into folder: String) -> Result<[String], MoveProblem> {
        let top = topLevel(paths)
        let target = nfc(folder)
        let keys = Set(top.map(nfc))
        var current = target
        while !current.isEmpty {
            if keys.contains(current) { return .failure(.intoItself) }
            current = ArchiveEntry.parentPath(of: current)
        }
        return .success(top.filter { ArchiveEntry.parentPath(of: nfc($0)) != target })
    }

    /// The given paths that no other given path holds, each once (its first spelling), in the given order:
    /// what ends up directly in the target folder, movers and items already there alike.
    static func topLevel(_ paths: [String]) -> [String] {
        let keys = Set(paths.map(nfc))
        var seen = Set<String>()
        return paths.filter { path in
            let key = nfc(path)
            guard seen.insert(key).inserted else { return false }
            var ancestor = ArchiveEntry.parentPath(of: key)
            while !ancestor.isEmpty {
                if keys.contains(ancestor) { return false }
                ancestor = ArchiveEntry.parentPath(of: ancestor)
            }
            return true
        }
    }

    static func message(for problem: MoveProblem) -> String {
        switch problem {
        case .intoItself:
            String(localized: "An item can’t be moved into itself.", table: "Shared",
                   comment: "Error when moving items inside the archive: the target folder is one of the moved items or inside one.")
        case .taken(let name):
            String(localized: "More than one item named “\(name)” would be moved into this folder.", table: "Shared",
                   comment: "Error when moving items inside the archive: two of them, or one and a hidden entry of the archive, would share a name in the target folder. %@ = the name.")
        case .holdsMovedOutItems(let name):
            String(localized: "“\(name)” can’t be used until you save, because items were moved out of a deleted folder with that name.", table: "Shared",
                   comment: "Error when moving items inside the archive (or deleting some) would put an item moved out of a deleted folder back at that folder's path: the user saves the archive first. %@ = the deleted folder's name.")
        case .unavailable, .notAFolder:
            String(localized: "These items can’t be moved.", table: "Shared",
                   comment: "Error when moving items inside the archive: an item is gone, the target is not a folder, or the archive can't be edited.")
        }
    }

    /// Byte keys would split NFC and NFD; String's `==` already folds them, NFC makes Set and the scalar walk agree.
    private static func nfc(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }
}
