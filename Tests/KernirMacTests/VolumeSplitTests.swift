import Testing
import Foundation
import KernirCore
@testable import Kernir

struct VolumeSplitTests {
    private let english = Locale(identifier: "en_US")
    private let russian = Locale(identifier: "ru_RU")

    @Test func presetsAreDecimalMegabytesAndTheFAT32FileLimit() {
        #expect(VolumeSplit.preset(.mb25).bytes == 25_000_000)
        #expect(VolumeSplit.preset(.mb100).bytes == 100_000_000)
        #expect(VolumeSplit.preset(.mb700).bytes == 700_000_000)
        // 4 GiB − 1: the largest file FAT32 can hold.
        #expect(VolumeSplit.preset(.fat32).bytes == 4_294_967_295)
        for preset in VolumeSplit.Preset.allCases {
            #expect(VolumeSplit.preset(preset).problem(estimatedSize: nil) == nil)
        }
    }

    @Test func customAmountsParseInTheLocale() {
        #expect(VolumeSplit.custom(amount: "1.5", unit: .gb).bytes(locale: english) == 1_500_000_000)
        #expect(VolumeSplit.custom(amount: "1,5", unit: .gb).bytes(locale: russian) == 1_500_000_000)
        #expect(VolumeSplit.custom(amount: " 10 ", unit: .mb).bytes(locale: english) == 10_000_000)
        #expect(VolumeSplit.custom(amount: "2", unit: .gb).bytes(locale: russian) == 2_000_000_000)
        #expect(VolumeSplit.custom(amount: "1,5", unit: .gb).problem(estimatedSize: nil, locale: russian) == nil)
    }

    @Test func aFractionOfAByteRoundsUpAndAWholeByteStays() {
        // 1.0000001 MB is 1 000 000.1 bytes: the volume is one byte bigger, never one smaller.
        #expect(VolumeSplit.custom(amount: "1.0000001", unit: .mb).bytes(locale: english) == 1_000_001)
        #expect(VolumeSplit.custom(amount: "1.0000009", unit: .mb).bytes(locale: english) == 1_000_001)
        #expect(VolumeSplit.custom(amount: "0.0000000001", unit: .gb).bytes(locale: english) == 1)
        // Exact amounts don't move.
        #expect(VolumeSplit.custom(amount: "1.000001", unit: .mb).bytes(locale: english) == 1_000_001)
        #expect(VolumeSplit.custom(amount: "0.000000001", unit: .gb).bytes(locale: english) == 1)
        // Rounding up lifts 999 999.1 bytes to 1 000 000, which is no longer too small.
        #expect(VolumeSplit.custom(amount: "0.9999991", unit: .mb).problem(estimatedSize: nil, locale: english)
            == nil)
    }

    @Test(arguments: ["", " ", "abc", "-3", "0", "0.0", "1.5.2", "1e3", "12abc", "99999999999999999999"])
    func customInputThatIsNoSizeIsInvalid(_ amount: String) {
        let split = VolumeSplit.custom(amount: amount, unit: .mb)
        #expect(split.bytes(locale: english) == nil)
        #expect(split.problem(estimatedSize: nil, locale: english) == .invalidSize)
    }

    @Test func aGroupingSeparatorIsNotADecimalPoint() {
        // In German "." groups thousands, so "1.5" is no size there; "1,5" is.
        let german = Locale(identifier: "de_DE")
        #expect(VolumeSplit.custom(amount: "1,5", unit: .gb).bytes(locale: german) == 1_500_000_000)
        #expect(VolumeSplit.custom(amount: "1.5", unit: .gb).problem(estimatedSize: nil, locale: german) == .invalidSize)
    }

    @Test func lessThanTheMinimumIsTooSmall() {
        #expect(VolumeSplit.minimumBytes == 1_000_000)
        #expect(VolumeSplit.minimumBytes == ArchiveWriteOptions.minimumVolumeSize)
        #expect(VolumeSplit.custom(amount: "0.5", unit: .mb).problem(estimatedSize: nil, locale: english) == .tooSmall)
        #expect(VolumeSplit.custom(amount: "0.000001", unit: .mb).problem(estimatedSize: nil, locale: english)
            == .tooSmall)
        #expect(VolumeSplit.custom(amount: "1", unit: .mb).problem(estimatedSize: nil, locale: english) == nil)
    }

    @Test func noSplitHasNoBytesAndNoProblem() {
        #expect(VolumeSplit.none.bytes == nil)
        #expect(VolumeSplit.none.problem(estimatedSize: nil) == nil)
        #expect(VolumeSplit.none.problem(estimatedSize: .max) == nil)
    }

    @Test func moreThanTheMaximumVolumesIsAProblem() {
        #expect(VolumeSplit.maximumVolumes == 999)
        #expect(VolumeSplit.maximumVolumes == ArchiveWriteOptions.maximumVolumeCount)
        let split = VolumeSplit.custom(amount: "1", unit: .mb)
        // 999 volumes exactly is fine; one byte more needs a 1000th.
        #expect(split.problem(estimatedSize: 999_000_000, locale: english) == nil)
        #expect(split.problem(estimatedSize: 999_000_001, locale: english) == .tooManyVolumes)
        #expect(split.problem(estimatedSize: nil, locale: english) == nil)
        #expect(VolumeSplit.preset(.mb25).problem(estimatedSize: 25_000_000 * 1_000) == .tooManyVolumes)
        #expect(VolumeSplit.preset(.mb25).problem(estimatedSize: 0) == nil)
    }

    @Test func anInvalidSizeIsReportedBeforeTooManyVolumes() {
        #expect(VolumeSplit.custom(amount: "0.5", unit: .mb).problem(estimatedSize: .max, locale: english) == .tooSmall)
        #expect(VolumeSplit.custom(amount: "x", unit: .mb).problem(estimatedSize: .max, locale: english)
            == .invalidSize)
    }
}
