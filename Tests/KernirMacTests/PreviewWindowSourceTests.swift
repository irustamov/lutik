import AppKit
import Foundation
import KernirCore
import Testing
import UniformTypeIdentifiers
@testable import Kernir

/// Kernir's own preview window: Share and Open With act on the archive entry,
/// its real name and bytes, never on the stand-in the window shows; Share's copies outlive the
/// preview and go with the archive window; a render for a window the user left opens nothing.
/// Nothing here launches another app: `ArchiveActions.launch` is swapped for a recorder.
@Suite(.serialized) @MainActor
struct PreviewWindowSourceTests {
    /// Records what the preview window asks its archive window for.
    private final class Recorder: PreviewWindowControllerDelegate {
        var closeRequests = 0
        var moves: [Int] = []
        func previewWindowDidRequestClose() { closeRequests += 1 }
        func previewWindowMoveSelection(by step: Int) { moves.append(step) }
        func previewWindowCanOpen(_ item: PreviewItem) -> Bool { true }
        func previewWindowCanShare(_ item: PreviewItem) -> Bool { true }
        func previewWindowOpen(_ item: PreviewItem, withApplicationAt app: URL?) {}
        func previewWindowShareItems(for item: PreviewItem) -> [URL] { [] }
    }

    private static let csv = Data("Item,Cost\nTea,3\n".utf8)

    /// Polls until `condition` holds, for at most about five seconds; the caller asserts the outcome.
    private func wait(for condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A folder of the test's own with `Budget.csv`, a stand-in `Budget.csv.txt` and a folder
    /// `docs`; a document whose archive holds `Budget.csv` and `docs` (pending additions, so
    /// nothing is extracted to the real temporary folder); and a preview source for it whose
    /// stand-ins live in the test's folder. `launch` records instead of opening. Everything,
    /// the opened copies too, is removed afterwards.
    private func withSource(
        _ body: @MainActor (PreviewWindowSource, ArchiveDocument, PreviewStandInStore, URL, LaunchRecorder) async throws -> Void
    ) async throws {
        try await LaunchRecorder.recording { launched in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("KernirTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let files = folder.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: files.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try Self.csv.write(to: files.appendingPathComponent("Budget.csv"))
            try Self.csv.write(to: files.appendingPathComponent("Budget.csv.txt"))

            let openedFiles = OpenedFiles()
            defer { openedFiles.close() }
            let document = try ArchiveDocument(type: "public.zip-archive")
            let model = ArchiveModel(reader: FakeReader(entries: []), undoManager: nil, openedFiles: openedFiles)
            document.state.model = model
            model.add([files.appendingPathComponent("Budget.csv"), files.appendingPathComponent("docs")], to: "")
            try #require(model.item(at: "Budget.csv") != nil && model.item(at: "docs") != nil)
            let actions = ArchiveActions(document: document)
            defer { actions.cancelAll() }
            let store = PreviewStandInStore(parent: folder)
            let source = PreviewWindowSource(state: document.state, standIns: store)
            source.actions = actions
            defer { source.windowWillClose() }
            try await body(source, document, store, files, launched)
            withExtendedLifetime((source, actions)) {}
        }
    }

    /// The item the window shows for `Budget.csv`: its text stand-in, titled and acting as the entry.
    private func budgetItem(_ files: URL) -> PreviewItem {
        PreviewItem(url: files.appendingPathComponent("Budget.csv.txt"), title: "Budget.csv",
                    entry: PreviewEntry(path: "Budget.csv", url: files.appendingPathComponent("Budget.csv")))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("Open With hands a copy of the entry, under its real name, to the chosen app")
    func openWithChosenApp() async throws {
        try await withSource { source, _, _, files, launched in
            let app = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            source.previewWindowOpen(budgetItem(files), withApplicationAt: app)
            await wait { launched.calls.count == 1 }
            let call = try #require(launched.calls.first)
            #expect(call.app == app)
            #expect(call.file.lastPathComponent == "Budget.csv", "the stand-in was opened")
            #expect(try Data(contentsOf: call.file) == Self.csv)
            // copyForOpening's copy, tracked so edits come back; never the user's own file.
            #expect(call.file.standardizedFileURL != files.appendingPathComponent("Budget.csv").standardizedFileURL)
            #expect(ArchiveActions.isOwnTemporaryFile(call.file))
        }
    }

    @Test("The Open With button opens in the default app, as a double-click does")
    func openWithDefaultApp() async throws {
        try await withSource { source, document, _, files, launched in
            source.previewWindowOpen(budgetItem(files), withApplicationAt: nil)
            await wait { launched.calls.count == 1 }
            #expect(launched.calls.first?.app == nil)
            #expect(launched.calls.first?.file.lastPathComponent == "Budget.csv")

            // Double-click: the same path.
            document.state.selection = ["Budget.csv"]
            try #require(source.actions).openSelectionInDefaultApp()
            await wait { launched.calls.count == 2 }
            #expect(launched.calls.last?.app == nil)
            #expect(launched.calls.last?.file.lastPathComponent == "Budget.csv")
        }
    }

    @Test("Open With is off for a folder entry, and opens nothing")
    func openWithFolder() async throws {
        try await withSource { source, _, _, files, launched in
            let folderItem = PreviewItem(url: files.appendingPathComponent("docs"), title: "docs",
                                         entry: PreviewEntry(path: "docs", url: files.appendingPathComponent("docs")))
            #expect(!source.previewWindowCanOpen(folderItem))
            #expect(source.previewWindowCanOpen(budgetItem(files)))
            source.previewWindowOpen(folderItem, withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(launched.calls.isEmpty)
        }
    }

    @Test("Share hands a copy of the entry, never the stand-in; it outlives the preview, not the window")
    func shareCopy() async throws {
        try await withSource { source, document, store, files, _ in
            let shared = await source.previewWindowShareItems(for: budgetItem(files))
            let copy = try #require(shared.first)
            #expect(shared.count == 1)
            #expect(copy.lastPathComponent == "Budget.csv")
            #expect(try Data(contentsOf: copy) == Self.csv)
            #expect(copy.path.hasPrefix(store.root.appendingPathComponent(PreviewStandInStore.shareFolderName).path + "/"))

            // The preview ends: the copy stays, AirDrop may still be reading it.
            document.state.previewURL = files.appendingPathComponent("Budget.csv")
            document.state.previewURL = nil
            try await Task.sleep(for: .milliseconds(200))
            #expect(exists(copy))

            // The archive window closes: the whole root goes.
            source.windowWillClose()
            #expect(!exists(store.root))
            #expect(await source.previewWindowShareItems(for: budgetItem(files)).isEmpty)
        }
    }

    @Test("Share extracts the entry again when its extracted file is gone, instead of an empty picker")
    func shareReextracts() async throws {
        try await withSource { source, _, store, files, _ in
            // The file the preview got is gone (a save deleted the reader's cache, say); the
            // entry itself is still in the archive.
            let gone = files.appendingPathComponent("cache/Budget.csv")
            let item = PreviewItem(url: files.appendingPathComponent("Budget.csv.txt"), title: "Budget.csv",
                                   entry: PreviewEntry(path: "Budget.csv", url: gone))
            #expect(!exists(gone))
            let shared = await source.previewWindowShareItems(for: item)
            let copy = try #require(shared.first)
            #expect(copy.lastPathComponent == "Budget.csv")
            #expect(try Data(contentsOf: copy) == Self.csv)
            #expect(copy.path.hasPrefix(store.root.path + "/"))
        }
    }

    @Test("Share gives nothing (the window beeps) when the entry can't be extracted again")
    func shareFailsCleanly() async throws {
        try await withSource { source, _, store, files, _ in
            let gone = files.appendingPathComponent("cache/Missing.csv")
            let item = PreviewItem(url: gone, title: "Missing.csv", entry: PreviewEntry(path: "Missing.csv", url: gone))
            #expect(await source.previewWindowShareItems(for: item).isEmpty)
            let share = store.root.appendingPathComponent(PreviewStandInStore.shareFolderName)
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: share.path)) ?? []).isEmpty)
        }
    }

    @Test("While an operation runs, Open With is off and Share extracts nothing again")
    func openWithAndShareWaitForAnOperation() async throws {
        try await withSource { source, document, _, files, launched in
            let gone = files.appendingPathComponent("cache/Budget.csv")
            let vanished = PreviewItem(url: files.appendingPathComponent("Budget.csv.txt"), title: "Budget.csv",
                                       entry: PreviewEntry(path: "Budget.csv", url: gone))
            // A save, an extraction or View > Text Encoding's reopen: the listing may change under it.
            document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
            #expect(!source.previewWindowCanOpen(budgetItem(files)))
            source.previewWindowOpen(budgetItem(files), withApplicationAt: nil)
            source.previewWindowOpen(budgetItem(files),
                                     withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
            #expect(await source.previewWindowShareItems(for: vanished).isEmpty)
            try await Task.sleep(for: .milliseconds(300))
            #expect(launched.calls.isEmpty)
            #expect(!exists(gone))

            document.state.progress = nil
            #expect(source.previewWindowCanOpen(budgetItem(files)))
            #expect(await source.previewWindowShareItems(for: vanished).first?.lastPathComponent == "Budget.csv")
        }
    }

    @Test("The window's Open With and Share go off when an operation starts and back on when it ends")
    func buttonsFollowAnOperation() async throws {
        try await withSource { source, document, _, files, _ in
            let controller = source.makeController()
            let window = try #require(controller.window)
            window.alphaValue = 0
            controller.show([budgetItem(files)], at: 0, over: nil)
            let toolbarItems = try #require(window.toolbar?.items)
            let openWith = try #require(toolbarItems.first { $0.itemIdentifier == PreviewWindowController.openWithIdentifier })
            let share = try #require(toolbarItems.first { $0.itemIdentifier == PreviewWindowController.shareIdentifier })
            let shareButton = try #require(share.view as? NSButton)
            #expect(openWith.isEnabled && share.isEnabled && shareButton.isEnabled)

            // The item shown stays the same: only the operation tells the window.
            document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
            await wait { !openWith.isEnabled && !shareButton.isEnabled }
            #expect(!openWith.isEnabled && !share.isEnabled && !shareButton.isEnabled)
            // Progress updates leave them off.
            document.state.progress = OperationProgress(title: "Saving", fraction: 0.5, cancel: nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(!openWith.isEnabled && !shareButton.isEnabled)

            document.state.progress = nil
            await wait { openWith.isEnabled && shareButton.isEnabled }
            #expect(openWith.isEnabled && share.isEnabled && shareButton.isEnabled)
        }
    }

    @Test("A render for an archive window the user isn't in opens nothing and ends the preview")
    func renderForAnotherWindow() async throws {
        try await withSource { source, document, store, files, _ in
            // No archive window at all (as after a close, or never key): the render finds no
            // window to open over.
            let csv = files.appendingPathComponent("Budget.csv")
            document.state.previewEntries = [PreviewEntry(path: "Budget.csv", url: csv)]
            document.state.previewURL = csv
            await wait { document.state.previewURL == nil }
            #expect(document.state.previewURL == nil)
            #expect(source.previewWindow == nil)
            // Its stand-in was discarded.
            let left = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
            #expect(left.isEmpty)
        }
    }

    @Test("The window pages with ←/→, titles \"2 of 3\", and its close button ends the preview")
    func windowPagesAndCloses() throws {
        let controller = PreviewWindowController()
        let recorder = Recorder()
        controller.delegate = recorder
        defer { controller.tearDown() }
        let window = try #require(controller.window)
        // On screen but fully transparent, like the hosted sheet tests.
        window.alphaValue = 0
        let items = ["a.txt", "b.txt", "c.txt"].map { name in
            PreviewItem(url: URL(fileURLWithPath: "/tmp/\(name)"), title: name,
                        entry: PreviewEntry(path: "dir/\(name)", url: URL(fileURLWithPath: "/tmp/\(name)")))
        }

        controller.show(items, at: 1, over: nil)
        #expect(controller.isOpen)
        #expect(window.title == "b.txt — 2 of 3")
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        controller.page(by: 1)
        #expect(window.title == "c.txt — 3 of 3")
        #expect(controller.currentItem?.entry.path == "dir/c.txt")
        controller.page(by: 1)
        #expect(window.title == "c.txt — 3 of 3")
        controller.pager.index = 0
        #expect(window.title == "a.txt — 1 of 3")

        // New items in the open window: no "of" for one item.
        controller.show([items[2]], at: 0, over: nil)
        #expect(window.title == "c.txt")

        controller.hide()
        #expect(!controller.isOpen)
        #expect(recorder.closeRequests == 0, "hide() asks no one")

        controller.show(items, at: 0, over: nil)
        window.performClose(nil)
        #expect(recorder.closeRequests == 1)
        #expect(!controller.isOpen)
    }

    /// Three items named a.txt, b.txt and c.txt (no files: the sheet shows their icons).
    private func threeItems() -> [PreviewItem] {
        ["a.txt", "b.txt", "c.txt"].map { name in
            PreviewItem(url: URL(fileURLWithPath: "/tmp/\(name)"), title: name,
                        entry: PreviewEntry(path: "dir/\(name)", url: URL(fileURLWithPath: "/tmp/\(name)")))
        }
    }

    private func hasGridButton(_ window: NSWindow) -> Bool {
        window.toolbar?.items.contains { $0.itemIdentifier == PreviewWindowController.gridIdentifier } == true
    }

    @Test("The index sheet: only for a multi-selection, titled \"3 items\"; a pick shows that item")
    func indexSheet() throws {
        let controller = PreviewWindowController()
        let recorder = Recorder()
        controller.delegate = recorder
        defer { controller.tearDown() }
        let window = try #require(controller.window)
        window.alphaValue = 0
        let items = threeItems()

        controller.show(items, at: 0, over: nil)
        #expect(hasGridButton(window))
        #expect(window.toolbar?.items.contains { $0.itemIdentifier == PreviewWindowController.fullScreenIdentifier } == true)
        // Edit > Copy asks the shown item's type (`ArchiveWindowController.previewedContentType`): none in the sheet.
        #expect(controller.shownContentType == .plainText)
        controller.setMode(.grid)
        #expect(controller.mode == .grid)
        #expect(controller.shownContentType == nil)
        #expect(!controller.gridView.isHidden)
        #expect(window.title == "3 items")
        #expect(controller.gridView.items.map(\.title) == ["a.txt", "b.txt", "c.txt"])

        // Arrows move in the sheet; the title stays; Return/Space show the item.
        #expect(controller.perform(.gridMove(.right)))
        #expect(controller.index == 1)
        #expect(window.title == "3 items")
        #expect(controller.gridView.collectionView.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
        #expect(controller.perform(.openSelected))
        #expect(controller.mode == .single)
        #expect(controller.gridView.isHidden)
        #expect(window.title == "b.txt — 2 of 3")

        // Esc in the sheet goes back to the item selected there; a click picks an item.
        controller.setMode(.grid)
        controller.perform(.gridMove(.left))
        controller.perform(.showSingle)
        #expect(controller.mode == .single)
        #expect(window.title == "a.txt — 1 of 3")
        controller.setMode(.grid)
        controller.pick(2)
        #expect(controller.mode == .single)
        #expect(window.title == "c.txt — 3 of 3")
        #expect(recorder.closeRequests == 0)

        // One item: no sheet and no button for it.
        controller.setMode(.grid)
        controller.show([items[0]], at: 0, over: nil)
        #expect(controller.mode == .single)
        #expect(!hasGridButton(window))
        controller.setMode(.grid)
        #expect(controller.mode == .single)
        #expect(window.title == "a.txt")

        // The next preview opens in the single view.
        controller.show(items, at: 0, over: nil)
        #expect(hasGridButton(window))
        controller.setMode(.grid)
        controller.hide()
        #expect(controller.mode == .single)
        #expect(controller.gridView.items.isEmpty)
        controller.show(items, at: 0, over: nil)
        #expect(controller.mode == .single)
    }

    private func itemIdentifiers(_ window: NSWindow) -> [NSToolbarItem.Identifier] {
        window.toolbar?.items.map(\.itemIdentifier) ?? []
    }

    /// Hosted run on a test Mac: every preview toolbar had the identifier
    /// "KernirPreview", so AppKit mirrored each index-sheet button insert and remove into the
    /// others by index; one whose controller had gone took the removes but not the inserts, lost
    /// its other buttons, and `hide()` then asserted in `-[NSToolbar _itemAtIndex:]`.
    @Test("Each preview window's toolbar is its own: the index-sheet button of one comes and goes in no other")
    func toolbarsAreSeparate() throws {
        let single: [NSToolbarItem.Identifier] = [.flexibleSpace, PreviewWindowController.fullScreenIdentifier,
                                                  PreviewWindowController.openWithIdentifier,
                                                  PreviewWindowController.shareIdentifier]
        let many = threeItems()
        // Two archive windows' previews, both open: one item in `other`, three in `controller`.
        let other = PreviewWindowController()
        defer { other.tearDown() }
        let otherWindow = try #require(other.window)
        otherWindow.alphaValue = 0
        other.show([many[0]], at: 0, over: nil)
        // A preview whose controller has gone while its window and toolbar live on (as after an
        // earlier test): its toolbar has no delegate to make items with.
        let orphan = PreviewWindowController()
        defer { orphan.tearDown() }
        let orphanWindow = try #require(orphan.window)
        let orphanToolbar = try #require(orphanWindow.toolbar)
        // Setup as much as a check: reading the identifiers makes the toolbar's items while it still
        // has its delegate, so the orphaned toolbar below has items to share.
        try #require(itemIdentifiers(orphanWindow) == single)
        orphanToolbar.delegate = nil
        defer { orphanToolbar.delegate = orphan }

        let controller = PreviewWindowController()
        defer { controller.tearDown() }
        let window = try #require(controller.window)
        window.alphaValue = 0
        #expect(window.toolbar?.identifier != otherWindow.toolbar?.identifier)
        #expect(window.toolbar?.identifier != orphanToolbar.identifier)

        // `#require` from here: with a shared identifier the toolbars drift apart, and carrying
        // on would end in AppKit's assertion (a crash and a hung run) instead of a failure.
        controller.show(many, at: 0, over: nil)
        #expect(hasGridButton(window))
        try #require(itemIdentifiers(otherWindow) == single, "one item: no index-sheet button")
        try #require(itemIdentifiers(orphanWindow) == single)

        // `other` gets three items and the button, then one again: `controller` keeps its own.
        other.show(many, at: 0, over: nil)
        #expect(hasGridButton(otherWindow))
        other.show([many[1]], at: 0, over: nil)
        #expect(itemIdentifiers(otherWindow) == single)
        try #require(hasGridButton(window))
        try #require(itemIdentifiers(orphanWindow) == single)

        // The hosted failure: the sheet up, then the preview ends.
        controller.setMode(.grid)
        controller.hide()
        #expect(controller.mode == .single)
        #expect(itemIdentifiers(window) == single)
        try #require(itemIdentifiers(otherWindow) == single)
        try #require(itemIdentifiers(orphanWindow) == single)
        // The next preview, and its end.
        controller.show(many, at: 0, over: nil)
        #expect(hasGridButton(window))
        try #require(itemIdentifiers(otherWindow) == single)
        controller.hide()
        #expect(itemIdentifiers(window) == single)
        #expect(itemIdentifiers(otherWindow) == single)
        #expect(itemIdentifiers(orphanWindow) == single)
    }

    @Test("Out of full screen the window floats, hides when Kernir is inactive and never becomes main")
    func windowedTraits() throws {
        let controller = PreviewWindowController()
        defer { controller.tearDown() }
        let window = try #require(controller.window)
        #expect(window.level == .floating)
        #expect(window.hidesOnDeactivate)
        #expect(!window.canBecomeMain)
        #expect(window.canBecomeKey)
        #expect(!controller.isFullScreen)
        // Not in full screen: what waits for the window to leave it runs at once.
        var ran = false
        controller.leaveFullScreen { ran = true }
        #expect(ran)
    }
}
