import Foundation
import KernirCore

/// In-memory `ArchiveReading` for tests. Extraction writes each file's path as its
/// UTF-8 contents, so tests can tell which entry produced which file. Paths match by Unicode
/// scalars, like KernirCore's `EntryPath.isSelected`: NFC and NFD spellings are different paths.
struct FakeReader: ArchiveReading {
    let url: URL
    let format: ArchiveFormat
    let entries: [ArchiveEntry]
    let isEncrypted: Bool
    let encryption: ArchiveEncryption
    let compressionMethod: ArchiveCompressionMethod?
    let nameEncoding: ArchiveNameEncoding
    let legacyNameEncoding: String.Encoding?
    /// Every part of a multi-volume set; a single file by default.
    var volumeURLs: [URL]
    /// The archive-level comment (`ArchiveReading.comment`); none by default.
    var comment: ArchiveComment?

    init(entries: [ArchiveEntry], format: ArchiveFormat = .zip,
         url: URL = URL(fileURLWithPath: "/tmp/fake.zip"), isEncrypted: Bool = false,
         encryption: ArchiveEncryption? = nil, compressionMethod: ArchiveCompressionMethod? = nil,
         nameEncoding: ArchiveNameEncoding = .automatic, legacyNameEncoding: String.Encoding? = nil,
         volumeURLs: [URL]? = nil, comment: ArchiveComment? = nil) {
        self.entries = entries
        self.format = format
        self.url = url
        self.isEncrypted = isEncrypted
        self.encryption = encryption ?? (isEncrypted ? .aes256 : .none)
        self.compressionMethod = compressionMethod
        self.nameEncoding = nameEncoding
        self.legacyNameEncoding = legacyNameEncoding
        self.volumeURLs = volumeURLs ?? [url]
        self.comment = comment
    }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        var selected = entries
        if let paths {
            for path in paths where !entries.contains(where: { Self.isSame($0.path, path) }) {
                throw ArchiveError.entryNotFound(path)
            }
            selected = entries.filter { entry in
                paths.contains { Self.isSame(entry.path, $0) || Self.isInside(entry.path, $0) }
            }
        }
        for (index, entry) in selected.enumerated() {
            try write(entry, under: directory)
            progress?(Double(index + 1) / Double(selected.count), entry.path)
        }
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        guard let entry = entries.first(where: { Self.isSame($0.path, path) && !$0.isDirectory }) else {
            throw ArchiveError.entryNotFound(path)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(entry.name)
        try Data(entry.path.utf8).write(to: file)
        return file
    }

    /// Scalar equality: String's `==` treats NFC and NFD spellings as equal.
    private static func isSame(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// True when `path` is inside the folder `directory`, comparing scalars.
    private static func isInside(_ path: String, _ directory: String) -> Bool {
        let p = Array(path.unicodeScalars), d = Array(directory.unicodeScalars)
        return p.count > d.count && p.starts(with: d) && p[d.count] == "/"
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
