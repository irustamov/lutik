import Foundation
import UIKit
import UniformTypeIdentifiers
import KernirCore

// Copy, Cut and Paste of archive items on iOS. The rules are `ArchivePaste`'s
// (App/Shared/ArchiveClipboard.swift); this part reads and writes the pasteboard.
//
// - Copy extracts the items into a fresh `Kernir-Clipboard-<process>/<UUID>` folder under the progress sheet
//   ("Copying…", Cancel) and puts one file provider per copy on the pasteboard, the first also carrying the
//   Kernir item (`.ownProcess`). The previous Copy's folder goes then: a paste here stages its own copy
//   (`addDropped`), so nothing reads it later, and it is removed off the main actor (`exportRemoval`). One Copy
//   export at a time, in the whole process.
// - Cut puts the Kernir item only: a paste in this document moves the items, anywhere else it is refused.
// - Paste adds the pasteboard's files (`addDropped`: Replace via `PendingReplacement`), moves a cut of this
//   document (`move(_:into:)`), or says why not in one alert.

extension ScreenState {
    /// The pasteboard Copy, Cut and Paste use: the general one; tests set a uniquely named one.
    @MainActor static var pasteboard: UIPasteboard = .general

    /// A Copy export, or a paste loading the pasteboard's files, runs somewhere in the process: no other
    /// starts. `removeExports` after a Copy would delete a running export's folder, or the copies a paste
    /// still reads, of this or another document's window.
    @MainActor private(set) static var clipboardOperations = 0 {
        didSet { ClipboardChanges.shared.bump() }
    }

    /// The previous Copy's export folders going, off the main actor, after a Copy: no Copy starts until they
    /// are gone (the sweep would take the new export's folder too). A paste may: it reads the kept one.
    /// Tests await it.
    @MainActor private(set) static var exportRemoval: Task<Void, Never>? {
        didSet { ClipboardChanges.shared.bump() }
    }

    /// The pasteboard's change count right after Lutik last wrote it, by pasteboard name: a cut pasted
    /// once is cleared only while it is still ours.
    @MainActor private static var clipboardWrites: [String: Int] = [:]

    // MARK: - Availability

    /// `paths` can be copied: it extracts, so read-only archives too; not while presenting is off, while a
    /// save or a Text Encoding reopen runs (the copies would be dropped at the end), while an operation of
    /// this document runs (the progress sheet), or while a Copy export, its folders' removal or a paste
    /// runs anywhere.
    func canCopy(_ paths: [String]) -> Bool {
        _ = ClipboardChanges.shared.tick
        guard allowsPresenting, !isBusy, runningOperations == 0, Self.clipboardOperations == 0,
              Self.exportRemoval == nil, let model, !paths.isEmpty else { return false }
        return paths.allSatisfy { model.item(at: $0) != nil }
    }

    /// `paths` can be cut: names can change (`canAdd`).
    func canCut(_ paths: [String]) -> Bool {
        guard canAdd, let model, !paths.isEmpty else { return false }
        return paths.allSatisfy { model.item(at: $0) != nil }
    }

    /// Something may be pasted: files can be added and the pasteboard holds the Lutik item or a file
    /// (`DroppedItem.fileType`). Its types only, never its contents: no paste prompt while menus validate.
    /// Observed through `ClipboardChanges`: the pasteboard and the process-wide gates aren't.
    var canPaste: Bool {
        _ = ClipboardChanges.shared.tick
        guard canAdd, runningOperations == 0, Self.clipboardOperations == 0 else { return false }
        return Self.holdsPasteable(Self.pasteboard)
    }

    /// `pasteboard` holds the Lutik item or a file (`pastedFileType`), by its items' types (metadata: no
    /// paste prompt).
    static func holdsPasteable(_ pasteboard: UIPasteboard) -> Bool {
        guard pasteboard.numberOfItems > 0, let items = pasteboard.types(forItemSet: nil) else { return false }
        return items.contains { types in
            types.contains(ArchiveClipboard.typeIdentifier) || pastedFileType(in: types) != nil
        }
    }

    /// The type a pasteboard item with `types` pastes as a file of (`DroppedItem.fileType`); nil when it is no
    /// file, or only the Lutik item. Paste's gate and Paste both ask it. An item's name isn't metadata: a text
    /// type counts as a file unless the item is `named` or also carries the UTF-8 or UTF-16 plain text a text
    /// snippet (`UIPasteboard.string`) writes; a text file copied in Files lists its own type only.
    static func pastedFileType(in types: [String], named: Bool = false) -> String? {
        let snippet = types.contains(UTType.utf8PlainText.identifier)
            || types.contains(UTType.utf16PlainText.identifier)
        let type = DroppedItem.fileType(in: types, named: named || !snippet)
        return type == ArchiveClipboard.typeIdentifier ? nil : type
    }

    /// The name an unnamed text file pastes under: "Pasted Text" with `type`'s extension.
    static func pastedTextName(_ type: String) -> String {
        let base = String(localized: "ScreenState.pastedTextName", defaultValue: "Pasted Text",
                          comment: "File name for a text file pasted (Paste) from the clipboard that has no name of its own. It becomes the file's name inside the archive, followed by the extension (e.g. “Pasted Text.txt”). Avoid “/” and “:”.")
        guard let ext = UTType(type)?.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }

    // MARK: - Copy, Cut, Paste

    /// Copy: extracts `paths` under the progress sheet ("Copying…", Cancel), then puts the copies and the
    /// Lutik item on the pasteboard. A cancel is silent; a failure gets one alert and leaves the pasteboard
    /// as it was. When something else was copied meanwhile (the change count moved), the copies are dropped,
    /// silently. When a save or a Text Encoding reopen landed meanwhile (the model swapped, its snapshot
    /// adopted, a save still writing), the copies are dropped instead, with the busy alert. True once the
    /// pasteboard was written.
    @discardableResult
    func copy(_ paths: [String]) async -> Bool {
        guard canCopy(paths), let model else { return false }
        let clipboard = ArchiveClipboard(source: dragSourceID, operation: .copy, paths: paths)
        guard !clipboard.paths.isEmpty else { return false }
        // The save and reopen counters (as `share`): a save that ends meanwhile adopts a new snapshot
        // (`snapshotGeneration`), one still writing shows as `isSaving`, a reopen counts in the document.
        let generation = model.snapshotGeneration
        let reopens = document.nameEncodingReopens
        // Something else copied meanwhile stays on the pasteboard.
        let pasteboard = Self.pasteboard
        let changeCount = pasteboard.changeCount
        Self.clipboardOperations += 1
        defer { Self.clipboardOperations -= 1 }
        let exported: (folder: URL, urls: [URL])
        do {
            exported = try await perform(ArchiveClipboard.progressTitle) { progress in
                try await ArchiveClipboard.export(clipboard.paths, from: model, progress: progress)
            }
        } catch {
            if error is CancellationError || (error as? ArchiveError) == .cancelled { return false }
            report(error, title: copyFailureTitle)
            return false
        }
        let reopened = self.model !== model || document.nameEncodingReopens != reopens
        let saved = isSaving || model.snapshotGeneration != generation
        let replaced = pasteboard.changeCount != changeCount
        guard !Task.isCancelled, !reopened, !saved, !replaced, !exported.urls.isEmpty else {
            // Never on the pasteboard: only this export's folder goes. Silent when something else was copied.
            ArchiveClipboard.removeExport(exported.folder)
            if !Task.isCancelled, !replaced, reopened || saved {
                alert = AlertContent(title: copyFailureTitle, message: busyMessage(saving: saved && !reopened))
            }
            return false
        }
        let providers = exported.urls.map { url -> NSItemProvider in
            let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
            provider.suggestedName = url.lastPathComponent
            return provider
        }
        Self.registerItem(clipboard.encoded(), on: providers[0])
        write(providers)
        // The previous Copy's folder: only after this export returned (one at a time, `clipboardOperations`),
        // off the main actor (a multi-GB tree), and no Copy starts until it is gone (`exportRemoval`).
        Self.removeExports(keeping: exported.folder)
        return true
    }

    /// Removes Copy's export folders but `kept`'s off the main actor, as `exportRemoval`: no Copy starts until
    /// they are gone. After a Copy (`kept`: its folder) and at launch (`sweepClipboardExportsAtLaunch`).
    private static func removeExports(keeping kept: URL?) {
        let removal = Task.detached(priority: .utility) {
            ArchiveClipboard.removeExports(in: FileManager.default.temporaryDirectory, keeping: kept)
        }
        exportRemoval = Task { @MainActor in
            await removal.value
            exportRemoval = nil
        }
    }

    private var copyFailureTitle: String {
        String(localized: "Couldn't Copy",
               comment: "Alert title when copying archive items to the clipboard (Copy) fails; the reason is shown below it.")
    }

    /// Cut: puts the Lutik item (no files) on the pasteboard; a paste in this document moves the items.
    func cut(_ paths: [String]) {
        guard canCut(paths) else { return }
        let clipboard = ArchiveClipboard(source: dragSourceID, operation: .cut, paths: paths)
        guard !clipboard.paths.isEmpty else { return }
        let provider = NSItemProvider()
        Self.registerItem(clipboard.encoded(), on: provider)
        write([provider])
    }

    /// Paste from a menu: ＋ > Paste and the long press on the list's empty space
    /// (`ArchiveEmptySpaceMenu`) both start it, into the folder on screen. Tests await the task.
    @discardableResult
    func startPaste(into folder: String) -> Task<PastePlan?, Never> {
        Task { await paste(into: folder) }
    }

    /// Paste into `folder` (the folder on screen): files add with Replace / Stop, a cut of this document
    /// moves (one "Move" undo step) and is cleared from the pasteboard once the items moved, after the Replace
    /// question too (`clearPastedCut`), while the pasteboard is still ours: an undone move is never pasted
    /// again. A refusal gets one alert, as nothing to paste does (the gate saw one, Paste found none). A text
    /// file without a name pastes as "Pasted Text" (`pastedTextName`). The plan it followed, nil when nothing
    /// was pasted.
    @discardableResult
    func paste(into folder: String) async -> PastePlan? {
        guard canPaste, model != nil else { return nil }
        let pasteboard = Self.pasteboard
        let name = pasteboard.name.rawValue
        let changeCount = pasteboard.changeCount
        Self.clipboardOperations += 1
        defer { Self.clipboardOperations -= 1 }
        let providers = pasteboard.itemProviders
        var clipboard: ArchiveClipboard?
        if let carrier = providers.first(where: { $0.registeredTypeIdentifiers.contains(ArchiveClipboard.typeIdentifier) }) {
            let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                Self.loadItem(from: carrier) { continuation.resume(returning: $0) }
            }
            clipboard = data.flatMap(ArchiveClipboard.decoded)
        }
        // The gate's rule (`pastedFileType`): the item's own type is no file, a cut's provider holds nothing to
        // add. An unnamed text file gets a name, or `addDropped` would skip it as a text snippet.
        var files: [NSItemProvider] = []
        var defaultNames: Set<String> = []
        for provider in providers {
            guard let type = Self.pastedFileType(in: provider.registeredTypeIdentifiers,
                                                 named: !(provider.suggestedName ?? "").isEmpty) else { continue }
            if DroppedItem.fileType(of: provider) == nil {
                provider.suggestedName = StagingArea.uniqueName(Self.pastedTextName(type), among: &defaultNames)
            }
            files.append(provider)
        }
        guard let model, canAdd else { return nil }
        guard let plan = ArchivePaste.plan(clipboard, hasFiles: !files.isEmpty, here: dragSourceID, into: folder,
                                           exists: { model.item(at: $0) != nil })
        else {
            alert = AlertContent(title: ArchivePaste.refusalTitle, message: Self.nothingToPasteMessage)
            return nil
        }
        switch plan {
        case .add(let directory):
            await addDropped(files, to: directory)
        case .move(let roots, let directory):
            // All already there: nothing to do, and the cut stays.
            guard !roots.isEmpty else { break }
            move(roots, into: directory)
            if pendingReplacement?.moving == roots {
                // Cleared once Replace moved them (`confirmReplacement`), if the pasteboard is unchanged.
                pendingReplacement?.pastedCut = PastedCut(pasteboard: name, changeCount: changeCount)
            } else if !roots.contains(where: { model.item(at: $0) != nil }) {
                Self.clearIfStillOurs(pasteboard)
            }
        case .refuse(let refusal):
            alert = AlertContent(title: ArchivePaste.refusalTitle, message: ArchivePaste.message(for: refusal))
        }
        return plan
    }

    /// Paste's alert message (title `ArchivePaste.refusalTitle`) when its plan comes out empty.
    static var nothingToPasteMessage: String {
        String(localized: "Nothing on the clipboard can be pasted here.",
               comment: "Alert message under “Couldn't Paste” when the clipboard looked like it held files or copied archive items, but none could be pasted.")
    }

    // MARK: - The pasteboard

    /// Replaces the pasteboard's items with `providers` and notes the change count as ours.
    private func write(_ providers: [NSItemProvider]) {
        let pasteboard = Self.pasteboard
        pasteboard.setItemProviders(providers, localOnly: false, expirationDate: nil)
        Self.clipboardWrites[pasteboard.name.rawValue] = pasteboard.changeCount
    }

    /// After Replace moved a pasted cut's items (`confirmReplacement`): the cut leaves the pasteboard, when
    /// the items did move and the pasteboard still holds that cut, ours.
    func clearPastedCut(_ cut: PastedCut, moved paths: [String]) {
        let pasteboard = Self.pasteboard
        guard let model, !paths.contains(where: { model.item(at: $0) != nil }),
              pasteboard.name.rawValue == cut.pasteboard, pasteboard.changeCount == cut.changeCount else { return }
        Self.clearIfStillOurs(pasteboard)
    }

    /// Clears `pasteboard` when Lutik's last write is still what it holds.
    static func clearIfStillOurs(_ pasteboard: UIPasteboard) {
        let name = pasteboard.name.rawValue
        guard let written = clipboardWrites[name], written == pasteboard.changeCount else { return }
        pasteboard.items = []
        clipboardWrites[name] = nil
    }

    /// The Lutik item on `provider`, for this process only. Nonisolated: UIKit calls the handler off main.
    private nonisolated static func registerItem(_ data: Data, on provider: NSItemProvider) {
        provider.registerDataRepresentation(forTypeIdentifier: ArchiveClipboard.typeIdentifier,
                                            visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
    }

    /// Loads the Lutik item's data from `provider`; nil when it has none. Nonisolated, so the handler UIKit
    /// calls off main isn't a main-actor closure.
    private nonisolated static func loadItem(from provider: NSItemProvider,
                                             _ done: @escaping @Sendable (Data?) -> Void) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: ArchiveClipboard.typeIdentifier) { data, _ in
            done(data)
        }
    }

    /// The launch sweep (`AppDelegate`): `sweepClipboardExports` off the main actor, as `exportRemoval`, so
    /// a Copy started right at launch doesn't run while it may still remove that Copy's folder.
    static func sweepClipboardExportsAtLaunch() {
        removeExports(keeping: nil)
    }

    /// The launch sweep of Copy's export folders (`AppDelegate`): those of runs that are gone. Never one
    /// another running process holds (`ArchiveClipboard.removeExports`).
    nonisolated static func sweepClipboardExports(in temporary: URL = FileManager.default.temporaryDirectory) {
        ArchiveClipboard.removeExports(in: temporary, keeping: nil)
    }
}

/// A cut pasted into a folder holding items of the same names: its pasteboard and change count, so Replace
/// clears that cut once the items moved (`ScreenState.clearPastedCut`).
struct PastedCut {
    var pasteboard: String
    var changeCount: Int
}

/// Bumped when what Copy's and Paste's gates read may have changed unobserved: the pasteboard (a change in
/// this app, or in another one while Lutik was away: back in the foreground, active again), and the
/// process-wide clipboard gates (a Copy or a paste in another window). `canCopy` and `canPaste` read `tick`,
/// so SwiftUI updates the row menu's Copy and the ＋ menu's Paste. Notifications only: no pasteboard read.
@MainActor @Observable
final class ClipboardChanges {
    static let shared = ClipboardChanges()

    private(set) var tick = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let names: [Notification.Name] = [
            UIPasteboard.changedNotification, UIPasteboard.removedNotification,
            UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willEnterForegroundNotification, UIScene.didActivateNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClipboardChanges.shared.bump() }
            }
        }
    }

    func bump() {
        tick &+= 1
    }
}
