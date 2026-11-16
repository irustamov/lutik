import SwiftUI

/// The Mac Welcome window's content: the hero art under the title bar ("Lutik" lettering, the dog, the
/// format icons; its VoiceOver label is "Welcome to <app>", also the window's title) and New Archive
/// centred under it, on the art's magenta, which fades into the window's background above the
/// features; the features two by two; Open Archive… and "Make <app> the Default App for Archives";
/// the "Show at launch" checkbox. Stock controls only; the hero is the one exception (its own art and
/// fill, and New Archive's outline).
struct WelcomeView: View {
    static let width: CGFloat = 640
    /// Above the art: clears the title bar the hero reaches under.
    private static let heroTop: CGFloat = 30
    /// Between the art (its own clear margin included) and New Archive.
    private static let heroArtToButton: CGFloat = 8
    /// The magenta stays solid this far below New Archive, then fades out over `heroFade`.
    private static let heroSolidBelowButton: CGFloat = 16
    private static let heroFade: CGFloat = 56
    /// Plain window background between the end of the fade and the first row of features.
    private static let featuresTop: CGFloat = 16

    let defaultApp: DefaultAppModel
    let settings: WelcomeSettings
    let openArchive: () -> Void
    let newArchive: () -> Void

    @State private var showsAtLaunch: Bool

    init(defaultApp: DefaultAppModel, settings: WelcomeSettings, openArchive: @escaping () -> Void,
         newArchive: @escaping () -> Void) {
        self.defaultApp = defaultApp
        self.settings = settings
        self.openArchive = openArchive
        self.newArchive = newArchive
        _showsAtLaunch = State(initialValue: settings.showsAtLaunch)
    }

    private var appName: String { defaultApp.appName }

    var body: some View {
        VStack(spacing: 0) {
            hero
            Grid(horizontalSpacing: 28, verticalSpacing: 24) {
                ForEach(Self.pairs(WelcomeFeature.mac), id: \.first.id) { pair in
                    GridRow(alignment: .top) {
                        WelcomeFeatureTile(feature: pair.first)
                        if let second = pair.second { WelcomeFeatureTile(feature: second) }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, Self.featuresTop)
            actions
                .padding(.horizontal, 32)
                .padding(.top, 28)
            Divider()
                .padding(.top, 24)
            Toggle(String(localized: "Show this window when \(appName) opens",
                          comment: "Mac Welcome window: checkbox at the bottom; on, the window opens at launches with no document. The value is the app's name."),
                   isOn: $showsAtLaunch)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("WelcomeShowAtLaunch")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .onChange(of: showsAtLaunch) { _, new in settings.showsAtLaunch = new }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The art across the window's width (it carries its own side margins) and New Archive centred
    /// under the dog, on the one gradient.
    private var hero: some View {
        VStack(spacing: Self.heroArtToButton) {
            Image(WelcomeHeaderArt.heroImageName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.width)
                .accessibilityLabel(WelcomeFeature.welcomeTitle(appName: appName))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("WelcomeHero")
            Button(String(localized: "New Archive",
                          comment: "Mac Welcome window: button under the hero art; makes a new, empty archive (File > New).")) {
                newArchive()
            }
            .buttonStyle(WelcomeOutlineButtonStyle())
            .accessibilityIdentifier("WelcomeNewArchive")
        }
        .padding(.top, Self.heroTop)
        .padding(.bottom, Self.heroSolidBelowButton + Self.heroFade)
        .background { WelcomeHeroBackground(fade: Self.heroFade) }
    }

    /// The features two by two (the last pair may have one).
    private static func pairs(_ features: [WelcomeFeature]) -> [FeaturePair] {
        stride(from: 0, to: features.count, by: 2).map { i in
            FeaturePair(first: features[i], second: i + 1 < features.count ? features[i + 1] : nil)
        }
    }

    private struct FeaturePair {
        let first: WelcomeFeature
        let second: WelcomeFeature?
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if defaultApp.isDefaultForAll {
                    Label(defaultApp.outcome == .madeDefault
                          ? String(localized: "\(appName) is now the default app for archives.",
                                   comment: "Mac Welcome window: shown in place of the “Make … the Default App for Archives” button right after it worked. The value is the app's name.")
                          : String(localized: "\(appName) is the default app for archives.",
                                   comment: "Mac Welcome window: shown in place of the “Make … the Default App for Archives” button when the app already opens every archive type. The value is the app's name."),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("WelcomeDefaultOutcome")
                } else {
                    Button(String(localized: "Make \(appName) the Default App for Archives",
                                  comment: "Mac Welcome window: button that makes the app the default app for every archive type it opens. The value is the app's name.")) {
                        Task { await defaultApp.makeDefaultForAll() }
                    }
                    .disabled(defaultApp.isWorking)
                    .accessibilityIdentifier("WelcomeMakeDefault")
                    if defaultApp.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 12)
                Button(String(localized: "Open Archive…",
                              comment: "Mac Welcome window: default button; shows the standard Open panel.")) {
                    openArchive()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("WelcomeOpenArchive")
            }
            .controlSize(.large)
            .modifier(DefaultAppDryRunMarker(isDryRun: defaultApp.isDryRun))
            if let message = defaultApp.problemMessage(pointsToSettings: true) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension WelcomeHeaderArt {
    /// The header art's lettering, dog and format icons with the background keyed out, with a clear
    /// margin on every side (from the App Store header art, x 385-1215 /
    /// y 195-492 in 1600-wide units; the icons cut by that crop removed), 1280 px wide. In the Mac-only
    /// App/macOS/WelcomeMac.xcassets (iOS shows `WelcomeHeaderView` instead).
    static let heroImageName = "WelcomeHeroArt"
}

/// The hero's background: one gradient top to bottom. The art's magenta, exactly
/// #FF00A8, solid down to `fade` points above the bottom, then eased (smoothstep) out to clear, so the
/// window's own background, light or dark, shows through from there on with no seam. The colour is a
/// plain fill under a gradient mask: a gradient of the colour itself drew it as #FF32A8.
struct WelcomeHeroBackground: View {
    nonisolated static let color = Color(.sRGB, red: 1, green: 0, blue: 0xA8 / 255.0)

    let fade: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let solidEnd = max(0, 1 - fade / max(proxy.size.height, 1))
            Self.color.mask {
                LinearGradient(stops: Self.stops(solidEnd: solidEnd).map {
                    Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location)
                }, startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
    }

    /// Solid from 0 to `solidEnd` (a fraction of the height), then `steps` eased steps to clear at 1.
    nonisolated static func stops(solidEnd: CGFloat, steps: Int = 12) -> [(location: CGFloat, opacity: Double)] {
        [(location: 0, opacity: 1)] + (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return (location: i == steps ? 1 : solidEnd + (1 - solidEnd) * t, opacity: 1 - t * t * (3 - 2 * t))
        }
    }
}

/// The hero's New Archive button: a stock Button drawn clear with a
/// capsule outline, its outline and title white in both appearances, on the hero's
/// magenta. System font, the extra-large control's height; pressed, the capsule takes a faint fill.
struct WelcomeOutlineButtonStyle: ButtonStyle {
    /// The outline, title and pressed fill: white whatever the appearance.
    nonisolated static let ink = Color.white

    func makeBody(configuration: Configuration) -> some View {
        WelcomeOutlineButtonBody(configuration: configuration)
    }
}

/// Reads the button's focus (inside the button, so `isFocused` is the button's own) for the capsule.
private struct WelcomeOutlineButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        WelcomeOutlineCapsule(label: configuration.label, isPressed: configuration.isPressed, isFocused: isFocused)
    }
}

/// The New Archive capsule. Its outline (a stroke inset by half its width, so it stays within the
/// capsule), pressed fill and focus ring are drawn in a `Canvas`: SwiftUI shape views came out with 18 pt
/// bars past both round ends in `cacheDisplay` snapshots (`-WelcomeSnapshot`), though clean on screen;
/// a Canvas draws the same both ways. A custom button style loses the system focus ring on the Mac, so a
/// focused button (Full Keyboard Access, Tab) gets a ring of the system's keyboard focus colour just
/// outside the capsule.
struct WelcomeOutlineCapsule<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    private static var lineWidth: CGFloat { 1.5 }
    private static var focusWidth: CGFloat { 3 }
    /// From the capsule's edge out to the focus ring's outer edge.
    private static var focusReach: CGFloat { focusWidth + 1 }

    var body: some View {
        let ink = WelcomeOutlineButtonStyle.ink
        label
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 20)
            .frame(minHeight: 36)
            .background {
                Canvas { context, size in
                    let bounds = CGRect(origin: .zero, size: size)
                    if isPressed {
                        context.fill(Capsule().path(in: bounds), with: .color(ink.opacity(0.15)))
                    }
                    let outline = bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
                    context.stroke(Capsule().path(in: outline), with: .color(ink), lineWidth: Self.lineWidth)
                }
            }
            .overlay {
                if isFocused {
                    Canvas { context, size in
                        let ring = CGRect(origin: .zero, size: size)
                            .insetBy(dx: Self.focusWidth / 2, dy: Self.focusWidth / 2)
                        context.stroke(Capsule().path(in: ring), with: .color(Color(nsColor: .keyboardFocusIndicatorColor)),
                                       lineWidth: Self.focusWidth)
                    }
                    .padding(-Self.focusReach)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A feature as a centred tile: a big tinted symbol over a title and a line of detail.
private struct WelcomeFeatureTile: View {
    let feature: WelcomeFeature

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(height: 38)
                .accessibilityHidden(true)
            Text(feature.title)
                .font(.title3.weight(.semibold))
            Text(feature.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}


/// With a dry run only (`DefaultAppModel.isDryRun`): the Welcome window's buttons sit in a group
/// identified `DefaultAppDryRun`, which the UI tests look for before they click "Make … the
/// Default App", so a build without the dry run never changes the machine's default apps.
struct DefaultAppDryRunMarker: ViewModifier {
    static let identifier = "DefaultAppDryRun"

    let isDryRun: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isDryRun {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(Self.identifier)
        } else {
            content
        }
    }
}
