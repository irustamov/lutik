import AppKit
import SwiftUI

/// The single Settings window. With the AppKit lifecycle there is no SwiftUI `Settings` scene.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    /// Settings > General's default-app rows (the Welcome window's too); re-read whenever the window becomes key.
    let defaultApp: DefaultAppModel

    private init() {
        let defaultApp = DefaultAppModel.shared
        self.defaultApp = defaultApp
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(defaultApp: defaultApp)))
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        defaultApp.refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Opens the window, or brings the existing one to the front.
    @objc func showSettings(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
