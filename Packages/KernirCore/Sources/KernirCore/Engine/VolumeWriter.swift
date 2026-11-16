import Foundation

/// The split writer behind `ArchiveWriter.writeVolumes`. The archive is written by the same entry-writing
/// path as a single-file save (`LibArchiveWriter.writeEntries`), through a libarchive write callback
/// (`WriteSession(output:)`) that cuts the byte stream into `<baseName>.<ext>.001`, `.002` … as it goes, so the
/// archive is never held in memory or on disk twice. A set of one volume is renamed to `<baseName>.<ext>`.
enum VolumeWriter {
    /// Writes into `directory`, which `VolumeFolderChecks` found empty. On any failure or cancellation every volume
    /// written is deleted; `directory` itself is never created, moved or removed.
    /// The thrown error is the sink's own when it stopped the write (a cancel seen while the archive was emitted,
    /// a file error), otherwise libarchive's or the entry loop's. A sink abandoned after another error records no
    /// failure of its own, so that error stays the one thrown. A sink stopped by the volume limit throws the
    /// public `ArchiveVolumeLimitError` instead of its internal `.io`, after the same cleanup.
    static func write(source: (any ArchiveReading)?, changes: ArchiveChangeSet, format: ArchiveFormat,
                      into directory: URL, baseName: String, options: ResolvedWriteOptions, volumeSize: Int64?,
                      progress: ArchiveProgressHandler?,
                      maximumVolumeCount: Int = ArchiveWriteOptions.maximumVolumeCount) throws -> [URL] {
        // A split set carries no archive comment: `.keep` drops the source's, anything else is refused.
        guard changes.comment == .keep else { throw ArchiveError.io("A split archive cannot have a comment") }
        // On scalars: "/" followed by a combining mark or ZWJ, or after a Prepend scalar, is one Character that is
        // not "/", and a Character `contains("/")` let `a/\u{301}b` through.
        guard !baseName.isEmpty, !baseName.unicodeScalars.contains(where: { $0 == "/" || $0.value == 0 }) else {
            throw ArchiveError.io("\"\(baseName)\" is not a file name")
        }
        var reader: LibArchiveReader?
        if let source {
            guard let r = source as? LibArchiveReader else { throw ArchiveError.notImplemented }
            reader = r
        }

        let entries = try LibArchiveWriter.planEntries(source: reader, changes: changes, format: format,
                                                       excludingMacMetadata: options.excludesMacMetadata)

        let sink = VolumeSink(directory: directory, baseName: baseName, fileExtension: format.fileExtension,
                              plan: VolumePlan(volumeSize: volumeSize, maximumCount: maximumVolumeCount))
        do {
            // The session (and libarchive's handle, whose close may still write) is gone when this returns. An
            // unfinished session abandons the sink before that close, so the close writes nothing.
            let tracker = try LibArchiveWriter.writeEntries(
                entries, keepsArchiveComment: false, progress: progress
            ) { () throws(ArchiveError) in try WriteSession(output: sink, format: format, options: options) }
            let urls = try sink.finish()
            tracker.finish()
            return urls
        } catch {
            sink.abandon()
            if sink.exceededVolumeLimit { throw ArchiveVolumeLimitError(maximum: sink.plan.maximumCount) }
            throw sink.failure ?? error
        }
    }
}

/// Pure arithmetic of a byte split, in `Int64` throughout (a FAT32 volume is 4 294 967 295 bytes and a set can
/// reach 999 of them, about 4.29 TB).
struct VolumePlan: Equatable {
    /// One run of bytes that lands in one volume.
    struct Piece: Equatable {
        /// 1-based volume number.
        let volume: Int
        /// Where the run starts inside that volume.
        let offset: Int64
        /// The run's bytes within the buffer being written.
        let range: Range<Int>
    }

    /// Bytes per volume; `Int64.max` for no split.
    let volumeSize: Int64
    let maximumCount: Int

    init(volumeSize: Int64?, maximumCount: Int = ArchiveWriteOptions.maximumVolumeCount) {
        self.volumeSize = volumeSize.map { max($0, 1) } ?? .max
        self.maximumCount = maximumCount
    }

    /// The volumes `count` bytes starting at archive offset `position` go to, in order. Throws `.io` when a byte
    /// would need a volume past `maximumCount`.
    func pieces(at position: Int64, count: Int) throws(ArchiveError) -> [Piece] {
        var pieces: [Piece] = []
        var done = 0
        while done < count {
            let at = position + Int64(done)
            let index = at / volumeSize
            guard index < Int64(maximumCount) else {
                throw .io("The archive needs more than \(maximumCount) volumes")
            }
            let offset = at % volumeSize
            let length = Int(min(Int64(count - done), volumeSize - offset))
            pieces.append(Piece(volume: Int(index) + 1, offset: offset, range: done..<(done + length)))
            done += length
        }
        return pieces
    }

    /// Volumes a `total`-byte archive fills (at least one).
    func volumeCount(forTotal total: Int64) -> Int {
        Int(max(1, (total - 1) / volumeSize + 1))
    }

    /// `Photos.7z.001`: three digits, as 7-Zip names them.
    static func name(baseName: String, fileExtension: String, volume: Int) -> String {
        "\(baseName).\(fileExtension).\(String(format: "%03d", volume))"
    }
}

/// The byte sink behind the libarchive write callback: creates each volume when its first byte arrives (never
/// over an existing file), writes through to it, and keeps every file it made so `abandon` can delete them.
/// Synchronous, on the saving task, so a cancel of that task is seen on every write. Not thread-safe.
final class VolumeSink {
    let directory: URL
    let baseName: String
    let fileExtension: String
    let plan: VolumePlan
    /// Why the sink stopped accepting bytes; nil while it accepts them.
    private(set) var failure: ArchiveError?
    /// The sink stopped because the plan refused a byte past `plan.maximumCount` volumes (`failure` then holds
    /// the plan's `.io`). `VolumeWriter` turns this into `ArchiveVolumeLimitError`.
    private(set) var exceededVolumeLimit = false
    private var isAbandoned = false

    private var position: Int64 = 0
    private var fd: Int32 = -1
    private var current = 0
    private(set) var urls: [URL] = []

    init(directory: URL, baseName: String, fileExtension: String, plan: VolumePlan) {
        self.directory = directory
        self.baseName = baseName
        self.fileExtension = fileExtension
        self.plan = plan
    }

    deinit { closeCurrent() }

    /// Writes all of `buffer`; false (with `failure` set) when it cannot, and for every write after that.
    func write(_ buffer: UnsafeRawBufferPointer) -> Bool {
        guard failure == nil, !isAbandoned else { return false }
        if Task.isCancelled { return stop(.cancelled) }
        do throws(ArchiveError) {
            let pieces: [VolumePlan.Piece]
            do { pieces = try plan.pieces(at: position, count: buffer.count) } catch {
                exceededVolumeLimit = true
                throw error
            }
            for piece in pieces {
                if piece.volume != current { try open(piece.volume) }
                var done = piece.range.lowerBound
                while done < piece.range.upperBound {
                    let n = Darwin.write(fd, buffer.baseAddress! + done, piece.range.upperBound - done)
                    if n < 0 {
                        let e = errno
                        if e == EINTR { continue }
                        throw .io("Could not write \(urls.last?.lastPathComponent ?? baseName): "
                                              + String(cString: strerror(e)))
                    }
                    done += n
                }
            }
        } catch {
            return stop(error)
        }
        position += Int64(buffer.count)
        return true
    }

    /// Closes the last volume and returns the set: a lone `.001` becomes `<baseName>.<ext>`. When that name is
    /// taken, it throws `.io` and keeps the `.001` (and nothing else) for `abandon` to delete.
    func finish() throws(ArchiveError) -> [URL] {
        if let failure { throw failure }
        let fd = self.fd
        self.fd = -1
        if fd >= 0, close(fd) != 0 {
            let e = errno
            throw fail(.io("Could not write \(urls.last?.lastPathComponent ?? baseName): " + String(cString: strerror(e))))
        }
        guard urls.count == 1 else { return urls }
        let single = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        // Never replaces a file: the name is reserved with O_EXCL, and rename(2) then replaces only that empty
        // placeholder. No hard link, which FAT32, exFAT and most SMB shares lack.
        let placeholder = Darwin.open(single.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard placeholder >= 0 else {
            let e = errno
            throw fail(.io("Could not name \(single.lastPathComponent): " + String(cString: strerror(e))))
        }
        close(placeholder)
        guard rename(urls[0].path, single.path) == 0 else {
            let e = errno
            unlink(single.path)
            throw fail(.io("Could not name \(single.lastPathComponent): " + String(cString: strerror(e))))
        }
        urls = [single]
        return urls
    }

    /// Stops the sink and deletes every volume it created. Records no failure: the caller's error stays the one
    /// thrown. Later calls do nothing.
    func abandon() {
        isAbandoned = true
        closeCurrent()
        for url in urls { unlink(url.path) }
        urls = []
    }

    // MARK: - Private

    private func open(_ volume: Int) throws(ArchiveError) {
        closeCurrent()
        let url = directory.appendingPathComponent(
            VolumePlan.name(baseName: baseName, fileExtension: fileExtension, volume: volume))
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let e = errno
            throw .io("Could not create \(url.lastPathComponent): " + String(cString: strerror(e)))
        }
        self.fd = fd
        current = volume
        urls.append(url)
    }

    private func closeCurrent() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    @discardableResult
    private func fail(_ error: ArchiveError) -> ArchiveError {
        if failure == nil { failure = error }
        return error
    }

    private func stop(_ error: ArchiveError) -> Bool {
        fail(error)
        return false
    }
}
