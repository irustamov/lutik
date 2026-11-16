import AppKit
import SwiftUI

/// The Welcome window, like Xcode's: non-modal, fixed size, centred, its header art reaching under
/// the title bar. Esc and ⌘W close it. Once it becomes key it counts as the user using the app for
/// the Services quit rule (`AppDelegate.windowDidOpen`): it opens by itself only at a launch that
/// already counts (AppKit's usual one, or one that opens a document).
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    /// The window's identifier, for `isWelcomeWindow(_:)`.
    static let identifier = NSUserInterfaceItemIdentifier("KernirWelcome")

    let settings: WelcomeSettings
    let defaultApp: DefaultAppModel
    /// Which document window closes it (`AppDelegate.windowDidOpen` asks it, for every document window).
    let documentWindows: WelcomeDocumentWindows

    init(settings: WelcomeSettings = WelcomeSettings(), defaultApp: DefaultAppModel = .shared,
         documentWindows: WelcomeDocumentWindows) {
        self.settings = settings
        self.defaultApp = defaultApp
        self.documentWindows = documentWindows
        let window = WelcomeWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                                   backing: .buffered, defer: true)
        window.identifier = Self.identifier
        window.title = WelcomeFeature.welcomeTitle(appName: defaultApp.appName)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior.insert(.fullScreenNone)
        super.init(window: window)
        let host = NSHostingController(rootView: WelcomeView(
            defaultApp: defaultApp, settings: settings,
            openArchive: { NSDocumentController.shared.openDocument(nil) },
            newArchive: { NSDocumentController.shared.newDocument(nil) }))
        host.sizingOptions = .preferredContentSize
        // The header reaches under the title bar: the content ignores every safe area here. With
        // `.ignoresSafeArea` in the view instead, the title bar's inset changing as the window
        // sizes itself re-ran the window's constraints until AppKit threw (a layout loop).
        host.safeAreaRegions = []
        window.contentViewController = host
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func isWelcomeWindow(_ window: NSWindow) -> Bool {
        window.identifier == identifier
    }

    var isShowing: Bool { window?.isVisible == true }

    /// Opens the window centred, or brings it forward, and records it as seen. With a document opening (`withDocument`)
    /// it comes forward without taking the keyboard from that document; the windows of the files the launch asked
    /// to open (`awaiting`) don't close it (`WelcomeDocumentWindows`).
    func show(withDocument: Bool = false, awaiting urls: [URL] = []) {
        guard let window else { return }
        if let appearance = LaunchOverrides.appearance { NSApp.appearance = appearance }
        documentWindows.welcomeShown(openDocuments: NSDocumentController.shared.documents, awaiting: urls)
        settings.markSeen()
        defaultApp.refresh()
        if !window.isVisible { window.center() }
        if withDocument {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        #if DEBUG
        if let name = LaunchOverrides.welcomeSnapshot {
            LaunchOverrides.snapshotWelcome(window, named: name)
        }
        #endif
    }

    func windowDidBecomeKey(_ notification: Notification) {
        defaultApp.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        documentWindows.welcomeClosed()
    }
}

/// Esc closes it, like a sheet's Cancel.
final class WelcomeWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
