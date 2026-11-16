import Testing
import Foundation
@testable import Kernir

// MARK: - Helpers

/// Bookmarks as plain paths. A folder marked stale resolves as stale; a dead one doesn't resolve
/// (file not found), nor does one failing with another error; a moved one resolves to where it went.
/// A bookmark's volume is /Volumes/<name> for a path there, / otherwise, unless marked unreadable;
/// it has the UUID recorded for that volume when it was made, if any. Counts the bookmarks it makes.
private final class FakeBookmarks: BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var stale = Set<String>()
    private var failures: [String: any Error] = [:]
    private var moved: [String: String] = [:]
    private var unreadableVolumes = Set<String>()
    private var volumeUUIDs: [String: String] = [:]
    private var made = 0
    private var refusesBookmarks = false

    func refuseBookmarks() { lock.withLock { refusesBookmarks = true } }
    func markStale(_ path: String) { lock.withLock { _ = stale.insert(path) } }
    func markDead(_ path: String) { fail(path, with: CocoaError(.fileNoSuchFile)) }
    func fail(_ path: String, with error: any Error) { lock.withLock { failures[path] = error } }
    func revive(_ path: String) { lock.withLock { _ = failures.removeValue(forKey: path) } }
    func markVolumeUnreadable(_ path: String) { lock.withLock { _ = unreadableVolumes.insert(path) } }
    func record(uuid: String, forVolume volume: String) { lock.withLock { volumeUUIDs[volume] = uuid } }
    func move(_ path: String, to newPath: String) { lock.withLock { moved[path] = newPath } }
    var bookmarksMade: Int { lock.withLock { made } }

    func bookmark(for url: URL) throws -> Data {
        try lock.withLock {
            if refusesBookmarks { throw CocoaError(.fileWriteNoPermission) }
            made += 1
            stale.remove(url.path)
            return Data((url.path + "\u{0}" + (volumeUUIDs[Self.volumePath(of: url.path)] ?? "")).utf8)
        }
    }

    /// The path and the volume UUID (nil for none) a bookmark was made with.
    private static func decode(_ data: Data) -> (path: String, uuid: String?) {
        let parts = String(decoding: data, as: UTF8.self).split(separator: "\u{0}", omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil)
    }

    private static func volumePath(of path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.count > 2 && components[1] == "Volumes" ? "/Volumes/" + components[2] : "/"
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        let path = Self.decode(data).path
        return try lock.withLock {
            if let failure = failures[path] { throw failure }
            return (URL(fileURLWithPath: moved[path] ?? path, isDirectory: true), stale.contains(path))
        }
    }

    func volume(of data: Data) -> VolumeIdentity? {
        let (path, uuid) = Self.decode(data)
        return lock.withLock {
            guard !unreadableVolumes.contains(path) else { return nil }
            return VolumeIdentity(url: folder(Self.volumePath(of: path)), uuid: uuid)
        }
    }
}

/// Mounted volumes: / and /Volumes/Drive, without UUIDs, until unmounted or others are mounted.
private final class FakeVolumes: @unchecked Sendable {
    private let lock = NSLock()
    private var mounted: [VolumeIdentity] = [VolumeIdentity(url: folder("/")),
                                             VolumeIdentity(url: folder("/Volumes/Drive"))]

    func unmount(_ path: String) { lock.withLock { mounted.removeAll { $0.url.path == path } } }
    func mount(_ path: String, uuid: String? = nil) {
        lock.withLock { mounted.append(VolumeIdentity(url: folder(path), uuid: uuid)) }
    }

    var volumes: MountedVolumes {
        MountedVolumes(list: { self.lock.withLock { self.mounted } })
    }
}

/// Security scope that counts each folder's starts and stops; a refused folder doesn't start.
private final class FakeScope: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = Set<String>()
    private var starts: [String: Int] = [:]
    private var stops: [String: Int] = [:]

    func refuse(_ path: String) { lock.withLock { _ = refused.insert(path) } }
    func started(_ path: String) -> Int { lock.withLock { starts[path, default: 0] } }
    func stopped(_ path: String) -> Int { lock.withLock { stops[path, default: 0] } }
    /// Every folder stopped as often as it started.
    var isBalanced: Bool { lock.withLock { starts.filter { $0.value > 0 } == stops.filter { $0.value > 0 } } }

    var scope: SecurityScope {
        SecurityScope(start: { url in
            self.lock.withLock {
                guard !self.refused.contains(url.path) else { return false }
                self.starts[url.path, default: 0] += 1
                return true
            }
        }, stop: { url in
            self.lock.withLock { self.stops[url.path, default: 0] += 1 }
        })
    }
}

/// Every grant's last-known path gone (lstat: ENOENT), so fake folders don't depend on the real disk.
private let gonePaths = PathStatus(lstatErrno: { _ in ENOENT })

/// A defaults suite of its own, removed by the caller (`removeTestDefaults`).
private func makeDefaults() -> (UserDefaults, String) {
    makeTestDefaults("FolderAccessStoreTests")
}

private func folder(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
}

// MARK: - covers

@Test(arguments: [
    ("/Users/me", "/Users/me", true),
    ("/Users/me", "/Users/me/Downloads/deep", true),
    ("/Users/me/", "/Users/me/Downloads", true),
    ("/", "/Volumes/Disk/x", true),
    ("/Users/me", "/Users/meet", false),
    ("/Users/me/Downloads", "/Users/me", false),
    ("/Users/me", "/Users/other/Downloads", false),
    ("/Users/me", "/Users/me/../other", false),
    // Case-exact: a case-only difference costs one more prompt, never a wrong grant.
    ("/Users/me/Downloads", "/Users/me/downloads", false),
    ("/Users/me/Caf\u{E9}", "/Users/me/Cafe\u{301}/x", true),
])
func coversMatchesWholePathComponents(_ grant: String, _ destination: String, _ expected: Bool) {
    #expect(FolderAccessStore.covers(folder(grant), folder(destination)) == expected)
}

/// Fixed paths: hosted, the temporary folder is in the app's container, not under /var.
@Test func coversSeesThroughPrivateVar() {
    let short = "/var/tmp"
    let long = "/private/var/tmp"
    #expect(FolderAccessStore.covers(folder(long), folder(short + "/sub")))
    #expect(FolderAccessStore.covers(folder(short), folder(long + "/sub")))
}

// MARK: - Store

@Test func aGrantCoversItsSubfolders() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths)

    try store.grant(folder("/Users/me/Downloads"))

    #expect(store.grants == [folder("/Users/me/Downloads")])
    #expect(store.access(for: folder("/Users/me/Downloads/sub/deeper"))?.url.path == "/Users/me/Downloads")
    #expect(store.access(for: folder("/Users/me/Downloads"))?.url.path == "/Users/me/Downloads")
    #expect(store.access(for: folder("/Users/me/Documents")) == nil)
}

@Test func theLongestGrantedAncestorWins() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths)

    // Outer first: granting a folder drops the grants inside it.
    try store.grant(folder("/Users/me"))
    try store.grant(folder("/Users/me/Downloads"))
    try store.grant(folder("/Users/me/Downloads/projects"))

    #expect(store.access(for: folder("/Users/me/Downloads/projects/x"))?.url.path == "/Users/me/Downloads/projects")
    #expect(store.access(for: folder("/Users/me/Downloads/other"))?.url.path == "/Users/me/Downloads")
    #expect(store.access(for: folder("/Users/me/Desktop"))?.url.path == "/Users/me")
}

@Test func grantsSurviveARelaunch() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    try FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                          paths: gonePaths).grant(folder("/Users/me/Downloads"))

    let relaunched = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope, paths: gonePaths)

    #expect(relaunched.grants == [folder("/Users/me/Downloads")])
    #expect(relaunched.access(for: folder("/Users/me/Downloads/sub")) != nil)
}

@Test func grantingAFolderAgainReplacesItsGrant() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths)

    try store.grant(folder("/Users/me/Downloads"))
    try store.grant(folder("/Users/me/Downloads/"))

    #expect(store.grants == [folder("/Users/me/Downloads")])
}

@Test func aStaleGrantIsBookmarkedAgainAndSaved() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope, paths: gonePaths)
    try store.grant(folder("/Users/me/Downloads"))
    coder.markStale("/Users/me/Downloads")

    #expect(store.access(for: folder("/Users/me/Downloads/sub"))?.url.path == "/Users/me/Downloads")

    #expect(coder.bookmarksMade == 2)
    // Saved: the next access finds a fresh bookmark and makes none.
    #expect(FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                              paths: gonePaths).access(for: folder("/Users/me/Downloads")) != nil)
    #expect(coder.bookmarksMade == 2)
}

@Test func aGrantThatNoLongerResolvesIsDroppedSoTheAppAsksAgain() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope, paths: gonePaths)
    try store.grant(folder("/Users/me"))
    try store.grant(folder("/Users/me/Downloads"))
    coder.markDead("/Users/me/Downloads")

    // The next granted ancestor still covers it.
    #expect(store.access(for: folder("/Users/me/Downloads/sub"))?.url.path == "/Users/me")
    #expect(store.grants == [folder("/Users/me")])
    #expect(FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                              paths: gonePaths).grants == [folder("/Users/me")])

    coder.markDead("/Users/me")
    #expect(store.access(for: folder("/Users/me/Downloads/sub")) == nil)
    #expect(store.grants.isEmpty)
}

@Test func aGrantWhoseFolderMovedFollowsItAndNoLongerCoversTheOldPlace() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope, paths: gonePaths)
    try store.grant(folder("/Users/me/Downloads/projects"))
    coder.move("/Users/me/Downloads/projects", to: "/Users/me/Archive/projects")

    #expect(store.access(for: folder("/Users/me/Downloads/projects")) == nil)
    #expect(store.grants == [folder("/Users/me/Archive/projects")])
    #expect(store.access(for: folder("/Users/me/Archive/projects/x"))?.url.path == "/Users/me/Archive/projects")
}

@Test func revokeRemovesTheGrant() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths)
    try store.grant(folder("/Users/me"))
    try store.grant(folder("/Users/me/Downloads"))

    store.revoke(folder("/Users/me/Downloads/"))

    #expect(store.grants == [folder("/Users/me")])
    store.revoke(folder("/Users/me"))
    #expect(store.access(for: folder("/Users/me/Downloads")) == nil)
}

@Test func unreadableStoredDataIsNoGrants() {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    defaults.set(Data("not a property list".utf8), forKey: "grants")
    let store = FolderAccessStore(defaults: defaults, key: "grants", coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths)
    #expect(store.grants.isEmpty)
    #expect(store.access(for: folder("/Users/me")) == nil)
}

@Test func aScopedFolderStopsOnce() {
    let scoped = ScopedFolder(url: folder("/Users/me"), isAccessing: false)
    scoped.stop()
    scoped.stop()
    #expect(scoped.url.path == "/Users/me")
}

// MARK: - Pruning

@Test func grantingDropsDeadGrantsAndGrantsInsideTheNewOne() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope, paths: gonePaths)
    try store.grant(folder("/Users/me/Downloads/projects"))
    try store.grant(folder("/Users/other"))
    try store.grant(folder("/Users/gone"))
    try store.grant(folder("/Users/me/Documents"))
    try store.grant(folder("/Users/meet"))
    coder.markDead("/Users/gone")

    try store.grant(folder("/Users/me"))

    #expect(store.grants == [folder("/Users/other"), folder("/Users/meet"), folder("/Users/me")])
    #expect(FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                              paths: gonePaths).grants == store.grants)
}

@Test func grantingAMovedFoldersOldPlaceKeepsTheMovedGrantWhereItIsNow() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope, paths: gonePaths)
    try store.grant(folder("/Users/me/Downloads/projects"))
    coder.move("/Users/me/Downloads/projects", to: "/Users/me/Archive/projects")

    try store.grant(folder("/Users/me/Downloads"))

    // The moved grant is no longer inside the new one: kept, under the place it resolves to.
    #expect(store.grants == [folder("/Users/me/Archive/projects"), folder("/Users/me/Downloads")])
}

@Test func tmpAndPrivateTmpAreOneGrant() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths)

    try store.grant(folder("/private/tmp/kernir-grant"))
    try store.grant(folder("/tmp/kernir-grant"))

    #expect(store.grants == [folder("/tmp/kernir-grant")])
}

// MARK: - Grants that don't resolve now

@Test func grantingKeepsTheGrantOfAnUnmountedDrive() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let volumes = FakeVolumes()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: volumes.volumes, paths: gonePaths)
    try store.grant(folder("/Volumes/Drive/photos"))
    // Unplugged: with .withoutUI its bookmark fails as if the folder were gone.
    volumes.unmount("/Volumes/Drive")
    coder.markDead("/Volumes/Drive/photos")

    try store.grant(folder("/Users/me/Downloads"))

    #expect(store.grants == [folder("/Volumes/Drive/photos"), folder("/Users/me/Downloads")])
    // Plugged back in, it covers its folder again.
    volumes.mount("/Volumes/Drive")
    coder.revive("/Volumes/Drive/photos")
    #expect(store.access(for: folder("/Volumes/Drive/photos/x"))?.url.path == "/Volumes/Drive/photos")
}

@Test func accessKeepsTheGrantOfAnUnmountedDrive() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let volumes = FakeVolumes()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: volumes.volumes, paths: gonePaths)
    try store.grant(folder("/Volumes/Drive"))
    try store.grant(folder("/Volumes/Drive/photos"))
    volumes.unmount("/Volumes/Drive")
    coder.markDead("/Volumes/Drive")
    coder.markDead("/Volumes/Drive/photos")

    #expect(store.access(for: folder("/Volumes/Drive/photos/x")) == nil)

    #expect(store.grants == [folder("/Volumes/Drive"), folder("/Volumes/Drive/photos")])
    #expect(FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                              paths: gonePaths).grants == store.grants)
    volumes.mount("/Volumes/Drive")
    coder.revive("/Volumes/Drive/photos")
    #expect(store.access(for: folder("/Volumes/Drive/photos/x"))?.url.path == "/Volumes/Drive/photos")
}

/// Not found: 4 and 260, and 259, which is what a deleted folder's security-scoped bookmark under
/// the home folder fails with.
private let notFoundErrors = [CocoaError(.fileNoSuchFile), CocoaError(.fileReadNoSuchFile),
                              CocoaError(.fileReadCorruptFile)]

@Test(arguments: notFoundErrors)
func aGoneFolderOnAMountedDriveIsDropped(_ error: CocoaError) throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let volumes = FakeVolumes()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: volumes.volumes, paths: gonePaths)
    try store.grant(folder("/Volumes/Drive/photos"))
    try store.grant(folder("/Volumes/Drive/music"))
    coder.fail("/Volumes/Drive/photos", with: error)
    coder.fail("/Volumes/Drive/music", with: error)

    #expect(store.access(for: folder("/Volumes/Drive/photos/x")) == nil)
    #expect(store.grants == [folder("/Volumes/Drive/music")])
    try store.grant(folder("/Users/me"))
    #expect(store.grants == [folder("/Users/me")])
}

@Test(arguments: notFoundErrors)
func aFolderNotFoundOnAnUnmountedDriveIsKept(_ error: CocoaError) throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let volumes = FakeVolumes()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: volumes.volumes, paths: gonePaths)
    try store.grant(folder("/Volumes/Drive/photos"))
    volumes.unmount("/Volumes/Drive")
    coder.fail("/Volumes/Drive/photos", with: error)

    #expect(store.access(for: folder("/Volumes/Drive/photos/x")) == nil)
    try store.grant(folder("/Users/me"))
    #expect(store.grants == [folder("/Volumes/Drive/photos"), folder("/Users/me")])
}

/// A not-found error from a folder that is still there, but can't be reached now (a folder above it
/// that can't be searched, say), mustn't cost its grant: the grant's last-known path is looked up
/// (lstat) first, and dropped only when nothing is there (ENOENT, ENOTDIR). lstat's errno (nil: it
/// found something), through access or through granting another folder.
@Test(arguments: [(nil, false), (EACCES, false), (EPERM, false), (EIO, false), (ENOENT, true), (ENOTDIR, true)]
                 as [(Int32?, Bool)],
      [true, false])
func aNotFoundGrantIsDroppedOnlyWhenNothingIsAtItsPath(_ lstat: (errno: Int32?, dropped: Bool),
                                                      _ throughAccess: Bool) throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let paths = PathStatus(lstatErrno: { $0 == "/Volumes/Drive/photos" ? lstat.errno : nil })
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: FakeVolumes().volumes, paths: paths)
    try store.grant(folder("/Volumes/Drive/photos"))
    coder.fail("/Volumes/Drive/photos", with: CocoaError(.fileReadCorruptFile))

    if throughAccess {
        #expect(store.access(for: folder("/Volumes/Drive/photos/x")) == nil)
        #expect(store.grants == (lstat.dropped ? [] : [folder("/Volumes/Drive/photos")]))
    } else {
        try store.grant(folder("/Users/me"))
        #expect(store.grants == (lstat.dropped ? [folder("/Users/me")]
                                               : [folder("/Volumes/Drive/photos"), folder("/Users/me")]))
    }
}

// MARK: - Telling volumes apart

@Test(arguments: [
    // UUIDs on both sides decide, wherever the volumes are mounted.
    ("/Volumes/Drive", "A", "/Volumes/Drive", "A", true),
    ("/Volumes/Drive", "A", "/Volumes/Drive 1", "A", true),
    ("/Volumes/Drive", "A", "/Volumes/Drive", "B", false),
    // A UUID missing on either side: the path decides.
    ("/Volumes/Drive", nil, "/Volumes/Drive", "B", true),
    ("/Volumes/Drive", "A", "/Volumes/Drive", nil, true),
    ("/Volumes/Drive", nil, "/Volumes/Drive 1", "A", false),
    ("/Volumes/Drive", "A", "/Volumes/Drive 1", nil, false),
] as [(String, String?, String, String?, Bool)])
func volumesAreTheSameByUUIDElseByPath(_ path: String, _ uuid: String?, _ otherPath: String, _ otherUUID: String?,
                                       _ expected: Bool) {
    let volume = VolumeIdentity(url: folder(path), uuid: uuid)
    let other = VolumeIdentity(url: folder(otherPath), uuid: otherUUID)
    #expect(volume.isSame(as: other) == expected)
    #expect(other.isSame(as: volume) == expected)
}

@Test(arguments: ["file:///Volumes/Drive", "file:///Volumes/Drive/", "file:///Volumes/Drive/./",
                  "file:///Volumes/Drive/sub/.."])
func aVolumesPathMatchesHoweverItIsSpelled(_ spelling: String) throws {
    let bookmarked = VolumeIdentity(url: try #require(URL(string: "file:///Volumes/Drive/")))
    let mounted = VolumeIdentity(url: try #require(URL(string: spelling)))
    #expect(bookmarked.isSame(as: mounted))
    #expect(mounted.isSame(as: bookmarked))
    #expect(!bookmarked.isSame(as: VolumeIdentity(url: folder("/Volumes/Drive2"))))
}

/// A gone folder's grant on a drive recorded as UUID `bookmarked` (or none), while one with
/// `mountedUUID` is mounted at `mountedPath`: dropped only when that is the drive.
@Test(arguments: [
    // Another drive mounted where it was: it is still unplugged.
    ("A", "/Volumes/Drive", "B", false),
    // It, mounted elsewhere (a name taken when it was plugged in).
    ("A", "/Volumes/Drive 1", "A", true),
    // No UUID on one side: where it is mounted decides.
    ("A", "/Volumes/Drive", nil, true),
    (nil, "/Volumes/Drive", "B", true),
    ("A", "/Volumes/Drive 1", nil, false),
] as [(String?, String, String?, Bool)])
func aDriveIsKnownByItsUUID(_ bookmarked: String?, _ mountedPath: String, _ mountedUUID: String?,
                            _ dropped: Bool) throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let volumes = FakeVolumes()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: volumes.volumes, paths: gonePaths)
    if let bookmarked { coder.record(uuid: bookmarked, forVolume: "/Volumes/Drive") }
    try store.grant(folder("/Volumes/Drive/photos"))
    try store.grant(folder("/Volumes/Drive/music"))
    volumes.unmount("/Volumes/Drive")
    volumes.mount(mountedPath, uuid: mountedUUID)
    coder.markDead("/Volumes/Drive/photos")
    coder.markDead("/Volumes/Drive/music")

    #expect(store.access(for: folder("/Volumes/Drive/photos/x")) == nil)
    #expect(store.grants == (dropped ? [folder("/Volumes/Drive/music")]
                                     : [folder("/Volumes/Drive/photos"), folder("/Volumes/Drive/music")]))
    try store.grant(folder("/Users/me"))
    #expect(store.grants == (dropped ? [folder("/Users/me")]
                                     : [folder("/Volumes/Drive/photos"), folder("/Volumes/Drive/music"),
                                        folder("/Users/me")]))
}

/// A grant whose bookmark fails some other way, or whose volume can't be read, may work later.
enum KeptFailure: CaseIterable, Sendable { case otherError, otherDomain, unreadableVolume }

@Test(arguments: KeptFailure.allCases)
func aGrantThatFailsOtherwiseIsKept(_ failure: KeptFailure) throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: FakeVolumes().volumes, paths: gonePaths)
    try store.grant(folder("/Users/me/Downloads"))
    try store.grant(folder("/Users/me/Documents"))
    for path in ["/Users/me/Downloads", "/Users/me/Documents"] {
        switch failure {
        case .otherError: coder.fail(path, with: CocoaError(.fileReadNoPermission))
        // Cocoa's not-found code, in another domain.
        case .otherDomain: coder.fail(path, with: NSError(domain: NSOSStatusErrorDomain, code: NSFileNoSuchFileError))
        case .unreadableVolume:
            coder.markDead(path)
            coder.markVolumeUnreadable(path)
        }
    }

    #expect(store.access(for: folder("/Users/me/Downloads/x")) == nil)
    try store.grant(folder("/Users/me/Desktop"))

    #expect(store.grants == [folder("/Users/me/Downloads"), folder("/Users/me/Documents"), folder("/Users/me/Desktop")])
}

/// A kept grant that doesn't resolve is replaced when its folder, or a folder holding it, is
/// granted again: the new grant covers it, so the list never holds the same folder twice.
@Test(arguments: KeptFailure.allCases, ["/Users/me/Downloads", "/Users/me/Downloads/", "/Users/me"])
func grantingAFolderAgainReplacesItsGrantThatDoesntResolve(_ failure: KeptFailure, _ granted: String) throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: FakeVolumes().volumes, paths: gonePaths)
    try store.grant(folder("/Users/me/Documents"))
    try store.grant(folder("/Users/me/Downloads"))
    try store.grant(folder("/Users/meet"))
    switch failure {
    case .otherError: coder.fail("/Users/me/Downloads", with: CocoaError(.fileReadNoPermission))
    case .otherDomain:
        coder.fail("/Users/me/Downloads", with: NSError(domain: NSOSStatusErrorDomain, code: NSFileNoSuchFileError))
    case .unreadableVolume:
        coder.markDead("/Users/me/Downloads")
        coder.markVolumeUnreadable("/Users/me/Downloads")
    }

    try store.grant(folder(granted))

    let expected = granted == "/Users/me"
        ? [folder("/Users/meet"), folder("/Users/me")]
        : [folder("/Users/me/Documents"), folder("/Users/meet"), folder("/Users/me/Downloads")]
    #expect(store.grants == expected)
}

/// Granting a folder replaces a covered grant that doesn't resolve only when both are on one drive
/// (or the old grant's drive can't be read): drive B mounted where drive A was doesn't take A's grants.
enum OtherDriveCase: CaseIterable, Sendable { case anotherDrive, sameDrive, unreadableVolume }

@Test(arguments: OtherDriveCase.allCases, ["/Volumes/Drive/photos", "/Volumes/Drive"])
func grantingReplacesAGrantThatDoesntResolveOnlyOnTheSameDrive(_ drive: OtherDriveCase, _ granted: String) throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let volumes = FakeVolumes()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: FakeScope().scope,
                                  volumes: volumes.volumes, paths: gonePaths)
    coder.record(uuid: "A", forVolume: "/Volumes/Drive")
    try store.grant(folder("/Volumes/Drive/photos"))
    // Fails some way that isn't gone, so only the replacement can drop it.
    coder.fail("/Volumes/Drive/photos", with: CocoaError(.fileReadNoPermission))
    let mounted = drive == .sameDrive ? "A" : "B"
    volumes.unmount("/Volumes/Drive")
    volumes.mount("/Volumes/Drive", uuid: mounted)
    coder.record(uuid: mounted, forVolume: "/Volumes/Drive")
    if drive == .unreadableVolume { coder.markVolumeUnreadable("/Volumes/Drive/photos") }

    try store.grant(folder(granted))

    #expect(store.grants == (drive == .anotherDrive ? [folder("/Volumes/Drive/photos"), folder(granted)]
                                                    : [folder(granted)]))
}

// MARK: - Security scope

@Test func aFolderWhoseAccessWontStartIsSkippedSoTheAppAsksAgain() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let scope = FakeScope()
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: scope.scope, paths: gonePaths)
    try store.grant(folder("/Users/me"))
    try store.grant(folder("/Users/me/Downloads"))
    scope.refuse("/Users/me/Downloads")

    // The next granted ancestor that starts covers it.
    #expect(store.access(for: folder("/Users/me/Downloads/sub"))?.url.path == "/Users/me")

    scope.refuse("/Users/me")
    #expect(store.access(for: folder("/Users/me/Downloads/sub")) == nil)
    // Kept: a refusal now may not be one later.
    #expect(store.grants == [folder("/Users/me"), folder("/Users/me/Downloads")])
    #expect(scope.isBalanced)
}

@Test func accessStartsOnceAndStopsOnce() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let scope = FakeScope()
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: scope.scope, paths: gonePaths)
    try store.grant(folder("/Users/me"))

    let scoped = try #require(store.access(for: folder("/Users/me/sub")))
    #expect(scope.started("/Users/me") == 1)
    #expect(scope.stopped("/Users/me") == 0)
    scoped.stop()
    scoped.stop()
    #expect(scope.stopped("/Users/me") == 1)

    // Dropped without stop(): deinit stops it.
    do { _ = try #require(store.access(for: folder("/Users/me/sub"))) }
    #expect(scope.started("/Users/me") == 2)
    #expect(scope.isBalanced)
}

@Test func accessStaysBalancedOnEveryErrorPath() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let scope = FakeScope()
    let coder = FakeBookmarks()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: scope.scope, paths: gonePaths)
    try store.grant(folder("/Users/me"))
    try store.grant(folder("/Users/me/Downloads"))
    try store.grant(folder("/Users/me/Downloads/projects"))
    try store.grant(folder("/Users/me/Desktop"))

    // Dead, moved away and refused grants are passed over without a start, or with none left open.
    coder.markDead("/Users/me/Downloads/projects")
    coder.move("/Users/me/Downloads", to: "/Users/me/Elsewhere")
    scope.refuse("/Users/me")
    #expect(store.access(for: folder("/Users/me/Downloads/projects/x")) == nil)
    #expect(scope.started("/Users/me/Elsewhere") == 0)
    #expect(scope.isBalanced)

    // A stale grant whose refresh fails is still used now, and still stops.
    coder.markStale("/Users/me/Desktop")
    coder.refuseBookmarks()
    let scoped = try #require(store.access(for: folder("/Users/me/Desktop/x")))
    #expect(scope.started("/Users/me/Desktop") == 1)
    scoped.stop()
    #expect(scope.isBalanced)
}

@Test func aScopedFolderThatNeverStartedNeverStops() {
    let scope = FakeScope()
    do {
        let scoped = ScopedFolder(url: folder("/Users/me"), isAccessing: false, scope: scope.scope)
        scoped.stop()
    }
    #expect(scope.stopped("/Users/me") == 0)
}

// MARK: - Real bookmarks

@Test func aRealBookmarkRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderAccessStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults)

    try store.grant(directory)
    let scoped = try #require(FolderAccessStore(defaults: defaults).access(for: directory.appendingPathComponent("sub")))
    defer { scoped.stop() }

    #expect(FolderAccessStore.covers(scoped.url, directory))
    #expect(FolderAccessStore.covers(directory, scoped.url))
}

@Test func aRealBookmarkToADeletedFolderIsDropped() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderAccessStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults)
    try store.grant(directory)
    try FileManager.default.removeItem(at: directory)

    #expect(store.access(for: directory) == nil)
    #expect(store.grants.isEmpty)
}

/// A folder in the home folder (the app's container, when hosted), where a deleted folder's
/// security-scoped bookmark fails with Cocoa 259, where the temporary folder's fails with 4.
/// Hosted, applicationSupportDirectory is inside the app's container, so a real ~/Documents folder
/// granted through the open panel isn't covered here: it is a manual check on the hosted-run checklist.
private func makeHomeFolder() throws -> URL {
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
    let directory = support.appendingPathComponent("FolderAccessStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #require(FolderAccessStore.covers(FileManager.default.homeDirectoryForCurrentUser, directory))
    return directory
}

@Test func aRealBookmarkToADeletedFolderInTheHomeFolderIsDropped() throws {
    let directory = try makeHomeFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults)
    try store.grant(directory)
    try FileManager.default.removeItem(at: directory)

    #expect(store.access(for: directory) == nil)
    #expect(store.grants.isEmpty)
}

@Test func aRealFolderDeletedMadeAgainAndGrantedAgainIsOneGrant() throws {
    let directory = try makeHomeFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults)
    try store.grant(directory)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    try store.grant(directory)

    #expect(store.grants.count == 1)
    #expect(store.access(for: directory) != nil)
}

/// A folder that is still there, under one that can't be searched (chmod 000), keeps its grant,
/// however its bookmark fails meanwhile.
@Test func aRealFolderUnderAFolderThatCantBeSearchedIsKept() throws {
    let parent = try makeHomeFolder()
    defer {
        chmod(parent.path, 0o755)
        try? FileManager.default.removeItem(at: parent)
    }
    let directory = parent.appendingPathComponent("inside", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let other = try makeHomeFolder()
    defer { try? FileManager.default.removeItem(at: other) }
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults)
    try store.grant(directory)
    try #require(chmod(parent.path, 0) == 0)

    _ = store.access(for: directory)
    #expect(store.grants.map(\.path) == [directory.standardizedFileURL.path])
    try store.grant(other)
    #expect(store.grants.map(\.path) == [directory.standardizedFileURL.path, other.standardizedFileURL.path])
}

@Test func theSystemVolumesSeeTheBootVolumeMountedAndAMadeUpOneNot() {
    #expect(MountedVolumes.system.isMounted(VolumeIdentity(url: folder("/"))))
    #expect(!MountedVolumes.system.isMounted(VolumeIdentity(url: folder("/Volumes/KernirNoSuchDrive-\(UUID().uuidString)"))))
    // Another UUID at / is another volume only when the boot volume's UUID can be read (a sandbox
    // may not); else the path decides.
    let bootHasUUID = MountedVolumes.system.list().contains { $0.url.standardizedFileURL.path == "/" && $0.uuid != nil }
    #expect(MountedVolumes.system.isMounted(VolumeIdentity(url: folder("/"), uuid: UUID().uuidString)) == !bootHasUUID)
}

@Test func aRealBookmarkKnowsItsVolume() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderAccessStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coder = SystemBookmarkCoding()
    let bookmark = try coder.bookmark(for: directory)
    try FileManager.default.removeItem(at: directory)

    let volume = try #require(coder.volume(of: bookmark))
    // Known by its UUID, which a mounted volume has too, when UUIDs can be read (a sandbox may not
    // read them); else by its path.
    if MountedVolumes.system.list().contains(where: { $0.url.standardizedFileURL.path == "/" && $0.uuid != nil }) {
        let uuid = try #require(volume.uuid)
        #expect(MountedVolumes.system.list().contains { $0.uuid == uuid })
    }
    #expect(MountedVolumes.system.isMounted(volume))
    #expect(coder.volume(of: Data("not a bookmark".utf8)) == nil)
}

// MARK: - Own container

/// The app's own container, where it may always write: covered with no grant, nothing started or
/// saved, nothing stopped on release, even with a grant inside it.
@Test func theOwnContainerNeedsNoGrant() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let coder = FakeBookmarks()
    let scope = FakeScope()
    let store = FolderAccessStore(defaults: defaults, coder: coder, scope: scope.scope, paths: gonePaths,
                                  ownContainer: folder("/c"))

    for destination in ["/c", "/c/Documents/sub"] {
        do {
            let scoped = try #require(store.access(for: folder(destination)))
            #expect(scoped.url.path == "/c")
            scoped.stop()
        }
    }
    #expect(defaults.data(forKey: FolderAccessStore.defaultKey) == nil)
    #expect(coder.bookmarksMade == 0)

    try store.grant(folder("/c/Documents"))
    let saved = defaults.data(forKey: FolderAccessStore.defaultKey)
    do {
        let scoped = try #require(store.access(for: folder("/c/Documents/sub")))
        #expect(scoped.url.path == "/c")
    }
    #expect(scope.started("/c") == 0)
    #expect(scope.started("/c/Documents") == 0)
    #expect(scope.stopped("/c") == 0)
    #expect(scope.stopped("/c/Documents") == 0)
    #expect(defaults.data(forKey: FolderAccessStore.defaultKey) == saved)
}

@Test func theOwnContainerMatchesItsPrivateSpelling() {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths,
                                  ownContainer: folder("/var/x"))
    #expect(store.access(for: folder("/private/var/x/Documents"))?.url.path == "/var/x")
}

/// Whole path components: "<container>X" is another folder.
@Test func aSiblingWithTheContainersNameAndMoreIsNotTheContainer() {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths,
                                  ownContainer: folder("/c"))
    #expect(store.access(for: folder("/cX")) == nil)
    #expect(store.access(for: folder("/cX/Documents")) == nil)
}

/// A symlink in the container that points out of it leads out of it: that needs a grant.
@Test func aSymlinkInTheContainerPointingOutIsNotTheContainer() throws {
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderAccessStoreTests-\(UUID().uuidString)", isDirectory: true)
    let container = work.appendingPathComponent("Container", isDirectory: true)
    let outside = work.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: container.appendingPathComponent("Documents"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside.appendingPathComponent("sub"),
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let link = container.appendingPathComponent("Documents/Downloads", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths,
                                  ownContainer: container)

    #expect(store.access(for: container.appendingPathComponent("Documents")) != nil)
    #expect(store.access(for: link) == nil)
    #expect(store.access(for: link.appendingPathComponent("sub")) == nil)
}

/// A folder not made yet, below a symlink in the container that points out of it, leads out of it
/// too: the link is followed though the rest of the path isn't there.
@Test func aFolderNotMadeYetBelowASymlinkPointingOutIsNotTheContainer() throws {
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderAccessStoreTests-\(UUID().uuidString)", isDirectory: true)
    let container = work.appendingPathComponent("Container", isDirectory: true)
    let outside = work.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: container.appendingPathComponent("Documents"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let link = container.appendingPathComponent("Documents/L", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                  paths: gonePaths,
                                  ownContainer: container)
    let destination = link.appendingPathComponent("new/deeper", isDirectory: true)
    try #require(!FileManager.default.fileExists(atPath: destination.path))

    #expect(store.access(for: destination) == nil)
    #expect(store.access(for: container.appendingPathComponent("Documents/new/deeper")) != nil)
}

/// The container given through a symlink is the folder it points to, either way round.
@Test func theOwnContainerThroughASymlinkIsTheContainer() throws {
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderAccessStoreTests-\(UUID().uuidString)", isDirectory: true)
    let container = work.appendingPathComponent("Container", isDirectory: true)
    try FileManager.default.createDirectory(at: container.appendingPathComponent("Documents/x"),
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let link = work.appendingPathComponent("LinkToContainer", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: container)
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }

    for (ownContainer, destinationRoot) in [(link, container), (container, link)] {
        let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: FakeScope().scope,
                                      paths: gonePaths,
                                      ownContainer: ownContainer)
        for tail in ["Documents/x", "Documents/x/new"] {
            let destination = destinationRoot.appendingPathComponent(tail, isDirectory: true)
            #expect(store.access(for: destination)?.url == ownContainer, "\(tail)")
        }
    }
}

/// Off by default: a store without a container asks for any folder it has no grant for, and
/// follows the grants as before.
@Test func noOwnContainerByDefault() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let scope = FakeScope()
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: scope.scope, paths: gonePaths)

    #expect(store.ownContainer == nil)
    #expect(store.access(for: folder(NSHomeDirectory())) == nil)
    #expect(store.access(for: folder(NSHomeDirectory() + "/Documents")) == nil)
    try store.grant(folder("/c"))
    let scoped = try #require(store.access(for: folder("/c/Documents")))
    #expect(scope.started("/c") == 1)
    scoped.stop()
    #expect(scope.stopped("/c") == 1)
}

@Test func outsideTheContainerGrantsStillDecide() throws {
    let (defaults, suite) = makeDefaults()
    defer { removeTestDefaults(defaults, suite: suite) }
    let scope = FakeScope()
    let store = FolderAccessStore(defaults: defaults, coder: FakeBookmarks(), scope: scope.scope, paths: gonePaths,
                                  ownContainer: folder("/c"))

    #expect(store.access(for: folder("/Users/me/Downloads")) == nil)
    try store.grant(folder("/Users/me"))
    let scoped = try #require(store.access(for: folder("/Users/me/Downloads")))
    #expect(scoped.url.path == "/Users/me")
    #expect(scope.started("/Users/me") == 1)
    scoped.stop()
    #expect(scope.isBalanced)
}
