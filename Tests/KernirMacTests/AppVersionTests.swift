import Foundation
import Testing
@testable import Kernir

/// About's version line (AppVersion): marketing version, build number and commit from Info.plist.
struct AppVersionTests {
    private let full: [String: Any] = [
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1234", "KernirGitCommit": "9cc7108",
    ]

    @Test func fullLine() {
        let version = AppVersion(infoDictionary: full)
        #expect(version.version == "0.1.0")
        #expect(version.buildDetail == "1234, 9cc7108")
        #expect(version.line == "Version 0.1.0 (1234, 9cc7108)")
    }

    /// A checkout xcodegen never ran in (App/Version.xcconfig defaults): build 1, commit dev.
    @Test func unstampedDefaults() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "KernirGitCommit": "dev",
        ])
        #expect(version.line == "Version 0.1.0 (1, dev)")
    }

    @Test(arguments: [
        (["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1234"], "Version 0.1.0 (1234)", "1234"),
        (["CFBundleShortVersionString": "0.1.0", "KernirGitCommit": "9cc7108"], "Version 0.1.0 (9cc7108)", "9cc7108"),
        (["CFBundleShortVersionString": "0.1.0"], "Version 0.1.0", nil),
        (["CFBundleVersion": "1234", "KernirGitCommit": "9cc7108"], "Build 1234, 9cc7108", "1234, 9cc7108"),
    ] as [([String: String], String, String?)])
    func missingKeys(info: [String: String], line: String, detail: String?) {
        let version = AppVersion(infoDictionary: info)
        #expect(version.line == line)
        #expect(version.buildDetail == detail)
    }

    @Test func nothingKnown() {
        let version = AppVersion(infoDictionary: [:])
        #expect(version.line == nil)
        #expect(version.buildDetail == nil)
    }

    /// Blank, non-string and unexpanded build-setting values ("$(KERNIR_GIT_COMMIT)") count as missing.
    @Test func ignoresJunkValues() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": " 0.1.0 ", "CFBundleVersion": 1234, "KernirGitCommit": "$(KERNIR_GIT_COMMIT)",
        ])
        #expect(version.line == "Version 0.1.0")
        #expect(AppVersion(infoDictionary: ["CFBundleShortVersionString": "  "]).line == nil)
    }

    @Test func website() {
        #expect(AppWebsite.url.absoluteString == "https://lutik.io")
        #expect(AppWebsite.label == "lutik.io")
    }
}
