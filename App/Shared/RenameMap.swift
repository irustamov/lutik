import Foundation
import KernirCore

/// Source path -> final path, applied as a prefix map (nearest renamed ancestor wins), so renaming a folder
/// moves everything beneath it, including entries below an implicit folder. Paths are not normalized: source paths are the reader's exact
/// entry paths (the engine throws `.entryNotFound` for any other key), finals are as typed; no trailing "/".
/// `sourceToFinal` becomes `ArchiveChangeSet.renamedPaths`.
struct RenameMap: Equatable, Sendable {
    var sourceToFinal: [String: String]

    init(_ sourceToFinal: [String: String] = [:]) {
        self.sourceToFinal = sourceToFinal
    }

    func finalPath(ofSource path: String) -> String {
        Self.longestMatch(of: path, in: sourceToFinal.map { ($0.key, $0.value) }) ?? path
    }

    /// The key that governs `path`: the longest one at or above it (by bytes, as `finalPath(ofSource:)` matches).
    func key(of path: String) -> String? {
        var best: String?
        for key in sourceToFinal.keys where key.utf8.count > (best?.utf8.count ?? -1) {
            if Self.relocate(path, from: key, to: key) != nil { best = key }
        }
        return best
    }

    /// Identity when nothing maps there.
    func sourcePath(ofFinal path: String) -> String {
        Self.longestMatch(of: path, in: sourceToFinal.map { ($0.value, $0.key) }) ?? path
    }

    /// Renames whatever is visible at `finalPath` to `newFinalPath`. Folds chains, rewrites descendants' finals,
    /// drops entries whose final equals their natural final.
    mutating func rename(finalPath: String, to newFinalPath: String) {
        let source = sourcePath(ofFinal: finalPath)
        for (key, value) in sourceToFinal where key != source {
            if let moved = Self.relocate(value, from: finalPath, to: newFinalPath) { sourceToFinal[key] = moved }
        }
        sourceToFinal[source] = newFinalPath
        dropNoOps()
    }

    /// Moves every final at or beneath `finalPath` to beneath `newFinalPath`, keys untouched: what was moved into
    /// a folder that is no source entry (a pending one) follows it when it is renamed or moved.
    mutating func moveFinals(from finalPath: String, to newFinalPath: String) {
        for (key, value) in sourceToFinal {
            if let moved = Self.relocate(value, from: finalPath, to: newFinalPath) { sourceToFinal[key] = moved }
        }
        dropNoOps()
    }

    /// Drops entries whose final equals their natural final (what the other entries make of them).
    mutating func dropNoOps() {
        // Removing an entry that changes nothing changes no other final either, so order does not matter.
        for (key, value) in sourceToFinal {
            var others = self
            others.sourceToFinal[key] = nil
            if others.finalPath(ofSource: key) == value { sourceToFinal[key] = nil }
        }
    }

    /// Finder metadata companions that move with `sourcePath` (d/._n, __MACOSX/d/n, __MACOSX/d/._n), restricted
    /// to `existing`. Keys are source paths next to `sourcePath`; values sit next to `newFinalPath`.
    static func companionMoves(of sourcePath: String, to newFinalPath: String, existing: Set<String>) -> [String: String] {
        let (oldDir, oldName) = split(sourcePath)
        let (newDir, newName) = split(newFinalPath)
        let candidates = [
            (oldDir + "._" + oldName, newDir + "._" + newName),
            ("__MACOSX/" + sourcePath, "__MACOSX/" + newFinalPath),
            ("__MACOSX/" + oldDir + "._" + oldName, "__MACOSX/" + newDir + "._" + newName),
        ]
        var moves: [String: String] = [:]
        for (from, to) in candidates where existing.contains(from) { moves[from] = to }
        return moves
    }

    // MARK: - Path helpers

    /// `path` with the longest matching `from` prefix replaced by its `to`; nil when none matches.
    private static func longestMatch(of path: String, in pairs: [(from: String, to: String)]) -> String? {
        var best: (length: Int, result: String)?
        for (from, to) in pairs where from.utf8.count > (best?.length ?? -1) {
            if let result = relocate(path, from: from, to: to) { best = (from.utf8.count, result) }
        }
        return best?.result
    }

    /// `path` moved from under `old` to under `new` (component-wise), or nil when `path` is not `old` or beneath it.
    private static func relocate(_ path: String, from old: String, to new: String) -> String? {
        let pathBytes = path.utf8, oldBytes = old.utf8
        guard pathBytes.starts(with: oldBytes) else { return nil }
        let rest = path.utf8.index(path.startIndex, offsetBy: oldBytes.count)
        if rest == path.endIndex { return new }
        guard pathBytes[rest] == UInt8(ascii: "/") else { return nil }
        return new + String(path[rest...])
    }

    /// ("d/", "n") for "d/n"; ("", "n") at the top level. On the "/" scalar (`ArchiveEntry.parentPath(of:)`,
    /// `name(of:)`), never on Characters: "/" with a combining mark or ZWJ after it, or a Prepend scalar
    /// before it, is one Character that is not "/", so `lastIndex(of: "/")` misses `d/\u{301}n`'s folder.
    private static func split(_ path: String) -> (dirPrefix: String, name: String) {
        let directory = ArchiveEntry.parentPath(of: path)
        return (directory.isEmpty ? "" : directory + "/", ArchiveEntry.name(of: path))
    }
}

/// The writer's rule for `ArchiveChangeSet.removedPaths` (KernirCore's `RepackCopier.isRemoved`, mirrored exactly):
/// a source entry at or beneath a removed path is dropped, unless the rename key that governs it
/// (`RenameMap.key(of:)`) lies strictly beneath every removed path at or above it and the key's own final path is
/// neither the final path of one of those nor strictly beneath the final path of any removed path: an item moved out
/// of a removed folder stays. The key decides for its whole subtree, so a folder moved out keeps everything beneath
/// it, even where that lands at or beneath a removed path's final path (one the moved folder now fills). Paths as
/// the reader and `renamedPaths` spell them; Set lookups and `==` fold NFC and NFD.
struct RemovalRule {
    let removed: Set<String>
    let renames: RenameMap
    private let removedFinals: Set<String>

    init(removed: Set<String>, renames: RenameMap) {
        self.removed = removed
        self.renames = renames
        removedFinals = renames.sourceToFinal.isEmpty ? removed : Set(removed.map(renames.finalPath(ofSource:)))
    }

    /// True when the writer drops the source entry `path`.
    func drops(_ path: String) -> Bool {
        guard !removed.isEmpty else { return false }
        // Removed paths at or above `path`, deepest first.
        var above: [String] = []
        var current = path
        while !current.isEmpty {
            if removed.contains(current) { above.append(current) }
            current = ArchiveEntry.parentPath(of: current)
        }
        guard let deepest = above.first else { return false }
        guard let key = renames.key(of: path), Self.isStrictlyBeneath(key, deepest) else { return true }
        let keyFinal = renames.finalPath(ofSource: key)
        if above.contains(where: { renames.finalPath(ofSource: $0) == keyFinal }) { return true }
        var ancestor = ArchiveEntry.parentPath(of: keyFinal)
        while !ancestor.isEmpty {
            if removedFinals.contains(ancestor) { return true }
            ancestor = ArchiveEntry.parentPath(of: ancestor)
        }
        return false
    }

    private static func isStrictlyBeneath(_ path: String, _ folder: String) -> Bool {
        var ancestor = ArchiveEntry.parentPath(of: path)
        while !ancestor.isEmpty {
            if ancestor == folder { return true }
            ancestor = ArchiveEntry.parentPath(of: ancestor)
        }
        return false
    }
}
