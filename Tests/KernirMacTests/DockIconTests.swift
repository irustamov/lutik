import AppKit
import Testing
@testable import Kernir

/// The running Dock tile art (AppDelegate.installDockIcon): a 512 px PNG with alpha in the app bundle
/// (the Dock draws at most 128 pt, 256 px on Retina).
struct DockIconTests {
    @Test func dockIconResolvesFromMainBundleAt512() throws {
        let image = try #require(NSImage(named: AppDelegate.dockIconName))
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == 512)
        #expect(rep.pixelsHigh == 512)
        #expect(rep.hasAlpha)
    }

    /// The art looks as big as its Dock neighbours. A macOS icon's
    /// squircle is 824 of 1024 px and covers about 61 % of the tile; the plate-free art is a narrower,
    /// irregular shape, so it needs a taller box: >= 90 % of the tile high, >= 77 % wide, centred, with a
    /// margin so it never touches the tile edge. The first art (708 x 816 px of 1024) failed this.
    @MainActor @Test func dockIconFillsTheTileLikeNeighbouringIcons() throws {
        let side = 256
        let image = try #require(NSImage(named: AppDelegate.dockIconName))
        let pixels = try #require(Self.pixels(of: image, side: side))
        var minX = side, maxX = -1, minY = side, maxY = -1
        for y in 0..<side {
            for x in 0..<side where pixels[(y * side + x) * 4 + 3] > 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let width = Double(maxX - minX + 1) / Double(side), height = Double(maxY - minY + 1) / Double(side)
        #expect(height >= 0.90, "art height \(height) of the tile")
        #expect(width >= 0.77, "art width \(width) of the tile")
        #expect(min(minX, minY, side - 1 - maxX, side - 1 - maxY) >= side / 64, "art touches the tile edge")
        #expect(abs((minX + maxX) - (side - 1)) <= side / 32, "art off centre horizontally")
        #expect(abs((minY + maxY) - (side - 1)) <= side / 32, "art off centre vertically")
    }

    /// The hosted app's launch (applicationWillFinishLaunching) installed the art as the Dock tile.
    /// AppKit keeps its own copy (other instance, other representations, other TIFF bytes), so the
    /// images are compared by what they draw: both rendered to 16 x 16 RGBA. The stock bundle icon
    /// (AppIcon.icon, with the system plate) must look clearly different, so a launch that left the
    /// default icon fails.
    @MainActor @Test func dockIconIsInstalledAtLaunch() throws {
        let dockIcon = try #require(NSImage(named: AppDelegate.dockIconName))
        let installed = try #require(NSApp.applicationIconImage)
        let stock = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let art = try #require(Self.pixels(of: dockIcon))
        let installedPixels = try #require(Self.pixels(of: installed))
        let stockPixels = try #require(Self.pixels(of: stock))
        let installedDiff = Self.meanDifference(installedPixels, art)
        let stockDiff = Self.meanDifference(stockPixels, art)
        #expect(installedDiff < 6, "installed Dock icon differs from DockIcon by \(installedDiff)")
        #expect(stockDiff > 3 * max(installedDiff, 6), "stock icon \(stockDiff) vs installed \(installedDiff)")
    }

    /// The image drawn into a 16 x 16 premultiplied RGBA bitmap, row-major bytes.
    @MainActor private static func pixels(of image: NSImage, side: Int = 16) -> [UInt8]? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: side * side * 4))
    }

    /// Mean absolute difference per channel byte, 0...255.
    private static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.count)
    }
}
