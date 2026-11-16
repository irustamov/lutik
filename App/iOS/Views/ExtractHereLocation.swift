import Foundation

/// Where Extract Here may write on iPhone and iPad. It is off for an
/// archive the system handed over as a copy, which sits in the app's tmp/ (tmp/<bundle>-Inbox, from
/// Mail and Share) or in Documents/Inbox (older systems). "Here" would be a folder the user never
/// sees, so only Extract To… is offered there. Everywhere else (Files in place, On My iPhone >
/// Lutik, iCloud Drive, other providers) it stays on.
///
/// Read the archive's URL when deciding, never a cached one: UIDocument updates `fileURL` on a move.
/// `ExtractHereLocationCache` keeps the answer per URL, not the URL.
enum ExtractHereLocation {
    /// The app's temporary folder and Documents/Inbox. ScreenState keeps its own copy of the list, so
    /// tests (whose fixtures sit in tmp) can exclude other folders.
    static var excludedFolders: [URL] {
        let fileManager = FileManager.default
        var folders = [fileManager.temporaryDirectory]
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            folders.append(documents.appendingPathComponent("Inbox", isDirectory: true))
        }
        return folders
    }

    /// False when `url` is one of `folders` or inside one: `FolderAccessStore.covers`, so whole path
    /// components (Documents/InboxOld is not Documents/Inbox), symlinks resolved from the deepest
    /// part that exists, and /var and /private/var alike.
    static func allowsExtractHere(at url: URL, excluding folders: [URL]) -> Bool {
        !folders.contains { FolderAccessStore.covers($0, url) }
    }
}

/// `ExtractHereLocation.allowsExtractHere`, decided again only when the URL or the folders differ
/// from the last call's: the Extract menus ask on every redraw, and the check reads the disk.
/// The caller passes the URL it reads now.
struct ExtractHereLocationCache {
    private let decide: (URL, [URL]) -> Bool
    private var last: (url: URL, folders: [URL], allows: Bool)?

    /// `decide` is the check; tests count its calls.
    init(decide: @escaping (URL, [URL]) -> Bool = ExtractHereLocation.allowsExtractHere(at:excluding:)) {
        self.decide = decide
    }

    mutating func allowsExtractHere(at url: URL, excluding folders: [URL]) -> Bool {
        if let last, last.url == url, last.folders == folders { return last.allows }
        let allows = decide(url, folders)
        last = (url, folders, allows)
        return allows
    }
}
