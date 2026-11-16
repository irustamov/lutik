import AppKit
import SwiftUI

// The live AppKit side of Finder Services' jobs what ServicesJobs.swift takes as
// seams. Kept apart so that file runs in the plain unit tests; this one shows real panels and is
// checked in the hosted and UI runs only.

extension ServicesJobRunner {
    /// The app's runner: the grants Extract Here keeps (`ExtractHereEffects.folderAccessStore`,
    /// the UI tests' own key under their launch arguments), an app-modal Allow panel, and an
    /// app-modal offer of another folder (`ServicesOtherFolderPanel`), and Extract
    /// Here's Trash setting, kept off an archive open in a Lutik document window. The Trash itself
    /// is the runner's default, `ExtractHereEffects.moveToTrash`. `settings` is read at each job.
    static func live(store: FolderAccessStore = ExtractHereEffects.folderAccessStore(),
                     settings: ExtractHereSettings = ExtractHereSettings()) -> ServicesJobRunner {
        ServicesJobRunner(access: { store.access(for: $0) },
                          grant: { try store.grant($0) },
                          askForAccess: { destination, job in ServicesAllowPanel.ask(for: destination, job: job) },
                          offerAnotherFolder: { failure, job in ServicesOtherFolderPanel.offer(failure, job: job) },
                          movesArchiveToTrash: { settings.movesArchiveToTrash },
                          openInKernir: { archive in
                              Self.openState(of: archive, in: NSDocumentController.shared.documents.map {
                                  (fileURL: $0.fileURL, isEdited: $0.isDocumentEdited)
                              })
                          })
    }
}

/// The Allow panel (`FolderAccessPanel`), app-modal: a Services job has no window for a sheet.
/// The user may pick the folder or any folder containing it; a pick that doesn't contain it gets
/// the same alert as the sheet's, then the panel again.
@MainActor
enum ServicesAllowPanel {
    /// The folder picked, or nil for Cancel.
    static func ask(for destination: URL, job: ServicesJob) -> URL? {
        // A Services-only launch runs in the background: bring the panel in front.
        NSApp.activate()
        while true {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = destination
            panel.message = message(for: destination, job: job)
            panel.prompt = String(localized: "Allow") // The same key as `FolderAccessPanel`, which has the comment.
            guard panel.runModal() == .OK, let picked = panel.url else { return nil }
            if FolderAccessStore.covers(picked, destination) { return picked }
            FolderAccessPanel.wrongFolderAlert(for: destination).runModal()
        }
    }

    /// Extract Here's text is the sheet's; Compress says what it writes.
    static func message(for destination: URL, job: ServicesJob) -> String {
        switch job {
        case .extractHere:
            FolderAccessPanel.message(for: destination)
        case .compress:
            String(localized: "Lutik needs permission to save the archive in “\(ServicesJobRunner.displayName(of: destination))”.",
                   comment: "Message at the top of the folder panel that asks for access before Finder's “Compress with Lutik” writes the new archive. %@ = the destination folder's name, as Finder shows it.")
        }
    }
}

/// App-modal like the Allow panel (a Services job has no window for a sheet):
/// an alert with the failure's title and reason offers another folder (`ServicesOtherFolderText`),
/// and its button opens a folder panel in the user's real Downloads (`otherFolderStart`).
@MainActor
enum ServicesOtherFolderPanel {
    /// The folder picked, or nil for Cancel in the alert or the panel.
    static func offer(_ failure: ServicesJobFailure, job: ServicesJob) -> URL? {
        // A Services-only launch runs in the background: bring the alert in front.
        NSApp.activate()
        return offer(ServicesOtherFolderText(failure: failure, job: job),
                     alert: { alert(for: $0).runModal() },
                     panel: { text in
                         let panel = NSOpenPanel()
                         configure(panel, text: text)
                         return (panel.runModal(), panel.url)
                     })
    }

    /// The offer's flow, the alert and the panel being shown by the caller: only the alert's first
    /// button goes on to the panel (`FolderAccessPanel.choosesAnotherFolder`), and the panel's
    /// pick counts only after OK (`FolderAccessPanel.pick`).
    static func offer(_ text: ServicesOtherFolderText,
                      alert: (ServicesOtherFolderText) -> NSApplication.ModalResponse,
                      panel: (ServicesOtherFolderText) -> (NSApplication.ModalResponse, URL?)) -> URL? {
        guard FolderAccessPanel.choosesAnotherFolder(alert(text)) else { return nil }
        let (response, url) = panel(text)
        return FolderAccessPanel.pick(response, url)
    }

    /// The failure's title and reason, with the job's button (the default) and Cancel.
    static func alert(for text: ServicesOtherFolderText) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.information
        alert.addButton(withTitle: text.choose)
        alert.addButton(withTitle: text.cancel)
        return alert
    }

    /// The other-folder panel (one folder, new folders allowed, opened in the real Downloads),
    /// with the job's message and prompt.
    static func configure(_ panel: some FolderPanelSettings, text: ServicesOtherFolderText) {
        FolderAccessPanel.configureOtherFolderPanel(panel)
        panel.message = text.panelMessage
        panel.prompt = text.panelPrompt
    }
}

extension ServicesJobEffects {
    /// The app's effects. `launchFlag` is `AppDelegate`'s, read when the queue drains.
    /// The alert is modal: `showAlert` returns once it is dismissed.
    @MainActor
    static func live(launchFlag: @escaping @MainActor () -> ServicesLaunchFlag) -> ServicesJobEffects {
        let panel = ServicesProgressPanel()
        return ServicesJobEffects(
            reveal: { ExtractHereEffects.reveal($0) },
            openDocument: { url in
                NSApp.activate()
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    guard let error, (error as NSError).code != CocoaError.userCancelled.rawValue else { return }
                    NSApp.presentError(error)
                }
            },
            showAlert: { text in
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = text.message
                alert.informativeText = text.information
                alert.runModal()
            },
            appState: { ServicesQuitState.live(flag: launchFlag()) },
            terminate: { NSApp.terminate(nil) },
            progress: ServicesProgressDisplay(show: { panel.show(title: $0, stop: $1) },
                                              update: { panel.update($0) },
                                              hide: { panel.hide() }))
    }
}

extension ServicesQuitState {
    /// The app's side of the quit rule as AppKit has it now: `flag`, then the documents and
    /// windows (`countsAsOpen`), the panels on screen (an Open panel, About; the queue's progress
    /// panel and alerts are gone by the time it drains; one hidden as Finder came in front counts
    /// through the menu action that opened it, `ServicesMenuActivity`), and a modal session.
    @MainActor
    static func live(flag: ServicesLaunchFlag) -> ServicesQuitState {
        let windows = NSApp.windows
        return ServicesQuitState(
            flag: flag,
            hasDocumentWindows: !NSDocumentController.shared.documents.isEmpty
                || windows.contains {
                    ServicesJobEffects.countsAsOpen(isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized,
                                                    isPanel: $0 is NSPanel)
                },
            hasVisiblePanels: windows.contains { $0 is NSPanel && $0.isVisible },
            hasModal: NSApp.modalWindow != nil)
    }
}

/// An action the user sends from the app's menu bar (About, File > Open, Open Recent,
/// Settings…) counts as using the app (`ServicesLaunchFlag.noteOpened`), chosen with the mouse
/// (menu tracking calls `performActionForItem(at:)`, which posts both notifications) or by a key
/// equivalent (checked in the hosted run; File > Open's ⌘O counts through
/// `KernirDocumentController.openDocument(_:)` in any case). The panels it opens may hide when
/// Finder comes in front (`NSPanel.hidesOnDeactivate`), so the quit rule's visible-panel check
/// alone would quit under them. Only menus under `mainMenu` count: the Services jobs send no menu
/// actions (Finder's request comes to `ServicesProvider`, alerts and the progress panel have
/// buttons only), and the menus inside the Allow panel (its pop-ups, a sidebar's menu) aren't the
/// menu bar's. Nor do actions while the queue's own prompt is up (`isQueuePrompting`,
/// `ServicesJobQueue.isPrompting`): the menu bar still works under an app-modal panel, and ⌘V or
/// ⌘A in the Allow panel's Go to Folder go through the Edit menu. Both notifications: `willSend`
/// comes before an action that runs a modal panel and returns only once it closes.
@MainActor
final class ServicesMenuActivity: NSObject {
    private let mainMenu: @MainActor () -> NSMenu?
    private let isQueuePrompting: @MainActor () -> Bool
    private let noteOpened: @MainActor () -> Void

    init(center: NotificationCenter = .default, mainMenu: @escaping @MainActor () -> NSMenu? = { NSApp.mainMenu },
         isQueuePrompting: @escaping @MainActor () -> Bool, noteOpened: @escaping @MainActor () -> Void) {
        self.mainMenu = mainMenu
        self.isQueuePrompting = isQueuePrompting
        self.noteOpened = noteOpened
        super.init()
        for name in [NSMenu.willSendActionNotification, NSMenu.didSendActionNotification] {
            center.addObserver(self, selector: #selector(menuSendsAction(_:)), name: name, object: nil)
        }
    }

    /// The activity `AppDelegate` uses: `queue` prompts through `ServicesJobQueue.isPrompting`,
    /// held weakly (the app delegate owns the queue).
    convenience init(queue: ServicesJobQueue, center: NotificationCenter = .default,
                     mainMenu: @escaping @MainActor () -> NSMenu? = { NSApp.mainMenu },
                     noteOpened: @escaping @MainActor () -> Void) {
        self.init(center: center, mainMenu: mainMenu, isQueuePrompting: { [weak queue] in queue?.isPrompting ?? false },
                  noteOpened: noteOpened)
    }

    /// A menu sends an item's action (AppKit posts it on the main thread).
    @objc private func menuSendsAction(_ notification: Notification) {
        guard !isQueuePrompting() else { return }
        guard let menu = notification.object as? NSMenu, Self.isInMenuBar(menu, mainMenu: mainMenu()) else { return }
        noteOpened()
    }

    /// Whether `menu` is `mainMenu` or one of its submenus, at any depth.
    static func isInMenuBar(_ menu: NSMenu, mainMenu: NSMenu?) -> Bool {
        guard let mainMenu else { return false }
        var current: NSMenu? = menu
        while let menu = current {
            if menu === mainMenu { return true }
            current = menu.supermenu
        }
        return false
    }
}

/// A Services job's progress with no archive window to hold a sheet: a small floating panel
/// hosting the window's own `ProgressSheet`, whose Cancel button stops the job.
@MainActor
final class ServicesProgressPanel {
    private var panel: NSPanel?
    private var hosting: NSHostingView<ProgressSheet>?
    private var progress: OperationProgress?

    func show(title: String, stop: @escaping @MainActor () -> Void) {
        let progress = OperationProgress(title: title, fraction: nil, cancel: stop)
        self.progress = progress
        if let hosting {
            hosting.rootView = ProgressSheet(progress: progress)
        } else {
            let hosting = NSHostingView(rootView: ProgressSheet(progress: progress))
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.contentView = hosting
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            self.hosting = hosting
            self.panel = panel
        }
        panel?.center()
        // A Services-only launch runs in the background: show it without taking focus from Finder.
        panel?.orderFrontRegardless()
    }

    func update(_ fraction: Double) {
        guard var progress else { return }
        progress.fraction = max(progress.fraction ?? 0, fraction)
        self.progress = progress
        hosting?.rootView = ProgressSheet(progress: progress)
    }

    func hide() {
        progress = nil
        panel?.orderOut(nil)
    }
}
