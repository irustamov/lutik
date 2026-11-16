import Foundation
import Testing
import KernirCore

struct FakeArchive: ArchiveReading {
    var url = URL(fileURLWithPath: "/tmp/none-such.bin")
    var format: ArchiveFormat = .zip
    var entries: [ArchiveEntry]
    var isEncrypted = false
    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {}
    func extractToTemporaryFile(_ path: String) async throws -> URL { url }
}

private func file(_ path: String, _ size: Int64 = 10) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: nil, modificationDate: nil)
}
private func dir(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
}
/// The corpus, located relative to this file (Tests/QuickLookTests -> repo root).
private func fixture(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
}
private let missing = URL(fileURLWithPath: "/tmp/kernir-ql-missing.zip")

struct PreviewContentTests {
    @Test func sampleListing() {
        let l = PreviewLoader.listing(for: SampleArchive())
        #expect(l.format == .zip)
        #expect(l.totalCount == 7)
        let expectedSize: Int64 = 4_096 + 2_048 + 1_200_000 + 340_000 + 1_024
        #expect(l.totalSize == expectedSize)
        #expect(l.hiddenCount == 0)
        #expect(l.nodes.map(\.entry.name) == ["assets", "src", "brief.pdf", "README.md"])
    }

    @Test func capHidesRest() {
        let entries = (0..<6_000).map { file("f\($0).txt") }
        let l = PreviewLoader.listing(for: FakeArchive(entries: entries), limit: 5_000)
        #expect(l.nodes.count == 5_000)
        #expect(l.hiddenCount == 1_000)
        #expect(l.totalCount == 6_000)
        #expect(l.totalSize == 60_000)
    }

    @Test func unknownFileSizeMakesTotalUnknown() {
        let unknown = ArchiveEntry(path: "b.txt", isDirectory: false, size: nil, compressedSize: nil, modificationDate: nil)
        let l = PreviewLoader.listing(for: FakeArchive(entries: [file("a.txt"), unknown, dir("d")]))
        #expect(l.totalSize == nil)
    }

    @Test func folderWithAnUnknownFileSizeHasNoSize() {
        let unknown = ArchiveEntry(path: "d/b.txt", isDirectory: false, size: nil, compressedSize: nil, modificationDate: nil)
        let l = PreviewLoader.listing(for: FakeArchive(entries: [dir("d"), file("d/a.txt"), unknown]))
        #expect(l.nodes.map(\.totalSize) == [nil])  // the row prints "—", not the known part (10 bytes)
    }

    @Test func cappedKeepsAncestorsOfShownEntries() {
        let entries = [file("a/b/c.txt"), dir("a"), dir("a/b")]
        let capped = PreviewLoader.cappedEntries(entries, limit: 1)
        #expect(Set(capped.map(\.path)) == ["a", "a/b", "a/b/c.txt"])
        let l = PreviewLoader.listing(for: FakeArchive(entries: entries), limit: 1)
        #expect(l.nodes[0].children![0].children![0].entry.path == "a/b/c.txt")
        #expect(l.hiddenCount == 0)
    }

    @Test func emptyArchiveIsEmptyListing() async throws {
        let c = try await PreviewLoader.load(missing, list: { _, _ in PreviewLoader.listing(for: FakeArchive(entries: [])) })
        guard case .listing(let l) = c else { Issue.record("expected listing"); return }
        #expect(l.isEmpty)
        #expect(l.nodes == [])
    }

    @Test func passwordErrorsMapToProtected() async throws {
        let a = try await PreviewLoader.load(missing, list: { _, _ in throw ArchiveError.passwordRequired })
        #expect(a == .passwordProtected(nil))
        let b = try await PreviewLoader.load(missing, list: { _, _ in throw ArchiveError.unsupportedEncryption(.sevenZip) })
        #expect(b == .passwordProtected(.sevenZip))
        let c = try await PreviewLoader.load(missing, list: { _, _ in throw ArchiveError.wrongPassword })
        guard case .passwordProtected = c else { Issue.record("expected protected"); return }
    }

    /// Limits a preview hits for archives too big to list in its memory budget: the "too large" placeholder.
    @Test(arguments: [ArchiveNestingError.Limit.entryCount, .totalPathBytes, .folderBytes, .ancestorWork])
    func previewBudgetLimitsMapToTooLarge(limit: ArchiveNestingError.Limit) async throws {
        let c = try await PreviewLoader.load(missing, list: { _, _ in throw ArchiveNestingError(limit: limit) })
        #expect(c == .tooLarge)
    }

    /// A single odd path fails in Kernir too, so "open it in Kernir" would mislead: these keep the generic preview.
    @Test(arguments: [ArchiveNestingError.Limit.depth, .pathLength, .combiningMarks])
    func perPathLimitsAreRethrown(limit: ArchiveNestingError.Limit) async {
        await #expect(throws: ArchiveNestingError(limit: limit)) {
            try await PreviewLoader.load(missing, list: { _, _ in throw ArchiveNestingError(limit: limit) })
        }
    }

    @Test func notImplementedIsRethrown() async {
        await #expect(throws: ArchiveError.notImplemented) {
            try await PreviewLoader.load(missing, list: { _, _ in throw ArchiveError.notImplemented })
        }
    }

    @Test func corruptedErrorIsRethrown() async {
        await #expect(throws: ArchiveError.corrupted("x")) {
            try await PreviewLoader.load(missing, list: { _, _ in throw ArchiveError.corrupted("x") })
        }
        await #expect(throws: ArchiveError.unsupportedFormat) {
            try await PreviewLoader.load(missing, list: { _, _ in throw ArchiveError.unsupportedFormat })
        }
    }

    @Test func hidesMacOSMetadata() {
        let entries = [
            dir("__MACOSX"),
            file("__MACOSX/._a.txt", 4_096),
            file("a.txt", 10),
            dir("dir"),
            file("dir/._b", 4_096),
            file("dir/b", 20),
        ]
        let l = PreviewLoader.listing(for: FakeArchive(entries: entries))
        #expect(l.nodes.map(\.entry.name) == ["dir", "a.txt"])
        #expect(l.nodes[0].children?.map(\.entry.name) == ["b"])
        #expect(l.totalCount == 3)
        #expect(l.totalSize == 30)
        #expect(l.hiddenCount == 0)
    }

    @Test func capCountsOnlyVisibleEntries() {
        let metadata = (0..<2_000).map { file("._x\($0)", 4_096) }
        let visible = (0..<5_000).map { file("f\($0).txt") }
        let l = PreviewLoader.listing(for: FakeArchive(entries: metadata + visible), limit: 5_000)
        #expect(l.nodes.count == 5_000)
        #expect(l.hiddenCount == 0)
        #expect(l.totalCount == 5_000)
    }

    @Test func tree5000IsFast() {
        let entries = (0..<5_000).map { file("d\($0 % 100)/f\($0).txt") }
        let archive = FakeArchive(entries: entries)
        let t = ContinuousClock().measure { _ = PreviewLoader.listing(for: archive) }
        #expect(t < .milliseconds(500), "took \(t)")
    }

    private func listing(_ relativePath: String) async throws -> PreviewListing {
        guard case .listing(let l) = try await PreviewLoader.load(fixture(relativePath)) else {
            Issue.record("expected a listing for \(relativePath)")
            throw ArchiveError.unsupportedFormat
        }
        return l
    }

    @Test func realZipListing() async throws {
        let l = try await listing("zip/store.zip")
        #expect(l.format == .zip)
        #expect(l.totalCount == 9)
        let expectedSize: Int64 = 70_000 + 20_000 + 52 + 0 + 15
        #expect(l.totalSize == expectedSize)
        #expect(l.hiddenCount == 0)
        #expect(l.nodes.map(\.entry.name).sorted() == ["docs", "empty-dir", "empty.txt", "hello.txt"])
    }

    // The default loader lists through Archive.previewListing; totals must match the open()-based listing at
    // every cap, and the whole listing must match when nothing is capped.
    @Test(arguments: ["zip/store.zip", "zip/macos-finder.zip", "tar/macos-bsdtar.tar", "zip/mixed-encryption.zip"])
    func previewListingMatchesOpen(_ name: String) async throws {
        let opened = try await Archive.open(at: fixture(name))
        for limit in [0, 1, 2, PreviewLoader.entryLimit] {
            let preview = PreviewLoader.listing(from: try await Archive.previewListing(at: fixture(name), limit: limit))
            let reference = PreviewLoader.listing(for: opened, limit: limit)
            #expect(preview.format == reference.format, "\(name) limit \(limit)")
            #expect(preview.totalCount == reference.totalCount, "\(name) limit \(limit)")
            #expect(preview.totalSize == reference.totalSize, "\(name) limit \(limit)")
            #expect(preview.hiddenCount >= 0, "\(name) limit \(limit)")
            if limit == PreviewLoader.entryLimit { #expect(preview == reference, "\(name)") }
        }
    }

    // Single-stream archives don't record their one entry's size: the header total is unknown (not 0) and the
    // row has no size, so the preview prints "—".
    @Test(arguments: ["single/hello.txt.gz", "single/no-name.gz", "single/notes.txt.bz2", "single/notes.txt.xz",
                      "single/notes.txt.zst"])
    func singleStreamSizeIsUnknown(_ name: String) async throws {
        let l = try await listing(name)
        #expect(l.totalCount == 1, "\(name)")
        #expect(l.totalSize == nil, "\(name)")
        #expect(l.nodes.map(\.totalSize) == [nil], "\(name)")
    }

    @Test func encryptedHeaders7zIsProtected() async throws {
        let c = try await PreviewLoader.load(fixture("7z/encrypted-headers.7z"))
        #expect(c == .passwordProtected(.sevenZip))
    }

    @Test func aesHeaders7zWithPasswordIsProtected() async throws {
        let c = try await PreviewLoader.load(fixture("7z/aes-he-pw.7z"))
        #expect(c == .passwordProtected(.sevenZip))
    }

    // Since the 7z AES-256 read, `Archive.open` checks a 7z password at open;
    // the preview only walks headers, so plain-header 7z with encrypted data must still list.
    // Counts and sizes are entryCount and the summed entry sizes in Fixtures/manifest.json.
    @Test(arguments: [("7z/encrypted-data.7z", 9, Int64(90_067)), ("7z/aes-pw.7z", 9, 90_067), ("7z/aes-solid.7z", 15, 76_066)])
    func encryptedData7zStillLists(_ name: String, _ count: Int, _ size: Int64) async throws {
        let l = try await listing(name)
        #expect(l.format == .sevenZip, "\(name)")
        #expect(l.totalCount == count, "\(name)")
        #expect(l.totalSize == size, "\(name)")
    }

    @Test func encryptedHeadersRarIsProtected() async throws {
        let c = try await PreviewLoader.load(fixture("third-party/rar/rar5-encrypted-headers.rar"))
        #expect(c == .passwordProtected(.rar))
    }

    @Test func encryptedZipEntriesStillList() async throws {
        // Exact counts are the entryCount values in Fixtures/manifest.json (no __MACOSX/._ entries here).
        for (name, count) in [("zip/zipcrypto-store.zip", 9), ("zip/mixed-encryption.zip", 10)] {
            let l = try await listing(name)
            #expect(l.format == .zip, "\(name)")
            #expect(l.totalCount == count, "\(name)")
        }
    }

    // Real corrupt files through the real default opener (no mock).
    @Test(arguments: ["corrupt/random.zip", "corrupt/text.zip", "corrupt/zero-bytes.zip"])
    func garbageZipThrows(_ name: String) async {
        await #expect(throws: (any Error).self, "\(name)") {
            _ = try await PreviewLoader.load(fixture(name))
        }
    }

    @Test func truncated7zIsNotMislabelledPasswordProtected() async {
        // Manifest says open: "any": it may throw or list, but must never read as password-protected.
        let c = try? await PreviewLoader.load(fixture("corrupt/truncated.7z"))
        if case .passwordProtected = c { Issue.record("truncated.7z reported as password-protected") }
    }

    // Split archives: a missing or unreadable part gives the placeholder, never a partial listing.
    @Test func volumePartPlaceholder() async throws {
        let c = try await PreviewLoader.load(fixture("multivolume/missing/s7.7z.001"))
        #expect(c == .volumePart(openedPart: 1))
    }

    /// A part the sandbox won't let Quick Look read gives the same placeholder.
    @Test func unreadablePartGivesThePlaceholder() async throws {
        let error = ArchiveVolumeError(reason: .noAccess, part: 4, fileName: "s7.7z.004", setName: "s7.7z.001",
                                       folder: URL(fileURLWithPath: "/tmp"), openedPart: 3)
        let c = try await PreviewLoader.load(missing, list: { _, _ in throw error })
        #expect(c == .volumePart(openedPart: 3))
    }

    @Test func spannedZipAtItsLastPartIsPart0() async throws {
        let c = try await PreviewLoader.load(fixture("multivolume/missing/span.zip"))
        #expect(c == .volumePart(openedPart: 0))
    }

    @Test func completeVolumeSetListsEverything() async throws {
        let l = try await listing("multivolume/s7.7z.001")
        // Fixtures/multivolume/EXPECTED.json, set "s7": data, data/alpha.bin, data/beta.bin, gamma.bin.
        #expect(l.totalCount == 4)
        // Whole, not capped: every entry is in the tree.
        #expect(l.hiddenCount == 0)
        #expect(l.nodes.map(\.entry.name).sorted() == ["data", "gamma.bin"])
        let data = try #require(l.nodes.first { $0.entry.name == "data" })
        #expect(data.children?.map(\.entry.name).sorted() == ["alpha.bin", "beta.bin"])
        #expect(l.totalSize == Int64(26_000 + 20_000 + 14_000))
    }

    @Test func finderZipHidesMacOSMetadata() async throws {
        let l = try await listing("zip/macos-finder.zip")
        #expect(l.nodes.map(\.entry.name) == ["Project"])
        #expect(l.totalCount == 4)  // Project, docs, readme.md, hello.txt
        #expect(l.totalSize == Int64(7 + 15))
    }

    @Test func bsdtarHidesAppleDoubleFiles() async throws {
        let l = try await listing("tar/macos-bsdtar.tar")
        #expect(l.format == .tar)
        #expect(l.nodes.map(\.entry.name).sorted() == ["docs", "hello.txt", "plain.txt"])
        #expect(l.totalCount == 4)  // docs, docs/readme.md, hello.txt, plain.txt
        #expect(l.totalSize == Int64(7 + 15 + 6))
    }
}
