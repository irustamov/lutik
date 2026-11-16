import Foundation
import Testing
@testable import KernirCore

/// The iOS 17.4 simulator trapped with "No UTF-8 locale available": its libc opens no UTF-8 locale at all
/// (newlocale fails with EFTYPE for every name; only "C" opens). The lookup now walks a chain of names and, when
/// every one fails, runs without switching locale; patch 0023 keeps libarchive's current charset UTF-8, so
/// names stay right.
/// `UTF8Locale.$forceUnavailable` takes that path here; the process locale stays "C" (no setlocale anywhere).
@Suite("UTF-8 locale")
struct UTF8LocaleTests {
    // MARK: Lookup

    /// These two tests open the name "UTF-8" itself, which an OS without a UTF-8 locale (iOS 17) or a run with
    /// KERNIR_NO_UTF8_LOCALE=1 cannot do; they skip there.
    static let utf8NameOpens: Bool = UTF8Locale.shared != nil && UTF8Locale.firstAvailable(["UTF-8"]).map { freelocale($0.locale); return true } ?? false

    @Test(.enabled(if: UTF8LocaleTests.utf8NameOpens)) func laterValidCandidateIsChosenAfterBogusOnes() throws {
        let found = try #require(UTF8Locale.firstAvailable(["kernir-bogus", "xx_XX.UTF-8", "C", "UTF-8"]))
        defer { freelocale(found.locale) }
        #expect(found.name == "UTF-8")
        #expect(UTF8Locale.isUTF8(found.locale))
    }

    @Test(.enabled(if: UTF8LocaleTests.utf8NameOpens)) func injectedOpenIsAskedInOrder() {
        var asked: [String] = []
        let found = UTF8Locale.firstAvailable(["a", "b", "UTF-8"]) { name in
            asked.append(name)
            return name == "b" ? nil : newlocale(LC_CTYPE_MASK, name == "a" ? "C" : name, nil)
        }
        defer { found.map { freelocale($0.locale) } }
        #expect(asked == ["a", "b", "UTF-8"])
        #expect(found?.name == "UTF-8")
    }

    @Test func allBogusCandidatesGiveNoLocale() {
        #expect(UTF8Locale.firstAvailable(["kernir-bogus", "zz_ZZ.UTF-8", "C"]) == nil)
        #expect(UTF8Locale.firstAvailable([]) == nil)
        #expect(UTF8Locale.firstAvailable(UTF8Locale.candidateNames) { _ in nil } == nil)
    }

    // The `forceUnavailable` hook exists only in DEBUG builds of KernirCore, so the tests below do too.
    #if DEBUG
    @Test func withoutLocaleTheBodyStillRuns() {
        let ran = UTF8Locale.$forceUnavailable.withValue(true) {
            #expect(!UTF8Locale.isAvailable)
            return withUTF8CType { 42 }
        }
        #expect(ran == 42)
    }

    // MARK: Names without a UTF-8 locale

    static func noLocale<T>(_ body: () async throws -> T) async rethrows -> T {
        try await UTF8Locale.$forceUnavailable.withValue(true) { try await body() }
    }

    static func hasNonASCII(_ paths: [String]) -> Bool {
        paths.contains { $0.unicodeScalars.contains { !$0.isASCII } }
    }

    /// Every readable fixture (and synthetic Unicode zip and RAR4 names) lists the same entries without a UTF-8
    /// locale as with one.
    @Test func listingWithoutUTF8LocaleMatches() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let flagged = SyntheticZip.write(SyntheticZip.stored(["Привет.txt", "中文/日本語.txt"].map {
            (nameBytes: Array($0.utf8), utf8Flag: true, dosTime: t, data: [UInt8]("x".utf8))
        }))
        let rar4 = SyntheticRAR4.write([(name: Array("Privet.txt".utf8), unicode: "Привет.txt", data: [1])])
        let dirs = ["zip", "7z", "tar", "xar", "cpio", "iso", "cab", "third-party/cab", "third-party/rar",
                    "third-party/lha"]
        var urls = [flagged, rar4]
        for dir in dirs {
            let base = ReaderListingTests.fixture(dir)
            let names = try FileManager.default.contentsOfDirectory(atPath: base.path).sorted()
            urls += names.map { base.appendingPathComponent($0) }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
        var compared = 0
        var nonASCII: Set<String> = []
        for url in urls {
            guard let normal = try? await Archive.open(at: url).entries else { continue }
            let degraded = try await Self.noLocale { try await Archive.open(at: url).entries }
            #expect(degraded == normal, "\(url.lastPathComponent)")
            compared += 1
            if Self.hasNonASCII(normal.map(\.path)) { nonASCII.insert(url.lastPathComponent) }
        }
        #expect(compared > 50)
        let expected = [flagged.lastPathComponent, rar4.lastPathComponent, "unicode.7z", "unicode.tar",
                        "unicode-utf8-flag.zip", "unicode-no-flag.zip", "cp437.zip", "cp866.zip",
                        "legacy-cp932.tar", "cp932-names.lzh", "cp932-names.cab"]
        for name in expected { #expect(nonASCII.contains(name), "\(name) lists non-ASCII names") }
    }

    static let names = ["Привет.txt", "中文/日本語.txt", "ünï/ç.txt"]

    static func sources() -> (dir: URL, changes: ArchiveChangeSet) {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(Dictionary(uniqueKeysWithValues: names.map { ("in/" + $0, Data("x".utf8)) }), in: dir)
        let changes = ArchiveChangeSet(additions: ["Привет.txt", "中文", "ünï"].map {
            .init(sourceURL: dir.appendingPathComponent("in/" + $0), destinationDirectory: "")
        })
        return (dir, changes)
    }

    static func ext(_ format: ArchiveFormat) -> String {
        switch format {
        case .zip: "zip"
        case .sevenZip: "7z"
        default: "tar"
        }
    }

    /// Added files, a plain save (repack copy) and a conversion keep non-ASCII names without a UTF-8 locale.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tar])
    func writingWithoutUTF8LocaleKeepsNames(format: ArchiveFormat) async throws {
        let (dir, changes) = Self.sources()
        let written = dir.appendingPathComponent("w." + Self.ext(format))
        try await Self.noLocale {
            try await ArchiveWriter.write(source: nil, changes: changes, format: format, to: written, options: nil)
        }
        let expected = Set(Self.names + ["中文", "ünï"])
        #expect(Set(try await Archive.open(at: written).entries.map(\.path)) == expected)
        if format == .zip {
            let central = SyntheticZip.centralNames(Array(try Data(contentsOf: written)))
            #expect(Set(central.map { String(decoding: $0.nameBytes, as: UTF8.self) }).isSuperset(of: Self.names))
            #expect(central.allSatisfy { $0.flags & 0x0800 != 0 || $0.nameBytes.allSatisfy { $0 < 0x80 } })
        }

        for target in [format, format == .zip ? ArchiveFormat.sevenZip : .zip] {
            let saved = dir.appendingPathComponent("s-\(Self.ext(format)).\(Self.ext(target))")
            try await Self.noLocale {
                let source = try await Archive.open(at: written)
                try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["Привет.txt"]),
                                              format: target, to: saved, options: nil)
            }
            #expect(Set(try await Archive.open(at: saved).entries.map(\.path)) == expected.subtracting(["Привет.txt"]),
                    "\(format) -> \(target)")
        }
    }

    /// Extraction writes the same file names without a UTF-8 locale.
    @Test func extractionWithoutUTF8LocaleKeepsNames() async throws {
        let fixtures = ["7z/unicode.7z", "zip/cp866.zip", "zip/unicode-utf8-flag.zip", "tar/unicode.tar",
                        "tar/legacy-cp932.tar"]
        for rel in fixtures {
            let url = ReaderListingTests.fixture(rel)
            let normalDir = Fixtures.tempDir()
            try await Archive.open(at: url).extract(nil, to: normalDir, progress: nil)
            let degradedDir = Fixtures.tempDir()
            try await Self.noLocale {
                try await Archive.open(at: url).extract(nil, to: degradedDir, progress: nil)
            }
            let normal = try FileManager.default.subpathsOfDirectory(atPath: normalDir.path).sorted()
            let degraded = try FileManager.default.subpathsOfDirectory(atPath: degradedDir.path).sorted()
            #expect(Self.hasNonASCII(normal), "\(rel)")
            #expect(degraded == normal, "\(rel)")
        }
    }
    #endif
}
