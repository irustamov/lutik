import Foundation
import KernirCore

extension ArchiveError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            String(localized: "This file isn't a supported archive.", table: "Shared")
        case .passwordRequired:
            String(localized: "This archive is password protected.", table: "Shared")
        case .wrongPassword:
            String(localized: "The password is incorrect.", table: "Shared")
        case .unsupportedEncryption(let format):
            String(localized: "Encrypted \(format.displayName) archives aren't supported yet.", table: "Shared")
        case .readOnlyFormat(let format):
            String(localized: "\(format.displayName) archives can only be read.", table: "Shared")
        case .corrupted:
            String(localized: "The archive is damaged and can't be read completely.", table: "Shared")
        case .entryNotFound:
            String(localized: "The item couldn't be found in the archive.", table: "Shared")
        case .io:
            String(localized: "The file couldn't be read or written.", table: "Shared")
        case .cancelled:
            String(localized: "The operation was cancelled.", table: "Shared")
        case .notImplemented:
            String(localized: "This feature isn't available yet.", table: "Shared")
        }
    }

    /// The same text: AppKit's open alert shows "The document “x” could not be opened." followed
    /// by the failure reason (never the description), then the recovery suggestion.
    public var failureReason: String? { errorDescription }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFormat:
            String(localized: "Choose a ZIP, 7z, RAR, TAR or other supported archive.", table: "Shared")
        case .passwordRequired:
            String(localized: "Enter the password to open it.", table: "Shared")
        case .wrongPassword:
            String(localized: "Check the password and try again.", table: "Shared")
        case .unsupportedEncryption:
            String(localized: "Decrypt it with another app first, or use a ZIP archive.", table: "Shared")
        case .readOnlyFormat:
            String(localized: "Use Save As to save a copy as ZIP or 7z.", table: "Shared")
        case .corrupted(let detail), .io(let detail):
            detail.isEmpty ? nil : detail
        case .entryNotFound, .cancelled, .notImplemented:
            nil
        }
    }
}

extension ArchiveVolumeError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch reason {
        case .missing:
            if let part {
                String(localized: "Part \(part) of “\(setName)” is missing.", table: "Shared")
            } else {
                String(localized: "The last part of “\(setName)” is missing.", table: "Shared")
            }
        case .noAccess:
            String(localized: "This archive is split into parts.", table: "Shared")
        }
    }

    /// The same text, for the same reason as `ArchiveError.failureReason`.
    public var failureReason: String? { errorDescription }

    public var recoverySuggestion: String? {
        switch reason {
        case .missing:
            String(localized: "Put all parts in one folder and open the archive again.", table: "Shared")
        case .noAccess:
            String(localized: "Lutik needs access to the folder that holds them.", table: "Shared")
        }
    }
}

/// KernirCore's refusal at open of an archive that nests too deeply or whose names are too big for it.
extension ArchiveNestingError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch limit {
        case .depth, .folderBytes, .ancestorWork:
            String(localized: "This archive nests folders too deeply.", table: "Shared")
        case .pathLength, .totalPathBytes, .combiningMarks:
            String(localized: "This archive's file names are too long or too complex to open.", table: "Shared")
        case .entryCount:
            String(localized: "This archive has too many files to open.", table: "Shared")
        }
    }

    /// The same text, for the same reason as `ArchiveError.failureReason`.
    public var failureReason: String? { errorDescription }
}

extension ArchiveVolumeError {
    /// Whether the locked view offers Grant Access…. A part that looks missing may only be
    /// unreadable (the sandbox hides it), so `.missing` offers it too.
    public var offersGrantAccess: Bool {
        switch reason {
        case .noAccess, .missing: true
        }
    }

    /// Whether `picked` is the folder that holds the parts: the same file identity (volume and
    /// file ID) or the same standardized path with symlinks resolved, so either one matching is enough.
    /// Another folder (a subfolder, a parent, a lookalike) gets the `wrongFolderTitle` alert.
    func isFolderOfParts(_ picked: URL) -> Bool {
        if Self.sameFolderByIdentity(picked, folder) == true { return true }
        func normalized(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        return normalized(picked) == normalized(folder)
    }

    /// nil when either folder has no volume or file identifier. The URLs are rebuilt from the
    /// resolved path (a symlink has an identity of its own), so values cached before access was granted aren't reused.
    private static func sameFolderByIdentity(_ a: URL, _ b: URL) -> Bool? {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .fileResourceIdentifierKey]
        func identity(_ url: URL) -> (volume: NSObjectProtocol, file: NSObjectProtocol)? {
            let fresh = URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path)
            guard let values = try? fresh.resourceValues(forKeys: keys),
                  let volume = values.volumeIdentifier, let file = values.fileResourceIdentifier
            else { return nil }
            return (volume, file)
        }
        guard let x = identity(a), let y = identity(b) else { return nil }
        return x.volume.isEqual(y.volume) && x.file.isEqual(y.file)
    }

    /// The alert after the user granted a folder other than the one that holds the parts. It names
    /// no file: `setName` is part 1's, which may be the missing one.
    var wrongFolderTitle: String {
        String(localized: "That folder doesn't contain this archive's other parts.", table: "Shared")
    }

    var wrongFolderMessage: String {
        String(localized: "Choose the folder that holds all parts of this archive.", table: "Shared")
    }

    /// Whether a retry after granting the right folder failed the same way as `other`: on the same
    /// part and file name (the reason may differ). Then `stillUnreadableTitle` says so; another part
    /// is a new error the locked view shows by itself.
    func isSameFailure(as other: ArchiveVolumeError) -> Bool {
        part == other.part && fileName == other.fileName
    }

    /// The alert after the right folder was granted but the reopen failed the same way again.
    var stillUnreadableTitle: String {
        switch reason {
        case .missing:
            if let part {
                String(localized: "Part \(part) is still missing.", table: "Shared")
            } else {
                String(localized: "The last part is still missing.", table: "Shared")
            }
        case .noAccess:
            String(localized: "Lutik still can't read the other parts.", table: "Shared")
        }
    }

    var stillUnreadableMessage: String {
        String(localized: "Make sure every part is downloaded and in this folder, then try again.", table: "Shared")
    }

    /// Thrown when a save would write over one of a set's parts (a set is read-only, so only a
    /// backstop reaches this). Still `.fileWriteUnknown`, with words for the user.
    static var saveInPlaceError: CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "A split archive can't be saved in place. Use Save As Copy.",
                                              table: "Shared"),
        ])
    }
}

extension ExtractionConflictError: @retroactive LocalizedError {
    public var errorDescription: String? {
        if paths.count == 1, let path = paths.first {
            let name = ArchiveEntry.name(of: path)
            return String(localized: "“\(name)” already exists.", table: "Shared")
        }
        return String(localized: "\(paths.count) items already exist.", table: "Shared")
    }

    public var failureReason: String? { errorDescription }
}

extension ExtractionContainmentError: LocalizedError {
    var errorDescription: String? {
        let folder = destination.lastPathComponent
        // True wherever the link leads (outside, inside, nowhere): the refusal is that it is a link at all.
        return String(localized: "“\(name)” wasn't extracted to “\(folder)”: its path has a link where a folder was expected.",
                      table: "Shared")
    }

    var failureReason: String? { errorDescription }
}

extension ExtractionRecoveryError: LocalizedError {
    var errorDescription: String? {
        let keptName = kept.lastPathComponent
        return switch kind {
        case .renamed:
            String(localized: "“\(name)” couldn't be replaced. The original is now named “\(keptName)”.", table: "Shared")
        case .inFolder:
            inFolderDescription(keptName: keptName)
        }
    }

    var failureReason: String? { errorDescription }

    /// A folder inside a hidden one (staging, when even the recovered folder couldn't move out) is
    /// named with it: Files doesn't show hidden folders and iOS has no reveal, so the text must do.
    private func inFolderDescription(keptName: String) -> String {
        let parentName = kept.deletingLastPathComponent().lastPathComponent
        guard parentName.hasPrefix(".") else {
            return String(localized: "“\(name)” couldn't be replaced. The original is in “\(keptName)”.", table: "Shared")
        }
        return String(localized: "“\(name)” couldn't be replaced. The original is in “\(keptName)”, inside the hidden folder “\(parentName)”.",
                      table: "Shared")
    }
}
