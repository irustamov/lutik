import Foundation

/// Finder's names for a copy beside an item that is in the way: "name 2" for folders,
/// "report 2.pdf" for files, then 3, 4… Shared by Extract Here and the Finder services.
/// The same rules as `ArchiveModel`'s Keep Both; `ExtractHereNamingTests` keeps the two in step.
enum FinderCopyName {
    /// The first Finder-style name after `name` that `isTaken` accepts as free: "name 2",
    /// "report 2.pdf". A name ending in a copy number (" 2"… " 999", no leading zero) counts on
    /// from it, as Finder does: "name 2.ext" gives "name 3.ext", not "name 2 2.ext". Any other
    /// number is part of the name: "Report 2024.pdf" gives "Report 2024 2.pdf". A folder's name is
    /// never split at a dot ("v1.2" gives "v1.2 2"), and a dotfile has no extension (".env 2").
    static func next(after name: String, isDirectory: Bool, isTaken: (String) -> Bool) -> String {
        let fileExtension = isDirectory ? "" : (name as NSString).pathExtension
        var base = fileExtension.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 2
        if let space = base.lastIndex(of: " "), space > base.startIndex {
            let digits = base[base.index(after: space)...]
            if digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.first != "0",
               let copy = Int(digits), (2..<1000).contains(copy) {
                base = String(base[..<space])
                number = copy + 1
            }
        }
        while true {
            let candidate = fileExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(fileExtension)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// `name` itself when nothing is at it in `directory` (lstat: a dangling symlink is in the way
    /// too) and it isn't in `reserved`, else `next(after:isDirectory:isTaken:)` by the same test.
    /// `reserved` holds names the same operation writes; they compare as the default volumes
    /// compare names, ignoring case and Unicode normalization. Only a check: the caller's move
    /// must still refuse to replace (`UniquePlacement`).
    static func free(_ name: String, isDirectory: Bool, in directory: URL, reserved: Set<String> = []) -> String {
        let reservedKeys = Set(reserved.map(folded))
        let isTaken = { (candidate: String) -> Bool in
            var status = stat()
            return reservedKeys.contains(folded(candidate))
                || lstat(directory.appendingPathComponent(candidate).path, &status) == 0
        }
        return isTaken(name) ? next(after: name, isDirectory: isDirectory, isTaken: isTaken) : name
    }

    /// `name` as the default (case- and normalization-insensitive) volumes compare names.
    private static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Names for Extract Here's results.
enum ExtractHereNaming {
    /// The folder that holds an archive's items when there is more than one: the archive's base
    /// name (`ArchiveBaseName`), "project" for project.zip and project.tar.gz, "notes.txt" for
    /// notes.txt. A split archive's is the set's name: "Photos" for Photos.part1.rar and Photos.zip.001.
    /// A base name that would be "", "." or ".." is the archive's own file name instead ("...part1.rar").
    static func folderName(for archiveURL: URL, isVolumeSet: Bool) -> String {
        ArchiveBaseName.of(archiveURL.lastPathComponent, isVolumeSet: isVolumeSet)
    }
}
