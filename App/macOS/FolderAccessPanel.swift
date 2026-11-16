import AppKit

/// What `FolderAccessPanel` sets on its open panels: NSOpenPanel's own properties, so tests can
/// check the settings on a stand-in without making a panel.
@MainActor
protocol FolderPanelSettings: AnyObject {
    var canChooseFiles: Bool { get set }
    var canChooseDirectories: Bool { get set }
    var canCreateDirectories: Bool { get set }
    var allowsMultipleSelection: Bool { get set }
    var directoryURL: URL? { get set }
    var message: String! { get set }
    var prompt: String! { get set }
}

extension NSOpenPanel: FolderPanelSettings {}

/// Asks the user, once per folder tree, to let Lutik write next to an archive: a stock open panel
/// as a sheet, opened on the destination folder. The user may pick that folder or any folder
/// containing it (the home folder, say); the caller keeps the pick as a grant
/// (`FolderAccessStore.grant`). A pick that doesn't contain the destination gets an alert saying
/// which folder to choose, then the panel again.
@MainActor
enum FolderAccessPanel {
    /// Shows the panel for `destination` on `window` and calls `completion` with the folder the
    /// user picked, or nil for Cancel. Tests swap it and restore the default afterwards.
    static var ask: @MainActor (_ destination: URL, _ window: NSWindow,
                                _ completion: @escaping @MainActor (URL?) -> Void) -> Void = {
        present(for: $0, on: $1, completion: $2)
    }

    /// The default `ask`.
    static func present(for destination: URL, on window: NSWindow,
                        completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        configureAllowPanel(panel, for: destination)
        panel.beginSheetModal(for: window) { response in
            guard let picked = pick(response, panel.url) else {
                completion(nil)
                return
            }
            guard FolderAccessStore.covers(picked, destination) else {
                askForTheRightFolder(destination, on: window, completion: completion)
                return
            }
            completion(picked)
        }
    }

    /// The Allow panel: folders only, one, no new folder, opened on `destination`, the archive's folder.
    static func configureAllowPanel(_ panel: some FolderPanelSettings, for destination: URL) {
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.message = message(for: destination)
        panel.prompt = String(localized: "Allow",
                              comment: "Default button of the folder panel that gives Lutik permission to write in the chosen folder: to extract into it, or (Finder's “Compress with Lutik”) to save a new archive there.")
    }

    /// The folder a panel ended with: its URL after OK, nil after Cancel (or any other end), even
    /// though the panel still has a URL then.
    static func pick(_ response: NSApplication.ModalResponse, _ url: URL?) -> URL? {
        response == .OK ? url : nil
    }

    /// "Lutik needs permission to extract into “Downloads”."
    static func message(for destination: URL) -> String {
        String(localized: "Lutik needs permission to extract into “\(displayName(of: destination))”.",
               comment: "Message at the top of the folder panel that asks for access. %@ = the destination folder's name, as Finder shows it.")
    }

    /// The pick didn't contain the destination: says which folder to choose, once the panel's
    /// sheet has gone, then shows the panel again.
    private static func askForTheRightFolder(_ destination: URL, on window: NSWindow,
                                             completion: @escaping @MainActor (URL?) -> Void) {
        let alert = wrongFolderAlert(for: destination)
        window.whenNoSheetAttached {
            alert.beginSheetModal(for: window) { _ in
                window.whenNoSheetAttached {
                    present(for: destination, on: window, completion: completion)
                }
            }
        }
    }

    /// The alert for a pick that doesn't contain `destination`.
    static func wrongFolderAlert(for destination: URL) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "That folder doesn't contain “\(displayName(of: destination))”.",
                                   comment: "Alert title after the user picked a folder that doesn't contain the destination. %@ = the destination folder's name.")
        alert.informativeText = String(localized: "Choose “\(displayName(of: destination))” or a folder that contains it.",
                                       comment: "Alert text under “That folder doesn't contain…”. %@ = the destination folder's name; the folder panel opens again after this alert.")
        return alert
    }

    // MARK: Read-only volume

    /// The destination's volume is read-only (`ExtractHereService.isReadOnlyVolume`): an error
    /// that offers another folder. "Choose Another Folder…" opens a folder panel and calls
    /// `completion` with the pick; Cancel, or Cancel in the panel, calls it with nil. Tests swap it
    /// and restore the default afterwards.
    static var offerAnotherFolder: @MainActor (_ destination: URL, _ window: NSWindow,
                                               _ completion: @escaping @MainActor (URL?) -> Void) -> Void = {
        presentReadOnlyError(for: $0, on: $1, completion: $2)
    }

    /// The default `offerAnotherFolder`.
    static func presentReadOnlyError(for destination: URL, on window: NSWindow,
                                     completion: @escaping @MainActor (URL?) -> Void) {
        let alert = readOnlyAlert(for: destination)
        window.whenNoSheetAttached {
            alert.beginSheetModal(for: window) { response in
                guard choosesAnotherFolder(response) else {
                    completion(nil)
                    return
                }
                window.whenNoSheetAttached {
                    chooseAnotherFolder(on: window, completion: completion)
                }
            }
        }
    }

    /// "“Untitled” is on a read-only volume." with "Choose Another Folder…" (default) and Cancel.
    static func readOnlyAlert(for destination: URL) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(displayName(of: destination))” is on a read-only volume.",
                                   comment: "Alert title when the folder to extract into can't be written to (a disk image, say). Also the reason text under “Couldn't extract …” or “Couldn't compress …” after Finder's “Extract Here with Lutik” or “Compress with Lutik”: the folder it writes in (to extract into, or to save a new archive in) is on a read-only volume. %@ = that folder's name.")
        alert.informativeText = String(localized: "Choose another folder to extract into.",
                                       comment: "Alert text under “… is on a read-only volume.”")
        alert.addButton(withTitle: String(localized: "Choose Another Folder…",
                                          comment: "Default button of the read-only volume alert: opens a folder panel to pick where to extract."))
        alert.addButton(withTitle: String(localized: "Cancel",
                    comment: "Cancel button of the password sheet, the progress sheet (stops the operation), the read-only volume alert, and the alert after a Finder service (“Extract Here with Lutik”, “Compress with Lutik”) couldn't write in its folder."))
        return alert
    }

    /// The read-only alert's response goes on to the folder panel: its first button, "Choose
    /// Another Folder…"; Cancel (the second, or Escape) doesn't.
    static func choosesAnotherFolder(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// A stock folder panel for the other destination (`configureOtherFolderPanel`).
    private static func chooseAnotherFolder(on window: NSWindow, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        configureOtherFolderPanel(panel)
        panel.beginSheetModal(for: window) { response in
            completion(pick(response, panel.url))
        }
    }

    /// The other-folder panel: folders only, one, new folders allowed, prompt "Extract", opened on
    /// `otherFolderStart`.
    static func configureOtherFolderPanel(_ panel: some FolderPanelSettings) {
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = otherFolderStart
        panel.prompt = String(localized: "Extract",
                    comment: "Extract (a verb): the label and VoiceOver label of the toolbar's Extract button, and the default button of the folder panels that pick where to extract (also the panel opened by “Extract to Another Folder…” after Finder's “Extract Here with Lutik” couldn't write in the archive's folder).")
    }

    /// Where the other-folder panel opens: the user's Downloads folder, where a download's archive
    /// (a disk image's, say) would go. The real one in the home folder: in the sandbox
    /// `FileManager`'s Downloads is the container's. If it isn't there, the panel opens where it was last.
    static var otherFolderStart: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The folder's name as Finder shows it.
    private static func displayName(of folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path)
    }
}
