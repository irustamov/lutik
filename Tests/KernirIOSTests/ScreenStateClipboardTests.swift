import Foundation
import Observation
import os
import Testing
import UIKit
import KernirCore
@testable import Kernir

/// Copy, Cut and Paste of archive items on iOS: what Copy and Cut put on the pasteboard, what a
/// paste does with it (`ArchivePaste.plan`), the gates, and the stock edit actions on the navigation controller.
/// Every test uses a pasteboard of its own (`UIPasteboard.withUniqueName()`), never the general one.
/// In `ScreenStateTests` for its `.serialized`: `ArchiveDocument.engine` and `ScreenState.pasteboard` are
/// process-wide test seams.
extension ScreenStateTests {
    /// Opens a copy of a ZIP fixture with a fake engine listing SampleArchive's entries (`format` as given).
    /// Once an earlier Copy's export folders are gone: until then no Copy starts.
    private func openForClipboard(format: ArchiveFormat = .zip, failure: ArchiveError? = nil,
                                  extractDelay: Duration = .zero) async throws -> ScreenState {
        await ScreenState.exportRemoval?.value
        let url = try Fixture.copy("zip/deflate.zip")
        ArchiveDocument.engine = FakeEngine(reader: { url in
            FakeReader(entries: SampleArchive().entries, format: format, url: url, failure: failure,
                       extractDelay: extractDelay)
        }).engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        #expect(document.session.model != nil)
        return ScreenState(document: document)
    }

    /// A pasteboard of the test's own, set as `ScreenState.pasteboard`; `endPasteboard` removes it.
    private func beginPasteboard() -> UIPasteboard {
        let pasteboard = UIPasteboard.withUniqueName()
        ScreenState.pasteboard = pasteboard
        return pasteboard
    }

    private func endPasteboard(_ pasteboard: UIPasteboard) {
        ScreenState.pasteboard = .general
        UIPasteboard.remove(withName: pasteboard.name)
        ArchiveClipboard.removeExports(in: FileManager.default.temporaryDirectory, keeping: nil)
    }

    /// The Kernir item on `pasteboard`, decoded; nil when there is none.
    private func clipboardItem(_ pasteboard: UIPasteboard) async -> ArchiveClipboard? {
        guard let provider = pasteboard.itemProviders.first(where: {
            $0.registeredTypeIdentifiers.contains(ArchiveClipboard.typeIdentifier)
        }) else { return nil }
        let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            Self.loadItemData(provider) { continuation.resume(returning: $0) }
        }
        return data.flatMap(ArchiveClipboard.decoded)
    }

    /// Polls until `condition` holds, for up to about five seconds.
    private func waitForClipboard(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// This process's Copy export folders, by name.
    private func exportFolders() -> Set<String> {
        let parent = ArchiveClipboard.exportParent(in: FileManager.default.temporaryDirectory)
        return Set((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
    }

    /// Whether reading `value` is invalidated by `change` (Observation, as SwiftUI sees it).
    private func invalidates(_ value: () -> Bool, by change: () async throws -> Void) async throws -> Bool {
        let changed = OSAllocatedUnfairLock(initialState: false)
        _ = withObservationTracking({ value() }, onChange: { changed.withLock { $0 = true } })
        try await change()
        try await waitForClipboard { changed.withLock { $0 } }
        return changed.withLock { $0 }
    }

    private nonisolated static func loadItemData(_ provider: NSItemProvider, _ done: @escaping @Sendable (Data?) -> Void) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: ArchiveClipboard.typeIdentifier) { data, _ in done(data) }
    }

    /// A provider with the Kernir item `data` only. Nonisolated: UIKit calls the handler off main.
    private nonisolated static func itemProvider(_ data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: ArchiveClipboard.typeIdentifier, visibility: .all) {
            completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// A provider with `url` as a file of `type` and no name, as a text file copied in Files. Nonisolated: UIKit
    /// calls the handler off main.
    private nonisolated static func unnamedFileProvider(_ url: URL, type: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    // MARK: - Copy and Cut

    /// Copy puts one file provider per copy, named as the item, the first also carrying the Kernir item.
    @Test func clipboardCopyPutsFileProvidersAndItem() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()

        #expect(await state.copy(["README.md", "src/main.swift"]))

        #expect(pasteboard.numberOfItems == 2)
        let providers = pasteboard.itemProviders
        #expect(providers.map(\.suggestedName) == ["README.md", "main.swift"])
        #expect(providers[0].registeredTypeIdentifiers.contains(ArchiveClipboard.typeIdentifier))
        #expect(!providers[1].registeredTypeIdentifiers.contains(ArchiveClipboard.typeIdentifier))
        #expect(providers.allSatisfy { DroppedItem.fileType(of: $0) != nil })
        let item = try #require(await clipboardItem(pasteboard))
        #expect(item == ArchiveClipboard(source: state.dragSourceID, operation: .copy,
                                         paths: ["README.md", "src/main.swift"]))
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    /// Cut puts the Kernir item only: no file.
    @Test func clipboardCutPutsItemOnly() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()

        state.cut(["README.md"])

        #expect(pasteboard.numberOfItems == 1)
        #expect(pasteboard.itemProviders.first?.registeredTypeIdentifiers == [ArchiveClipboard.typeIdentifier])
        #expect(await clipboardItem(pasteboard) == ArchiveClipboard(source: state.dragSourceID, operation: .cut,
                                                                    paths: ["README.md"]))
        await state.document.closeOnMain()
    }

    /// A failed Copy leaves the pasteboard as it was and says why.
    @Test func clipboardFailedCopyKeepsPasteboard() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        pasteboard.string = "kept"
        let state = try await openForClipboard(failure: .io(""))

        #expect(!(await state.copy(["README.md"])))

        #expect(pasteboard.string == "kept")
        #expect(await clipboardItem(pasteboard) == nil)
        #expect(state.alert?.title == "Couldn't Copy")
        await state.document.closeOnMain()
    }

    /// The copies are link-swept before they reach the pasteboard: an item that is a symlink out is dropped.
    @Test func clipboardCopySanitizesLinks() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let secret = try outsideSecret()
        defer { try? FileManager.default.removeItem(at: secret.deletingLastPathComponent()) }
        let archive = try linkArchive([
            (path: "photo.jpg", text: nil, link: secret.path),
            (path: "a.txt", text: "A", link: nil),
        ])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let state = try await openLive(at: archive)
        await ScreenState.exportRemoval?.value

        #expect(await state.copy(["photo.jpg", "a.txt"]))

        #expect(pasteboard.itemProviders.map(\.suggestedName) == ["a.txt"])
        #expect(try String(contentsOf: secret, encoding: .utf8) == "the user's own secret")
        await state.document.closeOnMain()
    }

    /// A read-only archive copies (it extracts) but neither cuts nor pastes.
    @Test func clipboardReadOnlyCopiesOnly() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let rar = try await openForClipboard(format: .rar)
        #expect(rar.canCopy(["README.md"]))
        #expect(!rar.canCut(["README.md"]))

        #expect(await rar.copy(["README.md"]))
        #expect(pasteboard.numberOfItems == 1)
        #expect(!rar.canPaste)
        rar.cut(["README.md"])
        #expect(await clipboardItem(pasteboard)?.operation == .copy)
        #expect(await rar.paste(into: "") == nil)
        await rar.document.closeOnMain()
    }

    // MARK: - Paste

    /// A copy pasted in another archive adds the copies; in its own archive, into another folder, too.
    @Test func clipboardPasteCopyAdds() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let source = try await openForClipboard()
        let target = try await openForClipboard()
        #expect(await source.copy(["README.md"]))

        #expect(await target.paste(into: "assets") == .add(into: "assets"))
        #expect(target.model?.item(at: "assets/README.md") != nil)
        #expect(target.alert == nil)

        #expect(await source.paste(into: "src") == .add(into: "src"), "same document, another folder")
        #expect(source.model?.item(at: "src/README.md") != nil)
        #expect(source.alert == nil)
        await source.document.closeOnMain()
        await target.document.closeOnMain()
    }

    /// A copy pasted into the folder it came from is refused, in one alert.
    @Test func clipboardPasteCopyIntoSameFolderRefused() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        #expect(await state.copy(["README.md"]))

        #expect(await state.paste(into: "") == .refuse(.sameFolder(["README.md"])))
        #expect(state.alert?.title == ArchivePaste.refusalTitle)
        await state.document.closeOnMain()
    }

    /// A cut pasted in its own archive moves the items and is used up: the pasteboard is cleared, a second
    /// paste does nothing.
    @Test func clipboardPasteCutMoves() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        state.cut(["README.md"])

        #expect(await state.paste(into: "src") == .move(["README.md"], into: "src"))
        #expect(state.model?.item(at: "src/README.md") != nil)
        #expect(state.model?.item(at: "README.md") == nil)
        #expect(state.alert == nil)
        #expect(pasteboard.numberOfItems == 0)
        #expect(await state.paste(into: "assets") == nil)
        await state.document.closeOnMain()
    }

    /// A cut pasted in another archive is refused (copy instead), and stays on the pasteboard.
    @Test func clipboardPasteCutElsewhereRefused() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let source = try await openForClipboard()
        let target = try await openForClipboard()
        source.cut(["README.md"])

        #expect(await target.paste(into: "") == .refuse(.cutElsewhere))
        #expect(target.alert?.title == ArchivePaste.refusalTitle)
        #expect(source.model?.item(at: "README.md") != nil)
        #expect(pasteboard.numberOfItems == 1)
        await source.document.closeOnMain()
        await target.document.closeOnMain()
    }

    // MARK: - Empty space

    /// A long press on the list's empty space shows ＋'s Paste, gated as ＋ is: no menu while ＋ is off
    /// (`canAdd`: read-only, saving), Paste off until the pasteboard holds something, in Select mode too.
    @Test func clipboardEmptySpaceMenuMatchesAddPaste() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()

        let empty = try #require(ArchiveEmptySpaceMenu.menu(for: state, into: ""))
        #expect(empty.children.count == 1)
        let emptyPaste = try #require(empty.children.first as? UIAction)
        #expect(emptyPaste.title == "Paste")
        #expect(emptyPaste.image != nil, "doc.on.clipboard, as ＋ > Paste")
        #expect(emptyPaste.attributes.contains(.disabled), "empty pasteboard, as ＋ > Paste")

        #expect(await state.copy(["README.md"]))
        let ready = try #require(ArchiveEmptySpaceMenu.menu(for: state, into: "")?.children.first as? UIAction)
        #expect(!ready.attributes.contains(.disabled))
        state.isSelecting = true
        state.selection = ["README.md"]
        let selecting = try #require(ArchiveEmptySpaceMenu.menu(for: state, into: "")?.children.first as? UIAction)
        #expect(!selecting.attributes.contains(.disabled), "＋ > Paste works in Select mode too")
        state.isSelecting = false

        state.session.saveFraction = 0.5
        #expect(ArchiveEmptySpaceMenu.menu(for: state, into: "") == nil, "＋ is off while a save runs")
        state.session.saveFraction = nil
        await state.document.closeOnMain()

        let rar = try await openForClipboard(format: .rar)
        #expect(ArchiveEmptySpaceMenu.menu(for: rar, into: "") == nil, "read-only: no ＋")
        await rar.document.closeOnMain()
    }

    /// ＋ > Paste and the empty-space Paste both start `paste(into:)` on the folder on screen.
    @Test func clipboardStartPastePastesIntoFolder() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let source = try await openForClipboard()
        let target = try await openForClipboard()
        #expect(await source.copy(["README.md"]))

        #expect(await target.startPaste(into: "assets").value == .add(into: "assets"))
        #expect(target.model?.item(at: "assets/README.md") != nil)
        #expect(target.alert == nil)
        await source.document.closeOnMain()
        await target.document.closeOnMain()
    }

    // MARK: - Commands

    /// The stock Copy, Cut and Paste (⌘C, ⌘X, ⌘V) on the Select-mode selection, as Delete; Paste into the
    /// folder on screen once the pasteboard holds something. None while a save runs, nor with no document.
    @Test func clipboardCommandsValidate() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        let copy = #selector(UIResponderStandardEditActions.copy(_:))
        let cut = #selector(UIResponderStandardEditActions.cut(_:))
        let paste = #selector(UIResponderStandardEditActions.paste(_:))

        #expect(!navigation.canPerformAction(copy, withSender: nil), "no selection outside Select mode")
        #expect(!navigation.canPerformAction(cut, withSender: nil))
        #expect(!navigation.canPerformAction(paste, withSender: nil), "empty pasteboard")
        state.isSelecting = true
        state.selection = ["README.md", "src", "src/main.swift"]
        #expect(navigation.canPerformAction(copy, withSender: nil))
        #expect(navigation.canPerformAction(cut, withSender: nil))

        navigation.cut(nil)
        #expect(await clipboardItem(pasteboard)?.paths == ["README.md", "src"])
        #expect(navigation.canPerformAction(paste, withSender: nil))

        state.session.saveFraction = 0.5
        #expect(!navigation.canPerformAction(copy, withSender: nil), "the copies would be dropped at the end")
        #expect(!navigation.canPerformAction(cut, withSender: nil))
        #expect(!navigation.canPerformAction(paste, withSender: nil))
        state.session.saveFraction = nil

        let none = ArchiveNavigationController(rootViewController: UIViewController())
        #expect(!none.canPerformAction(copy, withSender: nil))
        #expect(!none.canPerformAction(cut, withSender: nil))
        #expect(!none.canPerformAction(paste, withSender: nil))
        await state.document.closeOnMain()
    }

    /// Copy's and Paste's commands stay off while the search field or the name alert (Rename, New Folder) is
    /// up: its text field declines Copy and Cut with only a caret, and they would land here.
    @Test func clipboardCommandsOffWhileEnteringText() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        let actions = [#selector(UIResponderStandardEditActions.copy(_:)),
                       #selector(UIResponderStandardEditActions.cut(_:)),
                       #selector(UIResponderStandardEditActions.paste(_:))]
        state.isSelecting = true
        state.selection = ["README.md"]
        state.cut(["brief.pdf"])
        #expect(actions.allSatisfy { navigation.canPerformAction($0, withSender: nil) })

        state.isSearchPresented = true
        #expect(actions.allSatisfy { !navigation.canPerformAction($0, withSender: nil) }, "search")
        navigation.cut(nil)
        #expect(await clipboardItem(pasteboard)?.paths == ["brief.pdf"])
        state.isSearchPresented = false

        state.beginRename("README.md")
        #expect(state.renameRequest != nil)
        #expect(actions.allSatisfy { !navigation.canPerformAction($0, withSender: nil) }, "rename")
        navigation.cut(nil)
        #expect(await clipboardItem(pasteboard)?.paths == ["brief.pdf"])
        state.renameRequest = nil

        state.newFolder(in: "")
        #expect(state.renameRequest?.isNewFolder == true)
        #expect(actions.allSatisfy { !navigation.canPerformAction($0, withSender: nil) }, "new folder")
        state.renameRequest = nil
        await state.document.closeOnMain()
    }

    /// The stock Copy and Paste actions: ⌘C copies the selection, ⌘V pastes into the folder on screen.
    @Test func clipboardCopyAndPasteActions() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let source = try await openForClipboard()
        let target = try await openForClipboard()
        let from = ArchiveNavigationController(rootViewController: UIViewController())
        from.screenState = source
        let into = ArchiveNavigationController(rootViewController: UIViewController())
        into.screenState = target
        source.isSelecting = true
        source.selection = ["src/main.swift"]

        from.copy(nil)
        try await waitForClipboard { pasteboard.numberOfItems == 1 }
        #expect(await clipboardItem(pasteboard)?.paths == ["src/main.swift"])

        into.paste(nil)
        try await waitForClipboard { target.model?.item(at: "main.swift") != nil }
        #expect(target.model?.item(at: "main.swift") != nil)
        #expect(target.alert == nil)
        await source.document.closeOnMain()
        await target.document.closeOnMain()
    }

    /// Paste reads the pasteboard's types only, so SwiftUI is told when they may have changed: a pasteboard
    /// change, coming back to the foreground or active, a Copy in another window.
    @Test func clipboardGatesObserveChanges() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        let other = try await openForClipboard()
        #expect(!state.canPaste)

        let changed = try await invalidates({ state.canPaste }) {
            pasteboard.setItemProviders([NSItemProvider(object: "x.txt" as NSString)], localOnly: true, expirationDate: nil)
            NotificationCenter.default.post(name: UIPasteboard.changedNotification, object: pasteboard)
        }
        #expect(changed, "a pasteboard change")
        let file = try Fixture.copy("zip/deflate.zip")
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = try #require(NSItemProvider(contentsOf: file))
        let active = try await invalidates({ state.canPaste }) {
            pasteboard.setItemProviders([provider], localOnly: true, expirationDate: nil)
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        #expect(active, "back active")
        #expect(state.canPaste, "a file, written elsewhere")
        let copied = try await invalidates({ state.canCopy(["README.md"]) }) {
            _ = await other.copy(["README.md"])
        }
        #expect(copied, "a Copy in another window")
        await state.document.closeOnMain()
        await other.document.closeOnMain()
    }

    /// Paste is on for the Kernir item or a file, not for a text snippet; types only.
    @Test func clipboardPasteNeedsFileOrItem() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        pasteboard.string = "just text"
        #expect(!state.canPaste)
        #expect(await state.paste(into: "") == nil)

        state.cut(["README.md"])
        #expect(state.canPaste)
        await state.document.closeOnMain()
    }

    /// A text file copied in Files lists its own type only (no file URL, no name in the metadata): it counts
    /// as a file. Beside `public.utf8-plain-text` (what a text snippet writes) it doesn't.
    @Test func clipboardPasteTextFileTypes() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        func fileProvider(_ type: String) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) {
                completion in
                completion(nil, false, CocoaError(.fileNoSuchFile))
                return nil
            }
            return provider
        }
        for type in ["public.plain-text", "public.json", "public.comma-separated-values-text", "public.html"] {
            pasteboard.setItemProviders([fileProvider(type)], localOnly: true, expirationDate: nil)
            #expect(state.canPaste, "\(type)")
        }

        let snippet = fileProvider("public.plain-text")
        snippet.registerDataRepresentation(forTypeIdentifier: "public.utf8-plain-text", visibility: .all) {
            completion in
            completion(Data("x".utf8), nil)
            return nil
        }
        pasteboard.setItemProviders([snippet], localOnly: true, expirationDate: nil)
        #expect(!state.canPaste)
        await state.document.closeOnMain()
    }

    /// Paste follows its gate (`pastedFileType`): unnamed text files paste as files, named "Pasted Text" with
    /// their type's extension, numbered when there are several.
    @Test func clipboardPasteUnnamedTextFileAdds() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("pasted".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        pasteboard.setItemProviders([Self.unnamedFileProvider(file, type: "public.plain-text"),
                                     Self.unnamedFileProvider(file, type: "public.plain-text")],
                                    localOnly: true, expirationDate: nil)
        #expect(state.canPaste)

        #expect(await state.paste(into: "src") == .add(into: "src"))
        #expect(state.model?.item(at: "src/Pasted Text.txt") != nil)
        #expect(state.model?.item(at: "src/Pasted Text 2.txt") != nil)
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    /// The gate saw something to paste but Paste found nothing (a Kernir Copy item without its files): one alert.
    @Test func clipboardPasteNothingAlerts() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        let item = ArchiveClipboard(source: state.dragSourceID, operation: .copy, paths: ["README.md"])
        pasteboard.setItemProviders([Self.itemProvider(item.encoded())], localOnly: true, expirationDate: nil)
        #expect(state.canPaste)

        #expect(await state.paste(into: "src") == nil)
        #expect(state.alert?.title == "Couldn't Paste")
        #expect(state.alert?.message == ScreenState.nothingToPasteMessage)
        #expect(state.model?.item(at: "src/README.md") == nil)
        await state.document.closeOnMain()
    }

    /// The launch sweep is `exportRemoval`: no Copy starts until it ended (it could remove that Copy's folder).
    @Test func clipboardLaunchSweepGatesCopy() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        #expect(state.canCopy(["README.md"]))

        ScreenState.sweepClipboardExportsAtLaunch()
        #expect(ScreenState.exportRemoval != nil)
        #expect(!state.canCopy(["README.md"]))
        #expect(!(await state.copy(["README.md"])))
        await ScreenState.exportRemoval?.value
        #expect(ScreenState.exportRemoval == nil)
        #expect(await state.copy(["README.md"]))
        await ScreenState.exportRemoval?.value
        await state.document.closeOnMain()
    }

    /// Files from elsewhere (no Kernir item) paste as added files.
    @Test func clipboardPasteForeignFilesAdds() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        let file = try Fixture.copy("zip/deflate.zip")
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = try #require(NSItemProvider(contentsOf: file))
        provider.suggestedName = file.lastPathComponent
        pasteboard.setItemProviders([provider], localOnly: true, expirationDate: nil)
        #expect(state.canPaste)

        #expect(await state.paste(into: "src") == .add(into: "src"))
        #expect(state.model?.item(at: "src/\(file.lastPathComponent)") != nil)
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    /// A save landing during Copy's export drops the copies, with the busy alert; a Text Encoding reopen
    /// (the model replaced) too. The pasteboard stays as it was.
    @Test func clipboardCopyDroppedBySaveOrReopen() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard(extractDelay: .milliseconds(500))
        let other = try await openForClipboard(extractDelay: .milliseconds(500))

        let saved = Task { await state.copy(["README.md"]) }
        try await waitForClipboard { state.progress != nil }
        state.session.saveFraction = 0.5
        #expect(!(await saved.value))
        state.session.saveFraction = nil
        #expect(pasteboard.numberOfItems == 0)
        #expect(state.alert?.title == "Couldn't Copy")
        #expect(state.alert?.message == state.busyMessage(saving: true))

        let reopened = Task { await other.copy(["README.md"]) }
        try await waitForClipboard { other.progress != nil }
        other.session.phase = .ready(ArchiveModel(reader: FakeReader(entries: SampleArchive().entries),
                                                  undoManager: nil))
        #expect(!(await reopened.value))
        #expect(pasteboard.numberOfItems == 0)
        #expect(other.alert?.title == "Couldn't Copy")
        #expect(other.alert?.message == other.busyMessage(saving: false))
        #expect(exportFolders().isEmpty)
        await state.document.closeOnMain()
        await other.document.closeOnMain()
    }

    /// Something else copied during Copy's export stays on the pasteboard: the copies are dropped, silently.
    @Test func clipboardCopyKeepsWhatWasCopiedMeanwhile() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard(extractDelay: .milliseconds(500))

        let copied = Task { await state.copy(["README.md"]) }
        try await waitForClipboard { state.progress != nil }
        pasteboard.string = "theirs"
        #expect(!(await copied.value))
        #expect(pasteboard.string == "theirs")
        #expect(await clipboardItem(pasteboard) == nil)
        #expect(state.alert == nil)
        #expect(exportFolders().isEmpty)
        await state.document.closeOnMain()
    }

    /// One Copy export at a time in the process: a second Copy, of another window too, is refused while one
    /// runs. The next Copy's export stays, the previous one's folder goes (off the main actor).
    @Test func clipboardCopyOneAtATimeAndPreviousExportRemoved() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard(extractDelay: .milliseconds(300))
        let other = try await openForClipboard()

        let first = Task { await state.copy(["README.md"]) }
        try await waitForClipboard { state.progress != nil }
        #expect(!other.canCopy(["README.md"]))
        #expect(!(await other.copy(["README.md"])))
        #expect(await first.value)
        await ScreenState.exportRemoval?.value
        let before = exportFolders()
        #expect(before.count == 1)

        #expect(await other.copy(["brief.pdf"]))
        await ScreenState.exportRemoval?.value
        let after = exportFolders()
        #expect(after.count == 1)
        #expect(after.isDisjoint(with: before))
        #expect(pasteboard.itemProviders.map(\.suggestedName) == ["brief.pdf"])
        await state.document.closeOnMain()
        await other.document.closeOnMain()
    }

    /// A cut moved after Replace leaves the pasteboard: undoing the move doesn't let it paste again. One
    /// another writer replaced meanwhile stays.
    @Test func clipboardCutClearedAfterReplace() async throws {
        let pasteboard = beginPasteboard()
        defer { endPasteboard(pasteboard) }
        let state = try await openForClipboard()
        #expect(await state.copy(["README.md"]))
        #expect(await state.paste(into: "src") == .add(into: "src"))

        state.cut(["README.md"])
        #expect(await state.paste(into: "src") == .move(["README.md"], into: "src"))
        #expect(state.pendingReplacement?.moving == ["README.md"])
        state.confirmReplacement()
        #expect(state.model?.item(at: "README.md") == nil)
        #expect(pasteboard.numberOfItems == 0)
        state.undo()
        #expect(state.model?.item(at: "README.md") != nil)
        #expect(!state.canPaste)
        #expect(await state.paste(into: "src") == nil)

        state.cut(["README.md"])
        #expect(await state.paste(into: "src") == .move(["README.md"], into: "src"))
        pasteboard.string = "another writer"
        state.confirmReplacement()
        #expect(state.model?.item(at: "README.md") == nil)
        #expect(pasteboard.string == "another writer")
        await state.document.closeOnMain()
    }
}
