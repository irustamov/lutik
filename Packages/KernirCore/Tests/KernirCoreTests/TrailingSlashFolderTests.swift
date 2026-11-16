import Foundation
import Testing
@testable import KernirCore

/// A header name ending in "/" lists as a folder even when its mode says regular file (cpio has no other folder
/// signal than the mode, and libarchive's cpio reader does not look at the name). The check is on the byte "/",
/// never on Characters: a Prepend scalar (U+0600) before the "/" makes `\u{600}/` one Character that is not "/",
/// so `hasSuffix("/")` missed it and the folder `d\u{600}` listed as an empty file.
struct TrailingSlashFolderTests {
    /// A cpio "newc" archive of regular files (mode 0100644) with these exact names and contents.
    static func newc(_ files: [(name: String, data: [UInt8])]) -> URL {
        var out: [UInt8] = []
        func pad() { while out.count % 4 != 0 { out.append(0) } }
        func member(_ name: String, _ data: [UInt8], ino: Int, mode: Int, nlink: Int) {
            let nameBytes = Array(name.utf8) + [0]
            let fields = [ino, mode, 0, 0, nlink, 0, data.count, 0, 0, 0, 0, nameBytes.count, 0]
            out += Array("070701".utf8)
            for f in fields { out += Array(String(format: "%08X", f).utf8) }
            out += nameBytes
            pad()
            out += data
            pad()
        }
        for (i, f) in files.enumerated() { member(f.name, f.data, ino: i + 1, mode: 0o100644, nlink: 1) }
        member("TRAILER!!!", [], ino: 0, mode: 0, nlink: 1)
        let url = Fixtures.tempDir().appendingPathComponent("t.cpio")
        try! Data(out).write(to: url)
        return url
    }

    @Test(arguments: ["d/", "d\u{600}/", "a/d\u{600}/", "\u{600}/"])
    func regularHeaderWithATrailingSlashIsAFolder(_ name: String) async throws {
        let r = try await LibArchiveReader.open(at: Self.newc([(name, []), ("e", Array("e".utf8))]), password: nil)
        let folder = String(String.UnicodeScalarView(name.unicodeScalars.dropLast()))
        let entry = r.entries.first { Array($0.path.unicodeScalars) == Array(folder.unicodeScalars) }
        #expect(entry?.isDirectory == true, "\(r.entries.map { ($0.path.debugDescription, $0.isDirectory) })")
        #expect(r.entries.first { $0.path == "e" }?.isDirectory == false)
    }

    /// Without a trailing "/" the mode decides: a regular file, also when its name ends in a Prepend scalar.
    @Test(arguments: ["d", "d\u{600}", "a/\u{600}"])
    func regularHeaderWithoutATrailingSlashIsAFile(_ name: String) async throws {
        let r = try await LibArchiveReader.open(at: Self.newc([(name, Array("x".utf8))]), password: nil)
        let entry = r.entries.first { Array($0.path.unicodeScalars) == Array(name.unicodeScalars) }
        #expect(entry?.isDirectory == false, "\(r.entries.map { ($0.path.debugDescription, $0.isDirectory) })")
        #expect(entry?.size == 1)
    }
}
