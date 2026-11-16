import SwiftUI
import KernirCore

/// What Quick Look shows for an archive in the Files app: the summary header and the outline.
struct ArchivePreviewView: View {
    let content: PreviewContent

    var body: some View {
        switch content {
        case .listing(let listing) where listing.isEmpty:
            ContentUnavailableView(PreviewFormatting.emptyArchiveTitle, systemImage: "archivebox",
                                   description: Text(PreviewFormatting.formatName(listing.format)))
        case .listing(let listing):
            List {
                Section {
                    OutlineGroup(listing.nodes, children: \.children) { node in
                        HStack {
                            Label(node.entry.name, systemImage: node.entry.isDirectory ? "folder" : "doc")
                            Spacer()
                            Text(PreviewFormatting.size(node.totalSize))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text(PreviewFormatting.summary(listing))
                } footer: {
                    if listing.hiddenCount > 0 {
                        Text(PreviewFormatting.moreItems(listing.hiddenCount))
                    }
                }
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
}

#if DEBUG
private func previewListing(hidden: Int = 0, empty: Bool = false) -> PreviewListing {
    let entries: [ArchiveEntry] = empty ? [] : [
        ArchiveEntry(path: "Docs", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
        ArchiveEntry(path: "Docs/Readme.txt", isDirectory: false, size: 2_048, compressedSize: nil, modificationDate: nil),
        ArchiveEntry(path: "photo.jpg", isDirectory: false, size: 3_400_000, compressedSize: nil, modificationDate: nil),
    ]
    return PreviewListing(format: .zip, nodes: Archive.tree(from: entries), totalCount: entries.count + hidden,
                          totalSize: 3_402_048, hiddenCount: hidden)
}

#Preview("Listing") { ArchivePreviewView(content: .listing(previewListing())) }
#Preview("Truncated") { ArchivePreviewView(content: .listing(previewListing(hidden: 1_234))) }
#Preview("Empty") { ArchivePreviewView(content: .listing(previewListing(empty: true))) }
#Preview("Password") { ArchivePreviewView(content: .passwordProtected(.zip)) }
#Preview("Split part") { ArchivePreviewView(content: .volumePart(openedPart: 2)) }
#Preview("Too large") { ArchivePreviewView(content: .tooLarge) }
#endif
