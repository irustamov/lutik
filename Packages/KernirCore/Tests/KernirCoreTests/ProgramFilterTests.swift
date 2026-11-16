import Testing
import Foundation
import CLibArchive
@testable import KernirCore

/// The reader registers only filters libarchive decodes in-process. `archive_read_support_filter_all` also registered
/// lrzip, grzip, lzop and (this build has no liblz4) lz4, which libarchive decodes by spawning `lrzip -d -q`,
/// `grzip -d`, `lzop -d` or `lz4 -d -q` from PATH: a crafted file with one of their magics started a process.
/// Serialized: one test points PATH at stubs while it opens those files.
@Suite(.serialized) struct ProgramFilterTests {
    /// Header bytes each program-only bidder claims (libarchive's bid checks), padded past their lookahead.
    static let programMagics: [(name: String, bytes: [UInt8])] = [
        ("lrzip", Array("LRZI".utf8) + [0, 6] + Array(repeating: 0, count: 40)),
        ("lzop", [0x89, 0x4C, 0x5A, 0x4F, 0x00, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 40)),
        ("grzip", [0x47, 0x52, 0x5A, 0x69, 0x70, 0x49, 0x49, 0x00, 0x02, 0x04, 0x3A, 0x29]
            + Array(repeating: 0, count: 40)),
        ("lz4", [0x04, 0x22, 0x4D, 0x18, 0x40, 0x40, 0x00] + Array(repeating: 0, count: 40)),
        ("lz4-legacy", [0x02, 0x21, 0x4C, 0x18] + Array(repeating: 0, count: 40)),
    ]

    /// Each file reaches the raw reader unfiltered (so Kernir refuses it as unsupported), and no program runs: stubs
    /// named after the programs sit first on PATH and record any call.
    @Test func programOnlyFilterMagicsOpenRawWithoutSpawning() async throws {
        let dir = Fixtures.tempDir()
        let stubs = dir.appendingPathComponent("stubs", isDirectory: true)
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("spawned.txt")
        for program in ["lrzip", "grzip", "lzop", "lz4"] {
            let stub = stubs.appendingPathComponent(program)
            // Reads its input (libarchive writes the file to it) and writes nothing back.
            try Data("#!/bin/sh\necho \"$0 $*\" >> '\(marker.path)'\ncat > /dev/null\nexit 0\n".utf8).write(to: stub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        // `.serialized` orders only this suite; PATH is process-wide. That is tolerated because every
        // Process() in the tests uses an absolute executableURL and the stubs shadow only
        // lrzip/grzip/lzop/lz4, which nothing else runs. setenv can still race with a concurrent
        // Process environment copy (accepted, test-only).
        setenv("PATH", stubs.path + ":" + oldPath, 1)
        defer { setenv("PATH", oldPath, 1) }

        for (name, bytes) in Self.programMagics {
            let url = dir.appendingPathComponent("crafted.\(name)")
            try Data(bytes).write(to: url)
            // Not #require: every file is tried, so the marker check below sees every spawn.
            guard let session = try? ReadSession(url: url, password: nil) else {
                Issue.record("\(name): the open failed"); continue
            }
            #expect((try? session.nextHeader()) != nil, "\(name): no header")
            #expect(session.formatCode & Int32(ARCHIVE_FORMAT_BASE_MASK) == Int32(ARCHIVE_FORMAT_RAW), "\(name)")
            #expect(session.filterCodes.isEmpty, "\(name): \(session.filterCodes)")
            await #expect(throws: ArchiveError.unsupportedFormat, "\(name)") {
                _ = try await LibArchiveReader.open(at: url, password: nil)
            }
        }
        let spawned = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        #expect(spawned.isEmpty, "spawned: \(spawned)")
    }

    /// Every filter the reader registers returns ARCHIVE_OK, which libarchive returns only when it decodes the
    /// filter in-process (each one warns when it would fall back to a program), so `configure` fails closed if a
    /// build loses a library. The excluded ones warn here: they would run a program.
    @Test func registeredFiltersAreInProcess() throws {
        for (name, register) in ReadSession.filterSteps {
            let a = try #require(archive_read_new())
            defer { archive_read_free(a) }
            #expect(register(a) == ARCHIVE_OK, "\(name)")
        }
        let programOnly: [(String, (OpaquePointer?) -> Int32)] = [
            ("lrzip", archive_read_support_filter_lrzip), ("grzip", archive_read_support_filter_grzip),
            ("lzop", archive_read_support_filter_lzop), ("lz4", archive_read_support_filter_lz4),
        ]
        for (name, register) in programOnly {
            let a = try #require(archive_read_new())
            defer { archive_read_free(a) }
            #expect(register(a) == ARCHIVE_WARN, "\(name)")
        }
    }

    /// The kept filters Kernir does not map by name still decode in-process: a cpio behind compress, lzma, lzip
    /// or uuencode (written by libarchive) lists as cpio.
    @Test func unmappedInProcessFiltersStillDecode() async throws {
        let filters: [(String, (OpaquePointer?) -> Int32)] = [
            ("Z", archive_write_add_filter_compress), ("lzma", archive_write_add_filter_lzma),
            ("lz", archive_write_add_filter_lzip), ("uu", archive_write_add_filter_uuencode),
        ]
        for (ext, add) in filters {
            let url = Fixtures.tempDir().appendingPathComponent("a.cpio.\(ext)")
            withUTF8CType {
                let a = archive_write_new()
                defer { archive_write_free(a) }
                #expect(archive_write_set_format_cpio_newc(a) == ARCHIVE_OK)
                #expect(add(a) == ARCHIVE_OK, "\(ext)")
                #expect(archive_write_open_filename(a, url.path) == ARCHIVE_OK)
                let e = archive_entry_new()
                defer { archive_entry_free(e) }
                archive_entry_copy_pathname(e, "hello.txt")
                archive_entry_set_filetype(e, UInt32(S_IFREG))
                archive_entry_set_perm(e, 0o644)
                archive_entry_set_size(e, 5)
                #expect(archive_write_header(a, e) == ARCHIVE_OK)
                #expect(archive_write_data(a, "hello", 5) == 5)
                #expect(archive_write_close(a) == ARCHIVE_OK)
            }
            let r = try await LibArchiveReader.open(at: url, password: nil)
            #expect(r.format == .cpio, "\(ext)")
            #expect(r.entries.map(\.path) == ["hello.txt"], "\(ext)")
        }
    }
}
