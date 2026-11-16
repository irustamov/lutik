import Testing
@testable import Kernir
import KernirCore

@Suite struct ArchiveCommentTextTests {
    @Test func limitIsSixteenThousandBytes() {
        #expect(ArchiveCommentText.maxBytes == 16_000)
    }

    @Test func limitIsWhatTheEngineWrites() {
        #expect(ArchiveCommentText.maxBytes == ArchiveComment.maximumWritableLength)
    }

    @Test func asciiAtTheLimitIsNotTooLong() {
        #expect(!ArchiveCommentText.isTooLong(String(repeating: "a", count: 16_000)))
    }

    @Test func asciiPastTheLimitIsTooLong() {
        #expect(ArchiveCommentText.isTooLong(String(repeating: "a", count: 16_001)))
    }

    @Test func limitCountsUTF8BytesNotCharacters() {
        // 5 334 × "€" = 5 334 characters but 16 002 UTF-8 bytes.
        let euros = String(repeating: "€", count: 5_334)
        #expect(euros.count < ArchiveCommentText.maxBytes)
        #expect(ArchiveCommentText.isTooLong(euros))
    }

    @Test func emptyTextIsNotTooLong() {
        #expect(!ArchiveCommentText.isTooLong(""))
        #expect(ArchiveCommentText.bytes(for: "") == [])
    }

    @Test func editedTextIsWrittenAsUTF8() {
        #expect(ArchiveCommentText.bytes(for: "héllo") == Array("héllo".utf8))
        #expect(ArchiveCommentText.bytes(for: "héllo").count == 6)
    }

    @Test func asciiStaysASCII() {
        #expect(ArchiveCommentText.bytes(for: "readme\r\n") == [0x72, 0x65, 0x61, 0x64, 0x6D, 0x65, 0x0D, 0x0A])
    }

    @Test func noByteOrderMarkIsAdded() {
        #expect(ArchiveCommentText.bytes(for: "€").first == 0xE2)
    }

    @Test(arguments: ArchiveFormat.allCases)
    func onlyZIPHasComments(format: ArchiveFormat) {
        // ZIP only in 0.1.0; RAR and gzip later.
        #expect(ArchiveCommentText.supportsComments(format) == (format == .zip))
    }

    @Test func noFormatHasNoComment() {
        #expect(!ArchiveCommentText.supportsComments(nil))
    }

    @Test func tooLongMessageComesFromTheSharedTable() {
        #expect(ArchiveCommentText.tooLongMessage == String(localized: "Too long for a ZIP comment.", table: "Shared"))
    }

    // The engine refuses `.set` text whose UTF-8 holds a ZIP end-record signature.
    static let endRecordSignatures: [[UInt8]] = [
        [0x50, 0x4B, 0x05, 0x06], [0x50, 0x4B, 0x06, 0x06], [0x50, 0x4B, 0x06, 0x07],
    ]

    static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    @Test(arguments: endRecordSignatures)
    func signatureAloneIsRefused(signature: [UInt8]) {
        #expect(ArchiveCommentText.hasEndRecordSignature(Self.text(signature)))
    }

    @Test(arguments: endRecordSignatures)
    func signatureMidTextIsRefused(signature: [UInt8]) {
        #expect(ArchiveCommentText.hasEndRecordSignature(Self.text(Array("readme ".utf8) + signature + Array(" more".utf8))))
    }

    @Test(arguments: endRecordSignatures)
    func signatureAtTheVeryEndIsRefused(signature: [UInt8]) {
        #expect(ArchiveCommentText.hasEndRecordSignature(Self.text(Array("readme".utf8) + signature)))
    }

    @Test func pkFollowedByOtherBytesIsAllowed() {
        for tail: [UInt8] in [[0x03, 0x04], [0x01, 0x02], [0x05, 0x05], [0x06, 0x08], [0x07, 0x08], [0x05], []] {
            let text = Self.text(Array("x PK".utf8) + tail + Array(" y".utf8))
            #expect(!ArchiveCommentText.hasEndRecordSignature(text), "\(Array(text.utf8))")
        }
        #expect(!ArchiveCommentText.hasEndRecordSignature("PK"))
        #expect(!ArchiveCommentText.hasEndRecordSignature("PKZIP archive"))
    }

    @Test(arguments: endRecordSignatures)
    func signatureSplitByOneByteIsAllowed(signature: [UInt8]) {
        for gap in 1..<signature.count {
            let split = Array(signature[..<gap]) + [0x20] + Array(signature[gap...])
            #expect(!ArchiveCommentText.hasEndRecordSignature(Self.text(split)), "\(split)")
        }
    }

    @Test func signatureFromUnicodeScalarsIsRefused() {
        #expect(ArchiveCommentText.hasEndRecordSignature("\u{50}\u{4B}\u{5}\u{6}"))
        #expect(ArchiveCommentText.hasEndRecordSignature("note \u{50}\u{4B}\u{6}\u{6}"))
        #expect(ArchiveCommentText.hasEndRecordSignature("\u{50}\u{4B}\u{6}\u{7} end"))
    }

    @Test func plainTextHasNoSignature() {
        #expect(!ArchiveCommentText.hasEndRecordSignature(""))
        #expect(!ArchiveCommentText.hasEndRecordSignature("héllo € readme\r\n"))
    }

    @Test func endRecordMessageComesFromTheSharedTable() {
        #expect(ArchiveCommentText.endRecordSignatureMessage
                == String(localized: "The comment contains bytes a ZIP archive cannot hold", table: "Shared"))
    }

    @Test func validTextHasNoValidationMessage() {
        #expect(ArchiveCommentText.validationMessage(for: "") == nil)
        #expect(ArchiveCommentText.validationMessage(for: "PK readme") == nil)
        #expect(ArchiveCommentText.validationMessage(for: String(repeating: "a", count: 16_000)) == nil)
    }

    @Test func tooLongTextGetsTheLengthMessage() {
        #expect(ArchiveCommentText.validationMessage(for: String(repeating: "a", count: 16_001))
                == ArchiveCommentText.tooLongMessage)
    }

    @Test func signatureTextGetsTheEndRecordMessage() {
        #expect(ArchiveCommentText.validationMessage(for: "a\u{50}\u{4B}\u{5}\u{6}b")
                == ArchiveCommentText.endRecordSignatureMessage)
    }

    @Test func whenBothRulesFailTheLengthMessageWins() {
        // Same order as the engine's check: length first, then signatures.
        let text = String(repeating: "a", count: 16_001) + "\u{50}\u{4B}\u{5}\u{6}"
        #expect(ArchiveCommentText.isTooLong(text))
        #expect(ArchiveCommentText.hasEndRecordSignature(text))
        #expect(ArchiveCommentText.validationMessage(for: text) == ArchiveCommentText.tooLongMessage)
    }
}
