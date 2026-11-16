import CryptoKit
import Foundation
import os

/// Per-archive cache of single entries extracted to real files (Quick Look, drag-out, Open With).
/// Each entry gets a folder of its own under `root`, named by the SHA-256 of its exact path bytes, and keeps its
/// file name inside it: `root/<hash>/<leaf>`. Never `root/<entry path>`: names that differ only in case
/// (README, Readme) or Unicode normalization are one file on APFS, and a file "a" is the folder of "A/b", so a
/// second extraction would replace or block the first one's file while its cached URL still "exists".
final class TemporaryExtractionCache: Sendable {
    let root: URL
    private let urls = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kernir", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The stored URL, only if the file still exists.
    func cachedURL(for path: String) -> URL? {
        guard let url = urls.withLock({ $0[path] }) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where the file of `path` goes: the same place on every call, and a folder no other path shares, since the
    /// hash is of the exact UTF-8 bytes (`String` equality would merge NFC and NFD) and lowercase hex.
    ///
    /// `path` must be a normalized entry path (`EntryPath.normalize` output, as the reader passes): its last
    /// component is the file name. A path whose leaf is not a file name ("", "/", ".", "..", or one ending in
    /// them) would name the hash folder or the root itself; debug builds assert on it (`hasFileName`).
    func destination(for path: String) -> URL {
        assert(Self.hasFileName(path), "not a normalized entry path: \(path.debugDescription)")
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent(Self.leaf(of: path), isDirectory: false)
    }

    /// The last component, split on scalars like EntryPath: a "/" followed by a combining mark still ends one.
    private static func leaf(of path: String) -> String { EntryPath.split(path).last ?? path }

    /// True when the leaf of `path` is a file name: not empty, ".", "..", and no "/" or NUL.
    static func hasFileName(_ path: String) -> Bool { EntryPath.isValidComponent(leaf(of: path)) }

    func store(_ url: URL, for path: String) {
        urls.withLock { $0[path] = url }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
