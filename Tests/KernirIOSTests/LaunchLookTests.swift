import Foundation
import MachO
import Testing
@testable import Kernir

/// Which stock launch title view UIKit draws (`LaunchLook`): the art-only one only on iOS 27+ for
/// an app linked against SDK 27+, else the legacy card.
@Suite struct LaunchLookTests {
    @Test func legacyCardUnlessBothOSAndSDKAre27() {
        #expect(!LaunchLook.usesLegacyCard(osMajor: 27, linkedSDKMajor: 27))
        #expect(!LaunchLook.usesLegacyCard(osMajor: 28, linkedSDKMajor: 27))
        #expect(!LaunchLook.usesLegacyCard(osMajor: 27, linkedSDKMajor: 28))
        #expect(LaunchLook.usesLegacyCard(osMajor: 27, linkedSDKMajor: 26))
        #expect(LaunchLook.usesLegacyCard(osMajor: 26, linkedSDKMajor: 27))
        #expect(LaunchLook.usesLegacyCard(osMajor: 26, linkedSDKMajor: 26))
        #expect(LaunchLook.usesLegacyCard(osMajor: 18, linkedSDKMajor: 27))
        #expect(LaunchLook.usesLegacyCard(osMajor: 27, linkedSDKMajor: 0), "an unreadable SDK gets the card")
    }

    @Test func lookFollowsTheCondition() {
        #expect(LaunchLook.look(osMajor: 27, linkedSDKMajor: 27) == .art)
        #expect(LaunchLook.look(osMajor: 27, linkedSDKMajor: 26) == .card)
        #expect(LaunchLook.look(osMajor: 18, linkedSDKMajor: 27) == .card)
    }

    /// The Mach-O read agrees with the SDK Xcode records in the built Info.plist (`DTPlatformVersion`).
    @Test func mainExecutableSDKMatchesTheBuiltInfoPlist() throws {
        let sdk = try #require(LaunchLook.mainExecutableSDKMajor)
        let platform = try #require(Bundle.main.object(forInfoDictionaryKey: "DTPlatformVersion") as? String)
        #expect(sdk == Int(platform.split(separator: ".").first ?? ""))
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #expect(LaunchLook.current == LaunchLook.look(osMajor: os, linkedSDKMajor: sdk))
    }

    /// A crafted image: the header, a segment (skipped by its `cmdsize`), then `LC_BUILD_VERSION`
    /// with SDK 27.0 (`0x001B0000`, major in the high 16 bits) and minos 17.0.
    @Test func sdkFromABuildVersionAfterASegment() {
        let segmentSize = MemoryLayout<segment_command_64>.size
        let buildSize = MemoryLayout<build_version_command>.size
        let headerSize = MemoryLayout<mach_header_64>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: headerSize + segmentSize + buildSize,
                                                      alignment: 8)
        defer { buffer.deallocate() }
        var header = mach_header_64()
        header.magic = MH_MAGIC_64
        header.filetype = UInt32(MH_EXECUTE)
        header.ncmds = 2
        header.sizeofcmds = UInt32(segmentSize + buildSize)
        buffer.storeBytes(of: header, as: mach_header_64.self)
        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(segmentSize)
        buffer.storeBytes(of: segment, toByteOffset: headerSize, as: segment_command_64.self)
        var build = build_version_command()
        build.cmd = UInt32(LC_BUILD_VERSION)
        build.cmdsize = UInt32(buildSize)
        build.platform = UInt32(PLATFORM_IOSSIMULATOR)
        build.minos = 0x0011_0000
        build.sdk = 0x001B_0000
        buffer.storeBytes(of: build, toByteOffset: headerSize + segmentSize, as: build_version_command.self)
        #expect(LaunchLook.sdkMajor(of: buffer.bindMemory(to: mach_header.self, capacity: 1)) == 27)
    }

    @Test func noSDKInAnImageWithoutLoadCommands() {
        var header = mach_header_64()
        header.magic = MH_MAGIC_64
        header.ncmds = 0
        withUnsafePointer(to: &header) { pointer in
            pointer.withMemoryRebound(to: mach_header.self, capacity: 1) {
                #expect(LaunchLook.sdkMajor(of: $0) == nil)
            }
        }
    }
}
