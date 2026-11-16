// Corpus-wide (manifest-driven) checks of `ArchiveWriteOptions.excludesMacMetadata`.
// Reuses the corpus helpers from FixtureTests.swift (Corpus, Fixture, checking) and the row
// set of DataSafetyTests' "Repack keeps data" suite (RepackTests.repackable). MacMetadataWriteTests pin
// the engine on hand-picked rows and synthetic archives; this file holds every writable corpus row to the
// Mac metadata rule, with the manifest (not the engine) as the oracle for paths and bytes.
//
// The rule: Mac metadata is `.DS_Store`, `._*` and `__MACOSX/` with its contents, at any depth. `Icon\r`
// and `.localized` are not metadata and are kept. With the flag on, a repack drops exactly the metadata and
// keeps every other entry byte-identical; with the flag off it keeps everything. A nested `__MACOSX` folder
// (`photos/__MACOSX/`) is metadata like the root one, with everything in it (corpus row
// zip/macos-nested-junk.zip). Strict: there is no known issue left here.

import Foundation
import Testing
@testable import KernirCore

/// The Mac metadata rule as an oracle independent of `MacOSMetadata`.
enum MacMetadataRuling {
    /// Names that look like Finder's but are kept: the custom-icon file and the localized-folder marker.
    static let keptNames: Set<Substring> = ["Icon\r", ".localized"]

    /// `.DS_Store`, `._*` or `__MACOSX` as any component of `path` (a folder goes with its contents).
    static func isMetadata(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".DS_Store" || $0.hasPrefix("._") || $0 == "__MACOSX" }
    }

    /// A `__MACOSX` folder below the root is (or contains) `path`.
    static func isNestedMACOSX(_ path: String) -> Bool {
        path.split(separator: "/").dropFirst().contains("__MACOSX")
    }

    static func metadata(of fixture: Fixture) -> Set<String> {
        Set(fixture.entries.map(\.path).filter(isMetadata))
    }

    static func keptLookalikes(of fixture: Fixture) -> [String] {
        fixture.entries.map(\.path).filter { $0.split(separator: "/").last.map(keptNames.contains) == true }
    }
}

// MARK: - Oracle (runs without the engine)

@Suite("Mac metadata oracle") struct MacMetadataOracleTests {
    /// The manifest's `macMetadata` key is exactly the rule applied to the row's entries: rows without the key
    /// hold no metadata, and `Icon\r` / `.localized` are never listed.
    @Test(arguments: Corpus.fixtures)
    func manifestMacMetadataMatchesTheRuling(_ fixture: Fixture) {
        let ruling = MacMetadataRuling.metadata(of: fixture)
        #expect(Set(fixture.macMetadata ?? []) == ruling,
                "manifest \((fixture.macMetadata ?? []).sorted()), ruling \(ruling.sorted())")
        #expect(fixture.macMetadata?.isEmpty != true, "an empty macMetadata list is no list: leave the key out")
        for path in MacMetadataRuling.keptLookalikes(of: fixture) {
            #expect(!ruling.contains(path), "\(path) is not metadata")
        }
    }

    @Test func rulingNameEdges() {
        for path in [".DS_Store", "a/.DS_Store", "._a", "a/b/._c", "__MACOSX", "__MACOSX/a/b", "x/__MACOSX",
                     "x/__MACOSX/y", "._dir/child"] {
            #expect(MacMetadataRuling.isMetadata(path), "\(path)")
        }
        for path in ["Icon\r", "a/.localized", ".ds_store", ".DS_Store.txt", "a._b", "__macosx/a", "__MACOSX_old/a",
                     "MACOSX/a", "_a"] {
            #expect(!MacMetadataRuling.isMetadata(path), "\(path)")
        }
        #expect(MacMetadataRuling.isNestedMACOSX("x/__MACOSX"))
        #expect(MacMetadataRuling.isNestedMACOSX("x/y/__MACOSX/._z"))
        #expect(!MacMetadataRuling.isNestedMACOSX("__MACOSX/x/y"))
        #expect(!MacMetadataRuling.isNestedMACOSX("x/__MACOSX.txt"))
    }
}

// MARK: - Repack through the engine

@Suite("Mac metadata repack across the corpus",
       .enabled("KernirCore reader not landed yet") { await Corpus.readerAvailable }, .timeLimit(.minutes(2)))
struct MacMetadataCorpusTests {
    /// Every corpus row a plain save can repack (DataSafetyTests' set: writable format, opens and extracts,
    /// no libarchive gap/bug, corrupt or traversal tag).
    static let rows = RepackTests.repackable
    /// The rows that hold metadata, by the rule.
    static let metadataRows = rows.filter { !MacMetadataRuling.metadata(of: $0).isEmpty }

    /// Options an app with the toggle passes for a save: explicit, carrying the source's method, encryption and
    /// password (nil options never strip). An encryption `format` cannot carry is left out (cross-format only).
    static func options(_ source: any ArchiveReading, _ fixture: Fixture, to format: ArchiveFormat,
                        excludes: Bool) -> ArchiveWriteOptions {
        let encryption = format.supportedEncryptions.contains(source.encryption) ? source.encryption : .none
        return ArchiveWriteOptions(method: source.compressionMethod, encryption: encryption,
                                   password: encryption == .none ? nil : fixture.password,
                                   excludesMacMetadata: excludes)
    }

    /// Repacks `fixture` to `format` and checks the result against the manifest: with `excludes`, every metadata
    /// path is gone (a nested `__MACOSX` included) and nothing else is; without, every path stays. Each kept
    /// file's bytes (one entry at a time, so case-fold twins cannot collide) equal the manifest's sha256; kept
    /// folders stay folders; `Icon\r` and `.localized` are kept. The output keeps the encryption and method the
    /// options carry from the source. A row whose manifest lists only some entries is checked against the
    /// source's own listing instead.
    static func check(_ fixture: Fixture, to format: ArchiveFormat, excludes: Bool) async throws {
        let source = try await Archive.open(at: fixture.url, password: fixture.password)
        let out = Fixtures.tempDir().appending(path: "out.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
        let options = Self.options(source, fixture, to: format, excludes: excludes)
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: out,
                                      options: options)
        let password = options.encryption == .none ? nil : fixture.password
        let result = try await Archive.open(at: out, password: password)
        let listed = Dictionary(result.entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        let headers = Set(try WriterRepackTests.rawHeaders(out, password: password).map(\.path))

        // Stripping never downgrades the save. The reader reports a method for zip only.
        #expect(result.encryption == options.encryption, "encryption \(result.encryption), asked \(options.encryption)")
        if format == .zip, let method = options.method, format.supportedMethods.contains(method) {
            #expect(result.compressionMethod == method, "method \(String(describing: result.compressionMethod)), asked \(method)")
        }

        let metadata = excludes ? MacMetadataRuling.metadata(of: fixture) : []
        for path in metadata.sorted() {
            #expect(listed[path] == nil, "\(path): metadata still listed")
            #expect(!headers.contains(path), "\(path): metadata still stored")
        }
        if excludes {
            let left = Set(listed.keys).union(headers).filter(MacMetadataRuling.isMetadata)
            #expect(left.isEmpty, "metadata left: \(left.sorted())")
        }

        let kept = fixture.entries.filter { !metadata.contains($0.path) }
        let got = Set(listed.keys)
        if fixture.entriesComplete {
            let want = Set(kept.map(\.path))
            #expect(got == want, "lost \(want.subtracting(got).sorted()), gained \(got.subtracting(want).sorted())")
        } else {
            // The manifest lists a sample, so the source's listing is the oracle for the path set. (A folder
            // the source only implies, holding nothing but metadata, would go too; no such row today.)
            let want = Set(source.entries.map(\.path)).filter { !excludes || !MacMetadataRuling.isMetadata($0) }
            #expect(got == want, "lost \(want.subtracting(got).sorted()), gained \(got.subtracting(want).sorted())")
            if !excludes, let count = fixture.entryCount {
                #expect(result.entries.count == count, "entry count")
            }
        }
        for path in MacMetadataRuling.keptLookalikes(of: fixture) {
            #expect(listed[path] != nil, "\(path.debugDescription) must be kept")
        }
        for entry in kept {
            #expect(listed[entry.path]?.isDirectory == entry.dir, "\(entry.path): missing or wrong kind")
            guard !entry.dir, entry.symlink == nil, let sha = entry.sha256, entry.corruptData != true else { continue }
            let file = try await result.extractToTemporaryFile(entry.path)
            #expect(Fixtures.sha256(file) == sha, "\(entry.path): bytes")
        }
    }

    static func format(of fixture: Fixture) throws -> ArchiveFormat {
        try #require(fixture.format.flatMap(ArchiveFormat.init(rawValue:)), "\(fixture.file) has no format")
    }

    @Test func corpusHasMetadataRows() {
        guard Corpus.manifest != nil else { return }
        #expect(!Self.metadataRows.isEmpty, "no repackable row holds Mac metadata")
        // A nested __MACOSX, with a file that is metadata only because of its folder.
        #expect(Self.metadataRows.contains { $0.entries.contains { entry in
            MacMetadataRuling.isNestedMACOSX(entry.path) && !entry.dir
                && entry.path.split(separator: "/").last.map { !$0.hasPrefix("._") && $0 != ".DS_Store" } == true
        } }, "no repackable row holds a nested __MACOSX/ (zip/macos-nested-junk.zip)")
        // A row whose manifest lists only some entries.
        #expect(Self.rows.contains { !$0.entriesComplete }, "no repackable row with entriesComplete false")
    }

    /// Flag on, same format, every repackable row: metadata rows lose exactly their metadata, the others lose
    /// nothing (no false positives), and every kept entry is byte-identical.
    @Test(arguments: rows)
    func repackWithFlagOnDropsExactlyTheMetadata(_ fixture: Fixture) async throws {
        let format = try Self.format(of: fixture)
        await checking(fixture) { try await Self.check(fixture, to: format, excludes: true) }
    }

    /// Flag on, converting each metadata row to every other writable format.
    @Test(arguments: metadataRows)
    func convertWithFlagOnDropsExactlyTheMetadata(_ fixture: Fixture) async throws {
        let source = try Self.format(of: fixture)
        for format in ArchiveFormat.writable where format != source {
            await checking(fixture) { try await Self.check(fixture, to: format, excludes: true) }
        }
    }

    /// Flag off (explicit false), light: metadata rows keep every entry, metadata included, with its bytes.
    /// repackWithFlagOffKeepsEveryEntry pins the same on its rows, and DataSafetyTests' identity repack
    /// covers nil options corpus-wide.
    @Test(arguments: metadataRows)
    func repackWithFlagOffKeepsEverything(_ fixture: Fixture) async throws {
        let format = try Self.format(of: fixture)
        await checking(fixture) { try await Self.check(fixture, to: format, excludes: false) }
    }
}
