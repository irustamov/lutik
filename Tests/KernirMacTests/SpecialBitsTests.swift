import Testing
import Foundation
@testable import Kernir
import KernirCore

// Drag-out and Extract Here never place a setuid, setgid or sticky bit an archive gives its items
// (each keeps `mode & 0o777`), as Archive Utility and bsdtar without -p do: the
// engine never writes them, and the cross-volume copy never brings them back (`ExclusiveCopy`).
// End-to-end regression tests. The archive is a pax tar `/usr/bin/bsdtar` makes from an mtree spec,
// so its modes (04755, a 0000 file, a 0600 folder) need no files with those modes on disk. A hosted
// (App Sandbox) run can't set S_ISUID/S_ISGID on disk at all (chmod succeeds, the bits stay clear;
// sticky survives): the copy test that needs them on its source is disabled there
// (`setIDBitsSettable`) and its sticky-only variant runs; an unhosted run (shared harness with this file) runs both.

private let testDeviceToken = "5e7d5e7d5e7d5e7d"
private let bsdtar = "/usr/bin/bsdtar"

/// Whether this process can set S_ISUID and S_ISGID on a file it owns in the temporary folder
/// (chmod, then lstat); computed once. False in the App Sandbox of a hosted run.
private let setIDBitsSettable: Bool = {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpecialBitsTests-probe-\(UUID().uuidString)")
    guard (try? Data("probe".utf8).write(to: url)) != nil else { return false }
    defer { try? FileManager.default.removeItem(at: url) }
    func survives(_ bit: mode_t) -> Bool {
        var status = stat()
        return chmod(url.path, bit | 0o755) == 0 && lstat(url.path, &status) == 0 && status.st_mode & bit != 0
    }
    return survives(mode_t(S_ISUID)) && survives(mode_t(S_ISGID))
}()

private let setIDBitsReason: Comment = "App Sandbox clears setuid/setgid; runs unhosted (shared harness with SpecialBitsTests.swift)"

/// renamex_np(2), with `rule` answering first when it returns non-nil.
private func fileSystem(_ rule: @escaping @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32? = { _, _, _ in nil })
    -> ExtractionFileSystem {
    ExtractionFileSystem(deviceToken: testDeviceToken) { from, to, flags in
        if let answer = rule(from, to, flags) { return answer }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }
}

/// A fresh empty folder in the temporary folder; the caller removes it with `removeTree`.
private func makeFolder(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpecialBitsTests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Removes `url` with everything in it, folders without u+rx and setuid files included.
private func removeTree(_ url: URL) {
    unlockFolders(url)
    try? FileManager.default.removeItem(at: url)
}

/// Gives every folder from `url` down 0700 (top first, so a 0600 one can then be listed).
private func unlockFolders(_ url: URL) {
    var status = stat()
    guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return }
    _ = chmod(url.path, 0o700)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
        unlockFolders(url.appendingPathComponent(name))
    }
}

/// The mode bits of the item at `url` (lstat).
private func mode(_ url: URL) -> mode_t {
    var status = stat()
    return lstat(url.path, &status) == 0 ? status.st_mode & 0o7777 : 0o177777
}

/// A file at `url` with `mode`, set by chmod (S_ISUID on the test's own file is allowed unhosted).
private func makeFile(_ url: URL, mode: mode_t) throws {
    try Data("outside".utf8).write(to: url)
    guard chmod(url.path, mode) == 0 else { throw POSIXError(.EPERM) }
}

/// A folder at `url` with 01755 (sticky survives a hosted run): the fixture's symlink points at it,
/// and it must keep its mode.
private func makeVictim(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    guard chmod(url.path, 0o1755) == 0, mode(url) == 0o1755 else { throw POSIXError(.EPERM) }
}

/// `path` as an mtree(5) value: every byte but [A-Za-z0-9/._-] as a backslash and three octal
/// digits, vis(3) style (\040 for a space), so a temporary folder with spaces in it still works.
private func mtreeEscaped(_ path: String) -> String {
    path.utf8.map { byte in
        let character = Character(Unicode.Scalar(byte))
        let plain = character.isASCII && (character.isLetter || character.isNumber) || "/._-".contains(character)
        return plain ? String(character) : "\\" + String(byte, radix: 8).leftPadded(to: 3)
    }.joined()
}

private extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}

/// `modes.tar` in `folder`: a pax tar of one folder "modes" holding
/// suid 04755, sgid 02755, locked 0000, shared/ 01777, hidden/ 0600 with inner 04755 in it, and
/// outlink, a symlink to `linkTarget` (outside the staging).
private func makeArchive(in folder: URL, linkTarget: URL) throws -> URL {
    let content = folder.appendingPathComponent("content.txt")
    try Data("hello\n".utf8).write(to: content)
    let owner = "uid=\(getuid()) gid=\(getgid())"
    let contents = mtreeEscaped(content.path)
    let spec = """
    #mtree
    modes type=dir mode=0755 \(owner)
    modes/suid type=file mode=4755 \(owner) contents=\(contents)
    modes/sgid type=file mode=2755 \(owner) contents=\(contents)
    modes/locked type=file mode=0000 \(owner) contents=\(contents)
    modes/shared type=dir mode=1777 \(owner)
    modes/hidden type=dir mode=0600 \(owner)
    modes/hidden/inner type=file mode=4755 \(owner) contents=\(contents)
    modes/outlink type=link mode=0755 link=\(mtreeEscaped(linkTarget.path)) \(owner)

    """
    let specURL = folder.appendingPathComponent("modes.mtree")
    try Data(spec.utf8).write(to: specURL)
    let archive = folder.appendingPathComponent("modes.tar")
    // bsdtar must really run and write the archive: a fixture that can't be made fails the test,
    // never skips it (/usr/bin/bsdtar ships with macOS).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: bsdtar)
    process.arguments = ["--format", "pax", "-cf", archive.path, "@\(specURL.path)"]
    let errors = Pipe()
    process.standardError = errors
    do { try process.run() } catch { throw FixtureError("cannot run \(bsdtar): \(error)") }
    let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureError("\(bsdtar) exited \(process.terminationStatus): \(stderr)")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
    guard size > 0 else { throw FixtureError("\(bsdtar) wrote no archive: \(stderr)") }
    try FileManager.default.removeItem(at: specURL)
    try FileManager.default.removeItem(at: content)
    return archive
}

@MainActor
private func openModel(_ archive: URL, fileSystem: ExtractionFileSystem = fileSystem()) async throws -> ArchiveModel {
    let model = ArchiveModel(reader: try await Archive.open(at: archive), undoManager: nil)
    model.extractionFileSystem = fileSystem
    return model
}

/// What the placed "modes" folder at `placed` must hold: no special bits, everything else kept;
/// the symlink's target outside left as it was, and the symlink too, but a drag-out (`isExport`) hands
/// another app no link out of the item (`ExportLinkSweep`).
private func expectStripped(_ placed: URL, victim: URL, isExport: Bool = false,
                            sourceLocation: SourceLocation = #_sourceLocation) throws {
    func expectMode(_ relative: String, _ expected: mode_t) {
        let actual = mode(placed.appendingPathComponent(relative))
        #expect(actual == expected, "\(relative): \(String(actual, radix: 8))", sourceLocation: sourceLocation)
    }
    expectMode("suid", 0o755)
    expectMode("sgid", 0o755)
    expectMode("shared", 0o777)
    expectMode("locked", 0o000)
    expectMode("hidden", 0o600)
    let hidden = placed.appendingPathComponent("hidden")
    guard chmod(hidden.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    expectMode("hidden/inner", 0o755)
    let link = placed.appendingPathComponent("outlink")
    var status = stat()
    if isExport {
        let rc = lstat(link.path, &status)
        let code = errno
        #expect(rc == -1 && code == ENOENT, "outlink: rc \(rc), errno \(code)", sourceLocation: sourceLocation)
    } else {
        #expect(lstat(link.path, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK, sourceLocation: sourceLocation)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == victim.path,
                sourceLocation: sourceLocation)
    }
    #expect(mode(victim) == 0o1755, "the link's target: \(String(mode(victim), radix: 8))", sourceLocation: sourceLocation)
}

/// The fixture could not be made: the test fails with the cause.
private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - The fixture itself

/// The archive really carries the bits (the engine lists them): what the tests below rely on to be
/// red if the engine wrote them.
@Test func theFixtureCarriesTheSpecialBits() async throws {
    // A space in the paths the spec names: they go in escaped (mtree(5)).
    let folder = try makeFolder("fixture with space")
    defer { removeTree(folder) }
    let archive = try makeArchive(in: folder, linkTarget: folder.appendingPathComponent("victim"))
    let entries = try await Archive.open(at: archive).entries
    func permissions(_ path: String) -> UInt16? {
        entries.first { $0.path == path || $0.path == path + "/" }?.permissions
    }
    #expect(permissions("modes/suid") == 0o4755)
    #expect(permissions("modes/sgid") == 0o2755)
    #expect(permissions("modes/shared") == 0o1777)
    #expect(permissions("modes/hidden/inner") == 0o4755)
}

// MARK: - Extract Here

@MainActor @Test func extractHereDropsTheSpecialBits() async throws {
    let folder = try makeFolder("here")
    defer { removeTree(folder) }
    let victim = folder.appendingPathComponent("victim")
    try makeVictim(victim)
    let archive = try makeArchive(in: folder, linkTarget: victim)
    let model = try await openModel(archive)

    let placed = try await ExtractHereService.extract(.single(path: "modes", name: "modes", isDirectory: true),
                                                      from: model, nextTo: archive, progress: nil)

    #expect(placed.lastPathComponent == "modes")
    try expectStripped(placed, victim: victim)
}

@MainActor @Test func extractHereWrappedDropsTheSpecialBits() async throws {
    let folder = try makeFolder("wrapped")
    defer { removeTree(folder) }
    let victim = folder.appendingPathComponent("victim")
    try makeVictim(victim)
    let archive = try makeArchive(in: folder, linkTarget: victim)
    let model = try await openModel(archive)

    let placed = try await ExtractHereService.extract(.wrapped(folderName: "wrap", paths: ["modes"]),
                                                      from: model, nextTo: archive, progress: nil)

    #expect(mode(placed) & 0o7000 == 0, "\(String(mode(placed), radix: 8))")
    try expectStripped(placed.appendingPathComponent("modes"), victim: victim)
}

// MARK: - Drag-out

@MainActor @Test(arguments: [false, true])
func dragOutDropsTheSpecialBits(_ acrossVolumes: Bool) async throws {
    let folder = try makeFolder("drag")
    defer { removeTree(folder) }
    let destination = folder.appendingPathComponent("drop", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let victim = folder.appendingPathComponent("victim")
    try makeVictim(victim)
    let archive = try makeArchive(in: folder, linkTarget: victim)
    let dropPath = destination.path
    let model = try await openModel(archive, fileSystem: fileSystem { _, to, _ in
        acrossVolumes && (to as NSString).deletingLastPathComponent == dropPath ? EXDEV : nil
    })

    let placed = try await ArchiveDragOut.write("modes", from: model,
                                                toPromised: destination.appendingPathComponent("modes"))

    try expectStripped(placed, victim: victim, isExport: true)
}

// MARK: - ExclusiveCopy

/// The cross-volume copy never carries the bits, even from a source that has them (a user's own
/// files, not only the engine's output): the source keeps its own.
@Test(.enabled(if: setIDBitsSettable, setIDBitsReason))
func anExclusiveCopyNeverCarriesTheSpecialBits() throws { try exclusiveCopyDrops(idBits: true) }

/// Hosted-safe: the sticky folders only (the files have no setuid/setgid to begin with).
@Test func anExclusiveCopyNeverCarriesTheStickyBit() throws { try exclusiveCopyDrops(idBits: false) }

private func exclusiveCopyDrops(idBits: Bool) throws {
    let folder = try makeFolder("copy")
    defer { removeTree(folder) }
    let source = folder.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("shared"), withIntermediateDirectories: true)
    try makeFile(source.appendingPathComponent("suid"), mode: idBits ? 0o4755 : 0o755)
    try makeFile(source.appendingPathComponent("shared/sgid"), mode: idBits ? 0o2750 : 0o750)
    guard chmod(source.appendingPathComponent("shared").path, 0o1777) == 0, chmod(source.path, 0o1755) == 0 else {
        throw POSIXError(.EPERM)
    }
    let single = folder.appendingPathComponent("single")
    try makeFile(single, mode: idBits ? 0o4700 : 0o700)
    // The source really has the bits (an unhosted run must not pass vacuously).
    #expect(mode(source) == 0o1755)
    #expect(mode(source.appendingPathComponent("suid")) == (idBits ? 0o4755 : 0o755))
    #expect(mode(source.appendingPathComponent("shared/sgid")) == (idBits ? 0o2750 : 0o750))
    #expect(mode(single) == (idBits ? 0o4700 : 0o700))

    let copy = folder.appendingPathComponent("copy", isDirectory: true)
    try ExclusiveCopy.copy(source, to: copy, unlocksSource: true)
    let singleCopy = folder.appendingPathComponent("single copy")
    try ExclusiveCopy.copy(single, to: singleCopy, unlocksSource: true)

    #expect(mode(copy) == 0o755, "\(String(mode(copy), radix: 8))")
    #expect(mode(copy.appendingPathComponent("suid")) == 0o755)
    #expect(mode(copy.appendingPathComponent("shared")) == 0o777)
    #expect(mode(copy.appendingPathComponent("shared/sgid")) == 0o750)
    #expect(mode(singleCopy) == 0o700)
    #expect(mode(source.appendingPathComponent("suid")) == (idBits ? 0o4755 : 0o755), "the source is left as it was")
    #expect(mode(single) == (idBits ? 0o4700 : 0o700))
}

/// A tree with a link out of it onto a fresh destination (the copy unlocking its source, as drag-out's does):
/// the link is copied as a link, never followed, so the outside 01755 folder it points at keeps its mode and
/// stays empty; removing the copy (`ExclusiveCopy.removeItem`) leaves it alone too.
@Test func anExclusiveCopyNeverTouchesAnOutwardLinksTarget() throws {
    let folder = try makeFolder("outward")
    defer { removeTree(folder) }
    let victim = folder.appendingPathComponent("victim", isDirectory: true)
    try makeVictim(victim)
    let source = folder.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try makeFile(source.appendingPathComponent("sub/file"), mode: 0o000)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("out").path,
                                               withDestinationPath: victim.path)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("sub/up").path,
                                               withDestinationPath: "../../victim")
    guard chmod(source.appendingPathComponent("sub").path, 0o500) == 0, chmod(source.path, 0o1755) == 0 else {
        throw POSIXError(.EPERM)
    }

    let copy = folder.appendingPathComponent("copy", isDirectory: true)
    try ExclusiveCopy.copy(source, to: copy, unlocksSource: true)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("out").path)
            == victim.path)
    #expect(mode(copy) == 0o755, "\(String(mode(copy), radix: 8))")
    #expect(mode(copy.appendingPathComponent("sub")) == 0o500)
    #expect(mode(victim) == 0o1755, "the link's target: \(String(mode(victim), radix: 8))")
    #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path) == [])

    try ExclusiveCopy.removeItem(at: copy)

    var status = stat()
    #expect(lstat(copy.path, &status) == -1)
    #expect(mode(victim) == 0o1755, "the link's target: \(String(mode(victim), radix: 8))")
    #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path) == [])
    #expect(mode(source.appendingPathComponent("sub")) == 0o500, "the source is left as it was")
}

// MARK: - Pending additions

/// Where a pending addition's copy is placed from: Extract Here, or a drag-out on the staging's
/// volume (renamed into place) or across volumes (`ExclusiveCopy`).
enum SpecialBitsRoute: String, CaseIterable, Sendable { case extractHere, dragOut, dragOutAcrossVolumes }

/// A file added to the unsaved archive is copied into the staging by `FileManager`, not written by
/// the engine: its setuid and setgid bits are dropped all the same (`mode & 0o777`), and the user's
/// own file keeps them.
@MainActor @Test(.enabled(if: setIDBitsSettable, setIDBitsReason), arguments: SpecialBitsRoute.allCases)
func pendingAdditionsDropTheSpecialBits(_ route: SpecialBitsRoute) async throws {
    try await pendingAdditionsDrop(idBits: true, route: route)
}

/// Hosted-safe: a sticky added file and folder only.
@MainActor @Test(arguments: SpecialBitsRoute.allCases)
func pendingAdditionsDropTheStickyBit(_ route: SpecialBitsRoute) async throws {
    try await pendingAdditionsDrop(idBits: false, route: route)
}

/// The probe only reads false where the App Sandbox clears the bits (a hosted run): an unsandboxed
/// run where it is false would skip the setuid/setgid tests above without a word.
@Test func theSetIDProbeOnlyFailsInTheSandbox() {
    #expect(setIDBitsSettable || ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            "setuid/setgid can't be set outside the App Sandbox: the setuid/setgid tests would not run")
}

@MainActor
private func pendingAdditionsDrop(idBits: Bool, route: SpecialBitsRoute) async throws {
    let folder = try makeFolder("pending")
    defer { removeTree(folder) }
    let victim = folder.appendingPathComponent("victim")
    try makeVictim(victim)
    let archive = try makeArchive(in: folder, linkTarget: victim)
    let destination = folder.appendingPathComponent("drop", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let dropPath = destination.path
    let model = try await openModel(archive, fileSystem: fileSystem { _, to, _ in
        route == .dragOutAcrossVolumes && (to as NSString).deletingLastPathComponent == dropPath ? EXDEV : nil
    })
    let added = folder.appendingPathComponent("added", isDirectory: true)
    try FileManager.default.createDirectory(at: added, withIntermediateDirectories: false)
    let sticky = added.appendingPathComponent("added-sticky")
    try makeFile(sticky, mode: 0o1644)
    let shared = added.appendingPathComponent("added-shared", isDirectory: true)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
    try makeFile(shared.appendingPathComponent("plain"), mode: 0o644)
    guard chmod(shared.path, 0o1777) == 0 else { throw POSIXError(.EPERM) }
    var urls = [sticky, shared]
    if idBits {
        let suid = added.appendingPathComponent("added-suid"), sgid = added.appendingPathComponent("added-sgid")
        try makeFile(suid, mode: 0o4755)
        try makeFile(sgid, mode: 0o2750)
        urls += [suid, sgid]
    }
    // The sources really have the bits (no vacuous pass).
    #expect(mode(sticky) == 0o1644)
    #expect(mode(shared) == 0o1777)
    if idBits {
        #expect(mode(added.appendingPathComponent("added-suid")) == 0o4755)
        #expect(mode(added.appendingPathComponent("added-sgid")) == 0o2750)
    }
    model.add(urls, to: "modes")
    #expect(model.hasChanges)

    let placed: URL
    switch route {
    case .extractHere:
        placed = try await ExtractHereService.extract(.single(path: "modes", name: "modes", isDirectory: true),
                                                      from: model, nextTo: archive, progress: nil)
    case .dragOut, .dragOutAcrossVolumes:
        placed = try await ArchiveDragOut.write("modes", from: model,
                                                toPromised: destination.appendingPathComponent("modes"))
    }

    func expectMode(_ relative: String, _ expected: mode_t) {
        let actual = mode(placed.appendingPathComponent(relative))
        #expect(actual == expected, "\(route) \(relative): \(String(actual, radix: 8))")
    }
    expectMode("added-sticky", 0o644)
    #expect(mode(placed.appendingPathComponent("added-shared")) & 0o7000 == 0)
    expectMode("added-shared/plain", 0o644)
    if idBits {
        expectMode("added-suid", 0o755)
        expectMode("added-sgid", 0o750)
        #expect(mode(added.appendingPathComponent("added-suid")) == 0o4755, "the user's file is left as it was")
    }
    #expect(mode(sticky) == 0o1644, "the user's file is left as it was")
    try expectStripped(placed, victim: victim, isExport: route != .extractHere)
}
