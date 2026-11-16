import UIKit

/// The Lutik art on the stock iOS 18 launch view: lutik.io's hero (lutik_header.psd) as the
/// launch view's background, above the browser card, with New Archive at its bottom.
/// The art is decorative only; the button is a stock one.
@available(iOS 18.0, *)
@MainActor
enum LaunchHeader {
    /// Sets the stock background and the accessories of `options`: the art in the background one,
    /// a New Archive button running `newArchive` in the foreground one (none when nil).
    /// `onContentShown`: the art's `LaunchHeaderView.onContentShown`. `look` `.card`: the
    /// gradient alone behind the stock card (`LaunchHeaderView.showsFigures`).
    static func install(in options: UIDocumentViewController.LaunchOptions, look: LaunchLook = .art,
                        newArchive: UIAction? = nil, onContentShown: (() -> Void)? = nil) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = LaunchHeaderPalette.heroTop
        options.background = background
        let header = LaunchHeaderView()
        header.showsFigures = look == .art
        header.onContentShown = onContentShown
        options.backgroundAccessoryView = header
        if let newArchive {
            let button = LaunchNewArchiveView(action: newArchive)
            header.newArchiveView = button
            options.foregroundAccessoryView = button
        }
    }
}

/// The foreground accessory: a stock filled New Archive button, centred just above the browser
/// card (the accessory's bottom layout margin follows the card's top). Only the button takes
/// touches; hidden when the stock view leaves no room for it (iPhone landscape).
@available(iOS 18.0, *)
final class LaunchNewArchiveView: UIView {
    static let identifier = "LaunchNewArchive"
    let button: UIButton

    init(action: UIAction) {
        var config = UIButton.Configuration.borderedProminent()
        config.buttonSize = .large
        config.cornerStyle = .capsule
        button = UIButton(configuration: config, primaryAction: action)
        button.accessibilityIdentifier = Self.identifier
        button.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor,
                                           constant: -LaunchHeaderBand.buttonGap),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            button.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the button fits in a view of `height` with `bottomMargin` and `safeTop`: room for the
    /// gap above the card and the button itself. The one rule behind the button's `isHidden` and the
    /// art's room, so neither depends on the other's layout pass.
    static func fits(height: CGFloat, bottomMargin: CGFloat, safeTop: CGFloat, buttonHeight: CGFloat) -> Bool {
        height - bottomMargin - safeTop >= LaunchHeaderBand.buttonGap + buttonHeight
    }

    /// The button's height, or 0 when it does not fit a view of the given geometry (the art's own).
    func buttonHeight(height: CGFloat, bottomMargin: CGFloat, safeTop: CGFloat) -> CGFloat {
        let natural = button.intrinsicContentSize.height
        return Self.fits(height: height, bottomMargin: bottomMargin, safeTop: safeTop, buttonHeight: natural)
            ? natural : 0
    }

    /// The button's height, or 0 while it is hidden.
    var buttonHeight: CGFloat { button.isHidden ? 0 : button.intrinsicContentSize.height }

    override func layoutMarginsDidChange() {
        super.layoutMarginsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        button.isHidden = buttonHeight(height: bounds.height, bottomMargin: layoutMargins.bottom,
                                       safeTop: safeAreaInsets.top) == 0
        super.layoutSubviews()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// lutik.io's header gradient (site.css `.lutik`), light and dark. The light one is drawn in
/// oklab on the site; from 49 % on its stops carry their oklab quarter points here.
enum LaunchHeaderPalette {
    struct Stop: Equatable {
        let location: CGFloat
        let red: CGFloat, green: CGFloat, blue: CGFloat
    }

    /// `--hero-top`: what the gradient ends in and what the launch view shows below it.
    static let heroTop = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)
            : UIColor(red: 214 / 255, green: 228 / 255, blue: 242 / 255, alpha: 1)
    }

    private static let pink: [Stop] = [
        Stop(location: 0.00, red: 255, green: 0, blue: 177),
        Stop(location: 0.10, red: 255, green: 0, blue: 194),
        Stop(location: 0.20, red: 255, green: 0, blue: 215),
        Stop(location: 0.29, red: 255, green: 0, blue: 234),
        Stop(location: 0.37, red: 255, green: 0, blue: 244),
        Stop(location: 0.43, red: 255, green: 0, blue: 246),
        Stop(location: 0.49, red: 249, green: 0, blue: 243),
    ]

    static let light: [Stop] = pink + [
        Stop(location: 0.5175, red: 248, green: 44, blue: 242),
        Stop(location: 0.5450, red: 247, green: 64, blue: 241),
        Stop(location: 0.5725, red: 245, green: 79, blue: 239),
        Stop(location: 0.6000, red: 244, green: 92, blue: 238),
        Stop(location: 0.6400, red: 242, green: 114, blue: 239),
        Stop(location: 0.6800, red: 239, green: 134, blue: 239),
        Stop(location: 0.7200, red: 236, green: 151, blue: 240),
        Stop(location: 0.7600, red: 232, green: 168, blue: 240),
        Stop(location: 0.8200, red: 229, green: 184, blue: 241),
        Stop(location: 0.8800, red: 225, green: 199, blue: 241),
        Stop(location: 0.9400, red: 220, green: 213, blue: 242),
        Stop(location: 1.0000, red: 214, green: 228, blue: 242),
    ]

    static let dark: [Stop] = pink + [
        Stop(location: 0.55, red: 210, green: 0, blue: 211),
        Stop(location: 0.61, red: 161, green: 0, blue: 164),
        Stop(location: 0.67, red: 116, green: 0, blue: 120),
        Stop(location: 0.73, red: 92, green: 3, blue: 97),
        Stop(location: 0.78, red: 74, green: 8, blue: 79),
        Stop(location: 0.84, red: 59, green: 15, blue: 62),
        Stop(location: 0.90, red: 45, green: 21, blue: 48),
        Stop(location: 0.96, red: 35, green: 26, blue: 37),
        Stop(location: 1.00, red: 29, green: 29, blue: 31),
    ]

    /// The gradient's top colour, the brand magenta (the card look's wordmark, `LaunchCardTitle`).
    static let brand: UIColor = {
        let top = pink[0]
        return UIColor(red: top.red / 255, green: top.green / 255, blue: top.blue / 255, alpha: 1)
    }()

    static func stops(for style: UIUserInterfaceStyle) -> [Stop] {
        style == .dark ? dark : light
    }
}

/// Where the art goes in the room above the New Archive button: site.css's `.lutik-stage` in
/// points, cropped to the art's own rows (the wordmark's top to the dog's shadow) and as large as
/// the room allows, never squashed. Every PSD number is in PSD pixels; `k` turns one PSD pixel
/// into points for the dog and the layout, `ki` for the icons. Icons keep their design distance
/// to the dog and only ever move closer (`b`); where that would pile them up they get smaller,
/// and then the outer ones go (`maxRing`), so no two overlap.
struct LaunchHeaderLayout: Equatable {
    struct Icon: Equatable {
        /// Asset name suffix: `LaunchIcon-<name>`.
        let name: String
        /// -1 left of the dog, 1 right.
        let side: CGFloat
        /// PSD distance past the innermost icon of its side (`--d`).
        let distance: CGFloat
        /// PSD row of the icon's centre (`--y`).
        let row: CGFloat
        let width: CGFloat
        let height: CGFloat
        /// 0 = the innermost pair (bz2, zip) … 5 = the outermost (rar, vsix): the launch order.
        let ring: Int

        var assetName: String { "LaunchIcon-\(name)" }
    }

    /// Left to right, as in the PSD and on the site.
    static let icons: [Icon] = [
        Icon(name: "rar", side: -1, distance: 5046, row: 2360, width: 943, height: 935, ring: 5),
        Icon(name: "jar", side: -1, distance: 3802, row: 2359, width: 990, height: 1002, ring: 4),
        Icon(name: "gz", side: -1, distance: 2519, row: 2367, width: 1019, height: 1018, ring: 3),
        Icon(name: "apk", side: -1, distance: 1248, row: 2126, width: 968, height: 947, ring: 2),
        Icon(name: "whl", side: -1, distance: 964, row: 3120, width: 943, height: 941, ring: 1),
        Icon(name: "bz2", side: -1, distance: 18, row: 2418, width: 948, height: 943, ring: 0),
        Icon(name: "zip", side: 1, distance: 0, row: 2579, width: 965, height: 962, ring: 0),
        Icon(name: "xpi", side: 1, distance: 966, row: 3244, width: 1001, height: 970, ring: 1),
        Icon(name: "cab", side: 1, distance: 1227, row: 2169, width: 933, height: 956, ring: 2),
        Icon(name: "iso", side: 1, distance: 2288, row: 2647, width: 948, height: 944, ring: 3),
        Icon(name: "nupkg", side: 1, distance: 3514, row: 2285, width: 947, height: 948, ring: 4),
        Icon(name: "vsix", side: 1, distance: 4753, row: 2537, width: 975, height: 964, ring: 5),
    ]

    static let markAssetName = "LaunchMark"
    /// The first PSD row shown: the wordmark's top.
    static let topRow: CGFloat = 880
    /// PSD rows shown, down to the dog's shadow.
    static let stageRows: CGFloat = 3540
    /// The dog's middle: where the icons fly out from.
    static let flyRow: CGFloat = 3000
    /// PSD distance from the centre to the innermost icon (the design gap).
    static let innerGap: CGFloat = 1582
    /// Points kept free at the left and right edges.
    static let edgeMargin: CGFloat = 14
    /// The icons' size, relative to the dog's, where they don't fit at their own.
    static let smallIconScale: CGFloat = 0.75
    /// Of an icon's size: its transparent edge and rounded corners, which may touch another's.
    static let iconInset: CGFloat = 0.08

    let width: CGFloat
    /// Points per PSD pixel: dog, wordmark and positions.
    let k: CGFloat
    /// Points per PSD pixel: icon size.
    let ki: CGFloat
    /// Points per PSD pixel between the innermost and the outermost icon (squeezed to fit).
    let b: CGFloat
    /// The outermost ring shown.
    let maxRing: Int

    /// - Parameters: width, height: the room for the art; it fills the height unless the
    ///   innermost icons would leave the width.
    init(width: CGFloat, height: CGFloat) {
        self.width = width
        let half = max(0, width / 2 - Self.edgeMargin)
        let k = min(max(0, height) / Self.stageRows, half / (Self.innerGap + 520))
        self.k = k
        var chosen: (ki: CGFloat, b: CGFloat, ring: Int)?
        search: for ring in [5, 3, 2, 1] {
            for scale in [1, Self.smallIconScale] {
                let ki = k * scale
                let b = Self.squeeze(half: half, k: k, ki: ki, maxRing: ring)
                if !Self.overlap(k: k, ki: ki, b: b, maxRing: ring) {
                    chosen = (ki, b, ring)
                    break search
                }
            }
        }
        let fallback = (ki: k * Self.smallIconScale, ring: 0)
        let pick = chosen ?? (fallback.ki, Self.squeeze(half: half, k: k, ki: fallback.ki, maxRing: 0), 0)
        ki = pick.ki
        b = pick.b
        maxRing = pick.ring
    }

    /// The largest `b` up to `k` that keeps every icon up to `maxRing` inside `half` of the middle.
    private static func squeeze(half: CGFloat, k: CGFloat, ki: CGFloat, maxRing: Int) -> CGFloat {
        var b = k
        for icon in icons where icon.ring <= maxRing && icon.distance > 0 {
            b = min(b, (half - innerGap * k - icon.width * ki / 2) / icon.distance)
        }
        return max(0, b)
    }

    /// Two icons up to `maxRing` on one side overlap (past their transparent edges).
    private static func overlap(k: CGFloat, ki: CGFloat, b: CGFloat, maxRing: Int) -> Bool {
        let shown = icons.filter { $0.ring <= maxRing }
        for (index, one) in shown.enumerated() {
            for other in shown[(index + 1)...] where other.side == one.side {
                let dx = abs(one.distance - other.distance) * b
                let dy = abs(one.row - other.row) * k
                let reach = (1 - 2 * iconInset) * ki / 2
                if dx < (one.width + other.width) * reach, dy < (one.height + other.height) * reach { return true }
            }
        }
        return false
    }

    var height: CGFloat { Self.stageRows * k }

    var visibleIcons: [Icon] { Self.icons.filter { $0.ring <= maxRing } }

    /// The wordmark, the dog and its shadow (`.lutik-mark`, 2890 x 3390 PSD pixels from row 958).
    var markFrame: CGRect {
        CGRect(x: width / 2 + 20 * k - 1445 * k, y: (958 - Self.topRow) * k,
               width: 2890 * k, height: 3390 * k)
    }

    /// The dog without the wordmark and the shadow (measured on `LaunchMark`): no icon goes there.
    var dogFrame: CGRect {
        CGRect(x: width / 2 - 850 * k, y: (2210 - Self.topRow) * k, width: 1670 * k, height: 1660 * k)
    }

    /// The icon centre's horizontal offset from the middle (`--px`).
    func centreOffset(of icon: Icon) -> CGFloat {
        icon.side * (Self.innerGap * k + icon.distance * b)
    }

    func frame(of icon: Icon) -> CGRect {
        let size = CGSize(width: icon.width * ki, height: icon.height * ki)
        return CGRect(x: width / 2 + centreOffset(of: icon) - size.width / 2,
                      y: (icon.row - Self.topRow) * k - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Where an icon starts its flight, relative to where it lands: the dog's middle.
    func flightStart(of icon: Icon) -> CGVector {
        CGVector(dx: -centreOffset(of: icon), dy: (Self.flyRow - icon.row) * k)
    }
}

/// The art's room on the stock launch view: from the bars down to the New Archive button, which
/// sits just above the browser card. The accessory's bottom layout margin follows the card's top.
enum LaunchHeaderBand {
    /// Below this the art is not shown.
    static let minHeight: CGFloat = 60
    /// Between the button's bottom and the card, and between the art and the button.
    static let buttonGap: CGFloat = 20
    static let artGap: CGFloat = 16

    /// The art's height below `safeTop`; 0 when there is no room. `buttonHeight`: 0 without one.
    static func height(safeTop: CGFloat, guideBottom: CGFloat, buttonHeight: CGFloat) -> CGFloat {
        let reserved = buttonHeight > 0 ? buttonGap + buttonHeight + artGap : 0
        return max(0, guideBottom - reserved - safeTop)
    }

    static func showsArt(height: CGFloat) -> Bool { height >= minHeight }
}
/// When the intro starts. The stock launch view lays out its accessory, and the scene turns
/// active, seconds before the user sees it: until the browser is ready its content stays
/// transparent. So the intro waits until the view is shown in an active scene with nothing
/// presented over it (the Welcome sheet: the intro plays right after Continue); at that moment it plays, or is
/// skipped for good when there is no room for the art (iPhone landscape), so it never plays at a later rotation.
enum LaunchHeaderIntroGate {
    enum Step: Equatable { case wait, play, skip }

    static func step(visible: Bool, active: Bool, covered: Bool, showsArt: Bool) -> Step {
        guard visible, active, !covered else { return .wait }
        return showsArt ? .play : .skip
    }

    /// Something is presented over the window's root and `view` isn't in it: the top of the
    /// root's presented chain.
    @MainActor
    static func isCovered(_ view: UIView) -> Bool {
        guard let root = view.window?.rootViewController else { return false }
        var top = root
        while let next = top.presentedViewController { top = next }
        return top !== root && !view.isDescendant(of: top.view)
    }

    /// In a shown window, with no hidden or transparent view on the way up.
    @MainActor
    static func isShown(_ view: UIView) -> Bool {
        guard view.window != nil, view.bounds.width > 0 else { return false }
        var current: UIView? = view
        while let next = current {
            if next.isHidden || next.alpha < 0.01 { return false }
            current = next.superview
        }
        return true
    }
}

/// The background accessory: the gradient band and the art on it. Plays lutik.io's intro once per
/// view, the first time it is shown (`LaunchHeaderIntroGate`); never with Reduce Motion. Reports
/// that moment once (`onContentShown`), intro or not.
@available(iOS 18.0, *)
final class LaunchHeaderView: UIView {
    let gradientLayer = CAGradientLayer()
    let markView = UIImageView()
    /// One per `LaunchHeaderLayout.icons`, same order.
    let iconViews: [UIImageView]
    /// Injected by tests.
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    /// Injected by tests.
    lazy var sceneIsActive: () -> Bool = { [weak self] in
        self?.window?.windowScene?.activationState == .foregroundActive
    }
    /// Injected by tests.
    lazy var isCovered: () -> Bool = { [weak self] in
        guard let self else { return false }
        return LaunchHeaderIntroGate.isCovered(self)
    }
    /// Injected by tests.
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    private(set) var hasPlayedIntro = false
    private var introPending = false

    /// Called once per view, the first time the launch view is shown in an active scene, with or
    /// without the intro (Reduce Motion, no room): `SceneDelegate`'s Welcome sheet comes up then.
    /// The intro decides at the watch's next check, so a sheet presented here holds it back.
    var onContentShown: (() -> Void)? {
        didSet {
            guard awaitsContentShown, window != nil else { return }
            setNeedsLayout()
            startIntroWatch()
        }
    }
    private var hasReportedContentShown = false
    private var awaitsContentShown: Bool { onContentShown != nil && !hasReportedContentShown }
    /// The intro or the content-shown report still waits for the view to be shown.
    private var isWaiting: Bool { introPending || awaitsContentShown }
    /// While the intro waits: the stock view shows its content without laying out the accessory.
    private(set) var introWatch: CADisplayLink?
    private var introWatchEnd: CFTimeInterval = 0
    private(set) var currentLayout: LaunchHeaderLayout?

    static let introKey = "lutik-intro"

    override init(frame: CGRect) {
        iconViews = LaunchHeaderLayout.icons.map { UIImageView(image: UIImage(named: $0.assetName)) }
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.addSublayer(gradientLayer)
        for icon in iconViews { addSubview(icon) }
        markView.image = UIImage(named: LaunchHeaderLayout.markAssetName)
        addSubview(markView)
        for view in [markView] + iconViews {
            view.contentMode = .scaleAspectFit
            view.isAccessibilityElement = false
        }
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: LaunchHeaderView, _) in
            view.updateColors()
        }
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]) { (view: LaunchHeaderView, _) in
            view.setNeedsLayout()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(checkAgain(_:)),
                                               name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkAgain(_:)),
                                               name: WelcomeSheet.didDismissNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The New Archive button below the art (the foreground accessory): the art ends above it.
    weak var newArchiveView: LaunchNewArchiveView?
    /// The stage's top: in the room between the bars and the New Archive button (`LaunchHeaderBand`).
    private(set) var stageTop: CGFloat = 0
    /// False when the room is too low for the art (then neither art nor gradient shows).
    private(set) var showsArt = true
    /// False under the stock title card (`LaunchLook.card`), which covers the room: the gradient
    /// alone, no wordmark, dog or icons, and no intro. Set before the view is shown.
    var showsFigures = true {
        didSet { setNeedsLayout() }
    }

    /// The bottom margin follows the browser card, and settles after the stock animation.
    override func layoutMarginsDidChange() {
        super.layoutMarginsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safeTop = safeAreaInsets.top
        let guideBottom = max(0, bounds.height - layoutMargins.bottom)
        let band = LaunchHeaderBand.height(safeTop: safeTop, guideBottom: guideBottom,
                                           buttonHeight: newArchiveView?.buttonHeight(
                                            height: bounds.height, bottomMargin: layoutMargins.bottom,
                                            safeTop: safeTop) ?? 0)
        let layout = LaunchHeaderLayout(width: bounds.width, height: band)
        currentLayout = layout
        showsArt = LaunchHeaderBand.showsArt(height: band)
        stageTop = safeTop + max(0, band - layout.height) / 2
        let top = stageTop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Down to the browser card's top.
        gradientLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: guideBottom)
        gradientLayer.isHidden = !showsArt
        CATransaction.commit()
        markView.isHidden = !showsArt || !showsFigures
        place(markView, in: layout.markFrame.offsetBy(dx: 0, dy: top))
        for (icon, view) in zip(LaunchHeaderLayout.icons, iconViews) {
            let visible = layout.visibleIcons.contains(icon)
            view.isHidden = !visible || !showsArt || !showsFigures
            place(view, in: layout.frame(of: icon).offsetBy(dx: 0, dy: top))
        }
        guard isWaiting else { return }
        let visible = LaunchHeaderIntroGate.isShown(self), active = sceneIsActive()
        if visible, active, awaitsContentShown {
            hasReportedContentShown = true
            // Not inside this layout pass: the callback presents the Welcome sheet.
            DispatchQueue.main.async { [weak self] in self?.onContentShown?() }
            // What it presents may not be in the chain yet: the intro decides at the next check.
            if introPending { return startIntroWatch() }
        }
        if introPending {
            switch LaunchHeaderIntroGate.step(visible: visible, active: active, covered: isCovered(),
                                              showsArt: showsArt && showsFigures) {
            case .wait:
                // The watch may have run out (a slow cold launch, the scene in the background,
                // a sheet up for long).
                if introWatch == nil, window != nil { startIntroWatch() }
                return
            case .play: playIntro(with: layout)
            case .skip: break
            }
            introPending = false
        }
        if !isWaiting { stopIntroWatch() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return stopIntroWatch() }
        if !hasPlayedIntro {
            hasPlayedIntro = true
            // Under the card (no figures) there is no intro to wait for.
            introPending = !reduceMotion() && showsFigures
        }
        guard isWaiting else { return }
        setNeedsLayout()
        startIntroWatch()
    }

    /// The header's scene turned active, or the Welcome sheet over it was dismissed: check again.
    @objc private func checkAgain(_ notification: Notification) {
        guard isWaiting, let scene = window?.windowScene, notification.object as? UIScene === scene else { return }
        setNeedsLayout()
        startIntroWatch()
    }

    /// Checks often, for a few seconds, whether the waiting intro can start. Restarting
    /// extends the running watch; there is never more than one.
    private func startIntroWatch() {
        introWatchEnd = clock() + 10
        guard introWatch == nil else { return }
        let link = CADisplayLink(target: IntroWatchTarget(self), selector: #selector(IntroWatchTarget.tick(_:)))
        // A few checks a second are enough; keeps ProMotion displays from staying at 120 Hz.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
        link.add(to: .main, forMode: .common)
        introWatch = link
    }

    private func stopIntroWatch() {
        introWatch?.invalidate()
        introWatch = nil
    }

    /// The watch's check; called by its display link (and by tests).
    func introWatchTick() {
        guard isWaiting, clock() < introWatchEnd else { return stopIntroWatch() }
        guard LaunchHeaderIntroGate.isShown(self), sceneIsActive() else { return }
        if awaitsContentShown || !isCovered() { setNeedsLayout() }
    }

    private func place(_ view: UIView, in frame: CGRect) {
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    private func updateColors() {
        let stops = LaunchHeaderPalette.stops(for: traitCollection.userInterfaceStyle)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = stops.map {
            UIColor(red: $0.red / 255, green: $0.green / 255, blue: $0.blue / 255, alpha: 1).cgColor
        }
        gradientLayer.locations = stops.map { NSNumber(value: Double($0.location)) }
        CATransaction.commit()
    }

    // MARK: Intro (site.css `lutik-in` and `lutik-fly`)

    private func playIntro(with layout: LaunchHeaderLayout) {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)

        let mark = CAAnimationGroup()
        mark.animations = [
            Self.basic("opacity", from: 0, to: 1),
            Self.basic("transform.translation.y", from: 12, to: 0),
            Self.basic("transform.scale", from: 0.94, to: 1),
        ]
        mark.duration = 0.7
        mark.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)
        mark.beginTime = now
        mark.fillMode = .backwards
        markView.layer.add(mark, forKey: Self.introKey)

        let ease = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        for (icon, view) in zip(LaunchHeaderLayout.icons, iconViews) where !view.isHidden {
            let start = layout.flightStart(of: icon)
            let degrees = CGFloat.pi / 180
            let motion: [(String, [CGFloat])] = [
                ("transform.translation.x", [start.dx, 0, 0]),
                ("transform.translation.y", [start.dy, 0, 0]),
                ("transform.scale", [0.3, 1.05, 1]),
                ("transform.rotation.z", [icon.side * -150 * degrees, icon.side * 7 * degrees, 0]),
            ]
            var parts: [CAAnimation] = motion.map { keyPath, values in
                Self.keyframes(keyPath, values: values, at: [0, 0.78, 1], ease: ease)
            }
            parts.append(Self.keyframes("opacity", values: [0, 1, 1], at: [0, 0.35, 1], ease: ease))
            let fly = CAAnimationGroup()
            fly.animations = parts
            fly.duration = 1.15
            fly.beginTime = now + 0.3 + Double(icon.ring) * 0.07
            fly.fillMode = .backwards
            view.layer.add(fly, forKey: Self.introKey)
        }
    }

    private static func basic(_ keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.fillMode = .both
        return animation
    }

    private static func keyframes(_ keyPath: String, values: [CGFloat], at times: [NSNumber],
                                  ease: CAMediaTimingFunction) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        // CSS eases each stretch between two keyframes, not the whole run.
        animation.timingFunctions = Array(repeating: ease, count: values.count - 1)
        animation.duration = 1.15
        animation.fillMode = .both
        return animation
    }
}

/// The intro watch's display link target; holds the view weakly (a display link retains its target).
@available(iOS 18.0, *)
@MainActor
private final class IntroWatchTarget: NSObject {
    weak var view: LaunchHeaderView?
    init(_ view: LaunchHeaderView) { self.view = view }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.introWatchTick()
    }
}
