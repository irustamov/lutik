/// Sums sizes that come from archive headers. A crafted header can declare any size up to Int64.max (libarchive
/// accepts that), so two of them make a plain `+` trap. A sum past Int64 is nil: unknown, as a folder's total in
/// `Archive.tree` (only crafted sizes get there).
enum SizeSum {
    static func of<S: Sequence>(_ sizes: S) -> Int64? where S.Element == Int64 {
        var total: Int64 = 0
        for size in sizes {
            let (sum, overflow) = total.addingReportingOverflow(size)
            if overflow { return nil }
            total = sum
        }
        return total
    }
}
