import Foundation
import Testing
@testable import KernirCore

/// Zips over 4 GB that end with a zip64 locator whose total-number-of-disks field is 0 instead of 1. OneDrive and
/// SharePoint write every such download this way, with a 32-bit record whose central-directory offset is 0xFFFFFFFF.
/// Upstream libarchive ignored the locator, trusted 0xFFFFFFFF (it fits below the record in a file this big) and
/// failed with "Damaged Zip archive"; Kernir patch 0011 reads 0 as a single disk, as 7-Zip and Python's zipfile do.
/// Each test writes a sparse file of just over 4 GiB (a hole, no real disk space) and deletes it.
struct Zip64LocatorTests {
    static let t = SyntheticZip.dosTime(year: 2026, month: 2, day: 10, hour: 9, minute: 30, second: 0)
    static let files: [(path: String, dosTime: UInt32, data: [UInt8])] = [
        (path: "MR 10 Oct 2025/", dosTime: t, data: []),
        (path: "MR 10 Oct 2025/LMR10012025.pdf", dosTime: t, data: Array("%PDF-1.7 report".utf8)),
        (path: "T&D QUESTIONNAIRE 2025.docx", dosTime: t, data: Array("docx bytes".utf8)),
    ]

    @Test(arguments: [UInt32(0), 1])
    func opensAndExtracts(locatorTotalDisks: UInt32) async throws {
        let url = try SyntheticZip.writeOneDriveZip64(Self.files, locatorTotalDisks: locatorTotalDisks)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try await LibArchiveReader.open(at: url, password: nil)
        #expect(r.entries.map(\.path) == ["MR 10 Oct 2025", "MR 10 Oct 2025/LMR10012025.pdf", "T&D QUESTIONNAIRE 2025.docx"])
        let docx = try await r.extractToTemporaryFile("T&D QUESTIONNAIRE 2025.docx")
        #expect(try Data(contentsOf: docx) == Data("docx bytes".utf8))
    }

    @Test func previewListingReadsIt() async throws {
        let url = try SyntheticZip.writeOneDriveZip64(Self.files, locatorTotalDisks: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let l = try await Archive.previewListing(at: url, limit: 10)
        #expect(l.format == .zip && l.visibleEntryCount == 3 && l.visibleFileSize == 25)
    }

    /// More than one disk is a real split archive; the single-file reader still refuses it.
    @Test func locatorWithTwoDisksStaysRejected() async throws {
        let url = try SyntheticZip.writeOneDriveZip64(Self.files, locatorTotalDisks: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { _ = try await LibArchiveReader.open(at: url, password: nil) }
    }
}
