import SwiftUI
import UIKit

/// The one-time Welcome sheet:
/// header art, title, feature rows, how to open an archive from Files, Continue. Shown once, over
/// the document browser of the first window that comes up without a file, never again
/// (`WelcomeSettings.seenKey`). iOS has no public API to make an app the default for a file type,
/// so there is no default-app button.
enum WelcomeSheet {
    /// The sheet over the browser: a large sheet on iPhone, a form sheet on iPad (a large sheet
    /// again in compact width). Swipe-to-dismiss stays on: the sheet is marked seen in `settings`
    /// once it has appeared (`WelcomeSheetController`), so any dismissal counts.
    @MainActor static func makeController(appName: String = AppDisplayName.current,
                                          settings: WelcomeSettings = WelcomeSettings()) -> UIViewController {
        var dismiss: () -> Void = {}
        let controller = WelcomeSheetController(rootView: WelcomeSheetView(appName: appName) { dismiss() },
                                                settings: settings)
        dismiss = { [weak controller] in controller?.dismiss(animated: true) }
        controller.modalPresentationStyle = .formSheet
        controller.sheetPresentationController?.detents = [.large()]
        controller.view.accessibilityIdentifier = "WelcomeSheet"
        return controller
    }

    /// DEBUG only, for UI tests: `-KernirWelcomeReset YES` forgets that the sheet was seen, so this
    /// launch is a first one. (Other UI tests pass `-KernirWelcomeSeen YES`: the argument domain
    /// over the app's defaults, so the sheet doesn't cover the browser.)
    static func applyDebugReset() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-KernirWelcomeReset") {
            UserDefaults.standard.removeObject(forKey: WelcomeSettings.seenKey)
        }
        #endif
    }

    /// The app is a unit-test host (KernirIOSTests): no sheet over the host's window, and the
    /// simulator's defaults stay as they were. `-KernirWelcomeReset` still shows it.
    static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            && !ProcessInfo.processInfo.arguments.contains("-KernirWelcomeReset")
    }
}

/// Which window presents the Welcome sheet: at most one per process (several iPad windows can
/// come up at launch), never one launched to open a file (the sheet waits for a later plain
/// launch), never once seen.
@MainActor final class WelcomeSheetGate {
    static let shared = WelcomeSheetGate()

    /// A window of this process has presented the sheet.
    private(set) var hasPresented = false

    /// Whether the window asking presents the sheet now. When it does, the sheet is claimed for
    /// this process; it is marked seen only once it has appeared (`WelcomeSheetController`), so a
    /// present that never comes up leaves it for a later launch.
    /// - Parameters:
    ///   - launchedWithFile: the window was opened to show a file (Open In, a URL, a new window
    ///     for a file).
    ///   - browserIsCovered: something is already presented over the window's browser (the
    ///     archive it opened).
    func claim(settings: WelcomeSettings, launchedWithFile: Bool, browserIsCovered: Bool) -> Bool {
        guard !hasPresented, !launchedWithFile, !browserIsCovered, settings.shouldPresentOnce else { return false }
        hasPresented = true
        return true
    }
}

/// The sheet's content, stock apart from the header art: it scrolls (small phones, landscape,
/// large Dynamic Type), with Continue pinned at the bottom.
struct WelcomeSheetView: View {
    let appName: String
    let onContinue: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The art fills the sheet's width at width × 686/1600, its own aspect. This caps the height:
    /// a lower cap crops the art's flat top and bottom bands, never its content (`WelcomeHeaderView`).
    private var headerHeight: CGFloat { horizontalSizeClass == .regular ? 240 : 190 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                WelcomeHeaderView(maxHeight: headerHeight)
                VStack(alignment: .leading, spacing: 28) {
                    Text(WelcomeFeature.welcomeTitle(appName: appName))
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("WelcomeTitle")
                    WelcomeFeatureList(features: WelcomeFeature.iOS)
                    Text(Self.openHint(appName: appName))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // The header reaches the sheet's top edge.
        .ignoresSafeArea(.container, edges: .top)
        .modifier(BottomBar { continueButton })
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            Text("Continue", comment: "iOS Welcome sheet: the button that closes the sheet and shows the file browser.")
                .frame(maxWidth: .infinity)
        }
        .modifier(ProminentButton())
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("WelcomeContinue")
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// How to open an archive: in the app's own browser (every window's root), or from the Files
    /// app's share sheet, where the app is listed for the archive types it declares.
    static func openHint(appName: String) -> String {
        String(localized: "Open archives right here, or from Files: touch and hold an archive, tap Share, then choose \(appName).",
               comment: "iOS Welcome sheet: how to open an archive, under the feature rows. “Right here” is the app’s own file browser, shown when the sheet closes. Files is the iOS Files app; Share is its menu item. The value is the app’s name.")
    }
}

/// iOS 26: the Liquid Glass prominent button; earlier: the bordered prominent one.
private struct ProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

/// Continue under the scrolling content: iOS 26's safe-area bar (with its scroll edge effect);
/// earlier, an inset on the bar material.
private struct BottomBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.safeAreaBar(edge: .bottom) { bar() }
        } else {
            content.safeAreaInset(edge: .bottom) { bar().frame(maxWidth: .infinity).background(.bar) }
        }
    }
}
