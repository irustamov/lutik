import Foundation
import MachO

/// Which stock launch title view UIKit draws. iOS 27 draws the art-only one only for an app whose
/// main executable is linked against SDK 27 or later; every other case (iOS 18-26, or an older
/// SDK on iOS 27) gets the legacy title card: a rounded card over the background, holding the
/// stock title and primary action (fill the card).
enum LaunchLook: Equatable {
    /// The Lutik art with New Archive on it, no stock title.
    case art
    /// The legacy card, filled with the stock title and New Archive; the gradient behind it.
    case card

    /// UIKit's condition for the legacy card: unless both the OS and the linked SDK are 27+.
    static func usesLegacyCard(osMajor: Int, linkedSDKMajor: Int) -> Bool {
        osMajor < 27 || linkedSDKMajor < 27
    }

    static func look(osMajor: Int, linkedSDKMajor: Int) -> LaunchLook {
        usesLegacyCard(osMajor: osMajor, linkedSDKMajor: linkedSDKMajor) ? .card : .art
    }

    /// This process's look: the running OS and the main executable's linked SDK (0, the card,
    /// when it can't be read).
    static let current = look(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                              linkedSDKMajor: mainExecutableSDKMajor ?? 0)

    /// The main executable's linked SDK major version, from its Mach-O `LC_BUILD_VERSION` (or a
    /// legacy `LC_VERSION_MIN_*`), as UIKit reads it; nil when there is none.
    /// The main executable is the loaded image of type `MH_EXECUTE` (not always image 0: on the
    /// iOS 17 simulator runtime image 0 is a system library).
    static var mainExecutableSDKMajor: Int? {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), header.pointee.filetype == MH_EXECUTE else { continue }
            return sdkMajor(of: header)
        }
        return nil
    }

    /// The linked SDK major version recorded in a 64-bit Mach-O image's load commands.
    static func sdkMajor(of header: UnsafePointer<mach_header>) -> Int? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        let base = UnsafeRawPointer(header)
        var offset = MemoryLayout<mach_header_64>.size
        for _ in 0..<header.pointee.ncmds {
            let command = base.loadUnaligned(fromByteOffset: offset, as: load_command.self)
            switch command.cmd {
            case UInt32(LC_BUILD_VERSION):
                let build = base.loadUnaligned(fromByteOffset: offset, as: build_version_command.self)
                return Int(build.sdk >> 16)
            case UInt32(LC_VERSION_MIN_IPHONEOS):
                let minimum = base.loadUnaligned(fromByteOffset: offset, as: version_min_command.self)
                return Int(minimum.sdk >> 16)
            default:
                offset += Int(command.cmdsize)
            }
        }
        return nil
    }
}
