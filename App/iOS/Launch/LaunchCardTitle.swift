import UIKit

/// The card look's title: our art, the Lutik wordmark at its place in
/// lutik_header.psd but behind the dog (its ears in front of the letters), in UIKit's legacy
/// title card in place of the stock text title, New Archive kept below it. `LaunchOptions` has no title image, but the card's content is a public
/// `UIContentUnavailableView`: its configuration gets the art as its image and loses its text;
/// the button stays as UIKit set it. A `LaunchCardArtKeeper` puts the art back whenever UIKit
/// sets the configuration again. Without such a view showing the title, the stock text stays.
@available(iOS 18.0, *)
@MainActor
enum LaunchCardTitle {
    static let wordmarkAssetName = "LaunchWordmark"
    /// The dog alone (the PSD's "Layer 1", "Layer 5" and the half-opaque shadow "Layer 1 copy"),
    /// in `LaunchMark`'s frame: `LaunchMark` carries the white wordmark, which would cover ours.
    static let dogAssetName = "LaunchCardDog"
    /// The wordmark's tint: the gradient's top (site.css `.lutik`), as the white wordmark on the
    /// art would be invisible on the white card.
    static let wordmarkTint = LaunchHeaderPalette.brand

    /// `LaunchMark`'s size in its pixels (the dog layer has its aspect), and the wordmark's place
    /// on it (the PSD's "Layer 3", 2853 x 979 at PSD (8295, 968), with the mark at PSD x 8282.5, row 958, 2890 px wide), drawn
    /// first: the dog goes on top (the text at the same place, behind the dog).
    static let markSize = CGSize(width: 694, height: 814)
    static let wordmarkRect: CGRect = {
        let scale = markSize.width / 2890
        return CGRect(x: (8295 - 8282.5) * scale, y: (968 - 958) * scale,
                      width: 2853 * scale, height: 979 * scale)
    }()


    /// The art's height: at most `maxArtHeight`, at least `minArtHeight` (below that the art would
    /// be a smudge, and the stock title shows instead).
    static let maxArtHeight: CGFloat = 320
    static let minArtHeight: CGFloat = 60
    /// New Archive's height when the card has no button to measure (a large capsule button is
    /// about 51 pt tall at the default text size), scaled with the text size.
    static let fallbackButtonHeight: CGFloat = 60

    /// The art in one image, rendered once at its largest; the card scales it down.
    static let artImage: UIImage? = renderArt(height: maxArtHeight)

    static func renderArt(height: CGFloat) -> UIImage? {
        guard let dog = UIImage(named: dogAssetName),
              let wordmark = UIImage(named: wordmarkAssetName) else { return nil }
        let scale = height / markSize.height
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let size = CGSize(width: markSize.width * scale, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let word = wordmarkRect
            wordmark.withTintColor(wordmarkTint, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: word.minX * scale, y: word.minY * scale,
                                 width: word.width * scale, height: word.height * scale))
            dog.draw(in: CGRect(origin: .zero, size: size))
        }
        let art = image.withRenderingMode(.alwaysOriginal)
        art.accessibilityIdentifier = artIdentifier
        return art
    }

    /// Marks the art image, should UIKit hand the card's image view a copy of it.
    static let artIdentifier = "LaunchCardArt"

    static func isArt(_ image: UIImage?) -> Bool {
        guard let image else { return false }
        return image === artImage || image.accessibilityIdentifier == artIdentifier
    }

    /// The art's size in a card of `height` points with `config` and a `buttonHeight` button: the
    /// room inside the card's margins (UIKit sets a large bottom one for the part under the
    /// browser sheet; the card hides an image that does not fit) less the button and its
    /// paddings, up to the cap. Zero height (not laid out yet): the cap. Nil without room.
    static func artSize(cardHeight height: CGFloat, buttonHeight: CGFloat,
                        configuration config: UIContentUnavailableConfiguration) -> CGSize? {
        var artHeight = maxArtHeight
        if height > 0 {
            let margins = config.directionalLayoutMargins
            let room = height - margins.top - margins.bottom - buttonHeight
                - config.imageToTextPadding - config.textToButtonPadding
            artHeight = min(maxArtHeight, room.rounded(.down))
        }
        return size(forArtHeight: artHeight)
    }

    /// The art at `height`, its aspect kept; nil below `minArtHeight`.
    static func size(forArtHeight height: CGFloat) -> CGSize? {
        guard height >= minArtHeight else { return nil }
        return CGSize(width: (height * markSize.width / markSize.height).rounded(), height: height)
    }

    /// New Archive's height in `card`, measured (it grows with the text size), else the fallback
    /// scaled to the card's text size.
    static func buttonHeight(in card: UIContentUnavailableView) -> CGFloat {
        if let button = firstView(in: card, excluding: nil, depth: 0, where: { $0 is UIButton && !$0.isHidden }) {
            let fitted = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
            if fitted > 0 { return fitted.rounded(.up) }
        }
        return UIFontMetrics.default.scaledValue(for: fallbackButtonHeight, compatibleWith: card.traitCollection)
            .rounded(.up)
    }

    /// Puts the art in the title card under `roots` (later calls re-check it). `title`: the stock
    /// title's text. Views under `excluded` (the browser) are never searched. UIKit leaves
    /// `_UIDocumentLaunchView` out of its superview's `subviews` (iOS 27.2 simulator), so the
    /// document view controller passes its children's views too. Nil when no card was found.
    @discardableResult
    static func install(in roots: [UIView], title: String, excluding excluded: UIView?) -> UIContentUnavailableView? {
        guard !title.isEmpty, artImage != nil,
              let card = roots.lazy.compactMap({ self.card(in: $0, title: title, excluding: excluded) }).first
        else { return nil }
        return install(on: card, title: title)
    }

    /// Puts the art in `card`, found before: nil when it no longer is the title card.
    @discardableResult
    static func install(on card: UIContentUnavailableView, title: String) -> UIContentUnavailableView? {
        guard !title.isEmpty, artImage != nil, isCard(card, title: title) else { return nil }
        if let keeper = card.subviews.lazy.compactMap({ $0 as? LaunchCardArtKeeper }).first {
            keeper.reapply()
        } else {
            let keeper = LaunchCardArtKeeper(title: title)
            card.addSubview(keeper)
            keeper.reapply()
        }
        return card
    }

    /// The card under `root`: a content-unavailable view showing `title`, or our art already.
    static func card(in root: UIView, title: String, excluding excluded: UIView?) -> UIContentUnavailableView? {
        firstView(in: root, excluding: excluded, depth: 0) { view in
            guard let card = view as? UIContentUnavailableView else { return false }
            return isCard(card, title: title)
        } as? UIContentUnavailableView
    }

    static func isCard(_ card: UIContentUnavailableView, title: String) -> Bool {
        guard !card.isHidden, let config = card.configuration as? UIContentUnavailableConfiguration else { return false }
        return showsArt(config) || config.text == title || config.attributedText?.string == title
    }

    static func showsArt(_ config: UIContentUnavailableConfiguration) -> Bool {
        isArt(config.image)
    }

    /// Shows the art at `size` in `card` in place of its text, or the stock `title` again for nil;
    /// the button as it was. Sets the configuration only when it changes.
    static func apply(_ size: CGSize?, to card: UIContentUnavailableView, title: String) {
        guard var config = card.configuration as? UIContentUnavailableConfiguration,
              let art = artImage else { return }
        guard let size else {
            if showsArt(config) {
                config.image = nil
                config.imageProperties.maximumSize = .zero
                config.text = title
                card.configuration = config
            }
            return
        }
        if !showsArt(config) || config.text != nil || config.attributedText != nil
            || config.imageProperties.maximumSize != size {
            config.image = art
            config.imageProperties.maximumSize = size
            config.imageProperties.accessibilityIgnoresInvertColors = true
            config.imageProperties.tintColor = nil
            config.text = nil
            config.attributedText = nil
            card.configuration = config
        }
    }

    /// The card's image view: the art's, else the first outside the button (UIKit may show a copy
    /// of the art or rebuild the view).
    static func artImageView(in card: UIContentUnavailableView) -> UIImageView? {
        if let view = firstView(in: card, excluding: nil, depth: 0, where: { isArt(($0 as? UIImageView)?.image) }) {
            return view as? UIImageView
        }
        return firstView(in: card, excluding: nil, depth: 0, skipping: { $0 is UIButton || $0 is LaunchCardArtKeeper },
                         where: { $0 is UIImageView }) as? UIImageView
    }

    /// Depth-first, in subview order, skipping the subtree of `excluded` and of views `skipping`
    /// matches; bounded depth.
    static func firstView(in root: UIView, excluding excluded: UIView?, depth: Int,
                          skipping skip: (UIView) -> Bool = { _ in false },
                          where match: (UIView) -> Bool) -> UIView? {
        if root === excluded || depth > 24 || (depth > 0 && skip(root)) { return nil }
        if match(root) { return root }
        for subview in root.subviews {
            if let found = firstView(in: subview, excluding: excluded, depth: depth + 1, skipping: skip, where: match) {
                return found
            }
        }
        return nil
    }
}

/// How tall the art should be, with memory of the keeper's own changes, so a card whose height
/// follows its content settles. On the first pass at a new height after one of our own changes:
/// when the card's height changed by exactly what that change made it change (±1 pt), the art
/// stays; after a change that followed one of our own, the art does not shrink again if the
/// card's height moved the way ours did, by no more. A held art stays only while the card keeps
/// the height it was held at; any other height re-fits. Heights: 0 is the stock title.
struct LaunchCardArtSizing: Equatable {
    /// The card's height the art was last sized for, the art height set then and the one before.
    private(set) var cardHeight: CGFloat = 0
    private(set) var art: CGFloat = 0
    private(set) var before: CGFloat = 0
    /// Changes in a row, each made before a pass that changed nothing.
    private(set) var followUps = 0
    /// The card's height when the art was last held against what fits.
    private(set) var heldHeight: CGFloat?
    private var settled = true

    /// The art height to show in a card `cardHeight` tall now showing `current`, where `fitted`
    /// would fill it.
    mutating func decide(cardHeight height: CGFloat, current: CGFloat, fitted: CGFloat) -> CGFloat {
        var target = fitted
        if heldHeight != height { heldHeight = nil }
        if current == art {
            if !settled, cardHeight > 0, height != cardHeight {
                let moved = height - cardHeight, ours = art - before
                let exactly = abs(moved - ours) <= 1
                let likeOurs = moved * ours > 0 && abs(moved) <= abs(ours) + 1
                if exactly || (followUps > 0 && fitted < current && likeOurs) {
                    target = current
                    heldHeight = height
                }
            } else if settled, heldHeight == height {
                target = current
            }
        }
        guard target != current else {
            settled = true
            followUps = 0
            return current
        }
        if !settled { followUps += 1 }
        before = current
        art = target
        cardHeight = height
        heldHeight = nil
        settled = false
        return target
    }

    /// Something outside the card's height changed (the text size): size afresh.
    mutating func reset() { self = LaunchCardArtSizing() }
}

/// A hidden view in the card that puts the art back when UIKit sets the card's configuration
/// again (it rebuilds the card's content after we set it), and on the card's size and text size
/// changes; it labels the card's image view as the title on each pass.
@available(iOS 18.0, *)
final class LaunchCardArtKeeper: UIView {
    let title: String
    private(set) var sizing = LaunchCardArtSizing()
    private var observation: ConfigurationObservation?
    private weak var labelledImageView: UIImageView?
    private var applying = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (keeper: LaunchCardArtKeeper, _) in
            keeper.textSizeChanged()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        observation?.invalidate()
        observation = nil
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let card = superview as? UIContentUnavailableView else { return }
        frame = card.bounds
        // Not inside UIKit's own set (it may set the card again after us): on the next layout
        // pass. Our own sets need no pass.
        observation = ConfigurationObservation(card) { [weak self] in
            guard let self, !self.applying else { return }
            self.setNeedsLayout()
        }
    }

    /// Spans the card, so the card's size changes reach here.
    override func layoutSubviews() {
        super.layoutSubviews()
        reapply()
    }

    private func textSizeChanged() {
        sizing.reset()
        superview?.setNeedsLayout()
        setNeedsLayout()
        reapply()
    }

    func reapply() {
        guard !applying, let card = superview as? UIContentUnavailableView,
              let config = card.configuration as? UIContentUnavailableConfiguration else { return }
        applying = true
        defer { applying = false }
        let current = LaunchCardTitle.showsArt(config) ? config.imageProperties.maximumSize.height : 0
        let fitted = LaunchCardTitle.artSize(cardHeight: card.bounds.height,
                                             buttonHeight: LaunchCardTitle.buttonHeight(in: card),
                                             configuration: config)
        let height = sizing.decide(cardHeight: card.bounds.height, current: current, fitted: fitted?.height ?? 0)
        LaunchCardTitle.apply(LaunchCardTitle.size(forArtHeight: height), to: card, title: title)
        label(card)
    }

    /// The art reads as the title did: one "Lutik" heading, put back on every pass.
    private func label(_ card: UIContentUnavailableView) {
        let showsArt = (card.configuration as? UIContentUnavailableConfiguration).map(LaunchCardTitle.showsArt) ?? false
        let imageView = showsArt ? LaunchCardTitle.artImageView(in: card) : nil
        if let old = labelledImageView, old !== imageView {
            old.isAccessibilityElement = false
            old.accessibilityLabel = nil
            old.accessibilityTraits = .none
        }
        guard let imageView else { labelledImageView = nil; return }
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = title
        imageView.accessibilityTraits = [.header, .image]
        labelledImageView = imageView
    }
}

/// Key-value observation of a card's `configuration`, removed on `invalidate()` or when this goes
/// away. `object` is unowned: its keeper is the card's subview, so this never outlives the card,
/// and a weak reference would read nil while the card goes away, leaving the observer. (Swift's
/// `UIContentUnavailableView.configuration` is an overlay property with no KVC name, so
/// `observe(\.configuration)` cannot be used; the Objective-C property is observable.)
private final class ConfigurationObservation: NSObject {
    private nonisolated(unsafe) unowned(unsafe) let object: NSObject
    private nonisolated(unsafe) var removed = false
    private let onChange: @MainActor @Sendable () -> Void
    private nonisolated(unsafe) static let context = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    @MainActor
    init(_ object: NSObject, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.object = object
        self.onChange = onChange
        super.init()
        object.addObserver(self, forKeyPath: Self.keyPath, options: [.new], context: Self.context)
    }

    nonisolated func invalidate() {
        guard !removed else { return }
        removed = true
        object.removeObserver(self, forKeyPath: Self.keyPath, context: Self.context)
    }

    deinit { invalidate() }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        guard context == Self.context, keyPath == Self.keyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        let onChange = self.onChange
        MainActor.assumeIsolated { onChange() }
    }

    private static let keyPath = "configuration"
}
