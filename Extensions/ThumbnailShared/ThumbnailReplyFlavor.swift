import QuickLookThumbnailing

/// Finder draws a thumbnail inside a white "document page" decoration unless the reply asks for
/// the plain icon flavor. Our pictures are transparent on purpose (transparent icons,
/// no page behind them), so the macOS provider sets `iconFlavor` to 0, the
/// old `kQLThumbnailIconPlainFlavor`, on every reply.
///
/// `iconFlavor` is a private property of `QLThumbnailReply`: it has no public header, but the
/// setter exists on macOS 26 (default 2147483647, "unset"). The property is a signed int (ObjC
/// type `i`, verified on macOS 26.2); the guard below covers removal, not a type change.
/// SameBoy's thumbnail provider does the same (`reply.iconFlavor = 0`, GBThumbnailProvider.m).
/// It is applied through key-value coding and only when the class answers to the setter, so a
/// system without it is a no-op (the decoration stays; nothing crashes). On iOS, Files draws its own
/// tile behind every thumbnail whatever the flavor, so it is not applied there (iPadOS 27.2, 2026-11-15).
enum ThumbnailReplyFlavor {
    /// The raw value of the plain flavor (`kQLThumbnailIconPlainFlavor`).
    static let plain = 0

    /// Returns `reply` so a call site can wrap it inline: `handler(ThumbnailReplyFlavor.applyPlain(to: reply), nil)`.
    @discardableResult
    static func applyPlain(to reply: QLThumbnailReply) -> QLThumbnailReply {
        #if os(macOS)
        if reply.responds(to: NSSelectorFromString("setIconFlavor:")) {
            reply.setValue(plain, forKey: "iconFlavor")
        }
        #endif
        return reply
    }
}
