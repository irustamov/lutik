import Foundation
import UniformTypeIdentifiers

/// What a Finder Service received, sorted for its job: every file or folder for Compress, and
/// the archives among them for Extract Here. Reads names and types only, never the contents.
struct ServicesRequest: Equatable, Sendable {
    /// Each file or folder once, in the order received: what Compress takes.
    let items: [URL]
    /// The archives Extract Here extracts: one per split set (its first part, which opens the
    /// whole set), with `.jar` and `.whl` but no other zip-based package (`.war`, `.apk`…),
    /// which only open in Lutik.
    let archives: [URL]

    init(urls: [URL]) {
        var seen = Set<String>()
        items = urls.filter { $0.isFileURL && seen.insert(Self.key($0)).inserted }

        // One job per set: a plain archive is a set of its own. The first part wins.
        var firstParts: [SetKey: (url: URL, number: Int)] = [:]
        var order: [SetKey] = []
        for url in items where Self.isArchive(url) {
            let folder = Self.key(url.deletingLastPathComponent())
            let name = url.lastPathComponent
            let part = Self.part(of: name)
            let set = SetKey(folder: folder, name: (part?.set ?? name).lowercased(), isSplit: part != nil)
            let number = part?.number ?? 0
            if let first = firstParts[set] {
                if number < first.number { firstParts[set] = (url, number) }
            } else {
                firstParts[set] = (url, number)
                order.append(set)
            }
        }
        // A spanned zip's last part is the plain "x.zip": it goes with the "x.z01" set if that came too.
        // An old-style RAR's first part is the plain "x.rar": the "x.r00" set's job opens it.
        for set in order where !set.isSplit {
            if set.name.hasSuffix(".zip") {
                let spanned = SetKey(folder: set.folder, name: "z:" + set.name.dropLast(".zip".count), isSplit: true)
                if firstParts[spanned] != nil { firstParts[set] = nil }
            } else if set.name.hasSuffix(".rar") {
                let old = SetKey(folder: set.folder, name: "o:" + set.name.dropLast(".rar".count), isSplit: true)
                if firstParts[old] != nil { firstParts[old] = firstParts.removeValue(forKey: set) }
            }
        }
        archives = order.compactMap { firstParts[$0]?.url }
    }

    /// A split set, or a plain archive, in one folder.
    private struct SetKey: Hashable {
        let folder: String
        /// Lowercased: `part(of:)`'s set for a split set, else the file's name.
        let name: String
        let isSplit: Bool
    }

    /// The zip-based packages Extract Here takes in 0.1.0: Java's and Python's,
    /// by type or by extension (a `.whl` has its type only where the app's Info.plist imports it).
    /// Info.plist's Extract Here service sends these types too.
    static let extractablePackages: [(type: String, extension: String)] = [
        ("com.sun.java-archive", "jar"), ("org.python.wheel", "whl"),
    ]

    /// Whether Lutik opens `url` as a document: a file whose type is one of the app's document
    /// types (`KernirDocumentTypes.readable` and `.packageTypes`, the types Info.plist's
    /// CFBundleDocumentTypes give ArchiveDocument), as NSDocumentController judges it. The type is
    /// the file's own (its content type resource value; a symlink's target's), or, for a URL with
    /// no file behind it, its extension's. So a split part opens only with a declared tag
    /// (.r00…r99, .001…999, .z01…z99): ".s01" or ".000" is a plain file, which
    /// NSDocumentController could not open. The open routing (`OpenRoute`): anything else,
    /// folders too, is a plain item for a new archive.
    static func opensInKernir(_ url: URL) -> Bool {
        guard !isFolder(url) else { return false }
        let ownType = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard let type = ownType ?? UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return (KernirDocumentTypes.readable + KernirDocumentTypes.packageTypes).contains(where: type.conforms(to:))
    }

    /// A folder, or a symlink to one ("link.zip" to a folder is a folder).
    private static func isFolder(_ url: URL) -> Bool {
        url.hasDirectoryPath
            || (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// A file (not a folder) of a type Lutik reads, or a part of a split set, and no package
    /// but `extractablePackages`.
    /// A symlink is what it points to: "link.zip" to a folder is a folder.
    private static func isArchive(_ url: URL) -> Bool {
        if isFolder(url) { return false }
        if part(of: url.lastPathComponent) != nil { return true }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if extractablePackages.contains(where: { $0.extension == ext || $0.type == type?.identifier }) { return true }
        guard let type else { return false }
        if KernirDocumentTypes.packageTypes.contains(where: type.conforms(to:)) { return false }
        return KernirDocumentTypes.readable.contains(where: type.conforms(to:))
    }

    /// The set a split archive's part belongs to and its place in it: "x.part2.rar" → ("r:x", 2),
    /// "x.7z.001" → ("n:x.7z", 1), "x.z01" → ("z:x", 1), old-style RAR "x.r00" → ("o:x", 2) (its
    /// part 1, "x.rar", is a plain archive here, joined to the set in `init`). nil for any other
    /// name. The kind prefix keeps "x.zip.001" and a spanned "x.z01" apart.
    private static func part(of name: String) -> (set: String, number: Int)? {
        let patterns: [(prefix: String, regex: Regex<(Substring, Substring)>, number: (Substring) -> Int?)] = [
            ("r:", #/\.part(\d+)\.rar$/#.ignoresCase(), { Int($0) }),
            ("n:", #/\.(\d{3})$/#, { Int($0) }),
            ("z:", #/\.z(\d{2})$/#.ignoresCase(), { Int($0) }),
            // ".r00"…".r99" are parts 2…101, then ".s00"… up to ".y99", as KernirCore reads them.
            ("o:", #/\.([r-y]\d{2})$/#.ignoresCase(), { tag in
                guard let letter = tag.lowercased().unicodeScalars.first, let n = Int(tag.dropFirst()) else { return nil }
                return Int(letter.value - UnicodeScalar("r").value) * 100 + n + 2
            }),
        ]
        for (prefix, regex, number) in patterns {
            if let match = name.firstMatch(of: regex), match.range.lowerBound > name.startIndex,
               let number = number(match.output.1) {
                return (prefix + name[..<match.range.lowerBound], number)
            }
        }
        return nil
    }

    /// The URL's standardized path in NFC: two spellings of one file are one item.
    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}
