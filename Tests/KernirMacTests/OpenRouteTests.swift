import Testing
import Foundation
@testable import Kernir

/// What an open request (a drop on the
/// Mac Dock icon, Open With, `open`) does with its URLs. Slot-free: a fake predicate stands in for
/// `ServicesRequest.opensInKernir`.
struct OpenRouteTests {
    private let folder = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)

    /// The fake: Kernir opens the names ending in .zip or .7z, nothing else.
    private static func opens(_ url: URL) -> Bool { ["zip", "7z"].contains(url.pathExtension) }

    private func urls(_ names: [String]) -> [URL] { names.map { folder.appendingPathComponent($0) } }
    private func route(_ urls: [URL]) -> OpenRoute? { OpenRoute.route(urls, opensInKernir: Self.opens) }

    @Test func nothingIsNoRoute() {
        #expect(route([]) == nil)
    }

    @Test func archivesOnlyOpen() {
        #expect(route(urls(["a.zip"])) == .open(urls(["a.zip"])))
        #expect(route(urls(["a.zip", "b.7z"])) == .open(urls(["a.zip", "b.7z"])))
    }

    @Test func aPlainFileMakesANewArchive() {
        #expect(route(urls(["notes.txt"])) == .newArchive(urls(["notes.txt"])))
    }

    @Test func plainFilesGoIntoOneNewArchive() {
        #expect(route(urls(["notes.txt", "photo.jpg"])) == .newArchive(urls(["notes.txt", "photo.jpg"])))
    }

    @Test func aFolderMakesANewArchive() {
        let photos = folder.appendingPathComponent("Photos", isDirectory: true)
        #expect(route([photos]) == .newArchive([photos]))
    }

    /// One plain item among archives: every item goes into the one new archive, in order.
    @Test func aMixedSetGoesWholeIntoOneNewArchive() {
        let mixed = urls(["a.zip", "notes.txt", "b.7z"])
        #expect(route(mixed) == .newArchive(mixed))
    }

    /// Kernir declares no URL scheme: web and other non-file URLs are dropped before the rule.
    @Test func nonFileURLsAreIgnored() throws {
        let web = try #require(URL(string: "https://example.com/a.txt"))
        #expect(route([web]) == nil)
        #expect(route([web] + urls(["a.zip"])) == .open(urls(["a.zip"])))
        #expect(route(urls(["notes.txt"]) + [web]) == .newArchive(urls(["notes.txt"])))
    }
}

/// The gate's bug: `open -a Lutik note2.txt a.zip` made an archive of note2.txt alone, so
/// AppKit had handed the one request over in two `application(_:open:)` calls (Launch Services
/// sends a type Kernir declares and one it doesn't in separate open events). `OpenBatch` gathers
/// the calls that come within `OpenBatch.window` of each other into one request for the rule.
/// A recorded scheduler stands in for the main queue's timer.
@MainActor struct OpenBatchTests {
    private let folder = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)
    private func urls(_ names: [String]) -> [URL] { names.map { folder.appendingPathComponent($0) } }

    /// A batch whose scheduled flushes wait in `scheduled` until the test runs them.
    private final class Harness {
        var scheduled: [@MainActor @Sendable () -> Void] = []
        var delivered: [[URL]] = []
    }

    private func make() -> (OpenBatch, Harness) {
        let harness = Harness()
        let batch = OpenBatch(schedule: { harness.scheduled.append($0) },
                              deliver: { harness.delivered.append($0) })
        return (batch, harness)
    }

    @Test func nothingIsDeliveredBeforeTheWindowEnds() {
        let (batch, harness) = make()
        batch.add(urls(["note2.txt"]))
        #expect(harness.delivered.isEmpty)
        #expect(harness.scheduled.count == 1)
    }

    /// Two calls within the window are one request: the mixed set routes to one new archive of both.
    @Test func callsWithinTheWindowAreOneRequest() {
        let (batch, harness) = make()
        batch.add(urls(["note2.txt"]))
        batch.add(urls(["a.zip"]))
        harness.scheduled.forEach { $0() }
        #expect(harness.delivered == [urls(["note2.txt", "a.zip"])])
        let route = OpenRoute.route(harness.delivered[0], opensInKernir: { $0.pathExtension == "zip" })
        #expect(route == .newArchive(urls(["note2.txt", "a.zip"])))
    }

    /// Each call restarts the window: an earlier call's timer delivers nothing.
    @Test func aLaterCallRestartsTheWindow() {
        let (batch, harness) = make()
        batch.add(urls(["a.zip"]))
        let first = harness.scheduled.removeFirst()
        batch.add(urls(["b.7z"]))
        first()
        #expect(harness.delivered.isEmpty)
        harness.scheduled.removeFirst()()
        #expect(harness.delivered == [urls(["a.zip", "b.7z"])])
    }

    /// A call after the window ended is a request of its own.
    @Test func aCallAfterDeliveryStartsANewRequest() {
        let (batch, harness) = make()
        batch.add(urls(["a.zip"]))
        harness.scheduled.removeFirst()()
        batch.add(urls(["notes.txt"]))
        harness.scheduled.removeFirst()()
        #expect(harness.delivered == [urls(["a.zip"]), urls(["notes.txt"])])
    }

    @Test func anEmptyCallDeliversNothing() {
        let (batch, harness) = make()
        batch.add([])
        harness.scheduled.forEach { $0() }
        #expect(harness.delivered.isEmpty)
    }
}
