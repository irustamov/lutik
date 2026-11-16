import Testing
import Foundation
@testable import KernirCore

struct ReaderListingTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func fixture(_ rel: String) -> URL { repoRoot.appendingPathComponent("Fixtures/" + rel) }

    @Test func listsNestedZipAndSynthesizesDirectories() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a/b/c.txt": Data("hello".utf8), "top.txt": Data("x".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.zip", "--format", "zip", "a/b/c.txt", "top.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.zip"), password: nil)
        #expect(Set(r.entries.map(\.path)) == ["a", "a/b", "a/b/c.txt", "top.txt"])
        let a = try #require(r.entries.first { $0.path == "a" })
        #expect(a.isDirectory && a.size == nil && a.modificationDate == nil)
        let c = try #require(r.entries.first { $0.path == "a/b/c.txt" })
        #expect(c.size == 5 && c.permissions != nil)
        #expect(r.format == .zip && !r.isEncrypted)
        // Synthesized dirs precede their first descendant.
        let paths = r.entries.map(\.path)
        #expect(paths.firstIndex(of: "a")! < paths.firstIndex(of: "a/b")!)
        #expect(paths.firstIndex(of: "a/b")! < paths.firstIndex(of: "a/b/c.txt")!)
        #expect(r.headerOrdinalByPath["a"] == nil)
        #expect(r.headerOrdinalByPath["top.txt"] != nil)
    }

    @Test func ancestorSynthesisOrderIsUnchanged() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let paths = ["a/b/c.txt", "a/b/d.txt", "x/y.txt", "a/b/e.txt", "a/z.txt"]
        let url = SyntheticZip.write(SyntheticZip.stored(paths.map { (path: $0, dosTime: t, data: [1]) }))
        let r = try await LibArchiveReader.open(at: url, password: nil)
        #expect(r.entries.map(\.path) == ["a", "a/b", "a/b/c.txt", "a/b/d.txt", "x", "x/y.txt",
                                          "a/b/e.txt", "a/z.txt"])
    }

    @Test func ancestorSynthesisSplitsOnBytesNotCharacters() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        for (input, expected) in [(["top.txt", "r/\u{301}s"], ["top.txt", "r", "r/\u{301}s"]),
                                  (["q/a", "q/r/\u{301}s"], ["q", "q/a", "q/r", "q/r/\u{301}s"])] {
            let url = SyntheticZip.write(SyntheticZip.stored(input.map { (path: $0, dosTime: t, data: [1]) }))
            let r = try await LibArchiveReader.open(at: url, password: nil)
            #expect(r.entries.map { Array($0.path.unicodeScalars) } == expected.map { Array($0.unicodeScalars) })
        }
    }

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
    func listsEveryBsdtarFormat(_ c: Case) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["x/1.txt": Data("one".utf8), "2.bin": Data("two".utf8)], in: dir)
        // --no-mac-metadata: Apple bsdtar otherwise adds "._" companions for any xattr (even
        // com.apple.provenance), and tar lists those raw (tar:!mac-ext).
        try Fixtures.bsdtar(["--no-mac-metadata", "-cf", c.name] + c.args + ["x/1.txt", "2.bin"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent(c.name), password: nil)
        #expect(r.format == c.expected)
        let paths = Set(r.entries.map(\.path).map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 })
        #expect(paths.isSuperset(of: ["x/1.txt", "2.bin"]), "\(paths)")
        #expect(paths.subtracting(["x", "x/1.txt", "2.bin"]).isEmpty, "\(paths)")
    }

    @Test(arguments: ["pax", "zip"])
    func unicodeNamesRoundTrip(_ fmt: String) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["Привет/日本.txt": Data("a".utf8), "emoji 😀.md": Data("b".utf8)], in: dir)
        try Fixtures.bsdtar(["--no-mac-metadata", "-cf", "u.\(fmt)", "--format", fmt, "Привет/日本.txt", "emoji 😀.md"], cwd: dir,
                            env: ["LC_ALL": "en_US.UTF-8"])
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("u.\(fmt)"), password: nil)
        #expect(Set(r.entries.map(\.path)) == ["Привет", "Привет/日本.txt", "emoji 😀.md"])
    }

    @Test func cp866ZipWithoutUtf8Flag() async throws {
        let r = try await LibArchiveReader.open(at: Self.fixture("zip/cp866.zip"), password: nil)
        #expect(Set(r.entries.map(\.path)) == ["Документы", "Документы/отчёт.txt", "Привет.txt"])
    }

    @Test func duplicateTarEntriesLastWins() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("one".utf8), "b.txt": Data("bb".utf8)], in: dir)
        try Fixtures.bsdtar(["--no-mac-metadata", "-cf", "t.tar", "a.txt", "b.txt"], cwd: dir)
        Fixtures.makeFiles(["a.txt": Data("longer content".utf8)], in: dir)
        try Fixtures.bsdtar(["--no-mac-metadata", "-rf", "t.tar", "a.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        #expect(r.entries.map(\.path) == ["a.txt", "b.txt"])
        #expect(r.entries.first?.size == 14)
        #expect(r.headerOrdinalByPath["a.txt"] == 2)
    }

    @Test func singleStreamGzipIsOneEntry() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["notes.txt": Data(String(repeating: "hi ", count: 50).utf8)], in: dir)
        try Fixtures.run("/usr/bin/gzip", ["notes.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("notes.txt.gz"), password: nil)
        #expect(r.entries.map(\.path) == ["notes.txt"])
        #expect(r.format == .gzip)
        #expect(r.entries[0].size == nil)
    }

    @Test func emptyZipWithZeroEntriesOpens() async throws {
        let r = try await LibArchiveReader.open(at: Self.fixture("zip/empty.zip"), password: nil)
        #expect(r.format == .zip && r.entries.isEmpty)
    }

    @Test func rejectsNonArchives() async throws {
        let dir = Fixtures.tempDir()
        let blobs: [String: Data] = [
            "random.bin": Data((0..<4096).map { _ in UInt8.random(in: 0...255) }),
            "empty": Data(),
            "p.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 64)),
            "plain.txt": Data("just text, not an archive\n".utf8),
        ]
        for (name, data) in blobs {
            let u = dir.appendingPathComponent(name)
            try data.write(to: u)
            await #expect(throws: ArchiveError.unsupportedFormat, "\(name)") {
                _ = try await LibArchiveReader.open(at: u, password: nil)
            }
        }
    }

    @Test func truncatedZipThrowsCorrupted() async throws {
        let dir = Fixtures.tempDir()
        var files: [String: Data] = [:]
        for i in 0..<3 { files["f\(i).bin"] = Data((0..<50_000).map { _ in UInt8.random(in: 0...255) }) }
        let url = try Fixtures.archive("t.zip", bsdtarArgs: ["--format", "zip"], files: files)
        let full = try Data(contentsOf: url)
        let cut = dir.appendingPathComponent("cut.zip")
        try full.prefix(full.count / 2).write(to: cut)
        do {
            _ = try await LibArchiveReader.open(at: cut, password: nil)
            Issue.record("expected throw")
        } catch let e as ArchiveError {
            switch e {
            case .corrupted, .unsupportedFormat: break
            default: Issue.record("unexpected \(e)")
            }
        }
    }

    @Test func encryptedZipAes() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("secret".utf8), "d/b.txt": Data("more".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", "e.zip", "--format", "zip", "--options", "zip:encryption=aes256",
                             "--passphrase", "pw", "a.txt", "d/b.txt"], cwd: dir)
        try await checkEncrypted(dir.appendingPathComponent("e.zip"))
    }

    @Test func encryptedZipZipCrypto() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("secret".utf8), "d/b.txt": Data("more".utf8)], in: dir)
        try Fixtures.run("/usr/bin/zip", ["-q", "-P", "pw", "e.zip", "a.txt", "d/b.txt"], cwd: dir)
        try await checkEncrypted(dir.appendingPathComponent("e.zip"))
    }

    private func checkEncrypted(_ url: URL) async throws {
        let plain = try await LibArchiveReader.open(at: url, password: nil)
        #expect(plain.isEncrypted)
        #expect(plain.entries.filter { !$0.isDirectory }.allSatisfy { $0.isEncrypted })
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await LibArchiveReader.open(at: url, password: "nope")
        }
        let ok = try await LibArchiveReader.open(at: url, password: "pw")
        #expect(ok.isEncrypted)
    }

    @Test func missingFileThrowsIO() async {
        let u = Fixtures.tempDir().appendingPathComponent("nope.zip")
        do {
            _ = try await LibArchiveReader.open(at: u, password: nil)
            Issue.record("expected throw")
        } catch let e as ArchiveError {
            guard case .io = e else { Issue.record("unexpected \(e)"); return }
        } catch { Issue.record("\(error)") }
    }

    @Test func macExtensionEntriesAreListedRaw() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["d/a.txt": Data("x".utf8)], in: dir)
        try Fixtures.run("/usr/bin/xattr", ["-w", "com.kernir.t", "1", "d/a.txt"], cwd: dir)
        try Fixtures.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "d", "out.zip"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("out.zip"), password: nil)
        let paths = Set(r.entries.map(\.path))
        #expect(paths.contains("__MACOSX/d/._a.txt"), "\(paths)")
        #expect(paths.contains("d/a.txt"))
    }

    /// Nested `__MACOSX` folders are listed raw like the root one and classified as metadata (the archive window
    /// hides `isMacOSMetadata`), the folder entry, a folder only implied by its contents, and everything beneath.
    /// Look-alike names stay content.
    @Test func nestedMACOSXIsListedAsMetadata() async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let paths = ["a/", "a/__MACOSX/", "a/__MACOSX/x", "a/b/__MACOSX/._x", "f/__MACOSX", "__MACOSXfoo/y",
                     "c/foo__MACOSX/z", "c/__macosx/w", "keep.txt"]
        let zip = SyntheticZip.write(SyntheticZip.stored(paths.map {
            (path: $0, dosTime: t, data: $0.hasSuffix("/") ? [] : Array("data of \($0)".utf8))
        }))
        let r = try await Archive.open(at: zip)
        let metadata = Set(r.entries.filter(\.isMacOSMetadata).map(\.path))
        #expect(metadata == ["a/__MACOSX", "a/__MACOSX/x", "a/b/__MACOSX", "a/b/__MACOSX/._x", "f/__MACOSX"],
                "\(metadata.sorted())")
        let visible = Set(r.entries.filter { !$0.isMacOSMetadata }.map(\.path))
        #expect(visible == ["a", "a/b", "f", "__MACOSXfoo", "__MACOSXfoo/y", "c", "c/foo__MACOSX", "c/foo__MACOSX/z",
                            "c/__macosx", "c/__macosx/w", "keep.txt"], "\(visible.sorted())")
    }

    @Test func headerEncrypted7zNeedsPassword() async throws {
        await #expect(throws: ArchiveError.passwordRequired) {
            _ = try await LibArchiveReader.open(at: Self.fixture("7z/encrypted-headers.7z"), password: nil)
        }
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await LibArchiveReader.open(at: Self.fixture("7z/encrypted-headers.7z"), password: "pw")
        }
        let r = try await LibArchiveReader.open(at: Self.fixture("7z/encrypted-headers.7z"), password: "kernir")
        #expect(r.format == .sevenZip && r.isEncrypted && r.encryption == .aes256)
        #expect(r.entries.contains { $0.path == "docs/nested/deep/data.bin" && $0.isEncrypted })
    }

    @Test func dataEncrypted7zOpens() async throws {
        let r = try await LibArchiveReader.open(at: Self.fixture("7z/encrypted-data.7z"), password: nil)
        #expect(r.format == .sevenZip && r.isEncrypted)
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await LibArchiveReader.open(at: Self.fixture("7z/encrypted-data.7z"), password: "whatever")
        }
        let r2 = try await LibArchiveReader.open(at: Self.fixture("7z/encrypted-data.7z"), password: "kernir")
        #expect(r2.isEncrypted && r2.encryption == .aes256)
    }

    @Test func makeSessionDetectsChange() async throws {
        let url = try Fixtures.archive("t.tar", bsdtarArgs: [], files: ["a.txt": Data("x".utf8)])
        let r = try await LibArchiveReader.open(at: url, password: nil)
        _ = try r.makeSession()
        try Data("changed bytes".utf8).write(to: url)
        #expect(throws: ArchiveError.io("archive changed on disk")) { _ = try r.makeSession() }
    }

    @Test func replacedFileWithSameSizeAndMtimeIsDetected() async throws {
        let url = try Fixtures.archive("t.tar", bsdtarArgs: [], files: ["a.txt": Data("x".utf8)])
        let original = try Data(contentsOf: url)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        let r = try await LibArchiveReader.open(at: url, password: nil)
        _ = try r.makeSession()
        var other = original
        other[other.count - 1] ^= 0xFF
        let tmp = url.deletingLastPathComponent().appendingPathComponent("replacement")
        try other.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        #expect(throws: ArchiveError.io("archive changed on disk")) { _ = try r.makeSession() }
    }

    /// Catches quadratic work in listing and building the tree: 125,500 entries (100,000 files, 25,500 synthesized
    /// folders) cost about 10x what 12,550 entries of the same shape cost, and the bound is 30x. Both sizes are timed
    /// in this process, in alternating rounds, and the best of each is compared, so load from parallel suites stretches
    /// both alike and cannot fail the test the way an absolute bound did (11.6 s at load 56 against 7.3 s alone). The
    /// linear code measured 8.5-13x; quadratic synthesis (an Array instead of a Set for the synthesized folders)
    /// measured 88x. Milder growth passes: n log n gives about 12x and pure n^1.5 about 32x, and a quadratic term is
    /// caught only once it adds more than about 4.5 s at 125,500 entries; a uniform slowdown is not caught at all.
    @Test(.memoryHeavy) func hundredThousandEntriesStayLinear() async throws {
        let small = try Self.manyEntriesTar(files: 10_000)
        let large = try Self.manyEntriesTar(files: 100_000)
        let clock = ContinuousClock()
        func listAndTree(_ url: URL, expecting count: Int) async throws -> Duration {
            let start = clock.now
            let r = try await LibArchiveReader.open(at: url, password: nil)
            _ = Archive.tree(from: r.entries)
            let elapsed = clock.now - start
            #expect(r.entries.count == count)
            return elapsed
        }
        _ = try await listAndTree(small, expecting: 12_550)
        var bestSmall = Duration.seconds(3_600), bestLarge = Duration.seconds(3_600)
        // A burst of load can stretch one round; a regression is slow in every round. Retries stop after 2 minutes
        // (linear rounds take a few seconds even under load), so quadratic work fails within a round or two.
        let retriesEnd = clock.now + .seconds(120)
        for _ in 0..<4 {
            let s = try await listAndTree(small, expecting: 12_550)
            let l = try await listAndTree(large, expecting: 125_500)
            bestSmall = min(bestSmall, s)
            bestLarge = min(bestLarge, l)
            if bestLarge / bestSmall < 30 || clock.now > retriesEnd { break }
        }
        #expect(bestLarge / bestSmall < 30, "125,500 entries took \(bestLarge), 12,550 took \(bestSmall)")
    }

    /// A ustar archive of `files` empty files in `files / 200` folders of 50 subfolders each, written by hand (bsdtar
    /// reads paths from a file only for existing files). Consecutive files never share a folder, so every one
    /// takes the ancestor-synthesis path. 100,000 files list as 125,500 entries, 10,000 as 12,550.
    static func manyEntriesTar(files n: Int) throws -> URL {
        let folders = n / 200
        var tar = Data()
        tar.reserveCapacity(512 * n + 1024)
        func octal(_ v: Int, _ w: Int) -> [UInt8] { Array((String(v, radix: 8).leftPad(w - 1) + "\0").utf8) }
        for i in 0..<n {
            var h = [UInt8](repeating: 0, count: 512)
            let name = Array("d\(i % folders)/s\((i / folders) % 50)/f\(i).txt".utf8)
            h.replaceSubrange(0..<name.count, with: name)
            h.replaceSubrange(100..<108, with: octal(0o644, 8))
            h.replaceSubrange(108..<116, with: octal(0, 8))
            h.replaceSubrange(116..<124, with: octal(0, 8))
            h.replaceSubrange(124..<136, with: octal(0, 12))
            h.replaceSubrange(136..<148, with: octal(0, 12))
            h.replaceSubrange(148..<156, with: Array("        ".utf8))
            h[156] = UInt8(ascii: "0")
            h.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
            h.replaceSubrange(263..<265, with: Array("00".utf8))
            let sum = h.reduce(0) { $0 + Int($1) }
            h.replaceSubrange(148..<156, with: Array((String(sum, radix: 8).leftPad(6) + "\0 ").utf8))
            tar.append(contentsOf: h)
        }
        tar.append(Data(count: 1024))
        let url = Fixtures.tempDir().appendingPathComponent("many-\(n).tar")
        try tar.write(to: url)
        return url
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

@Suite(.serialized)
struct CLocaleListingTests {
    @Test func utf8NamesListInCLocale() async throws {
        let old = String(cString: setlocale(LC_CTYPE, nil))
        setlocale(LC_CTYPE, "C")
        defer { setlocale(LC_CTYPE, old) }
        let r = try await LibArchiveReader.open(
            at: ReaderListingTests.fixture("zip/unicode-utf8-flag.zip"), password: nil)
        #expect(Set(r.entries.map(\.path)) == ["café.txt", "emoji 🎉.txt", "spaces and (parens) [1].txt",
                                               "Привет мир.txt", "日本語", "日本語/ファイル.txt"])
    }
}
