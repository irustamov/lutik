import Foundation
import Testing
@testable import KernirCore

/// Data-loss regression for `excludesMacMetadata`: the walker skipped a metadata *file* (`.DS_Store`,
/// `._*`) and called the enumerator's `skipDescendants()` for it. On a `FileManager.DirectoryEnumerator` that
/// makes it skip the contents of the next folder it returns, so real files next to a Finder `.DS_Store` were
/// silently left out of the archive. Only a skipped *folder* (not a symlink to one) may skip its descendants.
///
/// Enumeration order is unspecified, so the trees here do not rely on it: in `pair`, each of `x` and `y` holds
/// only metadata items and a folder `a` (with a file). Whichever folder comes first, its metadata item is
/// followed either by its own `a` or, when it comes last, by the other folder, so the old code always lost a
/// real file. `proj` (8 siblings × 3 levels, metadata at every level) is the realistic Finder shape.
struct MacMetadataSkipDescendantsTests {
    static let on = ArchiveWriteOptions(excludesMacMetadata: true)

    /// `proj` with `f.txt`, `.DS_Store` and `._x` at the root and in every folder of `s0…s7/a/b`, and `pair`
    /// with `x` and `y`, each `{.DS_Store, ._x, ._lnk, a/f.txt}`. `._lnk` is a symlink to `a/f.txt`: Foundation's
    /// enumerator never lists a regular `._*` file, but it does list a `._*` symlink, so `._lnk` is the one listed
    /// `._*` non-folder the walker skips by name. Returns the two roots and the real items (folders and
    /// `f.txt` files) the archive must hold.
    static func makeTree() -> (roots: [URL], want: Set<String>) {
        let dir = Fixtures.tempDir()
        var files: [String: Data] = [:]
        var want: Set<String> = ["proj", "pair"]
        func folder(_ path: String, file: Bool = true) {
            want.insert(path)
            files[path + "/.DS_Store"] = Data("Bud1 \(path)".utf8)
            files[path + "/._x"] = Data("AppleDouble \(path)".utf8)
            if file {
                files[path + "/f.txt"] = Data("data of \(path)/f.txt\n".utf8)
                want.insert(path + "/f.txt")
            }
        }
        folder("proj")
        for i in 0..<8 {
            folder("proj/s\(i)")
            folder("proj/s\(i)/a")
            folder("proj/s\(i)/a/b")
        }
        for side in ["x", "y"] {
            folder("pair/\(side)", file: false)
            files["pair/\(side)/a/f.txt"] = Data("data of pair/\(side)/a/f.txt\n".utf8)
            want.formUnion(["pair/\(side)/a", "pair/\(side)/a/f.txt"])
        }
        Fixtures.makeFiles(files, in: dir)
        for side in ["x", "y"] {
            try? FileManager.default.createSymbolicLink(atPath: dir.appending(path: "pair/\(side)/._lnk").path,
                                                        withDestinationPath: "a/f.txt")
        }
        return ([dir.appending(path: "proj"), dir.appending(path: "pair")], want)
    }

    static func additions(_ roots: [URL]) -> ArchiveChangeSet {
        ArchiveChangeSet(additions: roots.map { .init(sourceURL: $0, destinationDirectory: "") })
    }

    /// The walker's archive paths for these roots added at the archive root.
    static func walked(_ roots: [URL], excludes: Bool) throws -> [String] {
        try AdditionWalker.items(for: roots.map { .init(sourceURL: $0, destinationDirectory: "") },
                                 excludingMacMetadata: excludes).map(\.archivePath)
    }

    static func missing(_ want: Set<String>, from got: [String]) -> [String] {
        want.subtracting(got).sorted()
    }

    // MARK: Metadata files never hide real items

    @Test(arguments: [true, false])
    func walkerKeepsEveryRealItemNextToMetadataFiles(_ excludes: Bool) throws {
        let (roots, want) = Self.makeTree()
        let got = try Self.walked(roots, excludes: excludes)
        #expect(Self.missing(want, from: got) == [], "lost with excludes \(excludes)")
        // Off, a nested `._x` would be kept if the enumerator listed it (on macOS it does not, see
        // `MacMetadataWriteTests.foundationNeverListsAppleDoubleFilesInAFolder`; not pinned here).
        let extra = got.filter { path in
            !want.contains(path) && (excludes || !(path.split(separator: "/").last ?? "").hasPrefix("._"))
        }
        #expect(extra == [], "unexpected with excludes \(excludes)")
        #expect(got.count == Set(got).count)
        // `._lnk` is listed (off, it is kept) and skipped by name (on); either way `a` beside it keeps its file.
        let links: Set = ["pair/x/._lnk", "pair/y/._lnk"]
        #expect(Set(got).intersection(links) == (excludes ? [] : links), "with excludes \(excludes)")
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tar])
    func writeKeepsEveryRealItemNextToMetadataFiles(_ format: ArchiveFormat) async throws {
        let (roots, want) = Self.makeTree()
        let out = Fixtures.tempDir().appending(path: "out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: nil, changes: Self.additions(roots), format: format, to: out,
                                      options: Self.on)
        let headers = try MacMetadataWriteTests.headerPaths(out)
        #expect(Self.missing(want, from: headers) == [], "\(format) lost")
        #expect(Set(headers) == want, "\(format)")
        #expect(headers.count == want.count, "\(format) \(headers)")
        let contents = try await WriterRepackTests.contents(of: try await Archive.open(at: out))
        for path in want where path.hasSuffix("f.txt") {
            #expect(contents[path] == Fixtures.sha256(roots[0].deletingLastPathComponent().appending(path: path)),
                    "\(format) \(path)")
        }
    }

    /// The split writer plans its entries with the same walker (`LibArchiveWriter.planEntries`).
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func writeVolumesKeepsEveryRealItemNextToMetadataFiles(_ format: ArchiveFormat) async throws {
        let (roots, want) = Self.makeTree()
        let folder = APIBatchTests.emptyFolder()
        var options = Self.on
        options.volumeSize = ArchiveWriteOptions.minimumVolumeSize
        let urls = try await ArchiveWriter.writeVolumes(source: nil, changes: Self.additions(roots), format: format,
                                                        into: folder, baseName: "Split", options: options)
        #expect(urls.count == 1, "\(urls)")
        let headers = try MacMetadataWriteTests.headerPaths(try #require(urls.first))
        #expect(Self.missing(want, from: headers) == [], "\(format) lost")
        #expect(Set(headers) == want, "\(format)")
        #expect(headers.count == want.count, "\(format) \(headers)")
    }

    // MARK: Metadata folders still go with their contents

    /// `m/{__MACOSX, .DS_Store, ._dir}` are real folders with contents; `m/k0…k3` are ordinary folders next to
    /// them. With the flag, each metadata folder is left out with everything inside it (the walker still skips a
    /// skipped folder's descendants), and every ordinary folder keeps its contents. Without it, as without the option:
    /// `__MACOSX` and `._dir` are kept, the `.DS_Store` folder itself is skipped by name but its contents are
    /// still walked (so the archive gets `m/.DS_Store` back as their missing parent).
    @Test(arguments: [true, false])
    func metadataFoldersGoWithTheirContents(_ excludes: Bool) async throws {
        let dir = Fixtures.tempDir()
        var files: [String: Data] = [:]
        for meta in ["__MACOSX", ".DS_Store", "._dir"] {
            files["m/\(meta)/inner.txt"] = Data("i".utf8)
            files["m/\(meta)/deep/f"] = Data("f".utf8)
        }
        var kept: Set<String> = ["m"]
        for i in 0..<4 {
            files["m/k\(i)/f"] = Data("k\(i)".utf8)
            kept.formUnion(["m/k\(i)", "m/k\(i)/f"])
        }
        Fixtures.makeFiles(files, in: dir)
        let root = dir.appending(path: "m")
        let want = excludes ? kept : kept.union([
            "m/__MACOSX", "m/__MACOSX/inner.txt", "m/__MACOSX/deep", "m/__MACOSX/deep/f",
            "m/._dir", "m/._dir/inner.txt", "m/._dir/deep", "m/._dir/deep/f",
            "m/.DS_Store/inner.txt", "m/.DS_Store/deep", "m/.DS_Store/deep/f",
        ])
        #expect(Set(try Self.walked([root], excludes: excludes)) == want, "walker, excludes \(excludes)")
        let wantHeaders = excludes ? want : want.union(["m/.DS_Store"])
        let out = Fixtures.tempDir().appending(path: "out.zip")
        try await ArchiveWriter.write(source: nil, changes: Self.additions([root]), format: .zip, to: out,
                                      options: ArchiveWriteOptions(excludesMacMetadata: excludes))
        let headers = try MacMetadataWriteTests.headerPaths(out)
        #expect(Set(headers) == wantHeaders, "excludes \(excludes)")
        #expect(headers.count == wantHeaders.count, "\(headers)")
    }

    /// A symlink to a folder named like metadata is skipped by its name, but it is not a folder the enumerator
    /// descends into (it never follows symlinks), so skipping it must not skip anything else: the `pair` shape
    /// with a `__MACOSX` symlink (and a `.DS_Store` symlink, skipped whatever the flag) in each of `x` and `y`.
    @Test(arguments: [true, false])
    func symlinkToAFolderNamedLikeMetadataHidesNothing(_ excludes: Bool) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["target/t.txt": Data("t".utf8), "pair/x/a/f.txt": Data("x".utf8),
                            "pair/y/a/f.txt": Data("y".utf8)], in: dir)
        let fm = FileManager.default
        for side in ["x", "y"] {
            for name in ["__MACOSX", ".DS_Store"] {
                try fm.createSymbolicLink(atPath: dir.appending(path: "pair/\(side)/\(name)").path,
                                          withDestinationPath: "../../target")
            }
        }
        let root = dir.appending(path: "pair")
        var want: Set<String> = ["pair", "pair/x", "pair/x/a", "pair/x/a/f.txt", "pair/y", "pair/y/a", "pair/y/a/f.txt"]
        if !excludes { want.formUnion(["pair/x/__MACOSX", "pair/y/__MACOSX"]) }
        #expect(Set(try Self.walked([root], excludes: excludes)) == want, "walker, excludes \(excludes)")
        let out = Fixtures.tempDir().appending(path: "out.zip")
        try await ArchiveWriter.write(source: nil, changes: Self.additions([root]), format: .zip, to: out,
                                      options: ArchiveWriteOptions(excludesMacMetadata: excludes))
        let headers = try MacMetadataWriteTests.headerPaths(out)
        #expect(Set(headers) == want, "excludes \(excludes)")
        #expect(headers.count == want.count, "\(headers)")
    }
}
