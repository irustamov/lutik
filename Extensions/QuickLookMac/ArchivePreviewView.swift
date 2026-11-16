import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KernirCore

/// What Quick Look shows for an archive. The panel draws the file name and the
/// "Open with" button itself, so this view is only the summary and the outline.
struct ArchivePreviewView: View {
    let content: PreviewContent

    var body: some View {
        VStack(spacing: 0) {
            switch content {
            case .listing(let listing) where listing.isEmpty:
                ContentUnavailableView(PreviewFormatting.emptyArchiveTitle, systemImage: "archivebox",
                                       description: Text(PreviewFormatting.formatName(listing.format)))
            case .listing(let listing):
                Text(PreviewFormatting.summary(listing))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Table(listing.nodes, children: \.children) {
                    TableColumn(String(localized: "Name", bundle: PreviewFormatting.bundle,
                                       comment: "Quick Look column title: file or folder name. The preview hides the header row.")) { node in
                        Label {
                            Text(node.entry.name)
                        } icon: {
                            Image(nsImage: Self.icon(for: node.entry))
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                    }
                    TableColumn(String(localized: "Size", bundle: PreviewFormatting.bundle,
                                       comment: "Quick Look column title: file size. The preview hides the header row.")) { node in
                        Text(PreviewFormatting.size(node.totalSize))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    // A minimum, not a fixed width: localized sizes ("1 023,5 Ko") and titles can be longer.
                    .width(min: 70, ideal: 90)
                }
                .tableColumnHeaders(.hidden)
                if listing.hiddenCount > 0 {
                    Text(PreviewFormatting.moreItems(listing.hiddenCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            case .passwordProtected(let format):
                ContentUnavailableView(PreviewFormatting.passwordProtectedTitle, systemImage: "lock.fill",
                                       description: Text(PreviewFormatting.formatName(format)))
            case .volumePart(let openedPart):
                ContentUnavailableView(PreviewFormatting.volumePartTitle(openedPart),
                                       systemImage: "square.stack.3d.up.slash",
                                       description: Text(PreviewFormatting.openInKernirDescription))
            case .tooLarge:
                ContentUnavailableView(PreviewFormatting.tooLargeTitle, systemImage: "tray.full",
                                       description: Text(PreviewFormatting.openInKernirDescription))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func icon(for entry: ArchiveEntry) -> NSImage {
        if entry.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (entry.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
