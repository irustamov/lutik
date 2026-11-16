import Testing
import UniformTypeIdentifiers
@testable import Kernir

/// Which files the Quick Look panel shows through a stand-in, and how stand-ins are named.
struct PreviewStrategyTests {
    // MARK: - Strategy by file name

    @Test("CSV, TSV, HTML and XHTML show as source text", arguments: [
        "Budget.csv", "Table.tsv", "Page.html", "Page.htm", "Page.xhtml", "UPPER.CSV",
    ])
    func textTypes(name: String) {
        #expect(PreviewStrategy(fileName: name) == .textCopy)
    }

    @Test("Office and iWork documents show as a rendered page, the icon when that fails", arguments: [
        "Report.docx", "Report.doc", "Macro.docm", "Template.dotx",
        "Sheet.xlsx", "Sheet.xls", "Macro.xlsm",
        "Deck.pptx", "Deck.ppt", "Show.ppsx", "Macro.pptm",
        "Letter.pages", "Budget.numbers", "Talk.key",
        "Saved.webarchive",
    ])
    func renderedTypes(name: String) {
        #expect(PreviewStrategy(fileName: name) == .thumbnail(fallback: .icon))
    }

    @Test("SVG shows as a rendered image, its source text when that fails")
    func svg() {
        #expect(PreviewStrategy(fileName: "Logo.svg") == .thumbnail(fallback: .textCopy))
    }

    @Test("Types Quick Look renders natively show as they are", arguments: [
        "Notes.txt", "Readme.md", "Paper.pdf", "Pixel.png", "Photo.jpg", "Letter.rtf",
        "Data.json", "Feed.xml", "Doc.odt", "Clip.mov", "Archive.zip", "Makefile", "noextension.",
    ])
    func originalTypes(name: String) {
        #expect(PreviewStrategy(fileName: name) == .original)
    }

    @Test("Listed types match by identifier too")
    func byType() {
        #expect(PreviewStrategy(for: .html) == .textCopy)
        #expect(PreviewStrategy(for: UTType("public.xhtml")) == .textCopy)
        #expect(PreviewStrategy(for: UTType("org.openxmlformats.presentationml.presentation")) == .thumbnail(fallback: .icon))
        #expect(PreviewStrategy(for: .pdf) == .original)
    }

    @Test("Kin of a listed type match through conformance, not only by exact identifier")
    func kinByConformance() throws {
        // Dynamic types (dyn.…) declared here: each conforms to a listed type but isn't listed.
        let htmlKin = try #require(UTType(tag: "kernir-html-kin", tagClass: .filenameExtension, conformingTo: .html))
        let wordKin = try #require(UTType(tag: "kernir-docx-kin", tagClass: .filenameExtension,
                                          conformingTo: UTType("org.openxmlformats.wordprocessingml.document")))
        let svgKin = try #require(UTType(tag: "kernir-svg-kin", tagClass: .filenameExtension, conformingTo: .svg))
        let all = PreviewStrategy.textTypes + PreviewStrategy.renderedTypes
        for kin in [htmlKin, wordKin, svgKin] {
            #expect(!all.contains(kin.identifier), "\(kin.identifier) is listed itself")
        }
        #expect(PreviewStrategy(for: htmlKin) == .textCopy)
        #expect(PreviewStrategy(for: wordKin) == .thumbnail(fallback: .icon))
        #expect(PreviewStrategy(for: svgKin) == .thumbnail(fallback: .textCopy))
        // No fileName check here: UTType(filenameExtension:) makes a dyn type conforming to
        // public.data only, a different identifier from htmlKin, so it can't see the conformance.
    }

    @Test("An unknown type shows as it is")
    func unknownType() {
        #expect(PreviewStrategy(for: nil) == .original)
        #expect(PreviewStrategy(for: UTType(filenameExtension: "kernir-unknown-ext")) == .original)
    }

    // MARK: - Strategy by extracted item

    @Test("Only a regular file gets a stand-in: a folder or link named like a listed type shows as it is")
    func regularFilesOnly() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernirTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("Budget.csv")
        try Data("a,b\n".utf8).write(to: file)
        #expect(PreviewStrategy(fileAt: file) == .textCopy)
        let document = folder.appendingPathComponent("Report.docx")
        try Data().write(to: document)
        #expect(PreviewStrategy(fileAt: document) == .thumbnail(fallback: .icon))

        for name in ["Table.csv", "Site.html", "Report.docx"] {
            let directory = folder.appendingPathComponent("Folders/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(PreviewStrategy(fileAt: directory) == .original, "folder \(name)")
        }
        let link = folder.appendingPathComponent("Link.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(PreviewStrategy(fileAt: link) == .original)
        #expect(PreviewStrategy(fileAt: folder.appendingPathComponent("Missing.csv")) == .original)
    }

    @Test("Every listed identifier is a well-formed reverse-DNS name, listed once")
    func lists() {
        let all = PreviewStrategy.textTypes + PreviewStrategy.renderedTypes
        #expect(Set(all).count == all.count)
        #expect(Set(PreviewStrategy.textTypes).isDisjoint(with: PreviewStrategy.renderedTypes))
        for identifier in all {
            #expect(identifier.split(separator: ".").count >= 2, "\(identifier)")
        }
    }

    // MARK: - Stand-in names

    @Test("A stand-in keeps the entry's name and adds its own extension")
    func standInName() {
        #expect(PreviewStrategy.standInName(for: "Budget.csv", pathExtension: "txt") == "Budget.csv.txt")
        #expect(PreviewStrategy.standInName(for: "Report.docx", pathExtension: "png") == "Report.docx.png")
        #expect(PreviewStrategy.standInName(for: ".hidden.html", pathExtension: "txt") == ".hidden.html.txt")
        #expect(PreviewStrategy.standInName(for: "Отчёт 2026.xlsx", pathExtension: "png") == "Отчёт 2026.xlsx.png")
    }

    @Test("An empty name becomes Preview")
    func emptyName() {
        #expect(PreviewStrategy.standInName(for: "", pathExtension: "txt") == "Preview.txt")
    }

    @Test("A long name is shortened to fit 255 UTF-8 bytes, never splitting a character")
    func longName() {
        let ascii = String(repeating: "a", count: 300) + ".csv"
        let shortened = PreviewStrategy.standInName(for: ascii, pathExtension: "txt")
        #expect(shortened.utf8.count == PreviewStrategy.maxFileNameBytes)
        #expect(shortened.hasSuffix("aaa.txt"))

        // Two-byte letters: at most 251 bytes of base, so 125 whole letters.
        let cyrillic = String(repeating: "ж", count: 200) + ".csv"
        let short = PreviewStrategy.standInName(for: cyrillic, pathExtension: "txt")
        #expect(short.utf8.count <= PreviewStrategy.maxFileNameBytes)
        #expect(short == String(repeating: "ж", count: 125) + ".txt")

        // A name that fits exactly is left alone.
        let exact = String(repeating: "b", count: 251)
        #expect(PreviewStrategy.standInName(for: exact, pathExtension: "txt") == exact + ".txt")

        // Emoji are single characters of several bytes; none is cut in half.
        let emoji = String(repeating: "👨‍👩‍👧", count: 20) + ".csv"
        let cut = PreviewStrategy.standInName(for: emoji, pathExtension: "txt")
        #expect(cut.utf8.count <= PreviewStrategy.maxFileNameBytes)
        #expect(cut.dropLast(4).allSatisfy { $0 == "👨‍👩‍👧" })
    }
}
