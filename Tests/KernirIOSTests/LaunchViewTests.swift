import Foundation
import Testing
import UIKit
@testable import Kernir

/// iOS 18+: the window's root is the document controller showing the system launch view: the Lutik art
/// with New Archive on it, and the stock browser below. iOS 17 keeps the full-screen browser (`DocumentBrowserTests`).
@MainActor @Suite struct LaunchViewTests {
    @available(iOS 18.0, *)
    private func loadedLaunchRoot(look: LaunchLook = .art) throws
        -> (ArchiveNavigationController, ArchiveDocumentViewController) {
        let nav = ArchiveDocumentViewController.makeLaunchNavigation(session: nil, look: look)
        let docVC = try #require(nav.viewControllers.first as? ArchiveDocumentViewController)
        docVC.loadViewIfNeeded()
        return (nav, docVC)
    }

    @available(iOS 18.0, *)
    @Test func launchRootHasNoDocumentAndLargeTitles() throws {
        let (nav, docVC) = try loadedLaunchRoot()
        #expect(nav.viewControllers.count == 1)
        #expect(nav.navigationBar.prefersLargeTitles)
        #expect(docVC.showsLaunchView)
        #expect(docVC.document == nil)
        #expect(docVC.dismissHandler == nil)
    }

    /// No stock title or button (no card), the art carries
    /// the name, and a stock New Archive button sits on the art, running the browser's New Archive flow.
    @available(iOS 18.0, *)
    @Test func launchOptionsHaveNoTitleAndNewArchiveOnTheArt() throws {
        let (_, docVC) = try loadedLaunchRoot()
        #expect(docVC.launchLook == .art)
        #expect(docVC.launchOptions.title == "")
        #expect(docVC.launchOptions.primaryAction == nil)
        let newArchive = try #require(docVC.launchOptions.foregroundAccessoryView as? LaunchNewArchiveView)
        #expect(newArchive.button.accessibilityIdentifier == LaunchNewArchiveView.identifier)
        #expect(newArchive.button.configuration?.title == String(localized: "New Archive"))
        let header = try #require(docVC.launchOptions.backgroundAccessoryView as? LaunchHeaderView)
        #expect(header.newArchiveView === newArchive)
        #expect(header.showsFigures)
    }

    /// Where UIKit draws its legacy title card (iOS < 27, or an
    /// older SDK), the card holds the app's name and New Archive, and only the gradient shows
    /// behind it: no wordmark, dog or icons under the card, and no button of ours.
    @available(iOS 18.0, *)
    @Test func launchOptionsFillTheLegacyCard() throws {
        let (_, docVC) = try loadedLaunchRoot(look: .card)
        #expect(docVC.launchLook == .card)
        let title = try #require(docVC.launchOptions.title)
        #expect(!title.isEmpty)
        #expect(title == ArchiveDocumentViewController.appDisplayName())
        let newArchive = try #require(docVC.launchOptions.primaryAction)
        #expect(newArchive.title == String(localized: "New Archive"))
        #expect(newArchive.identifier == ArchiveDocumentViewController.newArchiveActionIdentifier)
        #expect(docVC.launchOptions.foregroundAccessoryView == nil)
        let header = try #require(docVC.launchOptions.backgroundAccessoryView as? LaunchHeaderView)
        #expect(!header.showsFigures)
        #expect(header.newArchiveView == nil)
        let browser = docVC.launchOptions.browserViewController
        #expect(browser.allowsDocumentCreation)
        #expect(browser.delegate === docVC)
    }

    /// A bundle without a name gives no title (UIKit's default then), not an empty one.
    @Test func noDisplayNameWithoutOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("noname-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try #require(Bundle(url: folder))
        #expect(ArchiveDocumentViewController.appDisplayName(in: bundle) == nil)
        #expect(ArchiveDocumentViewController.appDisplayName() != nil)
    }

    /// The card's New Archive runs the same flow as the art's button: the options sheet.
    @available(iOS 18.0, *)
    @Test(.timeLimit(.minutes(1))) func cardNewArchivePresentsTheOptionsSheet() async throws {
        let (nav, docVC, window) = try hostedLaunchRoot(look: .card)
        let newArchive = try #require(docVC.launchOptions.primaryAction)
        UIButton(primaryAction: nil).sendAction(newArchive)
        let sheet = try #require(nav.presentedViewController, "New Archive brought up nothing")
        #expect(sheet.modalPresentationStyle == .formSheet)
        #expect(sheet.isModalInPresentation)
        try await waitUntil { !sheet.isBeingPresented }
        try await tearDown(window, docVC, nil)
    }

    @available(iOS 18.0, *)
    @Test func launchBrowserCreatesArchivesThroughTheController() throws {
        let (_, docVC) = try loadedLaunchRoot()
        let browser = docVC.launchOptions.browserViewController
        #expect(browser.allowsDocumentCreation)
        #expect(browser.localizedCreateDocumentActionTitle == String(localized: "New Archive"))
        #expect(browser.delegate === docVC)
        #expect(browser.additionalTrailingNavigationBarButtonItems.count == 1, "no Acknowledgements item")
    }

    /// The launch view's root keeps the system's back action (it empties the controller in
    /// place); only the archive presented over the iOS 17 browser gets the closing one.
    /// `UINavigationItem.backAction` is a copying property: compare identifiers, not instances.
    @available(iOS 18.0, *)
    @Test func launchRootKeepsTheSystemBackAction() async throws {
        let (_, launchVC) = try loadedLaunchRoot()
        // With a document, where the presented controller installs its own: the navigation
        // item's update must leave the launch root's back action alone. A real archive, opened
        // first, so the controller starts no open of its own that could fail after the test.
        let document = ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip"))
        #expect(await document.openOnMain())
        launchVC.document = document
        launchVC.navigationItemDidUpdate()
        #expect(launchVC.navigationItem.backAction?.identifier != launchVC.backAction.identifier)
        launchVC.document = nil
        // The controller closes the document it let go of; a second close would never call back.
        await document.closedByController()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("presented-\(UUID().uuidString).zip")
        let presented = try #require(DocumentBrowserController.makeDocumentNavigation(for: url, session: nil)
            .viewControllers.first as? ArchiveDocumentViewController)
        presented.loadViewIfNeeded()
        #expect(!presented.showsLaunchView)
        #expect(presented.navigationItem.backAction?.identifier == presented.backAction.identifier)
        presented.document = nil
    }

    /// A new archive the launch browser imported opens in place.
    @available(iOS 18.0, *)
    @Test func importedArchiveOpensInPlace() throws {
        let (_, docVC) = try loadedLaunchRoot()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        let source = folder.appendingPathComponent("Untitled.zip")
        let destination = folder.appendingPathComponent("Untitled 2.zip")
        docVC.documentBrowser(docVC.launchOptions.browserViewController, didImportDocumentAt: source,
                              toDestinationURL: destination)
        #expect(docVC.document is ArchiveDocument)
        #expect(docVC.document?.fileURL == destination)
        docVC.document = nil
    }

    /// New Archive on the art: the stock create action does nothing from a button of ours, so the
    /// controller runs the flow itself and moves the new archive into its folder under a free name,
    /// as the browser's import does, then opens it in place.
    @available(iOS 18.0, *)
    @Test(.timeLimit(.minutes(1))) func newArchiveFromTheArtMovesIntoTheFolderUnderAFreeName() async throws {
        let (_, docVC) = try loadedLaunchRoot()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("launch-new-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("untitled.tar.gz"))
        docVC.newArchiveFolder = folder
        let source = try Fixture.copy("zip/deflate.zip", as: "Untitled.tar.gz")
        docVC.importNewArchive(source)
        let destination = folder.appendingPathComponent("Untitled 2.tar.gz")
        let document = try #require(docVC.document as? ArchiveDocument)
        #expect(document.fileURL.standardizedFileURL == destination.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        docVC.document = nil
        // The controller closes the document it let go of; the folder goes only after that.
        await document.closedByController()
    }

    /// A move that fails leaves the launch view as it was.
    @available(iOS 18.0, *)
    @Test func newArchiveFromTheArtThatCannotMoveOpensNothing() throws {
        let (_, docVC) = try loadedLaunchRoot()
        let notAFolder = FileManager.default.temporaryDirectory.appendingPathComponent("launch-file-\(UUID().uuidString)")
        try Data().write(to: notAFolder)
        defer { try? FileManager.default.removeItem(at: notAFolder) }
        docVC.newArchiveFolder = notAFolder
        docVC.importNewArchive(try Fixture.copy("zip/deflate.zip", as: "Untitled.zip"))
        #expect(docVC.document == nil)
    }

    /// New archives from the art go to the app's Documents, where the browser shows them.
    @available(iOS 18.0, *)
    @Test func newArchiveFolderIsDocuments() throws {
        let (_, docVC) = try loadedLaunchRoot()
        #expect(docVC.newArchiveFolder == FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    /// Back, ⌘W: the document goes at once, and the launch view comes back in place.
    @available(iOS 18.0, *)
    @Test func closeEmptiesTheLaunchRootInPlace() throws {
        let (nav, docVC) = try loadedLaunchRoot()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("close-\(UUID().uuidString).zip")
        docVC.document = ArchiveDocument(fileURL: url)
        docVC.closeDocument()
        #expect(docVC.document == nil)
        #expect(!docVC.isClosing)
        #expect(nav.viewControllers.first === docVC)
    }

    // MARK: Welcome sheet over the launch view

    /// The launch root in a second window of the host's scene, on screen.
    @available(iOS 18.0, *)
    private func hostedLaunchRoot(look: LaunchLook = .art) throws
        -> (ArchiveNavigationController, ArchiveDocumentViewController, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let (nav, docVC) = try loadedLaunchRoot(look: look)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = nav
        window.isHidden = false
        return (nav, docVC, window)
    }

    @available(iOS 18.0, *)
    private func tearDown(_ window: UIWindow, _ docVC: ArchiveDocumentViewController, _ document: ArchiveDocument?) async throws {
        docVC.document = nil
        if let document { await document.closedByController() }
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func welcomeSheet(_ defaults: UserDefaults) -> UIViewController {
        WelcomeSheet.makeController(appName: "Kernir", settings: WelcomeSettings(defaults: defaults))
    }

    /// The sheet comes up over the launch view; a document arriving (Open In, a URL) takes it
    /// away and shows in place, with nothing left over it.
    @available(iOS 18.0, *)
    @Test(.timeLimit(.minutes(1))) func documentArrivingDismissesTheWelcomeSheet() async throws {
        let (nav, docVC, window) = try hostedLaunchRoot()
        let (defaults, suite) = makeTestDefaults("LaunchWelcome")
        defer { removeTestDefaults(defaults, suite: suite) }
        let welcome = welcomeSheet(defaults)
        SceneDelegate.presentWelcome(welcome, overLaunchViewOf: docVC)
        #expect(nav.presentedViewController === welcome)
        #expect(docVC.welcomeSheet === welcome)
        try await waitUntil { welcome.viewIfLoaded?.window != nil && !welcome.isBeingPresented }
        try #require(welcome.viewIfLoaded?.window != nil, "the Welcome sheet never came up")

        let document = ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip"))
        #expect(await document.openOnMain())
        docVC.document = document
        try await waitUntil { welcome.presentingViewController == nil }
        #expect(welcome.presentingViewController == nil, "the Welcome sheet is still up over the archive")
        #expect(nav.presentedViewController == nil)
        #expect(docVC.document === document)
        try await tearDown(window, docVC, document)
    }

    /// A document arriving while the sheet is still on its way up takes it away once it is up.
    @available(iOS 18.0, *)
    @Test(.timeLimit(.minutes(1))) func documentDuringTheWelcomeSheetsPresentDismissesItAfter() async throws {
        let (nav, docVC, window) = try hostedLaunchRoot()
        let (defaults, suite) = makeTestDefaults("LaunchWelcome")
        defer { removeTestDefaults(defaults, suite: suite) }
        // Opened first, so the controller starts no open of its own that could fail after the test.
        let document = ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip"))
        #expect(await document.openOnMain())
        let welcome = welcomeSheet(defaults)
        SceneDelegate.presentWelcome(welcome, overLaunchViewOf: docVC)
        try #require(welcome.viewIfLoaded?.window == nil || welcome.isBeingPresented, "the sheet is already up")
        docVC.document = document
        try await waitUntil { welcome.presentingViewController == nil && nav.presentedViewController == nil }
        #expect(welcome.presentingViewController == nil, "the Welcome sheet is stuck over the archive")
        #expect(nav.presentedViewController == nil)
        try await tearDown(window, docVC, document)
    }

    /// Presented from the top of the window's presented chain.
    @available(iOS 18.0, *)
    @Test(.timeLimit(.minutes(1))) func welcomeSheetComesUpOverWhatIsPresented() async throws {
        let (nav, docVC, window) = try hostedLaunchRoot()
        let (defaults, suite) = makeTestDefaults("LaunchWelcome")
        defer { removeTestDefaults(defaults, suite: suite) }
        let other = UIViewController()
        nav.present(other, animated: false)
        // Even a non-animated present ends a moment later; UIKit won't present over one under way.
        try await waitUntil { other.viewIfLoaded?.window != nil && !other.isBeingPresented }
        try #require(nav.presentedViewController === other, "the other controller never came up")
        let welcome = welcomeSheet(defaults)
        SceneDelegate.presentWelcome(welcome, overLaunchViewOf: docVC)
        #expect(other.presentedViewController === welcome)
        try await waitUntil { !welcome.isBeingPresented }
        try await tearDown(window, docVC, nil)
    }

    /// A stand-in for UIKit's legacy title card: a `UIContentUnavailableView` with the title as its
    /// text and the primary action as its button (as in `_UIDocumentUnavailableTitleView` on the
    /// iOS 27.2 simulator), next to a browser that shows a "Lutik" folder of its own and, before
    /// the card in the search order, a look-alike card of its own (`decoy`).
    @available(iOS 18.0, *)
    private func fakeCard(title: String = "Lutik")
        -> (root: UIView, browser: UIView, card: UIContentUnavailableView, stock: UIContentUnavailableConfiguration) {
        fakeCardAndDecoy(title: title).fake
    }

    @available(iOS 18.0, *)
    private func fakeCardAndDecoy(title: String = "Lutik")
        -> (fake: (root: UIView, browser: UIView, card: UIContentUnavailableView, stock: UIContentUnavailableConfiguration),
            decoy: UIContentUnavailableView) {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let browser = UIView(frame: CGRect(x: 0, y: 700, width: 800, height: 300))
        let folder = UILabel()
        folder.text = title
        browser.addSubview(folder)
        var config = UIContentUnavailableConfiguration.empty()
        config.text = title
        config.button = .tinted()
        config.button.title = "New Archive"
        config.buttonProperties.primaryAction = UIAction(identifier: ArchiveDocumentViewController.newArchiveActionIdentifier) { _ in }
        let decoy = UIContentUnavailableView(configuration: config)
        decoy.frame = CGRect(x: 0, y: 0, width: 800, height: 700)
        browser.addSubview(decoy)
        root.addSubview(browser)
        let card = UIContentUnavailableView(configuration: config)
        card.frame = CGRect(x: 100, y: 60, width: 600, height: 700)
        root.addSubview(card)
        card.layoutIfNeeded()
        return ((root, browser, card, config), decoy)
    }

    @available(iOS 18.0, *)
    private func fittedArt(_ card: UIContentUnavailableView, height: CGFloat,
                           _ config: UIContentUnavailableConfiguration) -> CGSize? {
        LaunchCardTitle.artSize(cardHeight: height, buttonHeight: LaunchCardTitle.buttonHeight(in: card), configuration: config)
    }

    @available(iOS 18.0, *)
    private func configuration(of card: UIContentUnavailableView) throws -> UIContentUnavailableConfiguration {
        try #require(card.configuration as? UIContentUnavailableConfiguration)
    }

    /// In the card look our art (wordmark over the dog) takes the stock
    /// title's place in the card, above New Archive: the card's image, its text gone, its button
    /// as UIKit set it. The browser's own "Lutik" is never taken for the card.
    @available(iOS 18.0, *)
    @Test func cardTitleArtReplacesTheStockTitle() throws {
        let (root, browser, card, stock) = fakeCard()
        #expect(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser) === card)
        let config = try configuration(of: card)
        #expect(LaunchCardTitle.isArt(config.image))
        #expect(config.text == nil)
        #expect(config.attributedText == nil)
        #expect(config.button == stock.button)
        #expect(config.buttonProperties.primaryAction?.identifier == ArchiveDocumentViewController.newArchiveActionIdentifier)
        #expect(config.imageProperties.accessibilityIgnoresInvertColors)
        #expect(config.imageProperties.maximumSize == fittedArt(card, height: 700, stock))
        // The art reads as the title did: one "Lutik" heading.
        card.layoutIfNeeded()
        LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser)
        let imageView = try #require(card.allSubviews.compactMap { $0 as? UIImageView }
            .first { LaunchCardTitle.isArt($0.image) })
        #expect(imageView.isAccessibilityElement)
        #expect(imageView.accessibilityLabel == "Lutik")
        #expect(imageView.accessibilityTraits.contains(.header))
        // Idempotent: one keeper, the same art.
        #expect(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser) === card)
        #expect(card.subviews.filter { $0 is LaunchCardArtKeeper }.count == 1)
        #expect(try configuration(of: card).image === config.image)
    }

    /// UIKit sets the card's configuration again after ours (seen on the iOS 27.2 simulator): the
    /// art comes back on the next layout pass (not inside UIKit's own set), with UIKit's new button.
    @available(iOS 18.0, *)
    @Test func cardTitleArtSurvivesUIKitResettingTheCard() throws {
        let (root, browser, card, stock) = fakeCard()
        try #require(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser) === card)
        var reset = stock
        reset.button.title = "New Archive 2"
        card.layoutIfNeeded()
        card.configuration = reset
        #expect(try configuration(of: card) == reset)
        card.layoutIfNeeded()
        let config = try configuration(of: card)
        #expect(LaunchCardTitle.isArt(config.image))
        #expect(config.text == nil)
        #expect(config.button.title == "New Archive 2")
        #expect(config.imageProperties.maximumSize == fittedArt(card, height: 700, reset))
    }

    /// The art follows the room UIKit leaves in the card (its bottom margin covers the part under
    /// the browser sheet, as on the iPhone): smaller when the card shrinks, the stock title again
    /// without room, the art back when the room returns.
    @available(iOS 18.0, *)
    @Test func cardTitleArtFollowsTheRoomInTheCard() throws {
        let (root, browser, card, stock) = fakeCard()
        var sheeted = stock
        sheeted.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 400, trailing: 20)
        card.configuration = sheeted
        card.frame.size.height = 788
        try #require(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser) === card)
        let fitted = try #require(fittedArt(card, height: 788, sheeted))
        #expect(fitted.height < LaunchCardTitle.maxArtHeight)
        #expect(try configuration(of: card).imageProperties.maximumSize == fitted)
        card.frame.size.height = 500
        card.layoutIfNeeded()
        var config = try configuration(of: card)
        #expect(config.image == nil)
        #expect(config.text == "Lutik")
        #expect(config.button == stock.button)
        card.frame.size.height = 788
        card.layoutIfNeeded()
        config = try configuration(of: card)
        #expect(LaunchCardTitle.isArt(config.image))
        #expect(config.text == nil)
        #expect(config.imageProperties.maximumSize == fitted)
    }

    /// Fail safe: no card showing the title, or an empty title, leave the stock title as it is.
    @available(iOS 18.0, *)
    @Test func cardTitleArtLeavesTheStockTitleWithoutTheCard() throws {
        let (root, browser, card, _) = fakeCard()
        #expect(LaunchCardTitle.install(in: [root], title: "Other", excluding: browser) == nil)
        #expect(LaunchCardTitle.install(in: [root], title: "", excluding: browser) == nil)
        // The card inside the excluded view is not ours to change.
        #expect(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: root) == nil)
        let config = try configuration(of: card)
        #expect(config.text == "Lutik")
        #expect(config.image == nil)
        #expect(!card.subviews.contains { $0 is LaunchCardArtKeeper })
    }

    /// The art fills the room inside the card's margins above the button up to its cap, never
    /// squashed, and gives way to the stock title without room; the wordmark lies on the mark's.
    @available(iOS 18.0, *)
    @Test func cardArtSizeFitsTheCard() throws {
        let aspect = LaunchCardTitle.markSize.width / LaunchCardTitle.markSize.height
        var config = UIContentUnavailableConfiguration.empty()
        config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 400, trailing: 20)
        config.imageToTextPadding = 15
        config.textToButtonPadding = 36
        #expect(LaunchCardTitle.artSize(cardHeight: 2000, buttonHeight: 60, configuration: config)?.height == LaunchCardTitle.maxArtHeight)
        #expect(LaunchCardTitle.artSize(cardHeight: 0, buttonHeight: 60, configuration: config)?.height == LaunchCardTitle.maxArtHeight)
        // 788 - 20 - 400 - 15 - 36 - the button.
        let size = try #require(LaunchCardTitle.artSize(cardHeight: 788, buttonHeight: 60, configuration: config))
        let room: CGFloat = 317
        #expect(size.height == room - 60)
        #expect(LaunchCardTitle.artSize(cardHeight: 788, buttonHeight: 100, configuration: config)?.height == room - 100)
        #expect(abs(size.width / size.height - aspect) < 0.01)
        #expect(LaunchCardTitle.artSize(cardHeight: 500, buttonHeight: 60, configuration: config) == nil)
        let mark = CGRect(origin: .zero, size: LaunchCardTitle.markSize)
        #expect(mark.contains(LaunchCardTitle.wordmarkRect))
        let art = try #require(LaunchCardTitle.artImage)
        #expect(art.size.height == LaunchCardTitle.maxArtHeight)
        #expect(UIImage(named: LaunchCardTitle.wordmarkAssetName)?.renderingMode == .alwaysTemplate)
        // The dog alone, in the mark's frame, drawn over the wordmark.
        let dog = try #require(UIImage(named: LaunchCardTitle.dogAssetName))
        #expect(abs(dog.size.width / dog.size.height - aspect) < 0.005)
    }

    /// Only the card look puts the art in; the art look keeps its own title view untouched.
    @available(iOS 18.0, *)
    @Test(arguments: [LaunchLook.art, .card])
    func onlyTheCardLookGetsTheCardArt(look: LaunchLook) throws {
        let (_, docVC) = try loadedLaunchRoot(look: look)
        let (_, _, card, _) = fakeCard(title: ArchiveDocumentViewController.appDisplayName() ?? "Lutik")
        docVC.view.insertSubview(card, at: 0)
        let found = docVC.installCardTitleArt()
        #expect((found != nil) == (look == .card))
        let config = try configuration(of: card)
        #expect(LaunchCardTitle.isArt(config.image) == (look == .card))
        #expect((config.text == nil) == (look == .card))
    }

    /// UIKit keeps the launch view out of the controller's `view.subviews` (iOS 27.2 simulator):
    /// a card reachable only through a child controller's view still gets the art.
    @available(iOS 18.0, *)
    @Test func cardArtFindsTheCardInAChildControllersView() throws {
        let (_, docVC) = try loadedLaunchRoot(look: .card)
        let (_, _, card, _) = fakeCard(title: ArchiveDocumentViewController.appDisplayName() ?? "Lutik")
        let child = UIViewController()
        child.view.addSubview(card)
        docVC.addChild(child)
        defer { child.removeFromParent() }
        #expect(try #require(docVC.installCardTitleArt()) === card)
    }

    /// The card kept from an earlier pass is never used once it sits in the
    /// browser (the search excludes the browser; the kept card must too).
    @available(iOS 18.0, *)
    @Test func keptCardArtNeverWalksIntoTheBrowser() throws {
        let (_, docVC) = try loadedLaunchRoot(look: .card)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.addSubview(docVC.view)
        window.isHidden = false
        let (_, _, card, _) = fakeCard(title: ArchiveDocumentViewController.appDisplayName() ?? "Lutik")
        docVC.view.insertSubview(card, at: 0)
        #expect(try #require(docVC.installCardTitleArt()) === card)
        let browserView = try #require(docVC.launchOptions.browserViewController.view)
        if !browserView.isDescendant(of: docVC.view) { docVC.view.addSubview(browserView) }
        browserView.addSubview(card)
        #expect(card.window != nil)
        #expect(docVC.installCardTitleArt() == nil)
    }

    /// The browser's own look-alike card ("Lutik" with New Archive, found first in subview order)
    /// is never taken for the title card: it stays as it is and the real card gets the art.
    @available(iOS 18.0, *)
    @Test func cardArtNeverWalksIntoTheBrowser() throws {
        let ((root, browser, card, stock), decoy) = fakeCardAndDecoy()
        #expect(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser) === card)
        #expect(LaunchCardTitle.isArt(try configuration(of: card).image))
        let untouched = try configuration(of: decoy)
        #expect(untouched == stock)
        #expect(!decoy.subviews.contains { $0 is LaunchCardArtKeeper })
    }

    /// Should the card's height follow its content (as it may on iOS 18 to 26), the art must not
    /// shrink pass after pass down to the stock title: it settles at one size within two changes.
    @available(iOS 18.0, *)
    @Test func cardArtSettlesInACardSizedToItsContent() throws {
        let (root, browser, card, _) = fakeCard()
        card.frame.size.height = 0
        try #require(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser) === card)
        var config = try configuration(of: card)
        let margins = config.directionalLayoutMargins
        // The card without its image: 9 pt short of the room it gives the art.
        let base = margins.top + margins.bottom + LaunchCardTitle.buttonHeight(in: card)
            + config.imageToTextPadding + config.textToButtonPadding - 9
        var sizes: [CGFloat] = []
        for _ in 0..<8 {
            config = try configuration(of: card)
            sizes.append(LaunchCardTitle.showsArt(config) ? config.imageProperties.maximumSize.height : 0)
            card.frame.size.height = base + (LaunchCardTitle.showsArt(config) ? config.imageProperties.maximumSize.height : 30)
            card.layoutIfNeeded()
        }
        let changes = zip(sizes, sizes.dropFirst()).filter { $0 != $1 }.count
        #expect(changes <= 1, "art sizes: \(sizes)")
        #expect(Set(sizes.suffix(5)).count == 1, "art sizes: \(sizes)")
        #expect(try #require(sizes.last) >= LaunchCardTitle.minArtHeight, "fell back to the text: \(sizes)")
    }

    /// The sizing's memory: a height change that is exactly our own change keeps the art; a
    /// change in a fixed card is followed (smaller, the stock title, back again).
    @Test func cardArtSizingTellsItsOwnChangesFromTheCards() {
        var sizing = LaunchCardArtSizing()
        // Not laid out: the cap; then the card grows by the art and gives 9 pt less room.
        #expect(sizing.decide(cardHeight: 0, current: 0, fitted: 320) == 320)
        #expect(sizing.decide(cardHeight: 600, current: 320, fitted: 311) == 311)
        #expect(sizing.decide(cardHeight: 591, current: 311, fitted: 302) == 311)
        #expect(sizing.decide(cardHeight: 591, current: 311, fitted: 302) == 311)
        // A fixed card: what fits is shown.
        var fixed = LaunchCardArtSizing()
        #expect(fixed.decide(cardHeight: 788, current: 0, fitted: 250) == 250)
        #expect(fixed.decide(cardHeight: 500, current: 250, fitted: 0) == 0)
        #expect(fixed.decide(cardHeight: 788, current: 0, fitted: 250) == 250)
        #expect(fixed.decide(cardHeight: 788, current: 250, fitted: 250) == 250)
    }

    /// Once settled, a card height that happens to differ by our last change (a
    /// rotation) is the card's own change and re-fits; so does a later card about as tall as the
    /// cap after a pass at height 0; a hold lasts only while the card keeps the height held at.
    @Test func cardArtSizingNeverFreezesAtAStaleSize() {
        var rotated = LaunchCardArtSizing()
        #expect(rotated.decide(cardHeight: 0, current: 0, fitted: 320) == 320)
        #expect(rotated.decide(cardHeight: 600, current: 320, fitted: 250) == 250)
        #expect(rotated.decide(cardHeight: 600, current: 250, fitted: 250) == 250)
        #expect(rotated.decide(cardHeight: 530, current: 250, fitted: 180) == 180)
        #expect(rotated.decide(cardHeight: 530, current: 180, fitted: 180) == 180)

        var capped = LaunchCardArtSizing()
        #expect(capped.decide(cardHeight: 0, current: 0, fitted: 320) == 320)
        #expect(capped.decide(cardHeight: 0, current: 320, fitted: 320) == 320)
        #expect(capped.decide(cardHeight: 320, current: 320, fitted: 200) == 200)

        var held = LaunchCardArtSizing()
        #expect(held.decide(cardHeight: 0, current: 0, fitted: 320) == 320)
        #expect(held.decide(cardHeight: 600, current: 320, fitted: 311) == 311)
        #expect(held.decide(cardHeight: 591, current: 311, fitted: 302) == 311)
        #expect(held.decide(cardHeight: 591, current: 311, fitted: 302) == 311)
        #expect(held.decide(cardHeight: 600, current: 311, fitted: 311) == 311)
        #expect(held.decide(cardHeight: 591, current: 311, fitted: 302) == 302)
    }

    /// A shrink between the first two passes larger than our own change (a
    /// rotation, with no pass after it) re-fits at once instead of holding the larger art.
    @Test func cardArtSizingFollowsAnOutsideShrinkBeforeSettling() {
        var sizing = LaunchCardArtSizing()
        #expect(sizing.decide(cardHeight: 0, current: 0, fitted: 320) == 320)
        #expect(sizing.decide(cardHeight: 600, current: 320, fitted: 250) == 250)
        #expect(sizing.decide(cardHeight: 500, current: 250, fitted: 130) == 130)
        // A card growing while our last change shrank the art is not ours either.
        var grown = LaunchCardArtSizing()
        #expect(grown.decide(cardHeight: 0, current: 0, fitted: 320) == 320)
        #expect(grown.decide(cardHeight: 600, current: 320, fitted: 311) == 311)
        #expect(grown.decide(cardHeight: 620, current: 311, fitted: 300) == 300)
    }

    /// At accessibility text sizes New Archive grows: the art gets smaller or gives way to the
    /// stock title, never more than the room left above the button.
    @available(iOS 18.0, *)
    @Test func cardArtMakesRoomForALargerButton() throws {
        var sheeted = fakeCard().stock
        sheeted.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 400, trailing: 20)
        // In a window: the text size reaches the card's button only through the trait hierarchy.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var windows: [UIWindow] = []
        defer { windows.forEach { $0.isHidden = true } }
        func installed(_ category: UIContentSizeCategory?) throws -> (UIContentUnavailableView, CGFloat?) {
            let (root, browser, card, _) = fakeCard()
            let window = UIWindow(windowScene: scene)
            window.frame = root.frame
            window.addSubview(root)
            window.isHidden = false
            windows.append(window)
            if let category { card.traitOverrides.preferredContentSizeCategory = category }
            card.configuration = sheeted
            card.frame.size.height = 788
            card.updateTraitsIfNeeded()
            card.layoutIfNeeded()
            try #require(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser) === card)
            card.layoutIfNeeded()
            let config = try configuration(of: card)
            return (card, LaunchCardTitle.showsArt(config) ? config.imageProperties.maximumSize.height : nil)
        }
        let (regularCard, regular) = try installed(nil)
        let (largeCard, large) = try installed(.accessibilityExtraExtraExtraLarge)
        let regularButton = LaunchCardTitle.buttonHeight(in: regularCard)
        let largeButton = LaunchCardTitle.buttonHeight(in: largeCard)
        #expect(largeButton > regularButton)
        let regularArt = try #require(regular)
        if let large {
            #expect(large < regularArt)
            #expect(large <= 788 - 20 - 400 - largeButton - sheeted.imageToTextPadding - sheeted.textToButtonPadding)
        } else {
            #expect(try configuration(of: largeCard).text == "Lutik")
        }
        // The text size changing under a card with the art: the art makes room at once.
        regularCard.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        regularCard.updateTraitsIfNeeded()
        regularCard.layoutIfNeeded()
        let changed = try configuration(of: regularCard)
        if LaunchCardTitle.showsArt(changed) {
            #expect(changed.imageProperties.maximumSize.height < regularArt)
        } else {
            #expect(changed.text == "Lutik")
        }
    }

    /// VoiceOver reads the art as the title: the card's image view is the "Lutik" heading even
    /// when it holds a copy of the art, put back on every pass.
    @available(iOS 18.0, *)
    @Test func cardArtImageViewStaysTheHeading() throws {
        let (root, browser, card, _) = fakeCard()
        try #require(LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser) === card)
        card.layoutIfNeeded()
        LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser)
        let imageView = try #require(LaunchCardTitle.artImageView(in: card))
        let art = try #require(LaunchCardTitle.artImage?.cgImage)
        imageView.image = UIImage(cgImage: art)
        imageView.accessibilityLabel = nil
        imageView.accessibilityTraits = .none
        LaunchCardTitle.install(in: [root], title: "Lutik", excluding: browser)
        let labelled = try #require(LaunchCardTitle.artImageView(in: card))
        #expect(labelled.isAccessibilityElement)
        #expect(labelled.accessibilityLabel == "Lutik")
        #expect(labelled.accessibilityTraits.contains(.header))
        #expect(!(labelled.superview is UIButton))
    }

    /// With a document open the card is left alone.
    @available(iOS 18.0, *)
    @Test func cardArtWaitsWhileADocumentIsOpen() async throws {
        let (_, docVC) = try loadedLaunchRoot(look: .card)
        let (_, _, card, stock) = fakeCard(title: ArchiveDocumentViewController.appDisplayName() ?? "Lutik")
        docVC.view.insertSubview(card, at: 0)
        let document = ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip"))
        #expect(await document.openOnMain())
        docVC.document = document
        #expect(docVC.installCardTitleArt() == nil)
        #expect(try configuration(of: card) == stock)
        #expect(!card.subviews.contains { $0 is LaunchCardArtKeeper })
        docVC.document = nil
        // The controller closes the document it let go of.
        await document.closedByController()
    }

    /// The launch header's content-shown moment reaches the controller's hook.
    @available(iOS 18.0, *)
    @Test(arguments: [LaunchLook.art, .card])
    func launchHeaderReportsToTheController(look: LaunchLook) throws {
        let (_, docVC) = try loadedLaunchRoot(look: look)
        var shown = 0
        docVC.onLaunchContentShown = { shown += 1 }
        let header = try #require(docVC.launchOptions.backgroundAccessoryView as? LaunchHeaderView)
        header.onContentShown?()
        #expect(shown == 1)
    }
}

private extension UIView {
    /// Every view under this one, depth-first.
    var allSubviews: [UIView] { subviews.flatMap { [$0] + $0.allSubviews } }
}
