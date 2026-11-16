import Testing
import Foundation
@testable import Kernir
import KernirCore

// App/Shared only (no AppKit): View > Text Encoding's titles, `ArchiveNameEncoding.title(of:systemName:)`.
// Also in KernirIOSTests (project.yml), so it runs on iOS too.

struct ArchiveNameEncodingTitleTests {
    /// The titles of `ArchiveNameEncoding.choices`, in order: macOS's `String.localizedName(of:)` for each,
    /// in English. TextEncodingMenuTests checks the Mac menu against them too.
    static let expectedTitles = [
        "Unicode (UTF-8)", "Cyrillic (Windows)", "Russian (DOS)", "Cyrillic (KOI8-R)", "Japanese (Windows, DOS)",
        "Chinese (GB 18030)", "Traditional Chinese (Big 5)", "Korean (Windows, DOS)", "Western (Windows Latin 1)",
        "Latin-US (DOS)", "Central European (Windows Latin 2)",
    ]

    /// As on iOS, where the system names every non-Unicode encoding "": each choice still has its own title,
    /// the English of the Mac menu.
    @Test func choicesHaveTitlesWithoutSystemNames() {
        let titles = ArchiveNameEncoding.choices.map { ArchiveNameEncoding.title(of: $0, systemName: { _ in "" }) }
        #expect(titles.allSatisfy { !$0.isEmpty }, "\(titles)")
        #expect(Set(titles).count == ArchiveNameEncoding.choices.count, "\(titles)")
        #expect(titles == Self.expectedTitles)
    }

    /// Every choice has a title of its own: none comes from the system name.
    @Test func noChoiceFallsBackToSystemName() {
        for encoding in ArchiveNameEncoding.choices {
            #expect(ArchiveNameEncoding.title(of: encoding, systemName: { _ in "FALLBACK" }) != "FALLBACK",
                    "\(encoding.rawValue)")
        }
    }

    /// An encoding that isn't a choice gets the system name, or a description when that is "" or blank.
    @Test func otherEncodingsFallBack() {
        let other = String.Encoding.isoLatin2
        #expect(!ArchiveNameEncoding.choices.contains(other))
        #expect(ArchiveNameEncoding.title(of: other, systemName: { _ in "System" }) == "System")
        #expect(!ArchiveNameEncoding.title(of: other, systemName: { _ in "" }).isEmpty)
        let blank = ArchiveNameEncoding.title(of: other, systemName: { _ in " \n" })
        #expect(!blank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(blank)")
    }

    /// The default path on this platform (`String.localizedName(of:)`, "" on iOS 26.x for all but Unicode):
    /// the choices get the same titles on both platforms, and a non-choice still gets a title that isn't "".
    /// This doesn't prove the Shared table is in the bundle: each key is its English value.
    @Test func titlesWithTheSystemNames() {
        #expect(ArchiveNameEncoding.choices.map { ArchiveNameEncoding.title(of: $0) } == Self.expectedTitles)
        #expect(!ArchiveNameEncoding.title(of: .isoLatin2).isEmpty)
    }

    #if os(macOS)
    /// The Mac menu reads as before: each title is the system name, byte for byte. Those names follow the
    /// app's language (the main bundle's localization), not the Mac's, and our titles are English only, so
    /// this runs only while the app is in English: always, while it ships English only.
    @Test(.enabled(if: Bundle.main.preferredLocalizations.first == "en",
                   "the system names are in the app's language, our titles in English"))
    func titlesMatchMacSystemNames() {
        for encoding in ArchiveNameEncoding.choices {
            #expect(ArchiveNameEncoding.title(of: encoding) == String.localizedName(of: encoding))
        }
        #expect(ArchiveNameEncoding.choices.map(String.localizedName(of:)) == Self.expectedTitles)
    }
    #endif
}
