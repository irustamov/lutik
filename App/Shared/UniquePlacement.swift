import Foundation

/// Moves an item into a folder under a name nothing else has, never replacing anything: the move
/// that puts Extract Here's result (and the Finder services' archives) next to the original.
enum UniquePlacement {
    /// Tries this many names before giving up with EEXIST, so a folder that refuses every name
    /// (or a broken file system) ends instead of looping.
    static let maxAttempts = 100

    /// Moves `source` into `directory` as `name`, or as the next free Finder name ("name 2",
    /// "report 2.pdf", `FinderCopyName`) when that is taken. Never replaces: the rename is
    /// exclusive (`RENAME_EXCL`), and an item that appears under the name between the check and
    /// the rename (EEXIST) makes it try the next name. On a file system without exclusive renames
    /// (`ArchiveModel.lacksExclusiveRename`) it checks, then renames plainly: the check is the lookup
    /// (`fileSystem.exists`) and, where the volume may fold case, a case twin in the folder
    /// (`CaseTwinListings`: listed once per placement, at its first check); either takes the next name.
    /// `source` must be on the same volume (a rename, not a copy). Any other failure throws its
    /// `POSIXError` and leaves `source` where it was. `nextName` names the next try (Finder's by
    /// default; the Finder services pass their own): it gets the name in the way, whether the item is a folder, and a
    /// test for names already taken here (the same lookup).
    /// Never into a folder that resolves outside `directory` (`ArchiveModel.checkContained`: a name with a
    /// hidden "/" must not reach through a symlink beside the archive); that throws
    /// `ExtractionContainmentError` and leaves `source` where it was.
    /// Returns the item's new URL, a folder's as a directory URL.
    @discardableResult
    static func place(_ source: URL, named name: String, in directory: URL, isDirectory: Bool,
                      fileSystem: ExtractionFileSystem = .system,
                      nextName: (_ name: String, _ isDirectory: Bool, _ isTaken: (String) -> Bool) -> String
                          = FinderCopyName.next) throws -> URL {
        let isTaken = { fileSystem.exists(directory.appendingPathComponent($0).path) }
        var name = isTaken(name) ? nextName(name, isDirectory, isTaken) : name
        // One placement is one operation: its own folder listings, gone when it returns.
        let twins = CaseTwinListings()
        for _ in 0..<maxAttempts {
            let target = directory.appendingPathComponent(name, isDirectory: isDirectory)
            try ArchiveModel.checkContained(target, in: directory)
            switch fileSystem.rename(source.path, target.path, UInt32(RENAME_EXCL)) {
            case 0:
                return target
            case EEXIST:
                break
            case let error where ArchiveModel.lacksExclusiveRename(error):
                // A folder that can't be listed for permission (EACCES, EPERM: a write-only drop box) fails open on
                // purpose; exists() still refuses the exact name. Any other listing error throws: nothing is renamed.
                let plain = try twins.renamePlainly(source, to: target, fileSystem: fileSystem)
                if plain == 0 { return target }
                if plain != EEXIST { throw posixError(plain) }
            case let error:
                throw posixError(error)
            }
            name = nextName(name, isDirectory, isTaken)
        }
        throw POSIXError(.EEXIST)
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
