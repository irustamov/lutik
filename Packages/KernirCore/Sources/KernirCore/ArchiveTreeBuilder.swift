import Foundation

enum ArchiveTreeBuilder {
    /// Builds the folder tree in O(n log n): groups entries by parent, then sorts each child list
    /// (lists are sorted concurrently). Missing ancestors are synthesized as directories;
    /// for duplicate paths the last entry wins. Paths are told apart by their UTF-8 bytes, so
    /// NFC/NFD twins (equal as Swift Strings) stay two entries.
    ///
    /// An entry with the empty path is left out, folder or file: its parent is "" too, so it names the root,
    /// which is not a node (as a folder it would be its own child forever). Every other path is kept as given,
    /// and each parent is a strict prefix of its child, so every child list holds only longer paths than its
    /// folder and the walk below ends.
    static func build(_ entries: [ArchiveEntry]) -> [ArchiveNode] {
        var byPath: [ExactPath: ArchiveEntry] = [:]
        byPath.reserveCapacity(entries.count)
        for entry in entries where !entry.path.isEmpty { byPath[ExactPath(entry.path)] = entry }

        // Group by parent (computed once per entry), synthesizing missing ancestors.
        // Each key hashes its path once and goes along with its entry, so the walk below needs no new key:
        // a deep path's ancestors hold many bytes in all.
        var grouped: [ExactPath: [Child]] = [:]
        for (key, entry) in Array(byPath) {
            var parent = ExactPath(parentPath(entry.path))
            grouped[parent, default: []].append(Child(key: key, entry: entry))
            while !parent.path.isEmpty, byPath[parent] == nil {
                let synthesized = ArchiveEntry(path: parent.path, isDirectory: true, size: nil,
                                               compressedSize: nil, modificationDate: nil)
                byPath[parent] = synthesized
                let child = Child(key: parent, entry: synthesized)
                parent = ExactPath(parentPath(parent.path))
                grouped[parent, default: []].append(child)
            }
        }

        // Sort every child list: folders first, then Finder order, then UTF-8 bytes for names Finder
        // order calls equal ("A"/"a", NFC/NFD twins). The order then does not depend on the input order, except
        // for rare names where localizedStandardCompare is not a strict order (it calls each of two names smaller
        // than the other, as for "e\u{E9}" and "\u{E9}\u{301}a\u{301}\u{600}"): their order can follow the input.
        let lists = Array(grouped)
        let sortedLists = SortedLists(count: lists.count)
        DispatchQueue.concurrentPerform(iterations: lists.count) { i in
            let sorted = lists[i].value
                .map { (name: $0.entry.name as NSString, entry: $0.entry, child: $0) }
                .sorted { a, b in
                    if a.entry.isDirectory != b.entry.isDirectory { return a.entry.isDirectory }
                    switch a.name.localizedStandardCompare(b.name as String) {
                    case .orderedAscending: return true
                    case .orderedDescending: return false
                    case .orderedSame: return a.entry.path.utf8.lexicographicallyPrecedes(b.entry.path.utf8)
                    }
                }
                .map(\.child)
            sortedLists.set(i, sorted)
        }
        var childrenOf: [ExactPath: [Child]] = [:]
        childrenOf.reserveCapacity(lists.count)
        for (i, list) in lists.enumerated() { childrenOf[list.key] = sortedLists.get(i) }

        // Post-order with an explicit stack, one frame per open folder: a crafted path can be tens of thousands
        // of folders deep, too deep to recurse on a thread's stack.
        struct Frame {
            let folder: ArchiveEntry?  // nil for the root
            let entries: [Child]
            var built: [ArchiveNode] = []
        }
        var stack = [Frame(folder: nil, entries: childrenOf[ExactPath("")] ?? [])]
        while true {
            let top = stack.count - 1
            let next = stack[top].built.count
            if next < stack[top].entries.count {
                let child = stack[top].entries[next]
                let entry = child.entry
                if entry.isDirectory {
                    stack.append(Frame(folder: entry, entries: childrenOf[child.key] ?? []))
                } else {
                    stack[top].built.append(ArchiveNode(entry: entry, children: nil, totalSize: entry.size))
                }
                continue
            }
            let done = stack.removeLast()
            guard let folder = done.folder else { return done.built }
            stack[stack.count - 1].built.append(
                ArchiveNode(entry: folder, children: done.built, totalSize: total(of: done.built)))
        }
    }

    /// A folder's size: one unknown size makes it unknown, not smaller (an empty folder is 0). So does a sum past
    /// Int64 (only crafted sizes get there), which would otherwise trap.
    private static func total(of children: [ArchiveNode]) -> Int64? {
        var total: Int64 = 0
        for child in children {
            guard let size = child.totalSize else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(size)
            if overflow { return nil }
            total = sum
        }
        return total
    }

    /// Before the last "/" scalar, as `ArchiveEntry.parentPath`: never on Characters, so `a/\u{301}b` goes under `a`.
    private static func parentPath(_ path: String) -> String {
        EntryPath.parent(of: path) ?? ""
    }

    /// A path hashed and compared by its UTF-8 bytes (String == uses canonical equivalence). The path
    /// is made contiguous once (a Foundation-bridged String may not be), so both work on its bytes.
    /// The bytes are hashed once, here; every dictionary use of the key then hashes that value.
    private struct ExactPath: Hashable {
        let path: String
        private let bytesHash: Int
        init(_ path: String) {
            var path = path
            path.makeContiguousUTF8()
            var hasher = Hasher()
            path.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
            self.path = path
            bytesHash = hasher.finalize()
        }

        static func == (a: Self, b: Self) -> Bool {
            guard a.bytesHash == b.bytesHash else { return false }
            var x = a.path, y = b.path
            return x.withUTF8 { x in
                y.withUTF8 { y in
                    x.count == y.count && (x.isEmpty || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0)
                }
            }
        }

        func hash(into hasher: inout Hasher) { hasher.combine(bytesHash) }
    }

    /// An entry with its own path's key.
    private struct Child {
        let key: ExactPath
        let entry: ArchiveEntry
    }

    /// Slot-per-index storage written from concurrent iterations (each index touched once).
    private final class SortedLists: @unchecked Sendable {
        private var slots: [[Child]]
        private let lock = NSLock()
        init(count: Int) { slots = Array(repeating: [], count: count) }
        func set(_ i: Int, _ value: [Child]) { lock.lock(); slots[i] = value; lock.unlock() }
        func get(_ i: Int) -> [Child] { slots[i] }
    }
}
