import Foundation
import Testing
@testable import Kernir

/// The third-party notices ship in the app bundle (BSD requires libarchive's and zstd's license
/// texts to ship with the app) and render without their markdown marks.
@Suite struct AcknowledgementsTests {
    @Test func bundleShipsTheNotices() throws {
        let url = try #require(Acknowledgements.url, "THIRD_PARTY_NOTICES.md is not in the app bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("## libarchive"))
        #expect(text.contains("## zstd"))
        #expect(text.contains("Redistribution and use in source and binary forms"))
    }

    @Test func bundledNoticesRenderWithoutMarkdownMarks() {
        let rendered = String(Acknowledgements.load().characters)
        #expect(rendered.contains("libarchive"))
        #expect(rendered.contains("Redistribution and use in source and binary forms"))
        #expect(!rendered.contains("```"))
        #expect(!rendered.contains("## "))
    }

    @Test func licenseBlocksKeepTheirLineBreaks() {
        let rendered = String(Acknowledgements.render("## Lib\n\nProse\n```\nline one\nline two\n```\nMore\n").characters)
        #expect(rendered == "Lib\n\nProse\nline one\nline two\nMore\n")
    }

    @Test func relativeLinksAreDroppedWebLinksKept() {
        let rendered = Acknowledgements.render("See [LICENSE](LICENSE) and [site](https://www.libarchive.org).\n")
        #expect(String(rendered.characters) == "See LICENSE and site.\n")
        let links = rendered.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://www.libarchive.org")!])
    }
}
