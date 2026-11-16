import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Kernir

/// The window's root, a full-screen document browser, and how
/// a window routes the files it is asked to open.
@MainActor @Suite struct DocumentBrowserTests {
    /// The browser offers exactly the types the app declares as documents in Info.plist.
    @Test func contentTypesAreTheDeclaredDocumentTypes() {
        let declared = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        let offered = DocumentBrowserController.contentTypes.map(\.identifier)
        #expect(!offered.isEmpty)
        #expect(Set(offered) == Set(declared))
        #expect(Set(offered).count == offered.count, "duplicate types: \(offered)")
    }

    @Test func browserCreatesArchivesAndHasADelegate() {
        let browser = DocumentBrowserController()
        #expect(browser.allowsDocumentCreation)
        #expect(browser.localizedCreateDocumentActionTitle == String(localized: "New Archive"))
        #expect(browser.delegate === browser)
        #expect(browser.presentedDocument == nil)
    }

    /// A document comes up full screen over the browser, in the archive window's navigation
    /// controller, with the document set (no launch view).
    @Test func documentNavigationIsFullScreenWithTheDocument() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("browser-\(UUID().uuidString).zip")
        let nav = DocumentBrowserController.makeDocumentNavigation(for: url, session: nil)
        #expect(nav.modalPresentationStyle == .fullScreen)
        let docVC = try #require(nav.viewControllers.first as? ArchiveDocumentViewController)
        #expect(docVC.document?.fileURL == url)
    }

    /// Closing takes the controller off screen first and lets the document go once that is done:
    /// a `UIDocumentViewController` without a document shows the system launch view.
    @Test func closeDismissesBeforeTheDocumentGoes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("close-\(UUID().uuidString).zip")
        let docVC = ArchiveDocumentViewController(document: nil)
        docVC.document = ArchiveDocument(fileURL: url)
        var finish: (@MainActor () -> Void)?
        docVC.dismissHandler = { done in finish = done }

        docVC.closeDocument()
        #expect(docVC.document != nil, "the document went before the dismissal finished")
        let done = try #require(finish, "closeDocument didn't ask to be dismissed")
        done()
        #expect(docVC.document == nil)
    }

    /// With no presenter (`dismissHandler` nil) the document goes at once.
    @Test func closeWithoutPresenterClearsTheDocument() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("close-\(UUID().uuidString).zip")
        let docVC = ArchiveDocumentViewController(document: nil)
        docVC.document = ArchiveDocument(fileURL: url)
        docVC.closeDocument()
        #expect(docVC.document == nil)
    }

    // MARK: - Routing

    @Test func routesFirstHereAndTheRestToNewWindows() throws {
        let a = URL(fileURLWithPath: "/r/a.zip"), b = URL(fileURLWithPath: "/r/b.zip"), c = URL(fileURLWithPath: "/r/c.7z")
        let route = try #require(WindowOpenRoute(urls: [a, b, c]))
        #expect(route.here == a)
        #expect(route.newWindows == [b, c])
    }

    @Test func routeDropsDuplicates() throws {
        let a = URL(fileURLWithPath: "/r/a.zip")
        let route = try #require(WindowOpenRoute(urls: [a, URL(fileURLWithPath: "/r/./a.zip"), URL(fileURLWithPath: "/r/x/../a.zip")]))
        #expect(route.here == a)
        #expect(route.newWindows.isEmpty)
    }

    @Test func noURLsNoRoute() {
        #expect(WindowOpenRoute(urls: []) == nil)
    }

    /// Launch: the files the scene was connected with (Files' Open In, a new window's hand-off)
    /// win over the DEBUG fixture, which is only asked for when there are none.
    @Test func launchFilesWinOverTheFixture() {
        let given = URL(fileURLWithPath: "/r/given.zip")
        var askedForFixture = false
        let urls = WindowOpenRoute.launchURLs(given: [given]) { askedForFixture = true; return URL(fileURLWithPath: "/f.zip") }
        #expect(urls == [given])
        #expect(!askedForFixture, "the fixture hook ran (and used up its one go) although files were given")

        let fixture = URL(fileURLWithPath: "/r/fixture.zip")
        #expect(WindowOpenRoute.launchURLs(given: []) { fixture } == [fixture])
        #expect(WindowOpenRoute.launchURLs(given: []) { nil }.isEmpty)
    }
}
