import CoreTransferable
import Foundation
import os
import UniformTypeIdentifiers

/// A document's private scratch folder for files on their way into the archive.
///
/// Picked files are copied in at once: a security-scoped URL from Files, or a photo's
/// temporary file, is gone long before the archive is saved. Each call stages into a batch
/// folder of its own, so an item keeps its name (and an earlier copy, which an undoable
/// addition may still point at, is never overwritten); names that collide within one call
/// get a " 2" suffix.
final class StagingArea: Sendable {
    private static let logger = Logger(subsystem: "com.kernir.app", category: "staging")

    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Copies files and folders (recursively) in and returns the copies, in order.
    func stage(_ urls: [URL]) throws -> [URL] {
        let batch = try makeBatch()
        var names = Set<String>()
        return try urls.map { url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let copy = batch.appendingPathComponent(Self.uniqueName(url.lastPathComponent, among: &names))
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        }
    }

    /// Writes `data` in as a file named `suggestedName`.
    func stage(data: Data, suggestedName: String) throws -> URL {
        let copy = try makeBatch().appendingPathComponent(suggestedName)
        try data.write(to: copy)
        return copy
    }

    /// Deletes the folder and everything in it. Missing folders are fine.
    func remove() {
        do {
            try FileManager.default.removeItem(at: root)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Self.logger.error("Cannot remove staging folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A new empty folder inside the area, for files on their way out (Share).
    func makeFolder() throws -> URL {
        try makeBatch()
    }

    private func makeBatch() throws -> URL {
        let batch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        return batch
    }

    /// `name`, or "name 2.ext", "name 3.ext", … when `names` (lowercased) already has it:
    /// the file system ignores case.
    static func uniqueName(_ name: String, among names: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while names.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        names.insert(candidate.lowercased())
        return candidate
    }
}

/// A photo or video from `PhotosPicker`, received as a file rather than loaded into memory.
/// The received file is deleted once the import returns, so it is copied to a temporary
/// folder first; the caller stages it and then deletes `folder`.
struct PickedMedia: Transferable {
    let url: URL

    /// The temporary folder holding `url`.
    var folder: URL { url.deletingLastPathComponent() }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie, importing: receive)
        FileRepresentation(importedContentType: .image, importing: receive)
    }

    private static func receive(_ received: ReceivedTransferredFile) throws -> PickedMedia {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(received.file.lastPathComponent)
        try FileManager.default.copyItem(at: received.file, to: copy)
        return PickedMedia(url: copy)
    }

    /// The same file under `name`, in the same folder.
    func renamed(to name: String) throws -> PickedMedia {
        guard name != url.lastPathComponent else { return self }
        let target = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: target)
        return PickedMedia(url: target)
    }

    /// Whether an item of these types may be loaded into memory when Photos offers it only as
    /// data: images only. A video can be gigabytes, so it is added from a file or not at all.
    static func mayLoadIntoMemory(_ types: [UTType]) -> Bool {
        types.contains { $0.conforms(to: .image) } && !types.contains { $0.conforms(to: .audiovisualContent) }
    }

    /// The name a picked photo or video is added under: the name Photos gave the file
    /// (`received`), with the extension of the item's type when it has none, or one that isn't
    /// an image's (a video's) extension. "Photo" or "Video" (localized) when Photos gave no name,
    /// or only an identifier.
    static func fileName(received: String?, contentTypes: [UTType]) -> String {
        let type = contentTypes.first { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) }
            ?? contentTypes.first
        let isVideo = type?.conforms(to: .audiovisualContent) == true
        var base = ((received ?? "") as NSString).deletingPathExtension
        var ext = ((received ?? "") as NSString).pathExtension
        if base.isEmpty || isIdentifier(base) {
            // Explicit keys: a bare "Photo" or "Video" key could clash with a UI label later.
            base = isVideo
                ? String(localized: "PickedMedia.videoName", defaultValue: "Video",
                         comment: "File name for a video added from Photos that has no name of its own. It becomes the file's name inside the archive, followed by the extension (e.g. “Video.mov”). Avoid “/” and “:”.")
                : String(localized: "PickedMedia.photoName", defaultValue: "Photo",
                         comment: "File name for a photo added from Photos that has no name of its own. It becomes the file's name inside the archive, followed by the extension (e.g. “Photo.heic”). Avoid “/” and “:”.")
        }
        let kind: UTType = isVideo ? .audiovisualContent : .image
        let extType = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        if extType?.conforms(to: kind) != true, let preferred = type?.preferredFilenameExtension {
            ext = preferred
        }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// A UUID, or a Photos resource query such as "version=1&uuid=…", rather than a name.
    private static func isIdentifier(_ base: String) -> Bool {
        UUID(uuidString: base) != nil || base.contains("uuid=")
    }
}

/// A picked photo or video, as `ScreenState.addPhotos` loads it: `PhotosPickerItem` in the
/// app, a stand-in in tests.
protocol PickedItem: Sendable {
    var supportedContentTypes: [UTType] { get }
    /// The item as a file; nil when Photos offers none.
    func loadFile() async throws -> PickedMedia?
    /// The item's bytes in memory; nil when Photos offers none.
    func loadData() async throws -> Data?
}
