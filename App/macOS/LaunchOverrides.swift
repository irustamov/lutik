import AppKit

/// Launch-argument hooks for the CI screenshot UI test (`-KernirWindowFrame 1024x640`,
/// `-KernirAppearance light|dark`) and the Quick Look UI tests (`-KernirPreviewStandInDelay 3`,
/// `-KernirOpenWithDryRun YES`, `-KernirPreviewFrameAutosave NO`) and the Welcome UI tests
/// (`-KernirDefaultAppDryRun YES`, `-KernirWelcomeReset YES`).
/// Launch arguments land in `UserDefaults`' argument domain. Without the arguments every hook
/// does nothing.
enum LaunchOverrides {
    /// Upper bound for a window side, in points; anything larger is treated as malformed.
    private static let maxSide = 10_000

    /// "WxH" with plain decimal digits and positive sizes up to `maxSide`; anything else is nil.
    static func parseFrame(_ text: String?) -> CGSize? {
        guard let text else { return nil }
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var sides: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let value = Int(part), value > 0, value <= maxSide else { return nil }
            sides.append(value)
        }
        return CGSize(width: sides[0], height: sides[1])
    }

    /// "light" is Aqua, "dark" is Dark Aqua; anything else is nil.
    static func parseAppearance(_ text: String?) -> NSAppearance? {
        switch text {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    /// Upper bound for the stand-in delay, in seconds; anything larger is treated as malformed.
    private static let maxDelay = 60.0

    /// Seconds, a plain decimal number above 0 and up to `maxDelay`; anything else is nil.
    static func parseDelay(_ text: String?) -> Duration? {
        guard let text, !text.isEmpty, text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }),
              let seconds = Double(text), seconds > 0, seconds <= maxDelay else { return nil }
        return .milliseconds(Int((seconds * 1000).rounded()))
    }

    /// How long each Quick Look stand-in waits before it is made (`PreviewWindowSource`), so the
    /// UI tests can close or leave a window mid-render instead of racing a ~0.3 s render.
    static var previewStandInDelay: Duration? {
        parseDelay(argument("KernirPreviewStandInDelay"))
    }

    /// "NO" turns preview frame autosaving off; "YES", anything else or no argument leaves it on.
    static func parsePreviewFrameAutosaveDisabled(_ text: String?) -> Bool {
        text == "NO"
    }

    /// `-KernirPreviewFrameAutosave NO` (Quick Look UI tests): the preview window neither reads
    /// nor writes its autosaved frame, so a frame saved by an earlier run never changes where it
    /// opens (`PreviewWindowController.autosaveName`). Unlike `openWithDryRun` this stays compiled
    /// in release, because `PreviewWindowController` reads it unconditionally; it is Debug-only
    /// through `argument(_:)`, which is nil in release, so there it is always false.
    static var previewFrameAutosaveDisabled: Bool {
        parsePreviewFrameAutosaveDisabled(argument("KernirPreviewFrameAutosave"))
    }

    #if DEBUG
    /// `-KernirOpenWithDryRun YES` (UI tests): opening a file in another app only reports the file
    /// and the app (`ArchiveActions.launchInApp`), so a test never launches a third-party app.
    /// Debug builds only: the release app has no such switch at all.
    static var openWithDryRun: Bool {
        argument("KernirOpenWithDryRun") == "YES"
    }

    /// `-KernirDefaultAppDryRun YES` (UI tests): "Make … the Default App" only records the types
    /// (`DryRunDefaultAppWorkspace`), so a test never changes the machine's default apps.
    static var defaultAppDryRun: Bool {
        argument("KernirDefaultAppDryRun") == "YES"
    }

    /// `-KernirWelcomeReset YES` (UI tests): at launch, forget that the Welcome window was seen and
    /// its "Show at launch" choice, as on a first launch. The UI tests that keep it closed pass
    /// `-KernirWelcomeSeen YES -KernirWelcomeShowAtLaunch NO`, which `WelcomeSettings` reads from
    /// the argument domain like any default.
    static var welcomeReset: Bool {
        argument("KernirWelcomeReset") == "YES"
    }

    /// A plain file name: ASCII letters, digits, `-`, `_` and `.`, not starting with a dot, 1 to 100
    /// characters; anything else (a path, spaces, nil) is nil.
    static func parseSnapshotName(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= 100, !text.hasPrefix("."),
              text.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                      || byte == 0x2D || byte == 0x5F || byte == 0x2E
              }) else { return nil }
        return text
    }

    /// `-WelcomeSnapshot <name>` (Debug): once the Welcome window shows,
    /// `snapshotWelcome(_:named:)` writes it to `<temporary directory>/<name>.png` and quits.
    static var welcomeSnapshot: String? {
        parseSnapshotName(argument("WelcomeSnapshot"))
    }

    /// About a second after the Welcome window shows (so its images are in), renders its content
    /// at 2x with `cacheDisplay` (no Screen Recording permission needed, but no title bar) over the
    /// window's background colour, as on screen, into `<temporary directory>/<name>.png`; logs the
    /// path and quits. The next run with the same name overwrites it: copy the file out first.
    @MainActor
    static func snapshotWelcome(_ window: NSWindow, named name: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if let view = window.contentView {
                view.layoutSubtreeIfNeeded()
                let bounds = view.bounds
                if let content = snapshotBitmap(size: bounds.size), let flat = snapshotBitmap(size: bounds.size),
                   let context = NSGraphicsContext(bitmapImageRep: flat) {
                    view.cacheDisplay(in: bounds, to: content)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        window.backgroundColor.setFill()
                        bounds.fill()
                    }
                    content.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                                 respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    writeSnapshot(flat.representation(using: .png, properties: [:]),
                                  to: FileManager.default.temporaryDirectory.appending(path: "\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// An empty 2x RGBA bitmap of `size` points.
    private static func snapshotBitmap(size: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func writeSnapshot(_ data: Data?, to url: URL) {
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
            NSLog("WelcomeSnapshot: wrote %@", url.path)
        } catch {
            NSLog("WelcomeSnapshot: failed %@: %@", url.path, String(describing: error))
        }
    }
    #endif

    static var windowFrame: CGSize? {
        parseFrame(argument("KernirWindowFrame"))
    }

    static var appearance: NSAppearance? {
        parseAppearance(argument("KernirAppearance"))
    }

    /// Launch arguments only (not a stray `defaults write`), and only in Debug builds, which is
    /// what CI's UI tests run: the release app carries no test hooks.
    private static func argument(_ key: String) -> String? {
        #if DEBUG
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
        #else
        nil
        #endif
    }

    /// Applies both hooks to a new archive window; returns true when it set the frame (so the
    /// caller skips the cascade).
    @MainActor
    static func apply(to window: NSWindow, frame: CGSize? = windowFrame) -> Bool {
        if let appearance { NSApp.appearance = appearance }
        guard let size = frame else { return false }
        window.setFrame(centered(size, on: NSScreen.screens.first?.visibleFrame), display: false)
        return true
    }

    /// `size` centered on `display`, the menu-bar display's visible frame: that is the display
    /// `XCUIScreen.main` captures. `window.center()` picks `NSScreen.main`, the display with the
    /// key window, so with two displays a shot could land on the other one.
    static func centered(_ size: CGSize, on display: NSRect?) -> NSRect {
        guard let display else { return NSRect(origin: .zero, size: size) }
        return NSRect(x: (display.midX - size.width / 2).rounded(), y: (display.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
}
