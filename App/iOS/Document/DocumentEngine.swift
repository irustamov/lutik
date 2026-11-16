import Foundation
import KernirCore

/// The archive engine calls `ArchiveDocument` makes; tests swap in a fake.
struct DocumentEngine: Sendable {
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

    /// KernirCore, opening with the name encoding remembered for the file.
    static let live = DocumentEngine(
        open: { url, password in
            try await ArchiveNameEncodingStore.shared.open(url, password: password)
        },
        openWithNameEncoding: { url, password, nameEncoding in
            try await Archive.open(at: url, password: password, nameEncoding: nameEncoding)
        },
        write: { source, changes, format, url, options, progress in
            try await ArchiveWriter.write(source: source, changes: changes, format: format, to: url,
                                          options: options, progress: progress)
        })
}

#if DEBUG
extension DocumentEngine {
    /// For UI tests (`-KernirSlowExtract`): every reader this engine opens takes `delay` longer to
    /// extract, so preview and share are slow enough to show their progress sheet.
    func slowingExtraction(by delay: Duration) -> DocumentEngine {
        var engine = self
        let open = self.open
        let openWithNameEncoding = self.openWithNameEncoding
        engine.open = { url, password in
            SlowReader(base: try await open(url, password), delay: delay)
        }
        engine.openWithNameEncoding = { url, password, nameEncoding in
            SlowReader(base: try await openWithNameEncoding(url, password, nameEncoding), delay: delay)
        }
        return engine
    }
}

/// A reader that waits `delay` before each extraction. Cancelling the wait throws `.cancelled`,
/// like the engine. Saving still works, except that KernirCore can't see an encrypted source's
/// password through the wrapper; the UI tests using it don't save.
private struct SlowReader: ArchiveReading {
    let base: any ArchiveReading
    let delay: Duration

    var url: URL { base.url }
    var volumeURLs: [URL] { base.volumeURLs }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }
    var encryption: ArchiveEncryption { base.encryption }
    var compressionMethod: ArchiveCompressionMethod? { base.compressionMethod }
    var nameEncoding: ArchiveNameEncoding { base.nameEncoding }
    var legacyNameEncoding: String.Encoding? { base.legacyNameEncoding }
    var comment: ArchiveComment? { base.comment }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await wait()
        try await base.extract(paths, to: directory, progress: progress)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await wait()
        return try await base.extractToTemporaryFile(path)
    }

    private func wait() async throws {
        do {
            try await Task.sleep(for: delay)
        } catch {
            throw ArchiveError.cancelled
        }
    }
}
#endif
