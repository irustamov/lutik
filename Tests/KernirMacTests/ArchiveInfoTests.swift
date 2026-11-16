import Testing
import AppKit
import SwiftUI
@testable import Kernir
import KernirCore
import os

// The Info popover (File > Get Info ⌘I, the toolbar's Info button, the footer's Comment button)
// and the ZIP comment's save rules in `ArchiveDocument`. A suite nested in `ArchiveDocumentTests`, so it runs
// serialized with it (`.serialized` covers nested suites): both swap the process-wide `ArchiveDocument.engine`.
// Hosted (an `ArchiveDocument`).

/// `open` gives a ZIP `FakeReader` with `comment` (the first of a two-part set when `volumeSet`), or a 7z one
/// without a comment for a `.7z` file; `write`
/// writes a placeholder and records the changes; `writeVolumes` records that it ran and writes nothing.
private final class CommentFakeEngine: Sendable {
    struct WriteCall: Sendable {
        let changes: ArchiveChangeSet
        let format: ArchiveFormat
    }

    private struct State {
        var writes: [WriteCall] = []
        var volumeCalls = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let comment: ArchiveComment?
    private let volumeSet: Bool

    init(comment: ArchiveComment?, volumeSet: Bool = false) {
        self.comment = comment
        self.volumeSet = volumeSet
    }

    var writes: [WriteCall] { state.withLock { $0.writes } }
    var volumeCalls: Int { state.withLock { $0.volumeCalls } }

    var engine: ArchiveEngine {
        var engine = ArchiveEngine(
            open: { url, _ in
                let isSevenZip = url.pathExtension == "7z"
                let parts = self.volumeSet && !isSevenZip
                    ? [url, url.deletingLastPathComponent().appendingPathComponent("a.z02")] : nil
                return FakeReader(entries: [ArchiveEntry(path: "README", isDirectory: false, size: 1,
                                                         compressedSize: 1, modificationDate: nil)],
                                  format: isSevenZip ? .sevenZip : .zip, url: url, volumeURLs: parts,
                                  comment: isSevenZip ? nil : self.comment)
            },
            write: { _, changes, format, url, _, progress in
                self.state.withLock { $0.writes.append(WriteCall(changes: changes, format: format)) }
                try Data("written \(format.rawValue)".utf8).write(to: url)
                progress?(1, nil)
            }
        )
        engine.writeVolumes = { _, _, _, _, _, _, _ in
            self.state.withLock { $0.volumeCalls += 1 }
            return []
        }
        return engine
    }
}

extension ArchiveDocumentTests {
    @MainActor struct ArchiveInfoTests {
        private static func comment(_ text: String, isWritable: Bool = true) -> ArchiveComment {
            ArchiveComment(bytes: Array(text.utf8), text: text, isWritable: isWritable)
        }

        /// A fresh folder holding `a.zip` (4 bytes); the caller removes the folder.
        private func makeInfoRoot() throws -> (root: URL, archive: URL) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveInfoTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let archive = root.appendingPathComponent("a.zip")
            try Data("PK\u{3}\u{4}".utf8).write(to: archive)
            return (root, archive)
        }

        /// Runs `body` with `fake` installed, then restores the live engine.
        private func withCommentEngine<T>(_ fake: CommentFakeEngine, _ body: () async throws -> T) async rethrows -> T {
            ArchiveDocument.engine = fake.engine
            defer { ArchiveDocument.engine = .live }
            return try await body()
        }

        /// File > Get Info (⌘I) shows and hides the Info popover; it needs a listing to describe.
        @Test func getInfoTogglesPopoverState() async throws {
            let fileMenu = MainMenu.fileMenu()
            let showInfo = #selector(ArchiveWindowController.showInfo(_:))
            let getInfo = try #require(fileMenu.items.first { $0.action == showInfo })
            #expect(getInfo.title == String(localized: "Get Info"))
            #expect(getInfo.keyEquivalent == "i")
            #expect(getInfo.keyEquivalentModifierMask == .command)

            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let controller = ArchiveWindowController(document: document, windowFrame: nil)
                // A window left open could show up in other suites' window checks.
                defer { controller.close() }
                #expect(!document.state.isShowingInfo)
                #expect(controller.validateMenuItem(getInfo))

                controller.showInfo(nil)
                #expect(document.state.isShowingInfo)
                controller.showInfo(nil)
                #expect(!document.state.isShowingInfo)

                // Locked, or not reread after a save: nothing to describe.
                let model = document.state.model
                document.state.model = nil
                #expect(!controller.validateMenuItem(getInfo))
                document.state.model = model
            }
        }

        /// The Info popover points at the toolbar's Info button while that is on screen, else at the footer: with
        /// the toolbar hidden (or the button in its overflow menu) a popover on the button would never show, and
        /// Get Info would stay "open" with nothing on screen.
        @Test func getInfoPointsAtTheFooterWithoutTheToolbarButton() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let controller = ArchiveWindowController(document: document, windowFrame: nil)
                defer { controller.close() }
                let window = try #require(controller.window)
                // On screen, so the toolbar lays out its items, but fully transparent.
                window.alphaValue = 0
                window.orderFront(nil)
                try await waitUntil { window.toolbar?.visibleItems?.isEmpty == false }
                let toolbar = try #require(window.toolbar)

                #expect(ArchiveActions.showsInfoButton(in: toolbar))
                controller.showInfo(nil)
                #expect(document.state.infoAnchor == .toolbar)
                controller.showInfo(nil)
                #expect(document.state.infoAnchor == nil)

                toolbar.isVisible = false
                #expect(!ArchiveActions.showsInfoButton(in: toolbar))
                controller.showInfo(nil)
                #expect(document.state.infoAnchor == .footer)
                controller.showInfo(nil)
                #expect(document.state.infoAnchor == nil)
                // The footer's Comment button opens it at the footer too.
                document.state.infoAnchor = .footer
                #expect(document.state.isShowingInfo)
                document.state.infoAnchor = nil
                toolbar.isVisible = true
                #expect(!ArchiveActions.showsInfoButton(in: nil))
            }
        }

        /// Text typed into the popover's comment field reaches the model as one "Edit Comment" step of the
        /// document's undo manager.
        @Test func commentFieldTypingIsOneDocumentUndoStep() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                let controller = ArchiveWindowController(document: document, windowFrame: nil)
                defer { controller.close() }
                let window = try #require(controller.window)
                window.alphaValue = 0
                window.orderFront(nil)
                try await waitUntil { window.toolbar?.visibleItems?.isEmpty == false }
                document.state.infoAnchor = .footer
                let textView = try await openCommentField(of: document, controller: controller)
                let undoManager = try #require(document.undoManager)
                defer { undoManager.groupsByEvent = true }
                // The text view has no "Typing" undo of its own, on whichever undo manager it gets (SwiftUI's
                // `TextEditor` gave it the document's on macOS 26.7.3), and the window's undo is
                // gated while the popover is on screen. Required, not expected: typing below with a manager that
                // registers outside a group would throw an Objective-C exception, which crashes the test host.
                try #require(!textView.allowsUndo)
                try #require(controller.windowWillReturnUndoManager(window) !== undoManager)
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                undoManager.groupsByEvent = false
                // The first key registers the step, in a group as its event makes; the keys after it join that
                // step and register nothing, so their events open no group. They type as a real key's event does
                // (`groupsByEvent`: a group opens only on a registration), not in an open group, which would hide
                // the step from the join; a key that registered after all fails here instead of crashing the host.
                Self.type("x", into: textView, inGroupOf: undoManager)
                #expect(document.isDocumentEdited)
                undoManager.groupsByEvent = true
                for key in ["y", "z"] {
                    textView.insertText(key, replacementRange: textView.selectedRange())
                    #expect(undoManager.groupingLevel == 0)
                }
                undoManager.groupsByEvent = false
                #expect(model.changes.comment == .set("helloxyz"))
                #expect(undoManager.undoActionName == String(localized: "Edit Comment", table: "Shared"))
                // Closed: one undo takes all of the typing back, and nothing else is left.
                document.state.infoAnchor = nil
                try await waitUntil { !document.state.isInfoPopoverOnScreen }
                #expect(controller.windowWillReturnUndoManager(window) === undoManager)
                undoManager.undo()
                #expect(model.changes.comment == .keep)
                #expect(!undoManager.canUndo)
                #expect(!document.isDocumentEdited)
            }
        }

        /// Closing the popover ends the typing step: typing after it reopens, and any other edit after the close,
        /// is a step of its own.
        @Test func closingThePopoverEndsTheTypingStep() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                let controller = ArchiveWindowController(document: document, windowFrame: nil)
                defer { controller.close() }
                let window = try #require(controller.window)
                window.alphaValue = 0
                window.orderFront(nil)
                try await waitUntil { window.toolbar?.visibleItems?.isEmpty == false }
                let undoManager = try #require(document.undoManager)
                let editComment = String(localized: "Edit Comment", table: "Shared")

                // Opens the popover, types `key` at the end of the comment in one group (as its event makes),
                // closes the popover.
                @MainActor func type(_ key: String) async throws {
                    document.state.infoAnchor = .footer
                    let textView = try await openCommentField(of: document, controller: controller)
                    textView.window?.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                    Self.type(key, into: textView, inGroupOf: undoManager)
                    document.state.infoAnchor = nil
                    try await waitUntil { !document.state.isInfoPopoverOnScreen }
                }
                undoManager.groupsByEvent = false
                defer { undoManager.groupsByEvent = true }
                try await type("x")
                try await type("y")
                #expect(model.changes.comment == .set("helloxy"))

                // Closed: an edit now (straight on the model) doesn't join the typing from before the close. No
                // group is open, as when its event begins: an edit that joins registers nothing, one that starts
                // a step opens the group its registration makes (`groupsByEvent`; undo closes it first). Only
                // one such group per test: this manager reopens none after closing one outside the run loop.
                undoManager.groupsByEvent = true
                #expect(undoManager.groupingLevel == 0)
                #expect(undoManager.undoActionName == editComment)
                model.setComment("helloxy.")
                undoManager.undo()
                #expect(model.changes.comment == .set("helloxy"))

                // The typing after the reopen, then the typing before the close.
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(model.changes.comment == .set("hellox"))
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(model.changes.comment == .keep)
                #expect(!undoManager.canUndo)
            }
        }

        /// Moving the open popover to another anchor (the toolbar hidden while it is open at the toolbar's Info
        /// button, then the footer's Comment button) ends the typing step too: it never passes through closed.
        @Test func movingThePopoverEndsTheTypingStep() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                let controller = ArchiveWindowController(document: document, windowFrame: nil)
                defer { controller.close() }
                let window = try #require(controller.window)
                window.alphaValue = 0
                window.orderFront(nil)
                try await waitUntil { window.toolbar?.visibleItems?.isEmpty == false }
                let undoManager = try #require(document.undoManager)
                let editComment = String(localized: "Edit Comment", table: "Shared")

                // Open at the toolbar's Info button; the first key registers the step, in a group as its event
                // makes.
                document.state.infoAnchor = .toolbar
                let textView = try await openCommentField(of: document, controller: controller)
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                undoManager.groupsByEvent = false
                defer { undoManager.groupsByEvent = true }
                Self.type("x", into: textView, inGroupOf: undoManager)
                #expect(model.changes.comment == .set("hellox"))

                // Moved to the footer: an edit now (straight on the model, no group open, as in
                // `closingThePopoverEndsTheTypingStep`) is a step of its own.
                document.state.infoAnchor = .footer
                undoManager.groupsByEvent = true
                #expect(undoManager.groupingLevel == 0)
                #expect(undoManager.undoActionName == editComment)
                model.setComment("hellox.")
                undoManager.undo()
                #expect(model.changes.comment == .set("hellox"))
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(model.changes.comment == .keep)
                #expect(!undoManager.canUndo)

                document.state.infoAnchor = nil
                try await waitUntil { !document.state.isInfoPopoverOnScreen }
            }
        }

        /// The undo gate follows the popover on screen, not `infoAnchor`: the document's undo comes back when the
        /// popover's anchor goes away while it is open (the toolbar hidden, the footer gone with the model).
        @Test func undoGateEndsWhenThePopoverLeavesTheScreen() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let controller = ArchiveWindowController(document: document, windowFrame: nil)
                defer { controller.close() }
                let window = try #require(controller.window)
                window.alphaValue = 0
                window.orderFront(nil)
                try await waitUntil { window.toolbar?.visibleItems?.isEmpty == false }
                let toolbar = try #require(window.toolbar)
                defer { toolbar.isVisible = true }
                let undoManager = try #require(document.undoManager)
                #expect(controller.windowWillReturnUndoManager(window) === undoManager)

                controller.showInfo(nil)
                #expect(document.state.infoAnchor == .toolbar)
                try await waitUntil { document.state.isInfoPopoverOnScreen }
                #expect(controller.windowWillReturnUndoManager(window) !== undoManager)

                toolbar.isVisible = false
                try await waitUntil { !document.state.isInfoPopoverOnScreen }
                #expect(document.state.infoAnchor == nil)
                #expect(controller.windowWillReturnUndoManager(window) === undoManager)

                // The footer goes away with the model (a failed reread).
                document.state.infoAnchor = .footer
                try await waitUntil { document.state.isInfoPopoverOnScreen }
                let model = document.state.model
                document.state.model = nil
                try await waitUntil { !document.state.isInfoPopoverOnScreen }
                #expect(document.state.infoAnchor == nil)
                // Back, it neither reopens the popover nor keeps the gate on.
                document.state.model = model
                try await Task.sleep(for: .milliseconds(300))
                #expect(!document.state.isInfoPopoverOnScreen)
                #expect(controller.windowWillReturnUndoManager(window) === undoManager)
            }
        }

        /// A read-only comment has no text field, so the open popover leaves the document's undo alone.
        @Test func undoGateOffWhenTheCommentIsReadOnly() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"), volumeSet: true)) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                #expect(!model.canEditComment)
                let controller = ArchiveWindowController(document: document, windowFrame: nil)
                defer { controller.close() }
                let window = try #require(controller.window)
                window.alphaValue = 0
                window.orderFront(nil)
                try await waitUntil { window.toolbar?.visibleItems?.isEmpty == false }
                let undoManager = try #require(document.undoManager)

                document.state.infoAnchor = .footer
                try await waitUntil { document.state.isInfoPopoverOnScreen }
                #expect(controller.windowWillReturnUndoManager(window) === undoManager)
                document.state.infoAnchor = nil
                try await waitUntil { !document.state.isInfoPopoverOnScreen }
            }
        }

        /// While an operation shows its progress sheet (a save, an extract), the open popover's comment is read-only:
        /// the save adopts its snapshot when it ends, which would drop text typed meanwhile. It turns editable again
        /// when the operation ends.
        @Test func commentReadOnlyWhileAnOperationRuns() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                #expect(model.canEditComment)
                let controller = ArchiveWindowController(document: document, windowFrame: nil)
                defer { controller.close() }
                let window = try #require(controller.window)
                window.alphaValue = 0
                window.orderFront(nil)
                try await waitUntil { window.toolbar?.visibleItems?.isEmpty == false }
                let undoManager = try #require(document.undoManager)
                document.state.infoAnchor = .footer
                defer { document.state.infoAnchor = nil }
                try await waitUntil { Self.popoverCommentField(of: document.state) != nil }

                // A save starts with the popover open (⌘S), as `save(to:ofType:for:completionHandler:)` puts its
                // sheet up. Should the sheet close the popover, there is no field either.
                document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
                try await waitUntil { Self.popoverCommentField(of: document.state) == nil }
                #expect(controller.windowWillReturnUndoManager(window) !== undoManager)
                #expect(model.changes.comment == .keep)
                document.state.progress = nil
                document.state.infoAnchor = nil
                try await waitUntil { !document.state.isInfoPopoverOnScreen }

                // Get Info (⌘I) while the sheet is up: if the popover shows, its comment is read-only.
                document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
                document.state.infoAnchor = .footer
                for _ in 0..<50 where !document.state.isInfoPopoverOnScreen {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await Task.sleep(for: .milliseconds(300))
                #expect(Self.popoverCommentField(of: document.state) == nil)
                #expect(controller.windowWillReturnUndoManager(window) !== undoManager)

                // The operation over, the comment is editable again (reopened, should the popover not have shown).
                document.state.progress = nil
                document.state.infoAnchor = nil
                try await waitUntil { !document.state.isInfoPopoverOnScreen }
                try await Task.sleep(for: .milliseconds(100))
                document.state.infoAnchor = .footer
                try await waitUntil { Self.popoverCommentField(of: document.state) != nil }
                #expect(model.changes.comment == .keep)
            }
        }

        /// The editable comment field of `state`'s Info popover while that is on screen, else nil. Only in that
        /// popover's window: a window an earlier test left on screen (a popover still closing) can hold an editable
        /// text view too, whose undo doesn't go through this document's window.
        private static func popoverCommentField(of state: ArchiveWindowState) -> NSTextView? {
            guard state.isInfoPopoverOnScreen else { return nil }
            return textView(in: state.infoPopoverWindow?.contentView)
        }

        /// Waits for `document`'s Info popover to show its editable comment field, and for `controller`'s undo
        /// gate to be on: the popover's window reports itself to the gate (`infoPopoverWindow`) as its content
        /// moves in, so a field found before that would still type into the document's undo manager.
        private func openCommentField(of document: ArchiveDocument,
                                      controller: ArchiveWindowController) async throws -> NSTextView {
            let window = try #require(controller.window)
            var field: NSTextView?
            try await waitUntil {
                field = Self.popoverCommentField(of: document.state)
                return field != nil && controller.windowWillReturnUndoManager(window) !== document.undoManager
            }
            return try #require(field)
        }

        private static func textView(in view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let textView = view as? NSTextView, textView.isEditable { return textView }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }

        /// Types `key` into `textView` in one group of `undoManager` (as the key's event makes), and of the text
        /// view's own undo manager should it have another one (it has none: its undo is off, `allowsUndo`).
        /// `insertText` must find no manager that registers without an open group: it would throw an Objective-C
        /// exception through these async frames, which crashes the test host.
        private static func type(_ key: String, into textView: NSTextView, inGroupOf undoManager: UndoManager) {
            let managers = [undoManager] + [textView.undoManager].compactMap { $0 }.filter { $0 !== undoManager }
            managers.forEach { $0.beginUndoGrouping() }
            defer { managers.reversed().forEach { $0.endUndoGrouping() } }
            textView.insertText(key, replacementRange: textView.selectedRange())
        }

        /// Waits for `condition` and returns as soon as it holds; the long limit only ends a hang.
        private func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while !condition() {
                try #require(ContinuousClock.now < deadline, "timed out")
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Typing a comment is an edit like any other: the window shows "Edited" and closing asks to save.
        @Test func commentEditMarksDocumentEdited() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                #expect(!document.isDocumentEdited)
                #expect(model.canEditComment)

                let undoManager = try #require(document.undoManager)

                // One explicit group, as an event makes: NSDocument counts a change when it closes.
                undoManager.groupsByEvent = false
                defer { undoManager.groupsByEvent = true }
                undoManager.beginUndoGrouping()
                model.setComment("hello,")
                undoManager.endUndoGrouping()
                #expect(document.isDocumentEdited)
                #expect(document.state.isEdited)
                // More typing joins that step: one undo takes it all back, and the document is clean again.
                model.setComment("hello, world")
                #expect(model.changes.comment == .set("hello, world"))
                #expect(undoManager.undoActionName == String(localized: "Edit Comment", table: "Shared"))
                undoManager.undo()
                #expect(model.changes.comment == .keep)
                #expect(!document.isDocumentEdited)
                #expect(!undoManager.canUndo)

                // Typing back to the archive's own comment leaves the document clean, with nothing to undo.
                undoManager.beginUndoGrouping()
                model.setComment("hello!")
                undoManager.endUndoGrouping()
                #expect(document.isDocumentEdited)
                model.setComment("hello")
                #expect(model.changes.comment == .keep)
                #expect(!document.isDocumentEdited)
                #expect(!document.state.isEdited)
                #expect(!undoManager.canUndo)
                #expect(!undoManager.canRedo)
            }
        }

        /// A comment Kernir won't write (too long, or holding a ZIP end-record signature) refuses the save with
        /// the field's message, before the engine: the file keeps its bytes and the document its edit.
        @Test(arguments: [String(repeating: "a", count: ArchiveComment.maximumWritableLength + 1), "x PK\u{5}\u{6} y"])
        func saveRefusedWhenTooLong(text: String) async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let original = try Data(contentsOf: archive)
            let fake = CommentFakeEngine(comment: Self.comment("hello"))
            try await withCommentEngine(fake) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                model.setComment(text)
                let problem = try #require(model.commentProblem)

                var saveError: (any Error)?
                do {
                    try await document.save(to: archive, ofType: "public.zip-archive", for: .saveOperation)
                } catch {
                    saveError = error
                }

                #expect(saveError?.localizedDescription == problem)
                #expect(fake.writes.isEmpty)
                #expect(try Data(contentsOf: archive) == original)
                #expect(document.model === model)
                #expect(model.changes.comment == .set(text))
                #expect(document.state.progress == nil)
            }
        }

        /// Save To a format without comments drops the comment edit, too long or not, instead of failing in the
        /// engine (which throws for `.set` there). The document stays the ZIP it was, its comment edit pending.
        @Test func saveToSevenZipDropsTheCommentEdit() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fake = CommentFakeEngine(comment: Self.comment("hello"))
            try await withCommentEngine(fake) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                model.setComment(String(repeating: "a", count: ArchiveComment.maximumWritableLength + 1))
                let destination = root.appendingPathComponent("b.7z")

                try await document.save(to: destination, ofType: KernirDocumentTypes.utType(for: .sevenZip).identifier,
                                        for: .saveToOperation)

                #expect(fake.writes.map(\.format) == [.sevenZip])
                #expect(fake.writes.first?.changes.comment == .keep)
                #expect(FileManager.default.fileExists(atPath: destination.path))
                #expect(document.model === model)
                #expect(model.changes.comment == .set(String(repeating: "a", count: ArchiveComment.maximumWritableLength + 1)))
                #expect(document.fileURL == archive)
            }
        }

        /// Save As 7z drops the comment edit too: the document becomes the written 7z, which has no comment, with
        /// nothing pending.
        @Test func saveAsSevenZipDropsTheCommentEdit() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fake = CommentFakeEngine(comment: Self.comment("hello"))
            try await withCommentEngine(fake) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                model.setComment("new")
                let destination = root.appendingPathComponent("b.7z")
                let sevenZip = KernirDocumentTypes.utType(for: .sevenZip).identifier

                try await document.save(to: destination, ofType: sevenZip, for: .saveAsOperation)

                #expect(fake.writes.map(\.format) == [.sevenZip])
                #expect(fake.writes.first?.changes.comment == .keep)
                #expect(document.fileURL?.standardizedFileURL == destination.standardizedFileURL)
                #expect(document.fileType == sevenZip)
                #expect(document.model?.format == .sevenZip)
                #expect(document.model?.changes.comment == .keep)
                #expect(document.model?.showsComment == false)
                #expect(!document.isDocumentEdited)
            }
        }

        /// The save panel says when the chosen format drops a comment the save would otherwise write: the edited
        /// one, else the source's. Nothing for an empty comment or a format that keeps it.
        @Test func savePanelNotesADroppedComment() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                _ = document.prepareSavePanel(NSSavePanel())
                let options = try #require(document.savePanelOptions)
                #expect(options.format == .zip)
                #expect(options.droppedCommentNote == nil)
                for format in [ArchiveFormat.sevenZip, .tar] {
                    options.format = format
                    #expect(options.droppedCommentNote
                            == String(localized: "\(format.displayName) archives can’t have a comment."))
                }

                // Removed in the Info popover: nothing to drop.
                model.setComment("")
                _ = document.prepareSavePanel(NSSavePanel())
                let removed = try #require(document.savePanelOptions)
                removed.format = .sevenZip
                #expect(removed.droppedCommentNote == nil)
            }
        }

        /// A split set can't hold a comment: with Split on, the save panel says so for the source's
        /// comment (which the split save drops) and for a typed one (which it refuses). Nothing for one file or
        /// a removed comment.
        @Test func savePanelNotesASplitSaveDropsTheComment() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                let splitNote = String(localized: "A split archive can’t have a comment.", table: "Shared")
                _ = document.prepareSavePanel(NSSavePanel())
                let kept = try #require(document.savePanelOptions)
                #expect(kept.droppedCommentNote == nil)
                kept.split = .preset(.mb25)
                #expect(kept.droppedCommentNote == splitNote)
                kept.split = .none
                #expect(kept.droppedCommentNote == nil)

                model.setComment("typed")
                _ = document.prepareSavePanel(NSSavePanel())
                let typed = try #require(document.savePanelOptions)
                typed.split = .preset(.mb25)
                #expect(typed.droppedCommentNote == splitNote)

                model.setComment("")
                _ = document.prepareSavePanel(NSSavePanel())
                let removed = try #require(document.savePanelOptions)
                removed.split = .preset(.mb25)
                #expect(removed.droppedCommentNote == nil)
            }
        }

        /// A split set can't hold a comment: a split save with a typed comment is refused with that
        /// message and writes nothing; a removed comment goes ahead, as `.keep`.
        @Test func splitSaveRefusesATypedComment() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fake = CommentFakeEngine(comment: Self.comment("hello"))
            try await withCommentEngine(fake) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                model.setComment("new")
                var settings = ArchiveSaveSettings(model: model)
                settings.split = .preset(.mb25)
                document.savePanelOptions = SavePanelOptions(settings: settings)
                let destination = root.appendingPathComponent("Photos")

                var saveError: (any Error)?
                do {
                    try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
                } catch {
                    saveError = error
                }

                #expect(saveError?.localizedDescription
                        == String(localized: "A split archive can’t have a comment.", table: "Shared"))
                #expect((saveError as NSError?)?.localizedRecoverySuggestion
                        == String(localized: "Remove the comment, or turn off splitting.", table: "Shared"))
                #expect(fake.volumeCalls == 0)
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(document.savePanelOptions == nil)
                #expect(model.changes.comment == .set("new"))
            }
        }

        /// A removed comment is no problem for a split save: every split save writes `.keep`, which writes no
        /// comment into a set, so the removal gets what it asks for and the set is written.
        @Test func splitSaveGoesAheadWithARemovedComment() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fake = CommentFakeEngine(comment: Self.comment("hello"))
            try await withCommentEngine(fake) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                model.setComment("")
                #expect(model.changes.comment == .remove)
                var settings = ArchiveSaveSettings(model: model)
                settings.split = .preset(.mb25)
                document.savePanelOptions = SavePanelOptions(settings: settings)
                let destination = root.appendingPathComponent("Photos")

                var saveError: (any Error)?
                do {
                    try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
                } catch {
                    saveError = error
                }

                #expect(fake.volumeCalls == 1)
                #expect(saveError?.localizedDescription
                        != String(localized: "A split archive can’t have a comment.", table: "Shared"))
            }
        }

        /// No comment field for a split set: its comment shows read-only, saying why. A comment the reader can't
        /// write back shows read-only with the general note; an editable one has none.
        @Test func commentFieldDisabledForSplit() async throws {
            let (root, archive) = try makeInfoRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"), volumeSet: true)) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                #expect(model.showsComment)
                #expect(!model.canEditComment)
                #expect(ArchiveInfoView.readOnlyNote(for: model)
                        == String(localized: "The comment of a split archive can’t be changed."))
            }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello", isWritable: false))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                #expect(!model.canEditComment)
                #expect(ArchiveInfoView.readOnlyNote(for: model)
                        == String(localized: "This comment can’t be changed in Lutik."))
            }
            try await withCommentEngine(CommentFakeEngine(comment: Self.comment("hello"))) {
                let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
                let model = try #require(document.model)
                #expect(model.canEditComment)
                #expect(ArchiveInfoView.readOnlyNote(for: model) == nil)
            }
        }

        /// A comment of `count` lines.
        private static func lines(_ count: Int) -> String {
            (1...count).map { "line \($0)" }.joined(separator: "\n")
        }

        /// The Info view with `comment` editable, hosted offscreen at its fitting size.
        private static func hostedInfoView(comment: Binding<String>) -> NSHostingView<ArchiveInfoView> {
            let summary = ArchiveInfoSummary(format: .zip, itemCount: 3, size: 10, compressedSize: 8, fileSize: 12,
                                             encryption: .none)
            let view = NSHostingView(rootView: ArchiveInfoView(summary: summary, comment: comment, showsComment: true,
                                                               canEditComment: true, readOnlyNote: nil,
                                                               commentProblem: nil))
            view.frame.size = view.fittingSize
            view.layoutSubtreeIfNeeded()
            return view
        }

        /// The editable comment field grows with its text from 4 lines to 12, then scrolls (as `TextEditor` did in
        /// the grouped form). With `KERNIR_INFO_SNAPSHOTS` set, writes the hosted view as PNGs into the (sandboxed)
        /// temporary folder, for a look.
        @Test(arguments: [1, 8, 30])
        func commentFieldGrowsThenScrolls(lineCount: Int) throws {
            let view = Self.hostedInfoView(comment: .constant(Self.lines(lineCount)))
            let textView = try #require(Self.textView(in: view))
            let scrollView = try #require(textView.enclosingScrollView)
            let height = scrollView.frame.height
            let lineHeight = ArchiveInfoView.lineHeight
            switch lineCount {
            case 1:
                #expect(height == lineHeight * 4)
            case 8:
                #expect(height > lineHeight * 4 && height < lineHeight * 12)
                #expect(abs(height - lineHeight * 8) <= 1)
                #expect(textView.frame.height <= scrollView.contentView.bounds.height + 1)
            default:
                #expect(height == lineHeight * 12)
                #expect(textView.frame.height > scrollView.contentView.bounds.height)
            }
            #expect(textView.frame.height >= scrollView.contentView.bounds.height)
            try Self.snapshot(view, named: "info-\(lineCount)-lines")
        }

        /// A comment ending in blank lines gets whole lines for them: the empty line after the last newline
        /// would measure at the default font's (smaller) height and leave the field short of its text.
        @Test(arguments: [2, 3])
        func commentFieldFitsTrailingBlankLines(newlines: Int) throws {
            let view = Self.hostedInfoView(comment: .constant(Self.lines(6) + String(repeating: "\n", count: newlines)))
            let textView = try #require(Self.textView(in: view))
            let scrollView = try #require(textView.enclosingScrollView)
            #expect(scrollView.frame.height == ArchiveInfoView.lineHeight * CGFloat(6 + newlines))
            #expect(textView.frame.height <= scrollView.contentView.bounds.height + 1)
            try Self.snapshot(view, named: "info-6-lines-\(newlines)-newlines")
        }

        /// An outside change of the comment (an undo, a save's snapshot) resizes the field too. Observed, as the
        /// model's comment is: SwiftUI updates the field on a later pass.
        @Test func commentFieldGrowsWithAnOutsideChange() async throws {
            let text = ObservedBox(Self.lines(1))
            let comment = Binding(get: { text.value }, set: { text.value = $0 })
            let view = Self.hostedInfoView(comment: comment)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = view
            let textView = try #require(Self.textView(in: view))
            let scrollView = try #require(textView.enclosingScrollView)
            let before = view.fittingSize.height
            #expect(scrollView.frame.height == ArchiveInfoView.lineHeight * 4)
            text.value = Self.lines(8)
            try await waitUntil { textView.string == text.value }
            try await waitUntil {
                view.layoutSubtreeIfNeeded()
                return abs(scrollView.frame.height - ArchiveInfoView.lineHeight * 8) <= 1
            }
            #expect(view.fittingSize.height > before)
        }

        /// With `KERNIR_INFO_SNAPSHOTS` set, writes `view` as `name`.png into the (sandboxed) temporary folder.
        private static func snapshot(_ view: NSView, named name: String) throws {
            guard ProcessInfo.processInfo.environment["KERNIR_INFO_SNAPSHOTS"] != nil else { return }
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveInfoSnapshots")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent(name + ".png"))
        }

        /// Typing new lines grows the field as it goes: SwiftUI asks for its size again.
        @Test func commentFieldGrowsAsItsTextChanges() throws {
            let text = Box("a")
            let view = Self.hostedInfoView(comment: Binding(get: { text.value }, set: { text.value = $0 }))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = view
            let textView = try #require(Self.textView(in: view))
            let scrollView = try #require(textView.enclosingScrollView)
            let before = view.fittingSize.height
            #expect(scrollView.frame.height == ArchiveInfoView.lineHeight * 4)
            textView.setSelectedRange(NSRange(location: 1, length: 0))
            for _ in 0..<7 {
                textView.insertText("\nmore", replacementRange: textView.selectedRange())
            }
            #expect(text.value == "a" + String(repeating: "\nmore", count: 7))
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.height > before)
            #expect(abs(scrollView.frame.height - ArchiveInfoView.lineHeight * 8) <= 1)
        }

        /// Text the input method is still composing (marked text) stays out of the comment; committing it brings
        /// it in.
        @Test func commentFieldTakesMarkedTextOnlyWhenCommitted() throws {
            let text = Box("a")
            let view = Self.hostedInfoView(comment: Binding(get: { text.value }, set: { text.value = $0 }))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = view
            let textView = try #require(Self.textView(in: view))
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 1, length: 0))
            let none = NSRange(location: NSNotFound, length: 0)
            textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            textView.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
            #expect(textView.hasMarkedText())
            #expect(text.value == "a")
            textView.unmarkText()
            #expect(text.value == "aka")
            textView.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            #expect(text.value == "aka")
            textView.insertText("y", replacementRange: none)
            #expect(text.value == "akay")
        }

        /// VoiceOver (and UI tests) find the editable comment's text view by its label; Writing Tools may only
        /// suggest (the field has no undo of its own to take a rewrite back).
        @Test func commentFieldTextViewIsLabelledAndLimitsWritingTools() throws {
            let view = Self.hostedInfoView(comment: .constant("hello"))
            let textView = try #require(Self.textView(in: view))
            #expect(textView.accessibilityLabel() == String(localized: "Comment"))
            #expect(!textView.allowsUndo)
            if #available(macOS 15.0, *) {
                #expect(textView.writingToolsBehavior == .limited)
            }
        }

        /// A reference for a test binding's value.
        private final class Box {
            var value: String
            init(_ value: String) { self.value = value }
        }

        /// An observed reference for a test binding's value, as the model's comment is.
        @Observable final class ObservedBox {
            var value: String
            init(_ value: String) { self.value = value }
        }
    }
}
