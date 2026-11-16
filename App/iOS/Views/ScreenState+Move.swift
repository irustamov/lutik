import Foundation
import SwiftUI
import UniformTypeIdentifiers
import KernirCore

// In-archive move: a row dragged onto a folder row or a level's list, and Move… (row
// context menu, Select mode's bottom bar) with its folder sheet. Both end in `move(_:into:)`, which asks
// Add's Replace question for same-named items first, then calls `ArchiveModel.move(_:into:)`: one undo step
// "Move", the replaced items removed inside it.

/// The Move sheet: the items it moves.
struct MoveRequest: Identifiable {
    let id = UUID()
    var paths: [String]
}

/// One folder of the Move sheet's list; `children` nil when it holds no folders.
struct MoveFolder: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    var children: [MoveFolder]?
}

/// What reaches the model: `ArchiveModel`'s own, or a test's.
struct MoveOperations {
    var conflicts: @MainActor (ArchiveModel, [String], String) -> [String]
    var move: @MainActor (ArchiveModel, [String], String) -> Result<[String: String], MoveProblem>

    static let model = MoveOperations(
        conflicts: { model, paths, folder in model.conflicts(moving: paths, into: folder) },
        move: { model, paths, folder in model.move(paths, into: folder) })
}

extension ScreenState {
    /// Whether `folder` takes `paths`: not one of them nor beneath one, and not where all of them are
    /// already (`MovePlanning.roots`). Folders only; "" is the top level.
    nonisolated static func isMoveTarget(_ folder: String, for paths: [String]) -> Bool {
        guard case .success(let roots) = MovePlanning.roots(paths, into: folder) else { return false }
        return !roots.isEmpty
    }

    /// `paths` can move into `folder` now: edits are allowed where ＋ adds (`canAdd`), `folder` is the top
    /// level or a listed folder, and it takes them (`isMoveTarget`). Paths no longer listed (the archive
    /// was reopened or reverted since they were picked) don't move.
    func canMove(_ paths: [String], into folder: String) -> Bool {
        guard canAdd, let model, !paths.isEmpty, paths.allSatisfy({ model.item(at: $0) != nil }) else { return false }
        guard folder.isEmpty || model.item(at: folder)?.isDirectory == true else { return false }
        return Self.isMoveTarget(folder, for: paths)
    }

    /// Moves `paths` into `folder` (one undo step "Move"), after Add's Replace question when the folder
    /// holds items of the same names (a folder replaces a folder: no merge). Moved rows leave the
    /// selection (they left this level); Select mode ends with its last selected row, as after Delete.
    /// A save or a reopen running now: nothing moves, and the user is told.
    func move(_ paths: [String], into folder: String) {
        guard canEdit, pendingExtraction == nil, let model, !paths.isEmpty else { return }
        guard !isBusy else {
            alert = AlertContent(title: moveFailureTitle(paths), message: busyMessage)
            return
        }
        guard canMove(paths, into: folder) else { return }
        let conflicts = moveOperations.conflicts(model, paths, folder)
        if conflicts.isEmpty {
            performMove(paths, into: folder)
        } else {
            pendingReplacement = PendingReplacement(urls: [], directory: folder, conflicts: conflicts, moving: paths)
        }
    }

    /// The model's move, after any Replace question. Internal for `confirmReplacement`.
    func performMove(_ paths: [String], into folder: String) {
        guard canEdit, pendingExtraction == nil, let model else { return }
        guard !isBusy else {
            alert = AlertContent(title: moveFailureTitle(paths), message: busyMessage)
            return
        }
        switch moveOperations.move(model, paths, folder) {
        case .success(let moves):
            guard !moves.isEmpty else { return }
            let moved = Set(moves.keys)
            let hadSelection = !selection.isEmpty
            selection = selection.filter { model.item(at: $0) != nil && !ArchiveModel.isCovered($0, by: moved) }
            if isSelecting, hadSelection, selection.isEmpty { isSelecting = false }
            dropSharesOfRemovedRows()
        case .failure(.taken(let name)) where isTakenByHiddenEntry(name, moving: paths, into: folder):
            alert = AlertContent(title: moveFailureTitle(paths),
                                 message: String(localized: "There is already an item named “\(name)” there.",
                                                 comment: "Alert message under “Couldn't move …” when a hidden item of the archive (Finder metadata, say) already has that name in the folder the items were moved to. %@ = that name."))
        case .failure(let problem):
            // Gone meanwhile, a deleted folder's name (`.holdsMovedOutItems`), a target the UI never offers, or
            // `.taken` by two moved items with one name or by a replaced item that holds a moved one.
            alert = AlertContent(title: moveFailureTitle(paths), message: MovePlanning.message(for: problem))
        }
    }

    /// The model's `.taken(name)` for moving `paths` into `folder` is a plain collision with an item already
    /// there that the list doesn't show: no two moved items have that name, and no visible item there does
    /// (one would have been asked about, unless replacing it would take a moved item along).
    private func isTakenByHiddenEntry(_ name: String, moving paths: [String], into folder: String) -> Bool {
        guard let model else { return false }
        let key = name.precomposedStringWithCanonicalMapping
        let named = MovePlanning.topLevel(paths).filter {
            ArchiveEntry.name(of: $0).precomposedStringWithCanonicalMapping == key
        }
        guard named.count < 2 else { return false }
        return model.item(at: folder.isEmpty ? name : folder + "/" + name) == nil
    }

    private func moveFailureTitle(_ paths: [String]) -> String {
        if paths.count == 1 {
            String(localized: "Couldn't move “\((paths[0] as NSString).lastPathComponent)”",
                   comment: "Alert title when moving an item to another folder of the archive fails; the reason is shown below it. %@ = the item's name.")
        } else {
            String(localized: "Couldn't move \(paths.count) items",
                   comment: "Alert title when moving several items to another folder of the archive fails; the reason is shown below it. %lld = number of items. In languages whose “one” form also covers 21, 31…, it must keep %lld.")
        }
    }

    // MARK: - The Move sheet

    /// Select mode's Move…: the topmost selected rows.
    func moveTargets() -> [String] {
        isSelecting ? Self.topmost(selection) : []
    }

    var canMoveSelection: Bool { canAdd && isSelecting && !selection.isEmpty }

    /// Move…: the folder sheet for `paths`, while edits are allowed.
    func beginMove(_ paths: [String]) {
        guard canAdd, let model, !paths.isEmpty, paths.allSatisfy({ model.item(at: $0) != nil }) else { return }
        confirmedMove = nil
        moveRequest = MoveRequest(paths: paths)
    }

    /// Move Here: the sheet goes, then `moveSheetDidDismiss` moves.
    func confirmMove(into folder: String) {
        guard let request = moveRequest else { return }
        confirmedMove = (request.paths, folder)
        moveRequest = nil
    }

    /// Cancel, or the sheet swiped down.
    func cancelMove() {
        moveRequest = nil
    }

    /// The document's content goes (the document view controller's `removeContent`): the Move sheet, a
    /// confirmed move waiting for it to go, a Replace question for a move (up, or about to be asked again)
    /// and the rows remembered from drags all go, so none of them acts after the close.
    func cancelPendingMove() {
        replacementAskedAgain?.cancel()
        replacementAskedAgain = nil
        moveRequest = nil
        confirmedMove = nil
        if let pending = pendingReplacement, !pending.moving.isEmpty { pendingReplacement = nil }
        draggedRows = [:]
        draggedRowOrder = []
    }

    /// The sheet has gone (`FolderScreen`): a confirmed move runs now, so its Replace question can come up.
    func moveSheetDidDismiss() {
        guard let confirmed = confirmedMove else { return }
        confirmedMove = nil
        move(confirmed.paths, into: confirmed.folder)
    }

    /// The archive's folders, nested, in the order the levels list them.
    func moveFolders() -> [MoveFolder] {
        guard let model else { return [] }
        func folders(in path: String) -> [MoveFolder]? {
            let children = model.children(of: path).filter(\.isDirectory).map {
                MoveFolder(path: $0.path, name: $0.name, children: folders(in: $0.path))
            }
            return children.isEmpty ? nil : children
        }
        return folders(in: "") ?? []
    }

    // MARK: - Drag and drop

    /// The start of each dragged row's own marker type; the rest is a fresh UUID (`draggedRows`).
    nonisolated var dragItemMarkerPrefix: String { dragMarkerType + ".item." }

    /// A fresh marker type for a row at `path` dragged out now. Only the last `Self.draggedRowsKept` rows
    /// dragged are remembered (more than any one drag carries: an older row's drop would be refused); a drop
    /// on this document forgets its own, moved or not (`performMoveDrop`). A drag abandoned or dropped
    /// elsewhere stays until the cap drops it: SwiftUI's `onDrag` reports no end.
    func registerDraggedRow(_ path: String) -> String {
        let type = dragItemMarkerPrefix + UUID().uuidString
        draggedRows[type] = path
        draggedRowOrder.append(type)
        if draggedRowOrder.count > Self.draggedRowsKept {
            for old in draggedRowOrder.prefix(draggedRowOrder.count - Self.draggedRowsKept) { draggedRows[old] = nil }
            draggedRowOrder.removeFirst(draggedRowOrder.count - Self.draggedRowsKept)
        }
        return type
    }

    nonisolated static let draggedRowsKept = 256

    private func forgetDraggedRows(_ providers: [NSItemProvider]) {
        let types = Set(providers.flatMap(\.registeredTypeIdentifiers).filter { $0.hasPrefix(dragItemMarkerPrefix) })
        for type in types { draggedRows[type] = nil }
        draggedRowOrder.removeAll { types.contains($0) }
    }

    /// The paths of `providers` when every one is a row dragged out of this document; else nil.
    func draggedPaths(_ providers: [NSItemProvider]) -> [String]? {
        guard !providers.isEmpty else { return nil }
        var paths: [String] = []
        for provider in providers {
            guard let path = provider.registeredTypeIdentifiers.lazy
                .filter({ $0.hasPrefix(self.dragItemMarkerPrefix) })
                .compactMap({ self.draggedRows[$0] }).first else { return nil }
            paths.append(path)
        }
        return paths
    }

    /// The rows of this document a drag without item providers (while it hovers) carries, by their item
    /// markers' types (`conforms`: the drop's `hasItemsConforming(to:)`); nil when it carries none.
    /// `performMoveDrop` checks again with the providers.
    func hoveringDraggedPaths(_ conforms: ([UTType]) -> Bool) -> [String]? {
        let paths = draggedRowOrder.compactMap { type in
            conforms([UTType(importedAs: type)]) ? draggedRows[type] : nil
        }
        return paths.isEmpty ? nil : paths
    }

    /// The drop of this document's rows on `folder` (`FolderDropDelegate`): true when it moves them.
    /// Its rows are forgotten either way: the drag has ended (the one end SwiftUI reports).
    func performMoveDrop(_ providers: [NSItemProvider], into folder: String) -> Bool {
        guard let paths = draggedPaths(providers) else { return false }
        forgetDraggedRows(providers)
        guard canMove(paths, into: folder) else { return false }
        move(paths, into: folder)
        return true
    }
}
