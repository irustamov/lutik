import Testing
import Foundation
import KernirCore

/// `ArchiveEntry.parentPath(of:)`, `name(of:)` and `components(of:)` split on the "/" scalar, never on Characters:
/// "/" followed by a combining mark (U+0301) or a ZWJ, or preceded by a Prepend scalar (U+0600), is part of one
/// Character that is not "/", so a Character split hides the separator. Apps that place or group items by path use
/// these, so they agree with the core's own scalar split. Results are compared on scalars, since String `==` is
/// canonical equivalence.
struct ArchiveEntryPathHelperTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let path: String
        let parent: String
        let name: String
        let components: [String]
        let label: String
        var testDescription: String { label }
    }

    static let hidden = [
        Case(path: "a/\u{301}b", parent: "a", name: "\u{301}b", components: ["a", "\u{301}b"],
             label: "combining mark after /"),
        Case(path: "a/\u{301}b/c", parent: "a/\u{301}b", name: "c", components: ["a", "\u{301}b", "c"],
             label: "combining mark after the first /"),
        Case(path: "a/\u{200D}b", parent: "a", name: "\u{200D}b", components: ["a", "\u{200D}b"],
             label: "ZWJ after /"),
        Case(path: "a\u{600}/b", parent: "a\u{600}", name: "b", components: ["a\u{600}", "b"],
             label: "Prepend before /"),
        Case(path: "link/\u{301}", parent: "link", name: "\u{301}", components: ["link", "\u{301}"],
             label: "a lone mark as the name"),
    ]

    /// Not normalized (the precondition says the core never produces these): what comes back is still a scalar
    /// split with empty components omitted, as `String.split` does.
    static let unnormalized = [
        Case(path: "a//b", parent: "a/", name: "b", components: ["a", "b"], label: "empty component"),
        Case(path: "/a", parent: "", name: "a", components: ["a"], label: "leading /"),
        Case(path: "a/", parent: "a", name: "a", components: ["a"], label: "trailing /"),
        Case(path: "/", parent: "", name: "/", components: [], label: "only /"),
        Case(path: "", parent: "", name: "", components: [], label: "empty"),
    ]

    @Test(arguments: hidden + unnormalized)
    func splitsOnTheSlashScalar(_ c: Case) {
        #expect(scalars(ArchiveEntry.parentPath(of: c.path)) == scalars(c.parent))
        #expect(scalars(ArchiveEntry.name(of: c.path)) == scalars(c.name))
        #expect(ArchiveEntry.components(of: c.path).map(scalars) == c.components.map(scalars))
    }

    /// Ordinary paths give exactly what a Character split gives (the instance properties' old code and
    /// `String.split`), byte for byte: NFC and NFD names, marks and ZWJ inside a name, spaces, CJK, emoji, dots.
    static let ordinary = [
        "a", "a/b", "a/b/c.txt", "README.md", "src/main.swift", "dir/", ".hidden/x", "a/.b/._c",
        "caf\u{E9}/men\u{FC}.txt", "cafe\u{301}/menu\u{308}.txt", "e\u{301}", "x/e\u{301}",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}/family", "a b/c d.pdf", "\u{65E5}\u{672C}/\u{8A9E}.txt",
        "Report 2024 2.pdf", "deep/a/b/c/d/e/f", "\u{05D0}\u{05D1}/\u{0627}\u{0644}", "a\\b/c", "..x/y..",
        "\u{1F1FA}\u{1F1F8}/flag", "\u{D55C}\u{AE00}/\u{1100}\u{1161}\u{11A8}",
    ]

    @Test(arguments: ordinary)
    func ordinaryPathsMatchTheCharacterSplit(_ path: String) {
        let characterParent = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        let characterName = path.split(separator: "/").last.map(String.init) ?? path
        #expect(scalars(ArchiveEntry.parentPath(of: path)) == scalars(characterParent))
        #expect(scalars(ArchiveEntry.name(of: path)) == scalars(characterName))
        #expect(ArchiveEntry.components(of: path).map(scalars)
                == path.split(separator: "/").map { scalars(String($0)) })
    }

    private func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map(\.value)
    }
}
