import Foundation
import UniformTypeIdentifiers
import KernirCore

/// What the save options form edits: the format plus `ArchiveWriteOptions`.
/// Every capability comes from KernirCore's `ArchiveFormat`; nothing here is format-specific.
struct ArchiveSaveSettings: Equatable, Sendable {
    enum Problem: Equatable, Sendable {
        case passwordEmpty, passwordMismatch, encryptionUnsupported
        /// The volume size is under `VolumeSplit.minimumBytes` (1 MB).
        case volumeTooSmall
        /// The typed volume size is no number greater than zero.
        case volumeSizeInvalid
        /// The estimated archive needs more than `VolumeSplit.maximumVolumes` (999) volumes.
        case tooManyVolumes

        var message: String {
            switch self {
            case .passwordEmpty: String(localized: "Enter a password.", table: "Shared")
            case .passwordMismatch: String(localized: "The passwords don't match.", table: "Shared")
            case .encryptionUnsupported:
                String(localized: "This format doesn't support the chosen encryption.", table: "Shared")
            case .volumeTooSmall:
                String(localized: "Volumes must be at least \(KernirFormat.size(VolumeSplit.minimumBytes)).", table: "Shared",
                       comment: "Save options, Split into volumes: the typed volume size is too small. %@ is the smallest size, such as “1 MB”.")
            case .volumeSizeInvalid: String(localized: "Enter a volume size greater than zero.", table: "Shared")
            case .tooManyVolumes:
                String(localized: "Too many volumes. Choose a larger volume size.", table: "Shared")
            }
        }

        init(_ problem: VolumeSplit.Problem) {
            switch problem {
            case .tooSmall: self = .volumeTooSmall
            case .invalidSize: self = .volumeSizeInvalid
            case .tooManyVolumes: self = .tooManyVolumes
            }
        }
    }

    var format: ArchiveFormat
    /// The password lives in `options.password`.
    var options: ArchiveWriteOptions
    var verifyPassword: String
    /// How the saved archive is split into volumes. Setting it sets `options.volumeSize` for a format
    /// that can split (`supportsVolumes`: 7z and ZIP) and clears it for any other, as does
    /// `formatDidChange()`. `init(format:options:verifyPassword:)` takes `options` as given and
    /// doesn't sync, so until one of those runs `volumeSize` may differ from `split`. Never
    /// remembered: `init(model:)` starts unsplit, and `ArchiveModel.apply(_:)` drops `volumeSize`.
    var split: VolumeSplit = .none {
        didSet { syncVolumeSize() }
    }
    /// About how big the saved archive will be, for the too-many-volumes check: the model's
    /// compressed size, else its total size; nil when unknown (no check).
    var estimatedSize: Int64?

    init(format: ArchiveFormat, options: ArchiveWriteOptions, verifyPassword: String = "") {
        self.format = format
        self.options = options
        self.verifyPassword = verifyPassword
    }

    /// Whether a save panel or sheet starts with "Exclude Mac metadata" on, when no saved options
    /// say otherwise. On by default.
    /// iOS uses the same value: Save As Copy follows it,
    /// New Archive starts from it (`NewArchiveFlow.defaultSettings()`), and both sheets have the row.
    static let excludesMacMetadataByDefault = true

    /// Starts from the options last saved with, else from the source archive's encryption,
    /// method and password, else the format's defaults. A read-only format becomes the first writable one.
    /// Fresh options exclude Mac metadata when `defaultExcludesMacMetadata`; saved ones keep their
    /// choice, which then applies to every save, plain ⌘S included.
    /// A volume size in saved options is dropped: every save starts unsplit.
    @MainActor init(model: ArchiveModel,
                    defaultExcludesMacMetadata: Bool = ArchiveSaveSettings.excludesMacMetadataByDefault) {
        let options: ArchiveWriteOptions
        if let saved = model.saveOptions {
            options = saved
        } else if let reader = model.reader {
            options = Self.sourceOptions(of: reader, password: model.password,
                                         excludesMacMetadata: defaultExcludesMacMetadata)
        } else {
            options = ArchiveWriteOptions(excludesMacMetadata: defaultExcludesMacMetadata)
        }
        let format = model.format.isWritable ? model.format : (ArchiveFormat.writable.first ?? model.format)
        self.init(format: format, options: options, verifyPassword: options.password ?? "")
        self.options.volumeSize = nil
        estimatedSize = model.compressedSize ?? model.totalSize
        formatDidChange()
    }

    /// Turning it on picks the format's first strong scheme; turning it off forgets the password.
    var isEncrypting: Bool {
        get { options.encryption != .none }
        set {
            guard newValue != isEncrypting else { return }
            if newValue {
                let schemes = format.supportedEncryptions.filter { $0 != .none }
                options.encryption = schemes.first { !$0.isWeak } ?? schemes.first ?? .none
            } else {
                stopEncrypting()
            }
        }
    }

    /// The password the saved archive opens with; nil when it isn't encrypted.
    var password: String? { isEncrypting ? options.password : nil }

    /// Empty when the settings can be saved: at most one encryption problem, then at most one
    /// split problem. Method and level are never problems: the writer falls back to the default
    /// method and clamps the level.
    var problems: [Problem] {
        var problems: [Problem] = []
        if let problem = encryptionProblem { problems.append(problem) }
        if format.supportsVolumes, let problem = split.problem(estimatedSize: estimatedSize) {
            problems.append(Problem(problem))
        }
        return problems
    }

    private var encryptionProblem: Problem? {
        guard isEncrypting else { return nil }
        if !format.supportedEncryptions.contains(options.encryption) { return .encryptionUnsupported }
        if (options.password ?? "").isEmpty { return .passwordEmpty }
        if options.password != verifyPassword { return .passwordMismatch }
        return nil
    }

    /// Fits the options to a newly chosen `format`: unsupported choices go back to the format's
    /// defaults, the level is clamped, and encryption falls back to the format's first strong
    /// scheme (or none). A format that can't split drops the split.
    mutating func formatDidChange() {
        if let method = options.method, !format.supportedMethods.contains(method) { options.method = nil }
        options.method = options.method ?? format.defaultMethod

        if let range = format.compressionLevelRange {
            options.compressionLevel = (options.compressionLevel ?? format.defaultCompressionLevel)
                .map { min(max($0, range.lowerBound), range.upperBound) }
        } else {
            options.compressionLevel = nil
        }

        if isEncrypting, !format.supportedEncryptions.contains(options.encryption) {
            if let strong = format.supportedEncryptions.first(where: { $0 != .none && !$0.isWeak }) {
                options.encryption = strong
            } else {
                stopEncrypting()
            }
        }

        if !format.supportsSolid { options.solid = nil }

        if !format.supportsVolumes { split = .none }
        syncVolumeSize()
    }

    /// `options.volumeSize` from `split`, for a format that can split; nil for any other.
    private mutating func syncVolumeSize() {
        options.volumeSize = format.supportsVolumes ? split.bytes : nil
    }

    /// No encryption, and no password left to store with the options or prefill later.
    private mutating func stopEncrypting() {
        options.encryption = .none
        options.password = nil
        verifyPassword = ""
    }

    /// `name` with its archive extension (if any) replaced by `format`'s: "Photos.tar.gz" → "Photos.zip".
    /// For a part of a split archive (`isVolumeSet`), the set's name instead: "s7.7z.001" → "s7.7z".
    static func fileName(_ name: String, for format: ArchiveFormat, isVolumeSet: Bool = false) -> String {
        let base = isVolumeSet ? volumeSetBaseName(name) : (droppingArchiveExtension(name) ?? name)
        return base + "." + format.fileExtension
    }

    /// The extension the macOS save panel proposes for `format`: its type's preferred one when
    /// that is one of the format's own ("tgz", "tbz2", "txz"), else `fileExtension`. The panel
    /// judges a name by its last extension only and can't carry "tar.gz" (no type has it), so a
    /// bare name typed over "x.tar.gz" got "gz", plain gzip. Deliberately so.
    static func savePanelExtension(for format: ArchiveFormat) -> String {
        let own = [format.fileExtension] + ArchiveBaseName.alternateExtensions(of: format)
        if let preferred = KernirDocumentTypes.utType(for: format).preferredFilenameExtension,
           own.contains(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) {
            return preferred
        }
        return format.fileExtension
    }

    /// The name the save panel proposes: a base name plus `savePanelExtension(for:)`.
    /// - A plain file drops every stacked archive extension: "s2-plain.tar.gz" → "s2-plain.tgz",
    ///   and so is the "s2-plain.tar.tgz" NSDocument starts with (it swaps only the last extension).
    /// - A part of a split archive (`isVolumeSet`) proposes the set's name, `volumeSetBaseName(_:)`:
    ///   the part suffix and only ONE recognized archive suffix go, a compound one counting as one.
    ///   "s7.7z.001" → "s7.7z", but "x.tar.tgz.001" keeps its
    ///   "tar": base "x.tar", so for `.tarGzip` → "x.tar.tgz".
    static func savePanelProposal(_ name: String, for format: ArchiveFormat, isVolumeSet: Bool = false) -> String {
        var base = name
        if isVolumeSet {
            base = volumeSetBaseName(name)
        } else {
            while let shorter = droppingArchiveExtension(base) { base = shorter }
        }
        return base + "." + savePanelExtension(for: format)
    }

    /// The name of the split archive `partName` belongs to: `ArchiveBaseName.of(_:isVolumeSet:)`, its
    /// part suffix and one recognized archive suffix dropped. "Photos.part1.rar", "Photos.r00",
    /// "Photos.zip.001", "span.z01", "span.zip" → "Photos", "span". A dot-only stem falls back to the
    /// file name: "...part1.rar" (stem "..") and "..z01" (stem ".") keep their whole name.
    static func volumeSetBaseName(_ partName: String) -> String {
        ArchiveBaseName.of(partName, isVolumeSet: true)
    }

    /// Whether saving to `url` would write over one of `parts`, the files of a split archive. A set
    /// is read-only: Save As must never land on a part. Compares file identity (symlinks followed;
    /// covers a case-insensitive volume), then the standardized, symlink-resolved path, for a
    /// destination that doesn't exist yet. One file is no set.
    static func isVolumePart(_ url: URL, of parts: [URL]) -> Bool {
        guard parts.count > 1 else { return false }
        let identity = fileIdentity(url)
        let path = canonicalPath(url)
        return parts.contains { part in
            if let identity, identity == fileIdentity(part) { return true }
            return canonicalPath(part) == path
        }
    }

    /// The folder name proposed for a split save: `ArchiveBaseName.of(_:isVolumeSet:)`, `name` without
    /// one recognized archive suffix, a compound one counting as one ("Photos.tar.gz" → "Photos",
    /// "s2-plain.tar.tgz" → "s2-plain.tar"). A part of a split archive
    /// (`isVolumeSet`) proposes the set's name: "s7.7z.001" → "s7". The volumes inside are named by
    /// the writer. A dot-only stem falls back to the file name: "..zip" and "...tar.gz" propose
    /// themselves. That also holds for the panel's name field, where a typed "." or ".." comes back
    /// as it is: the panel's own checks refuse it (`SplitSetPlacement.splitDestinationError`). Names
    /// with other dots keep them: ".hidden", "...", "a.".
    static func splitFolderProposal(_ name: String, isVolumeSet: Bool = false) -> String {
        ArchiveBaseName.of(name, isVolumeSet: isVolumeSet)
    }

    /// Whether a split save into `folder` could delete one of `sources`: `folder` is a source,
    /// holds one at any depth, or lies inside one, so replacing it would remove what is being
    /// read or added. Callers pass both the open archive's files (the document's URL and every
    /// part in `reader.volumeURLs`) and every pending addition's URL
    /// (`model.changes.additions.map(\.sourceURL)`): replacing a file being added loses the
    /// original along with the xattrs and tags the archive doesn't keep.
    ///
    /// Compares file identities (symlinks followed) along the symlink-resolved paths: `folder`
    /// against each source and every folder above it, and each source against every folder above
    /// `folder`. The file system does the name lookups, so a folder spelled in another case matches
    /// exactly where the volume ignores case. A source that no longer exists is walked up from the
    /// deepest folder still there. A folder that doesn't exist holds nothing.
    static func isUnsafeSplitDestination(_ folder: URL, sources: [URL]) -> Bool {
        guard let identity = fileIdentity(folder) else { return false }
        let holdsSource = sources.contains { source in
            pathAndAncestors(of: source).contains { fileIdentity(URL(fileURLWithPath: $0)) == identity }
        }
        if holdsSource { return true }
        let sourceIdentities = Set(sources.compactMap(fileIdentity))
        return pathAndAncestors(of: folder).contains { path in
            fileIdentity(URL(fileURLWithPath: path)).map(sourceIdentities.contains) ?? false
        }
    }

    /// Whether a split save may replace what is at `url`, an item the save panel's "Replace?" covers
    /// (q3 rule (a)): a real folder, opened with `O_NOFOLLOW`, that is empty or holds nothing but an
    /// earlier set named after it. Every entry must be a regular file, by `fstatat` relative to that
    /// folder without following a symlink, that `isSplitVolumeName` accepts
    /// with the folder's own name as the base. Two other entries are allowed: a `.DS_Store`, which
    /// Finder leaves in every folder it shows, and an AppleDouble "._<part>" for any name a part may
    /// have, which FAT and exFAT keep beside each file for its extended attributes.
    /// Gaps and stale parts still make a set.
    ///
    /// Not replaceable: nothing at `url`, a file, a symlink (even to a set folder; the replace would
    /// delete the link), a folder that can't be listed, and a folder holding anything else: another
    /// hidden item, a subfolder or a symlink. The listing keeps hidden items, which are exactly the
    /// ones that must refuse. `lastPathComponent` ignores the trailing slash an existing folder's
    /// panel URL has (q2).
    static func isReplaceableSetFolder(_ url: URL) -> Bool {
        replaceableSetFolderEntries(url) != nil
    }

    /// The entries of the folder at `url` that made `isReplaceableSetFolder` say yes, nil when it says no.
    /// What a split save replacing the set in place records before it writes.
    static func replaceableSetFolderEntries(_ url: URL) -> [FolderEntry]? {
        guard let entries = folderEntries(url) else { return nil }
        let baseName = url.lastPathComponent
        let approved = entries.allSatisfy { entry in
            let partName = entry.name.hasPrefix("._") ? String(entry.name.dropFirst(2)) : entry.name
            return (entry.name == ".DS_Store" || isSplitVolumeName(partName, baseName: baseName))
                && entry.type == S_IFREG
        }
        return approved ? entries : nil
    }

    /// One entry of a folder listing: its exact name and its type bits (`S_IFREG`, `S_IFDIR`, …), and
    /// its device and inode, by the same `fstatat` (no follow): which file it is, not only what it is
    /// called (a file rewritten under the name is another one).
    struct FolderEntry: Equatable, Sendable {
        let name: String
        let type: mode_t
        var device: dev_t = 0
        var inode: ino_t = 0
    }

    /// Every entry of the folder at `url` but "." and "..", "._" files too (`directoryEntries`); nil when
    /// `url` isn't a folder (a symlink isn't followed) or can't be listed in full.
    static func folderEntries(_ url: URL) -> [FolderEntry]? {
        // One descriptor for the folder, opened without following a symlink at `url`, then listed and
        // each entry `lstat`ed relative to it: a folder swapped for a symlink, or an
        // entry swapped, between the checks can't make another folder's contents count.
        let descriptor = open(lstatPath(url), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            return nil
        }
        defer { closedir(directory) }
        return directoryEntries(directory)
    }

    /// Every entry of `directory` but "." and "..", by `readdir`, with its type bits, device and inode by
    /// `fstatat` relative to the folder, not following a symlink; nil when it can't be listed in full, an entry
    /// can't be `lstat`ed, or a name isn't valid UTF-8 (a lossy decode could turn
    /// another file's name into a part's). Not `FileManager.contentsOfDirectory`: that drops
    /// AppleDouble "._" files, with or without the file they belong to, and all but a part's must
    /// refuse a replace.
    private static func directoryEntries(_ directory: UnsafeMutablePointer<DIR>) -> [FolderEntry]? {
        let folder = dirfd(directory)
        var entries: [FolderEntry] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? entries : nil }
            let length = Int(entry.pointee.d_namlen)
            // Not `String(validating:as:)`: macOS 15 / iOS 18, past the deployment targets. A decode
            // that repaired invalid UTF-8 doesn't round-trip, so the compare refuses it the same way.
            let decoded: String? = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                let buffer = bytes.prefix(length)
                let name = String(decoding: buffer, as: UTF8.self)
                guard name.utf8.elementsEqual(buffer) else { return nil }
                return name
            }
            guard let name = decoded else { return nil }
            if name == "." || name == ".." { continue }
            var info = stat()
            let found = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) { cName in
                    fstatat(folder, cName, &info, AT_SYMLINK_NOFOLLOW) == 0
                }
            }
            guard found else { return nil }
            entries.append(FolderEntry(name: name, type: info.st_mode & S_IFMT, device: info.st_dev,
                                       inode: info.st_ino))
        }
    }

    /// Whether `name` is a volume of a split set the writer names `baseName`: `<base>.<ext>.NNN` with
    /// exactly three ASCII digits (KernirCore's `VolumePlan.name`, internal there, so matched by shape),
    /// or `<base>.<ext>`, the plain name the writer gives a set of one volume. `<ext>` is the
    /// `fileExtension` of a format that `supportsVolumes` (7z, ZIP). Matched as a suffix, so a base
    /// with dots of its own ("v1.2 notes") works. Base and extension ignore case; the compare is
    /// NSString's non-literal `caseInsensitiveCompare`, which also treats NFC and NFD as equal.
    static func isSplitVolumeName(_ name: String, baseName: String) -> Bool {
        var stem = Substring(name)
        let number = stem.suffix(4)
        if number.count == 4, number.first == ".", number.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
            stem = stem.dropLast(4)
        }
        return ArchiveFormat.allCases.contains { format in
            guard format.supportsVolumes else { return false }
            let suffix = "." + format.fileExtension
            guard stem.count > suffix.count,
                  stem.suffix(suffix.count).caseInsensitiveCompare(suffix) == .orderedSame else { return false }
            return stem.dropLast(suffix.count).caseInsensitiveCompare(baseName) == .orderedSame
        }
    }

    /// The highest number `freeSplitFolderName` tries: "Photos 999".
    static let maximumSplitFolderNumber = 999

    /// The folder name a split save proposes in `directory` (q3 rule (b)): `name`, or, when that is
    /// taken, the first free of "name 2", "name 3" … "name 999", the way Finder numbers a copy. When
    /// all are taken it falls back to `name`; `panel(_:validate:)` then refuses what isn't a set.
    /// Before the panel's grant it can't list a folder to tell an earlier set from other files, so
    /// every existing name counts as taken. No folder known (the panel's `directoryURL` is nil):
    /// `name`, unchecked; `validate` still refuses what may not be replaced. `isTaken` is
    /// `isNameTaken` except in tests.
    ///
    /// At worst, with every name taken, this makes 999 `lstat` calls on the main thread. Each is cheap, and that
    /// needs a folder holding "name" and "name 2" … "name 999".
    static func freeSplitFolderName(_ name: String, in directory: URL?,
                                    isTaken: (URL) -> Bool = ArchiveSaveSettings.isNameTaken) -> String {
        guard let directory else { return name }
        func isFree(_ candidate: String) -> Bool {
            !isTaken(directory.appendingPathComponent(candidate, isDirectory: false))
        }
        if isFree(name) { return name }
        for number in 2...maximumSplitFolderNumber where isFree("\(name) \(number)") {
            return "\(name) \(number)"
        }
        return name
    }

    /// Whether anything holds `url`'s name, by `lstat`: only ENOENT means free. A dangling symlink is
    /// taken (`stat` would follow it and say free), and so is a name `lstat` can't answer for
    /// (EPERM without a grant, EACCES, …), which may hide an item.
    static func isNameTaken(_ url: URL) -> Bool {
        var info = stat()
        return lstat(lstatPath(url), &info) == 0 || errno != ENOENT
    }

    /// `url`'s standardized path without a trailing slash: `lstat` and `open` with `O_NOFOLLOW` follow
    /// a symlink named "Link/", and an existing folder's panel URL ends in one (q2).
    private static func lstatPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `url`'s symlink-resolved path, then each folder above it up to "/".
    private static func pathAndAncestors(of url: URL) -> [String] {
        var paths = [canonicalPath(url)]
        while let path = paths.last {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { break }
            paths.append(parent)
        }
        return paths
    }

    /// Device and inode of the file at `url`, following symlinks; nil when nothing is there.
    private static func fileIdentity(_ url: URL) -> [UInt64]? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return [UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino)]
    }

    /// `url` standardized, then symlink-resolved: the whole path when it exists, else its folder
    /// plus the last component, else the standardized path as it is.
    private static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        func resolved(_ path: String) -> String? {
            guard let buffer = realpath(path, nil) else { return nil }
            defer { free(buffer) }
            return String(cString: buffer)
        }
        if let path = resolved(standardized.path) { return path }
        if let folder = resolved(standardized.deletingLastPathComponent().path) {
            return URL(fileURLWithPath: folder).appendingPathComponent(standardized.lastPathComponent).path
        }
        return standardized.path
    }

    /// `name` without its archive extension ("x.tar.gz" → "x"); nil when it has none, or is
    /// nothing but one ("tar.gz").
    private static func droppingArchiveExtension(_ name: String) -> String? {
        // Longest first, so "tar.gz" wins over "gz".
        let known = Set(ArchiveFormat.allCases.flatMap {
            [$0.fileExtension] + ArchiveBaseName.alternateExtensions(of: $0)
        }).sorted { $0.count > $1.count }
        for ext in known {
            if let range = name.range(of: "." + ext, options: [.caseInsensitive, .anchored, .backwards]),
               range.lowerBound > name.startIndex {
                return String(name[..<range.lowerBound])
            }
        }
        return nil
    }
}
