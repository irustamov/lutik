import Foundation

/// Why a proposed entry name is refused.
enum EntryNameProblem: Error, Equatable, Sendable {
    case empty, containsSlash, reserved, hiddenMetadata, tooLong
    /// The proposed name as typed.
    case taken(String)
    /// Nothing can be renamed here: the item is gone, or the archive can't be edited (`ArchiveModel.rename`).
    case unavailable
    /// Until a save, the name of a deleted folder items were moved out of (`MoveProblem.holdsMovedOutItems`).
    case holdsMovedOutItems(String)
}

enum EntryNameCheck: Equatable, Sendable {
    /// Same name as the item's own (after NFC): no edit, no undo step.
    case unchanged
    /// The name to store, exactly as typed.
    case valid(String)
    case invalid(EntryNameProblem)
}

/// Finder's rules for a name inside an archive (Rename, New Folder), shared by Mac and iOS.
/// Names compare after NFC and case-sensitively: names that differ only in case are allowed.
enum EntryNameValidation {
    /// APFS limit; a longer name could not be extracted.
    static let maxUTF8Length = 255

    /// `current` = the item's own name (nil for a new item); `siblings` = visible sibling names, pending and
    /// source; `current` may be among them (it is skipped). A leading "." is allowed with no warning.
    static func check(_ proposed: String, current: String?, siblings: [String]) -> EntryNameCheck {
        let normalized = nfc(proposed)
        let normalizedCurrent = current.map(nfc)
        if normalized == normalizedCurrent { return .unchanged }
        if proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .invalid(.empty) }
        // Byte-level checks: a combining mark after "/" or "._" merges into one Character, but the bytes stay.
        let bytes = proposed.utf8
        if bytes.contains(UInt8(ascii: "/")) || bytes.contains(0) { return .invalid(.containsSlash) }
        // Exact bytes: "." plus a combining mark is a different, legal name.
        if bytes.elementsEqual(".".utf8) || bytes.elementsEqual("..".utf8) { return .invalid(.reserved) }
        // "__MACOSX" at any depth: nested __MACOSX/ folders are stripped and hidden.
        // ".DS_Store" (exact case, as `MacOSMetadata.isExcludedEntry`): saving without Mac metadata drops it.
        if bytes.starts(with: "._".utf8) || normalized == "__MACOSX" || normalized == ".DS_Store" {
            return .invalid(.hiddenMetadata)
        }
        // Stored as typed, so the typed bytes must fit; the NFC form too, as names compare in NFC.
        if max(bytes.count, normalized.utf8.count) > maxUTF8Length { return .invalid(.tooLong) }
        let taken = siblings.lazy.map(nfc).contains { $0 == normalized && $0 != normalizedCurrent }
        if taken { return .invalid(.taken(proposed)) }
        return .valid(proposed)
    }

    static func message(for problem: EntryNameProblem) -> String {
        switch problem {
        case .empty:
            String(localized: "Enter a name.", table: "Shared",
                   comment: "Error when renaming an item in the archive: the typed name is empty.")
        case .containsSlash:
            String(localized: "Names can't contain “/”.", table: "Shared",
                   comment: "Error when renaming an item in the archive: the typed name contains a slash.")
        case .reserved:
            String(localized: "The names “.” and “..” can't be used.", table: "Shared",
                   comment: "Error when renaming an item in the archive: “.” and “..” are reserved names.")
        case .hiddenMetadata:
            String(localized: "This name is reserved for Finder metadata.", table: "Shared",
                   comment: "Error when renaming an item in the archive: Finder uses the name for hidden metadata (__MACOSX, .DS_Store, names starting with “._”).")
        case .tooLong:
            String(localized: "The name is too long.", table: "Shared",
                   comment: "Error when renaming an item in the archive: the name is over 255 bytes in UTF-8.")
        case .taken(let name):
            String(localized: "The name “\(name)” is already taken. Please choose a different name.", table: "Shared",
                   comment: "Error when renaming an item in the archive: another item in the same folder has that name. %@ = the name as typed.")
        case .unavailable:
            String(localized: "This item can't be renamed.", table: "Shared",
                   comment: "Error when renaming an item in the archive: the item is gone, or the archive can't be edited.")
        case .holdsMovedOutItems(let name):
            MovePlanning.message(for: .holdsMovedOutItems(name))
        }
    }

    /// "untitled folder", then "untitled folder 2", "untitled folder 3"… (Finder): the first one no sibling has,
    /// ignoring case: case twins the user types are allowed, never one the app picks.
    static func untitledFolderName(siblings: [String]) -> String {
        untitledFolderName(siblings: siblings,
                           base: String(localized: "untitled folder", table: "Shared",
                                        comment: "Default name of a folder made with New Folder, stored in the archive: use Finder’s name for a new folder in your language (English is lowercase, like Finder’s). A second one gets “ 2” appended (“untitled folder 2”), then “ 3”…"))
    }

    /// `base` is the localized "untitled folder", maybe capitalized: names are compared by NameFold.key, the
    /// case-twin scan's fold (canonical equivalence, full case folding: final sigma, "ß" and "SS"), on the
    /// names as spelled; the name returned is NFC.
    static func untitledFolderName(siblings: [String], base: String) -> String {
        let taken = Set(siblings.map(NameFold.key))
        if !taken.contains(NameFold.key(base)) { return nfc(base) }
        var number = 2
        while taken.contains(NameFold.key("\(base) \(number)")) { number += 1 }
        return "\(nfc(base)) \(number)"
    }

    /// UTF-16 length to preselect when renaming: a file's name up to its last "." (a leading "." does not count);
    /// a folder's whole name.
    static func editableLength(of name: String, isDirectory: Bool) -> Int {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name.utf16.count }
        return name[..<dot].utf16.count
    }

    private static func nfc(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }
}
