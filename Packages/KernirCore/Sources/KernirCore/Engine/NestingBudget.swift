import Foundation

/// How deep and how long entry paths may get before the reader refuses the archive (`ArchiveNestingError`).
/// Every folder a path implies is listed with its whole path, so one path of `d` components and `L` bytes costs about
/// `d × L / 2` bytes of folder paths: quadratic in depth. The per-path limits cap that cost for one path; the totals
/// cap it for the archive. Real trees sit far below: Xcode.app (184k items), a DerivedData folder (381k items) and a
/// Homebrew prefix (349k items) are at most 29 levels and 329 bytes deep, with 83-275 MiB of ancestor work and
/// 6-12 MiB of distinct folders (with `folderOverhead`).
///
/// The folder and ancestor-work totals grow with the paths charged so far, so a wide archive does not meet them for
/// its entry count alone: a tar of a whole disk or home folder, or of a Time Machine-style tree
/// ("Backups.backupdb/<Mac>/<date>/Macintosh HD - Data/..."), may hold more than a million entries. Under such a
/// prefix the real trees cost 1,213-2,190 bytes of ancestor work per path (/System/Library, node_modules, Homebrew,
/// Xcode.app, DerivedData, the last the most) and 24-59 bytes of folders per path, so these totals, if fixed, would
/// refuse one of about 490k-890k entries. The per-path allowances are 3.7 and 8.7 times those worst cases. The name
/// total grows the same way: those trees store 174-254 bytes of names per entry under the prefix, and a fixed 256 MiB
/// refused one of about 1.05-1.55 million entries (`.totalPathBytes`); `nameBytesPerEntry` is twice the worst. What
/// bounds a very large listing is the entry count (`maxEntries`, `.entryCount`), 4 million headers.
/// A path costs at most about 3.2 MB of ancestor work or of folders (200 components in 16 KiB), so a crafted archive
/// gets that much only by charging about 400 paths of ancestor work or 6,300 paths of folders for each such path
/// first, before it: over N paths it stays under `maxAncestorWork + N × ancestorWorkPerPath` and
/// `maxFolderBytes + N × folderBytesPerPath`, linear in the entry count like the listing itself (about 500-750 bytes
/// per entry at its peak), with N at most `maxEntries`: 32 GiB of ancestor work and 2 GB of folders at most.
/// Counting only paths that add a new listed entry would not tighten this: a duplicate header costs its full place
/// in the listing until the visit merges it, and the cap bounds both kinds alike.
struct NestingLimits: Sendable, Equatable {
    /// Most components in one normalized entry path. 200 is about 7 times the deepest real tree above, and stays
    /// under the 250 levels where the apps' recursive views first overflowed a 512 KiB thread stack (debug).
    var maxComponents: Int
    /// Most UTF-8 bytes in one normalized entry path. 16 KiB is 16 times Darwin's PATH_MAX (1024) and 4 times Linux's
    /// (4096), so any path a tool can store from a file system fits; a zip name may hold 64 KiB, a pax path more.
    var maxPathBytes: Int
    /// Most bytes of distinct folder paths over the whole archive, each folder counted once, plus `folderOverhead`
    /// per folder: what the listing keeps. 64 MiB fits about 250,000 folders of real-world length.
    var maxFolderBytes: Int
    /// What the folder total allows for each path charged so far, once that is more than `maxFolderBytes`; 0 keeps it
    /// fixed. 512 bytes is 8.7 times the most a real tree under a Time Machine prefix takes per path (Xcode.app, 59),
    /// and holds a listing of nothing but folders up to 384 bytes long.
    var folderBytesPerPath: Int = 0
    /// Most bytes of folder paths summed over every entry path (each entry's ancestors, counted again per entry):
    /// what building every entry's ancestors costs in time (listing, saving, renaming). 1 GiB is about 4 times
    /// the DerivedData folder above.
    var maxAncestorWork: Int
    /// What the ancestor-work total allows for each path charged so far, once that is more than `maxAncestorWork`; 0
    /// keeps it fixed. 8 KiB is 3.7 times the most a real tree under a Time Machine prefix takes per path (DerivedData,
    /// 2,190 bytes), and under 1/390 of the most one path can take.
    var ancestorWorkPerPath: Int = 0
    /// Most bytes in one name or link target as the header stores it, before any decoding or normalization. 64 KiB is
    /// the most a zip name field holds; a pax path may hold 1 MiB and a 7z name has no limit, and only "./" or "//"
    /// padding can make a stored name that long normalize under `maxPathBytes`.
    var maxRawNameBytes: Int = 64 << 10
    /// Most stored bytes of every header's name and link targets added up, checked as each header is read: what the
    /// listing holds before it decodes any name. 256 MiB is about 2.68 million entries of 100 bytes, or 1.05-1.55
    /// million of the 174-254 bytes real trees take under a Time Machine-style prefix; past that it grows with
    /// `nameBytesPerEntry`, so an honest listing meets `maxEntries` first.
    var maxTotalNameBytes: Int = 256 << 20
    /// Most headers an archive may hold, every one counted (skipped and duplicate ones too), checked as each header
    /// is read, before its names. Also what the per-path and per-entry allowances grow with at most. 4 million is
    /// about 2.6 times the largest wide tree above that the fixed name total used to admit (1.55 million).
    var maxEntries: Int = 4_000_000
    /// What the name total allows for each header so far, once that is more than `maxTotalNameBytes`; 0 keeps it
    /// fixed. 512 bytes is twice the most a real tree under a Time Machine prefix stores per entry (DerivedData, 254).
    var nameBytesPerEntry: Int = 0

    /// What each distinct folder costs beyond its path bytes: a string header, a set slot and a listed entry.
    static let folderOverhead = 128

    static let standard = NestingLimits(maxComponents: 200, maxPathBytes: 16 << 10, maxFolderBytes: 64 << 20,
                                        folderBytesPerPath: 512, maxAncestorWork: 1 << 30,
                                        ancestorWorkPerPath: 8 << 10, maxRawNameBytes: 64 << 10,
                                        maxTotalNameBytes: 256 << 20, maxEntries: 4_000_000,
                                        nameBytesPerEntry: 512)

    /// What `previewListing` holds an archive to: the Quick Look extension that calls it is killed at about 1.3 GB
    /// of footprint, and a listing inside `standard` peaked at up to 8.2 GB (4 million zip entries of 380-byte names)
    /// in Release. A preview's peak grows with the entry count (550-900 bytes per entry, by format: the walk's
    /// headers and paths, the preview's path table, libarchive's own records) and with the name bytes (1.2-3.3 times
    /// them), so every total here is fixed, with no per-entry growth: 400,000 headers and 64 MiB of names keep the
    /// costliest shapes under about 550 MB. Real trees fit to the entry limit: 32 MiB of folders is 2.7 times the most
    /// the trees above take (12 MiB at 381k items, 59 bytes a path under a Time Machine prefix), and 1 GiB of ancestor
    /// work holds 400,000 paths of 2,190 bytes. Only the names are short of that under a Time Machine prefix (174-254
    /// bytes each: 264k-385k entries fit). Per path and per name the preview reads exactly what `open` reads.
    static let preview = NestingLimits(maxComponents: 200, maxPathBytes: 16 << 10, maxFolderBytes: 32 << 20,
                                       folderBytesPerPath: 0, maxAncestorWork: 1 << 30,
                                       ancestorWorkPerPath: 0, maxRawNameBytes: 64 << 10,
                                       maxTotalNameBytes: 64 << 20, maxEntries: 400_000,
                                       nameBytesPerEntry: 0)
}

/// Charges normalized entry paths against `NestingLimits`, from the path bytes alone: no folder path is built.
///
/// A distinct folder is recognized by a hash of its path bytes together with its length. `Hasher` is seeded at random
/// per process, so a crafted archive cannot pick colliding folders; a chance collision only leaves one folder
/// uncharged. The length keeps a collision found with a known seed (`SWIFT_DETERMINISTIC_HASHING`, set in some test
/// runs) to folders of one length, so it cannot skip a much longer folder's chain.
struct NestingBudget {
    let limits: NestingLimits
    /// Bytes of ancestor paths summed over every charged path (`maxAncestorWork`).
    private(set) var ancestorWork = 0
    /// Bytes of distinct folder paths plus `folderOverhead` each (`maxFolderBytes`).
    private(set) var folderBytes = 0
    /// Paths charged so far, including one refused for `.ancestorWork` or `.folderBytes` (one refused for `.pathLength`
    /// or `.depth` is not counted): what the allowances grow with. Only paths already charged count, never the paths
    /// still to come, so a costly path is paid for by the paths before it.
    private(set) var paths = 0
    /// The folders charged so far, by hash and length. Every ancestor of a charged folder is charged too.
    private var folders = Set<Folder>()
    /// Per call: each ancestor's hash and length, outermost first.
    private var ancestors: [(hash: Int, length: Int)] = []

    private struct Folder: Hashable {
        let hash: Int
        let length: Int
    }

    init(_ limits: NestingLimits) {
        self.limits = limits
    }

    /// Refuses a name or link target with more combining marks in a row than `EntryPath.maxCombiningRun`.
    static func checkMarks(_ name: String) throws(ArchiveNestingError) {
        if EntryPath.exceedsCombiningRun(name) { throw ArchiveNestingError(limit: .combiningMarks) }
    }

    /// Refuses a normalized path (a hardlink target) longer than `maxPathBytes`, without charging it.
    func checkLength(_ path: String) throws(ArchiveNestingError) {
        guard path.utf8.count <= limits.maxPathBytes else { throw ArchiveNestingError(limit: .pathLength) }
    }

    /// Charges one normalized entry path (no empty component, so components = "/" count + 1). Throws the first limit
    /// it passes; the counts then include a path refused for `.ancestorWork` or `.folderBytes` (not one refused for
    /// `.pathLength` or `.depth`).
    mutating func charge(_ path: String) throws(ArchiveNestingError) {
        let utf8 = path.utf8
        guard utf8.count <= limits.maxPathBytes else { throw ArchiveNestingError(limit: .pathLength) }
        ancestors.removeAll(keepingCapacity: true)
        let max = limits.maxComponents
        let scanned = utf8.withContiguousStorageIfAvailable { Self.scan($0, maxComponents: max, into: &ancestors) }
            ?? Array(utf8).withUnsafeBufferPointer { Self.scan($0, maxComponents: max, into: &ancestors) }
        guard let work = scanned else { throw ArchiveNestingError(limit: .depth) }

        paths += 1
        ancestorWork += work
        guard ancestorWork <= Self.allowance(limits.maxAncestorWork, limits.ancestorWorkPerPath, paths,
                                             cap: limits.maxEntries) else {
            throw ArchiveNestingError(limit: .ancestorWork)
        }
        // Deepest first: once a folder is known, so are all of its ancestors.
        for a in ancestors.reversed() {
            guard folders.insert(Folder(hash: a.hash, length: a.length)).inserted else { break }
            folderBytes += a.length + NestingLimits.folderOverhead
        }
        guard folderBytes <= Self.allowance(limits.maxFolderBytes, limits.folderBytesPerPath, paths,
                                            cap: limits.maxEntries) else {
            throw ArchiveNestingError(limit: .folderBytes)
        }
    }

    /// `total`, or `perPath` for each of `count` (at most `cap`) when that is more; `Int.max` where the product would
    /// overflow. `cap` is `maxEntries`: no allowance grows past what the entry cap implies.
    static func allowance(_ total: Int, _ perPath: Int, _ count: Int, cap: Int) -> Int {
        let (scaled, overflow) = perPath.multipliedReportingOverflow(by: min(count, cap))
        return overflow ? .max : Swift.max(total, scaled)
    }

    /// Appends each ancestor's hash and length (the offset of its "/") to `list`, outermost first, and returns the sum
    /// of those lengths; nil once the path has more than `maxComponents` components. The hasher takes the bytes in
    /// pieces that end before each "/", so equal folder paths always hash alike.
    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>, maxComponents: Int,
                             into list: inout [(hash: Int, length: Int)]) -> Int? {
        var hasher = Hasher()
        var start = 0
        var work = 0
        for i in bytes.indices where bytes[i] == 0x2F {
            if list.count + 2 > maxComponents { return nil }
            hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: bytes[start..<i])))
            start = i
            let copy = hasher
            list.append((copy.finalize(), i))
            work += i
        }
        return work
    }
}
