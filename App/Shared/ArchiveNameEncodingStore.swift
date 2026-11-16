import Foundation
import KernirCore
import os

/// The name encoding the user chose for each archive file (View > Text Encoding on the Mac), kept in the
/// app's defaults so reopening the same archive, on macOS or iOS, reads its names the same way.
///
/// A record is keyed by the file's path and holds the file's identity: its file ID and its creation date. A
/// record applies only while the file at that path still has one of them, so another archive saved under the
/// same name later isn't read with this one's choice. A save in place keeps the file ID; a safe save (a new
/// file swapped in with `FileManager.replaceItemAt`, as NSDocument and UIDocument do) keeps the creation date.
/// Lutik's own saves don't rely on either: they decide again for the file they wrote
/// (`ArchiveModel.openSaved(_:open:)`), which keeps the choice only while legacy names survived the save.
///
/// Only manual choices are kept; Automatic removes the record. At most `capacity` records are kept: the least
/// recently used one goes first. Quick Look never reads this (it always decodes automatically).
final class ArchiveNameEncodingStore: Sendable {
    /// The app's store, in its standard defaults.
    static let shared = ArchiveNameEncodingStore(defaults: .standard)

    /// How many archives keep their choice. A record is the path plus about 60 bytes, so the defaults entry
    /// stays well under 100 KB even with long paths.
    static let defaultCapacity = 200

    static let defaultsKey = "KernirNameEncodings"

    let capacity: Int

    private struct Record: Codable, Equatable {
        var path: String
        /// `String.Encoding.rawValue`, one of `ArchiveNameEncoding.choices`.
        var encoding: UInt
        var fileID: UInt64?
        /// Seconds since the reference date.
        var created: Double?
    }

    private struct Identity: Equatable {
        var fileID: UInt64?
        var created: Double?

        func matches(_ record: Record) -> Bool {
            (fileID != nil && fileID == record.fileID) || (created != nil && created == record.created)
        }
    }

    private nonisolated(unsafe) let defaults: UserDefaults
    /// Serializes read-modify-write of the defaults entry: documents open on background threads.
    private let lock = OSAllocatedUnfairLock()

    init(defaults: UserDefaults, capacity: Int = defaultCapacity) {
        self.defaults = defaults
        self.capacity = max(1, capacity)
    }

    /// The encoding to open `url` with: the choice remembered for this file, or `.automatic`.
    func nameEncoding(for url: URL) -> ArchiveNameEncoding {
        let path = Self.key(for: url)
        guard let identity = Self.identity(ofFileAt: path) else { return .automatic }
        return lock.withLock {
            var records = load()
            guard let index = records.firstIndex(where: { $0.path == path }) else { return .automatic }
            let record = records[index]
            guard identity.matches(record), ArchiveNameEncoding.choices.map(\.rawValue).contains(record.encoding) else {
                // Another file now has this path (or the record is unreadable): it doesn't apply any more.
                records.remove(at: index)
                save(records)
                return .automatic
            }
            // Most recently used first; already first, nothing to write.
            if index > 0 {
                records.remove(at: index)
                records.insert(record, at: 0)
                save(records)
            }
            return .specific(String.Encoding(rawValue: record.encoding))
        }
    }

    /// Remembers a manual choice for the file at `url` (as it is now); `.automatic` forgets the file's record.
    func remember(_ encoding: ArchiveNameEncoding, for url: URL) {
        let path = Self.key(for: url)
        let identity = Self.identity(ofFileAt: path)
        lock.withLock {
            var records = load()
            let index = records.firstIndex(where: { $0.path == path })
            if let index { records.remove(at: index) }
            guard case .specific(let chosen) = encoding, let identity else {
                // Nothing to write when there was nothing to forget.
                if index != nil { save(records) }
                return
            }
            records.insert(Record(path: path, encoding: chosen.rawValue, fileID: identity.fileID,
                                  created: identity.created), at: 0)
            save(Array(records.prefix(capacity)))
        }
    }

    /// Opens `url` the way the apps do: names decode with the choice remembered for the file, or automatically.
    func open(_ url: URL, password: String?) async throws -> any ArchiveReading {
        try await Archive.open(at: url, password: password, nameEncoding: nameEncoding(for: url))
    }

    // MARK: - Storage

    private func load() -> [Record] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records
    }

    private func save(_ records: [Record]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The same file's path however it was reached: standardized, symbolic links resolved.
    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// nil when nothing is at `path`. Read from a fresh URL: a URL caches resource values.
    private static func identity(ofFileAt path: String) -> Identity? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileIdentifierKey,
                                                                                    .creationDateKey])
        else { return nil }
        let identity = Identity(fileID: values.fileIdentifier,
                                created: values.creationDate?.timeIntervalSinceReferenceDate)
        return identity.fileID == nil && identity.created == nil ? nil : identity
    }
}
