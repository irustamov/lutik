import Foundation

/// What Extract Here waits on: a Files picker or a question about the archive's folder.
struct ExtractHereRequest: Equatable {
    enum Step: Equatable {
        /// The Files picker, opening at `folder`, for the archive's folder or one above it; the
        /// pick is kept as a grant (`FolderAccessStore`).
        case grant
        /// The pick doesn't hold the archive: the alert, then the picker again.
        case notContaining
        /// The archive's volume is read-only: Choose Another Folder… or Cancel.
        case readOnly
        /// The Files picker for any folder to extract into; no grant is kept for it.
        case otherFolder
    }

    var step: Step
    /// What to extract: nil for everything.
    var paths: [String]?
    /// The archive's folder.
    var folder: URL
    /// OK (`.notContaining`) or Choose Another Folder… (`.readOnly`) was tapped: the alert goes at
    /// once, and the picker step the answer leads to is taken only once the alert has gone
    /// (`alertDidDismiss()`). A picker asked for while the alert is still on its way out may never
    /// come up, which left Extract Here off until the archive was opened again.
    var isAnswered = false

    /// The alert of `.notContaining` or `.readOnly` is up: not yet answered.
    var asksQuestion: Bool {
        !isAnswered && (step == .notContaining || step == .readOnly)
    }

    /// The Files picker is up, or is to come up: `.grant` or `.otherFolder`.
    var waitsOnPicker: Bool {
        step == .grant || step == .otherFolder
    }

    /// OK or Choose Another Folder… on the alert. Nothing on a picker step.
    mutating func answer() {
        if asksQuestion { isAnswered = true }
    }

    /// The alert has gone. After an answer: the picker, for the archive's folder after
    /// `.notContaining`, for any folder after `.readOnly`. Without one (something else took the
    /// screen) the question stays and its alert comes back.
    mutating func alertDidDismiss() {
        guard isAnswered else { return }
        step = step == .readOnly ? .otherFolder : .grant
        isAnswered = false
    }
}
