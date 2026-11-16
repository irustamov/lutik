import AppKit
import KernirCore
import Observation
import os

/// A long-running operation shown in the window's progress sheet.
struct OperationProgress {
    /// Tells this operation's sheet from the next one's: late progress updates check it.
    let id = UUID()
    var title: String
    /// 0...1, or nil while the amount of work is unknown.
    var fraction: Double?
    var cancel: (@MainActor () -> Void)?
}

/// One previewed item: its path in the archive, which Share and Open With act on, and the file
/// extracted for it (`ArchiveModel.localFileURL(for:)`).
struct PreviewEntry: Equatable, Sendable {
    let path: String
    let url: URL
}

/// Per-document window state. The document owns it; it has one window.
@MainActor @Observable
final class ArchiveWindowState {
    /// nil while the archive is locked or failed to open.
    var model: ArchiveModel?
    /// Encrypted headers and no working password yet: the window asks for one.
    var isLocked = false
    /// Shown under the password field after a wrong password.
    var passwordError: String?
    /// Consecutive wrong passwords typed in the password sheet; reset by a success and by Cancel.
    private(set) var wrongPasswordCount = 0
    /// The locked archive is a 7z, whose AES has no check value: damage in the first encrypted
    /// file reports a wrong password too. ZIP's passwords are checked, so it never hints.
    private(set) var lockedArchiveIsSevenZip = false
    /// The password sheet adds "the archive may be damaged" from the second wrong 7z password.
    var showsDamagedHint: Bool { lockedArchiveIsSevenZip && wrongPasswordCount >= 2 }
    /// Why the archive can't be shown, e.g. it couldn't be reread after a save; nil otherwise.
    var loadError: String?
    /// The archive is a split set the engine can't read whole (a part is missing or unreadable):
    /// the window shows why, with Grant Access… when that may help. nil otherwise.
    var volumeError: ArchiveVolumeError?
    /// A reopen after a volume error is running: Grant Access… waits, and a second retry returns at once.
    var isRetrying = false
    /// Selected item paths.
    var selection = Set<String>()
    /// Expanded folder paths.
    var expanded = Set<String>()
    /// The item whose name the table is editing (Rename, New Folder), nil when none is.
    var renamingPath: String?
    var searchText = ""
    /// The folders open before the search began, restored when it clears; nil while no search shows. A rename
    /// under the search moves them with the item (`ArchiveActions`), so a renamed open folder stays open.
    var expandedBeforeSearch: Set<String>?
    /// Finder name order by default.
    var sortOrder: [KeyPathComparator<ArchiveItem>] = [KeyPathComparator(\.name, comparator: .localizedStandard)]
    var progress: OperationProgress?
    /// The Move To… sheet's folders while it is up (`ArchiveActions.beginMoveTo`); setting nil closes it.
    var moveTo: MoveToFolders?
    /// The item the preview shows: one of `previewEntries`' URLs. nil when no preview shows;
    /// setting nil closes it.
    var previewURL: URL?
    /// The previewed items, in the window's order: each entry's archive path and its extracted file.
    var previewEntries: [PreviewEntry] = []
    var previewURLs: [URL] { previewEntries.map(\.url) }
    /// The archive's size on disk, for the window subtitle; nil for an unsaved document.
    var fileSize: Int64?
    /// The document has unsaved changes (`isDocumentEdited`), for the window subtitle.
    var isEdited = false
    /// What the Info popover (File > Get Info, the toolbar's Info button, the footer's Comment button) points at
    /// while it is open; nil when it is closed. Closing or moving it ends the comment's typing undo step: SwiftUI
    /// doesn't call `onDisappear` for a macOS popover's content, the closes (Get Info again; a click outside, Esc or
    /// the anchor gone, through the popover's binding) set this to nil, and a popover left open at a hidden toolbar
    /// moves to the footer without passing through nil. Ending it on an open too is harmless.
    var infoAnchor: InfoAnchor? {
        didSet { if infoAnchor != oldValue { model?.endCommentTyping() } }
    }
    /// The Info popover is open.
    var isShowingInfo: Bool { infoAnchor != nil }
    /// The window of the Info popover shown last. The undo gate asks it whether the popover is on screen:
    /// `infoAnchor` could stay set with nothing on screen (the anchor gone with the popover open).
    @ObservationIgnored weak var infoPopoverWindow: NSWindow?
    /// The Info popover is on screen.
    var isInfoPopoverOnScreen: Bool { infoPopoverWindow?.isVisible == true }

    /// Where the Info popover shows: at the toolbar's Info button while that is on screen, else at the footer,
    /// which every listed archive's window has (the toolbar may be hidden, or the button in its overflow menu).
    enum InfoAnchor {
        case toolbar, footer
    }

    /// Opens the Info popover at `anchor`, or closes it when it is open (File > Get Info, the toolbar's Info button).
    func toggleInfo(at anchor: InfoAnchor) {
        infoAnchor = infoAnchor == nil ? anchor : nil
    }

    /// A progress handler for the operation `id` (the `id` of the `OperationProgress` just set).
    /// Callable from any thread; throttled, and updates that arrive after the operation was
    /// replaced or ended never touch the sheet that follows it.
    nonisolated func progressHandler(for id: UUID) -> ArchiveProgressHandler {
        ProgressForwarding.handler { [self] fraction in
            Task { @MainActor in applyProgress(fraction, for: id) }
        }
    }

    /// Sets the fraction of the running operation `id`; ignored when another one (or none) is showing.
    /// Never moves backwards: the main-actor hops of two updates can land in either order.
    func applyProgress(_ fraction: Double, for id: UUID) {
        guard let current = progress, current.id == id else { return }
        // Read before writing: `progress?.fraction = max(progress?.fraction …)` reads `progress`
        // inside its own modify access, a fatal exclusivity conflict.
        progress?.fraction = max(current.fraction ?? 0, fraction)
    }

    /// The table's top-level rows: `model`'s items filtered by the search, then sorted. Shared by
    /// the table and by ↑/↓ in the preview window.
    func tableItems(of model: ArchiveModel) -> [ArchiveItem] {
        model.items.filtered(matching: searchText).sorted(using: sortOrder)
    }

    func recordWrongPassword(isSevenZip: Bool) {
        lockedArchiveIsSevenZip = isSevenZip
        wrongPasswordCount += 1
    }

    func resetWrongPasswords() {
        wrongPasswordCount = 0
    }

    /// Nonisolated: NSDocumentController creates documents (and their state) on a background
    /// thread when it reads concurrently.
    nonisolated init() {}
}

/// Throttles a progress callback that engines call from background threads, thousands of times a second.
enum ProgressForwarding {
    /// At most one `deliver` per `interval` (about 30 a second), plus every update that reaches 1.
    /// The throttle state sits behind a lock: the handler is `@Sendable`. `clock` is injectable for tests.
    static func handler(
        interval: Duration = .milliseconds(33),
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        deliver: @escaping @Sendable (Double) -> Void
    ) -> ArchiveProgressHandler {
        let lastDelivery = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        return { fraction, _ in
            let now = clock()
            let send = lastDelivery.withLock { last in
                guard fraction >= 1 || last.map({ now - $0 >= interval }) ?? true else { return false }
                last = now
                return true
            }
            if send { deliver(fraction) }
        }
    }
}
