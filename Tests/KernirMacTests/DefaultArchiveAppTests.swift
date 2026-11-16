#if os(macOS)
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Kernir

/// "Make <app> the default app for archives" (DefaultArchiveApp) over a fake NSWorkspace.
@MainActor
struct DefaultArchiveAppTests {
    private static let app = URL(fileURLWithPath: "/Applications/Lutik.app", isDirectory: true)
    private static let other = URL(fileURLWithPath: "/Applications/Other.app", isDirectory: true)
    private static let bundleID = "io.lutik.test"

    @MainActor
    final class FakeWorkspace: DefaultAppWorkspace {
        var handlers: [String: URL] = [:]
        /// Identifiers whose change throws this error.
        var errors: [String: Error] = [:]
        private(set) var asked: [String] = []
        /// What a fresh process (Finder) sees, by identifier; nil = it can't tell.
        var finder: [String: Bool]?
        /// The identifiers each fresh-process check asked about.
        private(set) var finderChecks: [[String]] = []

        func urlForApplication(toOpen contentType: UTType) -> URL? { handlers[contentType.identifier] }

        func handlersSeenByFinder(bundleIdentifier: String, types: [String]) async -> [String: Bool]? {
            finderChecks.append(types)
            return finder?.filter { types.contains($0.key) }
        }

        func setDefaultApplication(at applicationURL: URL, toOpen contentType: UTType) async throws {
            asked.append(contentType.identifier)
            if let error = errors[contentType.identifier] { throw error }
            handlers[contentType.identifier] = applicationURL
        }
    }

    private func type(_ identifier: String) -> UTType { UTType(identifier) ?? UTType(importedAs: identifier) }

    /// Only archives are claimed: no catch-all, folder, own drag type, split part or developer package.
    @Test func claimsArchivesOnly() {
        let claimed = DefaultArchiveApp.claimableIdentifiers(from: [
            "public.zip-archive", "public.item", "public.folder", "public.directory", "com.kernir.app.archive-items",
            KernirDocumentTypes.volumeSetIdentifier, "com.sun.java-archive", "com.android.package-archive",
            "org.7-zip.7-zip-archive", "public.zip-archive",
        ])
        #expect(claimed == ["public.zip-archive", "org.7-zip.7-zip-archive"])
    }

    /// The claimed list is the app's document types minus the split part, and the groups cover it once each.
    @Test func typesComeFromTheDocumentTypes() {
        let expected = KernirDocumentTypes.identifiers.filter { $0 != KernirDocumentTypes.volumeSetIdentifier }
        #expect(Set(DefaultArchiveApp.types.map { $0.identifier }) == Set(expected))
        let grouped = DefaultArchiveApp.groups.flatMap { $0.types }.map { $0.identifier }
        #expect(grouped.count == Set(grouped).count)
        #expect(Set(grouped) == Set(expected))
        #expect(Set(DefaultArchiveApp.groups.map { $0.id }).count == DefaultArchiveApp.groups.count)
        #expect(DefaultArchiveApp.groups.first?.title == "ZIP")
        #expect(DefaultArchiveApp.groups.allSatisfy { !$0.title.isEmpty && !$0.types.isEmpty })
    }

    /// "For all" leaves ISO out: a double-clicked disk image keeps mounting. Its own row claims it.
    @Test func allLeavesOutISO() {
        let all = Set(DefaultArchiveApp.typesForAll.map { $0.identifier })
        #expect(!all.contains("public.iso-image"))
        #expect(DefaultArchiveApp.groups.filter { !$0.isInAll }.map { $0.id } == ["iso"])
        #expect(DefaultArchiveApp.groups.first { $0.id == "iso" }?.types.map { $0.identifier } == ["public.iso-image"])
        let others = DefaultArchiveApp.groups.filter { $0.id != "iso" }.flatMap { $0.types }.map { $0.identifier }
        #expect(all == Set(others))
    }

    /// Known cancel codes, also wrapped as an underlying error, are a decline; others aren't.
    @Test func cancellationCodes() {
        #expect(DefaultArchiveApp.isUserCancellation(CocoaError(.userCancelled)))
        #expect(DefaultArchiveApp.isUserCancellation(NSError(domain: NSOSStatusErrorDomain, code: -128)))
        #expect(DefaultArchiveApp.isUserCancellation(NSError(domain: "com.apple.LaunchServices", code: -128)))
        let wrapped = NSError(domain: "com.apple.LaunchServices", code: -10_810,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -128)])
        #expect(DefaultArchiveApp.isUserCancellation(wrapped))
        let many = NSError(domain: "test", code: 1,
                           userInfo: [NSMultipleUnderlyingErrorsKey: [NSError(domain: "x", code: 2), CocoaError(.userCancelled)]])
        #expect(DefaultArchiveApp.isUserCancellation(many))
        #expect(!DefaultArchiveApp.isUserCancellation(NSError(domain: "com.apple.LaunchServices", code: -10_810)))
        #expect(!DefaultArchiveApp.isUserCancellation(NSError(domain: "test", code: -128)))
        #expect(!DefaultArchiveApp.isUserCancellation(CocoaError(.fileWriteNoPermission)))
    }

    @Test func isDefault() {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive"), tar = type("public.tar-archive")
        let manager = DefaultArchiveApp(appURL: Self.app, workspace: workspace)
        #expect(!manager.isDefault(for: zip))
        workspace.handlers[zip.identifier] = URL(fileURLWithPath: "/Applications/Lutik.app/") // trailing slash
        workspace.handlers[tar.identifier] = Self.other
        #expect(manager.isDefault(for: zip))
        #expect(!manager.isDefault(for: tar))
        #expect(!manager.isDefault(for: [zip, tar]))
        #expect(manager.isDefault(for: [zip]))
        #expect(!manager.isDefault(for: []))
    }

    @Test func setsEveryTypeAndSkipsCurrentOnes() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive"), tar = type("public.tar-archive")
        workspace.handlers[zip.identifier] = Self.app
        let manager = DefaultArchiveApp(appURL: Self.app, workspace: workspace)
        let change = await manager.setDefault(for: [zip, tar])
        #expect(workspace.asked == [tar.identifier])
        #expect(change.entries.map { $0.outcome } == [.alreadyDefault, .changed])
        #expect(change.summary == .allSet)
        #expect(change.message(appName: "Lutik") == nil)
        #expect(manager.isDefault(for: [zip, tar]))
    }

    @Test func partialFailure() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive"), tar = type("public.tar-archive"), iso = type("public.iso-image")
        workspace.errors[tar.identifier] = CocoaError(.fileWriteUnknown)
        let manager = DefaultArchiveApp(appURL: Self.app, workspace: workspace)
        let change = await manager.setDefault(for: [zip, tar, iso])
        #expect(workspace.asked == [zip.identifier, tar.identifier, iso.identifier])
        #expect(change.entries.map { $0.outcome.isFailure } == [false, true, false])
        #expect(change.summary == .partial(failed: 1, total: 3))
        #expect(change.failedTypes == [tar])
        #expect(change.message(appName: "Lutik")?.contains("Lutik") == true)
        #expect(change.message(appName: "Lutik")?.hasSuffix("Settings shows which ones.") == true)
        #expect(change.message(appName: "Lutik", pointsToSettings: false)?.contains("Settings") == false)
    }

    @Test func everythingFails() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive")
        workspace.errors[zip.identifier] = CocoaError(.fileWriteNoPermission)
        let change = await DefaultArchiveApp(appURL: Self.app, workspace: workspace).setDefault(for: [zip])
        #expect(change.summary == .failed)
        #expect(change.message(appName: "Lutik")?.contains("Lutik") == true)
    }

    /// The user turning down the system's confirmation stops the run: the rest isn't asked.
    @Test(arguments: [
        CocoaError(.userCancelled) as Error,
        NSError(domain: NSOSStatusErrorDomain, code: -128) as Error,
        NSError(domain: "com.apple.LaunchServices", code: -10_810,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -128)]) as Error,
    ])
    func declineStopsAsking(error: Error) async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive"), tar = type("public.tar-archive"), iso = type("public.iso-image")
        workspace.errors[tar.identifier] = error
        let change = await DefaultArchiveApp(appURL: Self.app, workspace: workspace).setDefault(for: [zip, tar, iso])
        #expect(workspace.asked == [zip.identifier, tar.identifier])
        #expect(change.entries.map { $0.outcome } == [.changed, .declined, .skipped])
        #expect(change.summary == .declined)
        #expect(change.message(appName: "Lutik") == nil)
    }

    /// macOS 26.2 without the entitlement: the call succeeds and this process reads the app as the
    /// default, but a fresh process (Finder) still sees the old one. Those types aren't applied.
    @Test func changeFinderDoesNotSeeIsNotApplied() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive"), tar = type("public.tar-archive"), iso = type("public.iso-image")
        workspace.handlers[iso.identifier] = Self.app
        workspace.finder = [zip.identifier: false, tar.identifier: true]
        let manager = DefaultArchiveApp(appURL: Self.app, bundleIdentifier: Self.bundleID, workspace: workspace)
        let change = await manager.setDefault(for: [zip, tar, iso])
        #expect(workspace.finderChecks == [[zip.identifier, tar.identifier]])
        #expect(change.entries.map { $0.outcome } == [.notApplied, .changed, .alreadyDefault])
        #expect(change.notAppliedTypes == [zip])
        #expect(change.summary == .notApplied)
        let expected = "macOS didn’t make Lutik the default app for archives. In Finder, select an archive, choose File > Get Info, pick Lutik under “Open with”, then click Change All."
        #expect(change.message(appName: "Lutik") == expected)
        #expect(change.message(appName: "Lutik", pointsToSettings: false) == expected)
    }

    /// Types the system refused outright next to types Finder doesn't see: the message tells both, with
    /// the Get Info steps (they work for either).
    @Test func refusedTypesAreToldBesideNotAppliedOnes() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive"), tar = type("public.tar-archive"), iso = type("public.iso-image")
        workspace.errors[tar.identifier] = CocoaError(.fileWriteUnknown)
        workspace.finder = [zip.identifier: false, iso.identifier: true]
        let manager = DefaultArchiveApp(appURL: Self.app, bundleIdentifier: Self.bundleID, workspace: workspace)
        let change = await manager.setDefault(for: [zip, tar, iso])
        #expect(change.notAppliedTypes == [zip])
        #expect(change.failedTypes == [tar])
        #expect(change.summary == .notApplied)
        let expected = "macOS didn’t make Lutik the default app for archives, and refused some archive types outright. In Finder, select an archive of each type, choose File > Get Info, pick Lutik under “Open with”, then click Change All."
        #expect(change.message(appName: "Lutik") == expected)
        #expect(change.message(appName: "Lutik", pointsToSettings: false) == expected)
    }

    @Test func changeFinderSeesIsChanged() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive")
        workspace.finder = [zip.identifier: true]
        let manager = DefaultArchiveApp(appURL: Self.app, bundleIdentifier: Self.bundleID, workspace: workspace)
        let change = await manager.setDefault(for: [zip])
        #expect(change.entries.map { $0.outcome } == [.changed])
        #expect(change.summary == .allSet)
    }

    /// No answer from the fresh process (or none for a type): the API's word stands.
    @Test func unknownFinderStateKeepsTheChange() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive"), tar = type("public.tar-archive")
        let manager = DefaultArchiveApp(appURL: Self.app, bundleIdentifier: Self.bundleID, workspace: workspace)
        var change = await manager.setDefault(for: [zip])
        #expect(change.entries.map { $0.outcome } == [.changed])
        #expect(change.summary == .allSet)
        workspace.finder = [zip.identifier: true] // nothing about tar
        change = await manager.setDefault(for: [tar])
        #expect(change.entries.map { $0.outcome } == [.changed])
        // No bundle id to ask about: no check at all.
        let checks = workspace.finderChecks.count
        workspace.handlers = [:]
        let anonymous = DefaultArchiveApp(appURL: Self.other, bundleIdentifier: nil, workspace: workspace)
        change = await anonymous.setDefault(for: [zip])
        #expect(change.entries.map { $0.outcome } == [.changed])
        #expect(workspace.finderChecks.count == checks)
    }

    /// Nothing changed: no fresh-process check.
    @Test func noChangeNoFinderCheck() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive")
        workspace.handlers[zip.identifier] = Self.app
        workspace.finder = [zip.identifier: false]
        let change = await DefaultArchiveApp(appURL: Self.app, bundleIdentifier: Self.bundleID, workspace: workspace).setDefault(for: [zip])
        #expect(change.entries.map { $0.outcome } == [.alreadyDefault])
        #expect(workspace.finderChecks.isEmpty)
    }

    /// A type left unconfirmed is asked again, even though this process reads the app as its default.
    @Test func unconfirmedTypesAreAskedAgain() async {
        let workspace = FakeWorkspace()
        let zip = type("public.zip-archive")
        workspace.handlers[zip.identifier] = Self.app
        workspace.finder = [zip.identifier: true]
        let manager = DefaultArchiveApp(appURL: Self.app, bundleIdentifier: Self.bundleID, workspace: workspace)
        let change = await manager.setDefault(for: [zip], unconfirmed: [zip.identifier])
        #expect(workspace.asked == [zip.identifier])
        #expect(change.entries.map { $0.outcome } == [.changed])
    }

    /// The fresh-process script's lines: `type<TAB>1|0|?<TAB>handler path`; anything else is skipped.
    @Test func parsesTheFinderCheckOutput() {
        let ids = ["public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive"]
        let output = "public.zip-archive\t1\t/Applications/Lutik.app\norg.7-zip.7-zip-archive\t0\t/Applications/Other.app\n"
            + "com.rarlab.rar-archive\t?\nnoise\nother.type\t1\t/x\n"
        #expect(SystemDefaultAppWorkspace.parseHandlers(output, types: ids)
                == ["public.zip-archive": true, "org.7-zip.7-zip-archive": false])
        #expect(SystemDefaultAppWorkspace.parseHandlers("com.rarlab.rar-archive\t?", types: ids) == [:])
        #expect(SystemDefaultAppWorkspace.parseHandlers("", types: ids) == nil)
        #expect(SystemDefaultAppWorkspace.parseHandlers("execution error: nope (-2700)", types: ids) == nil)
    }

    /// The real check answers for a known type, also from the sandboxed test host; it only reads.
    /// (No Bundle.main id under SwiftPM: any id gets an answer, 1 or 0.)
    @Test(.timeLimit(.minutes(1))) func systemFinderCheckAnswers() async {
        let bundleID = Bundle.main.bundleIdentifier ?? Self.bundleID
        let seen = await SystemDefaultAppWorkspace().handlersSeenByFinder(bundleIdentifier: bundleID, types: ["public.zip-archive"])
        #expect(seen?["public.zip-archive"] != nil)
    }

    @Test func nothingToDo() async {
        let change = await DefaultArchiveApp(appURL: Self.app, workspace: FakeWorkspace()).setDefault(for: [])
        #expect(change.entries.isEmpty)
        #expect(change.summary == .allSet)
    }
}
#endif
