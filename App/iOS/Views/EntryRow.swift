import SwiftUI
import UniformTypeIdentifiers

/// One file or folder in a folder list: icon, name, detail, and a chevron for folders.
struct EntryRow: View {
    let item: ArchiveItem
    let detail: String
    /// What VoiceOver reads for `detail` ("Unknown size" for "--").
    let spokenDetail: String

    var body: some View {
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(spokenDetail))
                }
            } icon: {
                if item.isDirectory {
                    Image(systemName: "folder").foregroundStyle(.tint)
                } else {
                    Image(systemName: Self.symbol(forFileNamed: item.name)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.isPendingAddition {
                Image(systemName: "plus.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Not saved yet"))
            }
            if item.isDirectory {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    /// The SF Symbol for a file, chosen from the type its extension names.
    static func symbol(forFileNamed name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if [UTType.pdf, .rtf, .rtfd, .flatRTFD, .html].contains(where: type.conforms(to:)) { return "doc.richtext" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
