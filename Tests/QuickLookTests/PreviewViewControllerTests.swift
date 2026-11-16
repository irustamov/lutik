import AppKit
import SwiftUI
import Testing

/// Quick Look bridges the controller's view to the host (ViewBridge) before it calls
/// preparePreviewOfFile. Swapping `view` afterwards made qlmanage report "failed during
/// preview" (ViewBridge Code=17); the listing must go into the existing view instead.
@MainActor
struct PreviewViewControllerTests {
    private static let deflateZip = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/zip/deflate.zip")

    @Test func keepsTheBridgedViewAndAddsTheListingInside() async throws {
        let controller = PreviewViewController()
        let bridged = controller.view

        try await controller.preparePreviewOfFile(at: Self.deflateZip)

        #expect(controller.view === bridged)
        let hosting = try #require(bridged.subviews.first { $0 is NSHostingView<ArchivePreviewView> })
        bridged.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        bridged.layoutSubtreeIfNeeded()
        #expect(hosting.frame == bridged.bounds)
    }
}
