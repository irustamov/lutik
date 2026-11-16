import Darwin
import Foundation

/// Turns an opened file into the parts of the multi-volume set it belongs to.
///
/// Four steps:
/// 1. **Gate** on the opened file's bytes, so a file merely *named* like a part opens on its own: a
///    `.rar` must carry the RAR volume flag; a spanned zip opened at its `.zip` must have an EOCD disk
///    number above 0. `.zNN` and numbered `.NNN` names have no gate (the name alone says "split").
/// 2. **Enumerate** parts 1, 2, ... by `stat` until one is absent. An absent part at or before the
///    opened one is missing. A spanned zip's count comes from its `.zip` instead.
/// 3. **Access**: open each part read-only and close it at once, so a sandbox denial is reported as
///    `.noAccess` for the folder rather than as a read error halfway through the set.
/// 4. **Completeness** from the bytes: a RAR set's last part must not say "more volumes follow" and its
///    part 1 must not say "not the first volume"; a split 7z's sizes must add up to the total its first
///    part records; a split zip's parts, read as one file, must end in an EOCD record (which may start in an
///    earlier part than the last).
///
/// Unknown probe answers: `VolumeProbe` gives `isFirst`/`isLast` nil when it cannot tell (RAR4 headers
/// encrypted, a malformed or truncated header chain, a walk past its block cap, an old RAR 2.x volume
/// without the first-volume flag, a part that is not RAR at all). nil is neither "first"/"last" nor
/// "not first"/"not last": only an explicit `false` is evidence of a missing part. With nil the resolver
/// accepts what the names and `stat` found. Refusing instead would lock out every set the probe cannot
/// fully walk (a volume with more than 100 000 headers) with a "missing part" error naming a part that
/// may well not exist; libarchive still reports a set it cannot read through as truncated or corrupted.
enum VolumeSetResolver {
    /// nil: not a set (open as a single file). Otherwise every part, in libarchive read order.
    /// Throws `ArchiveVolumeError` for a set that cannot be read whole, `ArchiveError.io` when a file's
    /// bytes cannot be read for a reason other than access.
    static func resolve(_ url: URL) throws -> [URL]? {
        let candidates = VolumeNaming.match(url)
        guard let first = candidates.first else { return nil }
        let folder = url.deletingLastPathComponent()

        switch first.pattern {
        case .zipSpanned:
            return try resolveSpanned(first, opened: url, folder: folder)
        case .rarParts, .rarOld:
            // 1. Gate. All candidates of one name share a pattern, so the gate is the same for each.
            guard try VolumeProbe.rar(at: url)?.isVolume == true else { return nil }
        case .numbered:
            break
        }

        // The first candidate whose part 1 is there wins (an unreadable part 1 counts as there: it is
        // reported as `.noAccess`, not passed over). None: part 1 of the most likely reading is missing.
        guard let naming = candidates.first(where: { state(of: $0.url(ofPart: 1)) != .absent }) else {
            // `backup.2024`, `scan.100`: a lone file with a numeric extension and no inner extension is a
            // renamed single archive (libarchive sniffs it), not a split set missing its part 1.
            if case .numbered = first.pattern, !first.base.contains(".") { return nil }
            throw error(.missing, part: 1, naming: first, folder: folder)
        }

        // 2. Enumerate.
        var parts: [URL] = []
        enumerate: for n in 1...naming.maxPart {
            let part = naming.url(ofPart: n)
            switch state(of: part) {
            case .present:
                parts.append(part)
            case .noAccess:
                throw error(.noAccess, part: n, naming: naming, folder: folder)
            case .absent:
                if n <= naming.openedPart { throw error(.missing, part: n, naming: naming, folder: folder) }
                break enumerate
            }
            // Every name up to the cap exists: the set cannot be followed any further.
            if n == naming.maxPart { throw error(.missing, part: n + 1, naming: naming, folder: folder) }
        }

        // 3. Access.
        for (i, part) in parts.enumerated() where try !isOpenable(part) {
            throw error(.noAccess, part: i + 1, naming: naming, folder: folder)
        }

        // 4. Completeness.
        let next = parts.count + 1
        switch naming.pattern {
        case .rarParts, .rarOld:
            // Part 1 first: it is the lower part number. Only `false` counts, see the type comment.
            if try VolumeProbe.rar(at: parts[0])?.isFirst == false {
                throw error(.missing, part: 1, naming: naming, folder: folder)
            }
            if try VolumeProbe.rar(at: parts[parts.count - 1])?.isLast == false {
                throw error(.missing, part: next, naming: naming, folder: folder)
            }
            return parts
        case .numbered:
            if let total = try VolumeProbe.sevenZipTotalSize(firstPart: parts[0]) {
                if try sizeSum(parts) < total { throw error(.missing, part: next, naming: naming, folder: folder) }
                return parts
            }
            if try isZip(firstPart: parts[0], base: naming.base) {
                // The set's end, not its last part: the record may start in an earlier part (SPLIT-ZIP-EOCD-STRADDLE).
                if try !VolumeProbe.zipEOCD(parts: parts).found {
                    throw error(.missing, part: next, naming: naming, folder: folder)
                }
                return parts
            }
            // Neither 7z nor zip: nothing says whether the set is whole. A lone `.001` falls through to
            // libarchive as a single file; several parts are the set as found.
            return parts.count == 1 ? nil : parts
        case .zipSpanned:
            preconditionFailure("spanned zips are resolved by resolveSpanned")
        }
    }

    // MARK: - Spanned zip

    /// `base.z01` ... `base.zNN`, `base.zip`. The `.zip` holds the central directory and, in its EOCD,
    /// its own disk index, which is the number of `.zNN` parts before it.
    private static func resolveSpanned(_ naming: VolumeNaming, opened url: URL, folder: URL) throws -> [URL]? {
        guard let zip = naming.lastPartURL() else { return nil }
        let zipName = zip.lastPathComponent
        let diskNumber: Int
        if naming.openedPart == 0 {
            // 1. Gate: opened at the `.zip`; a single-disk zip (or no EOCD) is an ordinary zip.
            let eocd = try VolumeProbe.zipEOCD(at: url)
            guard eocd.found, eocd.diskNumber > 0 else { return nil }
            diskNumber = eocd.diskNumber
        } else {
            // Opened at a `.zNN`: the part count is unknown until the `.zip` is read.
            switch state(of: zip) {
            case .absent: throw error(.missing, part: nil, fileName: zipName, naming: naming, folder: folder)
            case .noAccess: throw error(.noAccess, part: nil, fileName: zipName, naming: naming, folder: folder)
            case .present: break
            }
            guard try isOpenable(zip) else {
                throw error(.noAccess, part: nil, fileName: zipName, naming: naming, folder: folder)
            }
            let eocd = try VolumeProbe.zipEOCD(at: zip)
            // The `.zip` says it is no spanned set, or one with fewer disks than the opened part's number:
            // the opened file is none of its parts. It opens on its own (libarchive says what it is).
            guard eocd.found, eocd.diskNumber >= naming.openedPart else { return nil }
            diskNumber = eocd.diskNumber
        }

        // 2. Every `.zNN` below the `.zip` must be there.
        // More disks than the scheme can name: no stat loop, the part past the cap is what is missing.
        if diskNumber > naming.maxPart { throw error(.missing, part: naming.maxPart + 1, naming: naming, folder: folder) }
        var parts: [URL] = []
        for n in 1...diskNumber {
            let part = naming.url(ofPart: n)
            switch state(of: part) {
            case .present: parts.append(part)
            case .absent: throw error(.missing, part: n, naming: naming, folder: folder)
            case .noAccess: throw error(.noAccess, part: n, naming: naming, folder: folder)
            }
        }
        parts.append(zip)

        // 3. Access. 4. Completeness: the EOCD's disk number already fixed the parts.
        for (i, part) in parts.enumerated() where try !isOpenable(part) {
            throw error(.noAccess, part: i + 1, fileName: part.lastPathComponent, naming: naming, folder: folder)
        }
        return parts
    }

    // MARK: - File system

    private enum PartState: Equatable { case present, absent, noAccess }

    /// `stat` the part. A name that is not a regular file (a folder, a FIFO, a device) counts as absent:
    /// it is no volume, and opening a FIFO could block.
    private static func state(of url: URL) -> PartState {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            return errno == EPERM || errno == EACCES ? .noAccess : .absent
        }
        return info.st_mode & S_IFMT == S_IFREG ? .present : .absent
    }

    /// Opens the part read-only and closes it at once. false on EPERM/EACCES; another failure (the part
    /// vanished, too many open files) throws `ArchiveError.io`.
    private static func isOpenable(_ url: URL) throws -> Bool {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return true
        }
        let code = errno
        if code == EPERM || code == EACCES { return false }
        throw ArchiveError.io("Could not open \(url.lastPathComponent): \(String(cString: strerror(code)))")
    }

    private static func sizeSum(_ parts: [URL]) throws -> Int64 {
        var sum: Int64 = 0
        for part in parts {
            var info = stat()
            guard stat(part.path, &info) == 0 else {
                throw ArchiveError.io("Could not read \(part.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            let (s, overflow) = sum.addingReportingOverflow(Int64(info.st_size))
            sum = overflow ? .max : s
        }
        return sum
    }

    /// A numbered split of a zip: the base name ends in `.zip`, or part 1 starts with a zip signature
    /// (local file header `PK\3\4`, or the split/spanning marker `PK\7\8` / `PK00`).
    private static func isZip(firstPart: URL, base: String) throws -> Bool {
        if base.lowercased().hasSuffix(".zip") { return true }
        let head: Data
        do {
            let handle = try FileHandle(forReadingFrom: firstPart)
            defer { try? handle.close() }
            head = try handle.read(upToCount: 4) ?? Data()
        } catch {
            throw ArchiveError.io("Could not read \(firstPart.lastPathComponent): \(error.localizedDescription)")
        }
        let signatures: [[UInt8]] = [[0x50, 0x4B, 0x03, 0x04], [0x50, 0x4B, 0x07, 0x08], [0x50, 0x4B, 0x30, 0x30]]
        return signatures.contains([UInt8](head))
    }

    // MARK: - Errors

    /// `fileName` defaults to part `part`'s name. `setName` is part 1's name (spanned zip: the `.zip`).
    private static func error(_ reason: ArchiveVolumeError.Reason, part: Int?, fileName: String? = nil,
                              naming: VolumeNaming, folder: URL) -> ArchiveVolumeError {
        let setName = (naming.lastPartURL() ?? naming.url(ofPart: 1)).lastPathComponent
        let name = fileName ?? part.map { naming.url(ofPart: $0).lastPathComponent } ?? setName
        return ArchiveVolumeError(reason: reason, part: part, fileName: name, setName: setName,
                                  folder: folder, openedPart: naming.openedPart)
    }
}
