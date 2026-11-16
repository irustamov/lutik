import Foundation
import KernirCore
import os

/// New archives and copies.
///
/// A new archive is written empty with the chosen options, then handed to the document browser,
/// which moves it into place and opens it through the normal URL read. An empty archive carries no
/// detectable encryption, so its settings are kept here under the file's URL until its document
/// opens and adopts them (`ArchiveModel.apply`): its in-place saves then keep the encryption and
/// password the user chose.
extension ArchiveDocument {
    /// Writes an empty archive at `url` with `settings`' format and explicit options.
    static func makeEmpty(at url: URL, settings: ArchiveSaveSettings) async throws {
        let engine = engine
        try await engine.write(nil, ArchiveChangeSet(), settings.format, url, settings.options, nil)
    }

    /// Writes the open archive, pending edits included, to `url` with `settings`. The document and
    /// its model are left as they were: the settings apply to this copy only. A comment edit goes into
    /// a format with comments only (`ArchiveModel.saveChanges(as:)`); one Lutik won't write refuses the
    /// copy before anything is written (`ArchiveModel.saveProblem(as:split:)`). A split copy writes `.keep`,
    /// as on the Mac (`saveSplit`): the split writer takes no other, a typed comment has refused the copy,
    /// and a removed one is what `.keep` writes into a set.
    @MainActor func writeCopy(to url: URL, settings: ArchiveSaveSettings,
                              progress: ArchiveProgressHandler?) async throws {
        guard let model = session.model else { throw CocoaError(.fileWriteUnknown) }
        let split = settings.options.volumeSize != nil
        if let problem = model.saveProblem(as: settings.format, split: split) {
            throw CommentSaveError(message: problem,
                                   recoverySuggestion: split ? ArchiveModel.splitSaveRecoverySuggestion : nil)
        }
        var changes = model.saveChanges(as: settings.format)
        if split { changes.comment = .keep }
        let engine = engine
        try await engine.write(model.reader, changes, settings.format, url, settings.options, progress)
    }

    // MARK: - Settings of new archives

    /// Settings of new archives whose documents haven't opened yet, by file path.
    private static let newArchives = OSAllocatedUnfairLock<[String: ArchiveSaveSettings]>(initialState: [:])

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Keeps `settings` for the new archive at `url`.
    static func registerNewArchive(_ settings: ArchiveSaveSettings, at url: URL) {
        newArchives.withLock { $0[key(url)] = settings }
    }

    /// The new archive at `source` is now at `destination` (the browser moved it).
    static func newArchiveDidMove(from source: URL, to destination: URL) {
        newArchives.withLock { archives in
            if let settings = archives.removeValue(forKey: key(source)) {
                archives[key(destination)] = settings
            }
        }
    }

    /// The settings the new archive at `url` was created with, while its document hasn't adopted them.
    static func newArchiveSettings(for url: URL) -> ArchiveSaveSettings? {
        newArchives.withLock { $0[key(url)] }
    }

    /// Returns and forgets the settings of the new archive at `url`.
    static func takeNewArchiveSettings(for url: URL) -> ArchiveSaveSettings? {
        newArchives.withLock { $0.removeValue(forKey: key(url)) }
    }
}

/// The archive comment can't be written (`ArchiveModel.saveProblem(as:split:)`): the save or copy is refused and
/// nothing written. `message` is the one the Info sheet shows under the comment.
struct CommentSaveError: LocalizedError {
    let message: String
    var recoverySuggestion: String?

    var errorDescription: String? { message }
}
