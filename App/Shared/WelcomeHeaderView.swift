import SwiftUI

/// The iOS Welcome sheet's header art (the one exception to PRODUCT.md's stock-colors rule, the header
/// block only, the same in light and dark mode).
///
/// The art (Welcome.xcassets/WelcomeHeader, 1600 x 686 from the App Store header art) always
/// fills the container's width at its own aspect, with no fill beside it. Under a height cap it is
/// aspect-filled and loses rows only from its flat bands: the top ~19% is flat #FF00A8 and the
/// bottom ~13% flat #1D1D1F (sampled in step A; `WelcomeContentTests` checks them against the asset).
enum WelcomeHeaderArt {
    /// The asset's name in Welcome.xcassets.
    static let imageName = "WelcomeHeader"
    /// Width / height of the art (1600 x 686 px, from 3840 x 1646).
    static let aspectRatio: CGFloat = 1600.0 / 686.0

    /// The art's flat top band, a fraction of its height, and its color.
    static let flatTop: CGFloat = 0.19
    static let topRGB: UInt32 = 0xFF00A8
    /// The art's flat bottom band, a fraction of its height, and its color.
    static let flatBottom: CGFloat = 0.13
    static let bottomRGB: UInt32 = 0x1D1D1F

    /// The header's height at `width` and where the art goes in it (it may overhang the frame
    /// above and below, to be clipped). Full width at the art's aspect; with `maxHeight` below
    /// that, the excess comes off the flat bands in proportion to their sizes, never off the
    /// content between them (so the cap is not met below the content's height).
    static func layout(width: CGFloat, maxHeight: CGFloat?) -> (height: CGFloat, imageRect: CGRect) {
        guard width > 0 else { return (0, .zero) }
        let natural = width / aspectRatio
        let content = natural * (1 - flatTop - flatBottom)
        let height = min(natural, max(content, maxHeight ?? natural))
        let cropTop = (natural - height) * flatTop / (flatTop + flatBottom)
        return (height, CGRect(x: 0, y: -cropTop, width: width, height: natural))
    }
}

/// The iOS Welcome sheet's header (the Mac window shows its hero, `WelcomeView`, instead): the art
/// across the full width, capped at `maxHeight` if given. Decorative for VoiceOver: the title under it says "Welcome to <app>", and the art's lettering
/// is the brand name, which may differ from the display name while the rename is on hold.
struct WelcomeHeaderView: View {
    var maxHeight: CGFloat?

    var body: some View {
        WelcomeHeaderLayout(maxHeight: maxHeight) {
            Image(decorative: WelcomeHeaderArt.imageName)
                .resizable()
                .interpolation(.high)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Sizes the header from the width it is offered (`WelcomeHeaderArt.layout`) and places the art.
private struct WelcomeHeaderLayout: Layout {
    var maxHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 1600.0 / 2
        return CGSize(width: width, height: WelcomeHeaderArt.layout(width: width, maxHeight: maxHeight).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rect = WelcomeHeaderArt.layout(width: bounds.width, maxHeight: maxHeight).imageRect
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                          proposal: ProposedViewSize(rect.size))
        }
    }
}
