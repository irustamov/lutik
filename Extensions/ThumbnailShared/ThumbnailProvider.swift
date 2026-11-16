import os
import QuickLookThumbnailing
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Quick Look thumbnails for archives: Finder on macOS (icon, column and gallery views, Get Info,
/// Open/Save panels) and the Files app on iOS/iPadOS. KernirThumbnailMac and KernirThumbnailIOS
/// both compile this one file.
///
/// It draws one bundled picture per archive type (Extensions/ThumbnailAssets/Thumbnails.xcassets),
/// picked from the file name by `ThumbnailArt`. The
/// provider draws nothing of its own on top (no text, no badge); the pictures are shown
/// as they are. Only the name is used: the file is never opened or read, so a dataless (cloud
/// placeholder) file stays dataless.
final class ThumbnailProvider: QLThumbnailProvider {
    private static let log = Logger(subsystem: "com.kernir.app", category: "thumbnail")

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let art = ThumbnailArt.resolve(fileName: request.fileURL.lastPathComponent,
                                       conformance: Self.typeChain(forExtension:))
        let maximum = request.maximumSize
        // The two ways to decline: the art is missing from the bundle, or the request's box is empty.
        guard let loaded = Self.loadArt(named: art.art) else {
            Self.log.error("art \(art.art, privacy: .public) missing from the bundle; declining")
            handler(nil, QLThumbnailError(.generationFailed))
            return
        }
        guard let size = ThumbnailArt.fittedSize(loaded.size, into: maximum) else {
            Self.log.error("art \(art.art, privacy: .public): empty size \(Int(maximum.width))x\(Int(maximum.height)) pt; declining")
            handler(nil, QLThumbnailError(.generationFailed))
            return
        }
        Self.log.info("art \(art.art, privacy: .public) (\(art.rule.rawValue, privacy: .public)) at \(Int(size.width))x\(Int(size.height)) pt @\(request.scale)x")
        let pixels = CGSize(width: (size.width * request.scale).rounded(.up),
                            height: (size.height * request.scale).rounded(.up))
        let image = Self.downsampled(loaded, toPixels: pixels)
        // contextSize is in points; Quick Look backs the context with contextSize × request.scale
        // pixels, so drawing into the point rect renders at the request's scale.
        let rect = CGRect(origin: .zero, size: size)
        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            Self.draw(image, in: rect)
        }
        // macOS: no Finder white page behind the transparent art (no-op on iOS).
        handler(ThumbnailReplyFlavor.applyPlain(to: reply), nil)
    }

    /// For `ThumbnailArt`'s conformance step: the type this appex's UTType database (its imported
    /// declarations included) gives the extension, then its supertypes, most specific first.
    private static func typeChain(forExtension ext: String) -> [String] {
        guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return [] }
        let supertypes = type.supertypes.sorted {
            ($0.supertypes.count, $1.identifier) > ($1.supertypes.count, $0.identifier)
        }
        return [type.identifier] + supertypes.map(\.identifier)
    }

    // MARK: - Loading and drawing
    //
    // Memory: each art is a 1024² PNG, about 4 MB once decoded, and the iOS appex's memory limit is
    // tight. A downsampled CGImageSource read (ImageIO thumbnail, no cache) would be ideal, but the
    // art lives in an asset catalog (Assets.car), not as plain files, and there is no public API to
    // get a CGImageSource for a catalog image without decoding it whole. So, per platform:
    // - macOS: `Bundle.image(forResource:)` reads the catalog like `NSImage(named:)` but does not
    //   register the name, so nothing is cached; the image is dropped once the reply has drawn.
    //   The draw itself scales it into the request's context, which Quick Look sizes in pixels.
    // - iOS: there is no uncached catalog loader, so `UIImage(named:in:with:)` is used (UIKit keeps
    //   it in its named-image cache, which it empties under memory pressure), then
    //   `preparingThumbnail(of:)` makes a copy at the request's pixel size; the reply holds only
    //   that copy, never the full image.
    // Plain PNGs in the bundle would allow the ImageIO path; that changes the asset pipeline, so it
    // waits until the iOS appex is seen running short of memory.

    #if os(macOS)
    private static func loadArt(named name: String) -> NSImage? { Bundle.main.image(forResource: name) }

    /// The draw scales; see the memory note above.
    private static func downsampled(_ image: NSImage, toPixels _: CGSize) -> NSImage { image }

    /// Internal, not private, so a renderer test can call it.
    static func draw(_ image: NSImage, in rect: CGRect) -> Bool {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
        return true
    }
    #else
    private static func loadArt(named name: String) -> UIImage? { UIImage(named: name, in: .main, with: nil) }

    private static func downsampled(_ image: UIImage, toPixels pixels: CGSize) -> UIImage {
        image.preparingThumbnail(of: pixels) ?? image
    }

    static func draw(_ image: UIImage, in rect: CGRect) -> Bool {
        image.draw(in: rect)
        return true
    }
    #endif
}
