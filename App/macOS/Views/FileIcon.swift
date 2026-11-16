import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Finder icon for an archive item's type, at 16 pt.
struct FileIcon: View {
    let item: ArchiveItem

    var body: some View {
        Image(nsImage: Self.icon(for: Self.type(of: item)))
            .resizable()
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }

    private static func type(of item: ArchiveItem) -> UTType {
        if item.isDirectory { return .folder }
        let ext = (item.name as NSString).pathExtension
        return ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
    }

    /// Icon lookups are slow; one image per type identifier.
    @MainActor private static var cache: [String: NSImage] = [:]

    private static func icon(for type: UTType) -> NSImage {
        if let cached = cache[type.identifier] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = icon
        return icon
    }
}
