import Testing
import Foundation
import CLibArchive
@testable import KernirCore

/// The reader enables only the libarchive formats Kernir maps (plus empty and raw). Unmapped formats were refused
/// only after libarchive parsed their first header: mtree reads and parses its whole text manifest there (work out
/// of proportion to the file), and its entries name host paths rather than archive members.
struct FormatListTests {
    /// The first header's libarchive base format code, as `ReadSession` reads it.
    static func firstHeaderFormat(_ url: URL) throws -> Int32 {
        let session = try ReadSession(url: url, password: nil)
        _ = try #require(try session.nextHeader())
        return session.formatCode & Int32(ARCHIVE_FORMAT_BASE_MASK)
    }

    @Test func mtreeManifestIsNotParsedAsMtree() async throws {
        let dir = Fixtures.tempDir()
        let manifest = dir.appendingPathComponent("m.mtree")
        try Data("#mtree\n./a type=file size=5 contents=/etc/hosts\n./b type=dir\n".utf8).write(to: manifest)

        // Never the mtree reader: the text reaches the raw reader, which Kernir refuses unfiltered.
        let first = try Self.firstHeaderFormat(manifest)
        #expect(first != Int32(ARCHIVE_FORMAT_MTREE))
        #expect(first == Int32(ARCHIVE_FORMAT_RAW))
        await #expect(throws: ArchiveError.unsupportedFormat) {
            _ = try await LibArchiveReader.open(at: manifest, password: nil)
        }
    }

    @Test func unmappedArAndWarcAreNotParsed() async throws {
        let dir = Fixtures.tempDir()
        func pad(_ s: String, _ n: Int) -> String { s + String(repeating: " ", count: n - s.count) }
        let member = pad("a.txt/", 16) + pad("0", 12) + pad("0", 6) + pad("0", 6) + pad("100644", 8) + pad("5", 10)
            + "`\nhello\n"
        let warc = "WARC/1.0\r\nWARC-Type: resource\r\nWARC-Target-URI: file://a.txt\r\n"
            + "WARC-Date: 2024-01-01T00:00:00Z\r\nContent-Length: 5\r\n\r\nhello\r\n\r\n"
        for (name, text) in [("x.a", "!<arch>\n" + member), ("x.warc", warc)] {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            #expect(try Self.firstHeaderFormat(url) == Int32(ARCHIVE_FORMAT_RAW), "\(name)")
            await #expect(throws: ArchiveError.unsupportedFormat, "\(name)") {
                _ = try await LibArchiveReader.open(at: url, password: nil)
            }
        }
    }

    @Test func gzippedMtreeManifestOpensAsSingleCompressedFile() async throws {
        let dir = Fixtures.tempDir()
        let manifest = Data("#mtree\n./a type=file size=5 contents=/etc/hosts\n./b type=dir\n".utf8)
        let url = dir.appendingPathComponent("m.mtree.gz")
        try Data(try DamagedChecksumTests.gzip(manifest)).write(to: url)

        // Intended: the raw reader parses nothing, so a compressed unmapped format is just a gzip file with one entry.
        let r = try await LibArchiveReader.open(at: url, password: nil)
        #expect(r.format == .gzip)
        #expect(r.entries.count == 1)
    }

    /// An mtree manifest naming a host file (by `contents=` and by its own relative path, the lookups mtree's reader
    /// makes, with `checkfs` among them) never yields that file's bytes: the raw reader returns the manifest text.
    @Test func mtreeManifestNeverReadsTheHostFilesItNames() async throws {
        let dir = Fixtures.tempDir()
        let secret = "kernir-mtree-host-secret-\(UUID().uuidString)"
        let host = dir.appendingPathComponent("a")
        try Data(secret.utf8).write(to: host)
        let text = "#mtree\n./a type=file size=\(secret.utf8.count)\n"
            + "./b type=file size=\(secret.utf8.count) contents=\(host.path)\n"
        let manifest = dir.appendingPathComponent("m.mtree")
        try Data(text.utf8).write(to: manifest)

        let session = try ReadSession(url: manifest, password: nil)
        _ = try #require(try session.nextHeader())
        var bytes = [UInt8]()
        while let block = try session.readBlock() { bytes += block.buffer }
        #expect(bytes == Array(text.utf8))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(secret))

        // Compressed, it opens as one gzip entry: its bytes are the manifest text too.
        let gz = dir.appendingPathComponent("m.mtree.gz")
        try Data(try DamagedChecksumTests.gzip(Data(text.utf8))).write(to: gz)
        let r = try await LibArchiveReader.open(at: gz, password: nil)
        let entry = try #require(r.entries.first)
        let out = try await r.extractToTemporaryFile(entry.path)
        #expect(try Data(contentsOf: out) == Data(text.utf8))
    }

    /// A reader setup step that fails (here every one: libarchive refuses registrations and options on a handle that
    /// is no longer new) refuses the open instead of reading with formats or options missing.
    @Test func failedReaderSetupFailsClosed() throws {
        let a = try #require(archive_read_new())
        defer { archive_read_free(a) }
        #expect(archive_read_support_format_empty(a) == ARCHIVE_OK)
        #expect(archive_read_open_memory(a, nil, 0) == ARCHIVE_OK)
        #expect {
            try ReadSession.configure(a)
        } throws: { error in
            guard case ArchiveError.io = error else { return false }
            return true
        }
    }

    @Test func everyMappedFormatStillOpens() async throws {
        let cases: [(String, ArchiveFormat)] = [
            ("zip/one-file.zip", .zip), ("7z/copy.7z", .sevenZip),
            ("third-party/rar/rar4-basic.rar", .rar), ("third-party/rar/rar5-stored.rar", .rar),
            ("tar/basic.tar", .tar), ("tar/basic.tar.gz", .tarGzip), ("tar/basic.tar.bz2", .tarBzip2),
            ("tar/basic.tar.xz", .tarXz), ("tar/basic.tar.zst", .tarZstd),
            ("single/hello.txt.gz", .gzip), ("single/notes.txt.bz2", .bzip2), ("single/notes.txt.xz", .xz),
            ("single/notes.txt.zst", .zstd), ("iso/basic.iso", .iso), ("cpio/newc.cpio", .cpio),
            ("cpio/odc.cpio", .cpio), ("xar/basic.xar", .xar), ("third-party/lha/lh0.lzh", .lha),
            ("cab/none.cab", .cab),
        ]
        for (rel, format) in cases {
            let r = try await LibArchiveReader.open(at: ReaderListingTests.fixture(rel), password: nil)
            #expect(r.format == format, "\(rel)")
            #expect(!r.entries.isEmpty, "\(rel)")
        }
    }
}
