import Foundation

/// `ArchiveChangeSet.renamedPaths`, checked and normalized, as a prefix map from source paths to final paths.
/// A path goes out under the value of its nearest key (the path itself, else its deepest ancestor that is a key),
/// so renaming a folder moves everything beneath it, implicit folders included.
struct RenameMap {
    /// Normalized source path → normalized final path; renames to the same path are left out.
    let targets: [String: String]

    static let none = RenameMap(targets: [:])

    private init(targets: [String: String]) { self.targets = targets }

    /// Refusals, before anything is written. First every value: `.io` for one that is empty, has an empty, `.` or
    /// `..` component (so no leading or trailing `/`), or contains NUL. Then each key, in sorted order:
    /// - `.entryNotFound(key)`: the key names no entry of the source as listed (implicit folders count); with no
    ///   source every key is missing.
    /// - `.io`: two spellings of one key (`a` and `./a`; NFC and NFD spellings are one key to a Swift dictionary
    ///   already) with different values, or a value inside its own key
    ///   (a folder moved into itself).
    /// Collisions between final paths are checked later, on the kept headers (`RepackCopier.checkFinalPaths`).
    init(_ raw: [String: String], sourcePaths: Set<String>) throws(ArchiveError) {
        var checked: [(key: String, path: String)] = []
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
            guard let path = Self.validated(value) else { throw .io("“\(value)” is not a valid name") }
            checked.append((key, path))
        }
        var targets: [String: String] = [:]
        for (key, path) in checked {
            guard let source = EntryPath.normalize(key), sourcePaths.contains(source) else {
                throw .entryNotFound(key)
            }
            if let other = targets[source], other != path { throw .io("\(source) is renamed twice") }
            if path != source, EntryPath.isSelected(path, by: [source]) {
                throw .io("\(source) cannot be moved into itself")
            }
            targets[source] = path
        }
        self.targets = targets.filter { $0.key != $0.value }
    }

    /// The normalized path for a valid value (every "/"-separated component valid, `EntryPath.isValidComponent`),
    /// nil for an invalid one.
    private static func validated(_ value: String) -> String? {
        let parts = value.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ EntryPath.isValidComponent(String(String.UnicodeScalarView($0))) }) else { return nil }
        return EntryPath.normalize(value)
    }

    var isEmpty: Bool { targets.isEmpty }

    /// The nearest key at or above `path`, if any.
    func key(of path: String) -> String? {
        guard !targets.isEmpty else { return nil }
        if targets[path] != nil { return path }
        return EntryPath.ancestors(of: path).reversed().first { targets[$0] != nil }
    }

    /// Where the source entry at `path` goes out.
    func finalPath(of path: String) -> String {
        guard let key = key(of: path), let target = targets[key] else { return path }
        // Scalar counts: the key is a scalar prefix of the path, followed by "/".
        return target + String(path.unicodeScalars.dropFirst(key.unicodeScalars.count))
    }
}
