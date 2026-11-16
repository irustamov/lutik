import Foundation

/// The up-front refusals of `ArchiveWriter.writeVolumes` (everything but the volume count, which only the
/// split writer can see). Nothing here writes, creates or removes anything.
enum VolumeFolderChecks {
    static func refuse(source: (any ArchiveReading)?, format: ArchiveFormat, directory: URL,
                       options: ArchiveWriteOptions) throws(ArchiveError) {
        guard format.supportsVolumes else { throw .unsupportedFormat }
        if let size = options.volumeSize, size < ArchiveWriteOptions.minimumVolumeSize {
            throw .io("A volume must be at least \(ArchiveWriteOptions.minimumVolumeSize) bytes")
        }

        let name = directory.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw .io("\(name) does not exist")
        }
        guard isDirectory.boolValue else { throw .io("\(name) is not a folder") }

        // Before the emptiness check, so a folder holding the source gets this message.
        // Compared on scalars (after NFC, which keeps the canonical equivalence a String prefix test had): "/"
        // followed by a combining mark or ZWJ is one Character that is not "/", so a Character `hasPrefix` missed
        // `<folder>/\u{301}x`. NFC never makes or absorbs "/".
        func scalars(_ url: URL) -> [Unicode.Scalar] {
            Array(LibArchiveWriter.canonicalPath(url).precomposedStringWithCanonicalMapping.unicodeScalars)
        }
        var prefix = scalars(directory)
        if prefix.last != "/" { prefix.append("/") }
        for part in source?.volumeURLs ?? [] where scalars(part).starts(with: prefix) {
            throw .io("The archive being saved is inside \(name)")
        }

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw .io("Could not read \(name): \(error.localizedDescription)")
        }
        guard contents.isEmpty else { throw .io("\(name) is not empty") }
    }
}
