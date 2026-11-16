// Data-safety tests for ArchiveWriter: a save may fail, but it must never lose or damage the user's data.
// Reuses the corpus helpers from FixtureTests.swift
// (Corpus, Fixture, sha256(of:), outcome, matches, checking).
//
// Spec anti-goal: a failed repack must never destroy the original. The writer builds the new archive in a
// temp file on the destination's volume (FileManager's itemReplacementDirectory) and replaces the
// original atomically. Each test says which data-loss risk it guards.
//
// Interop checks with zipinfo, bsdtar, 7-Zip, unzip and hdiutil run on macOS only. A missing tool skips its
// check, unless KERNIR_REQUIRE_INTEROP=1 (CI), which turns it into a failure.

import CLibArchive
import CryptoKit
import Foundation
import Testing
@testable import KernirCore

// MARK: - Helpers

/// A temp directory under the run root (`Fixtures.tempDir()`); `remove()` deletes it.
private struct Scratch {
    let url: URL

    init() throws {
        url = Fixtures.tempDir()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func subdirectory(_ name: String) throws -> URL {
        let dir = url.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeFile(_ path: String, contents: Data, in dir: URL? = nil) throws -> URL {
        let file = (dir ?? url).appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file)
        return file
    }

    /// Copies a fixture into `dir` (default: the scratch root), keeping its file name.
    func copy(_ fixture: Fixture, into dir: URL? = nil) throws -> URL {
        let copy = (dir ?? url).appending(path: fixture.url.lastPathComponent)
        try FileManager.default.copyItem(at: fixture.url, to: copy)
        return copy
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Names in `dir`, sorted; Finder's .DS_Store is ignored.
private func items(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }.sorted()
}

/// Regular files anywhere under `dir` (relative paths, sorted), except inside the top-level `skipping`
/// names. Folders don't count: the system may leave empty ones behind (.TemporaryItems/folders.<uid>).
private func files(under dir: URL, skipping skipped: Set<String> = []) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: dir.path) else { return [] }
    var found: [String] = []
    while let path = walker.nextObject() as? String {
        if skipped.contains(String(path.split(separator: "/").first ?? "")) { continue }
        if walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular { found.append(path) }
    }
    return found.sorted()
}

/// The ArchiveError a failed outcome carries; nil for .ok or a foreign error.
private func archiveError(_ result: Outcome) -> ArchiveError? {
    if case .failed(let error) = result { return error as? ArchiveError }
    return nil
}

/// True for a thrown ArchiveError.io: the only right answer when the file system refuses a save.
private func isIOError(_ result: Outcome) -> Bool {
    if case .io(_)? = archiveError(result) { return true }
    return false
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func fixtureNamed(_ file: String) throws -> Fixture {
    try #require(Corpus.fixtures.first { $0.file == file }, "\(file) is not in the manifest")
}

private func archiveFormat(of fixture: Fixture) throws -> ArchiveFormat {
    try #require(fixture.format.flatMap(ArchiveFormat.init(rawValue:)), "\(fixture.file) has no format")
}

/// Writes `megabytes` MiB of incompressible bytes: one random MiB repeated. Deflate's 32 KiB window
/// cannot see the repeats, so the archive grows by the full size.
private func makeBigFile(at url: URL, megabytes: Int) throws {
    let words = (0..<(1 << 17)).map { _ in UInt64.random(in: .min ... .max) }
    let block = words.withUnsafeBytes { Data($0) }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    for _ in 0..<megabytes { try handle.write(contentsOf: block) }
}

/// Thread-safe cell for state set from a progress handler (called on a background thread).
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLock { try body(&stored) }
    }
}

/// True when `path` is one of `removed` or inside one of them.
private func isRemoved(_ path: String, by removed: Set<String>) -> Bool {
    removed.contains { path == $0 || path.hasPrefix($0 + "/") }
}

/// What an archive must contain after a save.
private struct Expected {
    /// Path -> sha256 of the extracted bytes.
    var files: [String: String] = [:]
    var dirs: Set<String> = []
    /// Path -> symlink target.
    var symlinks: [String: String] = [:]
    var absent: Set<String> = []
    /// The source row is tagged case-twins: only then may `verify` skip case-fold twins' contents.
    var caseTwins = false

    /// Every manifest entry of `fixture` except `removed` paths and their contents, which must be gone.
    init(_ fixture: Fixture, removing removed: Set<String> = []) {
        caseTwins = fixture.tags.contains("case-twins")
        for entry in fixture.entries {
            if isRemoved(entry.path, by: removed) {
                absent.insert(entry.path)
            } else if entry.dir {
                dirs.insert(entry.path)
            } else if let target = entry.symlink {
                symlinks[entry.path] = target
            } else if let sha = entry.sha256, entry.corruptData != true {
                files[entry.path] = sha
            }
        }
        absent.formUnion(removed)
    }
}

/// Opens `archive` and checks it against `expected`: the listing (kinds, removals), then the bytes,
/// directories and symlink targets that extracting everything produces.
@discardableResult
private func verify(_ archive: URL, _ expected: Expected, password: String? = nil,
            sourceLocation: SourceLocation = #_sourceLocation) async throws -> any ArchiveReading {
    let reader = try await Archive.open(at: archive, password: password)
    let listed = Dictionary(reader.entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
    for path in expected.files.keys.sorted() {
        #expect(listed[path]?.isDirectory == false, "\(path): missing or not a file", sourceLocation: sourceLocation)
    }
    for path in expected.dirs.sorted() {
        #expect(listed[path]?.isDirectory == true, "\(path): missing or not a directory", sourceLocation: sourceLocation)
    }
    for path in expected.symlinks.keys.sorted() {
        #expect(listed[path]?.isDirectory == false, "\(path): symlink missing", sourceLocation: sourceLocation)
    }
    for path in expected.absent.sorted() {
        #expect(listed[path] == nil, "\(path): should be gone", sourceLocation: sourceLocation)
    }

    let out = try Scratch()
    defer { out.remove() }
    try await reader.extract(nil, to: out.url, progress: nil)
    // CASE-TWINS: engine stays later-wins by design (the app asks at its level, App/Shared CaseTwinScan);
    // permanent tolerance. Case-only twins (README, Readme) overwrite each other on a case-insensitive volume,
    // so as in FixtureTests their contents are checked only on a case-sensitive one.
    let caseInsensitive = (try? out.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
        .volumeSupportsCaseSensitiveNames == false
    let folded = Dictionary(grouping: expected.files.keys, by: { $0.lowercased() })
    // One skip set drives both the guards and the content loop below. The tolerance covers case-fold twins of a
    // case-twins row only (the keys are distinct, so a group of two or more is twins spelled differently; a
    // save that removes one twin leaves none to skip).
    let skip: Set<String> = caseInsensitive ? Set(folded.values.filter { $0.count > 1 }.joined()) : []
    #expect(skip.isEmpty || expected.caseTwins, "case-fold twins \(skip.sorted()) skipped in a row not tagged case-twins",
            sourceLocation: sourceLocation)
    for path in skip.sorted() {
        #expect(expected.files.keys.contains { $0 != path && $0.lowercased() == path.lowercased() },
                "\(path) skipped without a case-fold partner", sourceLocation: sourceLocation)
    }
    var checked = 0
    for (path, sha) in expected.files.sorted(by: { $0.key < $1.key }) where !skip.contains(path) {
        checked += 1
        #expect((try? sha256(of: out.url.appending(path: path))) == sha, "\(path): content",
                sourceLocation: sourceLocation)
    }
    #expect(checked + skip.count == expected.files.count, "checked \(checked) of \(expected.files.count) files, skip set has \(skip.count)",
            sourceLocation: sourceLocation)
    for path in expected.dirs.sorted() {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: out.url.appending(path: path).path, isDirectory: &isDir)
        #expect(exists && isDir.boolValue, "\(path): directory not extracted", sourceLocation: sourceLocation)
    }
    for (path, target) in expected.symlinks.sorted(by: { $0.key < $1.key }) {
        let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: out.url.appending(path: path).path)
        #expect(actual == target, "\(path): symlink target", sourceLocation: sourceLocation)
    }
    return reader
}

/// Every header in `archive`, read with libarchive directly: no last-wins, no synthesized directories.
/// Name and sha256 of the data, in archive order. The name passes through libarchive's UTF-8 conversion,
/// which normalizes it, so compare names with String `==`; for the stored bytes use `Tool.storedNames`.
private func rawHeaders(_ archive: URL) throws -> [(name: String, sha256: String)] {
    let handle = try #require(archive_read_new())
    defer { archive_read_free(handle) }
    archive_read_support_format_all(handle)
    archive_read_support_filter_all(handle)
    try #require(archive_read_open_filename(handle, archive.path, 1 << 16) == ARCHIVE_OK,
                 "\(archive.lastPathComponent): \(String(cString: archive_error_string(handle)))")
    var headers: [(name: String, sha256: String)] = []
    var entry: OpaquePointer?
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let status = withUTF8CType { archive_read_next_header(handle, &entry) }
        if status == ARCHIVE_EOF { break }
        try #require(status == ARCHIVE_OK, "header \(headers.count): \(String(cString: archive_error_string(handle)))")
        let name = try #require(withUTF8CType { archive_entry_pathname_utf8(entry) }.map { String(cString: $0) })
        var hasher = SHA256()
        while true {
            let count = archive_read_data(handle, &buffer, buffer.count)
            try #require(count >= 0, "\(name): \(String(cString: archive_error_string(handle)))")
            if count == 0 { break }
            hasher.update(data: buffer[..<count])
        }
        headers.append((name, hasher.finalize().map { String(format: "%02x", $0) }.joined()))
    }
    return headers
}

/// The three baseline trees (same content: docs/, docs/nested/deep/data.bin, empty-dir, ...) in each writer family.
private let baselineFiles = ["zip/deflate.zip", "tar/basic.tar.gz", "7z/lzma2.7z"]

// MARK: - External tools

#if os(macOS)
enum Tool {
    /// 7-Zip: brew `sevenzip` (7zz) first, then p7zip 17 (7z, 7za), which is what GitHub's macOS images ship.
    static let sevenZip = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7z",
                           "/opt/homebrew/bin/7za", "/usr/local/bin/7za"].first(where: FileManager.default.isExecutableFile)
    static let bsdtar = existing("/usr/bin/bsdtar")
    static let unzip = existing("/usr/bin/unzip")
    static let zipinfo = existing("/usr/bin/zipinfo")
    static let hdiutil = existing("/usr/bin/hdiutil")
    static let python3 = existing("/usr/bin/python3")

    private static func existing(_ path: String) -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static let interopRequired = ProcessInfo.processInfo.environment["KERNIR_REQUIRE_INTEROP"] == "1"

    /// `tool` if it is installed. Missing: nil (its check skips), or a failure when KERNIR_REQUIRE_INTEROP=1.
    static func optional(_ tool: String?, _ name: String,
                         sourceLocation: SourceLocation = #_sourceLocation) throws -> String? {
        guard interopRequired else { return tool }
        // Typed String: otherwise #require takes T = String? from the return type and can never fail.
        let installed: String = try #require(tool, "\(name) is not installed (KERNIR_REQUIRE_INTEROP=1)",
                                             sourceLocation: sourceLocation)
        return installed
    }

    /// Info-ZIP's per-entry "file security status" (zipinfo ships with macOS): true when encrypted, false when
    /// not encrypted or not listed, nil only when zipinfo is missing.
    static func zipinfoSaysEncrypted(_ zip: URL, _ entry: String,
                                     sourceLocation: SourceLocation = #_sourceLocation) throws -> Bool? {
        guard let zipinfo = try optional(zipinfo, "zipinfo", sourceLocation: sourceLocation) else { return nil }
        let run = try run(zipinfo, ["-v", zip.path, entry])
        let status = String(decoding: run.stdout, as: UTF8.self).split(separator: "\n")
            .first { $0.contains("file security status:") }
        return status.map { !$0.contains("not encrypted") } ?? false
    }

    /// Entry names exactly as stored (no normalization), read by Python's tarfile/zipfile: libarchive's own
    /// UTF-8 conversion normalizes names on read (NFD on macOS today, NFC once the engine's UTF-8 patch lands), so it
    /// cannot tell what the writer stored. nil for formats Python cannot read here, or when python3 is missing.
    static func storedNames(_ archive: URL, _ format: ArchiveFormat,
                            sourceLocation: SourceLocation = #_sourceLocation) throws -> [String]? {
        guard [.zip, .tar, .tarGzip, .tarBzip2, .tarXz].contains(format),
              let python3 = try optional(python3, "python3", sourceLocation: sourceLocation) else { return nil }
        let script = """
            import sys, tarfile, zipfile
            p = sys.argv[1]
            if zipfile.is_zipfile(p):
                for i in zipfile.ZipFile(p).infolist():
                    print(i.filename.encode("utf-8" if i.flag_bits & 0x800 else "cp437").hex())
            else:
                for n in tarfile.open(p, "r:*", encoding="utf-8", errors="surrogateescape").getnames():
                    print(n.encode("utf-8", "surrogateescape").hex())
            """
        let run = try run(python3, ["-I", "-c", script, archive.path])
        try #require(run.status == 0, "python3 cannot list \(archive.lastPathComponent): \(run.stderr)",
                     sourceLocation: sourceLocation)
        return String(decoding: run.stdout, as: UTF8.self).split(separator: "\n").map { hex in
            let bytes = stride(from: 0, to: hex.count, by: 2).map {
                UInt8(hex.dropFirst($0).prefix(2), radix: 16)!
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Runs a tool to completion. stdin is /dev/null (bsdtar otherwise asks /dev/tty for a password),
    /// stderr goes to a temp file, so a chatty tool cannot fill a pipe nobody is reading, and the locale is
    /// UTF-8 (7-Zip converts passwords such as "пароль" through it).
    static func run(_ tool: String, _ arguments: [String]) throws -> Result {
        let errDir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: errDir) }
        let errURL = errDir.appending(path: "tool.err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = errHandle
        // waitUntilExit() spins a run loop, which cooperative-pool threads don't service reliably.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        let stderr = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
#endif

// MARK: - Repack keeps data

@Suite("Repack keeps data", .timeLimit(.minutes(2)))
struct RepackTests {
    static let repackable = Corpus.fixtures.filter { fixture in
        guard let format = fixture.format.flatMap(ArchiveFormat.init(rawValue:)), format.isWritable else { return false }
        return fixture.open == "ok" && fixture.extract == "ok"
            && Set(["libarchive-gap", "libarchive-bug", "corrupt", "traversal"]).isDisjoint(with: fixture.tags)
    }

    static let encryptedSevenZip = Corpus.fixtures.filter {
        $0.format == ArchiveFormat.sevenZip.rawValue && $0.encrypted
    }

    /// Guards: a plain save dropping a 7z's encryption. Opened with their password, the encrypted
    /// 7z fixtures save back to 7z with nil options as AES-256 (patch 0005, header included), and the result
    /// reopens only with the password: none is `.passwordRequired`, a wrong one `.wrongPassword`. The identity
    /// repack below covers their content too (fresh IVs make the bytes differ; names, dates and data match).
    @Test func encryptedSevenZipPlainSaveKeepsAES256() async throws {
        if Corpus.manifest != nil { #expect(!Self.encryptedSevenZip.isEmpty, "no encrypted 7z fixtures") }
        for fixture in Self.encryptedSevenZip {
            let scratch = try Scratch()
            defer { scratch.remove() }
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            #expect(source.encryption == .aes256, "\(fixture.file)")
            let out = scratch.url.appending(path: "saved.7z")
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .sevenZip,
                                          to: out, options: nil)
            await #expect(throws: ArchiveError.passwordRequired, "\(fixture.file)") {
                _ = try await Archive.open(at: out)
            }
            await #expect(throws: ArchiveError.wrongPassword, "\(fixture.file)") {
                _ = try await Archive.open(at: out, password: "kernir-wrong-password")
            }
            let back = try await verify(out, Expected(fixture), password: fixture.password)
            #expect(back.encryption == .aes256, "\(fixture.file)")
            #if os(macOS)
            if let sevenZip = try Tool.optional(Tool.sevenZip, "7-Zip"), let password = fixture.password {
                #expect(try Tool.run(sevenZip, ["t", "-p\(password)", out.path]).status == 0, "\(fixture.file)")
                #expect(try Tool.run(sevenZip, ["t", out.path]).status != 0, "\(fixture.file)")
            }
            #endif
        }
    }

    /// Guards: a plain save (no edits) silently dropping or altering entries, empty directories,
    /// symlinks or timestamps. Repack must stream every kept entry as-is.
    @Test(arguments: repackable)
    func repackWithoutChangesIsIdentity(_ fixture: Fixture) async throws {
        let format = try archiveFormat(of: fixture)
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await Archive.open(at: fixture.url, password: fixture.password)
        let out = scratch.url.appending(path: "repacked.\(format.fileExtension)")

        await checking(fixture) {
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format,
                                          to: out, options: nil)
            let reader = try await verify(out, Expected(fixture), password: fixture.password)

            let before = Set(source.entries.map(\.path)), after = Set(reader.entries.map(\.path))
            #expect(after == before,
                    "lost \(before.subtracting(after).sorted()), gained \(after.subtracting(before).sorted())")

            // Every dated source entry keeps its date (±2 s: DOS times in ZIP have 2-second steps); where the
            // manifest pins an mtime, the source date must equal it too.
            let sourceDates = Dictionary(source.entries.compactMap { entry in entry.modificationDate.map { (entry.path, $0) } },
                                         uniquingKeysWith: { _, last in last })
            for entry in reader.entries {
                guard let want = sourceDates[entry.path] else { continue }
                let got = entry.modificationDate
                #expect(got.map { abs($0.timeIntervalSince(want)) <= 2 } == true,
                        "\(entry.path): mtime \(String(describing: got)), source \(want)")
                if let mtime = fixture.mtime {
                    #expect(abs(want.timeIntervalSince1970 - mtime) < 1, "\(entry.path): source mtime \(want)")
                }
            }

            #if os(macOS)
            // Names are stored as listed (NFC). String `==` is canonical equivalence, so compare scalars.
            if let stored = try Tool.storedNames(out, format) {
                let nfd = stored.filter {
                    Array($0.unicodeScalars) != Array($0.precomposedStringWithCanonicalMapping.unicodeScalars)
                }
                #expect(nfd.isEmpty, "stored as NFD: \(nfd.map { $0.unicodeScalars.map(\.value) })")
            }
            #endif
        }
    }

    /// Guards: an edit hitting the wrong entries. Removals drop exactly what was asked, additions land
    /// where asked, and every other entry comes through byte-identical.
    @Test(arguments: baselineFiles)
    func removeAndAdd(_ file: String) async throws {
        let fixture = try fixtureNamed(file)
        let format = try archiveFormat(of: fixture)
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = try scratch.subdirectory("input")
        let added = try scratch.makeFile("added.txt", contents: Data("added by DataSafetyTests\n".utf8), in: input)
        let nested = try scratch.makeFile("added-folder/inner/nested.txt", contents: Data(repeating: 0x4B, count: 5000),
                                          in: input)
        let folder = input.appending(path: "added-folder")

        let removed: Set = ["docs/notes.txt", "empty-dir"]
        let source = try await Archive.open(at: fixture.url)
        let out = scratch.url.appending(path: "out.\(format.fileExtension)")
        try await ArchiveWriter.write(
            source: source,
            changes: ArchiveChangeSet(removedPaths: removed, additions: [
                .init(sourceURL: added, destinationDirectory: "docs"),
                .init(sourceURL: folder, destinationDirectory: ""),
            ]),
            format: format, to: out, options: nil)

        var expected = Expected(fixture, removing: removed)
        expected.files["docs/added.txt"] = try sha256(of: added)
        expected.files["added-folder/inner/nested.txt"] = try sha256(of: nested)
        expected.dirs.formUnion(["added-folder", "added-folder/inner"])
        try await verify(out, expected)
    }

    /// Guards: removing a directory leaving orphaned contents behind (or, the other way round, a
    /// directory removal that only drops the directory entry and silently keeps its files listed).
    @Test(arguments: baselineFiles)
    func removingDirectoryDropsContents(_ file: String) async throws {
        let fixture = try fixtureNamed(file)
        let format = try archiveFormat(of: fixture)
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await Archive.open(at: fixture.url)
        let out = scratch.url.appending(path: "out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["docs/nested"]),
                                      format: format, to: out, options: nil)

        let expected = Expected(fixture, removing: ["docs/nested"])
        #expect(expected.absent.contains("docs/nested/deep/data.bin"))
        try await verify(out, expected)
    }

    /// Guards: a stale removal (the entry is already gone) failing the whole save, or a removal matched
    /// by string prefix instead of by path component ("docs/notes" taking "docs/notes.txt" with it).
    /// Paths that are not in the archive are ignored.
    @Test(arguments: baselineFiles)
    func removingMissingPathIsIgnored(_ file: String) async throws {
        let fixture = try fixtureNamed(file)
        let format = try archiveFormat(of: fixture)
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await Archive.open(at: fixture.url)
        let out = scratch.url.appending(path: "out.\(format.fileExtension)")
        try await ArchiveWriter.write(
            source: source, changes: ArchiveChangeSet(removedPaths: ["no/such/file.txt", "docs/notes", "hello"]),
            format: format, to: out, options: nil)

        let reader = try await verify(out, Expected(fixture))
        let before = Set(source.entries.map(\.path)), after = Set(reader.entries.map(\.path))
        #expect(after == before, "lost \(before.subtracting(after).sorted()), gained \(after.subtracting(before).sorted())")
    }

    /// Guards: an edit elsewhere in an archive that stores one path twice (or as NFC and NFD twins)
    /// writing both copies back, or keeping the wrong one. The reader lists the last copy, so the
    /// save must write exactly that one, under the listed NFC name.
    @Test(arguments: ["zip/duplicates.zip", "tar/nfc-nfd-twins.tar"])
    func duplicatesCollapseOnUnrelatedSave(_ file: String) async throws {
        let fixture = try fixtureNamed(file)
        let format = try archiveFormat(of: fixture)
        let scratch = try Scratch()
        defer { scratch.remove() }
        let archive = try scratch.copy(fixture)

        // The duplicated path: raw headers that normalize to one NFC name (String keys group NFC/NFD twins).
        let twins = Dictionary(grouping: try rawHeaders(archive)) { $0.name.precomposedStringWithCanonicalMapping }
            .filter { $0.value.count > 1 }
        try #require(twins.count == 1, "\(file) should store exactly one path twice")
        let duplicate = try #require(fixture.entries.first { $0.path == twins.first?.key })
        let lastCopy = try #require(duplicate.sha256)

        // An unrelated change: zip drops other.txt, tar gains new.txt.
        var expected = Expected(fixture)
        var changes = ArchiveChangeSet()
        if format == .zip {
            changes.removedPaths = ["other.txt"]
            expected = Expected(fixture, removing: ["other.txt"])
        } else {
            let added = try scratch.makeFile("new.txt", contents: Data("new\n".utf8), in: try scratch.subdirectory("input"))
            changes.additions = [.init(sourceURL: added, destinationDirectory: "")]
            expected.files["new.txt"] = sha256(Data("new\n".utf8))
        }

        let source = try await Archive.open(at: archive)
        let out = scratch.url.appending(path: "out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: changes, format: format, to: out, options: nil)

        let written = try rawHeaders(out)
        // String `==` is canonical equivalence: an NFD twin left behind matches too, so `count == 1` is
        // what catches it; the scalar check below then pins the one copy to the listed NFC name.
        let copies = written.filter { $0.name == duplicate.path }
        #expect(copies.count == 1, "\(duplicate.path): \(copies.count) headers in \(written.map(\.name))")
        try #require(copies.first != nil)
        #if os(macOS)
        if let stored = try Tool.storedNames(out, format)?.filter({ $0 == duplicate.path }) {
            #expect(stored.allSatisfy { Array($0.unicodeScalars) == Array(duplicate.path.unicodeScalars) },
                    "\(duplicate.path): stored as \(stored.map { $0.unicodeScalars.map(\.value) })")
        }
        #endif
        #expect(copies.allSatisfy { $0.sha256 == lastCopy }, "\(duplicate.path): not the last copy's bytes")

        let reader = try await verify(out, expected)
        let before = Set(source.entries.map(\.path)), after = Set(reader.entries.map(\.path))
        let want = before.subtracting(changes.removedPaths).union(changes.additions.isEmpty ? [] : ["new.txt"])
        #expect(after == want, "lost \(want.subtracting(after).sorted()), gained \(after.subtracting(want).sorted())")
        #expect(reader.entries.count == want.count, "listing: \(reader.entries.map(\.path))")
        #expect(try sha256(of: archive) == fixture.fileSha256, "the source archive changed")
    }

    /// Guards: losing resource forks and extended attributes. Finder zips keep them in __MACOSX/._*
    /// entries, which Apple's libarchive hides from listings (docs/qa/fixtures.md, finding 1); a repack
    /// built from that listing would drop them.
    @Test(arguments: [false, true])
    func finderMetadataSurvivesRepack(removingHello: Bool) async throws {
        let fixture = try fixtureNamed("zip/macos-finder.zip")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let removed: Set<String> = removingHello ? ["Project/hello.txt"] : []
        let source = try await Archive.open(at: fixture.url)
        let out = scratch.url.appending(path: "out.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: removed),
                                      format: .zip, to: out, options: nil)

        // The writer never removes companions on its own, so ._hello.txt survives hello.txt's removal; the
        // app removes them explicitly. extract(nil) writes __MACOSX/._* raw, so verify() checks
        // every companion's bytes along with the rest.
        let reader = try await verify(out, Expected(fixture, removing: removed))
        #expect(reader.entries.count == (removingHello ? 9 : 10), "entries: \(reader.entries.map(\.path).sorted())")
    }

    /// Guards: Save (as opposed to Save As) losing data or littering the folder. Writing over the source
    /// file must give the edited archive and leave nothing else behind.
    @Test(arguments: baselineFiles)
    func inPlaceSave(_ file: String) async throws {
        let fixture = try fixtureNamed(file)
        let format = try archiveFormat(of: fixture)
        let scratch = try Scratch()
        defer { scratch.remove() }
        let archive = try scratch.copy(fixture)
        let source = try await Archive.open(at: archive)
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["docs/notes.txt"]),
                                      format: format, to: archive, options: nil)

        try await verify(archive, Expected(fixture, removing: ["docs/notes.txt"]))
        #expect(items(in: scratch.url) == [archive.lastPathComponent], "leftover temp files")
    }

    /// Guards: a private archive becoming world-readable after a save (the replacement file must take
    /// over the original's permissions, not the umask default).
    @Test(arguments: baselineFiles)
    func inPlaceSaveKeepsPermissions(_ file: String) async throws {
        let fixture = try fixtureNamed(file)
        let format = try archiveFormat(of: fixture)
        let scratch = try Scratch()
        defer { scratch.remove() }
        let archive = try scratch.copy(fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let source = try await Archive.open(at: archive)
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["docs/notes.txt"]),
                                      format: format, to: archive, options: nil)

        let permissions = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int
        #expect(permissions.map { $0 & 0o777 } == 0o600, "permissions \(String(permissions ?? 0, radix: 8))")
    }
}

// MARK: - A failed save keeps the original

@Suite("Failed save keeps the original", .timeLimit(.minutes(2)))
struct FailedSaveTests {
    /// Guards: a write that fails halfway (here: an addition vanished before Save) truncating or
    /// replacing the archive it was saving over.
    @Test(arguments: ["zip/deflate.zip", "tar/basic.tar.gz"])
    func missingAdditionLeavesOriginal(_ file: String) async throws {
        let fixture = try fixtureNamed(file)
        let format = try archiveFormat(of: fixture)
        let scratch = try Scratch()
        defer { scratch.remove() }
        let dest = try scratch.subdirectory("dest")
        let archive = try scratch.copy(fixture, into: dest)
        let before = try sha256(of: archive)
        let missing = scratch.url.appending(path: "input/does-not-exist.txt")

        let source = try await Archive.open(at: archive)
        let result = await outcome {
            try await ArchiveWriter.write(
                source: source,
                changes: ArchiveChangeSet(removedPaths: ["hello.txt"],
                                          additions: [.init(sourceURL: missing, destinationDirectory: "")]),
                format: format, to: archive, options: nil)
        }
        #expect(isIOError(result), "write with a missing addition must throw .io, got \(result)")
        #expect(try sha256(of: archive) == before, "original changed")
        #expect(items(in: dest) == [archive.lastPathComponent], "leftover temp files")
    }

    /// Guards: validation that happens after the original was already opened for writing. A request
    /// the format cannot honor must be rejected before anything touches the destination.
    @Test func unsupportedEncryptionLeavesOriginal() async throws {
        let fixture = try fixtureNamed("tar/basic.tar")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let archive = try scratch.copy(fixture)
        let before = try sha256(of: archive)
        let source = try await Archive.open(at: archive)

        let result = await outcome {
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["hello.txt"]),
                                          format: .tar, to: archive,
                                          options: ArchiveWriteOptions(encryption: .aes256, password: "x"))
        }
        if case .failed(let error) = result {
            #expect(error as? ArchiveError == .unsupportedEncryption(.tar))
        } else {
            Issue.record("tar with AES-256 must throw")
        }
        #expect(try sha256(of: archive) == before, "original changed")
        #expect(items(in: scratch.url) == [archive.lastPathComponent], "leftover temp files")
    }

    /// Guards: a writer that deletes or truncates the original before it knows it can write the
    /// replacement. In a read-only folder the replacement cannot be moved in, so the save must fail cleanly.
    @Test func readOnlyDirectoryLeavesOriginal() async throws {
        guard geteuid() != 0 else { return }  // root ignores directory permissions
        let fixture = try fixtureNamed("zip/deflate.zip")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let dest = try scratch.subdirectory("readonly")
        let archive = try scratch.copy(fixture, into: dest)
        let before = try sha256(of: archive)
        let source = try await Archive.open(at: archive)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path) }
        let result = await outcome {
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["hello.txt"]),
                                          format: .zip, to: archive, options: nil)
        }
        #expect(isIOError(result), "saving into a read-only folder must throw .io, got \(result)")
        #expect(try sha256(of: archive) == before, "original changed")
        #expect(items(in: dest) == [archive.lastPathComponent], "leftover temp files")
    }

    /// Guards: Cancel during a long save leaving a half-written archive in place of the original, or a
    /// stray temp file. The task is cancelled from inside the first progress report, so the writer is
    /// mid-write for sure; it must throw .cancelled and leave the old bytes.
    @Test func cancellationLeavesOriginal() async throws {
        let fixture = try fixtureNamed("zip/deflate.zip")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let dest = try scratch.subdirectory("dest")
        let archive = try scratch.copy(fixture, into: dest)
        let before = try sha256(of: archive)
        let big = try scratch.subdirectory("input").appending(path: "big.bin")
        try makeBigFile(at: big, megabytes: 64)
        let source = try await Archive.open(at: archive)

        // The handler cancels on its first fraction > 0 call made after the task is stored.
        let stored = Locked<Task<Void, any Error>?>(nil)
        let cancelled = Locked(false)
        let task = Task {
            try await ArchiveWriter.write(
                source: source, changes: ArchiveChangeSet(additions: [.init(sourceURL: big, destinationDirectory: "")]),
                format: .zip, to: archive, options: nil,
                progress: { fraction, _ in
                    guard fraction > 0, let task = stored.value else { return }
                    cancelled.withLock { done in
                        if !done { task.cancel(); done = true }
                    }
                })
        }
        stored.withLock { $0 = task }

        let result = await task.result
        #expect(cancelled.value, "writer never reported progress after the task started")
        if case .failure(let error) = result {
            #expect(error as? ArchiveError == .cancelled, "expected .cancelled, got \(error)")
        } else {
            Issue.record("a save cancelled mid-write completed")
        }
        #expect(try sha256(of: archive) == before, "original changed by a cancelled save")
        #expect(items(in: dest) == [archive.lastPathComponent], "leftover temp files")
    }

    /// Guards: a crash or power loss mid-save (kill -9) destroying the original. Proxy: while the
    /// writer is busy, the original must still be byte-identical. Where the temp file lives is the
    /// writer's call (FileManager's itemReplacementDirectory, same volume but not necessarily the
    /// same folder), so only the absence of leftovers in the destination folder is asserted.
    @Test(.memoryHeavy) func originalUntouchedWhileWriting() async throws {
        let fixture = try fixtureNamed("zip/deflate.zip")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let dest = try scratch.subdirectory("dest")
        let archive = try scratch.copy(fixture, into: dest)
        let name = archive.lastPathComponent
        let before = try sha256(of: archive)
        let big = try scratch.subdirectory("input").appending(path: "big.bin")
        try makeBigFile(at: big, megabytes: 64)
        let source = try await Archive.open(at: archive)

        struct Observation {
            var checked = false
            var originalIntact = false
        }
        let seen = Locked(Observation())
        try await ArchiveWriter.write(
            source: source, changes: ArchiveChangeSet(additions: [.init(sourceURL: big, destinationDirectory: "")]),
            format: .zip, to: archive, options: nil,
            progress: { fraction, _ in
                guard fraction > 0.2 else { return }
                seen.withLock { seen in
                    guard !seen.checked else { return }
                    seen.checked = true
                    seen.originalIntact = (try? sha256(of: archive)) == before
                }
            })

        let observed = seen.value
        #expect(observed.checked, "progress never passed 0.2")
        #expect(observed.originalIntact, "original modified before the final replace")
        var expected = Expected(fixture)
        expected.files["big.bin"] = try sha256(of: big)
        try await verify(archive, expected)
        #expect(items(in: dest) == [name], "leftover temp files")
    }

    #if os(macOS)
    /// Guards: a full disk. The temp file cannot be completed, so the save must throw, keep the original
    /// and remove the partial temp file (which would otherwise eat the little space left).
    @Test(.enabled(if: Tool.hdiutil != nil || Tool.interopRequired, "needs hdiutil"))
    func diskFullLeavesOriginal() async throws {
        let hdiutil = try #require(Tool.hdiutil, "hdiutil is not installed (KERNIR_REQUIRE_INTEROP=1)")
        let fixture = try fixtureNamed("zip/deflate.zip")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let image = scratch.url.appending(path: "full.dmg")
        let volume = try scratch.subdirectory("mnt")
        let created = try Tool.run(hdiutil, ["create", "-quiet", "-size", "4m", "-fs", "HFS+",
                                             "-volname", "KernirFull", image.path])
        let attached = created.status == 0
            ? try Tool.run(hdiutil, ["attach", "-quiet", "-nobrowse", "-mountpoint", volume.path, image.path])
            : created
        guard attached.status == 0 else {
            // No disk images here (sandbox, CI without a GUI session): report, don't fail.
            withKnownIssue("cannot create or attach a disk image: \(attached.stderr)") {
                throw ArchiveError.io("hdiutil")
            }
            return
        }
        defer { _ = try? Tool.run(hdiutil, ["detach", "-quiet", "-force", volume.path]) }

        let archive = try scratch.copy(fixture, into: volume)
        let before = try sha256(of: archive)
        let big = try scratch.subdirectory("input").appending(path: "big.bin")
        try makeBigFile(at: big, megabytes: 16)
        // System folders a fresh HFS+ volume may grow on its own. .TemporaryItems is not one of them: on a
        // non-boot volume the writer's itemReplacementDirectory lives there, so its files count.
        let system: Set = [".fseventsd", ".Spotlight-V100", ".Trashes", ".HFS+ Private Directory Data\r",
                           ".journal", ".journal_info_block"]
        let filesBefore = files(under: volume, skipping: system)
        let source = try await Archive.open(at: archive)

        let result = await outcome {
            try await ArchiveWriter.write(
                source: source, changes: ArchiveChangeSet(additions: [.init(sourceURL: big, destinationDirectory: "")]),
                format: .zip, to: archive, options: ArchiveWriteOptions(method: .store))
        }
        // A real error (matches(_:"error") rejects .notImplemented); the save was never cancelled.
        #expect(matches(result, "error") && archiveError(result) != .cancelled,
                "16 MB into a 4 MB volume must throw, got \(result)")
        #expect(try sha256(of: archive) == before, "original changed")
        #expect(files(under: volume, skipping: system) == filesBefore, "leftover temp files")
    }
    #endif
}

// MARK: - Encryption on save

@Suite("Encryption on save", .timeLimit(.minutes(2)))
struct EncryptionOnSaveTests {
    /// Source fixture -> the method `encryption` reports for it (a mixed zip reports its first encrypted
    /// entry's method).
    static let methods: [String: ArchiveEncryption] = [
        "zip/aes256.zip": .aes256, "zip/aes128.zip": .aes128, "zip/zipcrypto.zip": .zipCrypto,
        "zip/mixed-encryption.zip": .aes256,
    ]

    /// Guards: a plain save quietly decrypting an archive (exposing private files) or switching it to a
    /// weaker scheme. With options nil the whole output uses the source's method, so every entry with
    /// content comes out encrypted, the formerly plain entries of a mixed archive included.
    @Test(arguments: methods.keys.sorted())
    func plainRepackKeepsEncryption(_ file: String) async throws {
        let fixture = try fixtureNamed(file)
        let password = Corpus.password
        let scratch = try Scratch()
        defer { scratch.remove() }
        // Keep the mixed archive's plain files (empty.txt, plain.txt), so remove an encrypted one there.
        let mixed = fixture.tags.contains("mixed-encryption")
        let removed = mixed ? "docs/readme.md" : "empty.txt"
        let source = try await Archive.open(at: fixture.url, password: password)
        #expect(source.encryption == Self.methods[file], "source encryption")
        let out = scratch.url.appending(path: "out.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: [removed]),
                                      format: .zip, to: out, options: nil)

        let reader = try await verify(out, Expected(fixture, removing: [removed]), password: password)
        #expect(reader.encryption == Self.methods[file])
        #expect(reader.isEncrypted)
        let listed = Dictionary(reader.entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        // Zero-length entries are skipped: libarchive writes them unencrypted (nothing to protect), so
        // their flag after a repack is not part of the contract.
        let withContent = fixture.entries.filter { !$0.dir && $0.symlink == nil && $0.size != 0 && $0.path != removed }
        for entry in withContent {
            #expect(listed[entry.path]?.isEncrypted == true, "\(entry.path) isEncrypted")
        }
        if mixed {
            #expect(listed["plain.txt"]?.isEncrypted == true, "plain.txt: a plain save encrypts every entry")
        }

        let locked = try await Archive.open(at: out)
        let withoutPassword = await outcome { try await locked.extract(nil, to: scratch.subdirectory("nopw"), progress: nil) }
        #expect(matches(withoutPassword, "passwordRequired"), "extract without password: \(withoutPassword)")

        let hello = try #require(fixture.entries.first { $0.path == "hello.txt" }?.sha256)
        let wrong = await outcome { _ = try await Archive.open(at: out, password: Corpus.wrongPassword) }
        if Self.methods[file] == .zipCrypto, wrong == .ok {
            // ZipCrypto checks a password against one header byte, so about 1 wrong password in 256 gets past
            // open(). Then the extract must throw, and even a wrongly successful extract must never yield the
            // plaintext.
            let opened = try await Archive.open(at: out, password: Corpus.wrongPassword)
            var leaked = false
            let extracted = await outcome {
                let url = try await opened.extractToTemporaryFile("hello.txt")
                defer { try? FileManager.default.removeItem(at: url) }
                leaked = (try? sha256(of: url)) == hello
            }
            #expect(matches(extracted, "error"), "wrong ZipCrypto password passed open(); extract must throw, got \(extracted)")
            #expect(!leaked, "a wrong ZipCrypto password extracted hello.txt")
        } else {
            let expectedWrong = fixture.openWithWrongPassword ?? "wrongPassword"
            #expect(matches(wrong, expectedWrong), "open with wrong password: expected \(expectedWrong), got \(wrong)")
        }

        #if os(macOS)
        for entry in withContent {
            if let encrypted = try Tool.zipinfoSaysEncrypted(out, entry.path) {
                #expect(encrypted, "zipinfo: \(entry.path) not encrypted or not listed")
            }
        }
        if let bsdtar = try Tool.optional(Tool.bsdtar, "bsdtar") {
            let run = try Tool.run(bsdtar, ["--passphrase", password, "-xOf", out.path, "hello.txt"])
            #expect(run.status == 0, "bsdtar: \(run.stderr)")
            #expect(sha256(run.stdout) == hello, "bsdtar: hello.txt content")
        }
        if let sevenZip = try Tool.optional(Tool.sevenZip, "7-Zip") {
            let run = try Tool.run(sevenZip, ["t", "-p\(password)", out.path])
            #expect(run.status == 0, "7-Zip t: \(run.stderr)")
        }
        #endif
    }

    /// Guards: a file added to an encrypted archive landing in it unencrypted. A plain save (options nil)
    /// keeps the source's encryption for every entry, new ones included.
    @Test func plainSaveEncryptsAdditions() async throws {
        let fixture = try fixtureNamed("zip/aes256.zip")
        let password = Corpus.password
        let scratch = try Scratch()
        defer { scratch.remove() }
        let added = try scratch.makeFile("input/added.txt", contents: Data("private addition\n".utf8))
        let source = try await Archive.open(at: fixture.url, password: password)
        let out = scratch.url.appending(path: "out.zip")
        try await ArchiveWriter.write(
            source: source, changes: ArchiveChangeSet(additions: [.init(sourceURL: added, destinationDirectory: "docs")]),
            format: .zip, to: out, options: nil)

        var expected = Expected(fixture)
        expected.files["docs/added.txt"] = try sha256(of: added)
        let reader = try await verify(out, expected, password: password)
        #expect(reader.encryption == .aes256)
        #expect(reader.entries.first { $0.path == "docs/added.txt" }?.isEncrypted == true, "docs/added.txt isEncrypted")

        let locked = try await Archive.open(at: out)
        let withoutPassword = await outcome { _ = try await locked.extractToTemporaryFile("docs/added.txt") }
        #expect(matches(withoutPassword, "passwordRequired"), "extract addition without password: \(withoutPassword)")

        #if os(macOS)
        // Independent of Kernir's reader: zipinfo's security status and 7-Zip's "Encrypted = +".
        if let encrypted = try Tool.zipinfoSaysEncrypted(out, "docs/added.txt") {
            #expect(encrypted, "zipinfo: docs/added.txt not encrypted or not listed")
        }
        if let sevenZip = try Tool.optional(Tool.sevenZip, "7-Zip") {
            let run = try Tool.run(sevenZip, ["l", "-slt", "-p\(password)", out.path])
            #expect(run.status == 0, "7-Zip l: \(run.stderr)")
            let block = String(decoding: run.stdout, as: UTF8.self).components(separatedBy: "\n\n")
                .first { $0.contains("Path = docs/added.txt\n") }
            #expect(block?.contains("Encrypted = +") == true, "7-Zip: docs/added.txt not encrypted: \(block ?? "missing")")
        }
        #endif
    }

    /// Guards: Save As producing an "encrypted" archive nobody else can open (or that opens without the
    /// password). Checked against Kernir itself, bsdtar, 7-Zip and, for ZipCrypto, Info-ZIP unzip.
    @Test(arguments: [ArchiveEncryption.aes256, .aes128, .zipCrypto], ["kernir", "пароль"])
    func saveAsEncryptedZipInterop(_ encryption: ArchiveEncryption, _ password: String) async throws {
        let fixture = try fixtureNamed("zip/deflate.zip")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await Archive.open(at: fixture.url)
        let out = scratch.url.appending(path: "out.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .zip, to: out,
                                      options: ArchiveWriteOptions(encryption: encryption, password: password))

        let reader = try await verify(out, Expected(fixture), password: password)
        #expect(reader.encryption == encryption)
        // libarchive leaves zero-length entries unencrypted (there are no bytes to protect; ZIP never
        // encrypts names), so only entries with content must carry the flag.
        for entry in reader.entries where !entry.isDirectory && entry.size != 0 {
            #expect(entry.isEncrypted, "\(entry.path) not encrypted")
        }
        let locked = try await Archive.open(at: out)
        let withoutPassword = await outcome { try await locked.extract(nil, to: scratch.subdirectory("nopw"), progress: nil) }
        #expect(matches(withoutPassword, "passwordRequired"), "extract without password: \(withoutPassword)")

        #if os(macOS)
        for entry in fixture.fileEntries where entry.size != 0 {
            if let encrypted = try Tool.zipinfoSaysEncrypted(out, entry.path) {
                #expect(encrypted, "zipinfo: \(entry.path) not encrypted or not listed")
            }
        }
        if let bsdtar = try Tool.optional(Tool.bsdtar, "bsdtar") {
            let dir = try scratch.subdirectory("bsdtar")
            let run = try Tool.run(bsdtar, ["--passphrase", password, "-x", "-f", out.path, "-C", dir.path])
            #expect(run.status == 0, "bsdtar: \(run.stderr)")
            for entry in fixture.fileEntries {
                #expect((try? sha256(of: dir.appending(path: entry.path))) == entry.sha256, "bsdtar: \(entry.path)")
            }
        }
        if let sevenZip = try Tool.optional(Tool.sevenZip, "7-Zip") {
            let run = try Tool.run(sevenZip, ["t", "-p\(password)", out.path])
            #expect(run.status == 0, "7-Zip t: \(run.stderr)")
        }
        // unzip reads ZipCrypto only, and takes the password as raw bytes; stick to ASCII there.
        if encryption == .zipCrypto, password.allSatisfy(\.isASCII), let unzip = try Tool.optional(Tool.unzip, "unzip") {
            let run = try Tool.run(unzip, ["-P", password, "-t", out.path])
            #expect(run.status == 0, "unzip -t: \(run.stderr)\(String(decoding: run.stdout, as: UTF8.self))")
        }
        #endif
    }

    /// Guards: Save As to another format losing entries on the way (each writer family has its own
    /// code path for directories, empty files and nesting).
    @Test(arguments: ArchiveFormat.writable.filter { $0 != .zip })
    func saveAsOtherFormatKeepsContents(_ format: ArchiveFormat) async throws {
        let fixture = try fixtureNamed("zip/deflate.zip")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await Archive.open(at: fixture.url)
        let out = scratch.url.appending(path: "out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: out,
                                      options: ArchiveWriteOptions())

        let reader = try await verify(out, Expected(fixture))
        #expect(reader.format == format)
        let before = Set(source.entries.map(\.path)), after = Set(reader.entries.map(\.path))
        #expect(after == before, "lost \(before.subtracting(after).sorted()), gained \(after.subtracting(before).sorted())")
    }

    /// Guards: asking for encryption and silently getting a plain archive. Formats without encryption
    /// must refuse, through both overloads, before creating the destination.
    @Test(arguments: ArchiveFormat.writable.filter { !$0.supportedEncryptions.contains(.aes256) })
    func encryptionTheFormatCannotHonorThrows(_ format: ArchiveFormat) async throws {
        let fixture = try fixtureNamed("zip/deflate.zip")
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await Archive.open(at: fixture.url)
        let out = scratch.url.appending(path: "out.\(format.fileExtension)")

        let withOptions = await outcome {
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: out,
                                          options: ArchiveWriteOptions(encryption: .aes256, password: "kernir"))
        }
        let withPassword = await outcome {
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: out,
                                          password: "kernir")
        }
        for result in [withOptions, withPassword] {
            if case .failed(let error) = result {
                #expect(error as? ArchiveError == .unsupportedEncryption(format), "got \(error)")
            } else {
                Issue.record("\(format) with AES-256 must throw")
            }
        }
        #expect(items(in: scratch.url).isEmpty, "destination or temp files created: \(items(in: scratch.url))")
    }
}
