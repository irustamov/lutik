import Foundation

/// Pure helpers for archive entry paths. `normalize` is the path-traversal safety boundary.
///
/// All logic works on unicode scalars, never Characters: a "/" followed by a combining mark forms a
/// single grapheme that is not "/", which would otherwise hide separators and ".." components.
enum EntryPath {
    private static let slash: Unicode.Scalar = "/"
    /// Most combining marks in a row a name may hold: the UAX #15 Stream-Safe limit. No real name comes close.
    static let maxCombiningRun = 30

    /// True when `s` has more than `maxCombiningRun` combining marks in a row: scalars of General_Category M (Mn, Mc,
    /// Me) or with a nonzero canonical combining class. Linear, and it stops at the first such run. NFC and String ==
    /// reorder a run of marks in time quadratic in its length, so the listing refuses such a name
    /// (`ArchiveNestingError.Limit.combiningMarks`) and `nfc` leaves it alone.
    static func exceedsCombiningRun(_ s: String) -> Bool {
        if s.utf8.allSatisfy({ $0 < 0x80 }) { return false }
        var run = 0
        for u in s.unicodeScalars {
            if isCombining(u) {
                run += 1
                if run > maxCombiningRun { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private static func isCombining(_ u: Unicode.Scalar) -> Bool {
        // No scalar below U+0300 is a mark or has a nonzero combining class.
        guard u.value >= 0x300 else { return false }
        let p = u.properties
        switch p.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return p.canonicalCombiningClass != .notReordered
        }
    }

    /// `s` in NFC, unless it has a run of marks past `maxCombiningRun` (`exceedsCombiningRun`): then `s` unchanged,
    /// since composing it costs time quadratic in the run and the listing refuses it anyway. Every NFC of a name goes
    /// through here (`EntryNameDecoder`, `NameEncodingDetector.decode`, `normalizeScalars`).
    static func nfc(_ s: String) -> String {
        exceedsCombiningRun(s) ? s : s.precomposedStringWithCanonicalMapping
    }
    private static let dot: Unicode.Scalar = "."

    private static func components(_ s: String) -> [[Unicode.Scalar]] {
        withoutNUL(s).unicodeScalars
            .split(separator: slash, omittingEmptySubsequences: true)
            .map(Array.init)
    }

    private static func withoutNUL(_ s: String) -> String {
        s.unicodeScalars.contains { $0.value == 0 }
            ? String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value != 0 })) : s
    }

    private static func join(_ parts: some Sequence<[Unicode.Scalar]>) -> String {
        var out = String.UnicodeScalarView()
        var first = true
        for p in parts {
            if !first { out.append(slash) }
            first = false
            out.append(contentsOf: p)
        }
        return String(out)
    }

    /// Normalizes to NFC (`nfc`: a name with a run of marks past `maxCombiningRun` is not composed), "/"-separated
    /// components with no leading or trailing "/".
    /// Drops empty, "." and ".." components (exact scalar matches only) and removes NUL scalars.
    /// Backslash is kept literally. Returns nil when nothing remains.
    ///
    /// This is the one "name -> entry path" step for header names (after `EntryNameDecoder`), link
    /// targets and caller selections alike, so an NFD spelling selects the NFC-listed entry. NUL scalars
    /// go first, so "e\0\u{301}" composes to "\u{E9}". NFC runs before the split: no canonical
    /// composition produces or absorbs "/" or ".".
    static func normalize(_ raw: String) -> String? {
        if isCleanASCII(raw) { return raw }
        return normalizeScalars(raw)
    }

    /// True when `s` is pure ASCII with no NUL, no empty, "." or ".." component and no leading or
    /// trailing "/": exactly the inputs `normalizeScalars` returns unchanged.
    private static func isCleanASCII(_ s: String) -> Bool {
        var s = s
        return s.withUTF8 { b in
            guard let first = b.first, first != 0x2F, b[b.count - 1] != 0x2F else { return false }
            var start = 0
            var i = 0
            while i <= b.count {
                if i == b.count || b[i] == 0x2F {
                    let len = i - start
                    if len == 0 { return false }
                    if b[start] == 0x2E, len == 1 || (len == 2 && b[start + 1] == 0x2E) { return false }
                    start = i + 1
                } else if b[i] == 0 || b[i] >= 0x80 {
                    return false
                }
                i += 1
            }
            return true
        }
    }

    /// General (scalar-based) normalization; the oracle for the ASCII fast path in `normalize`.
    static func normalizeScalars(_ raw: String) -> String? {
        let clean = withoutNUL(raw)
        let composed = clean.utf8.allSatisfy { $0 < 0x80 } ? clean : nfc(clean)
        let parts = components(composed).filter { $0 != [dot] && $0 != [dot, dot] }
        return parts.isEmpty ? nil : join(parts)
    }

    /// Whether `name` is one path component exactly as given: not empty, `.` or `..`, with no `/` or NUL.
    /// Checked on scalars (NFC never makes or absorbs `/` or `.`), so a combining mark cannot hide a `/`.
    static func isValidComponent(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return !scalars.isEmpty && !scalars.contains { $0 == slash || $0.value == 0 }
            && !scalars.elementsEqual([dot]) && !scalars.elementsEqual([dot, dot])
    }

    /// `path` before its last "/" scalar; nil when it has none. Nothing else is changed (no normalization).
    /// Never on Characters: "/" followed by a combining mark or ZWJ, or preceded by a Prepend scalar, is part of
    /// one Character that is not "/", so `lastIndex(of: "/")` on the String misses it (`d/\u{301}x` has no parent).
    static func parent(of path: String) -> String? {
        let scalars = path.unicodeScalars
        return scalars.lastIndex(of: slash).map { String(scalars[..<$0]) }
    }

    /// `path` split on the "/" scalar, empty components omitted as `String.split` does; nothing else is changed
    /// (no normalization, NUL kept). Never on Characters, see `parent(of:)`.
    static func split(_ path: String) -> [String] {
        path.unicodeScalars.split(separator: slash).map { String($0) }
    }

    /// `split(path).last ?? path` without splitting the rest: the last non-empty component, or `path` itself when it
    /// has none. Scans back from the end, so a name costs its own length, not the whole path's (deep paths).
    static func lastComponent(of path: String) -> String {
        let scalars = path.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex, scalars[scalars.index(before: end)] == slash { end = scalars.index(before: end) }
        guard end > scalars.startIndex else { return path }
        var start = end
        while start > scalars.startIndex, scalars[scalars.index(before: start)] != slash {
            start = scalars.index(before: start)
        }
        return String(scalars[start..<end])
    }

    /// True when `path` equals a selected path or lies beneath one. Both `path` and the selection
    /// entries must already be normalized. Compares scalars with a "/" boundary.
    static func isSelected(_ path: String, by selection: Set<String>) -> Bool {
        let p = Array(path.unicodeScalars)
        for sel in selection {
            let s = Array(sel.unicodeScalars)
            if p == s { return true }
            if p.count > s.count, p.starts(with: s), p[s.count] == slash { return true }
        }
        return false
    }

    /// Ancestor directory paths, outermost first: "a/b/c" gives ["a", "a/b"].
    static func ancestors(of path: String) -> [String] {
        var hasSlash = false
        var simple = true
        var prev: UInt8 = 0x2F  // a leading "/" counts as an empty component
        for b in path.utf8 {
            if b == 0 || (b == 0x2F && prev == 0x2F) { simple = false; break }
            if b == 0x2F { hasSlash = true }
            prev = b
        }
        if prev == 0x2F { simple = false }  // trailing "/" or empty path
        guard simple else { return ancestorsScalars(of: path) }
        guard hasSlash else { return [] }
        var out: [String] = []
        let u = path.utf8
        var i = u.startIndex
        while i != u.endIndex {
            if u[i] == 0x2F { out.append(String(path[..<i])) }
            i = u.index(after: i)
        }
        return out
    }

    /// General (scalar-based) ancestors; the oracle for the fast path in `ancestors(of:)`.
    static func ancestorsScalars(of path: String) -> [String] {
        let parts = components(path)
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { join(parts[0..<$0]) }
    }
}
