import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // As early as possible: setting it rebuilds the main menu.
        ArchiveCommands.configureMainMenu()
        // Copy's export folders of earlier runs: this run holds none yet. Off the main thread;
        // no Copy starts until it ends (`ScreenState.exportRemoval`).
        ScreenState.sweepClipboardExportsAtLaunch()
        WelcomeSheet.applyDebugReset()

        // A new install's Documents is empty, and iOS hides an empty app folder from Files.
        SampleArchiveSeeder.seedAtLaunch()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }

    /// The menu bar (iPadOS 26) and the ⌘-hold overlay: Save, Delete and, before 26, Close.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        ArchiveCommands.build(builder)
    }
}
