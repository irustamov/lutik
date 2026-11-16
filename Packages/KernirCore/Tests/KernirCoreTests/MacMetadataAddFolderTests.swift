// Add-folder checks of `ArchiveWriteOptions.excludesMacMetadata`, corpus style.
// MacMetadataSkipDescendantsTests pin the walker fix on its own trees; this file adds a
// deeper Finder-shaped folder through the public `ArchiveWriter.write`, into a new archive of every writable
// format and into the corpus's metadata rows, with the folder on disk (read with readdir/lstat, not the engine)
// as the oracle for paths and bytes and MacMetadataRuling (MacMetadataCorpusTests.swift) for what is metadata.
//
// The data-loss case: with the flag on, the walker used to call the enumerator's `skipDescendants()` after a
// skipped metadata *file*, and `FileManager.DirectoryEnumerator` then skipped the contents of the next folder it
// returned. So every folder here holds real files (the `pair` folders in a subfolder), and every folder at
// every level holds metadata non-folders.
//
// Foundation's enumerator (the one AdditionWalker uses) never returns a regular `._*` file on macOS, at any
// depth (pinned in MacMetadataWriteTests.foundationNeverListsAppleDoubleFilesInAFolder), so the `._x` files below
// are left out before the walker sees them and cannot reach the bug. What it does return is a `._*` symlink, so
// every folder also holds `._lnk`, a symlink: that is the `._` item the old code skipped descendants after. The
// suite checks both on disk and in the enumerator's own listing before relying on them.

import Foundation
import Testing
@testable import KernirCore

@Suite("Mac metadata add folder",
       .enabled("KernirCore reader not landed yet") { await Corpus.readerAvailable }, .timeLimit(.minutes(2)))
struct MacMetadataAddFolderTests {
    static let on = ArchiveWriteOptions(excludesMacMetadata: true)

    /// The added folder's name, and where `addFolderIntoMetadataRowKeepsEveryRealFile` puts it.
    static let rootName = "drop"
    static let into = "added"

    /// A folder tree on disk: `files` and `folders` are the real items (paths from the parent of `root`, so
    /// they read as archive paths when `root` is added at the archive root); `metaFiles` the regular
    /// `.DS_Store` and `._x` files; `links` the `._lnk` symlinks; `metaFolders` the metadata folders.
    struct Tree {
        let root: URL
        var files: [String: Data] = [:]
        var folders: Set<String> = []
        var metaFiles: Set<String> = []
        var links: Set<String> = []
        var metaFolders: Set<String> = []

        /// Every real item: what the archive must hold.
        var want: Set<String> { folders.union(files.keys) }
        var parent: URL { root.deletingLastPathComponent() }
    }

    /// Deterministic bytes, a different length per call site (some past 64 KB, so more than one read buffer).
    static func blob(_ seed: Int) -> Data {
        var x = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        let count = (seed &* 7919) % 90_000 + 1
        return Data((0..<count).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return UInt8(truncatingIfNeeded: x)
        })
    }

    /// `drop`, every folder of which holds a `.DS_Store` file, a `._x` AppleDouble file and a `._lnk` symlink
    /// (except `drop/meta`, whose `.DS_Store` is a folder):
    /// - `drop/s0…s5/a/b/c`: siblings four levels deep, each folder with `f.txt` and a `blob.bin` of its own size;
    /// - `drop/pair/{x,y}`: only metadata and a folder `a` with `f.txt`, so whichever of `x` and `y` comes first,
    ///   the folder after its metadata holds a real file whatever the enumeration order;
    /// - `drop/meta`: a `.DS_Store` folder, a `__MACOSX` folder and a `._dir` folder with contents, next to
    ///   ordinary folders `k0…k2`; and a nested `drop/s3/a/b/__MACOSX`. Each goes with everything inside it.
    static func makeTree() throws -> Tree {
        let dir = Fixtures.tempDir()
        var tree = Tree(root: dir.appending(path: rootName))
        var disk: [String: Data] = [:]
        var seed = 0
        func folder(_ path: String, real: Bool = true, dsStoreFile: Bool = true) {
            tree.folders.insert(path)
            disk[path + "/"] = Data()
            if dsStoreFile {
                disk[path + "/.DS_Store"] = Data("Bud1\0\0\0\u{1} \(path)".utf8)
                tree.metaFiles.insert(path + "/.DS_Store")
            }
            disk[path + "/._x"] = Data("\0\u{5}\u{16}\u{7}\0\u{2}\0\0Mac OS X AppleDouble \(path)".utf8)
            tree.metaFiles.insert(path + "/._x")
            tree.links.insert(path + "/._lnk")
            guard real else { return }
            seed += 1
            tree.files[path + "/f.txt"] = Data("data of \(path)/f.txt\n".utf8)
            tree.files[path + "/blob.bin"] = blob(seed)
        }
        func metaFolder(_ path: String, _ contents: [String: Data]) {
            tree.metaFolders.insert(path)
            for (name, data) in contents { disk[path + "/" + name] = data }
        }

        folder(rootName)
        tree.files[rootName + "/empty.txt"] = Data()
        for i in 0..<6 {
            var path = "\(rootName)/s\(i)"
            for level in ["", "a", "b", "c"] {
                if !level.isEmpty { path += "/" + level }
                folder(path)
            }
        }
        folder("\(rootName)/pair", real: false)
        for side in ["x", "y"] {
            folder("\(rootName)/pair/\(side)", real: false)
            folder("\(rootName)/pair/\(side)/a")
        }
        folder("\(rootName)/meta", dsStoreFile: false)
        for i in 0..<3 { folder("\(rootName)/meta/k\(i)") }
        let inner = ["inner.txt": Data("metadata inside".utf8), "deep/f": Data("deep".utf8), "deep/._g": Data("ad".utf8)]
        metaFolder("\(rootName)/meta/.DS_Store", inner)
        metaFolder("\(rootName)/meta/__MACOSX", inner.merging(["._f.txt": Data("ad".utf8)]) { a, _ in a })
        metaFolder("\(rootName)/meta/._dir", inner)
        metaFolder("\(rootName)/s3/a/b/__MACOSX", ["s3/._f.txt": Data("ad".utf8), "s3/plain.txt": Data("p".utf8)])

        for (path, data) in tree.files { disk[path] = data }
        Fixtures.makeFiles(disk, in: dir)
        for link in tree.links {
            try FileManager.default.createSymbolicLink(atPath: dir.appending(path: link).path,
                                                       withDestinationPath: "f.txt")
        }
        return tree
    }

    // MARK: Oracles independent of Foundation's listing

    /// The lstat file type of every item below `url`, by path relative to `base`, read with readdir (which,
    /// unlike FileManager, lists `._*` files).
    static func diskTree(_ url: URL, relativeTo base: URL) -> [String: mode_t] {
        var result: [String: mode_t] = [:]
        func walk(_ dir: String, _ rel: String) {
            guard let handle = opendir(dir) else { return }
            defer { closedir(handle) }
            while let entry = readdir(handle) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if name == "." || name == ".." { continue }
                let path = dir + "/" + name
                let relPath = rel.isEmpty ? name : rel + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let type = st.st_mode & S_IFMT
                result[relPath] = type
                if type == S_IFDIR { walk(path, relPath) }
            }
        }
        let start = url.path.dropFirst(base.path.count).drop { $0 == "/" }
        walk(url.path, String(start))
        if !start.isEmpty {
            var st = stat()
            if lstat(url.path, &st) == 0 { result[String(start)] = st.st_mode & S_IFMT }
        }
        return result
    }

    static func lstatType(_ url: URL) -> mode_t? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_mode & S_IFMT : nil
    }

    /// What the walker's enumerator returns for `root`, in order, made the same way (AdditionWalker.walk): path
    /// from the parent of `root`, and whether the item is itself a folder (lstat).
    static func enumerated(_ root: URL) -> [(path: String, isFolder: Bool)] {
        var result: [(path: String, isFolder: Bool)] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [],
                                                    errorHandler: { _, _ in false })
        while let url = walker?.nextObject() as? URL {
            let relative = url.pathComponents.suffix(walker?.level ?? 0).joined(separator: "/")
            result.append((root.lastPathComponent + "/" + relative, lstatType(url) == S_IFDIR))
        }
        return result
    }

    /// The tree is what it claims to be on disk, and the enumerator returns the metadata non-folders the old
    /// walker skipped descendants after, each followed by a folder holding real files: the data-loss case, for
    /// `.DS_Store` files and for `._` items both.
    static func checkPreconditions(_ tree: Tree) {
        let disk = diskTree(tree.root, relativeTo: tree.parent)
        for path in tree.metaFiles.sorted() { #expect(disk[path] == S_IFREG, "\(path) is not a file on disk") }
        for path in tree.links.sorted() { #expect(disk[path] == S_IFLNK, "\(path) is not a symlink on disk") }
        for path in tree.metaFolders.sorted() { #expect(disk[path] == S_IFDIR, "\(path) is not a folder on disk") }
        for path in tree.files.keys.sorted() { #expect(disk[path] == S_IFREG, "\(path) missing on disk") }
        for path in tree.folders.sorted() { #expect(disk[path] == S_IFDIR, "\(path) missing on disk") }
        #expect(Set(disk.keys).filter { !MacMetadataRuling.isMetadata($0) } == tree.want,
                "the real items on disk are not the tree's")

        let listing = enumerated(tree.root)
        let listed = Set(listing.map(\.path))
        // Every `._lnk` and every `.DS_Store` file is returned: the walker sees them and skips them by name.
        #expect(tree.links.subtracting(listed).sorted() == [], "enumerator hides ._ symlinks")
        let dsStores = tree.metaFiles.filter { $0.hasSuffix("/.DS_Store") }
        #expect(dsStores.subtracting(listed).sorted() == [], "enumerator hides .DS_Store files")
        // The `._x` files are not returned (see the header): if this changes, they reach the walker too, which
        // the archive checks still cover; update this pin and the header.
        let appleDouble = tree.metaFiles.filter { $0.hasSuffix("/._x") }
        #expect(appleDouble.intersection(listed).sorted() == [], "Foundation now lists regular ._ files")
        // Every real item is returned, so the walker can only lose it by skipping it.
        #expect(tree.want.subtracting([rootName]).subtracting(listed).sorted() == [], "enumerator hides real items")

        // Each metadata non-folder followed (anywhere later) by a real folder whose real contents the old code
        // dropped. Both kinds must occur, or one of them is not exercised.
        var lossCases: [String: Int] = [:]
        for (i, item) in listing.enumerated() where !item.isFolder {
            let name = String(item.path.split(separator: "/").last ?? "")
            guard name == ".DS_Store" || name.hasPrefix("._"),
                  let next = listing[(i + 1)...].first(where: { $0.isFolder }), !MacMetadataRuling.isMetadata(next.path)
            else { continue }
            let inside = tree.files.keys.filter { $0.hasPrefix(next.path + "/") }
            #expect(!inside.isEmpty, "\(next.path) after \(item.path) holds no real file")
            lossCases[name == ".DS_Store" ? ".DS_Store" : "._", default: 0] += 1
        }
        #expect(lossCases[".DS_Store", default: 0] > 0, "no .DS_Store file is followed by a folder: \(lossCases)")
        #expect(lossCases["._", default: 0] > 0, "no ._ item is followed by a folder: \(lossCases)")
    }

    /// Extracts `archive` and checks what lands on disk below `prefix` (readdir, so a `._*` file would show):
    /// exactly `tree.want` moved under `prefix`, folders as folders and every file byte-identical to its source.
    /// Returns the extraction folder.
    @discardableResult
    static func checkExtracted(_ archive: any ArchiveReading, _ tree: Tree, under prefix: String,
                               _ label: String) async throws -> URL {
        let out = Fixtures.tempDir()
        try await archive.extract(nil, to: out, progress: nil)
        let all = diskTree(out, relativeTo: out)
        let p = prefix.isEmpty ? "" : prefix + "/"
        let got = all.filter { $0.key == p + rootName || $0.key.hasPrefix(p + rootName + "/") }
        let want = Set(tree.want.map { p + $0 })
        #expect(Set(got.keys) == want,
                "\(label): extracted lost \(want.subtracting(got.keys).sorted()), gained \(Set(got.keys).subtracting(want).sorted())")
        for path in tree.folders { #expect(got[p + path] == S_IFDIR, "\(label): \(path) not a folder") }
        for (path, data) in tree.files {
            #expect(got[p + path] == S_IFREG, "\(label): \(path) not a file")
            #expect((try? Data(contentsOf: out.appending(path: p + path))) == data, "\(label): \(path) bytes")
        }
        return out
    }

    static func additions(_ tree: Tree, into directory: String) -> ArchiveChangeSet {
        ArchiveChangeSet(additions: [.init(sourceURL: tree.root, destinationDirectory: directory)])
    }

    // MARK: - Tests

    /// The walker on its own returns exactly the real items, once each.
    @Test func walkerReturnsExactlyTheRealItems() throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree.parent) }
        Self.checkPreconditions(tree)
        let got = try AdditionWalker.items(for: [.init(sourceURL: tree.root, destinationDirectory: "")],
                                           excludingMacMetadata: true).map(\.archivePath)
        #expect(Set(got) == tree.want, "lost \(tree.want.subtracting(got).sorted()), gained \(Set(got).subtracting(tree.want).sorted())")
        #expect(got.count == tree.want.count, "duplicates in \(got.sorted())")
    }

    /// Flag on, the folder added to a new archive of every writable format: the stored headers and the listing
    /// are exactly the real items, none is metadata, and the extracted files are byte-identical to the source.
    @Test(arguments: ArchiveFormat.writable)
    func addFolderToNewArchiveKeepsEveryRealFile(_ format: ArchiveFormat) async throws {
        let tree = try Self.makeTree()
        let outDir = Fixtures.tempDir()
        defer {
            try? FileManager.default.removeItem(at: tree.parent)
            try? FileManager.default.removeItem(at: outDir)
        }
        Self.checkPreconditions(tree)
        let out = outDir.appending(path: "out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: nil, changes: Self.additions(tree, into: ""), format: format, to: out,
                                      options: Self.on)
        let headers = try WriterRepackTests.rawHeaders(out).map(\.path)
        #expect(Set(headers) == tree.want,
                "\(format): headers lost \(tree.want.subtracting(headers).sorted()), gained \(Set(headers).subtracting(tree.want).sorted())")
        #expect(headers.count == tree.want.count, "\(format): duplicate headers")
        #expect(headers.filter(MacMetadataRuling.isMetadata) == [], "\(format): metadata stored")
        let result = try await Archive.open(at: out)
        let listed = Set(result.entries.map(\.path))
        #expect(listed == tree.want, "\(format): listing gained \(listed.subtracting(tree.want).sorted())")
        let extracted = try await Self.checkExtracted(result, tree, under: "", "\(format)")
        try? FileManager.default.removeItem(at: extracted)
    }

    /// The corpus's Mac metadata rows (one per format family), each with the folder added under `added/` with
    /// the flag on, as the app's Add Folder then Save does: the row's own metadata goes, its other entries stay
    /// byte-identical, and the added folder lands exactly as in a new archive.
    static let metadataRows = ["zip/macos-finder.zip", "7z/macos-junk.7z", "tar/macos-bsdtar.tar"]
    static let rows = RepackTests.repackable.filter { metadataRows.contains($0.file) }

    @Test func corpusHasTheMetadataRows() {
        guard Corpus.manifest != nil else { return }
        #expect(Self.rows.count == Self.metadataRows.count, "repackable: \(Self.rows.map(\.file))")
        for row in Self.rows { #expect(!MacMetadataRuling.metadata(of: row).isEmpty, "\(row.file) holds no metadata") }
    }

    @Test(arguments: rows)
    func addFolderIntoMetadataRowKeepsEveryRealFile(_ fixture: Fixture) async throws {
        await checking(fixture) {
            let format = try MacMetadataCorpusTests.format(of: fixture)
            let tree = try Self.makeTree()
            let outDir = Fixtures.tempDir()
            var extracted: [URL] = []
            defer {
                for url in [tree.parent, outDir] + extracted { try? FileManager.default.removeItem(at: url) }
            }
            Self.checkPreconditions(tree)
            let source = try await Archive.open(at: fixture.url, password: fixture.password)
            let out = outDir.appending(path: "out.\(format.fileExtension)")
            let options = MacMetadataCorpusTests.options(source, fixture, to: format, excludes: true)
            try await ArchiveWriter.write(source: source, changes: Self.additions(tree, into: Self.into),
                                          format: format, to: out, options: options)
            let password = options.encryption == .none ? nil : fixture.password
            let result = try await Archive.open(at: out, password: password)
            let label = fixture.file

            let added = Set(tree.want.map { Self.into + "/" + $0 })
            let kept = Set(source.entries.map(\.path)).filter { !MacMetadataRuling.isMetadata($0) }
            let want = kept.union(added).union([Self.into])
            let listed = Set(result.entries.map(\.path))
            #expect(listed == want, "\(label): lost \(want.subtracting(listed).sorted()), gained \(listed.subtracting(want).sorted())")
            let headers = try WriterRepackTests.rawHeaders(out, password: password).map(\.path)
            let addedHeaders = headers.filter { $0.hasPrefix(Self.into + "/") }
            #expect(Set(addedHeaders) == added, "\(label): added headers gained \(Set(addedHeaders).subtracting(added).sorted())")
            #expect(addedHeaders.count == added.count, "\(label): duplicate added headers")
            #expect(headers.filter(MacMetadataRuling.isMetadata) == [], "\(label): metadata stored")

            let got = try await Self.checkExtracted(result, tree, under: Self.into, label)
            extracted.append(got)
            // Kept entries: every real regular file the row extracts to is extracted again, byte-identical.
            let before = Fixtures.tempDir()
            extracted.append(before)
            try await source.extract(nil, to: before, progress: nil)
            let keptFiles = Self.diskTree(before, relativeTo: before)
                .filter { $0.value == S_IFREG && !MacMetadataRuling.isMetadata($0.key) }.keys
            #expect(!keptFiles.isEmpty, "\(label): no kept file to compare")
            for path in keptFiles.sorted() {
                #expect((try? Data(contentsOf: got.appending(path: path))) == (try? Data(contentsOf: before.appending(path: path))),
                        "\(label): kept \(path) bytes")
            }
        }
    }
}
