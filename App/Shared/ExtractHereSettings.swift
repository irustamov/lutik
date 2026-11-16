import Foundation

/// Extract Here's settings, in the app's defaults (Settings > Extracting).
struct ExtractHereSettings {
    static let movesArchiveToTrashKey = "KernirExtractHereMovesArchiveToTrash"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Move the archive to the Trash after an Extract Here that extracted everything. Off by default.
    var movesArchiveToTrash: Bool {
        get { defaults.bool(forKey: Self.movesArchiveToTrashKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.movesArchiveToTrashKey) }
    }
}

/// Whether the archive goes to the Trash after Extract Here.
enum ExtractHereTrashDecision: Equatable, Sendable {
    /// How the extraction ended.
    enum Outcome: Sendable {
        case completed, cancelled, failed
    }

    /// Why an archive the user wanted in the Trash was kept, when they need to be told.
    enum KeepReason: Equatable, Sendable {
        case unsavedChanges

        /// One line for the completion alert.
        var message: String {
            switch self {
            case .unsavedChanges:
                String(localized: "The archive was kept because it has unsaved changes.", table: "Shared",
                       comment: "Extract Here finished, but the archive wasn't moved to the Trash (Settings > Extracting) because it has unsaved edits.")
            }
        }
    }

    case moveToTrash
    /// The archive stays; `reason` is what to tell the user, if anything.
    case keep(KeepReason?)

    /// The Trash only when the setting is on (`enabled`), the whole archive was extracted
    /// (`extractedAll`: Extract Here ran on no selection, `ExtractHerePlan.make(nil, …)`; a
    /// selection, even of every item, is false), the archive has no unsaved changes (they would
    /// be lost) and is a file of its own (not an untitled copy without a file URL, nor one part of
    /// a volume set, whose other parts would stay behind). A cancel, a failure or a partial
    /// extraction keeps it without a word: the user sees what happened, or asked for part of it.
    static func decide(enabled: Bool, outcome: Outcome, extractedAll: Bool, hasUnsavedChanges: Bool,
                       isVolumeSet: Bool, hasFileURL: Bool) -> ExtractHereTrashDecision {
        guard enabled, outcome == .completed, extractedAll, hasFileURL, !isVolumeSet else { return .keep(nil) }
        return hasUnsavedChanges ? .keep(.unsavedChanges) : .moveToTrash
    }
}
