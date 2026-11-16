import SwiftUI
import UIKit
import KernirCore
import os

/// New Archive from the document browser (the iOS 18+ launch browser and the iOS 17 fallback):
/// the options sheet, then an empty archive for the browser to import.
@MainActor enum NewArchiveFlow {
    typealias ImportHandler = (URL?, UIDocumentBrowserViewController.ImportMode) -> Void

    private static let logger = Logger(subsystem: "com.kernir.app", category: "new-archive")

    /// The first writable format with its defaults, not encrypted, unsplit. "Exclude Mac metadata"
    /// starts at the shared default; the document keeps the choice for its later saves.
    static func defaultSettings() -> ArchiveSaveSettings {
        let options = ArchiveWriteOptions(excludesMacMetadata: ArchiveSaveSettings.excludesMacMetadataByDefault)
        var settings = ArchiveSaveSettings(format: ArchiveFormat.writable.first ?? .zip, options: options)
        // Also syncs `options.volumeSize` with `split` (none), which the memberwise init doesn't.
        settings.formatDidChange()
        return settings
    }

    /// Asks for the options, then writes the empty archive and hands it to `importHandler` to move
    /// into place. Cancel, or a failed write, calls `importHandler(nil, .none)`, as UIKit expects.
    static func present(from presenter: UIViewController, importHandler: @escaping ImportHandler) {
        let once = Once(importHandler)
        let host = HostBox()
        let sheet = SaveOptionsSheet(purpose: .newArchive, settings: defaultSettings(), onCancel: {
            host.controller?.dismiss(animated: true)
            once.call(nil, .none)
        }, onConfirm: { [weak presenter] settings in
            let start: @MainActor () -> Void = {
                Task { @MainActor in
                    do {
                        let url = try await create(with: settings)
                        logger.info("Created \(url.lastPathComponent, privacy: .public); importing")
                        once.call(url, .move)
                    } catch {
                        logger.error("Cannot create: \(error.localizedDescription, privacy: .public)")
                        once.call(nil, .none)
                        if let presenter { showError(error, from: presenter) }
                    }
                }
            }
            // The write starts once the sheet has gone, so an error alert can come up.
            if let controller = host.controller {
                controller.dismiss(animated: true) { start() }
            } else {
                start()
            }
        })
        let controller = KeyFocusHostingController(rootView: sheet)
        controller.modalPresentationStyle = .formSheet
        controller.isModalInPresentation = true
        host.controller = controller
        presenter.present(controller, animated: true)
    }

    /// Writes an empty "Untitled.<ext>" with `settings` into a new temporary folder and keeps the
    /// settings for its document. Returns the file.
    static func create(with settings: ArchiveSaveSettings) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(
            ArchiveSaveSettings.fileName(String(localized: "Untitled"), for: settings.format))
        do {
            try await ArchiveDocument.makeEmpty(at: url, settings: settings)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        ArchiveDocument.registerNewArchive(settings, at: url)
        return url
    }

    /// The browser moved the new archive from `source` to `destination` (maybe renamed, as
    /// "Untitled 2.zip"); its settings follow it there, for its document to adopt when it opens.
    static func didImport(from source: URL, to destination: URL) {
        logger.info("""
            Imported \(source.lastPathComponent, privacy: .public) as \
            \(destination.lastPathComponent, privacy: .public)
            """)
        ArchiveDocument.newArchiveDidMove(from: source, to: destination)
        removeTemporaryFolder(of: source)
    }

    /// The browser couldn't import the new archive: its settings and temporary file go.
    static func didFailToImport(_ source: URL, error: (any Error)?, presenter: UIViewController) {
        logger.error("""
            Cannot import \(source.lastPathComponent, privacy: .public): \
            \(error?.localizedDescription ?? "no error", privacy: .public)
            """)
        _ = ArchiveDocument.takeNewArchiveSettings(for: source)
        removeTemporaryFolder(of: source)
        if let error { showError(error, from: presenter) }
    }

    private static let folderName = "NewArchive"

    /// Removes the folder `create` made for `file`, and nothing else.
    private static func removeTemporaryFolder(of file: URL) {
        let folder = file.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().lastPathComponent == folderName else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func showError(_ error: any Error, from presenter: UIViewController) {
        let alert = UIAlertController(title: String(localized: "Couldn't create the archive"),
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        presenter.present(alert, animated: true)
    }

    /// Calls the import handler once: UIKit expects exactly one call.
    private final class Once {
        private var handler: ImportHandler?

        init(_ handler: @escaping ImportHandler) {
            self.handler = handler
        }

        func call(_ url: URL?, _ mode: UIDocumentBrowserViewController.ImportMode) {
            let handler = handler
            self.handler = nil
            handler?(url, mode)
        }
    }

    private final class HostBox {
        weak var controller: UIViewController?
    }
}

/// The New Archive sheet's host. The sheet comes up over the launch browser, whose file list runs
/// in another process and keeps the keyboard focus: without this, no key reaches the sheet and
/// Return (Create) and Escape (Cancel) do nothing. Becoming first responder when the sheet has
/// appeared takes the focus back; the sheet's `.keyboardShortcut` commands are on this controller.
private final class KeyFocusHostingController<Content: View>: UIHostingController<Content> {
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
}
