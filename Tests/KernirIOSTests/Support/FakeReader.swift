import Foundation
import KernirCore

/// In-memory `ArchiveReading` for tests. Extraction writes each file's path as its
/// UTF-8 contents, so tests can tell which entry produced which file.
struct FakeReader: ArchiveReading {
    let url: URL
    let format: ArchiveFormat
    let entries: [ArchiveEntry]
    let isEncrypted: Bool
    /// Thrown by every extraction, as the engine would (`.cancelled`, `.unsupportedEncryption`, …).
    let failure: ArchiveError?
    /// With a `failure`: how many entries `extract` writes before throwing it, as a damaged entry
    /// midway does. nil throws it before writing anything.
    let failureAfter: Int?
    /// How long `extract` and `extractToTemporaryFile` take, to keep an extraction in flight.
    /// Cancelling it throws `.cancelled`, like the engine.
    let extractDelay: Duration
    /// The encoding the names were asked to be read with. The entries stay as given: the fake
    /// decodes nothing.
    let nameEncoding: ArchiveNameEncoding
    /// The code page the archive's undeclared names are stored in, as the engine detects it; nil
    /// when every name is declared or ASCII (Text Encoding is off then).
    let legacyNameEncoding: String.Encoding?
    /// The files that make up the archive; more than one for a multi-volume set.
    let volumeURLs: [URL]
    /// The archive comment, as the engine reads it; nil for none.
    let comment: ArchiveComment?

    init(entries: [ArchiveEntry], format: ArchiveFormat = .zip,
         url: URL = URL(fileURLWithPath: "/tmp/fake.zip"), isEncrypted: Bool = false,
         failure: ArchiveError? = nil, failureAfter: Int? = nil, extractDelay: Duration = .zero,
         nameEncoding: ArchiveNameEncoding = .automatic, legacyNameEncoding: String.Encoding? = nil,
         volumeURLs: [URL]? = nil, comment: ArchiveComment? = nil) {
        self.entries = entries
        self.format = format
        self.url = url
        self.isEncrypted = isEncrypted
        self.failure = failure
        self.failureAfter = failureAfter
        self.extractDelay = extractDelay
        self.nameEncoding = nameEncoding
        self.legacyNameEncoding = legacyNameEncoding
        self.volumeURLs = volumeURLs ?? [url]
        self.comment = comment
    }

    /// This reader as opened with `nameEncoding`.
    func reading(as nameEncoding: ArchiveNameEncoding) -> FakeReader {
        FakeReader(entries: entries, format: format, url: url, isEncrypted: isEncrypted, failure: failure,
                   failureAfter: failureAfter, extractDelay: extractDelay, nameEncoding: nameEncoding,
                   legacyNameEncoding: legacyNameEncoding, volumeURLs: volumeURLs, comment: comment)
    }

    /// The prefix of the folders `extractToTemporaryFile` writes to, in the temporary directory.
    static let temporaryFolderPrefix = "FakeReader-"

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        if let failure, failureAfter == nil { throw failure }
        try await wait()
        var selected = entries
        if let paths {
            for path in paths where !entries.contains(where: { $0.path == path }) {
                throw ArchiveError.entryNotFound(path)
            }
            selected = entries.filter { entry in
                paths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
            }
        }
        for (index, entry) in selected.enumerated() {
            if let failure, let failureAfter, index >= failureAfter { throw failure }
            try write(entry, under: directory)
            progress?(Double(index + 1) / Double(selected.count), entry.path)
        }
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        if let failure { throw failure }
        try await wait()
        guard let entry = entries.first(where: { $0.path == path && !$0.isDirectory }) else {
            throw ArchiveError.entryNotFound(path)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.temporaryFolderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(entry.name)
        try Data(entry.path.utf8).write(to: file)
        return file
    }

    /// Waits `extractDelay`; cancelling the wait throws `.cancelled`.
    private func wait() async throws {
        guard extractDelay > .zero else { return }
        do {
            try await Task.sleep(for: extractDelay)
        } catch {
            throw ArchiveError.cancelled
        }
    }

    /// Removes every folder `extractToTemporaryFile` wrote.
    static func removeTemporaryFiles() {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
        let names = (try? fileManager.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix(temporaryFolderPrefix) {
            try? fileManager.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private func write(_ entry: ArchiveEntry, under directory: URL) throws {
        let target = directory.appendingPathComponent(entry.path)
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(entry.path.utf8).write(to: target)
        }
    }
}

extension FakeReader {
    /// A small archive: two top-level files and one folder.
    static func sample(url: URL = URL(fileURLWithPath: "/tmp/fake.zip"),
                       legacyNameEncoding: String.Encoding? = nil) -> FakeReader {
        FakeReader(entries: [
            ArchiveEntry(path: "README.md", isDirectory: false, size: 12, compressedSize: 10, modificationDate: nil),
            ArchiveEntry(path: "notes.txt", isDirectory: false, size: 5, compressedSize: 5, modificationDate: nil),
            ArchiveEntry(path: "src", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
            ArchiveEntry(path: "src/main.swift", isDirectory: false, size: 40, compressedSize: 30, modificationDate: nil),
        ], url: url, legacyNameEncoding: legacyNameEncoding)
    }

    var topLevelCount: Int { entries.filter { $0.parentPath.isEmpty }.count }
}
