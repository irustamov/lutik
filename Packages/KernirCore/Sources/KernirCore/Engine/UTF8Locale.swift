import Foundation

/// libarchive converts entry names between a format's charset and the "current locale" one. Patch 0023 makes that
/// one UTF-8 on Apple platforms whatever the thread's locale, and its multibyte <-> wide conversions UTF-8 too.
/// Calls that can convert names also run with a UTF-8 LC_CTYPE installed on the current thread only (no
/// process-global state), for any other C library call that reads the locale.
///
/// Not every OS has a UTF-8 locale: on iOS 17 `newlocale` fails for every UTF-8 name (EFTYPE), only "C" opens.
/// Then `shared` is nil and `withUTF8CType` runs its body in the thread's own locale; nothing traps, and names
/// still convert as UTF-8 through patch 0023.
enum UTF8Locale {
    /// Tried in order, LC_CTYPE only. "UTF-8" is the bare ctype name Darwin has long shipped; "C.UTF-8" the
    /// newer spelling; "en_US.UTF-8" covers a libc that only knows full names.
    static let candidateNames = ["UTF-8", "C.UTF-8", "en_US.UTF-8"]

    /// The first of `names` that `open` opens with a UTF-8 codeset, with its name; nil when none does. A locale
    /// that opens with another codeset (e.g. "C") is freed and skipped.
    static func firstAvailable(
        _ names: [String],
        open: (String) -> locale_t? = { newlocale(LC_CTYPE_MASK, $0, nil) }
    ) -> (name: String, locale: locale_t)? {
        for name in names {
            guard let locale = open(name) else { continue }
            if isUTF8(locale) { return (name, locale) }
            freelocale(locale)
        }
        return nil
    }

    static func isUTF8(_ locale: locale_t) -> Bool {
        // nl_langinfo_l is not imported into Swift; read the codeset with `locale` installed on this thread.
        let old = uselocale(locale)
        defer { uselocale(old) }
        guard let codeset = nl_langinfo(CODESET) else { return false }
        return String(cString: codeset) == "UTF-8"
    }

    /// Made once per process and never freed; nil when the OS has no UTF-8 locale. Debug builds started with
    /// KERNIR_NO_UTF8_LOCALE=1 act as such an OS throughout, so a whole test run can take the iOS 17 path.
    nonisolated(unsafe) static let shared: locale_t? = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KERNIR_NO_UTF8_LOCALE"] == "1" { return nil }
        #endif
        return firstAvailable(candidateNames)?.locale
    }()

    /// Whether `withUTF8CType` switches the thread to UTF-8 here.
    static var isAvailable: Bool { current != nil }

    #if DEBUG
    /// Tests only: within `$forceUnavailable.withValue(true)`, `withUTF8CType` behaves as on an OS without a
    /// UTF-8 locale (the iOS 17 path), on the calling task and its child tasks.
    @TaskLocal static var forceUnavailable = false
    #endif

    static var current: locale_t? {
        #if DEBUG
        if forceUnavailable { return nil }
        #endif
        return shared
    }
}

/// Runs `body` synchronously with a UTF-8 LC_CTYPE on this thread. Never wrap async code.
/// Without a UTF-8 locale (`UTF8Locale.isAvailable` false) `body` runs in the thread's current locale.
func withUTF8CType<T>(_ body: () throws -> T) rethrows -> T {
    guard let locale = UTF8Locale.current else { return try body() }
    let old = uselocale(locale)
    defer { uselocale(old) }
    return try body()
}
