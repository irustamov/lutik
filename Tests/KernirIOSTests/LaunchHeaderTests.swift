import Testing
import UIKit
@testable import Kernir

/// The Lutik header art on the iOS 18 launch view: what `LaunchHeader.install` sets, where the
/// art goes at each width, and the once-only intro (none with Reduce Motion).
@MainActor
@Suite struct LaunchHeaderTests {
    @Test(arguments: [false, true])
    func installSetsTheStockAccessories(withNewArchive: Bool) throws {
        guard #available(iOS 18.0, *) else { return }
        let options = UIDocumentViewController().launchOptions
        var shown = 0, created = 0
        let newArchive = withNewArchive ? UIAction(title: "New Archive") { _ in created += 1 } : nil
        LaunchHeader.install(in: options, newArchive: newArchive) { shown += 1 }
        let header = try #require(options.backgroundAccessoryView as? LaunchHeaderView)
        #expect(header.showsFigures)
        header.onContentShown?()
        #expect(shown == 1, "the content-shown callback isn't the header's")
        if withNewArchive {
            let accessory = try #require(options.foregroundAccessoryView as? LaunchNewArchiveView)
            #expect(header.newArchiveView === accessory)
            #expect(accessory.button.accessibilityIdentifier == LaunchNewArchiveView.identifier)
            accessory.button.sendActions(for: .primaryActionTriggered)
            #expect(created == 1, "the button doesn't run the action")
        } else {
            #expect(options.foregroundAccessoryView == nil)
            #expect(header.newArchiveView == nil)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            #expect(options.background.backgroundColor?.resolvedColor(with: traits)
                == LaunchHeaderPalette.heroTop.resolvedColor(with: traits))
        }
        #expect(header.isAccessibilityElement == false)
        #expect(header.accessibilityElementsHidden)
        #expect(header.isUserInteractionEnabled == false)
        #expect(header.markView.image != nil)
        #expect(header.iconViews.count == 12)
        #expect(header.iconViews.allSatisfy { $0.image != nil })
    }

    /// The New Archive accessory spans the launch view: only its button takes touches, and the
    /// button goes when the card leaves it no room (iPhone landscape).
    @Test func newArchiveSitsAboveTheCardAndPassesOtherTouches() throws {
        guard #available(iOS 18.0, *) else { return }
        let view = LaunchNewArchiveView(action: UIAction(title: "New Archive") { _ in })
        view.frame = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        view.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 750, right: 0)
        view.layoutIfNeeded()
        #expect(!view.button.isHidden)
        #expect(view.buttonHeight > 0)
        #expect(abs(view.button.frame.maxY - (1376 - 750 - LaunchHeaderBand.buttonGap)) < 0.5)
        #expect(abs(view.button.frame.midX - 516) < 0.5)
        #expect(view.hitTest(CGPoint(x: 20, y: 20), with: nil) == nil)
        #expect(view.hitTest(CGPoint(x: view.button.frame.midX, y: view.button.frame.midY), with: nil)?
            .isDescendant(of: view.button) == true)
        view.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 1376, right: 0)
        view.layoutIfNeeded()
        #expect(view.button.isHidden)
        #expect(view.buttonHeight == 0)
    }

    /// The button's fit rule is one pure function, used by the button and by the art's layout, so
    /// neither reads the other's layout state.
    @Test func newArchiveFitRuleNeedsTheGapAndTheButton() throws {
        guard #available(iOS 18.0, *) else { return }
        // Room = height - bottomMargin - safeTop; it must hold the gap and the button.
        let needed = LaunchHeaderBand.buttonGap + 50
        #expect(LaunchNewArchiveView.fits(height: 1376, bottomMargin: 750, safeTop: 24, buttonHeight: 50))
        #expect(LaunchNewArchiveView.fits(height: needed, bottomMargin: 0, safeTop: 0, buttonHeight: 50))
        #expect(!LaunchNewArchiveView.fits(height: needed - 1, bottomMargin: 0, safeTop: 0, buttonHeight: 50))
        // iPhone landscape: the card takes the height.
        #expect(!LaunchNewArchiveView.fits(height: 393, bottomMargin: 360, safeTop: 0, buttonHeight: 50))
        #expect(!LaunchNewArchiveView.fits(height: 1376, bottomMargin: 1376, safeTop: 24, buttonHeight: 50))
    }

    /// Room sizes measured on iOS 27.2 simulators (pt): iPad Pro 13 portrait and landscape,
    /// iPhone portrait, iPad mini portrait, a narrow iPhone, an iPad split.
    nonisolated static let rooms: [(width: Double, height: Double)] = [
        (1032, 460), (1376, 260), (402, 190), (744, 520), (320, 150), (507, 300), (1032, 2000), (390, 640),
    ]

    /// The art fills the room's height (or, where the innermost icons would leave the screen, its
    /// width), never squashed: the mark keeps the PSD's aspect.
    @Test(arguments: LaunchHeaderTests.rooms)
    func artFillsTheRoomAndKeepsItsAspect(width: Double, height: Double) {
        let layout = LaunchHeaderLayout(width: width, height: height)
        #expect(layout.height <= height + 0.001)
        let half = width / 2 - LaunchHeaderLayout.edgeMargin
        let fillsHeight = abs(layout.height - height) < 0.001
        let fillsWidth = abs(layout.k * (LaunchHeaderLayout.innerGap + 520) - half) < 0.001
        #expect(fillsHeight || fillsWidth)
        #expect(abs(layout.markFrame.width / layout.markFrame.height - 2890.0 / 3390) < 0.0001)
        #expect(layout.ki <= layout.k + 0.0001)
        #expect(layout.ki >= layout.k * LaunchHeaderLayout.smallIconScale - 0.0001)
    }

    /// No icon overlaps another (past their transparent edges) or the dog; the outer ones go
    /// first when they would pile up.
    @Test(arguments: LaunchHeaderTests.rooms)
    func noIconOverlapsAnotherOrTheDog(width: Double, height: Double) {
        let layout = LaunchHeaderLayout(width: width, height: height)
        let icons = layout.visibleIcons
        #expect(icons.allSatisfy { $0.ring <= layout.maxRing })
        #expect(icons.count == 2 * (layout.maxRing + 1))
        let inset = LaunchHeaderLayout.iconInset
        let frames = icons.map { icon in
            let frame = layout.frame(of: icon)
            return frame.insetBy(dx: frame.width * inset, dy: frame.height * inset)
        }
        for (index, one) in frames.enumerated() {
            #expect(!one.intersects(layout.dogFrame), "\(icons[index].name) on the dog")
            for (other, frame) in zip(icons[(index + 1)...], frames[(index + 1)...]) {
                let shared = one.intersection(frame)
                #expect(shared.isNull || shared.width < 0.5 || shared.height < 0.5,
                        "\(icons[index].name) over \(other.name)")
            }
        }
    }

    /// The measured rooms keep the design's icons: all twelve on the iPad, more than the
    /// innermost pair on the iPhone.
    @Test func roomsKeepTheirIcons() {
        #expect(LaunchHeaderLayout(width: 1376, height: 260).maxRing == 5)
        #expect(LaunchHeaderLayout(width: 1032, height: 460).maxRing >= 3)
        #expect(LaunchHeaderLayout(width: 402, height: 190).maxRing >= 1)
    }

    /// The art's room: from the bars to the button above the card.
    @Test func roomEndsAboveTheButton() {
        let room = LaunchHeaderBand.height(safeTop: 74, guideBottom: 626, buttonHeight: 50)
        #expect(abs(room - (626 - 74 - LaunchHeaderBand.buttonGap - 50 - LaunchHeaderBand.artGap)) < 0.001)
        #expect(LaunchHeaderBand.height(safeTop: 74, guideBottom: 626, buttonHeight: 0) == 552)
    }

    @Test func noArtBelowSixtyPoints() {
        #expect(LaunchHeaderBand.showsArt(height: 60))
        #expect(!LaunchHeaderBand.showsArt(height: 59.9))
        // iPhone landscape: the stock view gives the accessory no room.
        #expect(LaunchHeaderBand.height(safeTop: 0, guideBottom: 0, buttonHeight: 0) == 0)
        #expect(LaunchHeaderBand.height(safeTop: 32, guideBottom: 40, buttonHeight: 50) == 0)
    }

    @Test func lowHeaderShowsNoArt() throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 390, height: 60, reduceMotion: false)
        defer { window.isHidden = true }
        #expect(!header.showsArt)
        #expect(header.gradientLayer.isHidden)
        for view in [header.markView] + header.iconViews {
            #expect(view.isHidden)
            #expect(view.layer.animationKeys() == nil)
        }
    }

    /// No room on the first layout (iPhone landscape): the intro is skipped, not played when room
    /// comes later (a rotation).
    @Test func noIntroWhenRoomComesLater() throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 390, height: 60, reduceMotion: false)
        defer { window.isHidden = true }
        #expect(!header.showsArt)
        header.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        header.setNeedsLayout()
        header.layoutIfNeeded()
        #expect(header.showsArt)
        for view in [header.markView] + header.iconViews {
            #expect(view.layer.animationKeys() == nil)
        }
    }

    /// The stock launch view keeps its content transparent until the browser is ready (seconds
    /// after the first layout on a cold launch), and shows it without laying out the accessory:
    /// the intro watch's next check sees it, and the intro plays.
    @Test func introWaitsUntilTheLaunchViewIsShown() throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: false, contentAlpha: 0)
        defer { window.isHidden = true }
        #expect(header.showsArt)
        #expect(header.introWatch != nil)
        for view in [header.markView] + header.iconViews {
            #expect(view.layer.animationKeys() == nil)
        }
        let content = try #require(header.superview)
        content.alpha = 1
        header.layoutIfNeeded()
        #expect(header.markView.layer.animationKeys() == nil, "showing the content alone lays out nothing")
        header.introWatchTick()
        header.layoutIfNeeded()
        #expect(header.introWatch == nil)
        #expect(header.markView.layer.animation(forKey: LaunchHeaderView.introKey) != nil)
        for view in header.iconViews where !view.isHidden {
            #expect(view.layer.animation(forKey: LaunchHeaderView.introKey) != nil)
        }
    }

    /// Not before the scene is active (the launch is still on the system's snapshot).
    @Test func introWaitsForTheActiveScene() throws {
        guard #available(iOS 18.0, *) else { return }
        var active = false
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: false, sceneActive: { active })
        defer { window.isHidden = true }
        #expect(header.markView.layer.animationKeys() == nil)
        active = true
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: window.windowScene)
        header.layoutIfNeeded()
        #expect(header.markView.layer.animation(forKey: LaunchHeaderView.introKey) != nil)
    }

    /// Another scene's activation (here: no scene) neither lays out nor starts the intro.
    @Test func introIgnoresOtherScenesActivation() throws {
        guard #available(iOS 18.0, *) else { return }
        var active = false
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: false, sceneActive: { active })
        defer { window.isHidden = true }
        active = true
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: nil)
        header.layoutIfNeeded()
        #expect(header.markView.layer.animationKeys() == nil)
        #expect(header.introWatch != nil, "still waiting")
    }

    /// The watch runs out after a few seconds (a slow cold launch, the scene in the background):
    /// the next activation of the header's scene, or the next layout that still waits, starts it
    /// again; never a second one.
    @Test func introWatchRestartsAfterRunningOut() throws {
        guard #available(iOS 18.0, *) else { return }
        var active = false
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: false, sceneActive: { active })
        defer { window.isHidden = true }
        let firstWatch = try #require(header.introWatch)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: window.windowScene)
        #expect(header.introWatch === firstWatch)
        header.layoutIfNeeded()
        #expect(header.introWatch === firstWatch)

        let start = CACurrentMediaTime()
        header.clock = { start + 11 }
        header.introWatchTick()
        #expect(header.introWatch == nil)
        header.setNeedsLayout()
        header.layoutIfNeeded()
        #expect(header.introWatch != nil, "a waiting layout restarts it")

        header.clock = { start + 22 }
        header.introWatchTick()
        #expect(header.introWatch == nil)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: window.windowScene)
        let restarted = try #require(header.introWatch, "the scene's activation restarts it")
        active = true
        header.introWatchTick()
        #expect(header.introWatch === restarted)
        header.layoutIfNeeded()
        #expect(header.markView.layer.animation(forKey: LaunchHeaderView.introKey) != nil)
        #expect(header.introWatch == nil)
    }

    /// The first moment the launch view is shown decides: a hidden launch view with no room yet
    /// does not skip the intro, a shown one does.
    @Test func introGate() {
        typealias Gate = LaunchHeaderIntroGate
        #expect(Gate.step(visible: false, active: true, covered: false, showsArt: false) == .wait)
        #expect(Gate.step(visible: true, active: false, covered: false, showsArt: true) == .wait)
        #expect(Gate.step(visible: true, active: true, covered: true, showsArt: true) == .wait)
        #expect(Gate.step(visible: true, active: true, covered: true, showsArt: false) == .wait)
        #expect(Gate.step(visible: true, active: true, covered: false, showsArt: true) == .play)
        #expect(Gate.step(visible: true, active: true, covered: false, showsArt: false) == .skip)
    }

    /// The Welcome sheet over the launch view: the intro
    /// waits while anything is presented over the window's root, and plays right after the sheet
    /// is dismissed (`WelcomeSheet.didDismissNotification` restarts a watch that ran out).
    @Test(.timeLimit(.minutes(1))) func introWaitsUnderAPresentedSheetAndPlaysAfterItsDismissal() async throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: false, contentAlpha: 0)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        // A dismissal while the presentation is still in progress is dropped: wait for both.
        await withCheckedContinuation { done in root.present(UIViewController(), animated: false) { done.resume() } }
        try #require(root.presentedViewController != nil)
        try #require(header.superview).alpha = 1
        header.introWatchTick()
        header.setNeedsLayout()
        header.layoutIfNeeded()
        #expect(header.markView.layer.animationKeys() == nil, "the intro played under the sheet")
        #expect(header.introWatch != nil, "still waiting")

        // The sheet stays up longer than the watch.
        let start = CACurrentMediaTime()
        header.clock = { start + 11 }
        header.introWatchTick()
        #expect(header.introWatch == nil)
        await withCheckedContinuation { done in root.dismiss(animated: false) { done.resume() } }
        try #require(root.presentedViewController == nil)
        // Another scene's dismissal (here: no scene) doesn't restart it.
        NotificationCenter.default.post(name: WelcomeSheet.didDismissNotification, object: nil)
        #expect(header.introWatch == nil)
        NotificationCenter.default.post(name: WelcomeSheet.didDismissNotification, object: window.windowScene)
        #expect(header.introWatch != nil, "the sheet's dismissal restarts the watch")
        header.introWatchTick()
        header.layoutIfNeeded()
        #expect(header.markView.layer.animation(forKey: LaunchHeaderView.introKey) != nil)
        #expect(header.introWatch == nil)
    }

    /// `onContentShown` (the Welcome sheet's moment): once per view, the first time the launch
    /// view is shown in an active scene, also with Reduce Motion (no intro, so no watch of its own).
    @Test(arguments: [false, true])
    func contentShownFiresOnce(reduceMotion: Bool) async throws {
        guard #available(iOS 18.0, *) else { return }
        var shown = 0
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: reduceMotion, contentAlpha: 0,
                                          onContentShown: { shown += 1 })
        defer { window.isHidden = true }
        #expect(shown == 0)
        #expect(header.introWatch != nil)
        try #require(header.superview).alpha = 1
        header.introWatchTick()
        header.layoutIfNeeded()
        #expect(shown == 0, "the callback runs inside the layout pass")
        await drainMain()
        #expect(shown == 1)
        // The intro decides at the watch's next check, once the callback's present is under way.
        header.introWatchTick()
        header.layoutIfNeeded()
        #expect(header.introWatch == nil)
        #expect((header.markView.layer.animation(forKey: LaunchHeaderView.introKey) != nil) == !reduceMotion)

        let content = header.superview
        header.removeFromSuperview()
        content?.addSubview(header)
        header.setNeedsLayout()
        header.layoutIfNeeded()
        await drainMain()
        #expect(shown == 1, "a second time")
        #expect(header.introWatch == nil)
    }

    /// Behind UIKit's legacy title card (`LaunchLook.card`): the gradient alone, no button of
    /// ours, and the content-shown callback still the header's.
    @Test func installForTheCardShowsTheGradientAlone() throws {
        guard #available(iOS 18.0, *) else { return }
        let options = UIDocumentViewController().launchOptions
        var shown = 0
        LaunchHeader.install(in: options, look: .card) { shown += 1 }
        let header = try #require(options.backgroundAccessoryView as? LaunchHeaderView)
        #expect(!header.showsFigures)
        #expect(options.foregroundAccessoryView == nil)
        header.onContentShown?()
        #expect(shown == 1)
    }

    /// Under the card the wordmark, dog and icons stay hidden and the intro is skipped (it would
    /// play under the card); the gradient shows and the Welcome sheet's callback still fires.
    @Test func cardLookSkipsTheFiguresAndTheIntro() async throws {
        guard #available(iOS 18.0, *) else { return }
        var shown = 0
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: false, showsFigures: false,
                                          onContentShown: { shown += 1 })
        defer { window.isHidden = true }
        #expect(header.showsArt)
        #expect(!header.gradientLayer.isHidden)
        for view in [header.markView] + header.iconViews {
            #expect(view.isHidden)
            #expect(view.layer.animationKeys() == nil)
        }
        await drainMain()
        #expect(shown == 1)
        header.introWatchTick()
        header.layoutIfNeeded()
        #expect(header.introWatch == nil, "the intro still waits")
        for view in [header.markView] + header.iconViews {
            #expect(view.layer.animationKeys() == nil)
        }
    }

    /// Under the card there is no intro to wait for: with nothing else waiting (the content-shown
    /// callback reported, or none) no watch runs, even while the launch view is still hidden.
    @Test func cardLookRunsNoIntroWatch() throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: false, contentAlpha: 0,
                                          showsFigures: false)
        defer { window.isHidden = true }
        #expect(header.introWatch == nil)
    }

    /// No room for the art (iPhone landscape): the intro is skipped, the callback still fires.
    @Test func contentShownFiresWhenTheArtIsSkipped() async throws {
        guard #available(iOS 18.0, *) else { return }
        var shown = 0
        let (header, window) = try hosted(width: 390, height: 60, reduceMotion: false,
                                          onContentShown: { shown += 1 })
        defer { window.isHidden = true }
        #expect(!header.showsArt)
        await drainMain()
        #expect(shown == 1)
    }

    /// Set after the header is in its window (the launch view loads before the scene delegate
    /// could set it): the watch starts for it.
    @Test func contentShownSetLaterStillFires() async throws {
        guard #available(iOS 18.0, *) else { return }
        var shown = 0
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: true, contentAlpha: 0)
        defer { window.isHidden = true }
        #expect(header.introWatch == nil)
        header.onContentShown = { shown += 1 }
        #expect(header.introWatch != nil)
        try #require(header.superview).alpha = 1
        header.introWatchTick()
        header.layoutIfNeeded()
        await drainMain()
        #expect(shown == 1)
    }

    /// Lets the main-queue blocks enqueued so far run (the callback is dispatched after layout).
    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func artFitsTheBandBelowTheBars() throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: true)
        defer { window.isHidden = true }
        let band = LaunchHeaderBand.height(
            safeTop: header.safeAreaInsets.top, guideBottom: header.bounds.height - header.layoutMargins.bottom,
            buttonHeight: 0)
        let layout = try #require(header.currentLayout)
        #expect(header.showsArt)
        #expect(layout.height <= band + 0.001)
        #expect(header.stageTop >= header.safeAreaInsets.top)
        #expect(header.stageTop + layout.height <= header.safeAreaInsets.top + band + 0.001)
    }

    @Test(arguments: LaunchHeaderTests.rooms)
    func layoutMirrorsLeftAndRight(width: Double, height: Double) {
        let layout = LaunchHeaderLayout(width: width, height: height)
        let middle = CGFloat(width) / 2
        for icon in layout.visibleIcons {
            let mirrored = LaunchHeaderLayout.Icon(
                name: icon.name, side: -icon.side, distance: icon.distance, row: icon.row,
                width: icon.width, height: icon.height, ring: icon.ring)
            let frame = layout.frame(of: icon)
            #expect(abs((frame.midX - middle) + (layout.frame(of: mirrored).midX - middle)) < 0.001)
            #expect(icon.side < 0 ? frame.midX < middle : frame.midX > middle)
            // Every icon stays on screen and inside the stage.
            #expect(frame.minX >= 0 && frame.maxX <= CGFloat(width))
            #expect(frame.minY >= 0 && frame.maxY <= layout.height)
            // It flies out from the dog's middle.
            let start = layout.flightStart(of: icon)
            #expect(abs(frame.midX + start.dx - middle) < 0.001)
            #expect(abs(frame.midY + start.dy - (LaunchHeaderLayout.flyRow - LaunchHeaderLayout.topRow) * layout.k) < 0.001)
        }
        // Outward from the dog in launch order on each side.
        for side: CGFloat in [-1, 1] {
            let offsets = layout.visibleIcons.filter { $0.side == side }.sorted { $0.ring < $1.ring }
                .map { abs(layout.centreOffset(of: $0)) }
            #expect(offsets == offsets.sorted())
        }
        #expect(abs(layout.markFrame.midX - (middle + 20 * layout.k)) < 0.001)
    }

    @Test func reduceMotionShowsTheFinalLayoutWithoutAnimations() throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: true)
        defer { window.isHidden = true }
        #expect(header.hasPlayedIntro)
        for view in [header.markView] + header.iconViews {
            #expect(view.layer.animationKeys() == nil)
            #expect(view.transform == .identity)
            #expect(view.alpha == 1)
        }
        let layout = try #require(header.currentLayout)
        for (icon, view) in zip(LaunchHeaderLayout.icons, header.iconViews) {
            #expect(close(view.frame, layout.frame(of: icon).offsetBy(dx: 0, dy: header.stageTop)))
        }
        #expect(close(header.markView.frame, layout.markFrame.offsetBy(dx: 0, dy: header.stageTop)))
    }

    @Test func introPlaysOnceThenNeverAgain() throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 1032, height: 700, reduceMotion: false)
        defer { window.isHidden = true }
        #expect(header.markView.layer.animation(forKey: LaunchHeaderView.introKey) != nil)
        // The shown icons fly in; those the room leaves out stay still.
        #expect(header.iconViews.contains { !$0.isHidden })
        for view in header.iconViews {
            #expect((view.layer.animation(forKey: LaunchHeaderView.introKey) != nil) == !view.isHidden)
        }
        // Back to the launch view later: out of the window and in again.
        for view in [header.markView] + header.iconViews { view.layer.removeAllAnimations() }
        let content = header.superview
        header.removeFromSuperview()
        content?.addSubview(header)
        header.setNeedsLayout()
        header.layoutIfNeeded()
        for view in [header.markView] + header.iconViews {
            #expect(view.layer.animationKeys() == nil)
        }
    }

    @Test func gradientFollowsTheAppearance() throws {
        guard #available(iOS 18.0, *) else { return }
        let (header, window) = try hosted(width: 390, height: 844, reduceMotion: true)
        defer { window.isHidden = true }
        header.overrideUserInterfaceStyle = .light
        header.layoutIfNeeded()
        #expect(header.gradientLayer.colors?.count == LaunchHeaderPalette.light.count)
        header.overrideUserInterfaceStyle = .dark
        header.layoutIfNeeded()
        #expect(header.gradientLayer.colors?.count == LaunchHeaderPalette.dark.count)
        #expect(LaunchHeaderPalette.light.first == LaunchHeaderPalette.dark.first)
        #expect(LaunchHeaderPalette.light.last != LaunchHeaderPalette.dark.last)
        for stops in [LaunchHeaderPalette.light, LaunchHeaderPalette.dark] {
            #expect(stops.map(\.location) == stops.map(\.location).sorted())
            #expect(stops.first?.location == 0 && stops.last?.location == 1)
        }
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    /// A header in a window of the host's scene, laid out.
    /// `contentAlpha`: the alpha of the header's container (the stock launch view's content).
    @available(iOS 18.0, *)
    private func hosted(width: CGFloat, height: CGFloat, reduceMotion: Bool, contentAlpha: CGFloat = 1,
                        showsFigures: Bool = true, sceneActive: @escaping () -> Bool = { true },
                        onContentShown: (() -> Void)? = nil) throws -> (LaunchHeaderView, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        let content = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        content.alpha = contentAlpha
        root.view.addSubview(content)
        let header = LaunchHeaderView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        header.reduceMotion = { reduceMotion }
        header.showsFigures = showsFigures
        header.sceneIsActive = sceneActive
        header.onContentShown = onContentShown
        content.addSubview(header)
        window.isHidden = false
        header.layoutIfNeeded()
        return (header, window)
    }
}
