import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// `previewListing` holds an archive to `NestingLimits.preview`, tighter than the app's `standard` limits: the Quick
/// Look extension that calls it is killed at about 1.3 GB, and a listing inside the standard limits peaked at up to
/// 8.2 GB. The preview limits are fixed totals (no per-entry growth), so its peak is bounded by them alone.
@Suite("Preview budget")
struct PreviewBudgetTests {
    @Test func previewLimitsAreFixedAndTighter() {
        let p = NestingLimits.preview, s = NestingLimits.standard
        #expect(p.maxEntries == 400_000)
        #expect(p.maxTotalNameBytes == 64 << 20)
        #expect(p.nameBytesPerEntry == 0)
        #expect(p.maxFolderBytes == 32 << 20)
        #expect(p.folderBytesPerPath == 0)
        #expect(p.maxAncestorWork == 1 << 30)
        #expect(p.ancestorWorkPerPath == 0)
        // Per path and per name, the preview reads what the app reads.
        #expect(p.maxComponents == s.maxComponents)
        #expect(p.maxPathBytes == s.maxPathBytes)
        #expect(p.maxRawNameBytes == s.maxRawNameBytes)
    }

    /// One header over the preview's entry limit: `Archive.previewListing` refuses it with `.entryCount` inside
    /// libarchive, before the 7z's entries are allocated, while the app's limits read the same header.
    @Test(.memoryHeavy) func previewRefusesOneEntryOverItsLimit() async throws {
        let over = try SevenZipNameLimitTests.write(Array(repeating: 1, count: NestingLimits.preview.maxEntries + 1),
                                                   encoded: false)
        defer { try? FileManager.default.removeItem(at: over.deletingLastPathComponent()) }
        await #expect(throws: ArchiveNestingError(limit: .entryCount)) {
            _ = try await Archive.previewListing(at: over, limit: 5_000)
        }
        #expect(EntryCountLimitTests.libarchiveError(over, .standard) == nil)
        #expect(EntryCountLimitTests.libarchiveError(over, .preview) != nil)
    }

    /// Folders: each path here implies one new 160-byte folder (288 bytes with `folderOverhead`). The standard limits
    /// allow 512 bytes per path once past 64 MiB, so they never refuse this; the preview's 32 MiB is fixed.
    @Test func previewFolderTotalIsFixed() throws {
        let pad = String(repeating: "d", count: 150)
        func path(_ i: Int) -> String { pad + String(format: "%010d", i) + "/f" }
        let perFolder = 160 + NestingLimits.folderOverhead
        let fits = NestingLimits.preview.maxFolderBytes / perFolder
        var preview = NestingBudget(.preview)
        var standard = NestingBudget(.standard)
        for i in 0..<fits {
            try preview.charge(path(i))
            try standard.charge(path(i))
        }
        #expect(throws: ArchiveNestingError(limit: .folderBytes)) { try preview.charge(path(fits)) }
        for i in fits..<(fits + 1_000) { try standard.charge(path(i)) }
    }
}
