// Corpus-wide (manifest-driven) checks of `ArchiveWriter.writeVolumes`.
// Reuses the corpus helpers from FixtureTests.swift (Corpus, Fixture, checking), the row set of DataSafetyTests'
// "Repack keeps data" suite (RepackTests.repackable) and MacMetadataCorpusTests.options (the explicit options an
// app passes for a save). VolumeWriterTests pin the engine on synthetic input; this file holds corpus rows
// to the split rules, with the manifest (not the engine) as the oracle for paths and bytes and the harness's
// `check_split` as the oracle for the set's shape.
//
// The rules: volume sizes are decimal (1 MB = 1 000 000 B; the FAT32 preset is 4 294 967 295 B); a set has
// at most 999 volumes, more is an error the app turns into "choose a larger volume size"; only ZIP and 7z split
// (0.1.0). The documented names are `<base>.<ext>.001` … with no gaps (a byte split, as 7-Zip's `-v`), and a
// result that fits in one volume is one plain `<base>.<ext>`.
//
// Sizes below the 1 MB minimum go through the internal `VolumeWriter.write` (the public call refuses them up
// front): that is how a 70 KB corpus row gets volume boundaries inside its data and headers, and how the 999 cap
// is reached without writing a gigabyte.
//
// Runtime: the suite runs beside the timing tests of the full gate, so it samples instead of sweeping everything
// (one volume size per row, two for a handful; nine look-alike rows left out of the sweep; external tools on one
// size per row) and checks the bytes of a many-entry set in one extraction pass.

import Foundation
import Testing
@testable import KernirCore

@Suite("Split volumes across the corpus",
       .enabled("KernirCore reader not landed yet") { await Corpus.readerAvailable }, .timeLimit(.minutes(3)))
struct SplitVolumeCorpusTests {
    static let mb: Int64 = 1_000_000
    static let fat32: Int64 = 4_294_967_295
    static let base = "Split"

    static let rows = RepackTests.repackable
    /// Rows whose data or archive file is over 1 MB: split at 1 MB through the public call, to ZIP and to 7z.
    static let largeRows = rows.filter { dataBytes($0) > mb || fileBytes($0) > mb }
    /// A few small rows of other kinds (baselines, a converted tar.gz, Unicode names, a solid 7z, symlinks): at
    /// 1 MB each is one plain archive.
    static let smallRowFiles = ["zip/deflate.zip", "7z/lzma2.7z", "tar/basic.tar.gz", "zip/unicode-utf8-flag.zip",
                                "7z/solid.7z", "zip/symlinks.zip"]
    static let smallRows = rows.filter { smallRowFiles.contains($0.file) }
    /// Every repackable row in a splittable format.
    static let volumeRows = rows.filter { (try? format(of: $0))?.supportsVolumes == true }
    static let encryptedVolumeRows = volumeRows.filter(\.encrypted)
    /// Left out of the below-minimum sweep (runtime): legacy-charset ZIPs whose kind the kept rows have (a
    /// same-format split copies the stored names as bytes), and two archive-comment rows the comment test covers.
    /// All unencrypted Deflate ZIPs under 1 KB. Seven `legacy-encoding` ZIPs are skipped, legacy-cp866 among them
    /// (the untagged zip/cp866.zip stays); `sweepCharsetRows` stay, and the row check pins them.
    static let sweepSkipped: Set = ["zip/legacy-cp866.zip", "zip/legacy-koi8r.zip", "zip/legacy-gb18030.zip",
                                    "zip/legacy-big5.zip", "zip/legacy-cp949.zip", "zip/legacy-cp1252.zip",
                                    "zip/legacy-cp1250.zip", "zip/comment-utf8.zip", "zip/comment-utf8-bom.zip"]
    /// The `legacy-encoding` ZIPs the sweep keeps, exactly: cp1251, cp932, and mixed-flagged (bit-11, undeclared
    /// and Unicode-Path names in one archive).
    static let sweepLegacyRows: Set = ["zip/legacy-cp1251.zip", "zip/legacy-cp932.zip", "zip/legacy-mixed-flagged.zip"]
    /// Every charset row the sweep keeps: `sweepLegacyRows` and the untagged cp437 and cp866 ZIPs.
    static let sweepCharsetRows = sweepLegacyRows.union(["zip/cp437.zip", "zip/cp866.zip"])
    /// The sweep's rows: every ZIP and 7z row but `sweepSkipped`, so every encrypted row and every source method.
    static let sweepRows = volumeRows.filter { !sweepSkipped.contains($0.file) }
    /// Sweep rows over 8 KB split at both sizes (the others over 8 KB get ~4 KB volumes only).
    static let bothSizeRows: Set = ["zip/deflate.zip", "zip/zipcrypto.zip", "zip/aes256.zip", "7z/lzma2.7z",
                                    "7z/aes-solid.7z"]
    /// ZIP rows with an archive comment or entry comments, read from one plain file (Python cannot read a set).
    static let commentRows = volumeRows.filter {
        $0.format == ArchiveFormat.zip.rawValue && $0.volumes == nil && ($0.comment != nil || $0.entryComments != nil)
    }

    static func dataBytes(_ fixture: Fixture) -> Int64 {
        fixture.entries.reduce(0) { $0 + (($1.size ?? nil) ?? 0) }
    }

    static func fileBytes(_ fixture: Fixture) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: fixture.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func format(of fixture: Fixture) throws -> ArchiveFormat {
        try #require(fixture.format.flatMap(ArchiveFormat.init(rawValue:)), "\(fixture.file) has no format")
    }

    // MARK: - Writing

    /// A save's explicit options (MacMetadataCorpusTests.options: the source's method, encryption and password),
    /// `method` overriding the source's when given.
    static func options(_ source: any ArchiveReading, _ fixture: Fixture, to format: ArchiveFormat,
                        method: ArchiveCompressionMethod? = nil, volumeSize: Int64?,
                        excludes: Bool = false) -> ArchiveWriteOptions {
        var options = MacMetadataCorpusTests.options(source, fixture, to: format, excludes: excludes)
        if let method { options.method = method }
        options.volumeSize = volumeSize
        return options
    }

    /// The single-file archive `write` makes with the same options. A split set drops the archive comment and
    /// `write` cannot drop it yet (`.remove` is pending), so for a ZIP row with an archive comment the
    /// oracle is the split writer's own unsplit output (nil volume size: one plain file, no comment).
    static func single(_ source: any ArchiveReading, _ fixture: Fixture, to format: ArchiveFormat,
                       options: ArchiveWriteOptions, in scratch: SplitScratch) async throws -> URL {
        var options = options
        options.volumeSize = nil
        let folder = try scratch.subdirectory("single")
        if fixture.comment != nil && format.supportsComments {
            let urls = try splitBelowMinimum(source, to: format, options: options, into: folder, volumeSize: nil)
            return try #require(urls.count == 1 ? urls.first : nil, "\(fixture.file): unsplit write gave \(urls)")
        }
        let out = folder.appending(path: "single.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: out,
                                      options: options)
        return out
    }

    /// The internal split writer at any size (the public call's refusals do not apply), as `writeVolumes` calls it.
    static func splitBelowMinimum(_ source: any ArchiveReading, to format: ArchiveFormat, options: ArchiveWriteOptions,
                                  into folder: URL, volumeSize: Int64?) throws -> [URL] {
        let resolved = try ResolvedWriteOptions.resolve(
            options, format: format, sourceFormat: source.format, sourceEncryption: source.encryption,
            sourceMethod: source.compressionMethod, sourcePassword: (source as? LibArchiveReader)?.password)
        return try VolumeWriter.write(source: source, changes: ArchiveChangeSet(), format: format, into: folder,
                                      baseName: base, options: resolved, volumeSize: volumeSize, progress: nil)
    }

    // MARK: - Checks

    /// `check_split` in Swift: the folder holds exactly the returned set; a lone volume is `<base>.<ext>` of at
    /// most `volumeSize` bytes; a set is `<base>.<ext>.001` … `.NNN` with no gap, at most 999 parts, every part
    /// but the last exactly `volumeSize` bytes and the last 1 … `volumeSize`.
    static func checkShape(_ urls: [URL], in folder: URL, format: ArchiveFormat, volumeSize: Int64,
                           _ label: String) throws {
        let names = urls.map(\.lastPathComponent)
        #expect(APIBatchTests.contents(folder) == names.sorted(), "\(label): folder holds more than the set")
        #expect(urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL },
                "\(label): a volume outside the folder")
        let sizes = try urls.map(WriterTests.size)
        let ext = format.fileExtension
        if urls.count == 1 {
            #expect(names == ["\(base).\(ext)"], "\(label): a lone volume is named \(names)")
        } else {
            #expect(names == (1...urls.count).map { String(format: "\(base).\(ext).%03d", $0) },
                    "\(label): names \(names.prefix(3))…\(names.suffix(2))")
            #expect(urls.count <= 999, "\(label): \(urls.count) volumes")
            for (name, size) in zip(names, sizes).dropLast() where size != volumeSize {
                Issue.record("\(label): \(name) is \(size) B, not \(volumeSize)")
            }
        }
        let last = try #require(sizes.last)
        #expect(last > 0 && last <= volumeSize, "\(label): last part \(last) B, volume \(volumeSize)")
    }

    /// Reopens the set from its first volume and checks it against the manifest: the reader sees every volume,
    /// the entry list is the row's less `excluded` (when the manifest has it all), no excluded path is listed,
    /// each entry keeps its kind, and each file's bytes equal the manifest's sha256 (`checkBytes`).
    static func checkEntries(_ urls: [URL], _ fixture: Fixture, password: String?, excluded: Set<String> = [],
                             _ label: String) async throws {
        let set = try await Archive.open(at: try #require(urls.first), password: password)
        #expect(set.volumeURLs.map(\.lastPathComponent) == urls.map(\.lastPathComponent), "\(label): volumes")
        if password != nil {
            #expect(set.isEncrypted, "\(label): the set is not encrypted")
            if set.format == .sevenZip {
                await #expect(throws: ArchiveError.passwordRequired, "\(label): opens without the password") {
                    _ = try await Archive.open(at: urls[0])
                }
            }
        }
        let listed = Dictionary(set.entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        for path in excluded.sorted() where listed[path] != nil {
            Issue.record("\(label): \(path) is Mac metadata and still listed")
        }
        let kept = fixture.entries.filter { !excluded.contains($0.path) }
        if fixture.entriesComplete {
            let want = Set(kept.map(\.path)), got = Set(listed.keys)
            #expect(got == want, "\(label): lost \(want.subtracting(got).sorted()), gained \(got.subtracting(want).sorted())")
        }
        for entry in kept {
            #expect(listed[entry.path]?.isDirectory == entry.dir, "\(label): \(entry.path) missing or wrong kind")
        }
        try await checkBytes(set, kept, label)
    }

    /// Each file's bytes against the manifest's sha256, one entry at a time (`extractToTemporaryFile`, so case-fold
    /// twins cannot collide). That rescans the set for every entry, quadratic in a many-entry row (30 s for
    /// many-entries.zip in 413 volumes), so a row of over 32 files whose paths stay distinct under case folding
    /// and hold no Mac metadata (which an extraction could fold into a neighbour) is extracted in one pass.
    static func checkBytes(_ set: any ArchiveReading, _ entries: [Fixture.Entry], _ label: String) async throws {
        let files = entries.filter { !$0.dir && $0.symlink == nil && $0.sha256 != nil && $0.corruptData != true }
        let onePass = files.count > 32 && Set(entries.map { $0.path.lowercased() }).count == entries.count
            && !entries.contains { MacMetadataRuling.isMetadata($0.path) }
        guard onePass else {
            for entry in files {
                let file = try await set.extractToTemporaryFile(entry.path)
                #expect(Fixtures.sha256(file) == entry.sha256, "\(label): \(entry.path) bytes")
            }
            return
        }
        let scratch = try SplitScratch()
        defer { scratch.remove() }
        let out = try scratch.subdirectory("x")
        try await set.extract(files.map(\.path), to: out, progress: nil)
        for entry in files {
            #expect(Fixtures.sha256(out.appending(path: entry.path)) == entry.sha256, "\(label): \(entry.path) bytes")
        }
    }

    /// External readers: `7zz t` from the first volume (a split 7z has no other single-file tool), and for a ZIP
    /// `unzip -t` on the joined copy (`joined`, all volumes in order), as `check_split` does. AES ZIP sets are
    /// checked with 7zz only: Info-ZIP's unzip cannot decrypt WinZip AES.
    static func checkWithTools(_ urls: [URL], joined: Data, format: ArchiveFormat, encryption: ArchiveEncryption,
                               password: String?, scratch: SplitScratch, _ label: String) throws {
        if let sevenZip = try Tool.optional(Tool.sevenZip, "7-Zip") {
            let run = try Tool.run(sevenZip, ["t", "-bd"] + (password.map { ["-p" + $0] } ?? []) + [urls[0].path])
            #expect(run.status == 0, "\(label): 7zz t: \(run.stderr)\(String(decoding: run.stdout, as: UTF8.self).suffix(400))")
        }
        guard format == .zip, encryption == .none || encryption == .zipCrypto,
              let unzip = try Tool.optional(Tool.unzip, "unzip") else { return }
        var file = urls[0]
        if urls.count > 1 {
            file = try scratch.subdirectory("joined-\(UUID().uuidString)").appending(path: "\(base).zip")
            try joined.write(to: file)
        }
        let run = try Tool.run(unzip, ["-t"] + (password.map { ["-P", $0] } ?? []) + [file.path])
        // Info-ZIP exits 1 (a warning) for a ZIP with no entries.
        let empty = run.status == 1 && (run.stderr + String(decoding: run.stdout, as: UTF8.self)).contains("zipfile is empty")
        #expect(run.status == 0 || empty, "\(label): unzip -t: \(run.stderr)\(String(decoding: run.stdout, as: UTF8.self).suffix(400))")
    }

    /// The volumes' bytes, in order: the set as one file.
    static func join(_ urls: [URL]) throws -> Data {
        var joined = Data()
        for url in urls { joined.append(try Data(contentsOf: url)) }
        return joined
    }

    /// Shape, manifest (less `excluded`), tools (when `tools`) and (unencrypted: the bytes are deterministic) the
    /// joined set equals `single`.
    static func checkSet(_ urls: [URL], in folder: URL, _ fixture: Fixture, format: ArchiveFormat,
                         options: ArchiveWriteOptions, volumeSize: Int64, single: URL?, tools: Bool = true,
                         excluded: Set<String> = [], scratch: SplitScratch) async throws {
        let label = "\(fixture.file) → \(format.fileExtension) @ \(volumeSize) B"
        try checkShape(urls, in: folder, format: format, volumeSize: volumeSize, label)
        let password = options.encryption == .none ? nil : options.password
        try await checkEntries(urls, fixture, password: password, excluded: excluded, label)
        let joined = try join(urls)
        if tools {
            try checkWithTools(urls, joined: joined, format: format, encryption: options.encryption,
                               password: password, scratch: scratch, label)
        }
        if let single, options.encryption == .none {
            #expect(joined == (try Data(contentsOf: single)), "\(label): the joined set is not the single-file archive")
        }
    }

    // MARK: - Rulings and row sets

    @Test func ownerRulings() {
        #expect(ArchiveWriteOptions.minimumVolumeSize == Self.mb, "1 MB is 1 000 000 B")
        #expect(ArchiveWriteOptions.maximumVolumeCount == 999)
        #expect(ArchiveFormat.allCases.filter(\.supportsVolumes) == [.zip, .sevenZip])
    }

    @Test func corpusHasTheRowsThisSuiteNeeds() {
        guard Corpus.manifest != nil else { return }
        #expect(Self.largeRows.count >= 2, "large rows: \(Self.largeRows.map(\.file))")
        #expect(Self.largeRows.contains { Self.dataBytes($0) > 3 * Self.mb }, "no row splits into 3+ volumes at 1 MB")
        #expect(Self.smallRows.count == Self.smallRowFiles.count,
                "missing small rows: \(Set(Self.smallRowFiles).subtracting(Self.smallRows.map(\.file)).sorted())")
        #expect(Self.encryptedVolumeRows.count >= 3, "encrypted rows: \(Self.encryptedVolumeRows.map(\.file))")
        // The sweep's sample leaves out only unencrypted legacy-charset and comment look-alikes, and keeps both kinds.
        let skipped = Self.volumeRows.filter { Self.sweepSkipped.contains($0.file) }
        #expect(skipped.count == Self.sweepSkipped.count,
                "stale sweepSkipped: \(Self.sweepSkipped.subtracting(skipped.map(\.file)).sorted())")
        for row in skipped {
            #expect(!row.encrypted && Self.fileBytes(row) < 1_024
                        && (row.tags.contains("legacy-encoding") || Self.commentRows.contains { $0.file == row.file }),
                    "\(row.file) must not be left out of the sweep")
        }
        // Exactly these legacy-encoding rows stay (a skipped one fails here), and the untagged cp437/cp866 ZIPs too.
        let sweptLegacy = Set(Self.sweepRows.filter { $0.tags.contains("legacy-encoding") }.map(\.file))
        #expect(sweptLegacy == Self.sweepLegacyRows, "legacy-charset rows in the sweep: \(sweptLegacy.sorted())")
        let sweptFiles = Set(Self.sweepRows.map(\.file))
        #expect(Self.sweepCharsetRows.isSubset(of: sweptFiles),
                "charset rows not in the sweep: \(Self.sweepCharsetRows.subtracting(sweptFiles).sorted())")
        #expect(Self.encryptedVolumeRows.allSatisfy { row in Self.sweepRows.contains { $0.file == row.file } })
        #expect(Self.bothSizeRows.allSatisfy { file in Self.sweepRows.contains { $0.file == file } },
                "bothSizeRows: \(Self.bothSizeRows.sorted())")
        #expect(Self.commentRows.contains { $0.comment != nil && $0.entryComments != nil },
                "no row with an archive comment and entry comments: \(Self.commentRows.map(\.file))")
    }

    /// Refusals of the public call on a corpus row, before anything is written: a volume size one byte under the
    /// 1 MB minimum is `.io`, a format without volumes (tar) is `.unsupportedFormat`.
    @Test func publicCallRefusesBelowTheMinimumAndTar() async throws {
        let fixture = try #require(Self.rows.first { $0.file == "zip/deflate.zip" })
        await checking(fixture) {
            let scratch = try SplitScratch()
            defer { scratch.remove() }
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            let folder = try scratch.subdirectory("out")
            await WriterTests.expectIOError {
                try await ArchiveWriter.writeVolumes(
                    source: source, changes: ArchiveChangeSet(), format: .zip, into: folder, baseName: Self.base,
                    options: Self.options(source, fixture, to: .zip, volumeSize: Self.mb - 1))
            }
            await WriterTests.expectThrows(.unsupportedFormat) {
                try await ArchiveWriter.writeVolumes(
                    source: source, changes: ArchiveChangeSet(), format: .tar, into: folder, baseName: Self.base,
                    options: Self.options(source, fixture, to: .tar, volumeSize: Self.mb))
            }
            #expect(APIBatchTests.contents(folder) == [], "a refused call wrote into the folder")
        }
    }

    // MARK: - 1 MB through the public call

    /// Large rows, stored (so the data really splits) at 1 MB, to ZIP and to 7z: the set has the documented shape,
    /// reopens with the manifest's entries and bytes, passes 7-Zip (and unzip on the joined ZIP), and is a byte
    /// split of the single-file archive. A row with over 1 MB of data needs at least two volumes.
    @Test(arguments: largeRows, [ArchiveFormat.zip, .sevenZip])
    func largeRowSplitsAtOneMegabyte(_ fixture: Fixture, _ format: ArchiveFormat) async throws {
        await checking(fixture) {
            let scratch = try SplitScratch()
            defer { scratch.remove() }
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            let options = Self.options(source, fixture, to: format, method: .store, volumeSize: Self.mb)
            let folder = try scratch.subdirectory("out")
            let urls = try await ArchiveWriter.writeVolumes(source: source, changes: ArchiveChangeSet(), format: format,
                                                            into: folder, baseName: Self.base, options: options)
            if Self.dataBytes(fixture) > Self.mb {
                #expect(urls.count >= 2, "\(fixture.file) → \(format.fileExtension): \(urls.count) volume(s)")
            }
            let single = try await Self.single(source, fixture, to: format, options: options, in: scratch)
            try await Self.checkSet(urls, in: folder, fixture, format: format, options: options, volumeSize: Self.mb,
                                    single: single, scratch: scratch)
        }
    }

    /// Small rows at 1 MB or at the FAT32 preset (alternating by row, so both sizes reach both formats): one
    /// plain, valid `Split.<ext>` and nothing else in the folder.
    @Test(arguments: smallRows, [ArchiveFormat.zip, .sevenZip])
    func smallRowIsOnePlainArchive(_ fixture: Fixture, _ format: ArchiveFormat) async throws {
        await checking(fixture) {
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            let index = try #require(Self.smallRowFiles.firstIndex(of: fixture.file))
            for size in [index % 2 == 0 ? Self.mb : Self.fat32] {
                let scratch = try SplitScratch()
                defer { scratch.remove() }
                let options = Self.options(source, fixture, to: format, volumeSize: size)
                let folder = try scratch.subdirectory("out")
                let urls = try await ArchiveWriter.writeVolumes(source: source, changes: ArchiveChangeSet(),
                                                                format: format, into: folder, baseName: Self.base,
                                                                options: options)
                #expect(urls.map(\.lastPathComponent) == ["\(Self.base).\(format.fileExtension)"])
                let single = try await Self.single(source, fixture, to: format, options: options, in: scratch)
                try await Self.checkSet(urls, in: folder, fixture, format: format, options: options, volumeSize: size,
                                        single: single, scratch: scratch)
            }
        }
    }

    // MARK: - Every ZIP and 7z row, below the minimum

    /// The sweep's ZIP and 7z rows (encrypted ones with their own encryption and password), split in their own
    /// format below the minimum (`sweepSizes`): the same shape, manifest and byte-split checks, and exactly
    /// ceil(size / volume) volumes; the external tools run on the first size only. An archive under 100 B is
    /// written at its own size and must come out as one plain file.
    @Test(arguments: sweepRows)
    func everyRowSplitsBelowTheMinimum(_ fixture: Fixture) async throws {
        let format = try Self.format(of: fixture)
        await checking(fixture) {
            let scratch = try SplitScratch()
            defer { scratch.remove() }
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            let options = Self.options(source, fixture, to: format, volumeSize: nil)
            let single = try await Self.single(source, fixture, to: format, options: options, in: scratch)
            let total = try WriterTests.size(single)
            let sizes = Self.sweepSizes(total: total, both: Self.bothSizeRows.contains(fixture.file))
            for (index, size) in sizes.enumerated() {
                let folder = try scratch.subdirectory("out-\(size)")
                let urls = try Self.splitBelowMinimum(source, to: format, options: options, into: folder,
                                                      volumeSize: size)
                let label = "\(fixture.file) @ \(size) B of \(total) B"
                #expect(urls.count == Int((total + size - 1) / size), "\(label): \(urls.count) volume(s)")
                if total >= 100 && size == (total + 2) / 3 { #expect(urls.count == 3, "\(label)") }
                try await Self.checkSet(urls, in: folder, fixture, format: format, options: options, volumeSize: size,
                                        single: single, tools: index == 0, scratch: scratch)
            }
        }
    }

    /// The whole size for an archive under 100 B; three volumes up to 8 KB and over 256 KB (the two rows that big
    /// split at 1 MB in `largeRowSplitsAtOneMegabyte`; at 4 KB they made 400-volume sets); in between ~4 KB
    /// volumes of 4 099 B (boundaries all through data and headers, a ZIP's end record across the last one
    /// included), and with `both` three volumes as well.
    static func sweepSizes(total: Int64, both: Bool) -> [Int64] {
        guard total >= 100 else { return [total] }
        let three = (total + 2) / 3
        guard total > 8_192, total <= 256_000 else { return [three] }
        let small: Int64 = 4_099
        return both ? [small, three] : [small]
    }

    // MARK: - ZIP end record across the last boundary

    /// A ZIP whose last 1 MB volume holds 10 B: its 22 B end-of-central-directory record starts in the volume
    /// before. The set is valid (7-Zip tests it, the joined file passes unzip), and Kernir opens it too (split-eocd):
    /// any Kernir ZIP split whose size is 1 … 21 B past a volume boundary.
    @Test func zipEndRecordAcrossTheLastBoundary() async throws {
        let scratch = try SplitScratch()
        defer { scratch.remove() }
        let input = try scratch.subdirectory("in")
        let changes = ArchiveChangeSet(additions: [.init(sourceURL: input, destinationDirectory: "")])
        let options = ArchiveWriteOptions(method: .store, volumeSize: Self.mb)
        let target = Self.mb + 10
        // Stored, so the archive grows byte for byte with the file: one write to measure, one to land on target.
        var count = Int(Self.mb) - 200
        var total: Int64 = 0
        for attempt in 0..<2 {
            try VolumeWriterTests.noise(count).write(to: input.appending(path: "noise.bin"))
            let probe = try scratch.subdirectory("probe-\(attempt)").appending(path: "p.zip")
            try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: probe,
                                          options: ArchiveWriteOptions(method: .store))
            total = try WriterTests.size(probe)
            count += Int(target - total)
        }
        try #require(total == target, "stored zip is \(total) B, wanted \(target)")
        let folder = try scratch.subdirectory("out")
        let urls = try await ArchiveWriter.writeVolumes(source: nil, changes: changes, format: .zip, into: folder,
                                                        baseName: Self.base, options: options)
        #expect(try urls.map(WriterTests.size) == [Self.mb, 10])
        let sha = Fixtures.sha256(input.appending(path: "noise.bin"))
        if let sevenZip = try Tool.optional(Tool.sevenZip, "7-Zip") {
            #expect(try Tool.run(sevenZip, ["t", "-bd", urls[0].path]).status == 0, "7zz t")
        }
        if let unzip = try Tool.optional(Tool.unzip, "unzip") {
            let joined = try scratch.subdirectory("joined").appending(path: "\(Self.base).zip")
            try Self.join(urls).write(to: joined)
            let run = try Tool.run(unzip, ["-t", joined.path])
            #expect(run.status == 0, "unzip -t on the joined set: \(run.stderr)")
        }
        let set = try await Archive.open(at: urls[0])
        #expect(set.volumeURLs.map(\.lastPathComponent) == urls.map(\.lastPathComponent))
        #expect(Fixtures.sha256(try await set.extractToTemporaryFile("in/noise.bin")) == sha)
    }

    // MARK: - The 999-volume cap

    /// At the smallest volume size whose set fits in 999 volumes the write succeeds and the set checks out; one
    /// byte smaller it needs 1 000+ volumes: `ArchiveVolumeLimitError` with `maximum` 999 (the app's "choose a
    /// larger volume size"), thrown after 999 volumes were written, which are all deleted, leaving
    /// the folder in place and empty.
    /// One case per output format (the cap is the byte sink's, whatever the format; a conversion to 7z was dropped
    /// for runtime: 999-volume sets are the suite's costliest).
    @Test(arguments: [("zip/deflate.zip", ArchiveFormat.zip), ("7z/lzma2.7z", .sevenZip)])
    func theCapIs999Volumes(_ file: String, _ format: ArchiveFormat) async throws {
        let fixture = try #require(Self.rows.first { $0.file == file }, "\(file) is not repackable")
        await checking(fixture) {
            let scratch = try SplitScratch()
            defer { scratch.remove() }
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            let options = Self.options(source, fixture, to: format, volumeSize: nil)
            let single = try await Self.single(source, fixture, to: format, options: options, in: scratch)
            let total = try WriterTests.size(single)
            let fits = (total + 998) / 999
            try #require(fits >= 2, "\(file): \(total) B is too small to reach the cap")

            let ok = try scratch.subdirectory("fits")
            let urls = try Self.splitBelowMinimum(source, to: format, options: options, into: ok, volumeSize: fits)
            #expect(urls.count == Int((total + fits - 1) / fits) && urls.count <= 999, "\(urls.count) volumes")
            try await Self.checkSet(urls, in: ok, fixture, format: format, options: options, volumeSize: fits,
                                    single: single, scratch: scratch)

            let over = try scratch.subdirectory("over")
            do {
                let made = try Self.splitBelowMinimum(source, to: format, options: options, into: over,
                                                      volumeSize: fits - 1)
                Issue.record("\(file) → \(format.fileExtension) @ \(fits - 1) B: \(made.count) volumes, expected the limit error")
            } catch let error as ArchiveVolumeLimitError {
                #expect(error.maximum == 999)
            }
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: over.path, isDirectory: &isDirectory) && isDirectory.boolValue)
            #expect(APIBatchTests.contents(over) == [], "partial volumes left behind")
        }
    }

    // MARK: - Cancel

    /// A large row cancelled during a 1 MB split: `.cancelled`, every volume deleted, the folder kept. Independent
    /// of the progress cadence: the ZIP case cancels at the first progress report that finds a volume on disk
    /// (volumes are created as bytes arrive, and reports keep coming while data is copied) and checks that one
    /// did; if none ever did, the write completes and the test fails rather than passing vacuously. The 7z
    /// writer emits the whole archive at close, so its case cancels at the first report, before any volume
    /// (nothing to delete); the cap test above covers 7z cleanup after a failure.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func cancelledSplitLeavesNoVolumes(_ format: ArchiveFormat) async throws {
        let fixture = try #require(Self.largeRows.max { Self.dataBytes($0) < Self.dataBytes($1) })
        let scratch = try SplitScratch()
        defer { scratch.remove() }
        let source = try await Archive.open(at: fixture.url, password: fixture.password)
        let options = Self.options(source, fixture, to: format, method: .store, volumeSize: Self.mb)
        let folder = try scratch.subdirectory("out")
        let box = ExtractTests.TaskBox()
        let seen = CancelPoint()
        let task = Task {
            _ = try await ArchiveWriter.writeVolumes(source: source, changes: ArchiveChangeSet(), format: format,
                                                     into: folder, baseName: Self.base, options: options) { _, _ in
                guard !seen.isSet else { return }
                let volumes = APIBatchTests.contents(folder)?.count ?? 0
                if format == .sevenZip || volumes > 0 {
                    seen.set(volumes)
                    box.cancel()
                }
            }
        }
        box.set(task)
        await WriterTests.expectThrows(.cancelled) { try await task.value }
        if format == .zip { #expect((seen.volumes ?? 0) > 0, "cancelled before any volume existed") }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(APIBatchTests.contents(folder) == [], "partial volumes left behind")
    }
}

// MARK: - Comments and Mac metadata

extension SplitVolumeCorpusTests {
    #if os(macOS)
    /// The comment rule, read by Python's zipfile (Kernir's reader reports no archive comment on this base,
    /// `Fixture.commentReadPending`, and `ArchiveEntry` has no entry comment): a split save drops the archive
    /// comment and keeps every entry comment byte for byte, the source's as Python reads them. Through the public
    /// call at 1 MB (one plain Split.zip) and the internal writer in three volumes (joined for Python).
    @Test(arguments: commentRows)
    func splitDropsTheArchiveCommentAndKeepsEntryComments(_ fixture: Fixture) async throws {
        await checking(fixture) {
            let scratch = try SplitScratch()
            defer { scratch.remove() }
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            let options = Self.options(source, fixture, to: .zip, volumeSize: Self.mb)
            let plain = try await ArchiveWriter.writeVolumes(
                source: source, changes: ArchiveChangeSet(), format: .zip, into: try scratch.subdirectory("plain"),
                baseName: Self.base, options: options)
            try #require(plain.count == 1, "\(fixture.file): \(plain.count) volumes at 1 MB")
            let total = try WriterTests.size(plain[0])
            let size = (total + 2) / 3
            let urls = try Self.splitBelowMinimum(source, to: .zip, options: options,
                                                  into: try scratch.subdirectory("split"), volumeSize: size)
            #expect(urls.count == 3, "\(fixture.file) @ \(size) B: \(urls.count) volumes")
            let joined = try scratch.subdirectory("joined").appending(path: "\(Self.base).zip")
            try Self.join(urls).write(to: joined)

            let read = try Self.zipComments([fixture.url, plain[0], joined])
            let want = read[0]
            #expect(want.archive.isEmpty == (fixture.comment == nil), "source archive comment vs manifest")
            #expect(want.entries.values.contains { !$0.isEmpty } == (fixture.entryComments != nil),
                    "source entry comments vs manifest")
            for (name, got) in zip(["1 MB, one plain volume", "\(size) B, 3 volumes joined"], read.dropFirst()) {
                let kept = got.archive.count
                #expect(kept == 0, "\(fixture.file) \(name): archive comment kept (\(kept) B), a split set has none")
                #expect(got.entries == want.entries, "\(fixture.file) \(name): entry comments changed")
            }
        }
    }

    /// Each zip's comments as Python's zipfile reads them (`ZipCommentTests.comments`), in one python3 run.
    static func zipComments(_ urls: [URL]) throws -> [ZipCommentTests.Comments] {
        let script = """
            import sys, zipfile
            for path in sys.argv[1:]:
                z = zipfile.ZipFile(path)
                print("=" + z.comment.hex())
                for i in z.infolist():
                    print(i.filename.encode("utf-8").hex() + ":" + i.comment.hex())
            """
        var result: [ZipCommentTests.Comments] = []
        var archive: [UInt8]?
        var entries: [String: [UInt8]] = [:]
        var names: [String] = []
        func flush() {
            if let archive { result.append(.init(archive: archive, entries: entries, names: names)) }
            entries = [:]
            names = []
        }
        for line in try ZipCommentTests.python(script, urls.map(\.path)).split(separator: "\n") {
            if line.hasPrefix("=") {
                flush()
                archive = ZipCommentTests.unhex(line.dropFirst())
            } else {
                let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                let name = String(decoding: ZipCommentTests.unhex(parts[0]), as: UTF8.self)
                names.append(name)
                entries[name] = ZipCommentTests.unhex(parts[1])
            }
        }
        flush()
        try #require(result.count == urls.count, "python3 read \(result.count) of \(urls.count) zips")
        return result
    }
    #endif

    /// `excludesMacMetadata` through the split writer (documented as "exactly as it does in `write`"): a Finder ZIP
    /// and a 7z with Mac junk, and a ZIP with nested `__MACOSX/` folders, at 1 MB (one plain file) and in three
    /// volumes below the minimum, reopen without any metadata path of the rule (MacMetadataRuling) and with every
    /// other entry and its bytes.
    @Test(arguments: ["zip/macos-finder.zip", "7z/macos-junk.7z", "zip/macos-nested-junk.zip"])
    func splitWithExcludesDropsMacMetadata(_ file: String) async throws {
        let fixture = try #require(Self.rows.first { $0.file == file }, "\(file) is not repackable")
        let metadata = MacMetadataRuling.metadata(of: fixture)
        try #require(!metadata.isEmpty, "\(file): no metadata")
        await checking(fixture) {
            let format = try Self.format(of: fixture)
            let scratch = try SplitScratch()
            defer { scratch.remove() }
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            let options = Self.options(source, fixture, to: format, volumeSize: Self.mb, excludes: true)
            let plainFolder = try scratch.subdirectory("plain")
            let plain = try await ArchiveWriter.writeVolumes(source: source, changes: ArchiveChangeSet(), format: format,
                                                             into: plainFolder, baseName: Self.base, options: options)
            try await Self.checkSet(plain, in: plainFolder, fixture, format: format, options: options,
                                    volumeSize: Self.mb, single: nil, tools: false, excluded: metadata, scratch: scratch)
            let total = try WriterTests.size(try #require(plain.first))
            let size = (total + 2) / 3
            let folder = try scratch.subdirectory("split")
            let urls = try Self.splitBelowMinimum(source, to: format, options: options, into: folder, volumeSize: size)
            #expect(urls.count == 3, "\(file) @ \(size) B: \(urls.count) volumes")
            try await Self.checkSet(urls, in: folder, fixture, format: format, options: options, volumeSize: size,
                                    single: plain[0], excluded: metadata, scratch: scratch)
        }
    }
}

/// Where the cancel test cancelled: the number of volumes on disk at that report (nil: not yet).
final class CancelPoint: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int?
    var isSet: Bool { volumes != nil }
    var volumes: Int? { lock.lock(); defer { lock.unlock() }; return count }
    func set(_ n: Int) { lock.lock(); count = n; lock.unlock() }
}

/// A temp folder for one test under the run root (`Fixtures.tempDir()`), removed by the test.
struct SplitScratch {
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

    func remove() { try? FileManager.default.removeItem(at: url) }
}
