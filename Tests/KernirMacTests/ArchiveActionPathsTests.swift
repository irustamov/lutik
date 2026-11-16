import Testing
import Foundation
@testable import Kernir
import KernirCore

// A "/" followed by a combining mark (U+0301) or a ZWJ, or preceded by a Prepend scalar (U+0600), is part of one
// Character that is not "/". Archive paths split on the "/" scalar. Paths and names compare by scalars: String's
// `==` is canonical equivalence.

private func scalars(_ string: String) -> [Unicode.Scalar] { Array(string.unicodeScalars) }

/// The alerts (Add → Replace, extraction conflicts) name an item by its last scalar component.
@Test(arguments: [
    ("d/\u{301}x", "\u{301}x"), ("d/\u{200D}x", "\u{200D}x"), ("d\u{600}/x", "x"), ("d\u{600}/x/y", "y"),
    ("d/x\u{600}/y", "y"), ("d/e/\u{301}x", "\u{301}x"), ("a/b.txt", "b.txt"), ("top", "top"),
    ("e\u{301}/f", "f"),
])
func displayNameIsTheLastScalarComponent(path: String, name: String) {
    let shown = ArchiveActionPaths.displayName(of: path)
    #expect(scalars(shown) == scalars(name))
    #expect(!shown.unicodeScalars.contains("/"))
}

/// Quick Look and Open order items by these chains: every folder above the item, outermost first, then the item.
@Test(arguments: [
    ("d/\u{301}x", ["d", "d/\u{301}x"]),
    ("d/\u{200D}x", ["d", "d/\u{200D}x"]),
    ("d\u{600}/x", ["d\u{600}", "d\u{600}/x"]),
    ("d\u{600}/x/y", ["d\u{600}", "d\u{600}/x", "d\u{600}/x/y"]),
    ("d/e/\u{301}x", ["d", "d/e", "d/e/\u{301}x"]),
    ("a/b.txt", ["a", "a/b.txt"]),
    ("top", ["top"]),
    ("e\u{301}/f", ["e\u{301}", "e\u{301}/f"]),
])
func chainListsEveryFolderAboveAnItemBehindAHiddenSlash(path: String, expected: [String]) {
    #expect(ArchiveActionPaths.chain(of: path).map(scalars) == expected.map(scalars))
}

/// `ArchiveActions.ordered` sorts the chains `items(chainOf:in:)` gives and drops a path whose chain is nil. Every
/// item of a model, a hidden "/" in its path or not, keeps a chain, and the chain is the item's own folders in the
/// window, outermost first, then the item: Quick Look and Open keep every item and put a folder before what it
/// holds. The model's tree decides where an item sits, so the chain never names a folder the window doesn't show.
@MainActor @Test func everyItemKeepsItsChainOfFoldersInTheModel() throws {
    let paths = ["d/\u{301}x", "d/\u{200D}y", "p\u{600}/q/r", "s/t/\u{301}u", "a/b.txt", "top", "e\u{301}/f",
                 "g/h/i.txt"]
    let entries = paths.map {
        ArchiveEntry(path: $0, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }
    let model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
    var visited = 0
    func walk(_ directory: String, folders: [ArchiveItem]) throws {
        for item in model.children(of: directory) {
            visited += 1
            let chain = try #require(ArchiveActionPaths.items(chainOf: item.path, in: model),
                                     "\(item.path.debugDescription) is dropped")
            #expect(chain.map { scalars($0.path) } == (folders + [item]).map { scalars($0.path) })
            if item.isDirectory { try walk(item.path, folders: folders + [item]) }
        }
    }
    try walk("", folders: [])
    #expect(visited >= paths.count)
    #expect(ArchiveActionPaths.items(chainOf: "missing", in: model) == nil)
}

/// A folder above an item that the model doesn't hold is left out, and the item keeps its chain. The core's tree
/// creates every folder above a normalized path, so only a path the core never produces gets here: `a/b//c/f`
/// (an empty component) sits in folders `a/b/` and `a/b//c`, while its chain names `a/b/c`.
@MainActor @Test func aFolderTheModelLacksIsLeftOutOfTheChain() throws {
    let entries = [
        ArchiveEntry(path: "a", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
        ArchiveEntry(path: "a/b//c/f", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
    ]
    let model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
    #expect(ArchiveActionPaths.chain(of: "a/b//c/f") == ["a", "a/b", "a/b/c", "a/b/c/f"])
    #expect(model.item(at: "a/b") != nil)
    #expect(model.item(at: "a/b/c") == nil)
    let chain = try #require(ArchiveActionPaths.items(chainOf: "a/b//c/f", in: model), "the item is dropped")
    #expect(chain.map(\.path) == ["a", "a/b", "a/b//c/f"])
}
