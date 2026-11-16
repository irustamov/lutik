import AppKit
import SwiftUI
import Testing
import KernirCore

/// Renders every macOS preview state offscreen and writes PNGs for visual review.
@MainActor
struct MacSnapshotTests {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kernir-ql-snapshots", isDirectory: true)

    @Test func rendersAllStates() throws {
        let sample = PreviewLoader.listing(for: SampleArchive())
        let capped = PreviewLoader.listing(
            for: FakeArchive(entries: (0..<6_000).map {
                ArchiveEntry(path: "f\($0).txt", isDirectory: false, size: 1_000,
                             compressedSize: nil, modificationDate: nil)
            }))
        let states: [(String, PreviewContent, Bool)] = [
            ("sample", .listing(sample), false),
            ("sample-expanded", .listing(sample), true),
            ("empty", .listing(PreviewLoader.listing(for: FakeArchive(entries: []))), false),
            ("password", .passwordProtected(.sevenZip), false),
            ("capped", .listing(capped), false),
            ("volume-part", .volumePart(openedPart: 2), false),
            ("too-large", .tooLarge, false),
        ]
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for (name, content, expandAll) in states {
            for (suffix, appearanceName) in appearances {
                let url = Self.directory.appendingPathComponent("\(name)-\(suffix).png")
                let png = try render(ArchivePreviewView(content: content), expandAll: expandAll,
                                     appearance: NSAppearance(named: appearanceName)!)
                try png.write(to: url)
                print("snapshot: \(url.path)")
                #expect(png.count > 1_024, "\(url.lastPathComponent) is \(png.count) bytes")
            }
        }
    }

    private func render(_ view: ArchivePreviewView, expandAll: Bool, appearance: NSAppearance) throws -> Data {
        // The Quick Look panel supplies the backdrop in production; stand in for it here.
        let backdrop = view.background(Color(nsColor: .windowBackgroundColor))
        let size = NSSize(width: 640, height: 480)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        let hosting = NSHostingView(rootView: backdrop)
        hosting.sizingOptions = []  // as in PreviewViewController
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.display()
        // Table is AppKit-backed and populates its rows asynchronously.
        RunLoop.main.run(until: .now + 0.3)
        if expandAll {
            // Same as Option-clicking the disclosure triangles.
            let outline = try #require(firstOutlineView(in: hosting))
            outline.expandItem(nil, expandChildren: true)
            RunLoop.main.run(until: .now + 0.3)
        }
        hosting.layoutSubtreeIfNeeded()

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func firstOutlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { firstOutlineView(in: $0) }.first
    }
}
