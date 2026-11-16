import Testing
import Foundation
import CLibArchive
@testable import KernirCore

/// Extract never applies setuid, setgid or sticky bits: only `mode & 0o777` reaches the disk, for files,
/// folders (including the deferred folder fix-up at close), links, and the temporary-file path.
struct ExtractSpecialBitsTests {
    enum Node { case file(UInt16), directory(UInt16), symlink(String, UInt16), hardlink(String) }

    /// A pax tar whose entries belong to this process's user and to `gid`, so libarchive's own
    /// owner checks would let setuid/setgid through.
    static func craftedTar(_ nodes: [(String, Node)], gid: gid_t) throws -> URL {
        let url = Fixtures.tempDir().appendingPathComponent("special.tar")
        let a = try #require(archive_write_new())
        defer { archive_write_free(a) }
        #expect(archive_write_set_format_pax_restricted(a) == ARCHIVE_OK)
        #expect(archive_write_open_filename(a, url.path) == ARCHIVE_OK)
        for (path, node) in nodes {
            let e = try #require(archive_entry_new())
            defer { archive_entry_free(e) }
            archive_entry_set_pathname(e, path)
            archive_entry_set_mtime(e, 981_158_400, 0)
            archive_entry_set_uid(e, Int64(getuid()))
            archive_entry_set_gid(e, Int64(gid))
            var data = Data()
            switch node {
            case .file(let perm):
                data = Data(path.utf8)
                archive_entry_set_filetype(e, UInt32(S_IFREG))
                archive_entry_set_perm(e, mode_t(perm))
                archive_entry_set_size(e, Int64(data.count))
            case .directory(let perm):
                archive_entry_set_filetype(e, UInt32(S_IFDIR))
                archive_entry_set_perm(e, mode_t(perm))
            case .symlink(let target, let perm):
                archive_entry_set_filetype(e, UInt32(S_IFLNK))
                archive_entry_set_perm(e, mode_t(perm))
                archive_entry_set_symlink(e, target)
            case .hardlink(let target):
                archive_entry_set_filetype(e, UInt32(S_IFREG))
                archive_entry_set_perm(e, 0o4755)
                archive_entry_set_hardlink(e, target)
                archive_entry_set_size(e, 0)
            }
            #expect(archive_write_header(a, e) == ARCHIVE_OK)
            if !data.isEmpty {
                _ = data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }
            }
        }
        #expect(archive_write_close(a) == ARCHIVE_OK)
        return url
    }

    static func mode(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode & 0o7777 : nil
    }

    /// A destination that exists already, so entries can carry its group (new items inherit it on macOS).
    static func destination() throws -> (URL, gid_t) {
        let out = Fixtures.tempDir().appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var st = stat()
        #expect(stat(out.path, &st) == 0)
        return (out, st.st_gid)
    }

    /// Lets the run root's atexit removal descend into read-only folders.
    static func makeWritable(_ paths: [String]) {
        for p in paths { _ = chmod(p, 0o755) }
    }

    static let nodes: [(String, Node)] = [
        ("suid", .file(0o4755)),
        ("sgidfile", .file(0o2755)),
        ("stickyfile", .file(0o1644)),
        ("plain", .file(0o750)),
        ("sgid", .directory(0o2755)),
        ("sgid/a.txt", .file(0o644)),
        ("sticky", .directory(0o1777)),
        ("sticky/a.txt", .file(0o644)),
        ("ro", .directory(0o555)),
        ("ro/b.txt", .file(0o644)),
        ("link", .symlink("plain", 0o4755)),
        ("hard", .hardlink("suid")),
    ]

    @Test func extractAppliesOnlyTheNinePermissionBits() async throws {
        let (out, gid) = try Self.destination()
        let r = try await LibArchiveReader.open(at: try Self.craftedTar(Self.nodes, gid: gid), password: nil)
        defer { Self.makeWritable([out.appendingPathComponent("ro").path]) }
        try await r.extract(nil, to: out, progress: nil)

        func m(_ p: String) -> mode_t? { Self.mode(out.appendingPathComponent(p).path) }
        #expect(m("suid") == 0o755)
        #expect(m("sgidfile") == 0o755)
        #expect(m("stickyfile") == 0o644)
        #expect(m("plain") == 0o750)
        #expect(m("sgid") == 0o755)
        #expect(m("sticky") == 0o777)
        #expect(m("ro") == 0o555)
        #expect(m("ro/b.txt") == 0o644)
        #expect(m("hard") == 0o755)
        let link = try #require(m("link"))
        #expect(link & 0o7000 == 0, "symlink mode \(String(link, radix: 8))")
    }

    @Test func selectedExtractAppliesOnlyTheNinePermissionBits() async throws {
        let (out, gid) = try Self.destination()
        let r = try await LibArchiveReader.open(at: try Self.craftedTar(Self.nodes, gid: gid), password: nil)
        // "hard" alone gets the data holder's header written at its own path.
        try await r.extract(["sgid", "sticky", "hard", "sgidfile", "stickyfile"], to: out, progress: nil)
        func m(_ p: String) -> mode_t? { Self.mode(out.appendingPathComponent(p).path) }
        #expect(m("sgid") == 0o755)
        #expect(m("sticky") == 0o777)
        #expect(m("hard") == 0o755)
        #expect(m("sgidfile") == 0o755)
        #expect(m("stickyfile") == 0o644)
        #expect(m("suid") == nil)
    }

    @Test func temporaryFileAppliesOnlyTheNinePermissionBits() async throws {
        let (_, gid) = try Self.destination()
        let r = try await LibArchiveReader.open(at: try Self.craftedTar(Self.nodes, gid: gid), password: nil)
        for p in ["suid", "sgidfile", "hard"] {
            let url = try await r.extractToTemporaryFile(p)
            #expect(Self.mode(url.path) == 0o755, "\(p)")
        }
        #expect(Self.mode(try await r.extractToTemporaryFile("stickyfile").path) == 0o644)
        #expect(Self.mode(try await r.extractToTemporaryFile("plain").path) == 0o750)
    }
}
