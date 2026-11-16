import Cocoa
import os
import QuickLookUI
import SwiftUI

/// Quick Look preview for archives: Space on an archive in Finder.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let log = Logger(subsystem: "com.kernir.app", category: "preview")

    override func loadView() { view = NSView() }

    /// Errors propagate so Quick Look falls back to its generic preview.
    func preparePreviewOfFile(at url: URL) async throws {
        let started = ContinuousClock.now
        let content = try await PreviewLoader.load(url)
        let hosting = NSHostingView(rootView: ArchivePreviewView(content: content))
        // Fill whatever size the panel gives us instead of shrinking to the
        // SwiftUI ideal size (ContentUnavailableView is small).
        hosting.sizingOptions = []
        // Quick Look has already bridged `view` to the host by now: replacing it
        // kills the view service under qlmanage (ViewBridge Code=17), so add inside it.
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting)
        preferredContentSize = NSSize(width: 640, height: 480)
        let elapsed = started.duration(to: .now)
        let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        Self.log.info("preparePreviewOfFile finished in \(ms) ms")
    }
}
