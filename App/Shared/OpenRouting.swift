import Foundation

/// What an open request does with its URLs:
/// files and folders dropped on the Mac Dock icon, or sent by Open With or `open`, go into a new
/// untitled archive in a new window, with the Save sheet on it; archives alone open as before.
enum OpenRoute: Equatable, Sendable {
    /// Every item is a document Lutik opens: open each one.
    case open([URL])
    /// At least one item is a plain file or folder: every item (archives too) goes into one new archive.
    case newArchive([URL])

    /// The route for `urls`, all of which came in one request (on the Mac, the calls `OpenBatch`
    /// gathered). Only file URLs count: Lutik declares no URL scheme, so any other URL
    /// is ignored. nil when no file URL is left. `opensInKernir` tells an archive (or another
    /// document Lutik opens) from a plain file or folder.
    static func route(_ urls: [URL], opensInKernir: (URL) -> Bool) -> OpenRoute? {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return nil }
        return files.allSatisfy(opensInKernir) ? .open(files) : .newArchive(files)
    }
}

/// One open request as the rule (`OpenRoute`) needs it, from the calls AppKit makes. AppKit can
/// hand one request over in several `application(_:open:)` calls: Launch Services sends the
/// items of a type Lutik declares (an archive) and those of a type it doesn't (a text file) in
/// separate open events, so `open -a Lutik note.txt a.zip` would make an archive of note.txt alone.
/// `add` gathers the calls; once `window` passes with no other call, `deliver` gets every URL
/// they brought, in the order they came, as one request.
@MainActor
final class OpenBatch {
    /// How long a request stays open for more calls, from its latest. Launch Services sends the
    /// events of one request back to back; a person's second drop takes longer than this.
    nonisolated static let window: TimeInterval = 0.3

    private let schedule: @MainActor (_ flush: @escaping @MainActor @Sendable () -> Void) -> Void
    private let deliver: @MainActor ([URL]) -> Void
    private var pending: [URL] = []

    /// Bumped by each call, so only the latest call's flush delivers.
    private var generation = 0

    /// `schedule` runs a flush once the window has passed (tests run it themselves); `deliver`
    /// takes each gathered request.
    init(schedule: @escaping @MainActor (_ flush: @escaping @MainActor @Sendable () -> Void) -> Void = OpenBatch.afterWindow,
         deliver: @escaping @MainActor ([URL]) -> Void) {
        self.schedule = schedule
        self.deliver = deliver
    }

    /// One call's URLs: delivered with the others once the window passes with no further call.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending += urls
        generation += 1
        let current = generation
        schedule { [weak self] in self?.flush(current) }
    }

    private func flush(_ scheduledBy: Int) {
        guard scheduledBy == generation, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        deliver(urls)
    }

    /// The app's scheduler: `flush` on the main queue once `window` has passed.
    static func afterWindow(_ flush: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + window) {
            MainActor.assumeIsolated { flush() }
        }
    }
}
