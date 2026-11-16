import Foundation
import KernirCore

/// Case-only twins: archive items whose paths differ only by case as APFS folds it, such as `a.txt` and
/// `A.txt`, or `straße` and `STRASSE`: one `NameFold.key`, which is NFD(late folds(fold(NFD(path)))), never
/// an NFC form. By design they stay allowed in an archive, but extracting them onto a
/// case-insensitive volume, where they land on one name, must ask through the extract conflict dialog.
/// On HFS+, which folds less, the key also joins names that stay two there (ß / SS): a needless question or
/// a conflict refused, never a lost file (`NameFold`).
/// This finds the later twin of each pair, in the order the extraction writes them (the engine lets the
/// later one win). Pure: no disk access.
enum CaseTwinScan {
    struct Entry: Equatable, Sendable {
        let path: String
        let isDirectory: Bool
    }

    struct Twin: Equatable, Sendable {
        /// The later twin, as spelled in the entries: the one that would replace the earlier.
        let path: String
        /// The first item on that name.
        let earlierPath: String
        /// One of the two is a file and the other a folder: one name cannot hold both, so the later one
        /// can only replace the earlier or be kept beside it.
        let mixesFileAndFolder: Bool
    }

    /// The later twins among `entries` (in write order), each once, in write order. `requested` nil scans
    /// everything; otherwise only the requested item paths and their descendants (NFC), since nothing
    /// else is written. Full paths are compared folded (`NameFold.key`, as `ArchiveModel` folds), because
    /// folders merge: `D/x.txt` and `d/X.txt` collide. Two folders on one name merge and are not twins;
    /// a folder appears with its first entry, its own header or a child's. Items spelled the same after
    /// NFC are one item to the model, not twins. Paths split on the "/" scalar, never on Characters
    /// (`ArchiveEntry.components(of:)`, `parentPath(of:)`): a Character split hides `d` in `d/\u{301}x`.
    static func laterTwins(in entries: [Entry], requested: [String]?) -> [Twin] {
        let wanted = requested.map { Set($0.map(nfc)) }
        func isRequested(_ path: String) -> Bool {
            guard let wanted else { return true }
            var current = path
            while !current.isEmpty {
                if wanted.contains(current) { return true }
                current = ArchiveEntry.parentPath(of: current)
            }
            return false
        }
        // Folded path -> the first item there.
        var seen: [String: (path: String, nfcPath: String, isDirectory: Bool)] = [:]
        var reported = Set<String>()
        var twins: [Twin] = []
        for entry in entries where isRequested(nfc(entry.path)) {
            let components = ArchiveEntry.components(of: entry.path)
            var prefix = ""
            for (index, component) in components.enumerated() {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                let isDirectory = index < components.count - 1 || entry.isDirectory
                let nfcPath = nfc(prefix)
                // As spelled: the key normalizes on its own, and Foundation NFC can drop a base (`NameFold`).
                let key = NameFold.key(prefix)
                guard let earlier = seen[key] else {
                    seen[key] = (prefix, nfcPath, isDirectory)
                    continue
                }
                if earlier.nfcPath == nfcPath || (earlier.isDirectory && isDirectory) { continue }
                if reported.insert(nfcPath).inserted {
                    twins.append(Twin(path: prefix, earlierPath: earlier.path,
                                      mixesFileAndFolder: earlier.isDirectory != isDirectory))
                }
            }
        }
        return twins
    }

    /// Which twin holds the name each of `twins` (later twins in write order, as `laterTwins` returns
    /// them) lands on when its turn comes, given `answers` keyed by the later twin's path: the last earlier
    /// twin on that name answered Replace, else the first twin there. Skip leaves a twin out and Keep Both
    /// puts it beside under another name, so neither moves the name; an unanswered twin doesn't either.
    /// `ArchiveModel.extract` replaces the holder, and the questions name it (`ExtractionConflictScan`).
    static func holders(of twins: [Twin], answers: [String: ExtractionConflictResolution]) -> [String: String] {
        var holding: [String: String] = [:]  // first twin on a name -> the twin holding it
        var holders: [String: String] = [:]
        for twin in twins {
            holders[twin.path] = holding[twin.earlierPath] ?? twin.earlierPath
            if answers[twin.path] == .replace { holding[twin.earlierPath] = twin.path }
        }
        return holders
    }

    /// `items` (the requested ones) and their descendants, flattened and ordered by `writeOrder`
    /// (archive paths, compared after NFC). Items not in `writeOrder` (implicit folders, pending
    /// additions) follow, in tree order.
    static func entries(of items: [ArchiveItem], writeOrder: [String]) -> [Entry] {
        let rank = Dictionary(writeOrder.enumerated().map { (nfc($1), $0) }, uniquingKeysWith: min)
        let flat = items.flattened().enumerated().map { (offset: $0, rank: rank[nfc($1.path)], item: $1) }
        return flat.sorted { a, b in
            switch (a.rank, b.rank) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map { Entry(path: $0.item.path, isDirectory: $0.item.isDirectory) }
    }

    private static func nfc(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping
    }
}

/// Names as a case-insensitive APFS volume compares them: one key for two names exactly when APFS
/// keeps them on one name. Canonical caseless matching (Unicode D145): NFD, full Unicode case folding,
/// NFD again. `lowercased()` folds less: APFS also puts `straße` and `STRASSE`, `\u{FB00}` and `FF`,
/// `\u{3C2}` and `\u{3C3}` on one name. Foundation's fold (CFStringFold, locale nil: never the Turkish
/// dotless i) matches APFS everywhere except U+1C80–1C88 (Unicode 9 Cyrillic letter variants), mapped here.
/// Folded on NFD, never NFC: NFC composes U+0345 into its base (`\u{391}\u{342}\u{345}` to
/// `\u{1FBC}\u{342}`), the fold then expands that into a starter before U+0342, and `\u{1FB7}` ends up
/// with another key though APFS joins them; and Foundation's NFC on macOS 26.2
/// drops a supplementary base to 16 bits before a mark that composes with it (`\u{1042B}\u{308}` to
/// `\u{4F8}`), which NFD never does. So callers pass names as spelled, never Foundation-NFC'd first.
/// Checked on a live APFS volume (macOS 26.2): every assigned scalar, and 1,466,638 sequences
/// (cased scalars with combining marks, random ones), with no name APFS joins on two keys and none it
/// keeps apart on one. HFS+ folds otherwise. It folds less (not ß, ligatures or ς; not Kelvin or circled
/// letters either, which `lowercased()` already folded), so there a key can join names that stay two:
/// a needless question, or a conflict refused. It also joins some names no key joins (it ignores
/// U+200C–200F, U+202A–202E, U+206A–206F and U+FEFF, and folds Georgian U+10A0–10C5 onto U+10D0–10F5):
/// unasked, such file twins end in an error with one twin not extracted, folder twins in a conflict
/// before anything moves (a known gap, deferred).
/// One fold for the scan and the model.
enum NameFold {
    static func key(_ name: String) -> String {
        let folded = name.decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars { scalars.append(lateFolds[scalar.value] ?? scalar) }
        return String(scalars).decomposedStringWithCanonicalMapping
    }

    /// CaseFolding.txt entries Foundation's fold lacks and APFS has (probed 2026-11-11, macOS 26.2).
    private static let lateFolds: [UInt32: Unicode.Scalar] = [
        0x1C80: "\u{432}", 0x1C81: "\u{434}", 0x1C82: "\u{43E}", 0x1C83: "\u{441}", 0x1C84: "\u{442}",
        0x1C85: "\u{442}", 0x1C86: "\u{44A}", 0x1C87: "\u{463}", 0x1C88: "\u{A64B}",
    ]
}

/// Whether an extraction destination folds case. Asks the destination, or its nearest existing
/// ancestor when it doesn't exist yet. Unknown counts as case-insensitive: asking about a twin that
/// would not collide is a needless dialog, missing one loses a file. Injectable for tests.
struct DestinationCaseSensitivity: Sendable {
    var exists: @Sendable (URL) -> Bool
    /// `volumeSupportsCaseSensitiveNames` of an existing item; nil when unknown.
    var supportsCaseSensitiveNames: @Sendable (URL) -> Bool?

    static let live = DestinationCaseSensitivity(
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        supportsCaseSensitiveNames: {
            try? $0.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        })

    func isCaseInsensitive(_ destination: URL) -> Bool {
        supportsCaseSensitiveNames(nearest: destination).map { !$0 } ?? true
    }

    /// Whether the destination's volume says it folds case. Unknown is false here: `moveStaged` folds names
    /// on this answer alone only where the volume is known to fold them (elsewhere only folders staging
    /// shows as one), since on a case-sensitive volume "d" and "D" are two folders and folding them would
    /// move one with the other.
    func isKnownCaseInsensitive(_ destination: URL) -> Bool {
        supportsCaseSensitiveNames(nearest: destination) == false
    }

    /// `supportsCaseSensitiveNames` of the destination, or of its nearest existing ancestor; nil when unknown.
    private func supportsCaseSensitiveNames(nearest destination: URL) -> Bool? {
        var url = destination.standardizedFileURL
        while true {
            if exists(url) { return supportsCaseSensitiveNames(url) }
            if url.path == "/" { return nil }
            url = url.deletingLastPathComponent().standardizedFileURL
        }
    }
}
