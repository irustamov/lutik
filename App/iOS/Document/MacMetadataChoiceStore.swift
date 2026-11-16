import Foundation
import os

/// The user's answer to "Remove Mac metadata?" for each archive file on iOS: true
/// is Remove (strip), false is Keep. Kept in the app's defaults so the question isn't asked again after the
/// archive is closed and reopened. Modelled on `ArchiveNameEncodingStore`.
///
/// A record is keyed by the file's path and holds the file's identity: its file ID and its creation date.
/// A record applies only while the file at that path still matches, and the match is asymmetric:
/// - Keep matches by file ID or creation date. A safe save (`FileManager.replaceItemAt`, as UIDocument
///   does) keeps the creation date, and keeping metadata in a file the user didn't answer for loses nothing.
/// - Remove matches only by a file ID that both the file and the record have. Stripping a file the user
///   never answered for would delete its entries, so a Remove is stored only with a file ID; without one
///   it lasts for the session only (the document holds it, until the file is read again: a revert drops
///   a Remove the store has nothing for). The caller remembers the answer again after each of its own
///   saves (`remember(_:for:savedFileID:)`), which gives the record the new file's ID: a Remove only while
///   the file at the path is still the one that save wrote.
///
/// Only explicit answers are stored. At most `capacity` records are kept: the least recently used one goes
/// first. Paths stay in the local defaults and are never logged.
final class MacMetadataChoiceStore: Sendable {
    /// The app's store, in its standard defaults.
    static let shared = MacMetadataChoiceStore(defaults: .standard)

    /// How many archives keep their answer. A record is the path plus about 60 bytes, so the defaults entry
    /// stays well under 100 KB even with long paths.
    static let defaultCapacity = 200

    static let defaultsKey = "KernirMacMetadataChoices"

    /// What identifies a file at a path: its file ID and its creation date (seconds since the reference date).
    struct FileIdentity: Equatable, Sendable {
        var fileID: UInt64?
        var created: Double?
    }

    let capacity: Int

    private struct Record: Codable, Equatable {
        var path: String
        /// The answer: true is Remove.
        var strips: Bool
        var fileID: UInt64?
        /// Seconds since the reference date.
        var created: Double?
    }

    private nonisolated(unsafe) let defaults: UserDefaults
    private let identityOfFile: @Sendable (String) -> FileIdentity?
    /// Serializes read-modify-write of the defaults entry: documents open on background threads.
    private let lock = OSAllocatedUnfairLock()

    /// `identityOfFile` reads a path's identity, nil when nothing is there; tests replace it to stand for a
    /// file system without file IDs.
    init(defaults: UserDefaults, capacity: Int = defaultCapacity,
         identityOfFile: @escaping @Sendable (String) -> FileIdentity? = MacMetadataChoiceStore.identity(ofFileAt:)) {
        self.defaults = defaults
        self.capacity = max(1, capacity)
        self.identityOfFile = identityOfFile
    }

    /// The answer remembered for the file at `url` (true is Remove), or nil when there is none for this file.
    func choice(for url: URL) -> Bool? {
        let path = Self.key(for: url)
        let identity = identityOfFile(path)
        return lock.withLock {
            var records = load()
            guard let index = records.firstIndex(where: { $0.path == path }) else { return nil }
            let record = records[index]
            guard let identity, Self.matches(identity, record) else {
                // Another file now has this path: the answer doesn't apply any more.
                records.remove(at: index)
                save(records)
                return nil
            }
            // Most recently used first; already first, nothing to write.
            if index > 0 {
                records.remove(at: index)
                records.insert(record, at: 0)
                save(records)
            }
            return record.strips
        }
    }

    /// Remembers the user's answer for the file at `url` as it is now (true is Remove), replacing any earlier
    /// one. Not stored when the file can't be identified, or for a Remove without a file ID: the answer is
    /// then the session's only.
    func remember(_ strips: Bool, for url: URL) {
        let path = Self.key(for: url)
        replaceRecord(at: path, with: strips, identity: identityOfFile(path))
    }

    /// After a save of the file at `url` that wrote a file with `savedFileID`: remembers the answer as
    /// `remember(_:for:)` does, unless it is a Remove and the file at `url` now isn't the one written (iCloud
    /// or another app replaced it since). That Remove is not stored and false is returned: stripping that file
    /// would delete entries the user never answered for. An earlier record for the path goes too, as
    /// housekeeping: it holds the pre-save file's ID, which can't match the new file anyway. A Keep is
    /// remembered either way: keeping loses nothing.
    @discardableResult
    func remember(_ strips: Bool, for url: URL, savedFileID: UInt64?) -> Bool {
        let path = Self.key(for: url)
        let identity = identityOfFile(path)
        let mayRemember = Self.mayRememberAfterSave(strips, savedFileID: savedFileID, current: identity)
        // Refused: no identity stores nothing. Dropping the earlier record is housekeeping, not safety: it
        // has the pre-save file's ID, which can't match the new file.
        replaceRecord(at: path, with: strips, identity: mayRemember ? identity : nil)
        return mayRemember
    }

    /// The file ID of the file at `url`, read as the store reads it; nil without one. What a save wrote,
    /// for `remember(_:for:savedFileID:)`.
    func fileID(of url: URL) -> UInt64? {
        identityOfFile(Self.key(for: url))?.fileID
    }

    /// Replaces the record for `path` with the answer for a file with `identity`; nil stores nothing.
    private func replaceRecord(at path: String, with strips: Bool, identity: FileIdentity?) {
        lock.withLock {
            var records = load()
            let index = records.firstIndex(where: { $0.path == path })
            if let index { records.remove(at: index) }
            guard let identity, Self.isStorable(strips, identity) else {
                // Nothing to write when there was nothing to forget.
                if index != nil { save(records) }
                return
            }
            records.insert(Record(path: path, strips: strips, fileID: identity.fileID, created: identity.created),
                           at: 0)
            save(Array(records.prefix(capacity)))
        }
    }

    /// Forgets the answer for the file at `url`.
    func forget(_ url: URL) {
        let path = Self.key(for: url)
        lock.withLock {
            var records = load()
            guard let index = records.firstIndex(where: { $0.path == path }) else { return }
            records.remove(at: index)
            save(records)
        }
    }

    // MARK: - Matching

    /// After a save: a Keep always; a Remove only while the file at the path has the file ID the save wrote
    /// (both without one: a file system without file IDs, where the Remove is the session's only anyway).
    static func mayRememberAfterSave(_ strips: Bool, savedFileID: UInt64?, current: FileIdentity?) -> Bool {
        !strips || current?.fileID == savedFileID
    }

    /// Keep needs a file ID or a creation date; Remove needs a file ID.
    private static func isStorable(_ strips: Bool, _ identity: FileIdentity) -> Bool {
        strips ? identity.fileID != nil : (identity.fileID != nil || identity.created != nil)
    }

    /// Remove: the same file ID, which neither side may lack. Keep: the same file ID or creation date.
    private static func matches(_ identity: FileIdentity, _ record: Record) -> Bool {
        let sameFileID = identity.fileID != nil && identity.fileID == record.fileID
        if record.strips { return sameFileID }
        return sameFileID || (identity.created != nil && identity.created == record.created)
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

    /// The same file's path however it was reached: standardized, symbolic links resolved (so `/var` and
    /// `/private/var` are one path).
    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// nil when nothing is at `path`, or when it has neither a file ID nor a creation date. Read from a fresh
    /// URL: a URL caches resource values.
    static func identity(ofFileAt path: String) -> FileIdentity? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileIdentifierKey,
                                                                                    .creationDateKey])
        else { return nil }
        let identity = FileIdentity(fileID: values.fileIdentifier,
                                    created: values.creationDate?.timeIntervalSinceReferenceDate)
        return identity.fileID == nil && identity.created == nil ? nil : identity
    }
}
