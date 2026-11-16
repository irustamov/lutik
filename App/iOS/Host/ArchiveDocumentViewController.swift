import SwiftUI
import UIKit

/// The archive's folders. The root folder is a child sharing this controller's navigation item;
/// deeper folders are pushed onto the navigation controller.
/// iOS 18+: the window's root (`makeLaunchNavigation`), showing the system launch view while no
/// document is open. iOS 17: presented full screen over the window's
/// `DocumentBrowserController` with its document set; a close takes it off screen before the
/// document goes (`closeDocument`).
final class ArchiveDocumentViewController: UIDocumentViewController {
    /// The open document's state; nil without one. Internal so tests can stand in for `documentDidOpen`.
    var screenState: ScreenState?
    /// The root level's Undo, Redo and Save.
    private var rootEditItems: TrailingEditItems?

    private lazy var rootHost: ChromeHostingController<AnyView> = {
        let host = ChromeHostingController(rootView: AnyView(EmptyView()))
        host.onToolbarItemsChange = { [weak self] items, animated in
            self?.forwardToolbar(items, animated: animated)
        }
        return host
    }()

    /// The root folder's SwiftUI chrome and UIDocumentViewController's document bar share it.
    override var navigationItem: UINavigationItem { rootHost.navigationItem }

    /// The name alert's own while it is up (`ScreenState.renameUndoManager`), else the document's.
    override var undoManager: UndoManager? { screenState?.renameUndoManager ?? super.undoManager }

    /// iOS 18+: the window's root, which shows the system launch view while it has no document.
    /// Back (`closeDocument`) empties it in place. False when the iOS 17 browser presents it.
    private(set) var showsLaunchView = false

    /// iOS 18+: which launch title view UIKit draws (`LaunchLook`); tests pass either.
    private(set) var launchLook = LaunchLook.current

    /// The card look's title card last found (`installCardTitleArt`).
    private weak var cardTitleCard: UIContentUnavailableView?

    /// iOS 18+: the window's root, with no document (the launch view) and large titles.
    @available(iOS 18.0, *)
    static func makeLaunchNavigation(session: UISceneSession?,
                                     look: LaunchLook = .current) -> ArchiveNavigationController {
        let docVC = ArchiveDocumentViewController(document: nil)
        docVC.showsLaunchView = true
        docVC.launchLook = look
        docVC.sceneSession = session
        // A bare root has no navigation bar.
        let nav = ArchiveNavigationController(rootViewController: docVC)
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 18.0, *), showsLaunchView {
            configureLaunchOptions()
        }
        installBackAction()
    }

    /// The launch view, with the system browser below. `.art`: the Lutik art with New Archive on
    /// it and no stock title or button: the art carries the
    /// name. `.card` (UIKit's legacy title card): the app's name and New Archive in the card, the
    /// gradient behind it.
    @available(iOS 18.0, *)
    private func configureLaunchOptions() {
        // The stock create action does nothing from a button of ours (only from the stock card's):
        // New Archive runs the browser's flow itself (`createNewArchive`), in either look.
        let newArchive = UIAction(title: String(localized: "New Archive"),
                                  identifier: Self.newArchiveActionIdentifier) { [weak self] _ in
            self?.createNewArchive()
        }
        switch launchLook {
        case .art:
            launchOptions.title = ""
            launchOptions.primaryAction = nil
            LaunchHeader.install(in: launchOptions, newArchive: newArchive) { [weak self] in
                self?.onLaunchContentShown?()
            }
        case .card:
            // Without a name UIKit's default title stays (the property is not optional in Swift).
            if let name = Self.appDisplayName() { launchOptions.title = name }
            launchOptions.primaryAction = newArchive
            LaunchHeader.install(in: launchOptions, look: .card) { [weak self] in
                self?.onLaunchContentShown?()
            }
        }
        let browser = launchOptions.browserViewController
        browser.allowsDocumentCreation = true
        browser.localizedCreateDocumentActionTitle = String(localized: "New Archive")
        // Creation needs the delegate. Picked documents still open through UIDocumentViewController;
        // imported (new) ones open in `didImportDocumentAt`.
        browser.delegate = self
        browser.additionalTrailingNavigationBarButtonItems = [
            Acknowledgements.barButtonItem(presentingFrom: browser),
        ]
    }

    static let newArchiveActionIdentifier = UIAction.Identifier("LaunchNewArchive")

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if #available(iOS 18.0, *) { installCardTitleArt() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if #available(iOS 18.0, *) { installCardTitleArt() }
    }

    /// `.card` only, while the launch view shows: our art in place of the card's text title
    /// (`LaunchCardTitle`); the stock title stays when the card is not
    /// found. Nil in the art look. The card found is kept (weakly) and searched for again only
    /// once it left the window or the launch view, as this runs on every layout pass.
    @available(iOS 18.0, *)
    @discardableResult
    func installCardTitleArt() -> UIContentUnavailableView? {
        let title: String? = launchOptions.title
        guard showsLaunchView, launchLook == .card, document == nil, let title else { return nil }
        // The launch view is a child's view that UIKit keeps out of `view.subviews`.
        let roots = [view!] + children.compactMap(\.viewIfLoaded)
        let browser = launchOptions.browserViewController.viewIfLoaded
        if let card = cardTitleCard, card.window != nil,
           roots.contains(where: { card.isDescendant(of: $0) }),
           !(browser.map { card.isDescendant(of: $0) } ?? false),
           let kept = LaunchCardTitle.install(on: card, title: title) {
            return kept
        }
        let card = LaunchCardTitle.install(in: roots, title: title, excluding: browser)
        cardTitleCard = card
        return card
    }

    /// The card's title: the app's (localized) display name from the built Info.plist, so the
    /// product name lives in one place (no name literal in code).
    /// Nil without one: UIKit's default title then stays, not an empty one.
    static func appDisplayName(in bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    }

    /// Where New Archive on the art puts new archives: the app's Documents, which the launch
    /// browser shows (On My iPhone/iPad). Settable for tests.
    var newArchiveFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// New Archive on the art: the browser's options sheet and empty archive
    /// (`documentBrowser(_:didRequestDocumentCreationWithHandler:)`), imported here.
    @available(iOS 18.0, *)
    func createNewArchive() {
        // Cancel, or a failed write: (nil, .none), and nothing to import.
        NewArchiveFlow.present(from: self) { [weak self] url, mode in
            guard let self, let url, mode != .none else { return }
            self.importNewArchive(url)
        }
    }

    /// Moves the new archive at `source` into `newArchiveFolder` under a free name ("Untitled
    /// 2.zip"), as the browser's import does, then hands it on as the browser would: it opens in
    /// place (`didImportDocumentAt`), or its failure is shown (`failedToImportDocumentAt`).
    @available(iOS 18.0, *)
    func importNewArchive(_ source: URL) {
        let browser = launchOptions.browserViewController
        let fileManager = FileManager.default
        // "Untitled.tar.gz": the name up to its first dot is the base, the rest the extension.
        let name = source.lastPathComponent
        let dot = name.firstIndex(of: ".") ?? name.endIndex
        let ext = dot < name.endIndex ? String(name[name.index(after: dot)...]) : ""
        do {
            let taken = Set(try fileManager.contentsOfDirectory(atPath: newArchiveFolder.path))
            let free = ext.isEmpty ? name
                : CompressPlan.uniqueName(String(name[..<dot]), extension: ext, existingNames: taken)
            let destination = newArchiveFolder.appendingPathComponent(free)
            try fileManager.moveItem(at: source, to: destination)
            documentBrowser(browser, didImportDocumentAt: source, toDestinationURL: destination)
        } catch {
            documentBrowser(browser, failedToImportDocumentAt: source, error: error)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if screenState != nil {
            navigationController?.setToolbarHidden(toolbarItems?.isEmpty ?? true, animated: animated)
        }
    }

    /// iOS 18+: called once, the first time the launch view is shown in an active scene
    /// (`LaunchHeaderView.onContentShown`): `SceneDelegate`'s Welcome sheet.
    var onLaunchContentShown: (() -> Void)?

    /// iOS 18+: the Welcome sheet over the launch view, set by `SceneDelegate` when it presents
    /// it: a document arriving takes it away (`dismissWelcomeSheet`).
    weak var welcomeSheet: UIViewController?

    /// A document is to show here (Open In, a URL): the Welcome sheet, if up, goes away with the
    /// stock animation, as over the iOS 17 browser (`DocumentBrowserController.present`). One still
    /// on its way up is taken away once it is up (UIKit would drop the dismissal).
    private func dismissWelcomeSheet(retries: Int = 20) {
        guard let sheet = welcomeSheet, sheet.presentingViewController != nil, !sheet.isBeingDismissed else { return }
        guard sheet.isBeingPresented || sheet.viewIfLoaded?.window == nil else {
            sheet.dismiss(animated: true)
            return
        }
        guard retries > 0 else { return }
        if let coordinator = sheet.transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
               self?.dismissWelcomeSheet(retries: retries - 1)
           }) {
            return
        }
        // No transition yet (UIKit starts it a moment after the present), or one that won't call back.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.dismissWelcomeSheet(retries: retries - 1)
        }
    }

    /// The window's scene session, set by whoever puts this controller on screen. Each document
    /// it shows is in `OpenDocuments` under this session.
    weak var sceneSession: UISceneSession?

    /// Every document the window shows comes through here: the launch browser's pick, Open In
    /// (`SceneDelegate.open`; iOS 17: `DocumentBrowserController.present`), a new archive, and nil
    /// on close (`closeDocument`). A file another window already shows brings that window forward
    /// instead, and this one keeps what it had.
    override var document: UIDocument? {
        get { super.document }
        set {
            let old = super.document
            guard newValue !== old else {
                super.document = newValue
                return
            }
            if let newValue, OpenDocuments.activateWindow(showing: newValue.fileURL, from: sceneSession) { return }
            if newValue != nil { dismissWelcomeSheet() }
            // The shown document's Text Encoding reopen and conflict questions end with it, now: on a
            // swap its content goes only once the new document has opened, or never if that fails. Its
            // progress sheet's fallback stays until the content goes (`removeContent`): should the open
            // fail, the content stays, and a lost dismissal must still be taken as gone.
            screenState?.cancelNameEncoding()
            screenState?.cancelExtraction()
            // Extract Here's waiting hand-off would otherwise move the old document's request on to its
            // Files picker after the swap.
            screenState?.cancelExtractHere()
            if let old {
                // UIDocumentViewController closes the old document on its background queue, and
                // UIDocument's close takes the document out of UIKit's user-activity registry there,
                // while the setter goes on to take this controller out of the same entry here: the
                // registry's table could be mutated while being enumerated (NSGenericException, seen
                // on close). Both leave it on the main thread first; the close then finds no activity.
                userActivity = nil
                old.userActivity = nil
            }
            super.document = newValue
            if let old {
                // The old document's close (UIDocumentViewController's) may still save: its entry
                // stays until it reports closed, and a new document on its file waits for that.
                let sessionID = sceneSession?.persistentIdentifier
                OpenDocuments.trackClosing(old) { old in
                    if let sessionID {
                        // Only the old document's own entry: never one the window registered since.
                        OpenDocuments.forget(sessionID: sessionID, document: old)
                    } else {
                        OpenDocuments.forget(old.fileURL)
                    }
                }
            }
            if let newValue, let sceneSession {
                OpenDocuments.register(newValue.fileURL, session: sceneSession, document: newValue)
            }
            if newValue == nil { removeContent() }
        }
    }

    /// Set by the iOS 17 browser that presents this controller: takes it off screen, then calls
    /// the handler it is given. Nil (the launch view's root): the document goes at once, and the
    /// launch view comes back in place.
    var dismissHandler: ((@escaping @MainActor () -> Void) -> Void)?

    /// A close is on its way: the controller is going off screen, its document goes after.
    private(set) var isClosing = false

    /// Back chevron, ⌘W, Cancel on the password prompt, OK on a failed open: back to the launch
    /// view (iOS 17: the browser).
    func closeDocument() {
        guard document != nil, !isClosing else { return }
        guard let dismissHandler else {
            document = nil
            return
        }
        isClosing = true
        // Strong: the one-shot completion must clear the document (and its window's entry) even
        // when the navigation controller holding this controller is released first.
        dismissHandler {
            self.isClosing = false
            self.document = nil
        }
    }

    /// The browser couldn't take this controller off screen: the document stays, and a later
    /// close tries again.
    func closeAborted() { isClosing = false }

    /// iOS 17: the back chevron at the root, which closes the archive presented over the browser.
    /// The document bar shows a back button only when the item has a back action (editor style);
    /// the system's would empty this controller in place. The launch view's root keeps the
    /// system's, which does just that.
    private(set) lazy var backAction = UIAction { [weak self] _ in self?.closeDocument() }

    private func installBackAction() {
        guard !showsLaunchView else { return }
        if navigationItem.backAction !== backAction { navigationItem.backAction = backAction }
    }

    override func documentDidOpen() {
        super.documentDidOpen()
        guard let document = document as? ArchiveDocument else { return }
        installContent(for: document)
    }

    override func navigationItemDidUpdate() {
        super.navigationItemDidUpdate()
        // The system undo/redo group would overflow into "More" on iPhone; TrailingEditItems
        // pins Undo and Redo instead. UIKit doesn't place the group itself; keep it out anyway.
        undoRedoItemGroup.isHidden = true
        if navigationItem.trailingItemGroups.contains(where: { $0 === undoRedoItemGroup }) {
            navigationItem.trailingItemGroups.removeAll { $0 === undoRedoItemGroup }
        }
        rootEditItems?.update()
        installBackAction()
    }

    // MARK: - Content

    private func installContent(for document: ArchiveDocument) {
        removeContent()
        let state = ScreenState(document: document)
        state.openFolder = { [weak self] path in self?.pushFolder(at: path) }
        state.closeDocument = { [weak self] in self?.closeDocument() }
        state.closeUnlistedFolders = { [weak self] in self?.popUnlistedFolders() }
        screenState = state
        archiveNavigationController?.screenState = state
        rootHost.rootView = AnyView(FolderScreen(state: state, path: "", isRoot: true))
        addChild(rootHost)
        rootHost.view.frame = view.bounds
        rootHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(rootHost.view)
        rootHost.didMove(toParent: self)
        rootEditItems = TrailingEditItems(state: state, navigationItem: navigationItem)
    }

    /// On iPad a pushed level's bar is laid out as at the root, whose editor style comes from
    /// UIDocumentViewController: leading title, and Select and Save a Copy… in the centre, which
    /// UIKit folds into "More" when there's no room. Browser style does the same and keeps the
    /// back button's title; the default navigator style would always put them in "More".
    /// The title is inline, as at the root. iPhone keeps navigator.
    private func pushFolder(at path: String) {
        guard let screenState else { return }
        let host = FolderHostingController(state: screenState, path: path)
        if traitCollection.userInterfaceIdiom == .pad {
            host.navigationItem.style = .browser
            host.navigationItem.largeTitleDisplayMode = .never
        }
        navigationController?.pushViewController(host, animated: true)
    }

    /// Pops the folder levels whose folders the archive no longer lists (Text Encoding renamed them, an
    /// undo or redo took them away).
    private func popUnlistedFolders() {
        guard let navigationController, let model = screenState?.model else { return }
        let levels = navigationController.viewControllers
        let kept = FolderHostingController.listedLevels(levels, in: model)
        if kept.count != levels.count { navigationController.setViewControllers(kept, animated: true) }
    }

    /// The document has gone. SwiftUI's search and bar items would otherwise stay in the shared
    /// navigation item, with the search bar on top of the next document.
    private func removeContent() {
        screenState?.cancelNameEncoding()
        // A conflict question's hand-off waiting to run would ask or extract after the close; the
        // progress sheet's fallback would present what waited for the sheet.
        screenState?.cancelExtraction()
        // Extract Here's hand-off waiting for its alert would bring up the Files picker after the close.
        screenState?.cancelExtractHere()
        screenState?.cancelProgressSheetFallback()
        // The Move sheet, a confirmed move or a Replace question for a move would act on the next document.
        screenState?.cancelPendingMove()
        screenState = nil
        archiveNavigationController?.screenState = nil
        rootEditItems = nil
        navigationItem.pinnedTrailingGroup = nil
        navigationController?.popToRootViewController(animated: false)
        guard rootHost.parent != nil else { return }
        rootHost.rootView = AnyView(EmptyView())
        navigationItem.searchController = nil
        setToolbarItems(nil, animated: false)
        navigationController?.setToolbarHidden(true, animated: false)
        rootHost.willMove(toParent: nil)
        rootHost.view.removeFromSuperview()
        rootHost.removeFromParent()
    }

    private var archiveNavigationController: ArchiveNavigationController? {
        navigationController as? ArchiveNavigationController
    }

    /// With a document open, Undo and Redo go on up to `ArchiveNavigationController`, which
    /// refuses them while a save writes. UIDocumentViewController's own would undo anyway.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if screenState != nil, action == #selector(ArchiveNavigationController.undo(_:))
            || action == #selector(ArchiveNavigationController.redo(_:)) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    private func forwardToolbar(_ items: [UIBarButtonItem]?, animated: Bool) {
        setToolbarItems(items, animated: animated)
        if navigationController?.topViewController === self {
            navigationController?.setToolbarHidden(items?.isEmpty ?? true, animated: animated)
        }
    }
}

/// iOS 18+: the launch view's browser. New Archive's sheet, and the new archive opening in place.
extension ArchiveDocumentViewController: @preconcurrency UIDocumentBrowserViewControllerDelegate {
    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping
                         (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        NewArchiveFlow.present(from: controller, importHandler: importHandler)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL,
                         toDestinationURL destinationURL: URL) {
        NewArchiveFlow.didImport(from: sourceURL, to: destinationURL)
        // With a delegate set, the launch browser leaves opening the imported file to it.
        navigationController?.popToRootViewController(animated: false)
        document = ArchiveDocument(fileURL: destinationURL)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL,
                         error: (any Error)?) {
        NewArchiveFlow.didFailToImport(documentURL, error: error, presenter: controller)
    }
}

/// A pushed folder level; keeps its Undo, Redo and Save alive.
final class FolderHostingController: UIHostingController<FolderScreen> {
    private var editItems: TrailingEditItems?

    init(state: ScreenState, path: String) {
        super.init(rootView: FolderScreen(state: state, path: path, isRoot: false))
        editItems = TrailingEditItems(state: state, navigationItem: navigationItem)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The archive path of this level's folder.
    var path: String { rootView.path }

    /// `levels` up to the first folder level whose folder `model` no longer lists: that level goes,
    /// and so does every level above it, which was reached through it.
    static func listedLevels(_ levels: [UIViewController], in model: ArchiveModel) -> [UIViewController] {
        let unlisted = levels.firstIndex { level in
            (level as? FolderHostingController).map { model.item(at: $0.path)?.isDirectory != true } ?? false
        }
        return Array(levels[..<(unlisted ?? levels.endIndex)])
    }

    /// The document's, as at the root: the system's undo (Edit menu, gestures) reaches this
    /// level's edits. The name alert's own while it is up (`ScreenState.renameUndoManager`).
    override var undoManager: UndoManager? { rootView.state.responderUndoManager }
}
