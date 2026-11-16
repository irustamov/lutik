import Testing
import Foundation
import KernirCore

// Which archive dates are instants and which are wall-clock readings. 7z FILETIMEs and the zip "UT" extended
// timestamp are UTC: the same instant in every time zone. A zip DOS time without a UT field has no zone; it
// reads as local wall-clock time, so the instant moves with the zone (Archive Utility and 7-Zip do the same).
// Files stamped 09:30 under TZ=UTC therefore show 5:30 AM from a 7z but 9:30 AM from a `zip -X` zip on an EDT
// Mac (SS gallery, 2026-11-10): the fixtures differ, not the reader.
//
// The expectations follow the process time zone instead of setting TZ in-process (TZ is global, and the parallel
// zip tests and the per-thread DOS-time memo in archive_time.c would see the switch). Run the suite under two
// zones to cover both sides, e.g. `TZ=UTC swift test` and `TZ=America/New_York swift test`; under UTC the
// local-time case can't tell the two readings apart.

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
private let local: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    return c
}()
private let stamp = DateComponents(year: 2026, month: 3, day: 16, hour: 9, minute: 30)
private let stampDOS = SyntheticZip.dosTime(year: 2026, month: 3, day: 16, hour: 9, minute: 30, second: 0)

@Test func sevenZipDatesAreUTC() async throws {
    // Made by 7-Zip (Fixtures/manifest.json pins mtime 1767323045 = 2026-01-02 03:04:05 UTC).
    let url = Corpus.root.appending(path: "7z/copy.7z")
    let files = try await Archive.open(at: url).entries.filter { !$0.isDirectory }
    try #require(!files.isEmpty)
    for entry in files {
        #expect(entry.modificationDate == Date(timeIntervalSince1970: 1_767_323_045), "\(entry.path)")
    }
}

@Test func zipUTFieldIsUTCAndWinsOverDOSTime() async throws {
    let instant = try #require(utc.date(from: stamp))
    // The DOS field says 01:00 local; the UT field must win in every zone.
    let dos = SyntheticZip.dosTime(year: 2026, month: 3, day: 16, hour: 1, minute: 0, second: 0)
    let url = SyntheticZip.write(SyntheticZip.stored([(path: "Notes.txt", dosTime: dos, data: [1])],
                                                     unixTime: UInt32(instant.timeIntervalSince1970)))
    let entry = try #require(try await Archive.open(at: url).entries.first)
    #expect(entry.modificationDate == instant, "TZ \(TimeZone.current.identifier)")
}

@Test func zipDOSTimeWithoutUTFieldIsLocalWallClock() async throws {
    let url = SyntheticZip.write(SyntheticZip.stored([(path: "Notes.txt", dosTime: stampDOS, data: [1])]))
    let date = try #require(try await Archive.open(at: url).entries.first?.modificationDate)
    #expect(date == local.date(from: stamp), "TZ \(TimeZone.current.identifier)")
    // Same wall clock, so the instant sits the zone's UTC offset away from 09:30 UTC (4 h in EDT).
    let instantUTC = try #require(utc.date(from: stamp))
    #expect(instantUTC.timeIntervalSince(date) == Double(TimeZone.current.secondsFromGMT(for: date)))
}
