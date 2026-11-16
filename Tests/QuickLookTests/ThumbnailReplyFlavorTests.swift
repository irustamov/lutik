#if os(macOS)
import CoreGraphics
import Foundation
import QuickLookThumbnailing
import Testing

/// Finder's white page: the thumbnail reply must carry the plain icon flavor (0).
/// No Quick Look service involved: it builds a reply in-process. Runs in a scratch
/// SwiftPM package (ThumbnailReplyFlavor.swift + this file).
struct ThumbnailReplyFlavorTests {
    private static func makeReply() -> QLThumbnailReply {
        QLThumbnailReply(contextSize: CGSize(width: 16, height: 16)) { true }
    }

    @Test func plainFlavorIsSetOnTheReply() throws {
        let reply = Self.makeReply()
        // Skip-by-pass where the private setter is absent: the helper is a no-op there.
        guard reply.responds(to: NSSelectorFromString("setIconFlavor:")) else { return }
        let returned = ThumbnailReplyFlavor.applyPlain(to: reply)
        #expect(returned === reply)
        let value = reply.value(forKey: "iconFlavor") as? NSNumber
        #expect(value?.intValue == 0)
    }

    @Test func theSetterExistsOnThisSystem() {
        // Deliberate canary: this fails if Apple removes the private property. The helper then
        // stays a no-op and Finder goes back to the white page.
        #expect(QLThumbnailReply.instancesRespond(to: NSSelectorFromString("setIconFlavor:")))
    }

    @Test func plainOverwritesANonZeroFlavor() {
        // Set the flavor to 1 first, so the result does not depend on the system's "unset" default.
        let reply = Self.makeReply()
        guard reply.responds(to: NSSelectorFromString("setIconFlavor:")) else { return }
        reply.setValue(1, forKey: "iconFlavor")
        #expect((reply.value(forKey: "iconFlavor") as? NSNumber)?.intValue == 1)
        ThumbnailReplyFlavor.applyPlain(to: reply)
        #expect((reply.value(forKey: "iconFlavor") as? NSNumber)?.intValue == 0)
    }
}
#endif
