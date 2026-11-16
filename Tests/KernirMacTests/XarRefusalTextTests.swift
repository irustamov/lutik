import Compression
import Foundation
import Testing
@testable import Kernir
import KernirCore

/// Kernir patch 0015 refuses, inside libarchive's xar reader, a TOC that nests more than 200 levels deep, holds a
/// pathname or link target over 65,536 bytes, or whose pathnames, link targets and hardlink copies pass 256 MiB.
/// KernirCore turns each refusal into the `ArchiveNestingError` its own limit for the same thing throws. These open
/// a crafted xar for each refusal and check the text the user sees.
@Suite("xar refusal text", .serialized)
struct XarRefusalTextTests {
    static let deep = "This archive nests folders too deeply."
    static let names = "This archive's file names are too long or too complex to open."

    enum Refusal: CaseIterable, CustomTestStringConvertible {
        case depth, name, link, total, hardlinks

        var testDescription: String { "\(self)" }

        var text: String {
            switch self {
            case .depth: XarRefusalTextTests.deep
            case .name, .link, .total, .hardlinks: XarRefusalTextTests.names
            }
        }

        func archive(in dir: URL) throws -> URL {
            var toc = TOC()
            switch self {
            case .depth:
                // 201 nested folders.
                for _ in 0..<201 { toc.open(3) }
                for _ in 0..<201 { toc.add("</file>") }
            case .name:
                toc.split(pre: "<file id=\"1\"><name>", length: 65_537, post: "</name>\(TOC.folder)</file>")
            case .link:
                toc.split(pre: "<file id=\"1\"><name>s</name><type>symlink</type><mode>0755</mode><link type=\"file\">",
                          length: 65_537, post: "</link></file>")
            case .total:
                // 256 MiB + 1 of stored pathnames: bare children of a 199-deep chain down to a 59,999-byte pathname.
                let limit = 256 << 20
                var total = 0, path = 0
                let chain = TOC.chain(59_999, 199)
                for n in chain {
                    path = path == 0 ? n : path + 1 + n
                    total += path
                    toc.open(n, TOC.bare)
                }
                var k = 0
                while limit - total >= path + 2 {
                    toc.add("<file id=\"\(toc.id())\"><name>\(String(k % 16, radix: 16))</name>\(TOC.bare)</file>")
                    k += 1
                    total += path + 2
                }
                for _ in chain { toc.add("</file>") }
                toc.open(limit + 1 - total, TOC.bare)
                toc.add("</file>")
            case .hardlinks:
                // 5,000 hardlinks to a 65,000-byte pathname: 325 MB of copies.
                let chain = TOC.chain(64_998, 199)
                for n in chain { toc.open(n, TOC.bare) }
                toc.add("<file id=\"9999999\"><name>o</name>\(TOC.hardlink("original"))</file>")
                for _ in chain { toc.add("</file>") }
                for i in 0..<5_000 {
                    toc.add("<file id=\"\(toc.id())\"><name>h\(i)</name>\(TOC.hardlink("9999999"))</file>")
                }
            }
            return try toc.write(to: dir.appendingPathComponent("\(self).xar"))
        }
    }

    /// An uncompressed xar TOC. libarchive inflates it 64 KiB at a time and expat splits text there; the reader keeps
    /// only a name's first piece, so `open` moves a name that would cross a boundary to the next chunk.
    struct TOC {
        static let chunk = 1 << 16
        static let folder = "<type>directory</type><mode>0755</mode>"
        static let bare = "<type>directory</type>"
        static func hardlink(_ link: String) -> String { "<type link=\"\(link)\">hardlink</type><mode>0644</mode>" }
        var bytes = Array(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xar><toc><creation-time>2024-01-01T00:00:00</creation-time>"
                .utf8)
        private var nextID = 0

        mutating func id() -> Int {
            nextID += 1
            return nextID
        }

        mutating func add(_ s: String) { bytes += Array(s.utf8) }

        /// `<file>` named `n` × "a", left open.
        mutating func open(_ n: Int, _ body: String = TOC.folder) {
            let pre = Array("<file id=\"\(id())\"><name>".utf8)
            let start = bytes.count + pre.count
            if n <= Self.chunk, start / Self.chunk != (start + n - 1) / Self.chunk {
                bytes += [UInt8](repeating: 0x20, count: Self.chunk - start % Self.chunk)
            }
            bytes += pre + [UInt8](repeating: 0x61, count: n) + Array("</name>\(body)".utf8)
        }

        /// One text of `length` bytes ("é", then "x"s) whose first byte ends the first chunk: expat holds the split
        /// character back and hands the whole text over in one piece with the next chunk.
        mutating func split(pre: String, length: Int, post: String) {
            bytes += [UInt8](repeating: 0x20, count: Self.chunk - 1 - pre.utf8.count - bytes.count)
            bytes += Array(pre.utf8) + Array("é".utf8) + [UInt8](repeating: 0x78, count: length - 2) + Array(post.utf8)
        }

        /// `d` name lengths whose chain of folders has a deepest pathname of exactly `length` bytes.
        static func chain(_ length: Int, _ d: Int) -> [Int] {
            let body = length - (d - 1)
            return (0..<d).map { body / d + ($0 < body % d ? 1 : 0) }
        }

        /// The xar: a 28-byte header (TOC checksum algorithm 0, none checked) and the zlib-coded TOC, no heap.
        func write(to url: URL) throws -> URL {
            let src = bytes + Array("</toc></xar>".utf8)
            let capacity = src.count + src.count / 8 + 4096
            var deflated = [UInt8](repeating: 0, count: capacity)
            let n = compression_encode_buffer(&deflated, capacity, src, src.count, nil, COMPRESSION_ZLIB)
            precondition(n > 0)
            // COMPRESSION_ZLIB is raw deflate: add the zlib header and the Adler-32 trailer.
            var a: UInt32 = 1, b: UInt32 = 0
            for byte in src {
                a = (a + UInt32(byte)) % 65_521
                b = (b + a) % 65_521
            }
            func be(_ v: UInt64, _ width: Int) -> [UInt8] {
                (0..<width).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
            }
            let body = [0x78, 0x9C] + deflated[0..<n] + be(UInt64((b << 16) | a), 4)
            let header = be(0x7861_7221, 4) + be(28, 2) + be(1, 2) + be(UInt64(body.count), 8)
                + be(UInt64(src.count), 8) + be(0, 4)
            try Data(header + body).write(to: url)
            return url
        }
    }

    @Test(arguments: Refusal.allCases)
    func refusalShowsItsText(_ refusal: Refusal) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XarRefusalText-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try refusal.archive(in: dir)
        do {
            _ = try await Archive.open(at: url)
            Issue.record("\(refusal) opened")
        } catch {
            #expect(error is ArchiveNestingError, "\(error)")
            #expect(error.localizedDescription == refusal.text)
            #expect((error as NSError).localizedFailureReason == refusal.text)
        }
    }
}
