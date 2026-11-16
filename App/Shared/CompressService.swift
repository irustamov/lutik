import Foundation
import KernirCore
import os

/// Compresses files and folders into a new archive beside them, with no document or window:
/// Finder's Services (and later App Intents) call it. The archive is written into a hidden staging
/// folder in the destination folder, then moved to `CompressPlan`'s name with an exclusive rename,
/// so it never replaces anything, even an item that takes the name at that instant. The staging
/// folder is gone afterwards: on success, failure and cancellation.
///
/// Redundant nested items (a folder and an item inside it, which Finder's list view can select)
/// are all archived, as Finder's own Compress does: what was selected is what the archive holds.
/// The archive and its staging go beside the outermost item (`CompressPlan`), never inside an
/// item, so the staging never becomes part of the input.
struct CompressService: Sendable {
    private static let logger = Logger(subsystem: "com.kernir.app", category: "compress")

    /// Renames with and names its staging by. Tests swap it.
    var fileSystem: ExtractionFileSystem = .system

    /// `compress` got no items: a caller's mistake, since every Service and intent sends at least one.
    struct NothingToCompress: Error, Equatable {}

    /// Writes `items` as a new `format` archive beside them (`CompressPlan`), or in `folder` when
    /// one is given, and returns its URL.
    /// Throws `ArchiveError.cancelled` when the task is cancelled before the archive is in place.
    /// `.DS_Store` files are left out by the engine.
    func compress(_ items: [URL], format: ArchiveFormat, in folder: URL? = nil, options: ArchiveWriteOptions? = nil,
                  progress: ArchiveProgressHandler? = nil) async throws -> URL {
        // Checked first: with `folder` given, the guard below doesn't look at `items`.
        guard !items.isEmpty else { throw NothingToCompress() }
        // Plan with each item's folder spelled without symlinks, so a file reached through a link
        // into another item is still seen as inside it.
        let planned = items.map {
            $0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent)
        }
        guard let directory = folder ?? CompressPlan.destination(for: planned, format: format, existingNames: [])?.directory else {
            throw NothingToCompress()
        }
        let fileManager = FileManager.default
        // The same name ArchiveModel's extraction staging has, so its sweep finds one a crash left.
        let staging = directory.appendingPathComponent(
            ".kernir-\(fileSystem.deviceToken)-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            do {
                try fileManager.removeItem(at: staging)
            } catch {
                // A locked item, say: the remnant is hidden, and only a sweep that can delete it removes it.
                Self.logger.error("Cannot remove staging \(staging.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            }
        }

        let staged = staging.appendingPathComponent("Archive." + format.fileExtension)
        let changes = ArchiveChangeSet(additions: items.map {
            ArchiveChangeSet.Addition(sourceURL: $0, destinationDirectory: "")
        })
        try await ArchiveWriter.write(source: nil, changes: changes, format: format, to: staged,
                                      options: options, progress: progress)
        if Task.isCancelled { throw ArchiveError.cancelled }
        // CompressPlan names the archive and every next try ("Archive 2.zip", trimmed to fit) from the
        // folder's listing plus each name refused since; UniquePlacement moves it there exclusively.
        var taken = Set(try fileManager.contentsOfDirectory(atPath: directory.path))
        guard let first = CompressPlan.destination(for: items, format: format, existingNames: taken)?.name else {
            throw NothingToCompress()
        }
        return try UniquePlacement.place(staged, named: first, in: directory, isDirectory: false,
                                         fileSystem: fileSystem) { refused, _, _ in
            taken.insert(refused)
            // Never nil: the first guard (`NothingToCompress`) already returned for empty `items`.
            return CompressPlan.destination(for: items, format: format, existingNames: taken)?.name ?? refused
        }
    }
}
