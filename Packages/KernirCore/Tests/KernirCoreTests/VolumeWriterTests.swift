import Foundation
import Testing
@testable import KernirCore

/// `ArchiveWriter.writeVolumes` splits the archive `write` would write into `<base>.<ext>.001` … byte
/// volumes (7-Zip's `-v` layout) inside the caller's empty folder.
@Suite("Split into volumes", .timeLimit(.minutes(3)))
struct VolumeWriterTests {
    static let mb: Int64 = ArchiveWriteOptions.minimumVolumeSize

    /// Bytes that do not compress (a fixed xorshift stream, so every run writes the same archive).
    static func noise(_ count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Data {
        var state = seed
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes[i] = UInt8(truncatingIfNeeded: state)
        }
        return Data(bytes)
    }

    /// `in/` with 2.5 MB of noise and two small text files: a little over two volumes of 1 MB.
    static func makeInput(noiseBytes: Int = 2_500_000) -> URL {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles([
            "in/noise.bin": noise(noiseBytes),
            "in/docs/readme.txt": Data("read me\n".utf8),
            "in/Привет.txt": Data("мир".utf8),
        ], in: dir)
        return dir.appendingPathComponent("in")
    }

    static func adding(_ url: URL) -> ArchiveChangeSet {
        ArchiveChangeSet(additions: [.init(sourceURL: url, destinationDirectory: "")])
    }

    static func size(_ url: URL) throws -> Int64 { try WriterTests.size(url) }

    static func joined(_ urls: [URL]) throws -> Data {
        var data = Data()
        for url in urls { data.append(try Data(contentsOf: url)) }
        return data
    }

    // MARK: - Names and sizes

    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func splitsIntoNumberedVolumesOfExactlyVolumeSize(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput()
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: format, into: folder, baseName: "Photos",
            options: ArchiveWriteOptions(method: .store, volumeSize: Self.mb))
        let ext = format.fileExtension
        #expect(urls.map(\.lastPathComponent) == ["Photos.\(ext).001", "Photos.\(ext).002", "Photos.\(ext).003"])
        #expect(urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL })
        #expect(APIBatchTests.contents(folder) == urls.map(\.lastPathComponent))
        let sizes = try urls.map(Self.size)
        #expect(sizes.dropLast().allSatisfy { $0 == Self.mb })
        let last = try #require(sizes.last)
        #expect(last > 0 && last < Self.mb)
    }

    /// The volumes are a plain byte split of the archive `write` writes with the same options.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func joinedVolumesAreTheSingleFileArchive(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput()
        let single = WriterTests.destination("single.\(format.fileExtension)")
        try await ArchiveWriter.write(source: nil, changes: Self.adding(input), format: format, to: single,
                                      options: ArchiveWriteOptions())
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: format, into: folder, baseName: "x",
            options: ArchiveWriteOptions(volumeSize: Self.mb))
        #expect(urls.count > 1)
        #expect(try Self.joined(urls) == (try Data(contentsOf: single)))
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func volumesReopenInKernirWithTheSameEntriesAndContents(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput()
        let single = WriterTests.destination("single.\(format.fileExtension)")
        try await ArchiveWriter.write(source: nil, changes: Self.adding(input), format: format, to: single,
                                      options: ArchiveWriteOptions())
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: format, into: folder, baseName: "Set",
            options: ArchiveWriteOptions(volumeSize: Self.mb))
        let set = try await Archive.open(at: try #require(urls.first))
        #expect(set.volumeURLs.map(\.lastPathComponent) == urls.map(\.lastPathComponent))
        let plain = try await Archive.open(at: single)
        #expect(set.entries.map(\.path).sorted() == plain.entries.map(\.path).sorted())
        let contents = try await WriterRepackTests.contents(of: set)
        #expect(contents == (try await WriterRepackTests.contents(of: plain)))
        #expect(contents["in/noise.bin"] == Fixtures.sha256(input.appendingPathComponent("noise.bin")))
    }

    /// The acceptance criterion's encrypted 7z (names hidden) and an AES zip round-trip through a split.
    @Test(arguments: [(ArchiveFormat.sevenZip, ArchiveEncryption.aes256), (.zip, .aes256)])
    func encryptedSplitRoundTrips(_ format: ArchiveFormat, _ encryption: ArchiveEncryption) async throws {
        let input = Self.makeInput()
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: format, into: folder, baseName: "Secret",
            options: ArchiveWriteOptions(encryption: encryption, password: WriterTests.password, volumeSize: Self.mb))
        #expect(urls.count == 3)
        let set = try await Archive.open(at: urls[0], password: WriterTests.password)
        #expect(set.isEncrypted)
        let contents = try await WriterRepackTests.contents(of: set)
        #expect(contents["in/noise.bin"] == Fixtures.sha256(input.appendingPathComponent("noise.bin")))
        #expect(contents["in/docs/readme.txt"] == Fixtures.sha256(input.appendingPathComponent("docs/readme.txt")))
    }

    /// A repack whose source is itself a split set: the result drops the removed entry and keeps the rest.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func repackOfASplitSetIntoANewSplitSet(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput()
        let first = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: format, into: first, baseName: "One",
            options: ArchiveWriteOptions(volumeSize: Self.mb))
        let source = try await Archive.open(at: urls[1])
        #expect(source.volumeURLs.count == 3)
        let second = APIBatchTests.emptyFolder()
        let again = try await ArchiveWriter.writeVolumes(
            source: source, changes: ArchiveChangeSet(removedPaths: ["in/docs"]), format: .sevenZip, into: second,
            baseName: "Two", options: ArchiveWriteOptions(volumeSize: Self.mb))
        #expect(again.map(\.lastPathComponent) == ["Two.7z.001", "Two.7z.002", "Two.7z.003"])
        var expected = try await WriterRepackTests.contents(of: source)
        expected["in/docs/readme.txt"] = nil
        #expect(try await WriterRepackTests.contents(of: try await Archive.open(at: again[0])) == expected)
        #expect(APIBatchTests.contents(first) == urls.map(\.lastPathComponent))
    }

    // MARK: - One file

    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func anArchiveThatFitsInOneVolumeIsOnePlainFile(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput(noiseBytes: 1000)
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: format, into: folder, baseName: "Small",
            options: ArchiveWriteOptions(volumeSize: Self.mb))
        #expect(urls.map(\.lastPathComponent) == ["Small.\(format.fileExtension)"])
        #expect(APIBatchTests.contents(folder) == ["Small.\(format.fileExtension)"])
        let reader = try await Archive.open(at: urls[0])
        #expect(reader.volumeURLs.count == 1)
        #expect(reader.entries.contains { $0.path == "in/noise.bin" })
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func aNilVolumeSizeWritesOnePlainFile(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput()
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: format, into: folder, baseName: "Whole",
            options: ArchiveWriteOptions(volumeSize: nil))
        #expect(urls.map(\.lastPathComponent) == ["Whole.\(format.fileExtension)"])
        #expect(APIBatchTests.contents(folder) == ["Whole.\(format.fileExtension)"])
        #expect(try Self.size(urls[0]) > 2 * Self.mb)
        let contents = try await WriterRepackTests.contents(of: try await Archive.open(at: urls[0]))
        #expect(contents["in/noise.bin"] == Fixtures.sha256(input.appendingPathComponent("noise.bin")))
    }

    // MARK: - Interop

    /// 7-Zip opens the set from its first volume (`7zz t`) and extracts the same bytes.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func sevenZipOpensTheSet(_ format: ArchiveFormat) async throws {
        guard let tool = try Tool.optional(Tool.sevenZip, "7-Zip") else { return }
        let input = Self.makeInput()
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: format, into: folder, baseName: "Interop",
            options: ArchiveWriteOptions(volumeSize: Self.mb))
        #expect(urls.count == 3)
        let test = try Tool.run(tool, ["t", "-bd", urls[0].path])
        #expect(test.status == 0, "7-Zip t: \(test.stderr)\(String(decoding: test.stdout, as: UTF8.self))")
        let out = Fixtures.tempDir()
        let extract = try Tool.run(tool, ["x", "-bd", "-y", "-o" + out.path, urls[0].path])
        #expect(extract.status == 0, "7-Zip x: \(extract.stderr)")
        #expect(Fixtures.sha256(out.appendingPathComponent("in/noise.bin"))
                == Fixtures.sha256(input.appendingPathComponent("noise.bin")))
    }

    // MARK: - Progress

    @Test func progressIsReportedAndEndsAtOne() async throws {
        let input = Self.makeInput()
        let folder = APIBatchTests.emptyFolder()
        let rec = WriterTests.Recorder()
        _ = try await ArchiveWriter.writeVolumes(
            source: nil, changes: Self.adding(input), format: .zip, into: folder, baseName: "P",
            options: ArchiveWriteOptions(volumeSize: Self.mb)) { f, _ in rec.add(f) }
        let v = rec.all
        #expect(v.count > 2)
        #expect(v.last == 1.0)
        #expect(v.dropLast().allSatisfy { $0 < 1.0 })
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 })
    }

    // MARK: - Failures leave the folder empty

    /// Cancelled halfway, after several volumes exist: they are deleted and the folder stays, empty.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func cancellationDeletesTheVolumesAndKeepsTheFolder(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput(noiseBytes: 8_000_000)
        let folder = APIBatchTests.emptyFolder()
        let box = ExtractTests.TaskBox()
        let task = Task {
            _ = try await ArchiveWriter.writeVolumes(
                source: nil, changes: Self.adding(input), format: format, into: folder, baseName: "C",
                options: ArchiveWriteOptions(method: .store, volumeSize: Self.mb)) { f, _ in
                    if f >= 0.6 { box.cancel() }
                }
        }
        box.set(task)
        await WriterTests.expectThrows(.cancelled) { try await task.value }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(APIBatchTests.contents(folder) == [])
    }

    /// The 7z writer emits the whole archive at close, where no entry loop checks for a cancel: the sink does,
    /// before it writes a byte, so a cancelled save stops there and creates no volume.
    @Test func theSinkStopsWritingOnceCancelled() async throws {
        let folder = APIBatchTests.emptyFolder()
        let task = Task { () -> (Bool, ArchiveError?) in
            let sink = VolumeSink(directory: folder, baseName: "C", fileExtension: "7z",
                                  plan: VolumePlan(volumeSize: Self.mb))
            withUnsafeCurrentTask { $0?.cancel() }
            let ok = Data([1, 2, 3]).withUnsafeBytes { sink.write($0) }
            return (ok, sink.failure)
        }
        let (ok, failure) = await task.value
        #expect(!ok)
        #expect(failure == .cancelled)
        #expect(APIBatchTests.contents(folder) == [])
    }

    /// A cancel seen by the sink is not the volume limit: `exceededVolumeLimit` stays false.
    @Test func aCancelledSinkIsNotTheVolumeLimit() async {
        let folder = APIBatchTests.emptyFolder()
        let task = Task { () -> Bool in
            let sink = VolumeSink(directory: folder, baseName: "C", fileExtension: "7z",
                                  plan: VolumePlan(volumeSize: Self.mb))
            withUnsafeCurrentTask { $0?.cancel() }
            _ = Data([1, 2, 3]).withUnsafeBytes { sink.write($0) }
            return sink.exceededVolumeLimit
        }
        #expect(await task.value == false)
    }

    /// A file error that is not the limit (volume 2 already exists, the sink never writes over a file) throws
    /// `.io`, not `ArchiveVolumeLimitError`. The volumes the sink made are deleted; the other file stays.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func aVolumeFileCollisionThrowsIONotTheLimitError(_ format: ArchiveFormat) throws {
        let input = Self.makeInput()
        let folder = APIBatchTests.emptyFolder()
        let taken = "Clash.\(format.fileExtension).002"
        try Data("mine".utf8).write(to: folder.appendingPathComponent(taken))
        let options = try ResolvedWriteOptions.resolve(ArchiveWriteOptions(method: .store), format: format,
                                                       sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
        do {
            _ = try VolumeWriter.write(source: nil, changes: Self.adding(input), format: format, into: folder,
                                       baseName: "Clash", options: options, volumeSize: Self.mb, progress: nil)
            Issue.record("expected .io")
        } catch ArchiveError.io(let message) {
            #expect(message.contains(taken), "\(message)")
        } catch {
            Issue.record("expected .io, got \(error)")
        }
        #expect(APIBatchTests.contents(folder) == [taken])
    }

    /// More volumes than allowed: refused while writing, after some volumes exist, with `ArchiveVolumeLimitError`
    /// (not an `ArchiveError`, which the apps switch on exhaustively); the volumes written so far are deleted and
    /// the folder stays as the caller made it, empty.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func tooManyVolumesThrowsTheLimitErrorAndLeavesTheFolderEmpty(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput()
        let folder = APIBatchTests.emptyFolder()
        let options = try ResolvedWriteOptions.resolve(ArchiveWriteOptions(), format: format,
                                                       sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
        #expect(throws: ArchiveVolumeLimitError(maximum: 2)) {
            _ = try VolumeWriter.write(source: nil, changes: Self.adding(input), format: format, into: folder,
                                       baseName: "Many", options: options, volumeSize: Self.mb, progress: nil,
                                       maximumVolumeCount: 2)
        }
        #expect(APIBatchTests.contents(folder) == [])
    }

    /// The production limit end to end: tiny volumes (below the public minimum, so only the internal writer takes
    /// them) make a 1.1 MB archive need more than 999; the 999 written are deleted and the error carries 999.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func theDefaultLimitThrowsTheLimitErrorWith999(_ format: ArchiveFormat) async throws {
        let input = Self.makeInput(noiseBytes: 1_100_000)
        let folder = APIBatchTests.emptyFolder()
        let options = try ResolvedWriteOptions.resolve(ArchiveWriteOptions(method: .store), format: format,
                                                       sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
        #expect(throws: ArchiveVolumeLimitError(maximum: 999)) {
            _ = try VolumeWriter.write(source: nil, changes: Self.adding(input), format: format, into: folder,
                                       baseName: "Many", options: options, volumeSize: 1_000, progress: nil)
        }
        #expect(APIBatchTests.contents(folder) == [])
    }

    /// The real limit is 999: the planner refuses byte 999 × volumeSize (the first byte of volume 1000) only.
    @Test func theDefaultLimitIs999Volumes() throws {
        let plan = VolumePlan(volumeSize: Self.mb)
        #expect(plan.maximumCount == 999)
        #expect(try plan.pieces(at: 999 * Self.mb - 1, count: 1) == [.init(volume: 999, offset: Self.mb - 1, range: 0..<1)])
        #expect(throws: ArchiveError.self) { try plan.pieces(at: 999 * Self.mb - 1, count: 2) }
    }

    @Test func aMissingAdditionThrowsIOAndWritesNothing() async {
        let folder = APIBatchTests.emptyFolder()
        let missing = Fixtures.tempDir().appendingPathComponent("nope.txt")
        await WriterTests.expectIOError {
            _ = try await ArchiveWriter.writeVolumes(
                source: nil, changes: Self.adding(missing), format: .zip, into: folder, baseName: "M",
                options: ArchiveWriteOptions(volumeSize: Self.mb))
        }
        #expect(APIBatchTests.contents(folder) == [])
    }

    /// Refused up front, by name. A NUL would otherwise cut the name short at the C call (`a` for `a\0b.zip.001`).
    /// Checked on scalars: a "/" or NUL followed by a combining mark (or a "/" after a Prepend scalar) is part of a
    /// Character that is neither, and must still be refused.
    @Test(arguments: ["", "a/b", "../escape", "a\u{0}b", "\u{0}", "a/\u{301}b", "\u{0}\u{301}", "a\u{600}/b",
                      "a/\u{200D}b"])
    func aBaseNameThatIsNotAFileNameThrowsIO(_ baseName: String) async {
        let input = Self.makeInput(noiseBytes: 10)
        let folder = APIBatchTests.emptyFolder()
        do {
            _ = try await ArchiveWriter.writeVolumes(
                source: nil, changes: Self.adding(input), format: .zip, into: folder, baseName: baseName,
                options: ArchiveWriteOptions(volumeSize: Self.mb))
            Issue.record("expected .io")
        } catch ArchiveError.io(let message) {
            #expect(message.hasSuffix("is not a file name"), "\(message)")
        } catch {
            Issue.record("expected .io, got \(error)")
        }
        #expect(APIBatchTests.contents(folder) == [])
        #expect(APIBatchTests.contents(folder.deletingLastPathComponent()) == ["Split"])
    }

    // MARK: - Comments

    /// `.keep` drops the source's archive comment: no volume set carries one. Entry comments stay.
    @Test func keepDropsTheSourcesArchiveComment() async throws {
        let src = Fixtures.tempDir().appendingPathComponent("src.zip")
        try await ArchiveWriter.write(source: nil, changes: Self.adding(Self.makeInput(noiseBytes: 1_500_000)),
                                      format: .zip, to: src, options: ArchiveWriteOptions(method: .store))
        try ZipCommentTests.annotate(src, comment: Array("archive comment".utf8),
                                     entries: ["in/noise.bin": Array("entry".utf8)])
        #expect(try ZipCommentTests.comments(src).archive == Array("archive comment".utf8))
        let source = try await Archive.open(at: src)
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: source, changes: ArchiveChangeSet(), format: .zip, into: folder, baseName: "K",
            options: ArchiveWriteOptions(method: .store, volumeSize: Self.mb))
        #expect(urls.count == 2)
        let joined = Fixtures.tempDir().appendingPathComponent("joined.zip")
        try Self.joined(urls).write(to: joined)
        let comments = try ZipCommentTests.comments(joined)
        #expect(comments.archive == [])
        #expect(comments.entries["in/noise.bin"] == Array("entry".utf8))
        #expect(try VolumeProbe.zipComment(at: urls[1]) ?? [] == [])
    }

    /// Any comment other than `.keep` is refused by the split writer itself (through `writeVolumes` too, see
    /// `APIBatchTests.writeVolumesRefusesAnyCommentChange`), first:
    /// before the entries are planned, so neither a missing addition nor the 7z format's own comment refusal is
    /// what is reported.
    @Test(arguments: [ArchiveChangeSet.CommentChange.set("x"), .set(""), .remove], [ArchiveFormat.zip, .sevenZip])
    func theSplitWriterRefusesAnyCommentChange(_ comment: ArchiveChangeSet.CommentChange,
                                               format: ArchiveFormat) async throws {
        let input = Self.makeInput(noiseBytes: 10)
        let missing = ArchiveChangeSet.Addition(sourceURL: Fixtures.tempDir().appendingPathComponent("missing.txt"),
                                                destinationDirectory: "")
        let options = try ResolvedWriteOptions.resolve(ArchiveWriteOptions(), format: format,
                                                       sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
        for additions in [Self.adding(input).additions, [missing]] {
            let folder = APIBatchTests.emptyFolder()
            let changes = ArchiveChangeSet(additions: additions, comment: comment)
            #expect(throws: ArchiveError.io("A split archive cannot have a comment")) {
                _ = try VolumeWriter.write(source: nil, changes: changes, format: format, into: folder, baseName: "K",
                                           options: options, volumeSize: Self.mb, progress: nil)
            }
            #expect(APIBatchTests.contents(folder) == [])
        }
    }

    // MARK: - Mac metadata

    /// A source with Mac metadata, repacked into the same format.
    enum MetadataSource: String, CaseIterable, Sendable {
        case junkZip = "zip/macos-junk.zip", junk7z = "7z/macos-junk.7z", finderZip = "zip/macos-finder.zip"
        var format: ArchiveFormat { self == .junk7z ? .sevenZip : .zip }
    }

    /// `excludesMacMetadata` reaches the split writer: a repack of a source holding Mac metadata, plus additions
    /// `.DS_Store`, `._a`, `__MACOSX/x`, `a` and 1.5 MB of noise (so the set has more than one volume) under
    /// `added/`. On, the set holds neither the kept metadata entries nor the added `._a` and `__MACOSX/x`; off, it
    /// keeps both (an added `.DS_Store` is skipped either way). The joined volumes carry the same headers as the
    /// single-file `write` with the same options, so a split save strips exactly what a plain save strips.
    @Test(arguments: MetadataSource.allCases, [true, false])
    func excludesMacMetadataReachesTheSplitWriter(_ source: MetadataSource, excludes: Bool) async throws {
        let oracle = try MacMetadataWriteTests.oracle(source.rawValue)
        // Without metadata in the source, the kept-entry half of the check below would pass vacuously.
        #expect(!oracle.metadata.isEmpty)
        let reader = try await Archive.open(at: Corpus.root.appending(path: source.rawValue))
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles([".DS_Store": Data("ds".utf8), "._a": Data("ad".utf8), "__MACOSX/x": Data("x".utf8),
                            "a": Data("a".utf8), "big.bin": Self.noise(1_500_000)], in: dir)
        // `subpathsOfDirectory`: Foundation's directory listings leave out `._*` names.
        let additions = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
            .filter { !$0.contains("/") }.sorted()
            .map { ArchiveChangeSet.Addition(sourceURL: dir.appending(path: $0), destinationDirectory: "added") }
        #expect(additions.count == 5)
        let changes = ArchiveChangeSet(additions: additions)
        let options = ArchiveWriteOptions(method: .store, excludesMacMetadata: excludes, volumeSize: Self.mb)

        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(source: reader, changes: changes, format: source.format,
                                                        into: folder, baseName: "Meta", options: options)
        #expect(urls.count == 2)

        let added: Set = ["added", "added/a", "added/big.bin"]
        let addedMetadata: Set = ["added/._a", "added/__MACOSX", "added/__MACOSX/x"]
        let want = excludes ? oracle.entries.subtracting(oracle.metadata).union(added)
                            : oracle.entries.union(added).union(addedMetadata)
        let set = try await Archive.open(at: urls[0])
        #expect(Set(set.entries.map(\.path)) == want)

        let joined = Fixtures.tempDir().appending(path: "joined.\(source.format.fileExtension)")
        try Self.joined(urls).write(to: joined)
        let headers = Set(try MacMetadataWriteTests.headerPaths(joined))
        #expect(headers.isDisjoint(with: ["added/.DS_Store"]))
        if excludes {
            #expect(headers.isDisjoint(with: oracle.metadata.union(addedMetadata)), "\(headers.sorted())")
        } else {
            #expect(headers.isSuperset(of: oracle.metadata.union(addedMetadata)), "\(headers.sorted())")
        }
        let single = Fixtures.tempDir().appending(path: "single.\(source.format.fileExtension)")
        try await ArchiveWriter.write(source: reader, changes: changes, format: source.format, to: single,
                                      options: ArchiveWriteOptions(method: .store, excludesMacMetadata: excludes))
        #expect(headers == Set(try MacMetadataWriteTests.headerPaths(single)))

        var wantContents = try await WriterRepackTests.contents(of: reader)
        if excludes { for path in oracle.metadata { wantContents[path] = nil } }
        for name in excludes ? ["a", "big.bin"] : ["a", "big.bin", "._a", "__MACOSX/x"] {
            wantContents["added/\(name)"] = Fixtures.sha256(dir.appending(path: name))
        }
        #expect(try await WriterRepackTests.contents(of: set) == wantContents)
    }

    /// The split writer strips a nested `__MACOSX` tree of the source exactly as the single-file `write` does
    /// (on), and keeps it (off). 1.5 MB of noise in the source makes the set more than one volume.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip], [true, false])
    func theSplitWriterStripsNestedMACOSX(_ format: ArchiveFormat, excludes: Bool) async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let small = ["a/", "a/__MACOSX/", "a/__MACOSX/x", "a/b/__MACOSX/._x", "a/b/__MACOSX/c/d", "a/__MACOSXfoo",
                     "keep.txt"].map { (path: $0, dosTime: t, data: $0.hasSuffix("/") ? [] : Array("data of \($0)".utf8)) }
        let zip = SyntheticZip.write(SyntheticZip.stored(small + [(path: "a/big.bin", dosTime: t,
                                                                   data: Array(Self.noise(1_500_000)))]))
        let reader = try await Archive.open(at: zip)
        let options = ArchiveWriteOptions(method: .store, excludesMacMetadata: excludes, volumeSize: Self.mb)
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(source: reader, changes: ArchiveChangeSet(), format: format,
                                                        into: folder, baseName: "Nested", options: options)
        #expect(urls.count == 2)

        let nested: Set = ["a/__MACOSX", "a/__MACOSX/x", "a/b/__MACOSX", "a/b/__MACOSX/._x", "a/b/__MACOSX/c",
                           "a/b/__MACOSX/c/d"]
        let content: Set = ["a", "a/__MACOSXfoo", "a/big.bin", "keep.txt"]
        let set = try await Archive.open(at: urls[0])
        let listed = Set(set.entries.map(\.path))
        #expect(listed == (excludes ? content : content.union(nested).union(["a/b"])), "\(listed.sorted())")

        let joined = Fixtures.tempDir().appending(path: "joined.\(format.fileExtension)")
        try Self.joined(urls).write(to: joined)
        let headers = Set(try MacMetadataWriteTests.headerPaths(joined))
        let single = Fixtures.tempDir().appending(path: "single.\(format.fileExtension)")
        try await ArchiveWriter.write(source: reader, changes: ArchiveChangeSet(), format: format, to: single,
                                      options: ArchiveWriteOptions(method: .store, excludesMacMetadata: excludes))
        #expect(headers == Set(try MacMetadataWriteTests.headerPaths(single)))
        #expect(excludes ? headers.isDisjoint(with: nested) : headers.isSuperset(of: ["a/__MACOSX/x", "a/b/__MACOSX/._x"]),
                "\(headers.sorted())")
    }

    // MARK: - Planning (pure, no files): FAT32's 4 294 967 295-byte volumes

    static let fat32: Int64 = 4_294_967_295

    @Test func piecesWithinOneVolume() throws {
        let plan = VolumePlan(volumeSize: Self.mb)
        #expect(try plan.pieces(at: 0, count: 10) == [.init(volume: 1, offset: 0, range: 0..<10)])
        #expect(try plan.pieces(at: Self.mb - 10, count: 10) == [.init(volume: 1, offset: Self.mb - 10, range: 0..<10)])
        #expect(try plan.pieces(at: Self.mb, count: 1) == [.init(volume: 2, offset: 0, range: 0..<1)])
        #expect(try plan.pieces(at: 5, count: 0) == [])
    }

    @Test func piecesAcrossVolumeBoundaries() throws {
        let plan = VolumePlan(volumeSize: Self.mb)
        let mb = Int(Self.mb)
        #expect(try plan.pieces(at: Self.mb - 3, count: 2 * mb + 2) == [
            .init(volume: 1, offset: Self.mb - 3, range: 0..<3),
            .init(volume: 2, offset: 0, range: 3..<(mb + 3)),
            .init(volume: 3, offset: 0, range: (mb + 3)..<(2 * mb + 2)),
        ])
    }

    /// FAT32 preset: offsets past 2³², and volume numbers that 32-bit arithmetic would get wrong.
    @Test func fat32PiecesHaveNo32BitOverflow() throws {
        let plan = VolumePlan(volumeSize: Self.fat32)
        #expect(try plan.pieces(at: Self.fat32 - 5, count: 10) == [
            .init(volume: 1, offset: 4_294_967_290, range: 0..<5),
            .init(volume: 2, offset: 0, range: 5..<10),
        ])
        // 2³² is inside volume 2, at offset 1.
        #expect(try plan.pieces(at: 4_294_967_296, count: 1) == [.init(volume: 2, offset: 1, range: 0..<1)])
        // Volume 3 starts at 8 589 934 590 (more than 2³³).
        #expect(try plan.pieces(at: 8_589_934_589, count: 2) == [
            .init(volume: 2, offset: 4_294_967_294, range: 0..<1),
            .init(volume: 3, offset: 0, range: 1..<2),
        ])
        // The last allowed byte, near 4.29 TB, and the first refused one.
        let end = 999 * Self.fat32
        #expect(end == 4_290_672_327_705)
        #expect(try plan.pieces(at: end - 1, count: 1) == [.init(volume: 999, offset: 4_294_967_294, range: 0..<1)])
        #expect(throws: ArchiveError.self) { try plan.pieces(at: end, count: 1) }
    }

    @Test func fat32VolumeCounts() {
        let plan = VolumePlan(volumeSize: Self.fat32)
        #expect(plan.volumeCount(forTotal: 1) == 1)
        #expect(plan.volumeCount(forTotal: Self.fat32) == 1)
        #expect(plan.volumeCount(forTotal: Self.fat32 + 1) == 2)
        #expect(plan.volumeCount(forTotal: 10_000_000_000) == 3)
        #expect(plan.volumeCount(forTotal: 999 * Self.fat32) == 999)
        #expect(plan.volumeCount(forTotal: 999 * Self.fat32 + 1) == 1000)
    }

    @Test func aNilVolumeSizeNeverRollsOver() throws {
        let plan = VolumePlan(volumeSize: nil)
        #expect(try plan.pieces(at: 1 << 40, count: 3) == [.init(volume: 1, offset: 1 << 40, range: 0..<3)])
    }

    @Test func volumeNames() {
        #expect(VolumePlan.name(baseName: "Photos", fileExtension: "7z", volume: 1) == "Photos.7z.001")
        #expect(VolumePlan.name(baseName: "Photos", fileExtension: "zip", volume: 42) == "Photos.zip.042")
        #expect(VolumePlan.name(baseName: "Photos", fileExtension: "zip", volume: 999) == "Photos.zip.999")
    }

    // MARK: - The writer's own byte sink

    /// Exactly one volume's worth of bytes is one volume: the next one opens only when a byte needs it.
    @Test func exactlyOneVolumeOfBytesOpensNoSecondVolume() throws {
        let folder = APIBatchTests.emptyFolder()
        let sink = VolumeSink(directory: folder, baseName: "E", fileExtension: "zip",
                              plan: VolumePlan(volumeSize: Self.mb))
        let data = Self.noise(Int(Self.mb))
        for chunk in stride(from: 0, to: data.count, by: 10240) {
            let ok = data[chunk..<min(chunk + 10240, data.count)].withUnsafeBytes { sink.write($0) }
            #expect(ok)
        }
        let urls = try sink.finish()
        #expect(urls.map(\.lastPathComponent) == ["E.zip"])
        #expect(try Data(contentsOf: urls[0]) == data)
    }

    @Test func oneByteMoreOpensTheSecondVolume() throws {
        let folder = APIBatchTests.emptyFolder()
        let sink = VolumeSink(directory: folder, baseName: "E", fileExtension: "7z", plan: VolumePlan(volumeSize: Self.mb))
        let data = Self.noise(Int(Self.mb) + 1)
        #expect(data.withUnsafeBytes { sink.write($0) })
        let urls = try sink.finish()
        #expect(urls.map(\.lastPathComponent) == ["E.7z.001", "E.7z.002"])
        #expect(try Self.joined(urls) == data)
        #expect(try Self.size(urls[1]) == 1)
    }

    @Test func abandonDeletesEveryVolumeAndRefusesLaterWrites() throws {
        let folder = APIBatchTests.emptyFolder()
        let sink = VolumeSink(directory: folder, baseName: "A", fileExtension: "7z", plan: VolumePlan(volumeSize: Self.mb))
        #expect(Self.noise(Int(Self.mb) * 2 + 7).withUnsafeBytes { sink.write($0) })
        #expect(APIBatchTests.contents(folder)?.count == 3)
        sink.abandon()
        #expect(APIBatchTests.contents(folder) == [])
        #expect(!Data([1, 2, 3]).withUnsafeBytes { sink.write($0) })
        #expect(APIBatchTests.contents(folder) == [])
    }

    /// A volume name that already exists is never overwritten (the folder was checked empty; something put it there).
    @Test func anExistingVolumeFileIsNotOverwritten() throws {
        let folder = APIBatchTests.emptyFolder()
        let sink = VolumeSink(directory: folder, baseName: "O", fileExtension: "7z", plan: VolumePlan(volumeSize: Self.mb))
        let other = folder.appendingPathComponent("O.7z.002")
        FileManager.default.createFile(atPath: other.path, contents: Data("theirs".utf8))
        #expect(!Self.noise(Int(Self.mb) + 10).withUnsafeBytes { sink.write($0) })
        if case .io? = sink.failure {} else { Issue.record("expected an .io failure, got \(String(describing: sink.failure))") }
        sink.abandon()
        #expect(try Data(contentsOf: other) == Data("theirs".utf8))
        #expect(APIBatchTests.contents(folder) == ["O.7z.002"])
    }

    /// A lone volume's final name is never taken from a file that is already there: the name is reserved with
    /// O_EXCL before the rename, so their file stays as it was and the save fails.
    @Test func theSingleVolumeRenameNeverReplacesAFile() throws {
        let folder = APIBatchTests.emptyFolder()
        let sink = VolumeSink(directory: folder, baseName: "R", fileExtension: "zip",
                              plan: VolumePlan(volumeSize: 1_000_000))
        let theirs = folder.appendingPathComponent("R.zip")
        FileManager.default.createFile(atPath: theirs.path, contents: Data("theirs".utf8))
        #expect(Data([1, 2, 3]).withUnsafeBytes { sink.write($0) })
        #expect(throws: ArchiveError.self) { try sink.finish() }
        if case .io? = sink.failure {} else { Issue.record("expected an .io failure, got \(String(describing: sink.failure))") }
        sink.abandon()
        #expect(try Data(contentsOf: theirs) == Data("theirs".utf8))
        #expect(APIBatchTests.contents(folder) == ["R.zip"])
    }

    /// Each volume is closed when the next one opens, and the last one by `finish` or `abandon`: a 999-volume
    /// set never holds 999 descriptors.
    @Test(arguments: [false, true])
    func noVolumeStaysOpen(_ abandons: Bool) throws {
        let folder = APIBatchTests.emptyFolder()
        let sink = VolumeSink(directory: folder, baseName: "F", fileExtension: "7z", plan: VolumePlan(volumeSize: Self.mb))
        #expect(Self.noise(Int(Self.mb) * 3 + 1).withUnsafeBytes { sink.write($0) })
        #expect(APIBatchTests.contents(folder)?.count == 4)
        #expect(Self.openFiles(in: folder).count == 1)
        if abandons { sink.abandon() } else { _ = try sink.finish() }
        #expect(Self.openFiles(in: folder) == [])
    }

    /// This process's open files inside `folder` (each test has its own folder, so parallel tests do not count).
    static func openFiles(in folder: URL) -> [String] {
        let prefix = LibArchiveWriter.canonicalPath(folder) + "/"
        var paths: [String] = []
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [] {
            guard let fd = Int32(name), fcntl(fd, F_GETPATH, &buffer) == 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            if path.hasPrefix(prefix) { paths.append(path) }
        }
        return paths
    }

    /// An error that is not the sink's (an addition that cannot be read) ends the save there. The unfinished
    /// 7z, whose close would write all of it, is not emitted into volumes first, so the volume limit that
    /// emission would hit cannot hide the real error.
    @Test func anEntryErrorIsNotHiddenByTheUnfinishedArchive() throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.bin": Self.noise(3_000_000), "z.bin": Data("locked".utf8)], in: dir)
        let locked = dir.appendingPathComponent("z.bin")
        #expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o644) }
        let folder = APIBatchTests.emptyFolder()
        let options = try ResolvedWriteOptions.resolve(ArchiveWriteOptions(method: .store), format: .sevenZip,
                                                       sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
        // In this order: the 3 MB are staged in the 7z writer when the read fails.
        let changes = ArchiveChangeSet(additions: ["a.bin", "z.bin"].map {
            .init(sourceURL: dir.appendingPathComponent($0), destinationDirectory: "")
        })
        do {
            _ = try VolumeWriter.write(source: nil, changes: changes, format: .sevenZip, into: folder, baseName: "E",
                                       options: options, volumeSize: Self.mb, progress: nil, maximumVolumeCount: 1)
            Issue.record("expected .io")
        } catch ArchiveError.io(let message) {
            #expect(message.contains("z.bin"), "\(message)")
        }
        #expect(APIBatchTests.contents(folder) == [])
    }
}
