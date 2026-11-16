import Foundation
#if os(macOS)
import AppKit
#endif

/// Launch arguments Extract Here's UI tests pass, so a run touches nothing but its own work folder:
/// no Finder window, nothing in the user's Trash, no grants in the user's list. Read in Debug
/// builds only, and only from the launch arguments (not a stray `defaults write`); a Release
/// build has none, so every hook below does what the app always does. Kept out of
/// `LaunchOverrides`.
struct ExtractHereLaunchArguments: Equatable, Sendable {
    /// `-KernirSuppressReveal YES`: `ExtractHereEffects.reveal` shows nothing.
    var suppressesReveal = false
    /// `-KernirTrashDirectory <absolute path>`: `ExtractHereEffects.moveToTrash` moves the archive
    /// into this existing folder (the app must be able to write there: in the UI tests, a folder
    /// inside the granted one) instead of the Trash.
    var trashDirectory: URL?
    /// `-KernirFolderAccessGrantsKey <key>`: the grants live under this defaults key, never the
    /// user's (`FolderAccessStore.defaultKey`).
    var folderAccessGrantsKey: String?
    /// `-KernirFolderAccessGrantsReset <token>`: with an alternate key, the grants under it are
    /// cleared at the first launch with a new token (one per UI test), and kept across the test's
    /// relaunches. Ignored without an alternate key.
    var folderAccessGrantsReset: String?
    /// `-KernirDisableOwnContainerSkip YES`: the iOS store asks for a folder in the app's own
    /// container too (`FolderAccessStore.ownContainer`), as the picker UI tests' fixtures land in
    /// its Documents. Only those tests pass it.
    var disablesOwnContainerSkip = false
    /// `-KernirExtractHereGrant <path>` (iOS UI tests): the first Files picker of a launch for
    /// the archive's folder (Extract Here's `.grant`) doesn't come up; this folder is taken as the
    /// pick. A relative path is in the app's home: "Documents" is the app's Documents, which a UI
    /// test can't name. The folder carries no security scope, so with it the iOS store counts access
    /// the system won't start as started, for this folder and what's inside it only
    /// (`ExtractHereEffects.scope(for:onIOS:system:)`).
    ///
    /// Not only the first pick, then: the lenient scope is on for any launch that passes the
    /// argument, and it is what opens a grant the hook saved. A relaunch that relies on a hook
    /// grant must pass the argument again (with any folder covering the saved one); without it the
    /// saved plain-path bookmark won't start and the picker comes up. For the same reason the UI
    /// tests can't catch a "grant saved, but its scope won't start" regression: that needs a real
    /// Files pick on a device.
    var extractHereGrant: URL?
    /// `-KernirExtractHereReadOnly YES` (iOS UI tests): the first Extract Here of a launch into the
    /// archive's folder fails as on a read-only volume, for the `.readOnly` alert.
    var failsExtractHereAsReadOnly = false

    init() {}

    /// The arguments in `domain`, the argument domain's contents; a relative grant path is in `home`.
    init(domain: [String: Any], home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        suppressesReveal = (domain["KernirSuppressReveal"] as? String).map {
            ["yes", "true", "1"].contains($0.lowercased())
        } ?? false
        if let path = domain["KernirTrashDirectory"] as? String, path.hasPrefix("/") {
            trashDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let key = domain["KernirFolderAccessGrantsKey"] as? String, !key.isEmpty {
            folderAccessGrantsKey = key
        }
        folderAccessGrantsReset = domain["KernirFolderAccessGrantsReset"] as? String
        #if DEBUG
        // Release builds ignore it: there the iOS store always skips the app's own container.
        disablesOwnContainerSkip = (domain["KernirDisableOwnContainerSkip"] as? String).map {
            ["yes", "true", "1"].contains($0.lowercased())
        } ?? false
        // The iOS UI tests' stand-ins for a Files pick and a read-only volume.
        if let path = domain["KernirExtractHereGrant"] as? String, !path.isEmpty {
            extractHereGrant = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
                : home.appendingPathComponent(path, isDirectory: true)
        }
        failsExtractHereAsReadOnly = (domain["KernirExtractHereReadOnly"] as? String).map {
            ["yes", "true", "1"].contains($0.lowercased())
        } ?? false
        #endif
    }

    /// This launch's arguments; none in a Release build.
    static var current: ExtractHereLaunchArguments {
        #if DEBUG
        ExtractHereLaunchArguments(domain: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
        #else
        ExtractHereLaunchArguments()
        #endif
    }
}

/// What Extract Here does outside the archive's folder: shows the result in Finder, moves the
/// archive to the Trash, keeps folder grants. The one place for each, so the UI tests' launch
/// arguments (`ExtractHereLaunchArguments`) cover every caller.
enum ExtractHereEffects {
    #if os(macOS)
    /// Selects `urls` in a Finder window (`show`, the workspace by default), unless the launch
    /// arguments suppress it. Returns whether it showed them.
    @MainActor @discardableResult
    static func reveal(_ urls: [URL], arguments: ExtractHereLaunchArguments = .current,
                       show: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }) -> Bool {
        guard !arguments.suppressesReveal, !urls.isEmpty else { return false }
        show(urls)
        return true
    }
    #endif

    /// Moves `url` to the Trash (`FileManager.trashItem`, so Finder's Put Back works) and returns
    /// where it went, if the system says. With a test trash folder in the launch arguments, moves
    /// it there instead, under a free name, never replacing anything.
    static func moveToTrash(_ url: URL, arguments: ExtractHereLaunchArguments = .current) throws -> URL? {
        if let directory = arguments.trashDirectory {
            return try UniquePlacement.place(url, named: url.lastPathComponent, in: directory,
                                             isDirectory: url.hasDirectoryPath)
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// Whether this is the iOS app, whose store skips the app's own container.
    static let isIOS: Bool = {
        #if os(iOS)
        true
        #else
        false
        #endif
    }()

    /// The app's folder grants: the user's, or with the launch arguments, the UI tests' own key,
    /// cleared once per reset token. On iOS (`onIOS`), a folder in the app's own container
    /// (`NSHomeDirectory()`: On My iPhone > Lutik is its Documents) needs no grant, unless the
    /// launch arguments turn that off. Never on macOS, whose sandbox container links out
    /// (Data/Downloads -> ~/Downloads). The iOS app on a Mac ("Designed for iPad", or Mac Catalyst)
    /// is os(iOS) too, so its store skips the app's Mac container; still safe, as `covers` resolves
    /// symlinks: a folder through the container's links out (Data/Downloads and the like) is outside
    /// it, and needs a grant.
    static func folderAccessStore(defaults: UserDefaults = .standard,
                                  arguments: ExtractHereLaunchArguments = .current,
                                  onIOS: Bool = isIOS) -> FolderAccessStore {
        let ownContainer = onIOS && !arguments.disablesOwnContainerSkip
            ? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) : nil
        let securityScope = scope(for: arguments, onIOS: onIOS)
        guard let key = arguments.folderAccessGrantsKey, key != FolderAccessStore.defaultKey else {
            return FolderAccessStore(defaults: defaults, scope: securityScope, ownContainer: ownContainer)
        }
        let tokenKey = key + ".resetToken"
        if let token = arguments.folderAccessGrantsReset, defaults.string(forKey: tokenKey) != token {
            defaults.removeObject(forKey: key)
            defaults.set(token, forKey: tokenKey)
        }
        return FolderAccessStore(defaults: defaults, key: key, scope: securityScope, ownContainer: ownContainer)
    }

    /// The store's security scope: `system`'s. In a Debug build of the iOS app (`onIOS`) with
    /// `-KernirExtractHereGrant`, access to the hook's folder, or a folder inside it, that the
    /// system won't start counts as started: the hook's folder is a plain path, not a pick from
    /// Files, so it carries no scope. Every other URL gets the system's answer, so a real grant
    /// whose scope won't start is passed over as in a Release build. Stopping goes to the system
    /// only for an access the system did start (once per start), never for one it refused. Never
    /// on macOS, where no hook uses the argument; never in a Release build, which has no lenient
    /// path at all.
    static func scope(for arguments: ExtractHereLaunchArguments, onIOS: Bool = isIOS,
                      system: SecurityScope = .system) -> SecurityScope {
        #if DEBUG
        if onIOS, let grant = arguments.extractHereGrant {
            let started = StartedScopes()
            return SecurityScope(start: { url in
                if system.start(url) {
                    started.insert(url)
                    return true
                }
                return FolderAccessStore.covers(grant, url)
            }, stop: { url in
                if started.remove(url) { system.stop(url) }
            })
        }
        #endif
        return system
    }
}

#if DEBUG
/// The URLs whose access the system started, counted per start, for the hook's scope to stop only
/// those (`ExtractHereEffects.scope(for:onIOS:system:)`).
private final class StartedScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [URL: Int] = [:]

    func insert(_ url: URL) {
        lock.withLock { counts[url, default: 0] += 1 }
    }

    /// Whether `url` had a start left, which is then used up.
    func remove(_ url: URL) -> Bool {
        lock.withLock {
            guard let count = counts[url] else { return false }
            counts[url] = count > 1 ? count - 1 : nil
            return true
        }
    }
}
#endif
