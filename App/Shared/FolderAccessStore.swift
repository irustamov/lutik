import Foundation
import os

/// Makes and reads folder bookmarks. The store's seam: tests swap in their own.
protocol BookmarkCoding: Sendable {
    /// A bookmark for `url`, a folder the user picked (or one the app is accessing).
    func bookmark(for url: URL) throws -> Data
    /// Where `data` points now, and whether it should be bookmarked again (`isStale`).
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    /// The volume `data` was made on, as it recorded then (so known while the volume is
    /// unmounted); nil when that can't be read.
    func volume(of data: Data) -> VolumeIdentity?
}

/// A volume as the store tells volumes apart: where it is mounted, and its UUID when known.
struct VolumeIdentity: Equatable, Sendable {
    var url: URL
    var uuid: String?

    /// The same volume: the same UUID when both have one (so another drive mounted where it was
    /// isn't it, and it is it mounted elsewhere); the same standardized path when either has none.
    func isSame(as other: VolumeIdentity) -> Bool {
        if let uuid, let otherUUID = other.uuid { return uuid == otherUUID }
        return url.standardizedFileURL.path == other.url.standardizedFileURL.path
    }
}

/// Real bookmarks: security-scoped on macOS (needs `com.apple.security.files.bookmarks.app-scope`),
/// plain on iOS, where a bookmark of a picked folder carries its access.
struct SystemBookmarkCoding: BookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        #endif
        return (url, isStale)
    }

    func volume(of data: Data) -> VolumeIdentity? {
        let values = URL.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey], fromBookmarkData: data)
        return values?.volume.map { VolumeIdentity(url: $0, uuid: values?.volumeUUIDString) }
    }
}

/// The volumes mounted now. The store's third seam: tests plug and unplug drives.
struct MountedVolumes: Sendable {
    /// The mounted volumes; none when they can't be listed.
    var list: @Sendable () -> [VolumeIdentity]

    /// Whether `volume` is among them (`VolumeIdentity.isSame`).
    func isMounted(_ volume: VolumeIdentity) -> Bool {
        list().contains { $0.isSame(as: volume) }
    }

    /// `FileManager`'s mounted volumes, with their UUIDs.
    static let system = MountedVolumes(list: {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
        return urls.map { VolumeIdentity(url: $0, uuid: try? $0.resourceValues(forKeys: keys).volumeUUIDString) }
    })
}

/// Looks up what is at a path, without following a symlink there. The store's fourth seam: tests
/// feed it errnos.
struct PathStatus: Sendable {
    /// `lstat(2)` of the path: nil when it found something there, else its errno.
    var lstatErrno: @Sendable (String) -> Int32?

    static let system = PathStatus(lstatErrno: { path in
        var info = stat()
        return Darwin.lstat(path, &info) == 0 ? nil : errno
    })
}

/// Starts and stops access to a security-scoped URL. The store's other seam: tests count the calls.
struct SecurityScope: Sendable {
    /// `startAccessingSecurityScopedResource()`: true when access started, and must be stopped.
    var start: @Sendable (URL) -> Bool
    /// `stopAccessingSecurityScopedResource()`.
    var stop: @Sendable (URL) -> Void

    static let system = SecurityScope(start: { $0.startAccessingSecurityScopedResource() },
                                      stop: { $0.stopAccessingSecurityScopedResource() })
}

/// Access to a granted folder, held from `FolderAccessStore.access(for:)` until `stop()` or
/// deinit, whichever comes first.
final class ScopedFolder {
    /// The granted folder, which holds the destination.
    let url: URL
    private var isAccessing: Bool
    private let scope: SecurityScope

    /// `isAccessing`: `scope.start(url)` returned true, so this stops it through `scope`.
    init(url: URL, isAccessing: Bool, scope: SecurityScope = .system) {
        self.url = url
        self.isAccessing = isAccessing
        self.scope = scope
    }

    /// Ends the access. Safe to call more than once.
    func stop() {
        guard isAccessing else { return }
        isAccessing = false
        scope.stop(url)
    }

    deinit { stop() }
}

/// Folders the user let Lutik write to, kept as bookmarks in the app's defaults, so Extract Here
/// (and the Finder services) asks once per folder tree, across launches. A destination is
/// covered by its longest granted ancestor. A grant whose bookmark went stale is bookmarked again;
/// one whose folder is gone from a mounted volume is dropped, so the app asks again, while one that
/// doesn't resolve for any other reason (its drive unplugged, its folder out of reach, say) is kept
/// for when it does. Granting a folder drops the grants it makes needless, so the list doesn't grow
/// without end.
final class FolderAccessStore {
    private struct Grant: Codable, Equatable {
        /// Standardized path, as last resolved.
        var path: String
        var bookmark: Data
    }

    private static let logger = Logger(subsystem: "com.kernir.app", category: "folderAccess")

    /// Where the app keeps its grants; UI tests use a key of their own (`ExtractHereEffects`).
    static let defaultKey = "KernirFolderAccessGrants"
    private let defaults: UserDefaults
    private let key: String
    private let coder: any BookmarkCoding
    private let scope: SecurityScope
    private let volumes: MountedVolumes
    private let paths: PathStatus
    /// The app's own sandbox folder (its home, `NSHomeDirectory()`), where it may always write:
    /// `access(for:)` needs no grant inside it. Nil, the default, for none: only the iOS app's
    /// store has one (`ExtractHereEffects.folderAccessStore`). Never an App Group, File Provider or
    /// iCloud folder.
    let ownContainer: URL?

    init(defaults: UserDefaults = .standard, key: String = FolderAccessStore.defaultKey,
         coder: any BookmarkCoding = SystemBookmarkCoding(), scope: SecurityScope = .system,
         volumes: MountedVolumes = .system, paths: PathStatus = .system, ownContainer: URL? = nil) {
        self.ownContainer = ownContainer
        self.defaults = defaults
        self.key = key
        self.coder = coder
        self.scope = scope
        self.volumes = volumes
        self.paths = paths
    }

    /// The granted folders in the order they were granted, as last resolved: for the Settings list.
    var grants: [URL] {
        load().map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    /// Remembers `folder`, a URL the user just picked (an open panel's, which carries access).
    /// On the way it drops the grants whose folder is gone (`isGone`), and those for `folder` itself
    /// or a folder inside it, as they resolve now (so /tmp/x and /private/tmp/x are one grant), or,
    /// for one that doesn't resolve now, as last resolved on `folder`'s volume (`isReplaced`), which
    /// `folder` covers from now on. The others keep their place, under where they resolve; one that
    /// doesn't resolve now stays as it was.
    func grant(_ folder: URL) throws {
        let bookmark = try coder.bookmark(for: folder)
        let volume = coder.volume(of: bookmark)
        var grants: [Grant] = []
        for var grant in load() {
            let resolved: URL
            do {
                resolved = try coder.resolve(grant.bookmark).url
            } catch {
                if !isReplaced(grant, by: folder, on: volume), !isGone(grant, error) {
                    grants.append(grant)
                }
                continue
            }
            guard !Self.covers(folder, resolved) else { continue }
            grant.path = Self.standardizedPath(resolved)
            grants.append(grant)
        }
        grants.append(Grant(path: Self.standardizedPath(folder), bookmark: bookmark))
        save(grants)
    }

    /// Forgets `folder`'s grant, if there is one.
    func revoke(_ folder: URL) {
        let path = Self.standardizedPath(folder)
        let grants = load()
        let kept = grants.filter { $0.path != path }
        if kept != grants { save(kept) }
    }

    /// Access to the longest granted ancestor of `destination` (or `destination` itself), started
    /// for the caller; nil when no grant covers it (the app asks). On the way, a grant whose folder is
    /// gone is dropped (`isGone`; one that doesn't resolve otherwise is passed over and kept), one
    /// whose folder moved follows it (and covers only the new place), and a stale one is bookmarked
    /// again; the changes are saved. A grant whose access won't start is passed over (and kept): the
    /// next one covering it is tried, or the app asks again. A destination in `ownContainer`
    /// (`covers`, so a symlink in it that points out leads out) is the container, with nothing
    /// started, stopped, read or saved.
    func access(for destination: URL) -> ScopedFolder? {
        if let ownContainer, Self.covers(ownContainer, destination) {
            return ScopedFolder(url: ownContainer, isAccessing: false, scope: scope)
        }
        var grants = load()
        let original = grants
        defer { if grants != original { save(grants) } }
        let destinationComponents = Self.components(destination.path)
        let candidates = grants.map { ($0, Self.components($0.path)) }
            .filter { destinationComponents.starts(with: $0.1) }
            .sorted { $0.1.count > $1.1.count }
            .map(\.0)
        for candidate in candidates {
            guard let index = grants.firstIndex(of: candidate) else { continue }
            let resolved: (url: URL, isStale: Bool)
            do {
                resolved = try coder.resolve(candidate.bookmark)
            } catch {
                if isGone(candidate, error) { grants.remove(at: index) }
                continue
            }
            let path = Self.standardizedPath(resolved.url)
            grants[index].path = path
            guard Self.covers(resolved.url, destination) else { continue }
            guard scope.start(resolved.url) else {
                Self.logger.error("Access to a granted folder didn't start; trying the next grant")
                continue
            }
            if resolved.isStale {
                do {
                    grants[index].bookmark = try coder.bookmark(for: resolved.url)
                } catch {
                    // Still usable now; the next access tries again.
                    Self.logger.error("Cannot refresh a stale folder grant: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                }
            }
            return ScopedFolder(url: resolved.url, isAccessing: true, scope: scope)
        }
        return nil
    }

    /// Whether `grant`, which doesn't resolve now, is made needless by granting `folder`, whose
    /// bookmark is on `volume`: `folder` covers it as last resolved, on the same volume. Same path on
    /// another drive (mounted where its drive was) isn't it; one whose volume can't be read from its
    /// bookmark is taken for it.
    private func isReplaced(_ grant: Grant, by folder: URL, on volume: VolumeIdentity?) -> Bool {
        guard Self.covers(folder, URL(fileURLWithPath: grant.path)) else { return false }
        guard let grantVolume = coder.volume(of: grant.bookmark) else { return true }
        return volume.map(grantVolume.isSame) == true
    }

    /// Whether `grant`, whose bookmark failed to resolve with `error`, should be dropped: only when
    /// its folder wasn't found, its volume is mounted, and nothing is at its last-known path. Not
    /// found is Cocoa's 4 or 260, or 259 (`NSFileReadCorruptFileError`), which a deleted folder's
    /// security-scoped bookmark fails with under the home folder (4 elsewhere). A bookmark on an
    /// unplugged drive fails the same way (`.withoutUI` won't mount it), so a grant whose volume
    /// isn't mounted, or can't be read from the bookmark, is kept. So is one whose folder is there
    /// but can't be reached (259 and 4 again, under a folder that can't be searched): only lstat's
    /// ENOENT or ENOTDIR means it is gone. One failing any other way is kept too: it may resolve later.
    private func isGone(_ grant: Grant, _ error: any Error) -> Bool {
        let error = error as NSError
        let notFound = error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadCorruptFileError].contains(error.code)
        let isGone = notFound && coder.volume(of: grant.bookmark).map(volumes.isMounted) == true
            && paths.lstatErrno(grant.path).map { [ENOENT, ENOTDIR].contains($0) } == true
        if isGone {
            Self.logger.error("Dropping a folder grant whose folder is gone: \(error.domain, privacy: .public) \(error.code)")
        } else {
            Self.logger.info("Keeping a folder grant that doesn't resolve now: \(error.domain, privacy: .public) \(error.code)")
        }
        return isGone
    }

    /// True when `destination` is `grant` or inside it: whole path components, after standardizing
    /// both and resolving symlinks, so /var and /private/var match. Case-exact: a case-only
    /// difference costs one more prompt, never a wrong grant.
    static func covers(_ grant: URL, _ destination: URL) -> Bool {
        let grantComponents = components(grant.path)
        let destinationComponents = components(destination.path)
        return destinationComponents.starts(with: grantComponents)
    }

    /// `path`'s components, standardized and symlink-resolved, with the "/private" of /private/var,
    /// /private/tmp and /private/etc dropped (resolving drops it only for items that exist).
    /// Resolving takes the deepest part of the path that exists and puts the rest back after it, so
    /// a symlink above a folder not made yet is still followed.
    private static func components(_ path: String) -> [String] {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var components = existing.resolvingSymlinksInPath().pathComponents + missing
        if components.count > 2, components[0] == "/", components[1] == "private",
           ["var", "tmp", "etc"].contains(components[2]) {
            components.remove(at: 1)
        }
        return components
    }

    private static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() -> [Grant] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try PropertyListDecoder().decode([Grant].self, from: data)
        } catch {
            Self.logger.error("Cannot read folder grants: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            return []
        }
    }

    private func save(_ grants: [Grant]) {
        do {
            defaults.set(try PropertyListEncoder().encode(grants), forKey: key)
        } catch {
            Self.logger.error("Cannot save folder grants: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }
}
