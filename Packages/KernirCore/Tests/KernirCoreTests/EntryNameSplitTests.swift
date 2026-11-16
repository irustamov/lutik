import Foundation
import Testing
@testable import KernirCore

/// `ArchiveEntry.name`, `ArchiveEntry.parentPath` and the tree split a path on the scalar "/", as `EntryPath` does,
/// never on Characters. A "/" followed by a combining mark (U+0301) or a ZWJ, or preceded by a Prepend scalar
/// (U+0600), is part of one Character that is not "/": a Character split gave `a/\u{301}b` the name `a/\u{301}b` and
/// the parent "", so the tree hung it at the root next to the folder `a` the reader synthesizes for it.
struct EntryNameSplitTests {
    static let mark = "\u{301}"

    static func entry(_ path: String, directory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: directory, size: directory ? nil : 1, compressedSize: nil,
                     modificationDate: nil)
    }

    static func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

    struct Hidden: Sendable, CustomTestStringConvertible {
        let path: String
        let name: String
        let parent: String
        let label: String
        var testDescription: String { label }
    }

    static let hidden = [
        Hidden(path: "a/\(mark)b", name: "\(mark)b", parent: "a", label: "combining mark after /"),
        Hidden(path: "a/b/\(mark)c", name: "\(mark)c", parent: "a/b", label: "combining mark after the last /"),
        Hidden(path: "a/\(mark)b/c", name: "c", parent: "a/\(mark)b", label: "combining mark after the first /"),
        Hidden(path: "a/\u{200D}b", name: "\u{200D}b", parent: "a", label: "ZWJ after /"),
        Hidden(path: "a\u{600}/b", name: "b", parent: "a\u{600}", label: "Prepend before /"),
        Hidden(path: "a/\(mark)", name: mark, parent: "a", label: "combining mark alone after /"),
    ]

    /// Compared as scalars: String `==` is canonical, but none of these has a canonical twin that would hide a "/".
    @Test(arguments: hidden)
    func nameAndParentSplitOnScalars(_ c: Hidden) {
        let e = Self.entry(c.path)
        #expect(Self.scalars(e.name) == Self.scalars(c.name), "\(e.name.debugDescription)")
        #expect(Self.scalars(e.parentPath) == Self.scalars(c.parent), "\(e.parentPath.debugDescription)")
    }

    /// The tree places the entry under its folder (given or synthesized), with the scalar name.
    @Test(arguments: hidden, [false, true])
    func treePlacesTheEntryUnderItsFolder(_ c: Hidden, folderListed: Bool) {
        var entries = [Self.entry(c.path)]
        if folderListed { entries += EntryPath.ancestors(of: c.path).map { Self.entry($0, directory: true) } }
        let tree = Archive.tree(from: entries)
        let top = EntryPath.split(c.path)[0]
        #expect(tree.map { Self.scalars($0.entry.path) } == [Self.scalars(top)])
        // Walk down the ancestors to the entry's folder.
        var level = tree
        for ancestor in EntryPath.ancestors(of: c.path) {
            guard let node = level.first(where: { Self.scalars($0.entry.path) == Self.scalars(ancestor) }) else {
                Issue.record("no folder \(ancestor.debugDescription)")
                return
            }
            #expect(node.entry.isDirectory)
            level = node.children ?? []
        }
        #expect(level.map { Self.scalars($0.entry.path) } == [Self.scalars(c.path)])
        #expect(level.map { Self.scalars($0.entry.name) } == [Self.scalars(c.name)])
    }

    /// The same through the reader: a tar holding only `d/\u{301}x` lists the synthesized folder `d`, and the tree
    /// shows one folder `d` holding `\u{301}x`, not `d` (empty) next to an item named `d/\u{301}x`.
    @Test func readerListingTreesTheHiddenSlashEntryUnderItsFolder() async throws {
        let path = "d/\(Self.mark)x"
        let r = try await ExtractHiddenSlashTests.reader([path: Data("x".utf8)], order: [path])
        let tree = Archive.tree(from: r.entries)
        #expect(tree.map(\.entry.path) == ["d"])
        #expect(tree.first?.entry.isDirectory == true)
        #expect(tree.first?.children?.map { Self.scalars($0.entry.path) } == [Self.scalars(path)])
        #expect(tree.first?.children?.map { Self.scalars($0.entry.name) } == [Self.scalars("\(Self.mark)x")])
        #expect(tree.first?.totalSize == 1)
    }

    // MARK: - Ordinary paths are unchanged

    /// The Character-based code before the scalar split, kept as the oracle for ordinary paths.
    static func legacyName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
    static func legacyParent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Paths where every "/" is a Character of its own: ASCII, NFC and NFD accents, emoji (ZWJ sequences, flags,
    /// skin tones, keycaps), CJK, Hangul (precomposed and conjoining jamo), RTL, spaces, CRLF, leading, trailing and
    /// doubled "/", a lone "/", "", and the same names in every position.
    static let ordinary: [String] = {
        let names = [
            "a", "README.md", "file name.txt", " lead", "trail ", "caf\u{E9}", "cafe\u{301}", "Cafe\u{301} cre\u{300}me",
            "\u{1F600}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1FA}\u{1F1F8}", "\u{1F44D}\u{1F3FD}",
            "1\u{FE0F}\u{20E3}", "\u{6F22}\u{5B57}", "\u{65E5}\u{672C}\u{8A9E} \u{30D5}\u{30A1}\u{30A4}\u{30EB}",
            "\u{D55C}\u{AE00}", "\u{1112}\u{1161}\u{11AB}", "\u{5E9}\u{5DC}\u{5D5}\u{5DD}", "\u{627}\u{644}\u{639}",
            "a\r\nb", "._x", "__MACOSX", ".DS_Store", "..", ".", "a\\b", "x\u{0}y", "\u{E01}\u{E33}",
            "\u{915}\u{94D}\u{937}", "o\u{308}\u{332}",
        ]
        var paths = ["", "/", "//", "a/", "/a", "a//b", "/a/b/", "a/b//"]
        for n in names {
            paths += [n, "\(n)/", "/\(n)", "dir/\(n)", "\(n)/x", "\(n)/\(n)", "a/\(n)/b/\(n)", "d d/\(n)/", "\(n)//\(n)"]
        }
        return paths
    }()

    /// Byte for byte the same name and parent as the Character code for every ordinary path.
    @Test func ordinaryPathsAreByteIdentical() {
        // Each of these is ordinary: no "/" in it is part of a larger Character.
        for p in Self.ordinary {
            #expect(p.filter { $0 == "/" }.count == p.unicodeScalars.filter { $0 == "/" }.count,
                    "\(p.debugDescription) is not ordinary")
        }
        for p in Self.ordinary {
            let e = Self.entry(p)
            #expect(Array(e.name.utf8) == Array(Self.legacyName(p).utf8), "name of \(p.debugDescription)")
            #expect(Array(e.parentPath.utf8) == Array(Self.legacyParent(p).utf8), "parent of \(p.debugDescription)")
        }
    }

    /// The tree over ordinary paths: every node sits under the folder the Character split gave it, with the same
    /// name, byte for byte. All are folders, so a path below another one is reachable.
    @Test func ordinaryPathsTreeAsBefore() {
        let paths = Self.ordinary.filter { !$0.isEmpty && !$0.hasPrefix("/") && !$0.hasSuffix("/") && !$0.contains("//") }
        let tree = Archive.tree(from: paths.map { Self.entry($0, directory: true) })
        var count = 0
        func check(_ nodes: [ArchiveNode], under parent: String) {
            for n in nodes {
                count += 1
                #expect(Array(Self.legacyParent(n.entry.path).utf8) == Array(parent.utf8),
                        "\(n.entry.path.debugDescription)")
                #expect(Array(n.entry.name.utf8) == Array(Self.legacyName(n.entry.path).utf8))
                check(n.children ?? [], under: n.entry.path)
            }
        }
        check(tree, under: "")
        #expect(count >= Set(paths.map { Array($0.utf8) }).count)
    }
}
