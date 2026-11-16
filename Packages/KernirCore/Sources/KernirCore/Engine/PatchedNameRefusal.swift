/// Names that a Kernir libarchive patch refuses inside libarchive, before the names reach Swift. Such a reader cannot
/// let `walkHeaders` see the names first (7z copies its whole names block, xar its whole TOC, ISO 9660 a whole
/// directory and its continuation areas, the seekable zip reader its whole central directory, before the first header
/// is returned), so the patch refuses with ARCHIVE_FATAL and a fixed message, which `ReadSession` passes on as
/// `.corrupted(message)`. The listing walk (`LibArchiveReader.headerFailure`) turns each one into the
/// `ArchiveNestingError` the Swift-side limit for the same thing throws, so a caller gets one error for a name or a
/// total over the limits, whichever side refused it, and an encrypted 7z header never turns it into `.wrongPassword`.
enum PatchedNameRefusal {
    /// The patches' exact `archive_error_string` messages and the limit each one stands for. Exact, so a damaged
    /// archive's message can never be taken for a refusal; SevenZipNameLimitTests reads each 7z message from
    /// libarchive itself, XarTOCLimitTests each xar one and ISO9660LimitTests each ISO 9660 one, so a reworded patch
    /// fails there instead of falling back to `.corrupted`.
    static let limits: [String: ArchiveNestingError.Limit] = [
        // Patch 0014 (7z read_Header): one name over 65,536 UTF-16 units is over the 64 KiB of UTF-8 a stored name
        // may hold (`NestingLimits.maxRawNameBytes`).
        "7-Zip entry name is longer than 65536 UTF-16 units": .pathLength,
        // Patches 0014 and 0016: a names block over twice the names limit in UTF-16 (plus the terminators) holds more
        // than the `maxTotalNameBytes` of UTF-8 names and link targets an archive may list. It does not grow with
        // `nameBytesPerEntry`: the count it would grow by is only claimed by the header.
        "7-Zip entry names take more UTF-16 than the names limit": .totalPathBytes,
        // Patch 0016: more files, or more folders, unpack streams or (4 times as many) pack streams, than the
        // archive may list (`NestingLimits.maxEntries`), refused before libarchive allocates them.
        "7-Zip archive has more entries than the entry limit": .entryCount,
        "7-Zip archive has more folders or streams than the entry limit": .entryCount,
        // Patch 0015 (xar read_toc): an entry nested deeper than the 200 folders a path may hold
        // (`NestingLimits.maxComponents`), bare folders included.
        "xar entry nests more than 200 directories deep": .depth,
        // Patch 0015: a pathname or a link target over 65,536 bytes is over the 64 KiB a stored name may hold.
        "xar entry name is longer than 65536 bytes": .pathLength,
        "xar link target is longer than 65536 bytes": .pathLength,
        // Patch 0020: an <ea>'s <name> (an extended attribute name) over 65,536 bytes, the same per-name limit.
        "xar extended attribute name is longer than 65536 bytes": .pathLength,
        // Patches 0015 and 0016: pathnames and link targets (and <ea> names, patch 0020), and then the hardlink
        // target copies, over the names an archive may list (256 MiB, or 512 bytes per <file> so far once that is
        // more).
        "xar entry names and link targets take more than the names limit": .totalPathBytes,
        "xar hardlink targets take the entry names past the names limit": .totalPathBytes,
        // Patch 0016, 0019: listed <file> elements over the limit are refused; any <file> over 2x the limit (bounded
        // memory); more <ea> elements than the archive may list, or
        // more than 1,024 <ea> on one file, whose cost grows with the square of their count.
        "xar archive has more entries than the entry limit": .entryCount,
        "xar entry has more than 1024 extended attributes": .entryCount,
        "xar archive has more extended attributes than the entry limit": .entryCount,
        // Patch 0021 (ISO 9660 read_children, read_CE): every directory record, the root included, over the entry
        // limit, counted before it is allocated (multi-extent parts, CL placeholders and a hidden rr_moved too, so
        // such an image can be refused slightly before Swift's count); a Rockridge name or link target over 65,536
        // bytes; names and link targets over the names an image may list (256 MiB, or 512 bytes per record so far
        // once that is more), charged after each record and each continuation area, which several records can share;
        // continuation-area bytes count too, each record's pass over each area, held to that allowance plus the bytes
        // read so far.
        "ISO9660 image has more entries than the entry limit": .entryCount,
        "ISO9660 entry name is longer than 65536 bytes": .pathLength,
        "ISO9660 link target is longer than 65536 bytes": .pathLength,
        "ISO9660 entry names and link targets take more than the names limit": .totalPathBytes,
        // Patch 0022 (zip slurp_central_directory, the seekable reader): more central-directory records with a new
        // local header offset than the archive may list, or more than twice that in all, and the record names over
        // the names an archive may list (256 MiB, or 512 bytes per listed record so far once that is more).
        "ZIP archive has more entries than the entry limit": .entryCount,
        "ZIP entry names take more than the names limit": .totalPathBytes,
        // Patch 0025: the record comments, which the reader keeps for every record (patch 0012), charged to the same
        // total after the names; names plus comments over it. The comments share the counter, so when earlier
        // comments use up the allowance, the next record's name is refused with the names message above; the error
        // is the same `.totalPathBytes`.
        "ZIP entry comments take the entry names past the names limit": .totalPathBytes,
    ]

    /// The refusal `error` stands for, or nil when it is not one of the patches' refusals.
    static func refusal(for error: ArchiveError) -> ArchiveNestingError? {
        guard case .corrupted(let message) = error, let limit = limits[message] else { return nil }
        return ArchiveNestingError(limit: limit)
    }
}
