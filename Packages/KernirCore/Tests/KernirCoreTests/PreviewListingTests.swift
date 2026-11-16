import Foundation
import Testing
@testable import KernirCore

@Suite("Archive.previewListing")
struct PreviewListingTests {
    private static let stamp = SyntheticZip.dosTime(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 6)

    private static func zip(_ items: [(String, Int)]) -> URL {
        SyntheticZip.write(SyntheticZip.stored(items.map {
            (path: $0.0, dosTime: stamp, data: [UInt8](repeating: 7, count: $0.1))
        }))
    }

    @Test(arguments: [0, 1, 3, 5000])
    func totalsMatchOpenOnEveryFixture(limit: Int) async throws {
        for fixture in Corpus.fixtures {
            guard let reader = try? await Archive.open(at: fixture.url) else { continue }
            let visible = reader.entries.filter { !$0.isMacOSMetadata }
            let p = try await Archive.previewListing(at: fixture.url, limit: limit)
            #expect(p.visibleEntryCount == visible.count, "\(fixture.file)")
            #expect(p.visibleFileSize == visible.filter { !$0.isDirectory }.reduce(0) { $0 + ($1.size ?? 0) },
                    "\(fixture.file)")
            #expect(p.format == reader.format, "\(fixture.file)")
            #expect(p.isEncrypted == reader.isEncrypted, "\(fixture.file)")
            #expect(p.entries.count <= max(limit, 0), "\(fixture.file)")
            var cursor = 0
            for e in p.entries {
                guard let i = visible[cursor...].firstIndex(where: { $0.path == e.path }) else {
                    Issue.record("\(fixture.file): \(e.path) missing or out of order")
                    continue
                }
                #expect(visible[i] == e, "\(fixture.file): \(e.path)")
                cursor = i + 1
            }
        }
    }

    @Test func missingFoldersAreCounted() async throws {
        let url = Self.zip([("a/b/c.txt", 3), ("a/d.txt", 4)])
        let p = try await Archive.previewListing(at: url, limit: 1)
        #expect(p.entries.map(\.path) == ["a/b/c.txt"])
        #expect(p.visibleEntryCount == 4)
        #expect(p.visibleFileSize == 7)
    }

    @Test func duplicatesBeyondTheLimit() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["f.txt": Data([1, 2]), "g.txt": Data([1, 2, 3])], in: dir)
        try Fixtures.bsdtar(["-cf", "a.tar", "f.txt", "g.txt"], cwd: dir)
        Fixtures.makeFiles(["f.txt": Data([1, 2, 3, 4, 5])], in: dir)
        try Fixtures.bsdtar(["-rf", "a.tar", "f.txt"], cwd: dir)
        let url = dir.appendingPathComponent("a.tar")
        let p = try await Archive.previewListing(at: url, limit: 1)
        #expect(p.entries.map(\.path) == ["f.txt"])
        #expect(p.entries[0].size == 5)
        #expect(p.visibleEntryCount == 2)
        #expect(p.visibleFileSize == 8)
        let r = try await Archive.open(at: url)
        let visible = r.entries.filter { !$0.isMacOSMetadata }
        #expect(visible.count == p.visibleEntryCount)
        #expect(visible.reduce(0) { $0 + ($1.size ?? 0) } == p.visibleFileSize)
    }

    @Test func metadataIsNotCounted() async throws {
        let url = Self.zip([("f.txt", 3), ("__MACOSX/._f.txt", 10)])
        let p = try await Archive.previewListing(at: url, limit: 5)
        #expect(p.entries.map(\.path) == ["f.txt"])
        #expect(p.visibleEntryCount == 1)
        #expect(p.visibleFileSize == 3)
    }

    /// A nested `__MACOSX` tree is metadata like the root one, its implied folder included; look-alikes count.
    @Test func nestedMACOSXIsNotCounted() async throws {
        let url = Self.zip([("a/__MACOSX/x", 5), ("a/b/__MACOSX/._x", 7), ("a/f.txt", 3), ("a/__MACOSXfoo", 2),
                            ("a/foo__MACOSX/y", 4)])
        let p = try await Archive.previewListing(at: url, limit: 10)
        #expect(p.entries.map(\.path) == ["a/f.txt", "a/__MACOSXfoo", "a/foo__MACOSX/y"])
        // a, a/b, a/f.txt, a/__MACOSXfoo, a/foo__MACOSX, a/foo__MACOSX/y
        #expect(p.visibleEntryCount == 6)
        #expect(p.visibleFileSize == 9)
        let r = try await Archive.open(at: url)
        #expect(r.entries.filter { !$0.isMacOSMetadata }.count == p.visibleEntryCount)
    }

    @Test func errorsMatchOpen() async throws {
        var passwords: [String?] = [nil, Corpus.password, Corpus.wrongPassword]
        passwords.append("")
        for fixture in Corpus.fixtures {
            for pw in passwords {
                let expected: ArchiveError?
                do { _ = try await Archive.open(at: fixture.url, password: pw); expected = nil }
                catch { expected = error as? ArchiveError }
                guard let expected else { continue }
                do {
                    _ = try await Archive.previewListing(at: fixture.url, password: pw, limit: 10)
                    Issue.record("\(fixture.file) (\(pw ?? "nil")): preview succeeded, open threw \(expected)")
                } catch {
                    #expect(error as? ArchiveError == expected, "\(fixture.file) (\(pw ?? "nil"))")
                }
            }
        }
        let junk = Fixtures.tempDir().appendingPathComponent("junk.bin")
        try Data([0x12, 0x34, 0x56, 0x78]).write(to: junk)
        await #expect(throws: ArchiveError.unsupportedFormat) {
            _ = try await Archive.previewListing(at: junk, limit: 10)
        }
    }

    @Test func cancelled() async throws {
        let url = Self.zip([("a.txt", 1)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Archive.previewListing(at: url, limit: 10)
        }
        await #expect(throws: ArchiveError.cancelled) { _ = try await task.value }
    }
}
