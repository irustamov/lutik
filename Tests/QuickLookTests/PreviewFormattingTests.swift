import Foundation
import Testing
import KernirCore

private func listing(_ entries: [ArchiveEntry]) -> PreviewListing {
    PreviewLoader.listing(for: FakeArchive(entries: entries))
}

struct PreviewFormattingTests {
    @Test func unknownSizeShowsDash() {
        #expect(PreviewFormatting.size(nil) == "—")
    }

    @Test func sizeMatchesFinder() {
        #expect(PreviewFormatting.size(1_200_000)
                == ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file))
    }

    @Test func summaryForSample() {
        let s = PreviewFormatting.summary(PreviewLoader.listing(for: SampleArchive()))
        #expect(s.contains("ZIP archive · 7 items · "))
    }

    @Test func singularItem() {
        let e = ArchiveEntry(path: "a.txt", isDirectory: false, size: 10,
                             compressedSize: nil, modificationDate: nil)
        #expect(PreviewFormatting.summary(listing([e])) == "ZIP archive · 1 item · \(PreviewFormatting.size(10))")
    }

    @Test func summaryLeavesOutAnUnknownSize() {
        // Single-stream archives (.gz, .xz, ...) don't record their entry's size: say nothing, not "Zero KB".
        let e = ArchiveEntry(path: "notes.txt", isDirectory: false, size: nil,
                             compressedSize: nil, modificationDate: nil)
        let l = PreviewLoader.listing(for: FakeArchive(format: .gzip, entries: [e]))
        #expect(PreviewFormatting.summary(l) == "GZ archive · 1 item")
    }

    @Test func emptySummary() {
        #expect(PreviewFormatting.summary(listing([])) == "ZIP archive · 0 items")
    }

    @Test func moreItemsPlural() {
        // A standalone line, not an "and …" sentence fragment; "1 more item" needs the catalog's plural.
        #expect(PreviewFormatting.moreItems(1) == "1 more item")
        #expect(PreviewFormatting.moreItems(2) == "2 more items")
        let s = PreviewFormatting.moreItems(1000)
        #expect(!s.hasPrefix("and"))
        #expect(s.hasSuffix(" more items"))
    }

    @Test func stringsComeFromTheCatalogInThisBundle() {
        // In this test bundle Bundle.main is the xctest runner; the catalog is compiled into the bundle
        // that holds PreviewFormatting (here the test bundle, in the extensions the appex).
        #expect(PreviewFormatting.bundle != Bundle.main)
        #expect(PreviewFormatting.bundle.url(forResource: "Localizable", withExtension: "stringsdict",
                                             subdirectory: nil, localization: "en") != nil)
        #expect(PreviewFormatting.emptyArchiveTitle == "Empty archive")
        #expect(PreviewFormatting.passwordProtectedTitle == "Password-protected archive")
    }

    @Test func formatNameNil() {
        #expect(PreviewFormatting.formatName(nil) == "Archive")
        #expect(PreviewFormatting.formatName(.tarGzip) == "TAR.GZ archive")
    }

    @Test func tooLargeText() {
        #expect(PreviewFormatting.tooLargeTitle == "Archive too large to preview")
    }

    @Test func volumePartText() {
        #expect(PreviewFormatting.volumePartTitle(1) == "Part 1 of a split archive")
        #expect(PreviewFormatting.volumePartTitle(3) == "Part 3 of a split archive")
        #expect(PreviewFormatting.volumePartTitle(0) == "Last part of a split archive")
        #expect(PreviewFormatting.volumePartTitle(-1) == "Last part of a split archive")
        #expect(PreviewFormatting.openInKernirDescription == "Open in Lutik to see everything.")
    }
}
