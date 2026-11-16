import AppKit
import Observation
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore

/// ⌘C / ⌘X / ⌘V on the archive window's rows (`ArchiveActions+Clipboard.swift`) over a real ZIP
/// (`LegacyZip`: each file holds its own path). Every test uses a named pasteboard of its own (released at the
/// end, never the general one), its own temporary folder for Copy's exports, and a TestDefaults suite. No
/// window: refusals have no alert, and the replace question is answered through `mover.confirmReplace`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ArchiveActionsClipboardTests {
    /// A test device token, so staging never reads or writes the standard defaults (`.system` does).
    private static let testDeviceToken = "c1b0c1b0c1b0c1b1"
    private static let foldsCase = DestinationCaseSensitivity(exists: { _ in true },
                                                              supportsCaseSensitiveNames: { _ in false })
    private static let itemType = NSPasteboard.PasteboardType(ArchiveClipboard.typeIdentifier)

    private static let paths = ["README", "docs/", "docs/a.txt", "other/", "other/README"]

    /// One test's world; `close()` removes its folders, temporary files, pasteboard and defaults suite.
    @MainActor private struct Opened {
        let directory: URL
        let temporary: URL
        let model: ArchiveModel
        let document: ArchiveDocument
        let actions: ArchiveActions
        let undoManager: UndoManager
        let pasteboard: NSPasteboard
        let defaults: UserDefaults
        let suite: String

        var state: ArchiveWindowState { document.state }

        func close() {
            model.removeTemporaryFiles()
            ArchiveClipboard.removeAllExports(in: temporary)
            pasteboard.releaseGlobally()
            removeTestDefaults(defaults, suite: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        /// Copy's export folders in this test's temporary folder (in this process's parent there).
        func exportFolders() throws -> [String] {
            let parent = ArchiveClipboard.exportParent(in: temporary)
            guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: parent.path)
        }

        func clipboard() -> ArchiveClipboard? {
            pasteboard.data(forType: ArchiveActionsClipboardTests.itemType).flatMap(ArchiveClipboard.decoded)
        }

        func fileURLs() -> [URL] {
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
                .compactMap { $0 as? URL } ?? []
        }

        /// One event's undo group (the manager doesn't group by event: a registration outside a group raises).
        func step<T>(_ body: () throws -> T) rethrows -> T {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            return try body()
        }
    }

    private func open(_ paths: [String] = paths) async throws -> Opened {
        let (defaults, suite) = makeTestDefaults("ArchiveActionsClipboardTests")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveActionsClipboardTests-\(UUID().uuidString)", isDirectory: true)
        let temporary = directory.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let zipURL = try LegacyZip.write(paths, as: .utf8)
        let zip = directory.appendingPathComponent("source.zip")
        try FileManager.default.moveItem(at: zipURL, to: zip)
        try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent())
        let document = try ArchiveDocument(type: "public.zip-archive")
        let undoManager = try #require(document.undoManager)
        let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: undoManager)
        model.nameEncodingStore = ArchiveNameEncodingStore(defaults: defaults)
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: Self.testDeviceToken) { from, to, flags in
            renamex_np(from, to, flags) == 0 ? 0 : errno
        }
        model.caseSensitivity = Self.foldsCase
        document.state.model = model
        let actions = ArchiveActions(document: document)
        document.actions = actions
        let pasteboard = NSPasteboard(name: .init("ArchiveActionsClipboardTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        actions.pasteboard = pasteboard
        actions.clipboardTemporaryDirectory = temporary
        return Opened(directory: directory, temporary: temporary, model: model, document: document,
                      actions: actions, undoManager: undoManager, pasteboard: pasteboard, defaults: defaults,
                      suite: suite)
    }

    /// Plain files standing for Finder's, in the test's folder.
    private func finderFiles(_ names: [String], in opened: Opened) throws -> [URL] {
        let folder = opened.directory.appendingPathComponent("finder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try names.map { name in
            let url = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
    }

    private func text(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - Copy and Cut

    @Test func copyWritesTheCopiesFileURLsAndTheItem() async throws {
        let opened = try await open()
        defer { opened.close() }
        #expect(!opened.actions.canPaste)
        opened.state.selection = ["README", "docs"]
        #expect(opened.actions.canCopy)

        let task = try #require(opened.actions.copySelection())
        // The progress sheet is up while it extracts: a second Copy can't start.
        #expect(opened.state.progress?.title == ArchiveClipboard.progressTitle)
        #expect(!opened.actions.canCopy && opened.actions.copySelection() == nil)
        await task.value

        #expect(opened.state.progress == nil)
        let urls = opened.fileURLs()
        #expect(Set(urls.map(\.lastPathComponent)) == ["README", "docs"])
        #expect(try text(try #require(urls.first { $0.lastPathComponent == "README" })) == "README")
        #expect(try opened.exportFolders().count == 1)
        let clipboard = try #require(opened.clipboard())
        #expect(clipboard.operation == .copy)
        #expect(clipboard.source == opened.actions.clipboardSource)
        #expect(Set(clipboard.paths) == ["README", "docs"])
        #expect(opened.actions.canPaste)

        // A second Copy keeps the first one's folder: a pending addition may still read it at save.
        opened.state.selection = ["other/README"]
        await opened.actions.copySelection()?.value
        #expect(try opened.exportFolders().count == 2)
        #expect(opened.fileURLs().map(\.lastPathComponent) == ["README"])
        #expect(opened.clipboard()?.paths == ["other/README"])
    }

    @Test func cutWritesTheItemOnly() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README"]
        #expect(opened.actions.canCut)
        opened.actions.cutSelection()

        #expect(opened.pasteboard.types?.contains(Self.itemType) == true)
        #expect(opened.pasteboard.types?.contains(.fileURL) == false)
        #expect(opened.fileURLs().isEmpty)
        let clipboard = try #require(opened.clipboard())
        #expect(clipboard.operation == .cut)
        #expect(clipboard.source == opened.actions.clipboardSource)
        #expect(clipboard.paths == ["README"])
        #expect(try opened.exportFolders().isEmpty)
        #expect(opened.actions.canPaste)
    }

    // MARK: - Edit > Cut and Copy

    /// A focused field's editor that records Cut and Copy instead of writing the general pasteboard. With
    /// `enablesCutAndCopyWithoutSelection` it enables cut: and copy: with only the caret, as a text view may.
    private final class RecordingTextView: NSTextView {
        var cuts = 0
        var copies = 0
        /// Cut and Copy on with only the caret, as a text view may have copy:.
        var enablesCutAndCopyWithoutSelection = false
        override func cut(_ sender: Any?) { cuts += 1 }
        override func copy(_ sender: Any?) { copies += 1 }
        override func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if enablesCutAndCopyWithoutSelection, [#selector(cut(_:)), #selector(copy(_:))].contains(item.action) {
                return true
            }
            return super.validateMenuItem(item)
        }
    }

    /// Stands for the rows (the table in the hosting view) as first responder: it answers no cut: or copy:.
    private final class RowsFocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// The archive window over `opened` (its actions on the test's pasteboard and temporary folder), key (a
    /// hosted test's window never is), its standard Cut and Copy found from its own first responder on.
    private func windowController(for opened: Opened) throws -> ArchiveWindowController {
        let controller = ArchiveWindowController(document: opened.document, windowFrame: nil)
        let actions = try #require(opened.document.actions)
        actions.pasteboard = opened.pasteboard
        actions.clipboardTemporaryDirectory = opened.temporary
        let window = try #require(controller.window)
        controller.keyWindow = { window }
        controller.standardEdit.target = Self.chain(of: window)
        return controller
    }

    /// The first responder in `window`'s chain, from its first responder on, that answers an action: AppKit's
    /// `target(forAction:to:from:)` for a key window, which a hosted test's window never is.
    private static func chain(of window: NSWindow) -> @MainActor (Selector, Any?) -> AnyObject? {
        { [weak window] action, _ in
            var responder = window?.firstResponder
            while let current = responder {
                if current.responds(to: action) { return current }
                responder = current.nextResponder
            }
            return nil
        }
    }

    /// A plain window standing for another one of the app's (Settings, the About panel, the preview, a sheet).
    private func otherWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// `view` in `window`'s content, made its first responder.
    private func focus(_ view: NSView, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        content.addSubview(view)
        try #require(window.makeFirstResponder(view))
        try #require(window.firstResponder === view)
    }

    /// A text view holding "abc def" with "bc" selected, the focus of `window`.
    private func focusedText(in window: NSWindow) throws -> RecordingTextView {
        let text = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        text.string = "abc def"
        try focus(text, in: window)
        text.setSelectedRange(NSRange(location: 1, length: 2))
        return text
    }

    /// `sheet` attached to `window`, ordered in far off screen first (a hidden window takes no sheet); the caller
    /// ends both (`detach`).
    private func attach(_ sheet: NSWindow, to window: NSWindow) async throws {
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.beginSheet(sheet, completionHandler: nil)
        for _ in 0..<200 where window.attachedSheet !== sheet { try await Task.sleep(for: .milliseconds(10)) }
        try #require(window.attachedSheet === sheet)
    }

    private func detach(_ sheet: NSWindow, from window: NSWindow) {
        if window.attachedSheet === sheet { window.endSheet(sheet) }
        sheet.orderOut(nil)
        window.orderOut(nil)
    }

    /// Neither Copy nor Cut reached the rows: no progress, the test's pasteboard as it was.
    private func expectRowsUntouched(_ opened: Opened, changeCount: Int,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(opened.state.progress == nil, sourceLocation: sourceLocation)
        #expect(opened.pasteboard.changeCount == changeCount, sourceLocation: sourceLocation)
        #expect(opened.clipboard() == nil, sourceLocation: sourceLocation)
        #expect(opened.fileURLs().isEmpty, sourceLocation: sourceLocation)
    }

    private static let copyItem = NSMenuItem(title: "Copy", action: #selector(ArchiveWindowController.copySelection(_:)),
                                             keyEquivalent: "")
    private static let cutItem = NSMenuItem(title: "Cut", action: #selector(ArchiveWindowController.cutSelection(_:)),
                                            keyEquivalent: "")

    /// ⌘C and ⌘X are the archive window's, not SwiftUI's `onCopyCommand`, which empties the pasteboard before a
    /// Copy's export ends.
    @Test func editMenuCutAndCopyGoToTheArchiveWindow() {
        let items = MainMenu.editMenu().items
        #expect(items.first { $0.keyEquivalent == "x" }?.action == #selector(ArchiveWindowController.cutSelection(_:)))
        #expect(items.first { $0.keyEquivalent == "c" }?.action == #selector(ArchiveWindowController.copySelection(_:)))
    }

    /// In the key archive window with the rows (or nothing: the window itself) as first responder, Edit > Cut
    /// and Copy take the selected rows, enabled as `canCut` / `canCopy`.
    @Test func editMenuCutAndCopyTakeTheRowsOutsideText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        // Nothing has the focus: the window itself is first responder.
        window.makeFirstResponder(nil)
        try #require(window.firstResponder === window)
        opened.state.selection = ["README"]
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))

        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: window)
        opened.state.selection = []
        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        opened.state.selection = ["README"]
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))

        controller.cutSelection(nil)
        #expect(opened.clipboard()?.operation == .cut)

        controller.copySelection(nil)
        #expect(opened.state.progress?.title == ArchiveClipboard.progressTitle)
        #expect(!controller.validateMenuItem(Self.copyItem))
        for _ in 0..<500 where opened.state.progress != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened.clipboard()?.operation == .copy)
        #expect(opened.fileURLs().map(\.lastPathComponent) == ["README"])
    }

    /// In focused text of the archive window (a name, the comment) Edit > Cut and Copy are the text's own cut:
    /// and copy:, as the text validates them; the rows stay off the pasteboard.
    @Test func editMenuCutAndCopyGoToFocusedText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let text = try focusedText(in: window)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        text.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        text.setSelectedRange(NSRange(location: 1, length: 2))
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        text.isEditable = false
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))

        controller.copySelection(nil)
        controller.cutSelection(nil)
        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        expectRowsUntouched(opened, changeCount: changeCount)
    }

    /// Only the caret in editable text of the archive window (a name, the search), though the text enables its
    /// cut: and copy: there: Edit > Cut and Copy are off and do nothing, neither the text's (empty text on the
    /// pasteboard) nor the rows'. The same through the app delegate (no archive window key or main), and for the
    /// standard command itself; selectable text that isn't editable keeps its own.
    @Test func editMenuCutAndCopyDoNothingWithOnlyTheCaretInEditableText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let text = try focusedText(in: window)
        text.enablesCutAndCopyWithoutSelection = true
        text.setSelectedRange(NSRange(location: 1, length: 0))
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        controller.cutSelection(nil)
        #expect(text.copies == 0)
        #expect(text.cuts == 0)
        expectRowsUntouched(opened, changeCount: changeCount)

        let delegate = AppDelegate()
        delegate.standardEdit.target = Self.chain(of: window)
        #expect(!delegate.validateMenuItem(Self.copyItem))
        #expect(!delegate.validateMenuItem(Self.cutItem))
        delegate.copySelection(nil)
        delegate.cutSelection(nil)
        #expect(text.copies == 0)
        #expect(text.cuts == 0)

        #expect(StandardEditCommand.isCaretOnlyInEditableText(text))
        #expect(!StandardEditCommand.isCaretOnlyInEditableText(nil))
        #expect(!StandardEditCommand.isCaretOnlyInEditableText(window))
        text.isEditable = false
        #expect(!StandardEditCommand.isCaretOnlyInEditableText(text))
        #expect(controller.standardEdit.validate(#selector(NSText.copy(_:)), for: nil))
        controller.standardEdit.send(#selector(NSText.copy(_:)), from: nil)
        #expect(text.copies == 1)
        text.isEditable = true
        text.setSelectedRange(NSRange(location: 1, length: 2))
        #expect(!StandardEditCommand.isCaretOnlyInEditableText(text))
        expectRowsUntouched(opened, changeCount: changeCount)
    }

    /// Another window key (Settings, the preview, the About panel) with text focused: Edit > Cut and Copy are
    /// that text's, enabled as it validates them, though the archive window's rows are focused and selected.
    @Test func editMenuCutAndCopyGoToAnotherKeyWindowsText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: window)
        let other = otherWindow()
        defer { other.orderOut(nil) }
        let text = try focusedText(in: other)
        controller.keyWindow = { other }
        controller.standardEdit.target = Self.chain(of: other)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        controller.cutSelection(nil)

        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        expectRowsUntouched(opened, changeCount: changeCount)
    }

    /// Another window key where nothing answers cut: or copy: (no text focused): Edit > Cut and Copy are off,
    /// and sent anyway they do nothing; the archive window's selected rows stay off the pasteboard.
    @Test func editMenuCutAndCopyAreOffInAnotherWindowWithoutText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: window)
        let other = otherWindow()
        defer { other.orderOut(nil) }
        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: other)
        controller.keyWindow = { other }
        controller.standardEdit.target = Self.chain(of: other)
        opened.state.selection = ["README"]
        let actions = try #require(opened.document.actions)
        #expect(actions.canCopy && actions.canCut)
        let changeCount = opened.pasteboard.changeCount

        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        controller.cutSelection(nil)

        expectRowsUntouched(opened, changeCount: changeCount)
    }

    /// The archive window's preview window key, the archive window main (as the preview leaves it out of full
    /// screen), nothing there with a Cut or Copy of its own: Edit > Cut and Copy take the archive window's rows,
    /// enabled as `canCut` / `canCopy`, as on main. Off while another window is main.
    @Test func editMenuCutAndCopyInThePreviewWindowWithoutTextTakeTheRows() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let preview = otherWindow()
        defer { preview.orderOut(nil) }
        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: preview)
        controller.keyWindow = { preview }
        controller.isPreviewWindow = { $0 === preview }
        controller.standardEdit.target = Self.chain(of: preview)
        opened.state.selection = ["README"]

        controller.mainWindow = { nil }
        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        controller.mainWindow = { window }
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        opened.state.selection = []
        #expect(!controller.validateMenuItem(Self.copyItem))
        opened.state.selection = ["README"]

        controller.cutSelection(nil)
        #expect(opened.clipboard()?.operation == .cut)
        controller.copySelection(nil)
        #expect(opened.state.progress?.title == ArchiveClipboard.progressTitle)
        for _ in 0..<500 where opened.state.progress != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened.clipboard()?.operation == .copy)
        #expect(opened.fileURLs().map(\.lastPathComponent) == ["README"])
    }

    /// The preview window key with selected text: Edit > Cut and Copy are that text's, the rows stay off the
    /// pasteboard. With only the caret in editable text they are off and do nothing; in selectable
    /// text that isn't editable (a preview's) they are the rows' again, of a text-like item too, whatever the text
    /// answers to copy: (r3 gate).
    @Test func editMenuCutAndCopyInThePreviewWindowGoToItsSelectedText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let preview = otherWindow()
        defer { preview.orderOut(nil) }
        let text = try focusedText(in: preview)
        controller.keyWindow = { preview }
        controller.mainWindow = { window }
        controller.isPreviewWindow = { $0 === preview }
        controller.standardEdit.target = Self.chain(of: preview)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        controller.cutSelection(nil)
        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        expectRowsUntouched(opened, changeCount: changeCount)

        text.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        controller.cutSelection(nil)
        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        expectRowsUntouched(opened, changeCount: changeCount)

        text.isEditable = false
        text.enablesCutAndCopyWithoutSelection = true
        controller.previewedContentType = { .plainText }
        try #require(text.selectedRange == NSRange(location: 1, length: 0))
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.cutSelection(nil)
        #expect(text.cuts == 1)
        #expect(opened.clipboard()?.operation == .cut)
    }

    /// Stands for the Quick Look preview: it answers copy: and enables it as `enablesCopy` says (an image's or a
    /// page's with nothing selected, a text's with its out-of-process selection); it records a Copy instead of
    /// writing the general pasteboard.
    private final class PreviewContentView: NSView {
        var copies = 0
        var enablesCopy = true
        override var acceptsFirstResponder: Bool { true }
        @objc func copy(_ sender: Any?) { copies += 1 }
        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { enablesCopy }
    }

    /// A PDF view whose selection is the test's own and that records a Copy instead of writing the general
    /// pasteboard.
    private final class RecordingPDFView: PDFView {
        var copies = 0
        private var selection: PDFSelection?
        override var currentSelection: PDFSelection? {
            get { selection }
            set { selection = newValue }
        }
        override func copy(_ sender: Any?) { copies += 1 }
    }

    /// A one-page PDF that reads "Kernir PDF text", and "Kernir" selected on it.
    private func pdfTextSelection() throws -> (PDFDocument, PDFSelection) {
        let label = NSTextField(labelWithString: "Kernir PDF text")
        label.frame = NSRect(x: 0, y: 0, width: 240, height: 30)
        let document = try #require(PDFDocument(data: label.dataWithPDF(inside: label.bounds)))
        let selection = try #require(document.findString("Kernir", withOptions: []).first)
        try #require(selection.string == "Kernir")
        return (document, selection)
    }

    /// The preview window key, the archive window main, the preview of an image enabling copy: with no text
    /// selected: Edit > Copy takes the rows, not the image.
    @Test func editMenuCopyInTheImagePreviewTakesTheRowsOverItsEnabledCopy() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let preview = otherWindow()
        defer { preview.orderOut(nil) }
        let content = PreviewContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        try focus(content, in: preview)
        controller.keyWindow = { preview }
        controller.mainWindow = { window }
        controller.isPreviewWindow = { $0 === preview }
        controller.previewedContentType = { .png }
        controller.standardEdit.target = Self.chain(of: preview)
        try #require(controller.standardEdit.validate(#selector(NSText.copy(_:)), for: nil))
        opened.state.selection = ["README"]

        #expect(controller.validateMenuItem(Self.copyItem))
        controller.copySelection(nil)
        #expect(content.copies == 0)
        #expect(opened.state.progress?.title == ArchiveClipboard.progressTitle)
        for _ in 0..<500 where opened.state.progress != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened.clipboard()?.operation == .copy)
        #expect(opened.fileURLs().map(\.lastPathComponent) == ["README"])
    }

    /// The preview window key showing a text-like item (text, PDF, HTML, source) whose Quick Look view
    /// enables copy: (its text selection is out of process, so it can't be seen here): Edit > Copy and Cut are the
    /// preview's; with copy: off there they are the rows' again.
    @Test func editMenuCopyInATextPreviewGoesToItsEnabledCopy() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let preview = otherWindow()
        defer { preview.orderOut(nil) }
        let content = PreviewContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        try focus(content, in: preview)
        controller.keyWindow = { preview }
        controller.mainWindow = { window }
        controller.isPreviewWindow = { $0 === preview }
        controller.previewedContentType = { .plainText }
        controller.standardEdit.target = Self.chain(of: preview)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        #expect(controller.validateMenuItem(Self.copyItem))
        controller.copySelection(nil)
        #expect(content.copies == 1)
        expectRowsUntouched(opened, changeCount: changeCount)
        for type in [UTType.pdf, .html, .rtf, .swiftSource] {
            controller.previewedContentType = { type }
            controller.copySelection(nil)
        }
        #expect(content.copies == 5)
        expectRowsUntouched(opened, changeCount: changeCount)

        controller.previewedContentType = { .plainText }
        content.enablesCopy = false
        #expect(controller.validateMenuItem(Self.copyItem))
        controller.copySelection(nil)
        #expect(content.copies == 5)
        #expect(opened.state.progress?.title == ArchiveClipboard.progressTitle)
        for _ in 0..<500 where opened.state.progress != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened.clipboard()?.operation == .copy)
        #expect(opened.fileURLs().map(\.lastPathComponent) == ["README"])

        // Cut: Quick Look's view has no cut:, so with copy: on or off there Edit > Cut is the rows'.
        content.enablesCopy = true
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.cutSelection(nil)
        #expect(content.copies == 5)
        #expect(opened.clipboard()?.operation == .cut)
    }

    /// Which previewed items have no text to select, so the preview's copy: never counts: images, movies, sounds,
    /// archives, folders, unknown binary data (exactly `.data`) and nothing shown (the index sheet); never text, PDF,
    /// HTML, RTF(D) or source, though most of them conform to `.data`.
    @Test func previewHasNoTextForImagesMediaArchivesAndFolders() throws {
        for type in [UTType.png, .jpeg, .heic, .svg, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .zip, .gzip, .folder,
                     .data] {
            #expect(ArchiveWindowController.previewHasNoText(type), "\(type.identifier)")
        }
        #expect(ArchiveWindowController.previewHasNoText(nil))
        for type in [UTType.plainText, .utf8PlainText, .pdf, .html, .rtf, .rtfd, .swiftSource, .json] {
            #expect(!ArchiveWindowController.previewHasNoText(type), "\(type.identifier)")
        }
        let markdown = try #require(UTType(filenameExtension: "md"))
        #expect(!ArchiveWindowController.previewHasNoText(markdown))
    }

    /// A preview item's type is its shown file's: a folder on disk as a folder, else by its extension, `.data` when
    /// that tells nothing.
    @Test func previewItemTypeIsTheShownFilesType() {
        let missing = URL(fileURLWithPath: "/nonexistent-kernir-test")
        #expect(PreviewItem.contentType(of: FileManager.default.temporaryDirectory).conforms(to: .folder))
        #expect(PreviewItem.contentType(of: missing.appendingPathComponent("page.png")) == .png)
        #expect(PreviewItem.contentType(of: missing.appendingPathComponent("hello.txt")) == .plainText)
        #expect(PreviewItem.contentType(of: missing.appendingPathComponent("noextension")) == .data)
    }

    /// A shown file that is a link has its target's type, not a link's.
    @Test func previewItemTypeOfALinkIsItsTargets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kernir-preview-type-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("page.png")
        try Data().write(to: target)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(PreviewItem.contentType(of: link) == .png)
    }

    /// The preview window key with a PDF's text selected (the focus a view inside the PDF view): Edit > Copy is
    /// the PDF view's; with nothing selected there, Cut and Copy are the rows' again, though the PDF view enables
    /// copy: then too (r3 gate).
    @Test func editMenuCutAndCopyInThePreviewWindowGoToAPDFsSelectedText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let preview = otherWindow()
        defer { preview.orderOut(nil) }
        let (document, selection) = try pdfTextSelection()
        let pdf = RecordingPDFView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        pdf.document = document
        // Stands for the page view inside the PDF view, which takes the focus.
        let page = RowsFocusView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let previewContent = try #require(preview.contentView)
        previewContent.addSubview(pdf)
        pdf.addSubview(page)
        try #require(preview.makeFirstResponder(page))
        controller.keyWindow = { preview }
        controller.mainWindow = { window }
        controller.isPreviewWindow = { $0 === preview }
        controller.previewedContentType = { .pdf }
        controller.standardEdit.target = Self.chain(of: preview)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        pdf.currentSelection = selection
        controller.copySelection(nil)
        #expect(pdf.copies == 1)
        expectRowsUntouched(opened, changeCount: changeCount)

        pdf.currentSelection = nil
        try #require(controller.standardEdit.validate(#selector(NSText.copy(_:)), for: nil),
                     "the PDF view's copy: is off with nothing selected (no longer the case shown here)")
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.cutSelection(nil)
        #expect(pdf.copies == 1)
        #expect(opened.clipboard()?.operation == .cut)
    }

    /// Selected text is looked for at the focus and the views that hold it, never below it: an `NSText` with a
    /// non-empty selection, a `PDFView` whose selection has text, false with none there; a window, nil or other
    /// views aren't such text (nil).
    @Test func selectedTextIsFoundFromTheFocusUp() throws {
        #expect(ArchiveWindowController.textSelection(from: nil) == nil)
        #expect(ArchiveWindowController.textSelection(from: otherWindow()) == nil)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        text.string = "abc def"
        holder.addSubview(text)
        text.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(ArchiveWindowController.textSelection(from: text) == false)
        text.setSelectedRange(NSRange(location: 1, length: 2))
        #expect(ArchiveWindowController.textSelection(from: text) == true)
        #expect(ArchiveWindowController.textSelection(from: holder) == nil)

        let (document, selection) = try pdfTextSelection()
        let pdf = RecordingPDFView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        pdf.document = document
        let inner = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        pdf.addSubview(inner)
        #expect(ArchiveWindowController.textSelection(from: inner) == false)
        pdf.currentSelection = selection
        #expect(ArchiveWindowController.textSelection(from: inner) == true)
        #expect(ArchiveWindowController.textSelection(from: pdf) == true)
    }

    /// Copy is off while a name field shows, as Cut: with the preview window key and the rows the
    /// target, and with the archive window key, its rows the focus.
    @Test func editMenuCopyIsOffWhileARowIsRenamed() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let preview = otherWindow()
        defer { preview.orderOut(nil) }
        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: preview)
        controller.keyWindow = { preview }
        controller.mainWindow = { window }
        controller.isPreviewWindow = { $0 === preview }
        controller.standardEdit.target = Self.chain(of: preview)
        opened.state.selection = ["README"]
        #expect(controller.validateMenuItem(Self.copyItem))

        opened.state.renamingPath = "README"
        let changeCount = opened.pasteboard.changeCount
        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        expectRowsUntouched(opened, changeCount: changeCount)

        opened.state.renamingPath = nil
        #expect(controller.validateMenuItem(Self.copyItem))

        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: window)
        controller.keyWindow = { window }
        controller.standardEdit.target = Self.chain(of: window)
        #expect(controller.validateMenuItem(Self.copyItem))
        opened.state.renamingPath = "README"
        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        expectRowsUntouched(opened, changeCount: changeCount)
        opened.state.renamingPath = nil
        #expect(controller.validateMenuItem(Self.copyItem))
    }

    /// A child window of the archive window key (the Info popover's), the archive window main, nothing there
    /// with a Cut or Copy of its own: Edit > Cut and Copy are the rows'. Not for a window that isn't its child.
    @Test func editMenuCutAndCopyInAChildWindowWithoutTextTakeTheRows() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        let child = otherWindow()
        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: child)
        controller.keyWindow = { child }
        controller.mainWindow = { window }
        controller.standardEdit.target = Self.chain(of: child)
        opened.state.selection = ["README"]
        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))

        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        child.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.addChildWindow(child, ordered: .above)
        defer {
            window.removeChildWindow(child)
            child.orderOut(nil)
            window.orderOut(nil)
        }
        try #require(child.parent === window)
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.cutSelection(nil)
        #expect(opened.clipboard()?.operation == .cut)
    }

    /// A child window of the archive window key (the Info popover's) whose focus enables copy: with no text
    /// selected: unlike the preview window, Edit > Copy is that focus's own; the rows stay off the pasteboard.
    @Test func editMenuCopyInAChildWindowGoesToItsEnabledCopy() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        let child = otherWindow()
        let content = PreviewContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        try focus(content, in: child)
        controller.keyWindow = { child }
        controller.mainWindow = { window }
        controller.standardEdit.target = Self.chain(of: child)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        child.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.addChildWindow(child, ordered: .above)
        defer {
            window.removeChildWindow(child)
            child.orderOut(nil)
            window.orderOut(nil)
        }
        try #require(child.parent === window)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        #expect(controller.validateMenuItem(Self.copyItem))
        controller.copySelection(nil)
        #expect(content.copies == 1)
        expectRowsUntouched(opened, changeCount: changeCount)
    }

    /// A child window of the archive window key (the Info popover's) with the focus in a text view: with text
    /// selected Edit > Copy and Cut are the text view's; with only the caret in editable text (the comment), though
    /// the text view enables its cut: and copy: there, they are off and do nothing (neither empty text nor the rows
    /// on the pasteboard); with only the caret in selectable text that isn't editable (a read-only archive's
    /// comment), they are the rows'.
    @Test func editMenuCutAndCopyInAChildWindowsTextDoNothingWithOnlyTheCaretInEditableText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        let child = otherWindow()
        let text = try focusedText(in: child)
        text.enablesCutAndCopyWithoutSelection = true
        controller.keyWindow = { child }
        controller.mainWindow = { window }
        controller.standardEdit.target = Self.chain(of: child)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        child.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.addChildWindow(child, ordered: .above)
        defer {
            window.removeChildWindow(child)
            child.orderOut(nil)
            window.orderOut(nil)
        }
        try #require(child.parent === window)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        controller.copySelection(nil)
        controller.cutSelection(nil)
        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        expectRowsUntouched(opened, changeCount: changeCount)

        text.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!controller.validateMenuItem(Self.copyItem))
        #expect(!controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        controller.cutSelection(nil)
        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        expectRowsUntouched(opened, changeCount: changeCount)

        text.isEditable = false
        try #require(controller.standardEdit.validate(#selector(NSText.copy(_:)), for: nil))
        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.cutSelection(nil)
        #expect(text.cuts == 1)
        #expect(opened.clipboard()?.operation == .cut)
        controller.copySelection(nil)
        #expect(text.copies == 1)
        #expect(opened.state.progress?.title == ArchiveClipboard.progressTitle)
        for _ in 0..<500 where opened.state.progress != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened.clipboard()?.operation == .copy)
        #expect(opened.fileURLs().map(\.lastPathComponent) == ["README"])
    }

    /// With full keyboard access a toolbar button can be the archive window's first responder, outside its
    /// content: Edit > Cut and Copy are the rows' there too.
    @Test func editMenuCutAndCopyTakeTheRowsWithAToolbarButtonFocused() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let frame = try #require(content.superview)
        let button = RowsFocusView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        frame.addSubview(button)
        try #require(window.makeFirstResponder(button))
        try #require(window.firstResponder === button && !button.isDescendant(of: content))
        opened.state.selection = ["README"]

        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.cutSelection(nil)
        #expect(opened.clipboard()?.operation == .cut)
    }

    /// Validates menu items without declaring `NSMenuItemValidation`, as a remote panel's view does.
    private final class InformalMenuItemValidator: NSObject {
        var enabled = false
        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { enabled }
    }

    /// Validates interface items without declaring `NSUserInterfaceValidations`.
    private final class InformalInterfaceValidator: NSObject {
        var enabled = false
        @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool { enabled }
    }

    /// The standard Cut and Copy are validated as AppKit validates them, by what the target responds to: an
    /// informal validation counts; a target with none is enabled.
    @Test func standardEditHonorsInformalValidators() {
        var command = StandardEditCommand()
        let copy = #selector(NSText.copy(_:))
        let menuItemValidator = InformalMenuItemValidator()
        command.target = { _, _ in menuItemValidator }
        #expect(!command.validate(copy, for: nil))
        menuItemValidator.enabled = true
        #expect(command.validate(copy, for: nil))

        let interfaceValidator = InformalInterfaceValidator()
        command.target = { _, _ in interfaceValidator }
        #expect(!command.validate(copy, for: nil))
        interfaceValidator.enabled = true
        #expect(command.validate(copy, for: nil))

        let plain = NSObject()
        command.target = { _, _ in plain }
        #expect(command.validate(copy, for: nil))
    }

    /// A key sheet on the archive window (an open or save panel, a password sheet): Edit > Cut and Copy are its
    /// focused text's.
    @Test func editMenuCutAndCopyGoToAKeySheetsText() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: window)
        let sheet = otherWindow()
        let text = try focusedText(in: sheet)
        defer { detach(sheet, from: window) }
        try await attach(sheet, to: window)
        controller.keyWindow = { sheet }
        controller.standardEdit.target = Self.chain(of: sheet)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        #expect(controller.validateMenuItem(Self.copyItem))
        #expect(controller.validateMenuItem(Self.cutItem))
        controller.copySelection(nil)
        controller.cutSelection(nil)

        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        expectRowsUntouched(opened, changeCount: changeCount)
    }

    /// While a sheet is attached, the rows are never the target, even with the archive window itself key and
    /// its rows focused: Edit > Cut and Copy are the standard ones (here the sheet's text).
    @Test func editMenuCutAndCopyLeaveTheRowsWhileASheetIsAttached() async throws {
        let opened = try await open()
        defer { opened.close() }
        let controller = try windowController(for: opened)
        let window = try #require(controller.window)
        try focus(RowsFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), in: window)
        let sheet = otherWindow()
        let text = try focusedText(in: sheet)
        defer { detach(sheet, from: window) }
        try await attach(sheet, to: window)
        controller.standardEdit.target = Self.chain(of: sheet)
        opened.state.selection = ["README"]
        let changeCount = opened.pasteboard.changeCount

        controller.copySelection(nil)
        controller.cutSelection(nil)

        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        expectRowsUntouched(opened, changeCount: changeCount)
    }

    /// With no archive window key or main (the About panel, Settings alone), Edit > Cut and Copy reach the app
    /// delegate, which sends the standard cut: / copy: and validates them as their target does; off with no
    /// target. Its other actions stay on.
    @Test func editMenuCutAndCopyWithNoArchiveWindowGoToTheStandardTarget() throws {
        let delegate = AppDelegate()
        let other = otherWindow()
        defer { other.orderOut(nil) }
        let text = try focusedText(in: other)
        delegate.standardEdit.target = Self.chain(of: other)

        #expect(delegate.validateMenuItem(Self.copyItem))
        #expect(delegate.validateMenuItem(Self.cutItem))
        delegate.copySelection(nil)
        delegate.cutSelection(nil)
        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        text.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!delegate.validateMenuItem(Self.copyItem))
        #expect(!delegate.validateMenuItem(Self.cutItem))

        delegate.standardEdit.target = { _, _ in nil }
        #expect(!delegate.validateMenuItem(Self.copyItem))
        #expect(!delegate.validateMenuItem(Self.cutItem))
        delegate.copySelection(nil)
        delegate.cutSelection(nil)
        #expect(text.copies == 1)
        #expect(text.cuts == 1)
        #expect(delegate.validateMenuItem(NSMenuItem(title: "About", action: #selector(AppDelegate.showAbout(_:)),
                                                     keyEquivalent: "")))
    }

    // MARK: - Paste

    @Test func pasteOfFinderFilesAddsThemToTheSelectedFolder() async throws {
        let opened = try await open()
        defer { opened.close() }
        let files = try finderFiles(["new.txt", "more.txt"], in: opened)
        opened.pasteboard.clearContents()
        opened.pasteboard.writeObjects(files as [NSURL])
        #expect(opened.actions.canPaste)

        opened.state.selection = ["docs"]
        let plan = opened.step { opened.actions.paste() }
        #expect(plan == .add(into: "docs"))
        #expect(opened.model.item(at: "docs/new.txt") != nil)
        #expect(opened.model.item(at: "docs/more.txt") != nil)
        // Files stay on the pasteboard: a second paste is possible.
        #expect(opened.fileURLs().count == 2)
    }

    @Test func pasteOfOwnCutMovesTheItemsAndClearsTheCut() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README"]
        opened.actions.cutSelection()

        opened.state.selection = ["docs"]
        let plan = opened.step { opened.actions.paste() }
        #expect(plan == .move(["README"], into: "docs"))
        #expect(opened.model.item(at: "docs/README") != nil && opened.model.item(at: "README") == nil)
        #expect(opened.clipboard() == nil)
        #expect(!opened.actions.canPaste)
    }

    @Test func stopInTheReplaceQuestionKeepsTheCut() async throws {
        let opened = try await open()
        defer { opened.close() }
        var answer = false
        var asked: [[String]] = []
        opened.actions.mover.confirmReplace = { conflicts, reply in
            asked.append(conflicts)
            reply(answer)
        }
        opened.state.selection = ["README"]
        opened.actions.cutSelection()

        // "other" already holds a README: Stop moves nothing, and the cut can still be pasted.
        opened.state.selection = ["other"]
        #expect(opened.step { opened.actions.paste() } == .move(["README"], into: "other"))
        #expect(asked.count == 1)
        #expect(opened.model.item(at: "README") != nil)
        #expect(opened.clipboard()?.operation == .cut)

        answer = true
        #expect(opened.step { opened.actions.paste() } == .move(["README"], into: "other"))
        #expect(asked.count == 2)
        #expect(opened.model.item(at: "README") == nil && opened.model.item(at: "other/README") != nil)
        #expect(opened.clipboard() == nil)
    }

    @Test func aCutFromAnotherSourceIsRefused() async throws {
        let opened = try await open()
        defer { opened.close() }
        let elsewhere = ArchiveClipboard(source: UUID(), operation: .cut, paths: ["README"])
        opened.pasteboard.clearContents()
        opened.pasteboard.setData(elsewhere.encoded(), forType: Self.itemType)
        #expect(opened.actions.canPaste)

        opened.state.selection = ["docs"]
        #expect(opened.step { opened.actions.paste() } == .refuse(.cutElsewhere))
        #expect(opened.model.item(at: "README") != nil && opened.model.item(at: "docs/README") == nil)
        #expect(!opened.model.hasChanges)
        // Refused: the other window's cut stays on the pasteboard.
        #expect(opened.clipboard() == elsewhere)
    }

    @Test func aCopyPastedHereIntoAnotherFolderAddsAndIntoItsOwnFolderIsRefused() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README"]
        await opened.actions.copySelection()?.value
        #expect(opened.clipboard()?.operation == .copy)

        opened.state.selection = []
        #expect(opened.step { opened.actions.paste() } == .refuse(.sameFolder(["README"])))
        #expect(!opened.model.hasChanges)

        opened.state.selection = ["docs"]
        #expect(opened.step { opened.actions.paste() } == .add(into: "docs"))
        #expect(opened.model.item(at: "docs/README") != nil && opened.model.item(at: "README") != nil)
        // A copy is not used up.
        #expect(opened.clipboard()?.operation == .copy)
    }

    @Test func aReadOnlyArchiveCopiesButNeitherCutsNorPastes() async throws {
        let entries = [
            ArchiveEntry(path: "README", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
        ]
        let document = ArchiveDocument()
        let model = ArchiveModel(reader: FakeReader(entries: entries, format: .rar,
                                                    url: URL(fileURLWithPath: "/tmp/fake.rar")),
                                 undoManager: nil)
        document.state.model = model
        let actions = ArchiveActions(document: document)
        document.actions = actions
        let pasteboard = NSPasteboard(name: .init("ArchiveActionsClipboardTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/whatever.txt") as NSURL])
        actions.pasteboard = pasteboard
        #expect(!model.isEditable)

        document.state.selection = ["README"]
        #expect(actions.canCopy)
        #expect(!actions.canCut)
        #expect(!actions.canPaste)
        actions.cutSelection()
        #expect(pasteboard.types?.contains(Self.itemType) == false)
        #expect(actions.paste() == nil)
        #expect(!model.hasChanges)
        // The row menu: Copy on the row; no Paste anywhere (empty space then has no menu, as before).
        #expect(actions.clipboardMenu(for: ["README"])
                == ArchiveClipboardMenu(showsCopy: true, canCopy: true, pasteFolder: nil, canPaste: false))
        #expect(actions.clipboardMenu(for: []).pasteFolder == nil)
    }

    // MARK: - The row menu

    @Test func theRowMenusCopyCopiesTheRowsUnderItNotTheSelection() async throws {
        let opened = try await open()
        defer { opened.close() }
        // A right-click on a row outside the selection: the menu acts on that row (`contextMenu`'s paths).
        opened.state.selection = ["README"]
        #expect(opened.actions.canCopy(["docs/a.txt"]))
        await opened.actions.copyItems(["docs/a.txt"])?.value

        #expect(opened.clipboard()?.paths == ["docs/a.txt"])
        let url = try #require(opened.fileURLs().first)
        #expect(url.lastPathComponent == "a.txt")
        #expect(try text(url) == "docs/a.txt")
        #expect(opened.state.selection == ["README"])
    }

    @Test func theRowMenusPasteOnAFolderRowPastesIntoThatFolder() async throws {
        let opened = try await open()
        defer { opened.close() }
        let files = try finderFiles(["new.txt"], in: opened)
        opened.pasteboard.clearContents()
        opened.pasteboard.writeObjects(files as [NSURL])

        // Another row selected: the menu's folder wins over the selection.
        opened.state.selection = ["docs"]
        #expect(opened.step { opened.actions.paste(into: "other") } == .add(into: "other"))
        #expect(opened.model.item(at: "other/new.txt") != nil && opened.model.item(at: "docs/new.txt") == nil)
        // Empty space: the top level, whatever is selected.
        #expect(opened.step { opened.actions.paste(into: "") } == .add(into: ""))
        #expect(opened.model.item(at: "new.txt") != nil)
    }

    @Test func theRowMenusPasteOnTheCopiedFolderPastesNextToIt() async throws {
        let opened = try await open()
        defer { opened.close() }
        // As ⌘V with the copied folder still selected (`ArchivePaste.destination`): beside it, here the top
        // level, where it already is.
        opened.state.selection = ["docs"]
        await opened.actions.copySelection()?.value
        opened.state.selection = []
        #expect(opened.step { opened.actions.paste(into: "docs") } == .refuse(.sameFolder(["docs"])))
        #expect(!opened.model.hasChanges)
    }

    @Test func theRowMenusClipboardItems() async throws {
        let opened = try await open()
        defer { opened.close() }
        let actions = opened.actions
        // Nothing to paste: Paste shows, disabled; on empty space no Copy.
        #expect(actions.clipboardMenu(for: [])
                == ArchiveClipboardMenu(showsCopy: false, canCopy: false, pasteFolder: "", canPaste: false))
        #expect(actions.clipboardMenu(for: ["docs"])
                == ArchiveClipboardMenu(showsCopy: true, canCopy: true, pasteFolder: "docs", canPaste: false))
        // A file row, or several rows: Copy only.
        #expect(actions.clipboardMenu(for: ["README"]).pasteFolder == nil)
        #expect(actions.clipboardMenu(for: ["docs", "other"]).pasteFolder == nil)

        let files = try finderFiles(["new.txt"], in: opened)
        opened.pasteboard.clearContents()
        opened.pasteboard.writeObjects(files as [NSURL])
        #expect(actions.clipboardMenu(for: []).canPaste)
        #expect(actions.clipboardMenu(for: ["other"]).canPaste)

        // While a Copy exports (its progress sheet up): neither Copy nor Paste.
        opened.state.selection = ["README"]
        let task = try #require(actions.copySelection())
        #expect(actions.clipboardMenu(for: ["other"])
                == ArchiveClipboardMenu(showsCopy: true, canCopy: false, pasteFolder: "other", canPaste: false))
        // Empty space: no Paste, as no New Folder, while an operation runs (nothing would sit above a divider).
        #expect(actions.clipboardMenu(for: []).pasteFolder == nil)
        await task.value
        #expect(actions.clipboardMenu(for: ["other"]).canCopy)
        #expect(actions.clipboardMenu(for: []).pasteFolder == "")
    }

    @Test func theRowMenusPasteIsDisabledWhileARowIsRenamed() async throws {
        let opened = try await open()
        defer { opened.close() }
        let actions = opened.actions
        let files = try finderFiles(["new.txt"], in: opened)
        opened.pasteboard.clearContents()
        opened.pasteboard.writeObjects(files as [NSURL])
        #expect(actions.clipboardMenu(for: []).canPaste && actions.clipboardMenu(for: ["other"]).canPaste)

        // As ⌘V (`ArchiveTableView`'s validator): no paste while the name field shows.
        opened.state.renamingPath = "README"
        #expect(actions.clipboardMenu(for: [])
                == ArchiveClipboardMenu(showsCopy: false, canCopy: false, pasteFolder: "", canPaste: false))
        #expect(!actions.clipboardMenu(for: ["other"]).canPaste)
        opened.state.renamingPath = nil
        #expect(actions.clipboardMenu(for: ["other"]).canPaste)
    }

    // MARK: - An export overtaken

    @Test func aModelSwappedDuringTheExportDropsTheCopies() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README"]
        let task = try #require(opened.actions.copySelection())
        // A Text Encoding reopen or a Revert puts another model in before the export returns.
        let other = ArchiveModel(reader: FakeReader(entries: []), undoManager: nil)
        opened.state.model = other
        await task.value
        opened.state.model = opened.model

        #expect(opened.clipboard() == nil && opened.fileURLs().isEmpty)
        #expect(try opened.exportFolders().isEmpty)
    }

    @Test func aSheetThatReplacedTheProgressDropsTheCopies() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README"]
        let task = try #require(opened.actions.copySelection())
        // A save puts up its own sheet over Copy's.
        opened.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        await task.value

        #expect(opened.state.progress?.title == "Saving")
        #expect(opened.clipboard() == nil && opened.fileURLs().isEmpty)
        #expect(try opened.exportFolders().isEmpty)
    }

    @Test func cancelDropsTheCopiesSilently() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README", "docs"]
        let task = try #require(opened.actions.copySelection())
        opened.state.progress?.cancel?()
        await task.value

        #expect(opened.state.progress == nil)
        #expect(opened.clipboard() == nil && opened.fileURLs().isEmpty)
        #expect(try opened.exportFolders().isEmpty)
        // The cancelled Copy no longer counts as running.
        #expect(opened.actions.canCopy)
    }

    @Test func aSaveDuringTheExportDropsTheCopies() async throws {
        let opened = try await open()
        defer { opened.close() }
        let saved = try await Archive.open(at: opened.directory.appendingPathComponent("source.zip"))
        opened.state.selection = ["README"]
        let task = try #require(opened.actions.copySelection())
        // A save adopted before the export returns (its sheet already gone): the snapshot moved on.
        opened.model.didSave(reader: saved)
        await task.value

        #expect(opened.state.progress == nil)
        #expect(opened.clipboard() == nil && opened.fileURLs().isEmpty)
        #expect(try opened.exportFolders().isEmpty)
    }

    /// One Copy export at a time: a ⌘S under Copy's sheet replaces it and then goes, but Copy still runs.
    @Test func aSecondCopyWaitsForTheFirstAfterASaveReplacedItsSheet() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README"]
        let task = try #require(opened.actions.copySelection())
        opened.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        opened.state.progress = nil

        #expect(!opened.actions.canCopy)
        #expect(opened.actions.copySelection() == nil)
        await task.value
        #expect(opened.actions.canCopy)
    }

    /// `canCopy` is observable: the table's ⌘C (read in its body) comes back once a Copy ends, with nothing
    /// else changing (the sheet already gone, as after a ⌘S under it).
    @Test func theEndOfACopyIsObserved() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README"]
        let task = try #require(opened.actions.copySelection())
        opened.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        opened.state.progress = nil
        #expect(!opened.actions.canCopy)

        final class Flag: @unchecked Sendable { var changed = false }
        let flag = Flag()
        withObservationTracking { _ = opened.actions.canCopy } onChange: { flag.changed = true }
        await task.value
        #expect(flag.changed)
        #expect(opened.actions.canCopy)
    }

    // MARK: - The real temporary folder

    /// Copies in the real temporary folder's `Kernir-Clipboard-<process>/<UUID>` (where `isOwnTemporaryFile`
    /// matches, so `addDropped` would drop them) are added: Paste goes through `add(_:to:)`. Whatever export
    /// folder the Copy made goes at the end, pasted or not, and this process's parent there if this test made it.
    @Test func copiesInTheRealTemporaryFolderArePastedThroughAdd() async throws {
        let opened = try await open()
        defer { opened.close() }
        let fileManager = FileManager.default
        let real = fileManager.temporaryDirectory
        let parent = ArchiveClipboard.exportParent(in: real)
        let hadParent = fileManager.fileExists(atPath: parent.path)
        let before = Set((try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? [])
        defer {
            let after = Set((try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? [])
            for name in after.subtracting(before) {
                ArchiveClipboard.removeExport(parent.appendingPathComponent(name, isDirectory: true))
            }
            if !hadParent, ((try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []).isEmpty {
                // Only this process's own parent and lock: no sweep of the real temporary folder.
                ArchiveClipboard.removeExportParent(in: real)
            }
        }
        opened.actions.clipboardTemporaryDirectory = real
        opened.state.selection = ["README"]
        await opened.actions.copySelection()?.value
        let urls = opened.fileURLs()
        #expect(urls.map(\.lastPathComponent) == ["README"])
        #expect(urls.allSatisfy { $0.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                    == parent.standardizedFileURL })
        #expect(urls.allSatisfy(ArchiveActions.isOwnTemporaryFile))

        opened.state.selection = ["docs"]
        #expect(opened.step { opened.actions.paste() } == .add(into: "docs"))
        #expect(opened.model.item(at: "docs/README") != nil)
    }

    /// The app's launch and quit sweep leaves the real temporary folder alone while tests host the app: a live
    /// instance's copies stay. Any other folder is swept: at launch the parents of runs that are gone, at quit
    /// only this process's own.
    @Test func theLaunchAndQuitSweepSkipsTheRealTemporaryFolderUnderTests() async throws {
        let opened = try await open()
        defer { opened.close() }
        let fileManager = FileManager.default
        let live = fileManager.temporaryDirectory
            .appendingPathComponent("\(ArchiveClipboard.exportPrefix)\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: live) }
        let stale = opened.temporary
            .appendingPathComponent("\(ArchiveClipboard.exportPrefix)\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stale, withIntermediateDirectories: true)

        ArchiveActions.sweepClipboardExports()
        ArchiveActions.removeOwnClipboardExports()
        #expect(fileManager.fileExists(atPath: live.path))
        // The quit sweep takes only this process's own parent: an unheld one of a run that is gone stays for
        // the next launch's sweep.
        ArchiveActions.removeOwnClipboardExports(in: opened.temporary)
        #expect(fileManager.fileExists(atPath: stale.path))
        ArchiveActions.sweepClipboardExports(in: opened.temporary)
        #expect(!fileManager.fileExists(atPath: stale.path))
    }

    @Test func clearIfStillOursLeavesAnotherAppsWrite() async throws {
        let opened = try await open()
        defer { opened.close() }
        opened.state.selection = ["README"]
        opened.actions.cutSelection()
        // Another app writes after Kernir: not cleared.
        opened.pasteboard.clearContents()
        opened.pasteboard.setString("theirs", forType: .string)
        ArchiveActions.clearIfStillOurs(opened.pasteboard)
        #expect(opened.pasteboard.string(forType: .string) == "theirs")

        opened.actions.cutSelection()
        ArchiveActions.clearIfStillOurs(opened.pasteboard)
        #expect(opened.pasteboard.types?.isEmpty != false)
    }
}
