import Foundation

/// Reads a zip's encryption and compression method straight from its central directory, and
/// whether any encrypted entry uses PKWARE strong encryption (general-purpose bit 6), which
/// libarchive cannot decrypt.
///
/// libarchive does not expose the AES strength or the per-entry method, so this parses just
/// enough of the zip structure. All input is untrusted: every offset and length is checked
/// against the file size before it is used, reads are bounded, and the central-directory walk
/// advances at least one fixed header per iteration, so it always terminates.
///
/// When the central directory cannot be read, `detect` falls back to scanning local file headers
/// (`PK\3\4`) from offset 0 for strong encryption, stopping at the first header with flag bit 3
/// (sizes unknown) or a bad signature. Each step moves past a 30-byte header, so it terminates too.
enum ZipEncryptionProbe {
    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64EocdSignature: UInt32 = 0x0606_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let eocdSize: UInt64 = 22
    private static let locatorSize: UInt64 = 20
    private static let zip64EocdMinSize: UInt64 = 56
    private static let centralHeaderSize: UInt64 = 46
    private static let maxCommentLength: UInt64 = 0xFFFF

    static func detect(at url: URL) throws(ArchiveError) -> (encryption: ArchiveEncryption, method: ArchiveCompressionMethod?, strongEncryption: Bool) {
        try detect(parts: [url])
    }

    /// `detect(at:)` on `parts` read as one file, in order. Only for a byte split (`x.zip.001` ..., one disk-0 zip
    /// cut anywhere), whose recorded offsets are positions in the joined bytes; a spanned set's offsets are per
    /// disk, so it is probed at its `.zip` alone.
    static func detect(parts: [URL]) throws(ArchiveError) -> (encryption: ArchiveEncryption, method: ArchiveCompressionMethod?, strongEncryption: Bool) {
        do {
            let source = FileSource(file: try JoinedFile(parts))
            do {
                return try probe(source)
            } catch ArchiveError.corrupted {
                // The central directory is unusable (cut off, damaged). The local headers can still
                // show PKWARE strong encryption, which no password decrypts.
                if (try? localHeadersShowStrongEncryption(source)) == true { return (.none, nil, true) }
                throw ArchiveError.corrupted("zip central directory unreadable")
            }
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw .io("Could not read \(parts[parts.count - 1].lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Bounds-checked file access

    private struct FileSource {
        let file: JoinedFile
        var size: UInt64 { file.size }

        /// Reads exactly `count` bytes at `offset`; throws `.corrupted` when the range leaves the file.
        func read(at offset: UInt64, count: UInt64) throws -> [UInt8] {
            guard offset <= size, count <= size - offset else { throw ArchiveError.corrupted("zip structure out of range") }
            guard let bytes = try file.read(at: offset, count: count) else { throw ArchiveError.corrupted("zip truncated") }
            return bytes
        }
    }

    /// Sequential access to the central directory through a small sliding window.
    private struct DirectoryWindow {
        let source: FileSource
        let end: UInt64
        private var windowStart: UInt64 = 0
        private var window: [UInt8] = []
        private static let chunk: UInt64 = 64 * 1024

        init(source: FileSource, end: UInt64) {
            self.source = source
            self.end = end
        }

        mutating func read(at offset: UInt64, count: UInt64) throws -> [UInt8] {
            guard offset <= end, count <= end - offset else { throw ArchiveError.corrupted("central directory entry out of range") }
            let windowEnd = windowStart + UInt64(window.count)
            if offset < windowStart || offset + count > windowEnd {
                windowStart = offset
                window = try source.read(at: offset, count: min(max(count, Self.chunk), end - offset))
            }
            let from = Int(offset - windowStart)
            return Array(window[from..<from + Int(count)])
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i)) | UInt32(u16(b, i + 2)) << 16 }
    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }

    // MARK: - Probe

    private static func probe(_ source: FileSource) throws -> (encryption: ArchiveEncryption, method: ArchiveCompressionMethod?, strongEncryption: Bool) {
        let directory = try locateCentralDirectory(source)
        let cdOffset = try centralDirectoryStart(source, directory)
        let cdEnd = cdOffset + directory.size

        var window = DirectoryWindow(source: source, end: cdEnd)
        var position = cdOffset
        // The strongest scheme seen (aes256 > aes128 > zipCrypto), so a plain save never downgrades
        // an archive that mixes schemes.
        var encryption: ArchiveEncryption?
        var strongEncryption = false
        // Method facts: deflate or store seen on a non-empty file, and the first non-directory entry's
        // method (used only when the archive holds no non-empty file).
        var sawDeflate = false
        var sawStore = false
        var sawNonEmptyFile = false
        var firstFileMethod: ArchiveCompressionMethod?
        var sawFile = false

        // Each iteration consumes at least the 46-byte fixed header, so the loop terminates. Every
        // entry is read: a later one may carry a stronger scheme or strong encryption.
        while position + centralHeaderSize <= cdEnd {
            let header = try window.read(at: position, count: centralHeaderSize)
            guard u32(header, 0) == centralSignature else { throw ArchiveError.corrupted("bad zip central directory entry") }
            let flags = u16(header, 8)
            let rawMethod = u16(header, 10)
            let uncompressedSize = u32(header, 24)
            let nameLength = UInt64(u16(header, 28))
            let extraLength = UInt64(u16(header, 30))
            let commentLength = UInt64(u16(header, 32))
            let nameOffset = position + centralHeaderSize
            let extraOffset = nameOffset + nameLength
            let next = extraOffset + extraLength + commentLength
            guard next <= cdEnd else { throw ArchiveError.corrupted("zip central directory entry overruns directory") }

            let isEncrypted = flags & 1 != 0
            var isDirectory = false
            if nameLength > 0 {
                isDirectory = try window.read(at: nameOffset + nameLength - 1, count: 1)[0] == UInt8(ascii: "/")
            }
            // 0xFFFFFFFF defers the size to the ZIP64 extra field; such an entry is never empty.
            let isNonEmptyFile = !isDirectory && uncompressedSize != 0
            let decidesMethod = isNonEmptyFile || (!isDirectory && !sawFile)
            var aes: (strength: UInt8, method: UInt16)?
            if rawMethod == 99, isEncrypted || decidesMethod {
                aes = aesInfo(try window.read(at: extraOffset, count: extraLength))
            }

            if decidesMethod {
                let method: ArchiveCompressionMethod? = switch rawMethod == 99 ? aes?.method : rawMethod {
                case 0: .store
                case 8: .deflate
                default: nil
                }
                if !sawFile {
                    sawFile = true
                    firstFileMethod = method
                }
                if isNonEmptyFile {
                    sawNonEmptyFile = true
                    if method == .deflate { sawDeflate = true }
                    if method == .store { sawStore = true }
                }
            }
            if isEncrypted {
                let scheme: ArchiveEncryption
                if rawMethod == 99 {
                    switch aes?.strength {
                    case 1: scheme = .aes128
                    case 2, 3: scheme = .aes256
                    default: throw ArchiveError.corrupted("zip AES entry without valid AES extra field")
                    }
                } else {
                    scheme = .zipCrypto
                }
                if strength(scheme) > strength(encryption) { encryption = scheme }
                if flags & 0x0040 != 0 { strongEncryption = true }
            }
            position = next
        }

        let method: ArchiveCompressionMethod?
        if sawDeflate {
            method = .deflate
        } else if sawStore {
            method = .store
        } else if sawNonEmptyFile {
            method = nil
        } else {
            method = firstFileMethod
        }
        return (encryption ?? .none, method, strongEncryption)
    }

    /// Walks local file headers from offset 0 (the central directory is unusable) and reports an entry
    /// with flag bits 0 (encrypted) and 6 (strong encryption). Stops at the first header with bit 3 (sizes
    /// unknown) or a bad signature. Each step advances past a 30-byte header, so it terminates.
    private static func localHeadersShowStrongEncryption(_ source: FileSource) throws -> Bool {
        let localSignature: UInt32 = 0x0403_4b50
        let localHeaderSize: UInt64 = 30
        var position: UInt64 = 0
        while position + localHeaderSize <= source.size {
            let header = try source.read(at: position, count: localHeaderSize)
            guard u32(header, 0) == localSignature else { return false }
            let flags = u16(header, 6)
            if flags & 0x0001 != 0, flags & 0x0040 != 0 { return true }
            if flags & 0x0008 != 0 { return false }
            let next = position + localHeaderSize + UInt64(u32(header, 18)) + UInt64(u16(header, 26)) + UInt64(u16(header, 28))
            guard next > position else { return false }
            position = next
        }
        return false
    }

    private static func strength(_ e: ArchiveEncryption?) -> Int {
        switch e {
        case .aes256: 3
        case .aes128: 2
        case .zipCrypto: 1
        default: 0
        }
    }

    /// Where the central directory really starts. The EOCD offset is trusted when a central header
    /// sits there; otherwise (a self-extracting stub or other data prepended without fixing the
    /// offsets) the directory is taken to end right at the EOCD record, as Info-ZIP and libarchive do.
    /// Only central-directory offsets are used; local-header offsets are never followed.
    private static func centralDirectoryStart(_ source: FileSource, _ directory: CentralDirectory) throws -> UInt64 {
        let size = directory.size
        let recorded = directory.offset
        if recorded <= source.size, size <= source.size - recorded,
           try startsWithCentralHeader(source, at: recorded, size: size) {
            return recorded
        }
        if !directory.isZip64, size <= directory.eocdPosition {
            let adjusted = directory.eocdPosition - size
            if adjusted != recorded, try startsWithCentralHeader(source, at: adjusted, size: size) {
                return adjusted
            }
        }
        if recorded <= source.size, size <= source.size - recorded {
            throw ArchiveError.corrupted("bad zip central directory entry")
        }
        throw ArchiveError.corrupted("zip central directory out of range")
    }

    /// True when the in-range directory at `offset` is too small to hold an entry (the walk then reads
    /// nothing) or begins with a central-header signature.
    private static func startsWithCentralHeader(_ source: FileSource, at offset: UInt64, size: UInt64) throws -> Bool {
        guard size >= centralHeaderSize else { return true }
        return u32(try source.read(at: offset, count: 4), 0) == centralSignature
    }

    /// The 0x9901 extra field: vendor version (2), "AE" (2), strength (1), actual method (2).
    private static func aesInfo(_ extra: [UInt8]) -> (strength: UInt8, method: UInt16)? {
        var i = 0
        while i + 4 <= extra.count {
            let id = u16(extra, i)
            let length = Int(u16(extra, i + 2))
            let body = i + 4
            guard length <= extra.count - body else { return nil }
            if id == 0x9901 {
                guard length >= 7 else { return nil }
                return (extra[body + 4], u16(extra, body + 5))
            }
            i = body + length
        }
        return nil
    }

    // MARK: - End of central directory

    private struct CentralDirectory {
        let offset: UInt64
        let size: UInt64
        /// File position of the EOCD record; the directory normally ends right before it.
        let eocdPosition: UInt64
        let isZip64: Bool
    }

    private static func locateCentralDirectory(_ source: FileSource) throws -> CentralDirectory {
        guard source.size >= eocdSize else { throw ArchiveError.corrupted("not a zip file") }
        let tailLength = min(source.size, eocdSize + maxCommentLength)
        let tailStart = source.size - tailLength
        let tail = try source.read(at: tailStart, count: tailLength)

        // Scan backwards. A record whose comment ends exactly at EOF wins; failing that, the last record
        // whose comment ends before EOF (trailing data appended after the zip).
        var exact: Int?
        var loose: Int?
        var i = tail.count - Int(eocdSize)
        while i >= 0 {
            if u32(tail, i) == eocdSignature {
                let commentLength = Int(u16(tail, i + 20))
                let available = tail.count - i - Int(eocdSize)
                if commentLength == available {
                    exact = i
                    break
                }
                if commentLength < available, loose == nil {
                    loose = i
                }
            }
            i -= 1
        }
        guard let eocd = exact ?? loose else { throw ArchiveError.corrupted("zip end of central directory not found") }

        var thisDisk = UInt32(u16(tail, eocd + 4))
        var directoryDisk = UInt32(u16(tail, eocd + 6))
        var size = UInt64(u32(tail, eocd + 12))
        var offset = UInt64(u32(tail, eocd + 16))
        let eocdPosition = tailStart + UInt64(eocd)
        var isZip64 = false
        let needsZip64 = u16(tail, eocd + 8) == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF
        if needsZip64, eocdPosition >= locatorSize {
            let locator = try source.read(at: eocdPosition - locatorSize, count: locatorSize)
            if u32(locator, 0) == zip64LocatorSignature {
                let recordOffset = u64(locator, 8)
                let record = try source.read(at: recordOffset, count: zip64EocdMinSize)
                guard u32(record, 0) == zip64EocdSignature else { throw ArchiveError.corrupted("bad zip64 end of central directory") }
                thisDisk = u32(record, 16)
                directoryDisk = u32(record, 20)
                size = u64(record, 40)
                offset = u64(record, 48)
                isZip64 = true
            }
        }
        // The directory offset is relative to the disk the directory starts on. Read on its own (a set's
        // last part), this file can resolve it only when that disk is this one; reading it here anyway
        // would take another file's offsets as this file's.
        guard thisDisk == directoryDisk else { throw ArchiveError.corrupted("zip central directory starts on another disk") }
        return CentralDirectory(offset: offset, size: size, eocdPosition: eocdPosition, isZip64: isZip64)
    }
}
