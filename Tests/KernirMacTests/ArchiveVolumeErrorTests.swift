import Foundation
import KernirCore
import Testing
@testable import Kernir

/// What the locked view of a split archive offers (App/Shared/ArchiveError+Localized.swift).
struct ArchiveVolumeErrorTests {
    private func error(_ reason: ArchiveVolumeError.Reason, part: Int? = 3) -> ArchiveVolumeError {
        ArchiveVolumeError(reason: reason, part: part, fileName: "Photos.part3.rar", setName: "Photos.part1.rar",
                           folder: URL(fileURLWithPath: "/tmp/Photos"), openedPart: 1)
    }

    @Test func grantAccessIsOfferedWhenAccessMayBeTheCause() {
        #expect(error(.noAccess).offersGrantAccess)
        // A part that looks missing may only be unreadable.
        #expect(error(.missing).offersGrantAccess)
    }

    @Test func theLockedViewHasATitleAndAHint() {
        for reason in [ArchiveVolumeError.Reason.noAccess, .missing] {
            #expect(error(reason).errorDescription?.isEmpty == false)
            #expect(error(reason).recoverySuggestion?.isEmpty == false)
        }
    }

    /// Granting a folder other than the one holding the parts asks for the right one.
    @Test func onlyTheFolderOfThePartsCounts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveVolumeErrorTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sub"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let error = ArchiveVolumeError(reason: .noAccess, part: 2, fileName: "Photos.part2.rar",
                                       setName: "Photos.part1.rar", folder: folder, openedPart: 1)

        #expect(error.isFolderOfParts(folder))
        #expect(error.isFolderOfParts(URL(fileURLWithPath: folder.path + "/")))
        #expect(error.isFolderOfParts(folder.appendingPathComponent("Sub/..")))
        #expect(error.isFolderOfParts(link))
        #expect(!error.isFolderOfParts(folder.appendingPathComponent("Sub")))
        #expect(!error.isFolderOfParts(root))
        // Same folder, another spelling of the name: only a case-insensitive volume treats it as the same folder.
        let otherCase = root.appendingPathComponent("PHOTOS", isDirectory: true)
        let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        if !caseSensitive {
            #expect(error.isFolderOfParts(otherCase))
        }  // On a case-sensitive volume "PHOTOS" is a different (missing) folder, so the case is skipped.
        // A sibling that exists is another folder.
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        #expect(!error.isFolderOfParts(other))
        // A folder that doesn't exist takes the path fallback and differs.
        #expect(!error.isFolderOfParts(root.appendingPathComponent("Gone", isDirectory: true)))
    }

    /// Another folder than the parts': the alert states the new problem, not the locked view's
    /// headline, and names no file (part 1's name may be the missing one).
    @Test func theWrongFolderAlertNamesNoFile() {
        for reason in [ArchiveVolumeError.Reason.noAccess, .missing] {
            #expect(error(reason).wrongFolderTitle == "That folder doesn't contain this archive's other parts.")
            #expect(error(reason).wrongFolderMessage == "Choose the folder that holds all parts of this archive.")
            #expect(error(reason).wrongFolderTitle != error(reason).errorDescription)
        }
    }

    /// The right folder, but the reopen fails the same way: the alert says it still can't.
    @Test func theStillUnreadableAlertSaysWhatIsLeft() {
        #expect(error(.missing).stillUnreadableTitle == "Part 3 is still missing.")
        #expect(error(.missing, part: nil).stillUnreadableTitle == "The last part is still missing.")
        #expect(error(.noAccess).stillUnreadableTitle == "Lutik still can't read the other parts.")
        for reason in [ArchiveVolumeError.Reason.noAccess, .missing] {
            #expect(error(reason).stillUnreadableMessage
                == "Make sure every part is downloaded and in this folder, then try again.")
        }
    }

    /// A retry after the right folder was granted "still fails" only on the same part and file
    /// name; another part (or file) is a new error the locked view shows instead.
    @Test func theSameFailureIsTheSamePartAndFileName() {
        let missing = error(.missing)
        #expect(missing.isSameFailure(as: missing))
        // The reason may change (a hidden part turns out missing): still the same part.
        #expect(error(.noAccess).isSameFailure(as: missing))
        // The folder, set name and opened part don't count.
        let elsewhere = ArchiveVolumeError(reason: .missing, part: 3, fileName: "Photos.part3.rar",
                                           setName: "Other.part1.rar", folder: URL(fileURLWithPath: "/tmp/Other"),
                                           openedPart: 2)
        #expect(elsewhere.isSameFailure(as: missing))
        let nextPart = ArchiveVolumeError(reason: .missing, part: 4, fileName: "Photos.part4.rar",
                                          setName: "Photos.part1.rar", folder: URL(fileURLWithPath: "/tmp/Photos"),
                                          openedPart: 1)
        #expect(!nextPart.isSameFailure(as: missing))
        #expect(!missing.isSameFailure(as: nextPart))
        // Same part number, another file name (the set was renamed): another failure.
        let renamed = ArchiveVolumeError(reason: .missing, part: 3, fileName: "Pics.part3.rar",
                                         setName: "Pics.part1.rar", folder: URL(fileURLWithPath: "/tmp/Photos"),
                                         openedPart: 1)
        #expect(!renamed.isSameFailure(as: missing))
        // The unknown last part: same only with the same file name.
        #expect(error(.missing, part: nil).isSameFailure(as: error(.missing, part: nil)))
        #expect(!error(.missing, part: nil).isSameFailure(as: missing))
    }

    /// The backstop when a save would write over a part: a write error with words for the user.
    @Test func savingASetInPlaceExplainsItself() {
        let error = ArchiveVolumeError.saveInPlaceError
        #expect(error.code == .fileWriteUnknown)
        #expect(error.localizedDescription == "A split archive can't be saved in place. Use Save As Copy.")
    }
}
