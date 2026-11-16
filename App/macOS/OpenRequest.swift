import AppKit
import KernirCore
import UniformTypeIdentifiers

/// The window a Dock drop of plain items opened:
/// a new untitled archive holding the items, with the Save sheet on it. `ArchiveDocument` is one;
/// tests use their own.
@MainActor
protocol NewArchiveSession: AnyObject {
    /// Whether the next drop still goes here: the document is open, has never been saved (no file
    /// yet, no split set saved) and can take items now (no save running).
    var takesMoreItems: Bool { get }
    /// The name and folder the Save sheet proposes (`ArchiveDocument.prepareSavePanel`).
    var newArchiveProposal: CompressPlan.Destination? { get set }
    /// Adds `items` at the archive's top level, as Add Files… does.
    func add(_ items: [URL])
    /// Brings the window to the front.
    func bringToFront()
    /// Shows the Save sheet on the window.
    func beginSave()
}

/// What `AppDelegate.application(_:open:)` does with one open request, apart from AppKit so
/// tests can run it: `OpenRoute` decides; `open` takes each archive; plain items (with any archives
/// dropped among them) go into a new archive window that `newSession` makes, whose Save sheet opens
/// at once. While that window is open and unsaved, later drops go into it (and bring it to the
/// front) without opening the sheet again: a sheet the user closed stays closed, and one that is up
/// stays up. Once it is saved or closed, the next drop makes a new window. The Finder Service's
/// Compress (`ServicesProvider`) is unrelated and unchanged.
@MainActor
final class OpenRequest {
    private let opensInKernir: (URL) -> Bool
    private let open: (URL) -> Void
    private let newSession: () -> (any NewArchiveSession)?

    /// The Dock session's window, weakly: closing it ends the session.
    private weak var session: (any NewArchiveSession)?
    /// Every item the Dock session got, for its Save sheet's proposal.
    private var sessionItems: [URL] = []

    init(opensInKernir: @escaping (URL) -> Bool = ServicesRequest.opensInKernir,
         open: @escaping (URL) -> Void,
         newSession: @escaping () -> (any NewArchiveSession)?) {
        self.opensInKernir = opensInKernir
        self.open = open
        self.newSession = newSession
    }

    /// One gathered request (`OpenBatch`). Non-file URLs are ignored.
    func handle(_ urls: [URL]) {
        switch OpenRoute.route(urls, opensInKernir: opensInKernir) {
        case .open(let documents):
            documents.forEach(open)
        case .newArchive(let items):
            if let session, session.takesMoreItems {
                // A repeated name replaces the item it names: one item, as in the archive.
                let names = Set(items.map(\.lastPathComponent))
                sessionItems = sessionItems.filter { !names.contains($0.lastPathComponent) } + items
                session.newArchiveProposal = Self.proposal(for: sessionItems)
                session.add(items)
                session.bringToFront()
            } else if let made = newSession() {
                session = made
                sessionItems = items
                made.newArchiveProposal = Self.proposal(for: items)
                made.add(items)
                made.beginSave()
            }
        case nil:
            break
        }
    }

    /// What the Save sheet proposes for `items`: Compress's name ("notes.txt.zip" for one item,
    /// "Archive.zip" for several) in the first item's folder, as a ZIP. Unnumbered: Lutik may not
    /// list that folder, and the panel itself asks before replacing a file.
    static func proposal(for items: [URL]) -> CompressPlan.Destination? {
        CompressPlan.destination(for: items, format: .zip, existingNames: [])
    }
}

extension ArchiveDocument: NewArchiveSession {
    /// A new untitled ZIP in its own window, for a Dock drop (`OpenRequest`); nil (the error
    /// presented) if AppKit could not make one. `display` false leaves the window hidden (tests).
    static func makeNewArchiveSession(display: Bool = true) -> ArchiveDocument? {
        let controller = NSDocumentController.shared
        do {
            guard let document = try controller.makeUntitledDocument(ofType: UTType.zip.identifier)
                as? ArchiveDocument else { return nil }
            controller.addDocument(document)
            document.makeWindowControllers()
            if display { document.showWindows() }
            return document
        } catch {
            controller.presentError(error)
            return nil
        }
    }

    var takesMoreItems: Bool {
        fileURL == nil && !savedSplitSet && actions?.canAdd == true
            && NSDocumentController.shared.documents.contains { $0 === self }
    }

    /// The window's own add (Add Files…, a drop on the table): asks before replacing an item of the
    /// same name. The archive reads the files when it is saved; the open event's sandbox extensions
    /// last as long as the app runs.
    func add(_ items: [URL]) { actions?.add(items, to: "") }

    func bringToFront() { showWindows() }

    /// ⌘S on an untitled document: the Save sheet.
    func beginSave() { save(nil) }
}

/// The Save sheet a Dock window's proposal named (`ArchiveDocument.prepareSavePanel`), held
/// weakly: a later drop changes the proposal ("notes.txt.zip" → "Archive.zip"), and the sheet, if
/// it is still up and its name is still the one proposed (the user hasn't edited it), takes the
/// new name. Another format or Split already changed the name, so those keep theirs.
@MainActor
final class NewArchiveSavePanel {
    private weak var panel: NSSavePanel?
    /// The name the panel showed when it was tracked or last renamed.
    private var shownName: String?

    nonisolated init() {}

    /// `panel`, as `prepareSavePanel` left it, is the one later proposals rename.
    func track(_ panel: NSSavePanel) {
        self.panel = panel
        shownName = panel.nameFieldStringValue
    }

    /// A new proposal's name, for the tracked panel while it is on screen.
    func propose(_ name: String?) { propose(name, isShown: panel?.isVisible == true) }

    /// `propose`, with whether the panel is on screen given (tests: a panel can't be shown there).
    func propose(_ name: String?, isShown: Bool) {
        guard let panel, let name,
              let newName = Self.newName(field: panel.nameFieldStringValue, shown: shownName,
                                         isShown: isShown, proposing: name) else { return }
        panel.nameFieldStringValue = newName
        shownName = panel.nameFieldStringValue
    }

    /// The name to put in the field: `name`, when the panel is on screen and its field still
    /// shows the name it was given (`shown`); nil to leave it.
    nonisolated static func newName(field: String, shown: String?, isShown: Bool, proposing name: String) -> String? {
        guard isShown, let shown, field == shown, field != name else { return nil }
        return name
    }
}
