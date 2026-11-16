import Foundation
@testable import Kernir

// The FolderAccessStore seams for Extract Here's tests. Copies of the private fakes in
// KernirMacTests' FolderAccessStoreTests.swift: the test targets share no sources.

/// Bookmarks as plain paths. A folder marked stale resolves as stale; a dead one doesn't resolve
/// (file not found), nor does one failing with another error; a moved one resolves to where it went.
/// A bookmark's volume is /Volumes/<name> for a path there, / otherwise, unless marked unreadable;
/// it has the UUID recorded for that volume when it was made, if any. Counts the bookmarks it makes.
final class FakeBookmarks: BookmarkCoding, @unchecked Sendable {
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
            return VolumeIdentity(url: fakeFolder(Self.volumePath(of: path)), uuid: uuid)
        }
    }
}

/// Mounted volumes: / and /Volumes/Drive, without UUIDs, until unmounted or others are mounted.
/// So a dead grant's "is its volume mounted" doesn't depend on the simulator's mount list.
final class FakeVolumes: @unchecked Sendable {
    private let lock = NSLock()
    private var mounted: [VolumeIdentity] = [VolumeIdentity(url: fakeFolder("/")),
                                             VolumeIdentity(url: fakeFolder("/Volumes/Drive"))]

    func unmount(_ path: String) { lock.withLock { mounted.removeAll { $0.url.path == path } } }
    func mount(_ path: String, uuid: String? = nil) {
        lock.withLock { mounted.append(VolumeIdentity(url: fakeFolder(path), uuid: uuid)) }
    }

    var volumes: MountedVolumes {
        MountedVolumes(list: { self.lock.withLock { self.mounted } })
    }
}

/// Security scope that counts each folder's starts and stops; a refused folder doesn't start.
final class FakeScope: @unchecked Sendable {
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

private func fakeFolder(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
}
