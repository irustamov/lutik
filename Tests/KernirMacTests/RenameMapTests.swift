import Testing
@testable import Kernir

struct RenameMapTests {
    @Test func simpleFile() {
        var map = RenameMap()
        map.rename(finalPath: "a/x.txt", to: "a/y.txt")
        #expect(map.finalPath(ofSource: "a/x.txt") == "a/y.txt")
        #expect(map.sourcePath(ofFinal: "a/y.txt") == "a/x.txt")
        #expect(map.finalPath(ofSource: "a/z.txt") == "a/z.txt")
        #expect(map.sourcePath(ofFinal: "a/z.txt") == "a/z.txt")
    }

    @Test func folderPrefix() {
        var map = RenameMap()
        map.rename(finalPath: "a", to: "b")
        #expect(map.sourceToFinal == ["a": "b"])
        #expect(map.finalPath(ofSource: "a") == "b")
        #expect(map.finalPath(ofSource: "a/c/d.txt") == "b/c/d.txt")
        #expect(map.sourcePath(ofFinal: "b/c/d.txt") == "a/c/d.txt")
        #expect(map.finalPath(ofSource: "ab/x") == "ab/x")
        #expect(map.sourcePath(ofFinal: "bc/x") == "bc/x")
    }

    /// "a/b" is a byte prefix of "a/bc/x" but not its ancestor: matching stops at a "/" boundary.
    @Test func nestedSiblingWithSharedPrefixIsNotMoved() {
        var map = RenameMap()
        map.rename(finalPath: "a/b", to: "a/z")
        #expect(map.finalPath(ofSource: "a/bc/x") == "a/bc/x")
        #expect(map.finalPath(ofSource: "a/b/x") == "a/z/x")
        #expect(map.sourcePath(ofFinal: "a/zc/x") == "a/zc/x")
        #expect(map.sourcePath(ofFinal: "a/z/x") == "a/b/x")
    }

    @Test func deepNestedSiblingWithSharedPrefixIsNotMoved() {
        var map = RenameMap()
        map.rename(finalPath: "p/q/r", to: "p/q/s")
        #expect(map.finalPath(ofSource: "p/q/rs/t/u") == "p/q/rs/t/u")
        #expect(map.finalPath(ofSource: "p/q/r/t/u") == "p/q/s/t/u")
        #expect(map.sourcePath(ofFinal: "p/q/ss/t/u") == "p/q/ss/t/u")
    }

    /// A renamed entry under the prefix-sharing sibling keeps its final path when the shorter folder is renamed.
    @Test func renamingAFolderLeavesAPrefixSharingSiblingsRenameAlone() {
        var map = RenameMap()
        map.rename(finalPath: "a/bc/x", to: "a/bc/y")
        map.rename(finalPath: "a/b", to: "a/z")
        #expect(map.sourceToFinal == ["a/bc/x": "a/bc/y", "a/b": "a/z"])
        #expect(map.finalPath(ofSource: "a/bc/x") == "a/bc/y")
        #expect(map.sourcePath(ofFinal: "a/bc/y") == "a/bc/x")
    }

    @Test func chainFolds() {
        var map = RenameMap()
        map.rename(finalPath: "x", to: "y")
        map.rename(finalPath: "y", to: "z")
        #expect(map.sourceToFinal == ["x": "z"])
    }

    @Test func renameBackClears() {
        var map = RenameMap()
        map.rename(finalPath: "x", to: "y")
        map.rename(finalPath: "y", to: "x")
        #expect(map.sourceToFinal == [:])
    }

    /// The child keeps its new name, the folder gets its old one back.
    @Test func nestedRenamesFold() {
        var map = RenameMap()
        map.rename(finalPath: "a", to: "b")
        map.rename(finalPath: "b/x", to: "b/y")
        map.rename(finalPath: "b", to: "a")
        #expect(map.sourceToFinal == ["a/x": "a/y"])
        #expect(map.finalPath(ofSource: "a/x/z") == "a/y/z")
        #expect(map.sourcePath(ofFinal: "a/y/z") == "a/x/z")
    }

    @Test func renamingAFolderMovesARenamedChild() {
        var map = RenameMap()
        map.rename(finalPath: "a/x", to: "a/y")
        map.rename(finalPath: "a", to: "b")
        #expect(map.sourceToFinal == ["a": "b", "a/x": "b/y"])
        #expect(map.finalPath(ofSource: "a/x") == "b/y")
        #expect(map.finalPath(ofSource: "a/w") == "b/w")
        #expect(map.sourcePath(ofFinal: "b/y") == "a/x")
    }

    @Test func swappedNamesMapBothWays() {
        var map = RenameMap()
        map.rename(finalPath: "a", to: "tmp")
        map.rename(finalPath: "b", to: "a")
        map.rename(finalPath: "tmp", to: "b")
        #expect(map.sourceToFinal == ["a": "b", "b": "a"])
        #expect(map.finalPath(ofSource: "a/f") == "b/f")
        #expect(map.sourcePath(ofFinal: "a/f") == "b/f")
    }

    @Test func companionMoves() {
        let existing: Set<String> = ["d/._n", "__MACOSX/d/n", "__MACOSX/d/._n"]
        #expect(RenameMap.companionMoves(of: "d/n", to: "d/m", existing: existing) == [
            "d/._n": "d/._m",
            "__MACOSX/d/n": "__MACOSX/d/m",
            "__MACOSX/d/._n": "__MACOSX/d/._m",
        ])
        #expect(RenameMap.companionMoves(of: "d/n", to: "d/m", existing: ["d/._n"]) == ["d/._n": "d/._m"])
        #expect(RenameMap.companionMoves(of: "d/n", to: "d/m", existing: []) == [:])
    }

    @Test func companionMovesAtTopLevel() {
        let existing: Set<String> = ["._n", "__MACOSX/n", "__MACOSX/._n"]
        #expect(RenameMap.companionMoves(of: "n", to: "m", existing: existing) == [
            "._n": "._m",
            "__MACOSX/n": "__MACOSX/m",
            "__MACOSX/._n": "__MACOSX/._m",
        ])
    }

    /// The companions sit next to the source entry, split on the "/" scalar: a name that starts with a
    /// combining mark, or a folder that ends in a Prepend scalar, hides the "/" in one Character.
    @Test(arguments: [("d", "\u{301}n", "\u{301}m"), ("x\u{600}", "n", "m")])
    func companionMovesBehindAHiddenSlash(_ folder: String, _ old: String, _ new: String) {
        let existing: Set<String> = [folder + "/._" + old, "__MACOSX/" + folder + "/" + old,
                                     "__MACOSX/" + folder + "/._" + old]
        let moves = RenameMap.companionMoves(of: folder + "/" + old, to: folder + "/" + new, existing: existing)
        let expected = [
            folder + "/._" + old: folder + "/._" + new,
            "__MACOSX/" + folder + "/" + old: "__MACOSX/" + folder + "/" + new,
            "__MACOSX/" + folder + "/._" + old: "__MACOSX/" + folder + "/._" + new,
        ]
        // Byte-exact: String's == would take canonically equivalent spellings as one.
        #expect(Set(moves.map { [$0.key, $0.value].map { Array($0.utf8) } }) ==
                Set(expected.map { [$0.key, $0.value].map { Array($0.utf8) } }))
    }

    /// The companions sit next to the source entry; they go out next to its new final path.
    @Test func companionMovesFollowARenamedParent() {
        let existing: Set<String> = ["d/._n", "__MACOSX/d/n"]
        #expect(RenameMap.companionMoves(of: "d/n", to: "e/m", existing: existing) == [
            "d/._n": "e/._m",
            "__MACOSX/d/n": "__MACOSX/e/m",
        ])
    }
    /// A folder that is no source entry (a pending one) moves what was moved into it: values at or beneath its
    /// path follow, keys stay; a value that lands back on its natural place is dropped.
    @Test func moveFinals() {
        var map = RenameMap(["docs/a.txt": "untitled folder/a.txt", "b": "untitled folder/sub/b",
                             "c": "untitled folderx/c", "e": "f"])
        map.moveFinals(from: "untitled folder", to: "Photos")
        #expect(map.sourceToFinal == ["docs/a.txt": "Photos/a.txt", "b": "Photos/sub/b",
                                      "c": "untitled folderx/c", "e": "f"])

        var back = RenameMap(["x/a": "n/a"])
        back.moveFinals(from: "n", to: "x")
        #expect(back.sourceToFinal.isEmpty)
    }
}

/// `RemovalRule` mirrors KernirCore's `RepackCopier.isRemoved`: the cases of KernirCore's `RenameTests`
/// (removekeep2), as final path -> source path of what the writer keeps.
struct RemovalRuleTests {
    private func kept(_ paths: [String], removed: Set<String>, renames: [String: String]) -> [String: String] {
        let map = RenameMap(renames)
        let rule = RemovalRule(removed: removed, renames: map)
        var kept: [String: String] = [:]
        for path in paths where !rule.drops(path) { kept[map.finalPath(ofSource: path)] = path }
        return kept
    }

    /// Route 1: d/a moved into e over e/a, then Delete d: the key's final decides, so d/a keeps its subtree.
    @Test func folderEscapingOntoAFreedRemovedNameKeepsItsSubtree() {
        let paths = ["d", "d/a", "d/a/x.txt", "d/a/b", "d/a/b/y.txt", "d/c.txt",
                     "e", "e/a", "e/a/old.txt", "e/a/b", "e/a/b/old.txt", "e/c.txt", "keep.txt"]
        #expect(kept(paths, removed: ["d", "e/a"], renames: ["d/a": "e/a"])
                == ["e": "e", "e/c.txt": "e/c.txt", "e/a": "d/a", "e/a/x.txt": "d/a/x.txt",
                    "e/a/b": "d/a/b", "e/a/b/y.txt": "d/a/b/y.txt", "keep.txt": "keep.txt"])
    }

    /// Route 2: Delete a, d/a moved to the top level, then Delete d.
    @Test func folderEscapingToTheTopLevelOntoARemovedNameKeepsItsSubtree() {
        let paths = ["a", "a/old.txt", "a/b", "a/b/old.txt", "d", "d/a", "d/a/x.txt", "d/a/b", "d/a/b/y.txt",
                     "d/c.txt", "keep.txt"]
        #expect(kept(paths, removed: ["d", "a"], renames: ["d/a": "a"])
                == ["a": "d/a", "a/x.txt": "d/a/x.txt", "a/b": "d/a/b", "a/b/y.txt": "d/a/b/y.txt",
                    "keep.txt": "keep.txt"])
    }

    /// A key moved strictly beneath another removed folder's final path drops its subtree, renamed folder or not.
    @Test func folderEscapingIntoAnotherRemovedFolderIsDroppedWithItsSubtree() {
        let paths = ["d", "d/a", "d/a/x.txt", "d/a/b", "d/a/b/y.txt", "e", "e/c.txt", "keep.txt"]
        #expect(kept(paths, removed: ["d", "e"], renames: ["d/a": "e/q"]) == ["keep.txt": "keep.txt"])
        #expect(kept(paths, removed: ["d", "e"], renames: ["e": "f", "d/a": "f/q"]) == ["keep.txt": "keep.txt"])
    }

    /// e/d/a moved onto e, e/d removed: e/d/a/d/y.txt (final e/d/y.txt) is kept and fills the freed e/d.
    @Test func keyMovedOntoAnAncestorOfTheRemovedFolderKeepsItsSubtree() {
        #expect(kept(["e/d", "e/d/a", "e/d/a/d", "e/d/a/d/y.txt", "e/d/b.txt"],
                     removed: ["e/d"], renames: ["e/d/a": "e"])
                == ["e": "e/d/a", "e/d": "e/d/a/d", "e/d/y.txt": "e/d/a/d/y.txt"])
    }

    /// An inner key inside the removed folder overrides the escaping outer key.
    @Test func innerKeyInsideTheRemovedFolderOverridesTheEscapingOuterKey() {
        #expect(kept(["d", "d/a", "d/a/f.txt", "d/a/b", "d/a/b/g.txt"],
                     removed: ["d"], renames: ["d/a": "x", "d/a/b": "d/b"])
                == ["x": "d/a", "x/f.txt": "d/a/f.txt"])
    }

    /// A removed path strictly beneath the escaping key stays deleted.
    @Test func removedPathBeneathTheEscapingKeyStaysDeleted() {
        #expect(kept(["d", "d/a", "d/a/f.txt", "d/a/b", "d/a/b/g.txt"],
                     removed: ["d", "d/a/b"], renames: ["d/a": "x"])
                == ["x": "d/a", "x/f.txt": "d/a/f.txt"])
    }

    /// Moved within the folder it leaves, or a removed entry that is renamed itself: dropped.
    @Test func movedWithinTheRemovedFolderOrRenamedItselfIsDropped() {
        #expect(kept(["d", "d/a", "d/a/x.txt", "keep.txt"], removed: ["d"], renames: ["d/a": "d/b"])
                == ["keep.txt": "keep.txt"])
        #expect(kept(["d", "d/a", "d/a/x.txt", "keep.txt"], removed: ["d"], renames: ["d": "e"])
                == ["keep.txt": "keep.txt"])
    }
}
