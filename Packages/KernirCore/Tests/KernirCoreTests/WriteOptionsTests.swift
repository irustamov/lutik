import Foundation
import Testing
@testable import KernirCore

private struct Row {
    let format: ArchiveFormat
    let methods: [ArchiveCompressionMethod]
    let defaultMethod: ArchiveCompressionMethod?
    let range: ClosedRange<Int>?
    let level: Int?
    let encryptions: [ArchiveEncryption]
}

private let table: [Row] = [
    Row(format: .zip, methods: [.deflate, .store], defaultMethod: .deflate, range: 0...9, level: 6,
        encryptions: [.none, .aes256, .aes128, .zipCrypto]),
    Row(format: .sevenZip, methods: [.lzma2, .lzma, .bzip2, .deflate, .ppmd, .store], defaultMethod: .lzma2,
        range: 0...9, level: 6, encryptions: [.none, .aes256]),
    Row(format: .tar, methods: [], defaultMethod: nil, range: nil, level: nil, encryptions: [.none]),
    Row(format: .tarGzip, methods: [], defaultMethod: nil, range: 1...9, level: 6, encryptions: [.none]),
    Row(format: .tarBzip2, methods: [], defaultMethod: nil, range: 1...9, level: 9, encryptions: [.none]),
    Row(format: .tarXz, methods: [], defaultMethod: nil, range: 0...9, level: 6, encryptions: [.none]),
]

@Test(arguments: table) private func capabilityRow(_ row: Row) {
    #expect(row.format.supportedMethods == row.methods)
    #expect(row.format.defaultMethod == row.defaultMethod)
    #expect(row.format.compressionLevelRange == row.range)
    #expect(row.format.defaultCompressionLevel == row.level)
    #expect(row.format.supportedEncryptions == row.encryptions)
    #expect(row.format.supportsSolid == false)
}

@Test func readOnlyFormatsHaveNoControls() {
    for f in ArchiveFormat.allCases where !f.isWritable {
        #expect(f.supportedMethods == [])
        #expect(f.defaultMethod == nil)
        #expect(f.compressionLevelRange == nil)
        #expect(f.defaultCompressionLevel == nil)
        #expect(f.supportedEncryptions == [])
        #expect(f.supportsSolid == false)
    }
}

@Test func displayNamesAndWeakness() {
    #expect(ArchiveCompressionMethod.allCases.map(\.displayName) == ["Store", "Deflate", "BZip2", "LZMA", "LZMA2", "PPMd"])
    #expect(ArchiveEncryption.allCases.map(\.displayName) == ["None", "ZipCrypto", "AES-128", "AES-256"])
    #expect(ArchiveEncryption.allCases.filter(\.isWeak) == [.zipCrypto])
}

@Test func keepSourceAes256Zip() throws {
    let r = try ResolvedWriteOptions.resolve(nil, format: .zip, sourceEncryption: .aes256,
                                             sourceMethod: nil, sourcePassword: "pw")
    #expect(r.encryption == .aes256)
    #expect(r.password == "pw")
    #expect(r.method == .deflate)
    #expect(r.compressionLevel == 6)
}

@Test func keepSourceZipCryptoStore() throws {
    let r = try ResolvedWriteOptions.resolve(nil, format: .zip, sourceEncryption: .zipCrypto,
                                             sourceMethod: .store, sourcePassword: "pw")
    #expect(r.encryption == .zipCrypto)
    #expect(r.method == .store)
}

/// 7z writes AES-256, so a ZipCrypto source converted to 7z is upgraded rather than dropped.
@Test func zipCryptoSourceToSevenZipUpgradesToAES256() throws {
    let r = try ResolvedWriteOptions.resolve(nil, format: .sevenZip, sourceEncryption: .zipCrypto,
                                             sourceMethod: .store, sourcePassword: "pw")
    #expect(r.encryption == .aes256 && r.password == "pw")
    #expect(r.method == .store)
}

/// `encryption(carrying:)` is the nil-options rule an app reuses for explicit plain-save options:
/// kept when carried, AES-256 when offered, else nil.
@Test func encryptionCarryingKeepsUpgradesOrHasNone() {
    for enc in [ArchiveEncryption.none, .aes256, .aes128, .zipCrypto] {
        #expect(ArchiveFormat.zip.encryption(carrying: enc) == enc)
    }
    #expect(ArchiveFormat.sevenZip.encryption(carrying: .none) == ArchiveEncryption.none)
    for enc in [ArchiveEncryption.aes256, .aes128, .zipCrypto] {
        #expect(ArchiveFormat.sevenZip.encryption(carrying: enc) == .aes256)
        #expect(ArchiveFormat.tar.encryption(carrying: enc) == nil)
        #expect(ArchiveFormat.tarGzip.encryption(carrying: enc) == nil)
    }
    #expect(ArchiveFormat.tar.encryption(carrying: .none) == ArchiveEncryption.none)
    #expect(ArchiveFormat.rar.encryption(carrying: .none) == nil)
}

/// Nil options never drop encryption on a same-format save; they keep it, or refuse when the format
/// cannot carry it. 7z carries .aes256, so an encrypted 7z keeps AES-256.
@Test func sameFormatSaveKeepsOrRefusesToDropEncryption() throws {
    let kept = try ResolvedWriteOptions.resolve(nil, format: .sevenZip, sourceFormat: .sevenZip,
                                                sourceEncryption: .aes256, sourceMethod: .lzma2, sourcePassword: "pw")
    #expect(kept.encryption == .aes256 && kept.password == "pw" && kept.method == .lzma2)
    // The guard itself stays (no real format reaches it now): a same-format source encryption the format
    // cannot carry refuses instead of upgrading or dropping. A 7z never reports ZipCrypto; this pins the branch.
    #expect(throws: ArchiveError.unsupportedEncryption(.sevenZip)) {
        try ResolvedWriteOptions.resolve(nil, format: .sevenZip, sourceFormat: .sevenZip,
                                         sourceEncryption: .zipCrypto, sourceMethod: .lzma2, sourcePassword: "pw")
    }
    // Same format that can carry the encryption: unchanged.
    for enc in [ArchiveEncryption.aes256, .aes128, .zipCrypto] {
        let z = try ResolvedWriteOptions.resolve(nil, format: .zip, sourceFormat: .zip,
                                                 sourceEncryption: enc, sourceMethod: .deflate, sourcePassword: "pw")
        #expect(z.encryption == enc && z.password == "pw")
    }
    // Unencrypted same-format source: unchanged.
    let s = try ResolvedWriteOptions.resolve(nil, format: .sevenZip, sourceFormat: .sevenZip,
                                             sourceEncryption: .none, sourceMethod: .lzma2, sourcePassword: nil)
    #expect(s.encryption == .none && s.method == .lzma2)
    // Cross-format: upgrades to AES-256 (zip ZipCrypto -> 7z) or keeps (7z -> zip).
    let x = try ResolvedWriteOptions.resolve(nil, format: .sevenZip, sourceFormat: .zip,
                                             sourceEncryption: .zipCrypto, sourceMethod: .store, sourcePassword: "pw")
    #expect(x.encryption == .aes256 && x.password == "pw")
    let y = try ResolvedWriteOptions.resolve(nil, format: .zip, sourceFormat: .sevenZip,
                                             sourceEncryption: .aes256, sourceMethod: .lzma2, sourcePassword: "pw")
    #expect(y.encryption == .aes256 && y.password == "pw")
    // Explicit options are unchanged: .none on a same-format save is the caller's choice.
    let e = try ResolvedWriteOptions.resolve(.init(encryption: .none), format: .sevenZip, sourceFormat: .sevenZip,
                                             sourceEncryption: .aes256, sourceMethod: .lzma2, sourcePassword: "pw")
    #expect(e.encryption == .none)
}

@Test func keepSourceEncryptedWithoutPasswordThrows() {
    #expect(throws: ArchiveError.passwordRequired) {
        try ResolvedWriteOptions.resolve(nil, format: .zip, sourceEncryption: .aes256,
                                         sourceMethod: nil, sourcePassword: nil)
    }
}

@Test func aesWithoutPasswordThrows() {
    #expect(throws: ArchiveError.passwordRequired) {
        try ResolvedWriteOptions.resolve(.init(encryption: .aes128), format: .zip, sourceEncryption: .none,
                                         sourceMethod: nil, sourcePassword: nil)
    }
    #expect(throws: ArchiveError.passwordRequired) {
        try ResolvedWriteOptions.resolve(.init(encryption: .aes128, password: ""), format: .zip,
                                         sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
    }
}

@Test func unsupportedEncryptionThrows() {
    #expect(throws: ArchiveError.unsupportedEncryption(.tarGzip)) {
        try ResolvedWriteOptions.resolve(.init(encryption: .zipCrypto, password: "x"), format: .tarGzip,
                                         sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
    }
}

@Test func levelClampsAndMethodFallsBack() throws {
    let r = try ResolvedWriteOptions.resolve(.init(method: .ppmd, compressionLevel: 42), format: .zip,
                                             sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
    #expect(r.compressionLevel == 9)
    #expect(r.method == .deflate)
    let t = try ResolvedWriteOptions.resolve(.init(method: .store, compressionLevel: 3), format: .tar,
                                             sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
    #expect(t.compressionLevel == nil)
    #expect(t.method == nil)
}

@Test func readOnlyFormatThrows() {
    #expect(throws: ArchiveError.readOnlyFormat(.rar)) {
        try ResolvedWriteOptions.resolve(nil, format: .rar, sourceEncryption: .none,
                                         sourceMethod: nil, sourcePassword: nil)
    }
}

@Test func sampleArchiveDefaults() {
    #expect(SampleArchive().encryption == .none)
    #expect(SampleArchive().compressionMethod == nil)
}

@Test func writeWithoutOptionsIsUnambiguous() async {
    let dir = Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("w.zip")
    await #expect(throws: Never.self) {
        try await ArchiveWriter.write(source: nil, changes: .init(), format: .zip, to: url)
    }
    await #expect(throws: ArchiveError.passwordRequired) {
        try await ArchiveWriter.write(source: nil, changes: .init(), format: .zip, to: url,
                                      options: .init(encryption: .aes256))
    }
}

private struct FakeReader: ArchiveReading {
    let url = URL(fileURLWithPath: "/tmp/x.zip")
    let format: ArchiveFormat = .zip
    let entries: [ArchiveEntry] = []
    let isEncrypted = true
    let encryption: ArchiveEncryption = .zipCrypto
    let compressionMethod: ArchiveCompressionMethod? = .store
    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {}
    func extractToTemporaryFile(_ path: String) async throws -> URL { url }
}

@Test func conformerOverridesDispatchThroughExistential() {
    let r: any ArchiveReading = FakeReader()
    #expect(r.encryption == .zipCrypto)
    #expect(r.compressionMethod == .store)
}

@Test func passwordDroppedWhenNoEncryption() throws {
    let a = try ResolvedWriteOptions.resolve(nil, format: .tar, sourceEncryption: .zipCrypto,
                                             sourceMethod: nil, sourcePassword: "pw")
    #expect(a.encryption == .none)
    #expect(a.password == nil)
    let b = try ResolvedWriteOptions.resolve(.init(encryption: .none, password: "x"), format: .zip,
                                             sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
    #expect(b.password == nil)
}
