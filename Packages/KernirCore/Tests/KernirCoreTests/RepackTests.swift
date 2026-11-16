import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// Repacking an existing archive (ArchiveWriter.write with a source): the copy step, removals,
/// replacements, kept encryption, conversion, hardlinks and macOS companions. The corpus-wide data-safety
/// checks live in DataSafetyTests.swift; cases that duplicate one of those exactly are not repeated here.
struct WriterRepackTests {
    static let sourceFormats: [ArchiveFormat] = [.zip, .tarXz]
    static let encryptions: [ArchiveEncryption] = [.aes256, .aes128, .zipCrypto]
    static let mtime = Date(timeIntervalSince1970: 1_750_000_000)
    static let bigBytes = Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })

    /// Nested folders, an empty folder, an executable, a private file, a symlink and 100 KB of random bytes.
    static let files: [String: Data] = [
        "a.txt": Data("alpha\n".utf8),
        "b/c.txt": Data("charlie\n".utf8),
        "b/d/e.bin": bigBytes,
        "empty/": Data(),
        "run.sh": Data("#!/bin/sh\necho hi\n".utf8),
        "secret.txt": Data("private\n".utf8),
    ]

    /// Writes `files` (plus the symlink `link` -> a.txt) into a new folder with fixed permissions and dates.
    static func makeTree() throws -> URL {
        let dir = Fixtures.tempDir()
        let fm = FileManager.default
        Fixtures.makeFiles(files, in: dir)
        try fm.createSymbolicLink(atPath: dir.appending(path: "link").path, withDestinationPath: "a.txt")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "run.sh").path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appending(path: "secret.txt").path)
        for path in ["a.txt", "b/c.txt", "b/d/e.bin", "run.sh", "secret.txt", "b/d", "b", "empty"] {
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dir.appending(path: path).path)
        }
        return dir
    }

    /// The tree as a zip or tar.xz made by bsdtar.
    static func makeSource(_ format: ArchiveFormat) throws -> URL {
        let dir = try makeTree()
        let name = "src.\(format.fileExtension)"
        let formatArgs = format == .zip ? ["--format", "zip"] : ["-J"]
        try Fixtures.bsdtar(["-cf", name, "--no-mac-metadata"] + formatArgs
                            + ["a.txt", "b", "empty", "link", "run.sh", "secret.txt"], cwd: dir)
        return dir.appending(path: name)
    }

    /// The tree as a zip encrypted by Kernir's writer with password "pw".
    static func makeEncryptedZip(_ encryption: ArchiveEncryption) async throws -> URL {
        let tree = try makeTree()
        let out = Fixtures.tempDir().appending(path: "src.zip")
        let additions = ["a.txt", "b", "empty", "run.sh", "secret.txt"].map {
            ArchiveChangeSet.Addition(sourceURL: tree.appending(path: $0), destinationDirectory: "")
        }
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: additions), format: .zip,
                                      to: out, options: ArchiveWriteOptions(encryption: encryption, password: "pw"))
        return out
    }

    /// A path in a new, empty folder.
    static func destination(_ name: String) -> URL {
        let folder = Fixtures.tempDir().appending(path: "out", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    /// sha256 of every regular file `reader` extracts, by entry path.
    static func contents(of reader: any ArchiveReading) async throws -> [String: String] {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await reader.extract(nil, to: dir, progress: nil)
        // subpathsOfDirectory, not enumerator(atPath:): the enumerator skips AppleDouble "._" files.
        var result: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: dir.path) {
            let url = dir.appending(path: path)
            if try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular {
                result[path] = Fixtures.sha256(url)
            }
        }
        return result
    }

    struct RawHeader {
        let path: String
        let hardlink: String?
        let size: Int64
        let isRegular: Bool
    }

    /// Every header as stored (duplicates included), with names as the reader normalizes them.
    static func rawHeaders(_ url: URL, password: String? = nil) throws -> [RawHeader] {
        let session = try ReadSession(url: url, password: password)
        var result: [RawHeader] = []
        while let e = try session.nextHeader() {
            result.append(RawHeader(
                path: EntryNameDecoder.pathname(of: e).flatMap(EntryPath.normalize) ?? "",
                hardlink: EntryNameDecoder.normalizedHardlinkTarget(of: e),
                size: archive_entry_size(e),
                isRegular: archive_entry_filetype(e) & mode_t(S_IFMT) == mode_t(S_IFREG)))
        }
        return result
    }

    static func entryMap(_ reader: any ArchiveReading) -> [String: ArchiveEntry] {
        Dictionary(reader.entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
    }

    static func adding(_ url: URL, into directory: String) -> ArchiveChangeSet.Addition {
        .init(sourceURL: url, destinationDirectory: directory)
    }

    static func setXattr(_ url: URL, _ name: String, _ value: String) throws {
        let bytes = Array(value.utf8)
        let r = setxattr(url.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW)
        guard r == 0 else { throw Fixtures.ToolFailure(description: "setxattr \(url.path): \(errno)") }
    }

    /// A Finder-style zip of folder `name` (ditto --sequesterRsrc --keepParent) whose files carry an xattr.
    static func makeDittoZip(folder name: String, files: [String: Data]) throws -> URL {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(Dictionary(uniqueKeysWithValues: files.map { ("\(name)/\($0.key)", $0.value) }), in: dir)
        for path in files.keys where !path.hasSuffix("/") {
            try setXattr(dir.appending(path: "\(name)/\(path)"), "com.kernir.note", "note for \(path)")
        }
        try Fixtures.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", name, "\(name).zip"], cwd: dir)
        return dir.appending(path: "\(name).zip")
    }

    // MARK: - Removals and additions

    @Test(arguments: sourceFormats)
    func removeFileKeepsOthersIdentical(_ format: ArchiveFormat) async throws {
        let source = try await Archive.open(at: try Self.makeSource(format))
        let out = Self.destination("out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["a.txt"]),
                                      format: format, to: out, options: nil)

        let result = try await Archive.open(at: out)
        let before = Self.entryMap(source), after = Self.entryMap(result)
        #expect(Set(after.keys) == Set(before.keys).subtracting(["a.txt"]))
        var expected = try await Self.contents(of: source)
        expected["a.txt"] = nil
        #expect(try await Self.contents(of: result) == expected)
        for (path, old) in before where path != "a.txt" {
            let new = try #require(after[path])
            #expect(new.permissions == old.permissions, "\(path) permissions")
            if let want = old.modificationDate {
                #expect(new.modificationDate.map { abs($0.timeIntervalSince(want)) <= 2 } == true, "\(path) mtime")
            }
        }
        #expect(after["secret.txt"]?.permissions.map { $0 & 0o777 } == 0o600)
        #expect(after["run.sh"]?.permissions.map { $0 & 0o777 } == 0o755)
    }

    @Test(arguments: sourceFormats)
    func removeDirectoryDropsDescendants(_ format: ArchiveFormat) async throws {
        let source = try await Archive.open(at: try Self.makeSource(format))
        let out = Self.destination("out.\(format.fileExtension)")
        // "b/d" goes with its contents; "b" (a string prefix of other paths) and an unknown path are untouched.
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["b/d", "no/such"]),
                                      format: format, to: out, options: nil)

        let paths = Set(try await Archive.open(at: out).entries.map(\.path))
        #expect(paths == Set(source.entries.map(\.path)).subtracting(["b/d", "b/d/e.bin"]))
    }

    @Test(arguments: sourceFormats)
    func addIntoExistingFolderAndReplaceSamePath(_ format: ArchiveFormat) async throws {
        let archive = try Self.makeSource(format)
        let source = try await Archive.open(at: archive)
        let input = Fixtures.tempDir()
        Fixtures.makeFiles(["c.txt": Data("new charlie\n".utf8), "f.txt": Data("foxtrot\n".utf8)], in: input)
        let out = Self.destination("out.\(format.fileExtension)")
        try await ArchiveWriter.write(
            source: source,
            changes: ArchiveChangeSet(additions: [Self.adding(input.appending(path: "c.txt"), into: "b"),
                                                  Self.adding(input.appending(path: "f.txt"), into: "b")]),
            format: format, to: out, options: nil)

        let headers = try Self.rawHeaders(out).map(\.path)
        #expect(headers.count == Set(headers).count, "duplicate headers: \(headers.sorted())")
        #expect(Set(headers) == Set(try Self.rawHeaders(archive).map(\.path)).union(["b/f.txt"]))
        let result = try await Archive.open(at: out)
        let contents = try await Self.contents(of: result)
        #expect(contents["b/c.txt"] == Fixtures.sha256(input.appending(path: "c.txt")))
        #expect(contents["b/d/e.bin"] == (try await Self.contents(of: source))["b/d/e.bin"])
    }

    @Test(arguments: sourceFormats)
    func replaceFolderInOneSave(_ format: ArchiveFormat) async throws {
        let source = try await Archive.open(at: try Self.makeSource(format))
        let input = Fixtures.tempDir()
        Fixtures.makeFiles(["b/x.txt": Data("x-ray\n".utf8)], in: input)
        let out = Self.destination("out.\(format.fileExtension)")
        try await ArchiveWriter.write(
            source: source,
            changes: ArchiveChangeSet(removedPaths: ["b"], additions: [Self.adding(input.appending(path: "b"), into: "")]),
            format: format, to: out, options: nil)

        let headers = try Self.rawHeaders(out).map(\.path)
        #expect(headers.filter { $0 == "b" || $0.hasPrefix("b/") }.sorted() == ["b", "b/x.txt"])
        #expect(headers.count == Set(headers).count)
        let contents = try await Self.contents(of: try await Archive.open(at: out))
        #expect(contents["b/x.txt"] == Fixtures.sha256(input.appending(path: "b/x.txt")))
        #expect(contents["a.txt"] != nil)
    }

    /// An addition at a source file's path makes it a folder: the old file does not survive next to it.
    @Test func additionBelowSourceFileReplacesTheFile() async throws {
        let source = try await Archive.open(at: try Self.makeSource(.zip))
        let input = Fixtures.tempDir()
        Fixtures.makeFiles(["inner.txt": Data("inner\n".utf8)], in: input)
        let out = Self.destination("out.zip")
        try await ArchiveWriter.write(
            source: source, changes: ArchiveChangeSet(additions: [Self.adding(input.appending(path: "inner.txt"), into: "a.txt")]),
            format: .zip, to: out, options: nil)

        let entries = Self.entryMap(try await Archive.open(at: out))
        #expect(entries["a.txt"]?.isDirectory == true)
        #expect(entries["a.txt/inner.txt"]?.isDirectory == false)
        #expect(try Self.rawHeaders(out).filter { $0.path == "a.txt" }.count == 1)
    }

    @Test(arguments: sourceFormats)
    func saveInPlaceSourceEqualsDestination(_ format: ArchiveFormat) async throws {
        let original = try Self.makeSource(format)
        let archive = Self.destination(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: archive)
        let source = try await Archive.open(at: archive)
        let expected = try await Self.contents(of: source).filter { $0.key != "secret.txt" }
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["secret.txt"]),
                                      format: format, to: archive, options: nil)

        #expect(try await Self.contents(of: try await Archive.open(at: archive)) == expected)
        let folder = try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path)
        #expect(folder == [archive.lastPathComponent])
    }

    @Test func convertZipTo7z() async throws {
        let source = try await Archive.open(at: try Self.makeSource(.zip))
        let out = Self.destination("out.7z")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .sevenZip, to: out, options: nil)

        let result = try await Archive.open(at: out)
        #expect(result.format == .sevenZip)
        #expect(Set(result.entries.map(\.path)) == Set(source.entries.map(\.path)))
        #expect(try await Self.contents(of: result) == (try await Self.contents(of: source)))
    }

    /// A single gzip stream has no size in its header; tar and 7z need it before the data, so it is counted.
    @Test(arguments: [ArchiveFormat.tar, .sevenZip, .zip])
    func convertSingleStream(_ format: ArchiveFormat) async throws {
        let fixture = try #require(Corpus.fixtures.first { $0.file == "single/hello.txt.gz" })
        let source = try await Archive.open(at: fixture.url)
        let out = Self.destination("out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: out, options: nil)

        let result = try await Archive.open(at: out)
        #expect(result.entries.map(\.path) == ["hello.txt"])
        let contents = try await Self.contents(of: result), expected = try await Self.contents(of: source)
        #expect(contents.count == 1 && contents == expected)
    }

    @Test func duplicateEntriesCollapseOnRepack() async throws {
        let fixture = try #require(Corpus.fixtures.first { $0.file == "tar/duplicates.tar" })
        let source = try await Archive.open(at: fixture.url)
        let out = Self.destination("out.tar")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .tar, to: out, options: nil)

        let dups = try Self.rawHeaders(out).filter { $0.path == "dup.txt" }
        #expect(dups.count == 1)
        #expect(dups.first?.size == 22, "the last dup.txt (22 bytes) wins")
        #expect(try await Self.contents(of: try await Archive.open(at: out)) == (try await Self.contents(of: source)))
    }

    // MARK: - Encryption

    /// ⌘S on an encrypted zip: options nil keeps the method and the password.
    @Test(arguments: encryptions)
    func cmdSKeepsEncryption(_ encryption: ArchiveEncryption) async throws {
        let source = try await Archive.open(at: try await Self.makeEncryptedZip(encryption), password: "pw")
        #expect(source.encryption == encryption)
        let expected = try await Self.contents(of: source).filter { $0.key != "a.txt" }
        let out = Self.destination("out.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["a.txt"]),
                                      format: .zip, to: out, options: nil)

        #expect(try await Archive.open(at: out).encryption == encryption)
        let reopened = try await Archive.open(at: out, password: "pw")
        #expect(reopened.encryption == encryption)
        #expect(try await Self.contents(of: reopened) == expected)

        let wrong = await outcome { _ = try await Archive.open(at: out, password: "nope") }
        if encryption == .zipCrypto, wrong == .ok {
            // ZipCrypto checks one header byte: 1 wrong password in 256 passes open(); extracting must still fail.
            let opened = try await Archive.open(at: out, password: "nope")
            var leaked = false
            let extracted = await outcome {
                let url = try await opened.extractToTemporaryFile("secret.txt")
                leaked = Fixtures.sha256(url) == expected["secret.txt"]
            }
            #expect(matches(extracted, "error"))
            #expect(!leaked)
        } else {
            #expect(matches(wrong, "wrongPassword"), "open with a wrong password: \(wrong)")
        }
    }

    @Test func saveAsCanDropEncryption() async throws {
        let source = try await Archive.open(at: try await Self.makeEncryptedZip(.aes256), password: "pw")
        let out = Self.destination("out.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .zip, to: out,
                                      options: ArchiveWriteOptions())

        let result = try await Archive.open(at: out)
        #expect(result.isEncrypted == false)
        #expect(result.encryption == .none)
        #expect(try await Self.contents(of: result) == (try await Self.contents(of: source)))
    }

    @Test func encryptedSourceWithoutPasswordThrows() async throws {
        let source = try await Archive.open(at: try await Self.makeEncryptedZip(.aes256))
        let out = Self.destination("out.zip")
        let result = await outcome {
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["a.txt"]),
                                          format: .zip, to: out, options: ArchiveWriteOptions())
        }
        #expect(matches(result, "passwordRequired"), "\(result)")
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - A failed save keeps the original

    @Test(arguments: sourceFormats)
    func failedSaveLeavesOriginalIntact(_ format: ArchiveFormat) async throws {
        let archive = Self.destination("src.\(format.fileExtension)")
        try FileManager.default.copyItem(at: try Self.makeSource(format), to: archive)
        let folder = archive.deletingLastPathComponent()
        let before = Fixtures.sha256(archive)
        let source = try await Archive.open(at: archive)
        let missing = Fixtures.tempDir().appending(path: "gone.txt")

        let result = await outcome {
            try await ArchiveWriter.write(
                source: source,
                changes: ArchiveChangeSet(removedPaths: ["a.txt"], additions: [Self.adding(missing, into: "")]),
                format: format, to: archive, options: nil)
        }
        guard case .failed(ArchiveError.io) = result else { Issue.record("expected .io, got \(result)"); return }
        #expect(Fixtures.sha256(archive) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [archive.lastPathComponent])
    }

    @Test(arguments: sourceFormats)
    func unwritableDestinationLeavesOriginalIntact(_ format: ArchiveFormat) async throws {
        guard geteuid() != 0 else { return }
        let archive = Self.destination("src.\(format.fileExtension)")
        try FileManager.default.copyItem(at: try Self.makeSource(format), to: archive)
        let folder = archive.deletingLastPathComponent()
        let before = Fixtures.sha256(archive)
        let source = try await Archive.open(at: archive)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let result = await outcome {
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["a.txt"]),
                                          format: format, to: archive, options: nil)
        }
        guard case .failed(ArchiveError.io) = result else { Issue.record("expected .io, got \(result)"); return }
        #expect(Fixtures.sha256(archive) == before)
    }

    /// Cancelled while the copy step streams a large kept entry (no additions).
    @Test func cancelledSaveLeavesOriginalIntact() async throws {
        let input = Fixtures.tempDir()
        let big = input.appending(path: "big.bin")
        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        for _ in 0..<32 { try handle.write(contentsOf: block) }
        try handle.close()
        let archive = Self.destination("big.zip")
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: [Self.adding(big, into: "")]),
                                      format: .zip, to: archive, options: ArchiveWriteOptions(method: .store))
        let before = Fixtures.sha256(archive)
        let source = try await Archive.open(at: archive)

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var task: Task<Void, any Error>?
            var cancelled = false
        }
        let box = Box()
        let task = Task {
            try await ArchiveWriter.write(
                source: source, changes: ArchiveChangeSet(), format: .zip, to: archive, options: nil,
                progress: { fraction, _ in
                    box.lock.lock(); defer { box.lock.unlock() }
                    guard fraction > 0, !box.cancelled, let task = box.task else { return }
                    box.cancelled = true
                    task.cancel()
                })
        }
        box.lock.withLock { box.task = task }
        let result = await task.result
        #expect(box.lock.withLock { box.cancelled })
        guard case .failure(ArchiveError.cancelled) = result else { Issue.record("expected .cancelled, got \(result)"); return }
        #expect(Fixtures.sha256(archive) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path)
                == [archive.lastPathComponent])
    }

    // MARK: - Hardlinks

    @Test(arguments: [ArchiveFormat.tar, .zip])
    func hardlinkKeptWhenTargetRemoved(_ format: ArchiveFormat) async throws {
        let fixture = try #require(Corpus.fixtures.first { $0.file == "tar/links.tar" })
        let source = try await Archive.open(at: fixture.url)
        let hello = try #require(try await Self.contents(of: source)["hello.txt"])

        let removed = Self.destination("removed.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["hello.txt"]),
                                      format: format, to: removed, options: nil)
        let link = try #require(try Self.rawHeaders(removed).first { $0.path == "hardlink-to-hello" })
        #expect(link.hardlink == nil && link.isRegular && link.size == 15)
        let removedContents = try await Self.contents(of: try await Archive.open(at: removed))
        #expect(removedContents["hardlink-to-hello"] == hello)
        #expect(removedContents["hello.txt"] == nil)

        let kept = Self.destination("kept.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: kept, options: nil)
        let keptLink = try #require(try Self.rawHeaders(kept).first { $0.path == "hardlink-to-hello" })
        if format == .tar {
            #expect(keptLink.hardlink == "hello.txt")
        } else {
            // Zip has no hardlinks: the link becomes a regular file with the target's bytes.
            #expect(keptLink.hardlink == nil && keptLink.size == 15)
        }
        let keptContents = try await Self.contents(of: try await Archive.open(at: kept))
        #expect(keptContents["hardlink-to-hello"] == hello && keptContents["hello.txt"] == hello)
    }

    /// cpio newc keeps a hardlink group's bytes on its LAST member; every member must come out with them.
    @Test(arguments: [false, true])
    func cpioHardlinkGroupKeepsData(removingFirst: Bool) async throws {
        let dir = Fixtures.tempDir()
        let bytes = Data("shared bytes of a hardlink group\n".utf8)
        Fixtures.makeFiles(["f": bytes, "other.txt": Data("other\n".utf8)], in: dir)
        try FileManager.default.linkItem(at: dir.appending(path: "f"), to: dir.appending(path: "g"))
        try FileManager.default.linkItem(at: dir.appending(path: "f"), to: dir.appending(path: "h"))
        try Fixtures.bsdtar(["-cf", "src.cpio", "--format", "newc", "--no-mac-metadata", "f", "g", "h", "other.txt"], cwd: dir)
        let raw = try Self.rawHeaders(dir.appending(path: "src.cpio"))
        #expect(raw.first { $0.path == "f" }?.size == 0, "newc should put the data on the last link")

        let source = try await Archive.open(at: dir.appending(path: "src.cpio"))
        let out = Self.destination("out.tar")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: removingFirst ? ["f"] : []),
                                      format: .tar, to: out, options: nil)

        let contents = try await Self.contents(of: try await Archive.open(at: out))
        let sha = Fixtures.sha256(dir.appending(path: "f"))
        for member in removingFirst ? ["g", "h"] : ["f", "g", "h"] {
            #expect(contents[member] == sha, "\(member)")
        }
        #expect(removingFirst ? contents["f"] == nil : true)
        #expect(contents["other.txt"] != nil)
    }

    // MARK: - macOS metadata

    @Test func finderZipRepackKeepsMacOSMetadata() async throws {
        let zip = try Self.makeDittoZip(folder: "Proj", files: ["hello.txt": Data("hello\n".utf8),
                                                                "docs/readme.md": Data("readme\n".utf8)])
        let source = try await Archive.open(at: zip)
        let metadata = source.entries.filter { $0.path.hasPrefix("__MACOSX/") && !$0.isDirectory }
        #expect(metadata.count >= 2, "ditto wrote no companions: \(source.entries.map(\.path))")
        let out = Self.destination("out.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["Proj/hello.txt"]),
                                      format: .zip, to: out, options: nil)

        let result = try await Archive.open(at: out)
        let after = Self.entryMap(result)
        let beforeContents = try await Self.contents(of: source), afterContents = try await Self.contents(of: result)
        for entry in metadata {
            #expect(after[entry.path]?.size == entry.size, "\(entry.path) size")
            #expect(afterContents[entry.path] != nil && afterContents[entry.path] == beforeContents[entry.path],
                    "\(entry.path) bytes")
        }
    }

    @Test func macOSCompanionsFindsAllThree() {
        let paths = ["d", "d/f.txt", "d/._f.txt", "__MACOSX", "__MACOSX/d", "__MACOSX/d/._f.txt",
                     "__MACOSX/d/f.txt", "__MACOSX/d/f.txt/._inner", "top", "._top", "__MACOSX/top", "__MACOSX/._top"]
        let entries = paths.map {
            ArchiveEntry(path: $0, isDirectory: false, size: 1, compressedSize: nil, modificationDate: nil)
        }
        #expect(Archive.macOSCompanions(of: ["d/f.txt"], in: entries)
                == ["__MACOSX/d/f.txt", "d/._f.txt", "__MACOSX/d/._f.txt"])
        #expect(Archive.macOSCompanions(of: ["top"], in: entries) == ["__MACOSX/top", "._top", "__MACOSX/._top"])
    }

    @Test func macOSCompanionsIgnoresMissing() {
        let entries = ["d", "d/f.txt", "d/._g.txt", "__MACOSX", "__MACOSX/e/._f.txt", "._d.txt"].map {
            ArchiveEntry(path: $0, isDirectory: false, size: 1, compressedSize: nil, modificationDate: nil)
        }
        #expect(Archive.macOSCompanions(of: ["d/f.txt", "d", "missing"], in: entries).isEmpty)
        #expect(Archive.macOSCompanions(of: [], in: entries).isEmpty)
    }

    /// A nested `__MACOSX` is metadata (hidden, stripped) but holds no companions: Finder, ditto and Archive
    /// Utility write and read AppleDouble files only under the root `__MACOSX`, so `a/__MACOSX/._p.jpg` (a foreign
    /// extraction zipped again) is never paired with `a/p.jpg`. Root companions are found as before.
    @Test func macOSCompanionsIgnoreNestedMACOSX() {
        let paths = ["a", "a/p.jpg", "a/__MACOSX", "a/__MACOSX/._p.jpg", "a/__MACOSX/p.jpg", "a/__MACOSX/a/._p.jpg",
                     "x/__MACOSX/a/._p.jpg", "__MACOSX", "__MACOSX/a", "__MACOSX/a/._p.jpg"]
        let entries = paths.map {
            ArchiveEntry(path: $0, isDirectory: false, size: 1, compressedSize: nil, modificationDate: nil)
        }
        #expect(Archive.macOSCompanions(of: ["a/p.jpg"], in: entries) == ["__MACOSX/a/._p.jpg"])
        #expect(Archive.macOSCompanions(of: ["a"], in: entries) == ["__MACOSX/a"])
    }

    @Test func removingFolderWithCompanionsLeavesNoOrphans() async throws {
        let zip = try Self.makeDittoZip(folder: "d", files: ["one.txt": Data("one\n".utf8), "sub/two.txt": Data("two\n".utf8)])
        let source = try await Archive.open(at: zip)
        let companions = Archive.macOSCompanions(of: ["d"], in: source.entries)
        #expect(!companions.isEmpty, "\(source.entries.map(\.path))")
        let out = Self.destination("out.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: companions.union(["d"])),
                                      format: .zip, to: out, options: nil)

        let left = try await Archive.open(at: out).entries.map(\.path)
        #expect(left.allSatisfy { path in !path.split(separator: "/").contains { $0 == "d" || $0 == "._d" } },
                "orphans: \(left)")
    }
}
