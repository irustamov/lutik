import Testing
import Foundation
import CLibArchive

/// zstd must decode in-process: without libzstd, libarchive spawns `zstd -d -qq`, which iOS can't do and which
/// fails on any Mac without a `zstd` binary on PATH (Finder-launched apps, Quick Look, clean Macs).
@Test func zstdFilterIsBuiltIn() throws {
    let a = try #require(archive_read_new())
    defer { archive_read_free(a) }
    #expect(archive_read_support_filter_zstd(a) == ARCHIVE_OK, "\(String(cString: archive_error_string(a)))")
    #expect(String(cString: archive_version_details()).contains("libzstd/"))
}
