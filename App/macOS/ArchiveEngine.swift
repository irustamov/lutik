import Foundation
import KernirCore

/// The archive engine behind `ArchiveDocument`, as swappable closures so tests can inject fakes.
struct ArchiveEngine: Sendable {
    /// Opens a file the way the app does, with the name encoding remembered for it.
    var open: @Sendable (URL, String?) async throws -> any ArchiveReading
    /// Opens a file with its names decoded as the encoding passed says: the reopen after a save
    /// (`ArchiveModel.openSaved`), which decides the encoding itself.
    var openWithNameEncoding: @Sendable (URL, String?, ArchiveNameEncoding) async throws -> any ArchiveReading
    var write: @Sendable (_ source: (any ArchiveReading)?, _ changes: ArchiveChangeSet, _ format: ArchiveFormat,
                          _ to: URL, _ options: ArchiveWriteOptions?, _ progress: ArchiveProgressHandler?) async throws -> Void

    /// Without `openWithNameEncoding`, it opens with `open` and ignores the encoding, as a fake engine's
    /// readers don't decode names.
    init(open: @escaping @Sendable (URL, String?) async throws -> any ArchiveReading,
         openWithNameEncoding: (@Sendable (URL, String?, ArchiveNameEncoding) async throws -> any ArchiveReading)? = nil,
         write: @escaping @Sendable (_ source: (any ArchiveReading)?, _ changes: ArchiveChangeSet,
                                     _ format: ArchiveFormat, _ to: URL, _ options: ArchiveWriteOptions?,
                                     _ progress: ArchiveProgressHandler?) async throws -> Void) {
        self.open = open
        self.openWithNameEncoding = openWithNameEncoding ?? { url, password, _ in try await open(url, password) }
        self.write = write
    }

    /// KernirCore: `Archive.open`, with the name encoding remembered for the file, and `ArchiveWriter.write`.
    /// No test opens through `live.open` with a choice remembered: that would read and write the app's own
    /// defaults (`ArchiveNameEncodingStore.shared`). Tests cover the store's `open` on a store of their own.
    static let live = ArchiveEngine(
        open: { url, password in
            try await ArchiveNameEncodingStore.shared.open(url, password: password)
        },
        openWithNameEncoding: { url, password, nameEncoding in
            try await Archive.open(at: url, password: password, nameEncoding: nameEncoding)
        },
        write: { source, changes, format, url, options, progress in
            try await ArchiveWriter.write(source: source, changes: changes, format: format, to: url,
                                          options: options, progress: progress)
        }
    )

    /// Writes a split set into an empty folder and returns its volumes in order:
    /// `ArchiveWriter.writeVolumes`. A default value rather than an `init` parameter, so engines built
    /// without it (`live`, the fakes in tests) keep compiling; a test that splits sets its own.
    var writeVolumes: @Sendable (_ source: (any ArchiveReading)?, _ changes: ArchiveChangeSet,
                                 _ format: ArchiveFormat, _ directory: URL, _ baseName: String,
                                 _ options: ArchiveWriteOptions,
                                 _ progress: ArchiveProgressHandler?) async throws -> [URL] = {
        source, changes, format, directory, baseName, options, progress in
        try await ArchiveWriter.writeVolumes(source: source, changes: changes, format: format, into: directory,
                                             baseName: baseName, options: options, progress: progress)
    }
}
