import Testing
import Foundation
@testable import KernirCore

/// Single files extracted for Quick Look, drag-out and Open With must keep their own bytes when another entry's
/// name is the same file on the cache's volume: case-only twins (README, Readme) and Unicode normalization twins
/// on case- and normalization-insensitive APFS, or a file "a" next to a folder "A". An earlier
/// cache stored each file at root/<entry path>, so the second twin's rename replaced the first one's file, and
/// the first URL, still "existing", served the second twin's bytes; an Update from an opened copy then wrote
/// them into the first item.
struct ExtractCacheCollisionTests {
    static let readme = Data("README, upper case\n".utf8)
    static let mixedReadme = Data("Readme, mixed case, longer\n".utf8)

    /// The collisions only exist on a case-insensitive volume; on a case-sensitive one these tests would pass for
    /// the wrong reason, so they fail loudly instead.
    static func requireCaseInsensitiveCacheVolume(_ cache: TemporaryExtractionCache) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cache.root, withIntermediateDirectories: true)
        let sensitive = try cache.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        try #require(sensitive == false, "cache volume of \(cache.root.path) is case-sensitive: the collisions can't happen here")
    }

    static func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    @Test(arguments: ["zip/case-twins.zip", "tar/case-twins.tar"], [["README", "Readme"], ["Readme", "README"]])
    func caseTwinsKeepTheirOwnBytes(_ fixture: String, _ order: [String]) async throws {
        let r = try await LibArchiveReader.open(at: ReaderListingTests.fixture(fixture), password: nil)
        try Self.requireCaseInsensitiveCacheVolume(r.cache)
        let expected = ["README": Self.readme, "Readme": Self.mixedReadme]
        let first = try await r.extractToTemporaryFile(order[0])
        let second = try await r.extractToTemporaryFile(order[1])
        #expect(first.lastPathComponent == order[0])
        #expect(second.lastPathComponent == order[1])
        // Both stay valid after the second extraction: each one's bytes are its own entry's.
        #expect(try Self.bytes(first) == expected[order[0]])
        #expect(try Self.bytes(second) == expected[order[1]])
        #expect(first.path.lowercased() != second.path.lowercased())
        // A second request reuses each one's file, still with its own bytes.
        #expect(try await r.extractToTemporaryFile(order[0]) == first)
        #expect(try await r.extractToTemporaryFile(order[1]) == second)
        #expect(try Self.bytes(first) == expected[order[0]])
        #expect(try Self.bytes(second) == expected[order[1]])
    }

    /// A file "a" and a file "A/b": "A" is the same name as the file "a" on the volume.
    @Test(arguments: [["a", "A/b"], ["A/b", "a"]])
    func fileAndFolderTwinBothExtract(_ order: [String]) async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let zip = SyntheticZip.write(SyntheticZip.stored([
            (path: "a", dosTime: t, data: Array("file a".utf8)),
            (path: "A/b", dosTime: t, data: Array("file A/b".utf8)),
        ]))
        let r = try await LibArchiveReader.open(at: zip, password: nil)
        try Self.requireCaseInsensitiveCacheVolume(r.cache)
        let expected = ["a": Data("file a".utf8), "A/b": Data("file A/b".utf8)]
        let first = try await r.extractToTemporaryFile(order[0])
        let second = try await r.extractToTemporaryFile(order[1])
        #expect(first.lastPathComponent == String(order[0].split(separator: "/").last!))
        #expect(second.lastPathComponent == String(order[1].split(separator: "/").last!))
        #expect(try Self.bytes(first) == expected[order[0]])
        #expect(try Self.bytes(second) == expected[order[1]])
    }

    static let nfc = "caf\u{E9}.txt"
    static let nfd = "cafe\u{301}.txt"

    /// NFC and NFD spellings of one name: the reader keeps one entry for both (Swift `String` equality is
    /// canonical), so either spelling serves that entry's bytes, from one cached file, under the stored name.
    @Test func normalizationTwinsInOneArchiveServeTheListedEntry() async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let zip = SyntheticZip.write(SyntheticZip.stored([
            (nameBytes: Array(Self.nfc.utf8), utf8Flag: true, dosTime: t, data: Array("nfc bytes".utf8)),
            (nameBytes: Array(Self.nfd.utf8), utf8Flag: true, dosTime: t, data: Array("nfd bytes".utf8)),
        ]))
        let r = try await LibArchiveReader.open(at: zip, password: nil)
        try Self.requireCaseInsensitiveCacheVolume(r.cache)
        let files = r.entries.filter { !$0.isDirectory }
        try #require(files.count == 1)
        let viaNFC = try await r.extractToTemporaryFile(Self.nfc)
        let viaNFD = try await r.extractToTemporaryFile(Self.nfd)
        #expect(viaNFC == viaNFD)
        let listed = files[0].path
        // Canonically the listed name (a file URL's path may come back decomposed).
        #expect(viaNFC.lastPathComponent == listed)
        // The listed entry is the later header (last header wins).
        #expect(try Self.bytes(viaNFC) == Data("nfd bytes".utf8))
    }

    /// The cache layout itself: names that are one file on APFS (case-only or normalization-only twins, a file and a
    /// folder of the same folded name) each get a folder of their own and keep their exact leaf name. Written
    /// directly, since the reader merges normalization twins before they reach the cache.
    @Test func destinationsOfVolumeTwinsNeverShareAFile() throws {
        let cache = TemporaryExtractionCache()
        try Self.requireCaseInsensitiveCacheVolume(cache)
        let fm = FileManager.default
        let paths = ["README", "Readme", "readme", "dir/README", "DIR/Readme",
                     Self.nfc, Self.nfd, "CAF\u{C9}.txt", "A", "a", "A/b", "a/b/c"]
        var urls: [String: URL] = [:]
        for p in paths {
            // `String` keys merge NFC and NFD, so key by the exact scalars.
            let key = String(p.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-"))
            let url = cache.destination(for: p)
            #expect(url.lastPathComponent == String(p.split(separator: "/").last!))
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(key.utf8).write(to: url, options: .withoutOverwriting)
            urls[key] = url
            // Stable: asking again names the same place.
            #expect(cache.destination(for: p) == url)
        }
        for (key, url) in urls { #expect(try Self.bytes(url) == Data(key.utf8), "\(key) was overwritten") }
        // Components split on scalars, like EntryPath: a "/" before a combining mark still ends one.
        let marked = cache.destination(for: "d/\u{301}x")
        #expect(Array(marked.lastPathComponent.unicodeScalars) == ["\u{301}", "x"])
        urls["marked"] = marked
        // Each in a folder directly under the root, never the root itself or nested by the entry's own folders.
        for url in urls.values {
            #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                    == cache.root.standardizedFileURL.path)
        }
    }

    /// Review m1: the same leaf in different folders. The cache folder is named by the whole path, so `a/README`,
    /// `b/README` and `README` get three files, each with its own bytes, whatever order they are asked for in. A
    /// cache keyed by the leaf alone would hand one entry's bytes to Quick Look or Open With of another.
    @Test(arguments: [["a/README", "b/README", "README"], ["README", "b/README", "a/README"]])
    func sameLeafInDifferentFoldersKeepsItsOwnBytes(_ order: [String]) async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let zip = SyntheticZip.write(SyntheticZip.stored(order.map {
            (path: $0, dosTime: t, data: Array("bytes of \($0)".utf8))
        }))
        let r = try await LibArchiveReader.open(at: zip, password: nil)
        var urls: [String: URL] = [:]
        for path in order { urls[path] = try await r.extractToTemporaryFile(path) }
        #expect(Set(urls.values.map(\.standardizedFileURL.path)).count == order.count)
        for (path, url) in urls {
            #expect(url.lastPathComponent == "README")
            #expect(try Self.bytes(url) == Data("bytes of \(path)".utf8), "\(path)")
            // Asked again: the same file, still its own bytes.
            #expect(try await r.extractToTemporaryFile(path) == url)
        }
        for (path, url) in urls { #expect(try Self.bytes(url) == Data("bytes of \(path)".utf8), "\(path)") }
    }

    /// Review m2: `destination(for:)` takes a normalized entry path; one whose leaf is not a file name ("", "/",
    /// ".", "..", or a path ending in one) would name the hash folder or the root itself.
    @Test(arguments: ["", "/", "//", ".", "..", "a/.", "a/..", "a/b/..", "x\u{0}"])
    func pathsWithoutAFileNameAreRefused(_ path: String) {
        #expect(!TemporaryExtractionCache.hasFileName(path), "\(path.debugDescription)")
    }

    @Test(arguments: ["a", "README", "a/README", ".x", "..x", "a/...", "d/\u{301}x", "cafe\u{301}.txt", "a/b/c"])
    func pathsWithAFileNameAreTaken(_ path: String) {
        #expect(TemporaryExtractionCache.hasFileName(path), "\(path.debugDescription)")
    }

    /// The assertion itself fires (debug builds) for such a path.
    @Test(arguments: ["", "/", ".", ".."])
    func destinationAssertsOnAPathWithoutAFileName(_ path: String) async {
        await #expect(processExitsWith: .failure) { [path] in
            _ = TemporaryExtractionCache().destination(for: path)
        }
    }

    /// Review m3: when the cache folder cannot be made, the error names the entry, not the 64-hex hash folder.
    @Test func cacheFolderErrorNamesTheEntry() async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let zip = SyntheticZip.write(SyntheticZip.stored([(path: "docs/README", dosTime: t, data: Array("r".utf8))]))
        let r = try await LibArchiveReader.open(at: zip, password: nil)
        // A file where the entry's cache folder goes: createDirectory fails.
        let folder = r.cache.destination(for: "docs/README").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: r.cache.root, withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: folder)
        do {
            _ = try await r.extractToTemporaryFile("docs/README")
            Issue.record("no error")
        } catch let ArchiveError.io(detail) {
            #expect(detail.contains("docs/README"), "\(detail)")
            #expect(!detail.contains(folder.lastPathComponent), "\(detail)")
            #expect(detail == "Could not create a temporary folder for docs/README: File exists")
        }
    }
}
