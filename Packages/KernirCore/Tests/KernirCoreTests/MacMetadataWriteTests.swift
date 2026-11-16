import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// `ArchiveWriteOptions.excludesMacMetadata`. Additions skip `__MACOSX` folders (with their contents), `._*`
/// and `.DS_Store` by their names on disk, at any depth; kept source entries that are `isMacOSMetadata` (a
/// `__MACOSX` tree at any depth, `._*` names) or named `.DS_Store` are dropped. False and nil options keep today's
/// output.
struct MacMetadataWriteTests {
    static let formats: [ArchiveFormat] = [.zip, .sevenZip, .tar]
    static let on = ArchiveWriteOptions(excludesMacMetadata: true)

    // MARK: Helpers

    /// A folder `proj` with Mac junk at the root and nested, plus loose junk next to it:
    /// `proj/{a, ._a, .DS_Store, __MACOSX/{x, sub/._y}, sub/{b, ._b, .DS_Store, __MACOSX/z, nested/{c, ._c}}}`,
    /// and `._loose`, `__MACOSX/top`, `.DS_Store`, `keep.txt` beside `proj`.
    static func makeJunkTree() -> URL {
        let dir = Fixtures.tempDir()
        let files = ["proj/a", "proj/._a", "proj/.DS_Store", "proj/__MACOSX/x", "proj/__MACOSX/sub/._y",
                     "proj/sub/b", "proj/sub/._b", "proj/sub/.DS_Store", "proj/sub/__MACOSX/z",
                     "proj/sub/nested/c", "proj/sub/nested/._c",
                     "._loose", "__MACOSX/top", ".DS_Store", "keep.txt"]
        Fixtures.makeFiles(Dictionary(uniqueKeysWithValues: files.map { ($0, Data("data of \($0)\n".utf8)) }), in: dir)
        return dir
    }

    /// Every root item of `tree` as its own addition at the archive root. `subpathsOfDirectory`, not
    /// `contentsOfDirectory`: Foundation's directory listings and enumerators leave out every `._*` name.
    static func rootAdditions(_ tree: URL) throws -> [ArchiveChangeSet.Addition] {
        try FileManager.default.subpathsOfDirectory(atPath: tree.path).filter { !$0.contains("/") }.sorted().map {
            .init(sourceURL: tree.appending(path: $0), destinationDirectory: "")
        }
    }

    static func destination(_ format: ArchiveFormat) -> URL {
        Fixtures.tempDir().appending(path: "out.\(format.fileExtension)")
    }

    /// Header paths as stored, in order (no synthesized folders).
    static func headerPaths(_ url: URL) throws -> [String] {
        try WriterRepackTests.rawHeaders(url).map(\.path)
    }

    /// The listing (synthesized folders included).
    static func listing(_ url: URL) async throws -> Set<String> {
        Set(try await Archive.open(at: url).entries.map(\.path))
    }

    struct Row: Decodable {
        struct Entry: Decodable { let path: String }
        let file: String
        let entries: [Entry]
        let macMetadata: [String]?
    }

    /// A manifest row's entry paths and its `macMetadata` oracle.
    static func oracle(_ file: String) throws -> (entries: Set<String>, metadata: Set<String>) {
        struct Manifest: Decodable { let fixtures: [Row] }
        let data = try Data(contentsOf: Corpus.root.appending(path: "manifest.json"))
        let row = try #require(try JSONDecoder().decode(Manifest.self, from: data).fixtures.first { $0.file == file })
        let metadata = try #require(row.macMetadata, "\(file) has no macMetadata")
        return (Set(row.entries.map(\.path)), Set(metadata))
    }

    // MARK: Additions

    /// A temp folder holding `.DS_Store`, `._a`, `__MACOSX/x` and `a` writes only `a`.
    @Test(arguments: formats)
    func additionsFromAJunkFolderWriteOnlyTheFile(_ format: ArchiveFormat) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles([".DS_Store": Data("ds".utf8), "._a": Data("ad".utf8), "__MACOSX/x": Data("x".utf8),
                            "a": Data("a".utf8)], in: dir)
        let out = Self.destination(format)
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: try Self.rootAdditions(dir)),
                                      format: format, to: out, options: Self.on)
        #expect(try Self.headerPaths(out) == ["a"])
    }

    @Test(arguments: formats)
    func additionsSkipMetadataAtEveryDepth(_ format: ArchiveFormat) async throws {
        let tree = Self.makeJunkTree()
        let out = Self.destination(format)
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: try Self.rootAdditions(tree)),
                                      format: format, to: out, options: Self.on)
        let want: Set = ["keep.txt", "proj", "proj/a", "proj/sub", "proj/sub/b", "proj/sub/nested", "proj/sub/nested/c"]
        let headers = try Self.headerPaths(out)
        #expect(Set(headers) == want)
        #expect(headers.count == want.count, "\(headers)")
        // No dropped folder comes back as a synthesized one.
        #expect(try await Self.listing(out) == want)
        let contents = try await WriterRepackTests.contents(of: try await Archive.open(at: out))
        #expect(contents["proj/sub/nested/c"] == Fixtures.sha256(tree.appending(path: "proj/sub/nested/c")))
    }

    /// Today's behavior with the flag off, explicit false or nil options: `.DS_Store` is skipped, and nothing else
    /// by name. `._*` files inside an added folder never reach the walker on macOS (Foundation's enumerator leaves
    /// them out), so only the loose root `._loose` addition shows a `._` file being kept; nested ones are not pinned.
    @Test(arguments: formats, [false, true])
    func additionsWithFlagOffSkipOnlyDSStore(_ format: ArchiveFormat, nilOptions: Bool) async throws {
        let tree = Self.makeJunkTree()
        let out = Self.destination(format)
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: try Self.rootAdditions(tree)),
                                      format: format, to: out,
                                      options: nilOptions ? nil : ArchiveWriteOptions(excludesMacMetadata: false))
        let want: Set = ["._loose", "__MACOSX", "__MACOSX/top", "keep.txt",
                         "proj", "proj/a", "proj/__MACOSX", "proj/__MACOSX/x", "proj/__MACOSX/sub",
                         "proj/sub", "proj/sub/b", "proj/sub/__MACOSX",
                         "proj/sub/__MACOSX/z", "proj/sub/nested", "proj/sub/nested/c"]
        let headers = try Self.headerPaths(out)
        let nestedAppleDouble = headers.filter { $0.contains("/._") }
        #expect(Set(headers).subtracting(nestedAppleDouble) == want, "\(headers.sorted())")
    }

    /// Names on disk match whatever the item is: a file named `__MACOSX`, a folder named `._dir` (Foundation's
    /// enumerator lists `._*` folders, unlike `._*` files) and a `__MACOSX` folder added below the archive root.
    @Test(arguments: [true, false])
    func additionsMatchNamesWhateverTheItemIs(_ excludes: Bool) async throws {
        let tree = Fixtures.tempDir()
        Fixtures.makeFiles(["x/__MACOSX": Data("file".utf8), "x/._dir/inner": Data("i".utf8),
                            "x/keep": Data("k".utf8), "__MACOSX/m": Data("m".utf8)], in: tree)
        let changes = ArchiveChangeSet(additions: [.init(sourceURL: tree.appending(path: "x"), destinationDirectory: ""),
                                                   .init(sourceURL: tree.appending(path: "__MACOSX"),
                                                         destinationDirectory: "d")])
        let out = Self.destination(.zip)
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: out,
                                      options: excludes ? Self.on : nil)
        let want: Set = excludes ? ["x", "x/keep"]
            : ["x", "x/__MACOSX", "x/._dir", "x/._dir/inner", "x/keep", "d", "d/__MACOSX", "d/__MACOSX/m"]
        let headers = try Self.headerPaths(out)
        #expect(Set(headers) == want)
        #expect(headers.count == want.count, "\(headers)")
    }

    /// Pins Foundation's part: its enumerator never lists `._*` files inside an added folder, a stray one with no
    /// data file beside it included, so with the flag off (or nil options) they are not written either. If this
    /// fails, Foundation changed and nested `._*` files now reach the writer when the flag is off.
    @Test func foundationNeverListsAppleDoubleFilesInAFolder() async throws {
        let tree = Fixtures.tempDir()
        Fixtures.makeFiles(["f/._x": Data("stray".utf8), "f/._y": Data("ad".utf8), "f/y": Data("y".utf8),
                            "f/sub/._z": Data("stray".utf8)], in: tree)
        let folder = ArchiveChangeSet.Addition(sourceURL: tree.appending(path: "f"), destinationDirectory: "")
        let walked = try AdditionWalker.items(for: [folder], excludingMacMetadata: false).map(\.archivePath)
        #expect(walked.sorted() == ["f", "f/sub", "f/y"])
        let out = Self.destination(.zip)
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: [folder]), format: .zip,
                                      to: out, options: nil)
        #expect(Set(try Self.headerPaths(out)) == ["f", "f/sub", "f/y"])
    }

    // MARK: In-place saves and edges

    /// With the flag on, a plain in-place save (destination is the source file, as for the app's
    /// plain save) strips metadata from kept entries AND additions, not only Save As or a new file.
    @Test func inPlaceSaveStripsKeptAndAdded() async throws {
        let dir = Fixtures.tempDir()
        let archive = dir.appending(path: "doc.zip")
        try FileManager.default.copyItem(at: Corpus.root.appending(path: "zip/macos-junk.zip"), to: archive)
        let before = try await Self.listing(archive)
        #expect(before.contains { MacOSMetadata.isExcludedEntry(path: $0) }, "fixture has no metadata: \(before.sorted())")
        let tree = Fixtures.tempDir()
        Fixtures.makeFiles(["._direct": Data("ad".utf8), "plain.txt": Data("p".utf8)], in: tree)
        let source = try await Archive.open(at: archive)
        let changes = ArchiveChangeSet(additions: [.init(sourceURL: tree.appending(path: "._direct"), destinationDirectory: ""),
                                                   .init(sourceURL: tree.appending(path: "plain.txt"), destinationDirectory: "")])
        try await ArchiveWriter.write(source: source, changes: changes, format: .zip, to: archive, options: Self.on)
        let paths = try await Self.listing(archive)
        #expect(!paths.contains { MacOSMetadata.isExcludedEntry(path: $0) }, "\(paths.sorted())")
        #expect(paths.contains("plain.txt"))
        #expect(!paths.contains("._direct"))
    }

    /// Kept-entry names: exact, case-sensitive, component-bounded.
    @Test func keptNameEdges() async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let paths = ["._", ".DS_Store.txt", "x.DS_Store", "__MACOSX_old/a.txt", "__macosx/a.txt", ".ds_store",
                     "._e\u{301}.txt", "keep/._", "keep/f.txt", "MACOSX/._a"]
        let zip = SyntheticZip.write(SyntheticZip.stored(paths.map { (path: $0, dosTime: t, data: Array("d \($0)".utf8)) }))
        let source = try await Archive.open(at: zip)
        let out = Fixtures.tempDir().appending(path: "o.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .zip, to: out, options: Self.on)
        let got = try await Self.listing(out)
        let want: Set = [".DS_Store.txt", "x.DS_Store", "__MACOSX_old", "__MACOSX_old/a.txt", "__macosx", "__macosx/a.txt",
                         ".ds_store", "keep", "keep/f.txt"]
        #expect(got == want, "\(got.sorted())")
    }

    /// On-disk names of additions: exact, case-sensitive, no prefix match.
    @Test func diskNameEdges() async throws {
        let tree = Fixtures.tempDir()
        Fixtures.makeFiles(["._e\u{301}": Data("a".utf8), "__MACOSX copy/x": Data("x".utf8), ".DS_Store.txt": Data("d".utf8),
                            "k/__MACOSX/deep": Data("z".utf8), "k/f": Data("f".utf8)], in: tree)
        let roots = try FileManager.default.subpathsOfDirectory(atPath: tree.path).filter { !$0.contains("/") }
        let changes = ArchiveChangeSet(additions: roots.map { .init(sourceURL: tree.appending(path: $0), destinationDirectory: "") })
        let out = Self.destination(.zip)
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: out, options: Self.on)
        let got = Set(try Self.headerPaths(out))
        #expect(got == ["__MACOSX copy", "__MACOSX copy/x", ".DS_Store.txt", "k", "k/f"], "\(got.sorted())")
    }

    /// The name check the walker runs on every addition root and every enumerated child: with the flag a `._*`
    /// name is left out wherever it shows up, so a nested one is dropped too if the enumerator ever lists it.
    @Test func walkerNameCheck() {
        // Matching is case-sensitive: `.ds_store` is an ordinary name, kept with the flag on or off.
        for name in [".ds_store"] {
            #expect(!AdditionWalker.skips(name: name, excludingMacMetadata: false))
            #expect(!AdditionWalker.skips(name: name, excludingMacMetadata: true))
        }
        for name in [".DS_Store"] {
            #expect(AdditionWalker.skips(name: name, excludingMacMetadata: false))
            #expect(AdditionWalker.skips(name: name, excludingMacMetadata: true))
        }
        for name in ["._x", "._", "__MACOSX"] {
            #expect(!AdditionWalker.skips(name: name, excludingMacMetadata: false), "\(name)")
            #expect(AdditionWalker.skips(name: name, excludingMacMetadata: true), "\(name)")
        }
        for name in ["x", "_x", ".x", "MACOSX", "__macosx", ".DS_Store.txt", "a._x"] {
            #expect(!AdditionWalker.skips(name: name, excludingMacMetadata: true), "\(name)")
        }
    }

    /// An addition placed inside a metadata folder of the archive is metadata itself, so the flag leaves it out
    /// (and no `__MACOSX` parent is made for it).
    @Test func additionIntoAMetadataFolderIsLeftOut() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["f.txt": Data("f".utf8)], in: dir)
        let file = dir.appending(path: "f.txt")
        let changes = ArchiveChangeSet(additions: [.init(sourceURL: file, destinationDirectory: "__MACOSX/d"),
                                                   .init(sourceURL: file, destinationDirectory: "d/._x"),
                                                   .init(sourceURL: file, destinationDirectory: "d")])
        let out = Self.destination(.zip)
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: out, options: Self.on)
        #expect(try Self.headerPaths(out) == ["d", "d/f.txt"])
    }

    // MARK: Repack

    enum Repack: String, CaseIterable, Sendable {
        case junkZip, junk7z, bsdtarTar, finderZip, junkZipToTar, junkZipTo7z
        var file: String {
            switch self {
            case .junkZip, .junkZipToTar, .junkZipTo7z: "zip/macos-junk.zip"
            case .junk7z: "7z/macos-junk.7z"
            case .bsdtarTar: "tar/macos-bsdtar.tar"
            case .finderZip: "zip/macos-finder.zip"
            }
        }
        var format: ArchiveFormat {
            switch self {
            case .junkZip, .finderZip: .zip
            case .junk7z, .junkZipTo7z: .sevenZip
            case .bsdtarTar, .junkZipToTar: .tar
            }
        }
    }

    @Test(arguments: Repack.allCases)
    func repackDropsEveryMetadataEntry(_ repack: Repack) async throws {
        let oracle = try Self.oracle(repack.file)
        let source = try await Archive.open(at: Corpus.root.appending(path: repack.file))
        #expect(Set(source.entries.map(\.path)) == oracle.entries)
        let out = Self.destination(repack.format)
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: repack.format, to: out,
                                      options: Self.on)

        let want = oracle.entries.subtracting(oracle.metadata)
        #expect(try await Self.listing(out) == want)
        #expect(Set(try Self.headerPaths(out)).isDisjoint(with: oracle.metadata))
        var wantContents = try await WriterRepackTests.contents(of: source)
        for path in oracle.metadata { wantContents[path] = nil }
        #expect(try await WriterRepackTests.contents(of: try await Archive.open(at: out)) == wantContents)
    }

    /// Flag off (explicit false or nil options): a repack keeps every entry, metadata included, with its bytes.
    @Test(arguments: Repack.allCases, [false, true])
    func repackWithFlagOffKeepsEveryEntry(_ repack: Repack, nilOptions: Bool) async throws {
        let oracle = try Self.oracle(repack.file)
        let source = try await Archive.open(at: Corpus.root.appending(path: repack.file))
        let out = Self.destination(repack.format)
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: repack.format, to: out,
                                      options: nilOptions ? nil : ArchiveWriteOptions(excludesMacMetadata: false))
        #expect(try await Self.listing(out) == oracle.entries)
        #expect(try await WriterRepackTests.contents(of: try await Archive.open(at: out))
                == WriterRepackTests.contents(of: source))
    }

    /// Byte identity with the output before the option existed (sha256 recorded by this test with no engine
    /// change): a same-format repack with nil options or explicit `excludesMacMetadata: false` is unchanged.
    @Test(arguments: [("zip/macos-junk.zip", ArchiveFormat.zip,
                       "f0f8ede0e4b8728933ba290e51daa0ef14f9946a3f387277c005760fc3cfedcf"),
                      ("7z/macos-junk.7z", ArchiveFormat.sevenZip,
                       "5e630b7179e31bcb7210cbd7cb23bce29d5136b855584a00e349caf91ff98e71"),
                      ("tar/macos-bsdtar.tar", ArchiveFormat.tar,
                       "e16f1cccb78004a3d5e111547f321ab09d551f48b675dbcb9bc5733e747c60bf")])
    func repackWithFlagOffIsByteIdenticalToBefore(_ file: String, _ format: ArchiveFormat, _ sha: String) async throws {
        let source = try await Archive.open(at: Corpus.root.appending(path: file))
        for options in [nil, ArchiveWriteOptions(excludesMacMetadata: false)] as [ArchiveWriteOptions?] {
            let out = Self.destination(format)
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["missing"]),
                                          format: format, to: out, options: options)
            #expect(Fixtures.sha256(out) == sha, "\(file) options \(String(describing: options))")
        }
    }

    /// A nested `__MACOSX` folder in a source is metadata like the root one, with everything in
    /// it. Whatever lies beneath a dropped entry goes with it, so a dropped folder never comes back as a synthesized
    /// one; and a folder that only existed implicitly, above a dropped `.DS_Store`, is not generated.
    @Test func repackDropsBeneathDroppedEntriesAndNestedMACOSX() async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let paths = ["d/", "d/__MACOSX/", "d/__MACOSX/x.txt", "d/__MACOSX/._x.txt", "._dir/", "._dir/child.txt",
                     ".DS_Store/", ".DS_Store/inner.txt", "e/.DS_Store", "keep.txt"]
        let zip = SyntheticZip.write(SyntheticZip.stored(paths.map {
            (path: $0, dosTime: t, data: $0.hasSuffix("/") ? [] : Array("data of \($0)".utf8))
        }))
        let source = try await Archive.open(at: zip)
        for format in [ArchiveFormat.zip, .tar] {
            let out = Self.destination(format)
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: out,
                                          options: Self.on)
            let want: Set = ["d", "keep.txt"]
            #expect(Set(try Self.headerPaths(out)) == want, "\(format)")
            #expect(try await Self.listing(out) == want, "\(format)")
        }
    }

    /// Edges for kept source entries: a `__MACOSX` component at any depth goes with everything beneath it, the
    /// folder entry, a folder only implied by its contents and a plain file named `__MACOSX` alike (as at the
    /// root). Whole component only, case-sensitive. Off, every entry is kept.
    @Test(arguments: [ArchiveFormat.zip, .tar, .sevenZip], [true, false])
    func repackNestedMACOSXEdges(_ format: ArchiveFormat, excludes: Bool) async throws {
        let t = SyntheticZip.dosTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        let paths = ["a/", "a/__MACOSX/", "a/__MACOSX/x", "a/b/__MACOSX/._x", "f/", "f/__MACOSX", "__MACOSXfoo/y",
                     "c/foo__MACOSX/z", "c/__macosx/w", "c/__MACOSX_old/v", "keep.txt"]
        let zip = SyntheticZip.write(SyntheticZip.stored(paths.map {
            (path: $0, dosTime: t, data: $0.hasSuffix("/") ? [] : Array("data of \($0)".utf8))
        }))
        let source = try await Archive.open(at: zip)
        let out = Self.destination(format)
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: format, to: out,
                                      options: ArchiveWriteOptions(excludesMacMetadata: excludes))
        let kept: Set = ["a", "f", "__MACOSXfoo", "__MACOSXfoo/y", "c", "c/foo__MACOSX", "c/foo__MACOSX/z",
                         "c/__macosx", "c/__macosx/w", "c/__MACOSX_old", "c/__MACOSX_old/v", "keep.txt"]
        let want = excludes ? kept : Set(source.entries.map(\.path))
        #expect(try await Self.listing(out) == want, "\(format) \(excludes)")
        if excludes {
            #expect(Set(try Self.headerPaths(out)).isDisjoint(with: ["a/__MACOSX", "a/__MACOSX/x", "a/b",
                                                                     "a/b/__MACOSX", "a/b/__MACOSX/._x",
                                                                     "f/__MACOSX"]))
        }
    }

    /// An addition placed inside a nested `__MACOSX` folder of the archive is metadata too; a look-alike
    /// destination is not.
    @Test(arguments: [true, false])
    func additionIntoANestedMACOSXFolder(_ excludes: Bool) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["f.txt": Data("f".utf8)], in: dir)
        let file = dir.appending(path: "f.txt")
        let changes = ArchiveChangeSet(additions: [.init(sourceURL: file, destinationDirectory: "d/__MACOSX"),
                                                   .init(sourceURL: file, destinationDirectory: "d/e/__MACOSX/g"),
                                                   .init(sourceURL: file, destinationDirectory: "d/__MACOSXfoo")])
        let out = Self.destination(.zip)
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: out,
                                      options: ArchiveWriteOptions(excludesMacMetadata: excludes))
        let want: Set = excludes ? ["d", "d/__MACOSXfoo", "d/__MACOSXfoo/f.txt"]
            : ["d", "d/__MACOSX", "d/__MACOSX/f.txt", "d/e", "d/e/__MACOSX", "d/e/__MACOSX/g", "d/e/__MACOSX/g/f.txt",
               "d/__MACOSXfoo", "d/__MACOSXfoo/f.txt"]
        #expect(Set(try Self.headerPaths(out)) == want)
    }

    /// The flag with removals and additions in one save: kept paths, removals and added parents agree, and
    /// no metadata folder is made again as a missing parent.
    @Test func repackWithChangesKeepsPathsConsistent() async throws {
        let source = try await Archive.open(at: Corpus.root.appending(path: "zip/macos-junk.zip"))
        let tree = Fixtures.tempDir()
        Fixtures.makeFiles(["new/n.txt": Data("n".utf8), "new/._n.txt": Data("ad".utf8),
                            "new/__MACOSX/m": Data("m".utf8)], in: tree)
        let changes = ArchiveChangeSet(removedPaths: ["a"],
                                       additions: [.init(sourceURL: tree.appending(path: "new"),
                                                         destinationDirectory: "sub/nested")])
        let out = Self.destination(.zip)
        try await ArchiveWriter.write(source: source, changes: changes, format: .zip, to: out, options: Self.on)
        let want: Set = [".localized", "Icon\r", "readme.txt", "sub", "sub/file", "sub/nested", "sub/nested/deep.txt",
                         "sub/nested/new", "sub/nested/new/n.txt"]
        let headers = try Self.headerPaths(out)
        #expect(Set(headers) == want)
        #expect(headers.count == want.count, "\(headers)")
        #expect(try await Self.listing(out) == want)
    }

    /// A tar hardlink whose target is a dropped `._` entry keeps its data (written as a regular file).
    @Test func hardlinkToADroppedEntryKeepsItsData() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["._a": Data("appledouble bytes\n".utf8)], in: dir)
        try FileManager.default.linkItem(at: dir.appending(path: "._a"), to: dir.appending(path: "h"))
        try Fixtures.bsdtar(["-cf", "src.tar", "--no-mac-metadata", "._a", "h"], cwd: dir)
        let source = try await Archive.open(at: dir.appending(path: "src.tar"))
        #expect(source.entries.map(\.path).sorted() == ["._a", "h"])
        let out = Self.destination(.tar)
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .tar, to: out,
                                      options: Self.on)
        let headers = try WriterRepackTests.rawHeaders(out)
        #expect(headers.map(\.path) == ["h"])
        #expect(headers.first?.isRegular == true && headers.first?.hardlink == nil)
        let contents = try await WriterRepackTests.contents(of: try await Archive.open(at: out))
        #expect(contents == ["h": Fixtures.sha256(dir.appending(path: "._a"))])
    }
}
