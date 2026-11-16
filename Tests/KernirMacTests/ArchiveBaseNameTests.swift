import Testing
import Foundation
@testable import Kernir
import KernirCore

// MARK: - One archive

@Test(arguments: [
    ("x.tar.gz", "x"),
    ("X.TAR.XZ", "X"),
    ("x.tgz", "x"),
    ("x.tar.bz", "x"),
    ("report.v2.zip", "report.v2"),
    ("v1.2.7z", "v1.2"),
    ("notes.txt.gz", "notes.txt"),
    ("notes.txt", "notes.txt"),
    ("README", "README"),
    // One suffix only, a compound one counting as one.
    ("x.tar.gz.gz", "x.tar.gz"),
    ("s2-plain.tar.tgz", "s2-plain.tar"),
    ("app.jar", "app"),
    ("requests-2.31.0-py3-none-any.whl", "requests-2.31.0-py3-none-any"),
    // Nothing before the dot: not a suffix.
    (".zip", ".zip"),
    // The longest suffix with something before it.
    ("tar.gz", "tar"),
    (".tar.gz", ".tar"),
])
func baseNameDropsOneArchiveSuffix(_ name: String, _ expected: String) {
    #expect(ArchiveBaseName.of(name, isVolumeSet: false) == expected)
}

/// A base that is "", "." or ".." would be the archive's folder or the one above it: the archive's own
/// file name is used instead. Any other dots are kept.
@Test(arguments: [
    ("..zip", "..zip"),
    ("...zip", "...zip"),
    ("...tar.gz", "...tar.gz"),
    ("a..zip", "a."),
    ("....zip", "..."),
])
func baseNameOfOneArchiveIsNeverADotName(_ name: String, _ expected: String) {
    #expect(ArchiveBaseName.of(name, isVolumeSet: false) == expected)
}

@Test(arguments: [
    ("x.TAR.GZ", "x"),
    ("x.Tar.Bz2", "x"),
    ("x.TGZ", "x"),
    ("Photos.ZIP", "Photos"),
    ("app.JAR", "app"),
    ("x.tar.Z", "x"),
])
func baseNameIgnoresCase(_ name: String, _ expected: String) {
    #expect(ArchiveBaseName.of(name, isVolumeSet: false) == expected)
}

@Test(arguments: ArchiveFormat.allCases)
func baseNameKnowsEveryFormatsExtension(_ format: ArchiveFormat) {
    #expect(ArchiveBaseName.of("x." + format.fileExtension, isVolumeSet: false) == "x")
}

@Test(arguments: ["tgz", "taz", "tbz2", "tbz", "tb2", "txz", "tzst", "lzh", "jar", "whl", "war", "ear", "apk",
                  "aab", "xpi", "nupkg", "vsix", "gtar", "gzip", "bz", "pax", "tar.bz", "tar.lz4"])
func baseNameKnowsTheOtherExtensionsKernirOpens(_ suffix: String) {
    #expect(ArchiveBaseName.of("x." + suffix, isVolumeSet: false) == "x")
}

@Test func baseNameOfOneArchiveKeepsAPartSuffix() {
    // A set is told by its volumes, never by its name.
    #expect(ArchiveBaseName.of("Photos.zip.001", isVolumeSet: false) == "Photos.zip.001")
    #expect(ArchiveBaseName.of("Photos.part1.rar", isVolumeSet: false) == "Photos.part1")
}

// MARK: - Volume set

@Test(arguments: [
    ("Photos.part1.rar", "Photos"),
    ("Photos.part01.rar", "Photos"),
    ("Photos.PART12.RAR", "Photos"),
    ("Photos.r00", "Photos"),
    ("Photos.R00", "Photos"),
    ("Photos.zip.001", "Photos"),
    ("Photos.7z.001", "Photos"),
    ("Photos.TAR.GZ.001", "Photos"),
    ("span.z01", "span"),
    ("span.Z01", "span"),
    ("v1.2 notes.7z.003", "v1.2 notes"),
    (".hidden.part1.rar", ".hidden"),
    // One suffix after the part: "tar" stays.
    ("s2-plain.tar.tgz.001", "s2-plain.tar"),
    // Nothing before the part suffix: not a part suffix.
    (".001", ".001"),
    // Dots are kept when the set's name is more than a dot name.
    ("a..zip.001", "a."),
    ("....part1.rar", "..."),
])
func baseNameOfAVolumeSetDropsThePartThenOneSuffix(_ name: String, _ expected: String) {
    #expect(ArchiveBaseName.of(name, isVolumeSet: true) == expected)
}

/// Part numbers are ASCII digits only.
@Test(arguments: [
    ("Photos.zip.\u{0661}\u{0662}\u{0663}", "Photos.zip.\u{0661}\u{0662}\u{0663}"),
    ("Photos.r\u{0660}\u{0660}", "Photos.r\u{0660}\u{0660}"),
    ("Photos.part\u{0661}.rar", "Photos.part\u{0661}"),
    ("Photos.7z.001", "Photos"),
])
func baseNameOfAVolumeSetTakesOnlyASCIIPartDigits(_ name: String, _ expected: String) {
    #expect(ArchiveBaseName.of(name, isVolumeSet: true) == expected)
}

@Test(arguments: [
    // The last part of a split zip has no part suffix.
    ("span.zip", "span"),
    ("Photos.tar.gz", "Photos"),
    ("notes.txt", "notes.txt"),
    ("README", "README"),
])
func baseNameOfAVolumeSetWithoutAPartSuffixDropsOneSuffix(_ name: String, _ expected: String) {
    #expect(ArchiveBaseName.of(name, isVolumeSet: true) == expected)
}

@Test(arguments: ["...part1.rar", "..part1.rar", "..001", "...7z.001", "...zip.001", "..z01"])
func baseNameOfAVolumeSetIsNeverADotName(_ name: String) {
    #expect(ArchiveBaseName.of(name, isVolumeSet: true) == name)
}
