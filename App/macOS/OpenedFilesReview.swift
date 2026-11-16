import AppKit

/// Files opened from an archive window are copies the document owns until it closes. Closing
/// (and quitting) offers each one changed in another app back to the archive.
extension ArchiveDocument {
    /// True when a copy opened from this archive was changed in another app since, or another app
    /// left a new item next to one.
    var hasChangedOpenedFiles: Bool {
        !openedFiles.changed().isEmpty
    }

    /// Asks about every changed copy and new item, one sheet each, and saves the archive if any
    /// went in. `done(false)` cancels the close: Show in Finder, or a save that failed or was
    /// cancelled. Without a model (locked, or not reopened after a save) an item can only be shown
    /// or let go.
    func reviewOpenedFiles(then done: @escaping @MainActor (Bool) -> Void) {
        guard let window = windowControllers.first?.window else { return done(true) }
        let review = OpenedFilesReview(openedFiles: openedFiles, model: model) { file, canUpdate, isNew, nameTaken, answer in
            let alert = Self.openedFileChangedAlert(name: file.url.lastPathComponent, canUpdate: canUpdate,
                                                    isNew: isNew, nameTaken: nameTaken)
            window.whenNoSheetAttached {
                alert.beginSheetModal(for: window) { response in
                    answer(Self.answer(to: response, canUpdate: canUpdate, isNew: isNew, nameTaken: nameTaken))
                }
            }
        }
        review.run { outcome in
            switch outcome {
            case .finished(updated: true):
                self.saveAfterReview(then: done)
            case .finished(updated: false):
                done(true)
            case .showInFinder(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
                done(false)
            }
        }
    }

    /// A plain save (the Save panel for an untitled archive); the close goes on only if it worked.
    private func saveAfterReview(then done: @escaping @MainActor (Bool) -> Void) {
        let box = Unmanaged.passRetained(ReviewCompletion(done)).toOpaque()
        save(withDelegate: self, didSave: #selector(reviewSave(_:didSave:contextInfo:)), contextInfo: box)
    }

    @objc private func reviewSave(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        Unmanaged<ReviewCompletion>.fromOpaque(contextInfo).takeRetainedValue().done(didSave)
    }

    /// "“X” was changed in another app. Update the archive?" [Update] [Don't Update] [Show in Finder].
    /// An archive Lutik can't write offers Show in Finder first, so Return never loses the edits.
    /// `isNew`: X is an item another app saved next to a copy (an export, a renamed copy), which the
    /// user never opened, so the message says where it was saved instead, and letting it go takes
    /// a click on Delete, which has no key equivalent. Esc is Don't Update, or
    /// for a new item Show in Finder unless that is already Return. `nameTaken`: updating would
    /// replace a different archive item named X (`ArchiveModel.wouldReplace(_:)`), so Update
    /// becomes [Keep Both] (Return) and [Replace], as when extracting onto an existing name.
    static func openedFileChangedAlert(name: String, canUpdate: Bool, isNew: Bool = false,
                                       nameTaken: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch (canUpdate, isNew) {
        case (true, true) where nameTaken:
            alert.messageText = String(localized: "“\(name)” was saved in the folder of a file opened from this archive, and the archive already has an item with that name.")
            alert.informativeText = String(localized: "Keep Both adds it under a new name. Unless you update the archive with it or move it, it's deleted when the archive closes.")
        case (true, false) where nameTaken:
            alert.messageText = String(localized: "“\(name)” was changed in another app, and the archive already has a different item with that name.")
            alert.informativeText = String(localized: "Keep Both adds it under a new name.")
        case (true, false):
            alert.messageText = String(localized: "“\(name)” was changed in another app. Update the archive?")
        case (false, false):
            alert.messageText = String(localized: "“\(name)” was changed in another app, but this archive can't be updated.")
            alert.informativeText = String(localized: "Show it in Finder to keep your changes. It's deleted when the archive closes.")
        case (true, true):
            alert.messageText = String(localized: "“\(name)” was saved in the folder of a file opened from this archive. Update the archive?")
            alert.informativeText = String(localized: "Unless you update the archive with it or move it, it's deleted when the archive closes.")
        case (false, true):
            alert.messageText = String(localized: "“\(name)” was saved in the folder of a file opened from this archive, but this archive can't be updated.")
            alert.informativeText = String(localized: "Show it in Finder to keep it. Unless you move it, it's deleted when the archive closes.")
        }
        let answers = openedFileAnswers(canUpdate: canUpdate, isNew: isNew, nameTaken: nameTaken)
        for answer in answers {
            let button: NSButton
            switch answer {
            case .update:
                button = alert.addButton(withTitle: String(localized: "Update",
                    comment: "Update (a verb): button of the alert about a file opened from the archive and changed in another app; puts the changed file into the archive."))
                button.setAccessibilityIdentifier("openedFileChanged.update")
            case .keepBoth:
                button = alert.addButton(withTitle: String(localized: "Keep Both",
                    comment: "Keep Both (a button): in the alert about an extracted item with the same name, keeps the existing item and extracts the new one under a new name; in the alert about a file saved next to a file opened from the archive, adds the file to the archive under a new name."))
                button.setAccessibilityIdentifier("openedFileChanged.keepBoth")
            case .replace:
                button = alert.addButton(withTitle: String(localized: "Replace",
                    comment: "Replace (a verb): button of the alerts about an item with the same name when adding, extracting or moving (replaces the existing item), and of the alert about a changed file opened from the archive (replaces the archive's item of that name with it)."))
                button.hasDestructiveAction = true
                button.setAccessibilityIdentifier("openedFileChanged.replace")
            case .dontUpdate:
                button = alert.addButton(withTitle: String(localized: "Don't Update"))
                button.keyEquivalent = "\u{1b}"
                button.setAccessibilityIdentifier("openedFileChanged.dontUpdate")
            case .showInFinder:
                button = alert.addButton(withTitle: String(localized: "Show in Finder"))
                if isNew, answer != answers.first { button.keyEquivalent = "\u{1b}" }
                button.setAccessibilityIdentifier("openedFileChanged.showInFinder")
            case .delete:
                button = alert.addButton(withTitle: String(localized: "Delete",
                    comment: "Delete (a verb), in three places: the Edit menu command and context-menu item that remove the selected items from the archive, the label of the toolbar's － button doing the same, and a button of the alert about a file saved next to a file opened from the archive, which deletes that saved file."))
                button.hasDestructiveAction = true
                button.setAccessibilityIdentifier("openedFileChanged.delete")
            }
        }
        return alert
    }

    /// The answers `openedFileChangedAlert(name:canUpdate:isNew:nameTaken:)` offers, in button order.
    static func openedFileAnswers(canUpdate: Bool, isNew: Bool,
                                  nameTaken: Bool = false) -> [OpenedFilesReview.Answer] {
        switch (canUpdate, isNew) {
        case (true, false) where nameTaken: [.keepBoth, .replace, .dontUpdate, .showInFinder]
        case (true, true) where nameTaken: [.keepBoth, .replace, .showInFinder, .delete]
        case (true, false): [.update, .dontUpdate, .showInFinder]
        case (false, false): [.showInFinder, .dontUpdate]
        case (true, true): [.update, .showInFinder, .delete]
        case (false, true): [.showInFinder, .delete]
        }
    }

    /// Maps the button pressed in `openedFileChangedAlert(name:canUpdate:isNew:nameTaken:)` to the
    /// answer. Any other response (a sheet ended from outside) is Show in Finder, which loses nothing.
    static func answer(to response: NSApplication.ModalResponse, canUpdate: Bool,
                       isNew: Bool = false, nameTaken: Bool = false) -> OpenedFilesReview.Answer {
        let answers = openedFileAnswers(canUpdate: canUpdate, isNew: isNew, nameTaken: nameTaken)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answers.indices.contains(index) ? answers[index] : .showInFinder
    }

    /// Calls `document:shouldClose:contextInfo:` on `delegate`, as AppKit would.
    static func report(_ shouldClose: Bool, to delegate: Any, selector: Selector?, from document: NSDocument,
                       contextInfo: UnsafeMutableRawPointer?) {
        guard let delegate = delegate as? NSObject, let selector, delegate.responds(to: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(delegate.method(for: selector), to: Callback.self)
        callback(delegate, selector, document, shouldClose, contextInfo)
    }
}

/// Carries `reviewOpenedFiles`' completion through the save's `contextInfo`.
private final class ReviewCompletion {
    let done: @MainActor (Bool) -> Void
    init(_ done: @escaping @MainActor (Bool) -> Void) { self.done = done }
}

/// The steps of `reviewOpenedFiles`, apart from the sheets, which `ask` shows: one question per
/// item `OpenedFiles.changed()` reports, then `changed()` again for what changed while a sheet
/// was up, until it reports nothing. Every answer ends the item's question: Update (or Keep Both
/// or Replace, for an item named like a different archive item) puts it in, Don't Update and
/// Delete mark it seen, and Show in Finder ends the review. An Update that doesn't go in asks
/// about the same item again as an archive Lutik can't write, which offers no Update, so the
/// user always hears about it. An item is asked about again only if it changes
/// again.
@MainActor
final class OpenedFilesReview {
    /// The user's answer about one item.
    enum Answer: Equatable {
        case update, keepBoth, replace, dontUpdate, delete, showInFinder
    }

    enum Outcome: Equatable {
        /// Nothing left to ask about; `updated` when something went into the archive.
        case finished(updated: Bool)
        /// The user chose Show in Finder for `url`: the close is cancelled.
        case showInFinder(URL)
    }

    /// Shows the question about `file`, and calls `answer` with the user's answer. `nameTaken`:
    /// updating would replace a different archive item, so the user picks Keep Both or Replace.
    typealias Ask = @MainActor (_ file: OpenedFiles.File, _ canUpdate: Bool, _ isNew: Bool, _ nameTaken: Bool,
                                _ answer: @escaping @MainActor (Answer) -> Void) -> Void

    private let openedFiles: OpenedFiles
    private let model: ArchiveModel?
    private let ask: Ask
    private var queue: [OpenedFiles.File] = []
    private var updated = false

    init(openedFiles: OpenedFiles, model: ArchiveModel?, ask: @escaping Ask) {
        self.openedFiles = openedFiles
        self.model = model
        self.ask = ask
    }

    /// Asks about each item in turn and reports the outcome once.
    func run(then done: @escaping @MainActor (Outcome) -> Void) {
        if queue.isEmpty { queue = openedFiles.changed() }
        guard !queue.isEmpty else { return done(.finished(updated: updated)) }
        let file = queue.removeFirst()
        ask(about: file, canUpdate: model?.isEditable ?? false, then: done)
    }

    private func ask(about file: OpenedFiles.File, canUpdate: Bool,
                     then done: @escaping @MainActor (Outcome) -> Void) {
        let nameTaken = canUpdate && model?.wouldReplace(file) == true
        ask(file, canUpdate, !openedFiles.isTracked(file), nameTaken) { answer in
            switch answer {
            case .update, .keepBoth, .replace:
                let resolution: UpdateConflictResolution? = switch answer {
                case .keepBoth: .keepBoth
                case .replace: .replace
                default: nil
                }
                Task { @MainActor in
                    // Asked again without Update, so this can't come round more than once.
                    guard canUpdate, await self.model?.update(from: file, ifNameIsTaken: resolution) == true else {
                        return self.ask(about: file, canUpdate: false, then: done)
                    }
                    self.updated = true
                    self.run(then: done)
                }
            case .dontUpdate, .delete:
                self.openedFiles.markSeen(file)
                self.run(then: done)
            case .showInFinder:
                done(.showInFinder(file.url))
            }
        }
    }
}
