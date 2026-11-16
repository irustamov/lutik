import Testing
@testable import Kernir

/// Which of the given visible paths a move into a folder actually moves (pure, no model).
@Suite struct MovePlanningTests {
    private func roots(_ paths: [String], into folder: String) -> [String]? {
        try? MovePlanning.roots(paths, into: folder).get()
    }

    @Test func ancestorWins() {
        #expect(roots(["a", "a/b"], into: "d") == ["a"])
        #expect(roots(["a/b", "a"], into: "d") == ["a"])
        #expect(roots(["a/b/c", "a/b", "x"], into: "d") == ["a/b", "x"])
    }

    @Test func intoItselfRefused() {
        #expect(MovePlanning.roots(["a"], into: "a") == .failure(.intoItself))
        #expect(MovePlanning.roots(["a"], into: "a/b/c") == .failure(.intoItself))
        #expect(MovePlanning.roots(["x", "a"], into: "a/b") == .failure(.intoItself))
    }

    @Test func alreadyThereIsNoop() {
        #expect(roots(["d/x"], into: "d") == [])
        #expect(roots(["x"], into: "") == [])
        #expect(roots([], into: "d") == [])
    }

    @Test func mixedKeepsOnlyMovers() {
        #expect(roots(["d/x", "e/y"], into: "d") == ["e/y"])
        #expect(roots(["x", "d/y"], into: "") == ["d/y"])
    }

    @Test func prefixIsPerComponent() {
        #expect(roots(["ab"], into: "a") == ["ab"])
        #expect(roots(["a"], into: "ab") == ["a"])
        #expect(roots(["a", "ab/c"], into: "e") == ["a", "ab/c"])
    }

    /// Beneath is found on the "/" scalar: `d/\u{301}x` is in `d`, so it is already there, and `d` can't go into it.
    @Test func scalarSlash() {
        #expect(roots(["d/\u{301}x"], into: "d") == [])
        #expect(MovePlanning.roots(["d"], into: "d/\u{301}x") == .failure(.intoItself))
        #expect(roots(["d", "d/\u{301}x"], into: "e") == ["d"])
    }

    /// Paths compare after NFC: an NFD spelling of a given folder is the same folder.
    @Test func comparedAfterNFC() {
        #expect(MovePlanning.roots(["caf\u{e9}"], into: "cafe\u{301}/x") == .failure(.intoItself))
        #expect(roots(["cafe\u{301}/a"], into: "caf\u{e9}") == [])
        #expect(roots(["caf\u{e9}", "cafe\u{301}/a"], into: "") == [])
    }

    @Test func duplicatesCountOnce() {
        #expect(roots(["a/x", "a/x"], into: "") == ["a/x"])
    }

    @Test func messages() {
        #expect(MovePlanning.message(for: .intoItself) == "An item can’t be moved into itself.")
        #expect(MovePlanning.message(for: .taken("a.txt"))
                == "More than one item named “a.txt” would be moved into this folder.")
        #expect(MovePlanning.message(for: .unavailable) == "These items can’t be moved.")
        #expect(MovePlanning.message(for: .notAFolder) == "These items can’t be moved.")
        #expect(MovePlanning.message(for: .holdsMovedOutItems("docs"))
                == "“docs” can’t be used until you save, because items were moved out of a deleted folder with that name.")
    }
}
