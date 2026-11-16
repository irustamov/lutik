import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KernirCore

/// Root view of an archive window: the table with its toolbar, search and footer, the empty
/// and error states, and the password and progress sheets.
struct ArchiveWindowView: View {
    @Bindable var state: ArchiveWindowState
    let actions: ArchiveActions

    var body: some View {
        // A separate view, so selection changes (read by the toolbar) don't refilter and resort the tree.
        ArchiveContentView(state: state, actions: actions)
            .toolbar { toolbar }
            // SwiftUI's subtitle: with the bridged toolbar, the window draws this and not `NSWindow.subtitle`.
            // It replaces AppKit's own subtitle, so it says "Edited" itself.
            .navigationSubtitle(Self.subtitle(format: state.model?.format, fileType: actions.document?.fileType,
                                              fileSize: state.fileSize, isEdited: state.isEdited))
            .searchable(text: $state.searchText, placement: .toolbar)
            .onChange(of: state.searchText) { _, query in
                applySearch(query)
            }
            .sheet(isPresented: $state.isLocked) {
                PasswordSheet(name: actions.document?.displayName ?? "", error: state.passwordError,
                              showsDamagedHint: state.showsDamagedHint,
                              open: { password, remember in
                                  await actions.unlock(password: password, remember: remember)
                              },
                              cancel: { actions.cancelUnlock() })
            }
            // A separate view: one sheet modifier per view.
            .background {
                Color.clear
                    .sheet(isPresented: isShowingProgress) {
                        if let progress = state.progress {
                            ProgressSheet(progress: progress)
                        }
                    }
            }
            // Move To… (the table's context menu). Its Move closes it first; the move runs on the dismiss, so the
            // replace alert can attach.
            .background {
                Color.clear
                    .sheet(item: $state.moveTo, onDismiss: { actions.moveToSheetDidEnd() }) { folders in
                        MoveToSheet(folders: folders, move: { actions.chooseMoveTo($0) },
                                    cancel: { actions.cancelMoveTo() })
                    }
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Explains the disabled ＋ and － of a read-only archive.
        let readOnlyHelp = Self.readOnlyHelp(state.model).map { Text($0) } ?? Text(verbatim: "")
        ToolbarItem {
            ControlGroup {
                Button {
                    actions.addFiles()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityLabel("Add")
                .help(readOnlyHelp)
                .disabled(!actions.canAdd)
                Button {
                    actions.removeSelection()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .accessibilityLabel("Delete")
                .help(readOnlyHelp)
                .disabled(!actions.canRemoveSelection)
            }
        }
        ToolbarItem {
            Button {
                actions.extract(nextToArchive: NSEvent.modifierFlags.contains(.option))
            } label: {
                Label("Extract", systemImage: "arrow.down.doc")
            }
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("Extract")
            .disabled(!actions.canExtract)
        }
        ToolbarItem(id: ArchiveActions.infoItemID) {
            Button {
                actions.toggleInfo()
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .accessibilityLabel("Info")
            .help("Get Info")
            .disabled(state.model == nil)
            // File > Get Info opens this one too while the button is on screen; else the footer's opens.
            .popover(isPresented: state.isShowingInfo(at: .toolbar), arrowEdge: .bottom) {
                if let model = state.model {
                    ArchiveInfoPopover(model: model, state: state)
                }
            }
        }
    }

    // MARK: - Helpers

    /// The ＋ and － tooltip of an archive that can only be read; nil when it can be edited.
    static func readOnlyHelp(_ model: ArchiveModel?) -> String? {
        guard let model, !model.isEditable else { return nil }
        // A split archive's format may be writable: only its being split stops editing.
        if (model.reader?.volumeURLs.count ?? 1) > 1 {
            return String(localized: "Split archives can only be read. Save As to edit.")
        }
        return String(localized: "\(model.format.displayName) can only be read. Save As ZIP or 7z to edit.",
                      comment: "Tooltip of the ＋ and － buttons of an archive that can't be edited. %@ = the archive format's name (e.g. “RAR”). “Save As” is the File menu command; ZIP and 7z are format names.")
    }

    /// "ZIP · 4.2 MB", or just the format for an unsaved document, then " — Edited" while there
    /// are unsaved changes. A locked document has no model, so its format comes from its file
    /// type; zip-based packages (jar, apk…) read as ZIP.
    static func subtitle(format: ArchiveFormat?, fileType: String?, fileSize: Int64?, isEdited: Bool) -> String {
        let format = format ?? fileType.flatMap { type in
            KernirDocumentTypes.format(forTypeIdentifier: type)
                ?? (UTType(type)?.conforms(to: .zip) == true ? .zip : nil)
        }
        let name = format?.displayName
        let size = fileSize.map(KernirFormat.size)
        let details = if let name, let size {
            String(localized: "\(name) · \(size)",
                   comment: "Archive window subtitle. %1$@ = archive format (e.g. “ZIP”), %2$@ = file size (e.g. “4.2 MB”).")
        } else {
            name ?? size ?? ""
        }
        guard isEdited else { return details }
        return details.isEmpty
            ? String(localized: "Edited",
                     comment: "Archive window subtitle of a document with unsaved changes when neither its format nor its size is known.")
            : String(localized: "\(details) — Edited",
                     comment: "Archive window subtitle while there are unsaved changes. %@ = format and size (e.g. “ZIP · 4.2 MB”), or just one of them.")
    }

    /// "12 items · 4.2 MB, 1.8 MB compressed · ZIP"; see `KernirFormat.summary`.
    static func footerText(_ model: ArchiveModel) -> String {
        KernirFormat.summary(itemCount: model.itemCount, size: model.totalSize,
                             compressedSize: model.compressedSize, format: model.format)
    }

    /// While searching, every folder in the results is open and only results stay selected,
    /// so Delete never removes rows the search hides. Clearing the search restores the folders
    /// the user had open.
    private func applySearch(_ query: String) {
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching {
            let results = state.model?.items.filtered(matching: query) ?? []
            if state.expandedBeforeSearch == nil { state.expandedBeforeSearch = state.expanded }
            state.expanded = results.directoryIDs
            state.selection.formIntersection(results.flattened().map(\.id))
        } else if let expanded = state.expandedBeforeSearch {
            state.expanded = Self.expansionAfterSearch(restoring: expanded, renaming: state.renamingPath)
            state.expandedBeforeSearch = nil
        }
    }

    /// The folders open once the search clears: those open before it, and those above the row being renamed
    /// (New Folder or Rename cleared the search to show it), whose field ends the rename only if it shows.
    static func expansionAfterSearch(restoring expanded: Set<String>, renaming: String?) -> Set<String> {
        guard let renaming else { return expanded }
        return expanded.union(ArchiveActions.folders(above: renaming))
    }

    /// The operation clears `state.progress` when it ends; the sheet can't be dismissed otherwise.
    private var isShowingProgress: Binding<Bool> {
        Binding(get: { state.progress != nil }, set: { _ in })
    }
}

/// The table with its footer and empty states, or why the archive can't be shown. Its body reads
/// only the items, search and sort order, so the tree is refiltered and resorted only when they change.
private struct ArchiveContentView: View {
    let state: ArchiveWindowState
    let actions: ArchiveActions

    var body: some View {
        if let model = state.model {
            let rows = state.tableItems(of: model)
            ArchiveTableView(items: rows, state: state, actions: actions)
                .overlay {
                    if model.items.isEmpty {
                        ContentUnavailableView("Drag Files Here", systemImage: "archivebox",
                                               description: Text("Add files with ＋ or drag them into this window.")
                                                   .accessibilityLabel(Text("Add files with the Add button or drag them into this window.")))
                            // Drops land on the table underneath.
                            .allowsHitTesting(false)
                    } else if rows.isEmpty {
                        ContentUnavailableView.search(text: state.searchText)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ArchiveFooter(model: model, state: state)
                }
        } else if let volumeError = state.volumeError {
            ContentUnavailableView {
                Label(volumeError.errorDescription ?? "", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text(volumeError.recoverySuggestion ?? "")
            } actions: {
                if volumeError.offersGrantAccess {
                    Button {
                        actions.grantVolumeAccess()
                    } label: {
                        Text("Grant Access…", comment: "Button in the window of a split archive whose parts Lutik can't read: opens a folder panel to give Lutik access to the folder that holds the parts. Not the panel's own button “Grant Access”.")
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isRetrying)
                }
                // Reopening reads every part, which takes a while on a slow volume: show it's working.
                if state.isRetrying {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } else if let loadError = state.loadError {
            ContentUnavailableView("Can’t Read Archive", systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
        } else {
            // Locked: the password sheet covers this.
            Color.clear
        }
    }
}

/// The summary under the table, with the Comment button when the archive has a comment. The Info popover
/// points here when the toolbar's Info button isn't on screen (a hidden toolbar, or the button in the overflow menu).
private struct ArchiveFooter: View {
    let model: ArchiveModel
    let state: ArchiveWindowState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Text(ArchiveWindowView.footerText(model))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(6)
                // Beside the centred summary, so it stays centred.
                .overlay(alignment: .trailing) {
                    Group {
                        if model.showsComment, model.reader?.comment != nil {
                            Button {
                                state.infoAnchor = .footer
                            } label: {
                                Label("Comment", systemImage: "text.bubble")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("Comment")
                            .accessibilityLabel("Comment")
                        } else {
                            // Where the Comment button would be: the popover points here all the same.
                            Color.clear
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.trailing, 8)
                    .popover(isPresented: state.isShowingInfo(at: .footer), arrowEdge: .top) {
                        ArchiveInfoPopover(model: model, state: state)
                    }
                }
        }
        .background(.bar)
    }
}

extension ArchiveWindowState {
    /// What a popover at `anchor` presents with: true while the Info popover is open there. Dismissing it (a click
    /// outside, Esc) closes it, so the next Get Info opens it again at once.
    func isShowingInfo(at anchor: InfoAnchor) -> Binding<Bool> {
        Binding(get: { self.infoAnchor == anchor },
                set: { isShowing in
                    if isShowing {
                        self.infoAnchor = anchor
                    } else if self.infoAnchor == anchor {
                        self.infoAnchor = nil
                    }
                })
    }
}
