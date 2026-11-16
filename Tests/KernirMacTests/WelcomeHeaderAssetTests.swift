import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Kernir

/// The Welcome header art in the app's asset catalog (App/Shared/Welcome.xcassets). KernirMacTests
/// only: the shared harness compiles no asset catalog, so it has no image to read.
struct WelcomeHeaderAssetTests {
    /// The bands the header may crop really are flat in the asset: every pixel of every row there
    /// is the top or bottom color (within 2/255), so cropping them never cuts into the art.
    @Test func headerFlatBandsMatchTheAsset() throws {
        let image = try #require(NSImage(named: WelcomeHeaderArt.imageName))
        let width = 1600, height = 686
        var proposed = CGRect(x: 0, y: 0, width: width, height: height)
        let cgImage = try #require(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Row 0 of the buffer is the art's top row.
        func rowMatches(_ row: Int, _ rgb: UInt32) -> Bool {
            let want = [Int((rgb >> 16) & 0xFF), Int((rgb >> 8) & 0xFF), Int(rgb & 0xFF)]
            return (0..<width).allSatisfy { x in
                let i = (row * width + x) * 4
                return (0..<3).allSatisfy { abs(Int(pixels[i + $0]) - want[$0]) <= 2 }
            }
        }
        let topRows = Int((CGFloat(height) * WelcomeHeaderArt.flatTop).rounded(.up))
        let bottomRows = Int((CGFloat(height) * WelcomeHeaderArt.flatBottom).rounded(.up))
        #expect((0..<topRows).allSatisfy { rowMatches($0, WelcomeHeaderArt.topRGB) })
        #expect((height - bottomRows..<height).allSatisfy { rowMatches($0, WelcomeHeaderArt.bottomRGB) })
        #expect(WelcomeHeaderArt.topRGB == 0xFF00A8 && WelcomeHeaderArt.bottomRGB == 0x1D1D1F)
    }
}

/// The Mac Welcome window's hero: its art (App/macOS/WelcomeMac.xcassets/WelcomeHeroArt, Mac only) and the one
/// gradient behind it.
struct WelcomeHeroTests {
    /// Nothing in the art touches its edges (the gzip and CD icons were cut there): a clear margin of
    /// at least 8 px on every side.
    @Test func heroArtHasClearMargins() throws {
        let image = try #require(NSImage(named: WelcomeHeaderArt.heroImageName))
        var proposed = CGRect(origin: .zero, size: image.size)
        let cgImage = try #require(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        let width = cgImage.width, height = cgImage.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let margin = 8
        var opaqueAtEdge = 0
        for y in 0..<height {
            for x in 0..<width where x < margin || x >= width - margin || y < margin || y >= height - margin {
                if pixels[(y * width + x) * 4 + 3] != 0 { opaqueAtEdge += 1 }
            }
        }
        #expect(opaqueAtEdge == 0, "\(opaqueAtEdge) pixels of the art within \(margin) px of its edges")
    }

    /// One gradient: the magenta, solid down to `solidEnd`, then eased out to clear (the window's
    /// background) at the bottom, with no step anywhere.
    @Test func heroGradientIsSolidThenEasesOut() {
        let stops = WelcomeHeroBackground.stops(solidEnd: 0.8)
        #expect(stops.first?.location == 0 && stops.first?.opacity == 1)
        #expect(stops.contains { $0.location == 0.8 && $0.opacity == 1 })
        #expect(stops.last?.location == 1 && stops.last?.opacity == 0)
        for (a, b) in zip(stops, stops.dropFirst()) {
            #expect(a.location <= b.location && a.opacity >= b.opacity)
            // Eased: no single step drops more than a fifth of the way.
            #expect(a.opacity - b.opacity <= 0.2)
        }
        // Eased at both ends: the first and last steps of the fade are gentler than a straight line.
        let fade = stops.filter { $0.location >= 0.8 }
        let linearStep = 1 / Double(fade.count - 1)
        #expect(fade[0].opacity - fade[1].opacity < linearStep)
        #expect(fade[fade.count - 2].opacity - fade[fade.count - 1].opacity < linearStep)
    }

    /// The hero's magenta is exactly #FF00A8 in sRGB.
    @Test func heroColorIsExactlyFF00A8() throws {
        let color = try #require(NSColor(WelcomeHeroBackground.color).usingColorSpace(.sRGB))
        let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        #expect(rgb == [0xFF, 0x00, 0xA8])
    }

    /// The hero's New Archive button is white in both appearances: its ink is white,
    /// and the rendered outline and label have only white ink pixels, light and dark.
    @Test func newArchiveButtonInkIsWhite() {
        #expect(WelcomeOutlineButtonStyle.ink == .white)
    }

    @MainActor @Test(arguments: [ColorScheme.light, .dark])
    func newArchiveButtonRendersWhiteInBothAppearances(scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: WelcomeOutlineCapsule(
            label: Text(verbatim: "New Archive"), isPressed: false, isFocused: false)
            .padding(8)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // The context is premultiplied: white ink of alpha a stores r = g = b = a. Un-premultiply
        // before comparing, so antialiased edge pixels are judged by their colour, not their coverage.
        var solid = 0, notWhite = 0
        var sample = "none"
        for i in 0..<(width * height) where pixels[i * 4 + 3] > 200 {
            solid += 1
            let a = Int(pixels[i * 4 + 3])
            let rgb = (0..<3).map { min(255, (Int(pixels[i * 4 + $0]) * 255 + a / 2) / a) }
            if rgb.contains(where: { $0 < 245 }) {
                notWhite += 1
                if notWhite == 1 { sample = "rgba(premultiplied) \(pixels[i * 4]),\(pixels[i * 4 + 1]),\(pixels[i * 4 + 2]),\(a) -> rgb \(rgb)" }
            }
        }
        #expect(solid > 100, "solid ink pixels: \(solid) of \(width * height)")
        #expect(notWhite == 0, "non-white ink pixels: \(notWhite) of \(solid) solid; first: \(sample)")
    }

    /// The outline stays inside its capsule (no bars past the round ends, as the A3 snapshots had);
    /// focused (Full Keyboard Access, Tab), a ring shows outside it.
    @MainActor @Test(arguments: [ColorScheme.light, .dark])
    func newArchiveOutlineStaysInsideItsCapsuleAndShowsFocus(scheme: ColorScheme) throws {
        let pad: CGFloat = 8
        func inkOutside(focused: Bool) throws -> Int {
            let renderer = ImageRenderer(content: WelcomeOutlineCapsule(
                label: Text(verbatim: "New Archive"), isPressed: false, isFocused: focused)
                .padding(pad)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            return try Self.inkAroundCapsule(try #require(renderer.cgImage), pad: pad).outside
        }
        #expect(try inkOutside(focused: false) == 0)
        #expect(try inkOutside(focused: true) > 100)
    }

    /// The real button, rendered as `-WelcomeSnapshot` does (`cacheDisplay` of its hosting view at 2x):
    /// no ink past the round ends. SwiftUI shape strokes came out there with 18 pt bars at both ends
    /// (A3/A4 snapshots), though the window on screen drew them clean.
    @MainActor @Test(arguments: [ColorScheme.light, .dark])
    func newArchiveOutlineHasNoBarsInACacheDisplaySnapshot(scheme: ColorScheme) throws {
        let pad: CGFloat = 8
        let host = NSHostingView(rootView: Button("New Archive") {}
            .buttonStyle(WelcomeOutlineButtonStyle())
            .padding(pad)
            .environment(\.colorScheme, scheme))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        let image = try #require(rep.cgImage)
        let (outside, inside) = try Self.inkAroundCapsule(image, pad: pad)
        #expect(outside == 0)
        #expect(inside > 500)
    }

    /// Pixels with ink (alpha above 24) outside and inside the capsule that fills `image` less `pad`
    /// points (2x pixels) on every side; one pixel of slack for antialiasing.
    private static func inkAroundCapsule(_ image: CGImage, pad: CGFloat) throws -> (outside: Int, inside: Int) {
        let width = image.width, height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let inset = pad * 2, r = (CGFloat(height) - 2 * inset) / 2
        let left = inset + r, right = CGFloat(width) - inset - r, midY = inset + r
        var outside = 0, inside = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
                let px = CGFloat(x) + 0.5, py = CGFloat(y) + 0.5
                let dx = px < left ? left - px : (px > right ? px - right : 0)
                if (dx * dx + (py - midY) * (py - midY)).squareRoot() > r + 1 { outside += 1 } else { inside += 1 }
            }
        }
        return (outside, inside)
    }
}
