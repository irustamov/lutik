import Observation
import UIKit

/// Undo, Redo and Save for one folder level: the navigation item's pinned trailing group, the
/// only group that never moves into the overflow menu. On iPhone a long title or subtitle (such
/// as "1 item · 15 bytes uncompressed") pushed UIDocumentViewController's undo/redo group and
/// SwiftUI's `.confirmationAction` item into "More". Undo and Redo show while the archive can be
/// edited (`ScreenState.showsUndoRedo`), enabled from `canUndo` / `canRedo`; Save joins them
/// while there are unsaved edits and is disabled while saving. Read-only archives show nothing.
///
/// On iOS 26 the three share one glass capsule and Save loses its own prominent capsule: UIKit
/// ignores `sharesBackground` / `hidesSharedBackground` in a group of several items, and a fixed
/// space only widens the gap. Save pinned alone with Undo/Redo as a trailing group gives the
/// separate capsule, but at the root with the long subtitle Undo and Redo then go into "More".
/// So Save's text takes the accent tint inside the shared capsule to stay the primary action.
@MainActor final class TrailingEditItems {
    private weak var state: ScreenState?
    private weak var navigationItem: UINavigationItem?
    private let undo: UIBarButtonItem
    private let redo: UIBarButtonItem
    private let save: UIBarButtonItem
    /// The group this level pins, nil while it shows nothing. Rebuilt when its items change.
    private var group: UIBarButtonItemGroup?

    init(state: ScreenState, navigationItem: UINavigationItem) {
        self.state = state
        self.navigationItem = navigationItem
        undo = Self.item(String(localized: "Undo",
                                           comment: "Toolbar button that takes back the last edit to the archive. Verb. Pairs with Redo."),
                         image: "arrow.uturn.backward") { [weak state] in state?.undo() }
        redo = Self.item(String(localized: "Redo",
                                           comment: "Toolbar button that repeats the edit that was just undone. Verb. Pairs with Undo."),
                         image: "arrow.uturn.forward") { [weak state] in state?.redo() }
        let saveTitle = String(localized: "Save",
                                          comment: "Save the changes made to the archive: the Save menu command (⌘S), the trailing toolbar button and the confirm button of the save options sheet in Save a Copy. Verb.")
        let saveAction = UIAction(title: saveTitle) { [weak state] _ in
            Task { await state?.save() }
        }
        // The title shows as text: iOS 26 draws "Save" on an accent-tinted capsule, earlier versions
        // a bold "Save". (A checkmark icon was not understood as Save.)
        save = UIBarButtonItem(primaryAction: saveAction)
        if #available(iOS 26.0, *) {
            save.style = .prominent
            save.tintColor = .tintColor
        } else {
            save.style = .done
        }
        save.accessibilityLabel = saveTitle
        observe()
    }

    private static func item(_ title: String, image: String,
                             perform: @escaping @MainActor () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(primaryAction: UIAction(title: title, image: UIImage(systemName: image)) { _ in
            perform()
        })
        item.accessibilityLabel = title
        return item
    }

    /// Sets the pinned group and the items' enabled states. Also called when UIKit or SwiftUI
    /// rebuilds the navigation item's groups.
    func update() {
        guard let state, let navigationItem else { return }
        var items: [UIBarButtonItem] = []
        if state.showsUndoRedo { items = [undo, redo] }
        if state.hasChanges { items.append(save) }
        if !items.elementsEqual(group?.barButtonItems ?? [], by: ===) {
            group = items.isEmpty ? nil : UIBarButtonItemGroup(barButtonItems: items, representativeItem: nil)
        }
        if navigationItem.pinnedTrailingGroup !== group { navigationItem.pinnedTrailingGroup = group }
        setEnabled(undo, state.canUndo)
        setEnabled(redo, state.canRedo)
        setEnabled(save, !state.isSaving)
    }

    private func setEnabled(_ item: UIBarButtonItem, _ enabled: Bool) {
        if item.isEnabled != enabled { item.isEnabled = enabled }
    }

    private func observe() {
        guard let state else { return }
        withObservationTracking {
            _ = state.showsUndoRedo
            _ = state.hasChanges
            _ = state.canUndo
            _ = state.canRedo
            _ = state.isSaving
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }
}
