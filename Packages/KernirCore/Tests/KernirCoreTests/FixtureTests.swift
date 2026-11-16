// Manifest-driven tests over the fixture corpus (Fixtures/manifest.json, schema in docs/qa/fixtures.md).
// The corpus is found via #filePath, so Package.swift needs no resources.
//
// Engine tests are skipped until the reader lands (open() on a plain zip stops throwing .notImplemented).
// Fixtures tagged with a known gap (libarchive-bug) report mismatches as known issues. charset-heuristic is not
// a gap any more: the per-archive name encoding lists those fixtures, so a mismatch there is a failure.
// Set KERNIR_STRICT_FIXTURES=1 to make known-gap fixtures fail like everything else. libarchive-gap fixtures
// are strict: the manifest already encodes the expected unsupportedEncryption.

import CryptoKit
import Foundation
import Testing
@testable import KernirCore

// MARK: - Manifest model

struct FixtureManifest: Decodable {
    let version: Int
    let password: String
    let wrongPassword: String
    let fixtures: [Fixture]
}

struct Fixture: Decodable, Sendable, CustomTestStringConvertible {
    struct Entry: Decodable, Sendable {
        let path: String
        let dir: Bool
        /// nil when the manifest leaves size unasserted; .some(nil) when the engine must report nil.
        let size: Int64??
        let sha256: String?
        let symlink: String?
        let hardlink: String?
        let encrypted: Bool?
        let password: String?
        let corruptData: Bool?

        enum CodingKeys: String, CodingKey {
            case path, dir, size, sha256, symlink, hardlink, encrypted, password, corruptData
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            dir = try c.decode(Bool.self, forKey: .dir)
            size = c.contains(.size) ? .some(try c.decodeIfPresent(Int64.self, forKey: .size)) : nil
            sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
            symlink = try c.decodeIfPresent(String.self, forKey: .symlink)
            hardlink = try c.decodeIfPresent(String.self, forKey: .hardlink)
            encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted)
            password = try c.decodeIfPresent(String.self, forKey: .password)
            corruptData = try c.decodeIfPresent(Bool.self, forKey: .corruptData)
        }
    }

    let file: String
    let format: String?
    let detect: String?
    let open: String
    let password: String?
    let encrypted: Bool
    let extract: String
    let extractWithoutPassword: String?
    let openWithWrongPassword: String?
    let extractWithWrongPassword: String?
    let extractExpect: String?
    let mtime: Double?
    let entriesComplete: Bool
    let entryCount: Int?
    let entries: [Entry]
    let tags: [String]
    let fileSha256: String
    /// Other parts of a multi-volume set (the row's `file` is the part that is opened).
    let volumes: [String]?
    /// Decoded archive comment; nil when the archive has none.
    let comment: String?
    /// Entry path -> decoded entry comment.
    let entryComments: [String: String]?
    /// Entry paths that are macOS metadata.
    let macMetadata: [String]?

    var testDescription: String { file }
    var url: URL { Corpus.root.appending(path: file) }

    static let knownGapTags: Set = ["libarchive-bug"]
    /// COMMENT-READ-PENDING: `ArchiveReading.comment` was nil for every archive until the engine's read side landed.
    /// False now: the comment test holds every row strictly.
    static let commentReadPending = false
    var hasKnownGap: Bool {
        ProcessInfo.processInfo.environment["KERNIR_STRICT_FIXTURES"] != "1"
            && !Self.knownGapTags.isDisjoint(with: tags)
    }
    var fileEntries: [Entry] { entries.filter { !$0.dir && $0.sha256 != nil && $0.corruptData != true } }
    /// Expected result of open(password: self.password).
    var openWithPassword: String { open == "passwordRequired" ? "ok" : open }
}

enum Corpus {
    /// The repo root: the nearest ancestor of this file holding Fixtures/manifest.json.
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appending(path: "Fixtures/manifest.json").path) { return url }
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// Repo root/Fixtures, or $KERNIR_FIXTURES.
    static let root: URL = ProcessInfo.processInfo.environment["KERNIR_FIXTURES"].map(URL.init(fileURLWithPath:))
        ?? repoRoot.appending(path: "Fixtures")

    static let manifest: FixtureManifest? = try? JSONDecoder().decode(
        FixtureManifest.self, from: Data(contentsOf: root.appending(path: "manifest.json")))
    static var fixtures: [Fixture] { manifest?.fixtures ?? [] }
    static var password: String { manifest?.password ?? "" }
    static var wrongPassword: String { manifest?.wrongPassword ?? "" }

    /// True once the reader replaces the stub. Any other failure counts as available, so a broken
    /// reader fails the suite instead of skipping it.
    static var readerAvailable: Bool {
        get async {
            do { _ = try await Archive.open(at: root.appending(path: "zip/deflate.zip")) } catch ArchiveError.notImplemented {
                return false
            } catch {}
            return true
        }
    }
}

// MARK: - Helpers

enum Outcome: Equatable, CustomStringConvertible {
    case ok
    case failed(any Error)

    static func == (a: Outcome, b: Outcome) -> Bool { a.description == b.description }
    var description: String {
        switch self {
        case .ok: "ok"
        case .failed(let error): "\(error)"
        }
    }
}

func outcome(_ body: () async throws -> Void) async -> Outcome {
    do { try await body(); return .ok } catch { return .failed(error) }
}

/// Matches an outcome against a manifest result string ("ok", an ArchiveError case name, "error" or "any").
/// `format` (an ArchiveFormat raw value) also checks the unsupportedEncryption payload.
/// .notImplemented never matches, not even "any": once the reader exists, a stub path is a bug.
func matches(_ result: Outcome, _ expected: String, format: String? = nil) -> Bool {
    if case .failed(let error) = result, case ArchiveError.notImplemented? = error as? ArchiveError { return false }
    switch (expected, result) {
    case ("any", _): return true
    case ("ok", .ok): return true
    case (_, .ok): return false
    case (_, .failed(let error)):
        guard let error = error as? ArchiveError else { return false }
        switch (expected, error) {
        case ("error", _): return true
        case ("unsupportedEncryption", .unsupportedEncryption(let got)):
            return format.flatMap(ArchiveFormat.init(rawValue:)).map { $0 == got } ?? true
        case ("passwordRequired", .passwordRequired), ("wrongPassword", .wrongPassword),
             ("unsupportedFormat", .unsupportedFormat), ("corrupted", .corrupted),
             ("readOnlyFormat", .readOnlyFormat): return true
        default: return false
        }
    }
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// A temp sandbox: `destination` is root/l1/l2/dest, so "../.." escapes still land inside `root`, where they
/// are found by a recursive walk. Absolute targets the traversal fixtures use, and the folders just above `root` (its
/// parent under the run root, and the real temp folder) are snapshotted before extraction.
struct Sandbox {
    let root: URL
    let destination: URL
    private let probes: [String]
    private let probesBefore: [String: Date?]

    init() throws {
        root = Fixtures.tempDir()
        destination = root.appending(path: "l1/l2/dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Read only, never created: an escape one or two levels above `root` lands in one of these.
        let tmp = FileManager.default.temporaryDirectory.path
        let above = root.deletingLastPathComponent().path
        probes = ["/abs-evil.txt", "/tmp/pwned.txt", "/private/tmp/pwned.txt",
                  "\(tmp)/pwned.txt", "\(tmp)/evil.txt", "\(tmp)/evil2.txt",
                  "\(above)/pwned.txt", "\(above)/evil.txt", "\(above)/evil2.txt"]
        probesBefore = Dictionary(uniqueKeysWithValues: probes.map { ($0, Self.stamp($0)) })
    }

    private static func stamp(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Items outside `destination` that extraction created or changed. Removes new escapees as a side effect.
    func escapedItems() -> [String] {
        var escaped: [String] = []
        let base = root.standardizedFileURL.path
        if let walker = FileManager.default.enumerator(atPath: base) {
            while let rel = walker.nextObject() as? String {
                if rel == "l1/l2/dest" { walker.skipDescendants(); continue }
                if rel != "l1" && rel != "l1/l2" { escaped.append(rel) }
            }
        }
        for probe in probes where Self.stamp(probe) != probesBefore[probe]! {
            escaped.append(probe)
            if probesBefore[probe]! == nil { try? FileManager.default.removeItem(atPath: probe) }
        }
        return escaped
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Runs `body`, recording a thrown error as an issue; on a fixture with a known gap, issues become known issues.
func checking(_ fixture: Fixture, _ body: () async throws -> Void) async {
    if fixture.hasKnownGap {
        await withKnownIssue("known gap: \(fixture.tags.filter(Fixture.knownGapTags.contains))",
                             isIntermittent: true) { try await body() }
    } else {
        do { try await body() } catch { Issue.record(error) }
    }
}

// MARK: - Corpus integrity (runs without the engine)

@Suite("Fixture corpus") struct CorpusIntegrityTests {
    @Test func manifestLoads() throws {
        let manifest = try #require(Corpus.manifest, "cannot read \(Corpus.root.path)/manifest.json")
        #expect(manifest.version == 1)
        #expect(manifest.fixtures.count > 50)
    }

    @Test(arguments: Corpus.fixtures)
    func fileMatchesManifest(_ fixture: Fixture) throws {
        #expect(try sha256(of: fixture.url) == fixture.fileSha256, "regenerate Fixtures or the manifest")
        if let format = fixture.format {
            #expect(ArchiveFormat(rawValue: format) != nil, "unknown format \(format)")
        }
        // The comment tag marks exactly the rows with an archive or entry comment (docs/qa/fixtures.md).
        #expect(fixture.tags.contains("comment") == (fixture.comment != nil || fixture.entryComments != nil),
                "tag comment vs comment/entryComments keys")
        #expect(fixture.comment?.isEmpty != true, "an empty comment is no comment: leave the key out")
        let paths = Set(fixture.entries.map(\.path))
        for path in (fixture.entryComments.map { Array($0.keys) } ?? []) + (fixture.macMetadata ?? []) {
            #expect(paths.contains(path), "\(path) is not an entry of the row")
        }
    }
}

// MARK: - Engine tests

// Serialized: the $TMPDIR and absolute escape probes are shared, so a parallel test could report or delete
// another test's escapee.
@Suite("Fixtures through KernirCore", .enabled("KernirCore reader not landed yet") { await Corpus.readerAvailable },
       .serialized, .timeLimit(.minutes(1)))
struct FixtureTests {
    @Test(arguments: Corpus.fixtures)
    func detectFormat(_ fixture: Fixture) async {
        await checking(fixture) {
            #expect(Archive.detectFormat(at: fixture.url)?.rawValue == fixture.detect)
        }
    }

    @Test(arguments: Corpus.fixtures)
    func openWithoutPassword(_ fixture: Fixture) async throws {
        var reader: (any ArchiveReading)?
        let result = await outcome { reader = try await Archive.open(at: fixture.url) }
        await checking(fixture) {
            #expect(matches(result, fixture.open, format: fixture.format), "open: expected \(fixture.open), got \(result)")
            guard let reader, fixture.open == "ok" else { return }
            #expect(reader.isEncrypted == fixture.encrypted)
            if let format = fixture.format {
                #expect(reader.format.rawValue == format)
            }
            checkListing(reader.entries, fixture)
        }
    }

    @Test(arguments: Corpus.fixtures.filter { $0.openWithWrongPassword != nil })
    func openWithWrongPassword(_ fixture: Fixture) async {
        let expected = fixture.openWithWrongPassword!
        let result = await outcome { _ = try await Archive.open(at: fixture.url, password: Corpus.wrongPassword) }
        await checking(fixture) {
            #expect(matches(result, expected, format: fixture.format),
                    "open(wrong password): expected \(expected), got \(result)")
        }
    }

    @Test(arguments: Corpus.fixtures)
    func extractAll(_ fixture: Fixture) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var reader: (any ArchiveReading)?
        let opened = await outcome { reader = try await Archive.open(at: fixture.url, password: fixture.password) }
        let result: Outcome
        if let reader {
            result = await outcome { try await reader.extract(nil, to: sandbox.destination, progress: nil) }
        } else {
            result = opened
        }
        // Confinement holds for every fixture, known gap or not.
        let escaped = sandbox.escapedItems()  // once: the call removes escapees
        #expect(escaped.isEmpty, "extraction escaped the destination: \(escaped)")
        await checking(fixture) {
            if reader == nil {
                // Opening with the right password failed: only acceptable when the manifest says so.
                #expect(matches(opened, fixture.openWithPassword, format: fixture.format) && fixture.openWithPassword != "ok",
                        "open(password): expected \(fixture.openWithPassword), got \(opened)")
                // A failed open is the extraction's result too, so it must be the one the manifest expects.
                #expect(matches(opened, fixture.extract, format: fixture.format),
                        "extract: open failed with \(opened), expected \(fixture.extract)")
                return
            }
            #expect(matches(result, fixture.extract, format: fixture.format),
                    "extract: expected \(fixture.extract), got \(result)")
            guard result == .ok else { return }
            // Hostile fixtures may refuse or relocate hostile names; only the benign ok.txt is asserted.
            var wanted = fixture.extractExpect == "confined" ? fixture.entries.filter { $0.path == "ok.txt" } : fixture.entries
            // CASE-TWINS: engine stays later-wins by design (the app asks at its level, App/Shared CaseTwinScan);
            // permanent tolerance. Case-only twins (README, Readme) collide on a case-insensitive volume, so
            // their contents are checked only on a case-sensitive one; every other entry stays strict.
            let caseInsensitive = try sandbox.destination.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames == false
            let folded = Dictionary(grouping: wanted.map(\.path), by: { $0.lowercased() })
            // One skip set drives both the guards and the filter below.
            let skip: Set<String> = fixture.tags.contains("case-twins") && caseInsensitive
                ? Set(folded.values.filter { $0.count > 1 }.joined()) : []
            // The tolerance covers case-fold twins of a case-twins row only: such a row must have some, and each
            // skipped path needs a partner in the row spelled differently (not a duplicate of the same path).
            #expect(skip.isEmpty || fixture.tags.contains("case-twins"), "skip \(skip.sorted()) in a row not tagged case-twins")
            if fixture.tags.contains("case-twins") && caseInsensitive {
                #expect(!skip.isEmpty, "case-twins row without case-fold twins")
            }
            for path in skip.sorted() {
                #expect(wanted.contains { $0.path != path && $0.path.lowercased() == path.lowercased() },
                        "\(path) skipped without a case-fold partner")
            }
            let kept = wanted.filter { !skip.contains($0.path) }
            #expect(kept.count == wanted.count - skip.count, "skipped \(wanted.count - kept.count), skip set has \(skip.count)")
            wanted = kept
            for entry in wanted where !(fixture.password == nil && entry.encrypted == true) {
                try checkExtracted(entry, in: sandbox.destination, fixture: fixture)
            }
        }
    }

    @Test(arguments: Corpus.fixtures.filter { $0.extractWithoutPassword != nil })
    func extractWithoutPassword(_ fixture: Fixture) async throws {
        try await extractFailing(fixture, password: nil, expected: fixture.extractWithoutPassword!)
    }

    @Test(arguments: Corpus.fixtures.filter { $0.extractWithWrongPassword != nil })
    func extractWithWrongPassword(_ fixture: Fixture) async throws {
        try await extractFailing(fixture, password: Corpus.wrongPassword, expected: fixture.extractWithWrongPassword!)
    }

    /// Plain entries of a mixed-encryption archive extract without any password.
    @Test(arguments: Corpus.fixtures.filter { $0.tags.contains("mixed-encryption") })
    func plainEntriesOfMixedArchive(_ fixture: Fixture) async {
        await checking(fixture) {
            let reader = try await Archive.open(at: fixture.url)
            for entry in fixture.fileEntries where entry.encrypted == false {
                let url = try await reader.extractToTemporaryFile(entry.path)
                defer { try? FileManager.default.removeItem(at: url) }
                #expect(try sha256(of: url) == entry.sha256, "\(entry.path)")
            }
        }
    }

    @Test(arguments: Corpus.fixtures.filter { $0.open == "ok" && $0.extract == "ok" && !$0.fileEntries.isEmpty })
    func extractSingleToTemporaryFile(_ fixture: Fixture) async {
        await checking(fixture) {
            let reader = try await Archive.open(at: fixture.url, password: fixture.password)
            // The last file decodes the whole solid block in 7z/RAR; the first catches header handling.
            for entry in Set([fixture.fileEntries.first!.path, fixture.fileEntries.last!.path]).sorted() {
                let expected = fixture.fileEntries.first { $0.path == entry }!
                let url = try await reader.extractToTemporaryFile(entry)
                defer { try? FileManager.default.removeItem(at: url) }
                #expect(try sha256(of: url) == expected.sha256, "\(entry)")
            }
        }
    }

    @Test(arguments: Corpus.fixtures.filter { $0.entries.contains { $0.corruptData == true } })
    func corruptEntryFailsLoudly(_ fixture: Fixture) async {
        await checking(fixture) {
            let reader = try await Archive.open(at: fixture.url)
            for entry in fixture.entries where entry.corruptData == true {
                var url: URL?
                let result = await outcome { url = try await reader.extractToTemporaryFile(entry.path) }
                if let url { try? FileManager.default.removeItem(at: url) }
                #expect(matches(result, "corrupted"), "\(entry.path): expected corrupted, got \(result)")
            }
        }
    }

    /// Archive comments: a row with `comment` reports exactly that text (the oracle's decode: CP437 for
    /// non-UTF-8 bytes, a UTF-8 BOM stripped); every other row reports nil, the API's "no comment". Rows that
    /// open without a password are opened without one: a zip's end-of-central-directory comment is never
    /// encrypted. Entry comments (`entryComments`) are not asserted: `ArchiveEntry` exposes none.
    @Test(arguments: Corpus.fixtures.filter { $0.openWithPassword == "ok" })
    func archiveComment(_ fixture: Fixture) async {
        await checking(fixture) {
            let reader = try await Archive.open(at: fixture.url, password: fixture.open == "ok" ? nil : fixture.password)
            let got = reader.comment
            // COMMENT-DEFERRED: 0.1.0 reads ZIP comments only, a gzip FCOMMENT is out of scope (API.swift
            // `ArchiveReading.comment`), so nil is a known gap here. A comment it does report must still match.
            if fixture.tags.contains("comment-deferred") && got == nil { return }
            guard let want = fixture.comment else {
                #expect(got == nil, "expected no comment, got \(got.map { String($0.text.prefix(60)) } ?? "")")
                return
            }
            if Fixture.commentReadPending {
                // Only the nil read is the known issue; text and isWritable below stay strict. Non-intermittent:
                // once the reader reads the comment, "known issue was not recorded" fails until the flag flips.
                withKnownIssue("COMMENT-READ-PENDING: comment read side not in, ArchiveReading.comment is nil") {
                    _ = try #require(got, "no comment, expected \(want.count) characters")
                }
                guard got != nil else { return }
            }
            let comment = try #require(got, "no comment, expected \(want.count) characters")
            // Scalars, not String ==: an NFC/NFD or BOM difference is a real decode difference.
            let a = Array(comment.text.unicodeScalars), b = Array(want.unicodeScalars)
            let diff = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            #expect(a == b, "comment text: \(a.count) vs \(b.count) scalars, first difference at \(diff)")
            #expect(comment.isWritable == (reader.format.supportsComments && fixture.volumes == nil),
                    "isWritable")
        }
    }

    // MARK: Checks

    func checkListing(_ entries: [ArchiveEntry], _ fixture: Fixture) {
        let listed = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        #expect(listed.count == entries.count, "duplicate paths in listing")
        for entry in entries {
            #expect(!entry.path.hasPrefix("/") && !entry.path.hasSuffix("/") && !entry.path.isEmpty,
                    "unnormalized path \(entry.path.debugDescription)")
            #expect(!entry.path.split(separator: "/", omittingEmptySubsequences: false)
                        .contains { $0 == ".." || $0 == "." || $0.isEmpty },
                    "unnormalized path \(entry.path.debugDescription)")
            // ==, Set and Dictionary are canonical-equivalence aware; compare scalars to catch NFD output.
            #expect(Array(entry.path.unicodeScalars) == Array(entry.path.precomposedStringWithCanonicalMapping.unicodeScalars),
                    "path is not NFC: \(entry.path.debugDescription)")
            // In traversal fixtures a "parent" can be a symlink (escape -> ../..); it only has to exist.
            if !entry.parentPath.isEmpty {
                let parent = listed[entry.parentPath]
                #expect(parent != nil, "parent of \(entry.path) not synthesized")
                if !fixture.tags.contains("traversal") {
                    #expect(parent?.isDirectory == true, "parent of \(entry.path) is not a directory")
                }
            }
        }
        if let count = fixture.entryCount {
            #expect(entries.count == count, "entry count")
        }
        if fixture.entriesComplete {
            // String == is canonical-equivalence aware, so NFD names from libarchive match NFC expectations.
            let expected = Set(fixture.entries.map(\.path))
            let got = Set(entries.map(\.path))
            #expect(got == expected, "missing \(expected.subtracting(got).sorted()), extra \(got.subtracting(expected).sorted())")
        }
        for want in fixture.entries {
            guard let got = listed[want.path] else {
                Issue.record("missing entry \(want.path)")
                continue
            }
            #expect(got.isDirectory == want.dir, "\(want.path) isDirectory")
            if want.dir {
                #expect(got.size == nil, "\(want.path): directory size must be nil")
                if fixture.tags.contains("synthesized-dirs") {
                    #expect(got.modificationDate == nil, "\(want.path): synthesized directory date must be nil")
                }
            } else if let size = want.size, want.symlink == nil {
                #expect(got.size == size, "\(want.path) size")
            }
            if let encrypted = want.encrypted {
                #expect(got.isEncrypted == encrypted, "\(want.path) isEncrypted")
            }
            if let mtime = fixture.mtime, let date = got.modificationDate {
                #expect(abs(date.timeIntervalSince1970 - mtime) < 1, "\(want.path) mtime")
            }
        }
    }

    func checkExtracted(_ entry: Fixture.Entry, in destination: URL, fixture: Fixture) throws {
        let url = destination.appending(path: entry.path)
        if let target = entry.symlink {
            let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            #expect(actual == target, "\(entry.path) symlink target")
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            Issue.record("\(entry.path) not extracted")
            return
        }
        #expect(isDir.boolValue == entry.dir, "\(entry.path) kind on disk")
        if let sha = entry.sha256, entry.corruptData != true {
            #expect(try sha256(of: url) == sha, "\(entry.path) content")
        }
    }

    func extractFailing(_ fixture: Fixture, password: String?, expected: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let result = await outcome {
            let reader = try await Archive.open(at: fixture.url, password: password)
            try await reader.extract(nil, to: sandbox.destination, progress: nil)
        }
        await checking(fixture) {
            #expect(matches(result, expected, format: fixture.format), "expected \(expected), got \(result)")
        }
        let escaped = sandbox.escapedItems()
        #expect(escaped.isEmpty, "extraction escaped the destination: \(escaped)")
    }
}

// MARK: - Big fixtures (scripts/fixtures/make.sh, optional)

enum BigCorpus {
    /// $KERNIR_BIG_FIXTURES, or repo root/build/fixtures-big.
    static let root = ProcessInfo.processInfo.environment["KERNIR_BIG_FIXTURES"].map(URL.init(fileURLWithPath:))
        ?? Corpus.repoRoot.appending(path: "build/fixtures-big")
    static let fixtures: [Fixture] = (try? JSONDecoder().decode(
        FixtureManifestLite.self, from: Data(contentsOf: root.appending(path: "manifest.json"))))?.fixtures ?? []

    struct FixtureManifestLite: Decodable { let fixtures: [Fixture] }
}

@Suite("Big fixtures", .enabled("run scripts/fixtures/make.sh and land the reader first") {
           if BigCorpus.fixtures.isEmpty { return false }
           return await Corpus.readerAvailable
       },
       .timeLimit(.minutes(10)))
struct BigFixtureTests {
    @Test(arguments: BigCorpus.fixtures)
    func listsAndExtractsSamples(_ fixture: Fixture) async throws {
        let url = BigCorpus.root.appending(path: fixture.file)
        let reader = try await Archive.open(at: url)
        if let count = fixture.entryCount {
            #expect(reader.entries.count == count)
        }
        for entry in fixture.fileEntries.prefix(3) {
            if let size = entry.size {
                #expect(reader.entries.first { $0.path == entry.path }?.size == size)
            }
            let file = try await reader.extractToTemporaryFile(entry.path)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(try sha256(of: file) == entry.sha256)
        }
    }
}
