import Testing
import Foundation
import CLibArchive
@testable import KernirCore

struct DetectFormatTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let args: [String]
        let expected: ArchiveFormat
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "t.zip", args: ["--format", "zip"], expected: .zip),
        Case(name: "t.7z", args: ["--format", "7zip"], expected: .sevenZip),
        Case(name: "t.tar", args: ["--format", "pax"], expected: .tar),
        Case(name: "t.tar.gz", args: ["--format", "pax", "-z"], expected: .tarGzip),
        Case(name: "t.tar.bz2", args: ["--format", "pax", "-j"], expected: .tarBzip2),
        Case(name: "t.tar.xz", args: ["--format", "pax", "-J"], expected: .tarXz),
        Case(name: "t.cpio", args: ["--format", "cpio"], expected: .cpio),
        Case(name: "t.xar", args: ["--format", "xar"], expected: .xar),
        Case(name: "t.iso", args: ["--format", "iso9660"], expected: .iso),
    ]

    @Test(arguments: cases)
    func detectsBsdtarFormats(_ c: Case) throws {
        let url = try Fixtures.archive(c.name, bsdtarArgs: c.args,
                                       files: ["a.txt": Data("hello".utf8), "d/b.txt": Data("world".utf8)])
        #expect(LibArchiveReader.detectFormat(at: url) == c.expected)
    }

    private func single(tool: String, args: [String], expected: ArchiveFormat) throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data(String(repeating: "hello ", count: 100).utf8)], in: dir)
        try Fixtures.run(tool, args + ["a.txt"], cwd: dir)
        let out = dir.appendingPathComponent("a.txt." + (tool.hasSuffix("xz") ? "xz" : tool.hasSuffix("gzip") ? "gz" : "bz2"))
        #expect(LibArchiveReader.detectFormat(at: out) == expected)
    }

    @Test func detectsGzip() throws { try single(tool: "/usr/bin/gzip", args: ["-k"], expected: .gzip) }
    @Test func detectsBzip2() throws { try single(tool: "/usr/bin/bzip2", args: ["-k"], expected: .bzip2) }
    @Test func detectsXz() throws {
        let xz = "/opt/homebrew/bin/xz"
        try #require(FileManager.default.isExecutableFile(atPath: xz))
        try single(tool: xz, args: ["-k"], expected: .xz)
    }

    @Test func unknownDataIsNil() throws {
        let dir = Fixtures.tempDir()
        let random = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 56))
        Fixtures.makeFiles(["r.bin": random, "e.bin": Data(), "p.bin": png], in: dir)
        for n in ["r.bin", "e.bin", "p.bin"] {
            #expect(LibArchiveReader.detectFormat(at: dir.appendingPathComponent(n)) == nil, "\(n)")
        }
    }

    @Test func missingFileIsNil() {
        #expect(LibArchiveReader.detectFormat(at: URL(fileURLWithPath: "/nonexistent/x.zip")) == nil)
    }

    @Test func encryptionErrorMapping() {
        #expect(encryptionError(format: .sevenZip, hasPassphrase: true) == ArchiveError.wrongPassword)
        #expect(encryptionError(format: .sevenZip, hasPassphrase: false) == ArchiveError.passwordRequired)
        #expect(encryptionError(format: .rar, hasPassphrase: false) == ArchiveError.unsupportedEncryption(.rar))
        #expect(encryptionError(format: .zip, hasPassphrase: false) == ArchiveError.passwordRequired)
        #expect(encryptionError(format: .zip, hasPassphrase: true) == ArchiveError.wrongPassword)
    }

    @Test func sessionOpensAndIterates() throws {
        let url = try Fixtures.archive("s.zip", bsdtarArgs: ["--format", "zip"], files: ["a.txt": Data("hello".utf8)])
        let s = try ReadSession(url: url, password: nil)
        let e = try s.nextHeader()
        #expect(e != nil)
        var total = 0
        while let b = try s.readBlock() { total += b.buffer.count }
        #expect(total == 5)
        #expect(try s.nextHeader() == nil)
        #expect(s.formatCode & 0xff0000 == 0x50000)
    }

    @Test func macExtEntriesListedRaw() throws {
        let url = try Fixtures.archive("m.zip", bsdtarArgs: ["--format", "zip", "--no-mac-metadata"],
                                       files: ["a.txt": Data("x".utf8), "__MACOSX/._a.txt": Data("meta".utf8)])
        let s = try ReadSession(url: url, password: nil)
        var names: [String] = []
        while let e = try s.nextHeader() {
            names.append(archive_entry_pathname(e).map { String(cString: $0) } ?? "")
        }
        #expect(names.contains("__MACOSX/._a.txt"))
    }

    @Test func damagedSevenZipHeaderStillDetected() throws {
        let url = try Fixtures.archive("d.7z", bsdtarArgs: ["--format", "7zip"],
                                       files: ["a.txt": Data(String(repeating: "hello ", count: 50).utf8)])
        var bytes = try Data(contentsOf: url)
        for i in 32..<bytes.count { bytes[i] = 0 }
        try bytes.write(to: url)
        #expect(LibArchiveReader.detectFormat(at: url) == .sevenZip)
    }

    @Test func emptyPasswordMeansNoPassword() throws {
        let url = try Fixtures.archive("e.zip", bsdtarArgs: ["--format", "zip"], files: ["a.txt": Data("x".utf8)])
        #expect(try ReadSession(url: url, password: "").hasPassphrase == false)
        #expect(try ReadSession(url: url, password: "pw").hasPassphrase == true)
    }
}
