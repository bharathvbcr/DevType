import XCTest
@testable import DevTypeAppCore

/// The AI preview used to apply every streamed snapshot as its own whole-view replacement.
/// Snapshots are now coalesced to one application per scheduled turn, and growth is appended
/// rather than re-laid-out. The final text must stay byte-exact through all of it.
final class AIPreviewPartialCoalescerTests: XCTestCase {

    private final class Harness {
        var queued: [() -> Void] = []
        var applied: [String] = []
        lazy var coalescer = AIPreviewPartialCoalescer(
            schedule: { [unowned self] work in queued.append(work) },
            apply: { [unowned self] text in applied.append(text) }
        )
        func runTurn() {
            let work = queued
            queued.removeAll()
            work.forEach { $0() }
        }
    }

    func testManyPartialsInOneTurnApplyOnlyTheNewest() {
        let h = Harness()
        for index in 0..<500 { h.coalescer.offer("partial \(index)") }
        XCTAssertEqual(h.queued.count, 1, "One scheduled turn however many partials arrive")
        h.runTurn()
        XCTAssertEqual(h.applied, ["partial 499"])
    }

    func testEachTurnAppliesAtMostOnceAndRearms() {
        let h = Harness()
        h.coalescer.offer("a")
        h.runTurn()
        h.coalescer.offer("ab")
        h.coalescer.offer("abc")
        h.runTurn()
        h.runTurn()
        XCTAssertEqual(h.applied, ["a", "abc"])
    }

    func testCancelDropsQueuedPartialSoFinalTextIsNotOverwritten() {
        let h = Harness()
        h.coalescer.offer("stale partial")
        h.coalescer.cancel()
        h.runTurn()
        XCTAssertEqual(h.applied, [])
        h.coalescer.offer("fresh")
        h.runTurn()
        XCTAssertEqual(h.applied, ["fresh"], "Cancelling must not wedge later offers")
    }

    func testTakePendingHandsOverTheQueuedPartialForAFailedRequest() {
        let h = Harness()
        h.coalescer.offer("streamed so far")
        XCTAssertEqual(h.coalescer.takePending(), "streamed so far",
                       "A failure that overtakes the turn must still get the newest partial")
        XCTAssertNil(h.coalescer.takePending())
        h.runTurn()
        XCTAssertEqual(h.applied, [], "A taken partial is not applied a second time")
        h.coalescer.offer("next")
        h.runTurn()
        XCTAssertEqual(h.applied, ["next"])
    }

    func testEmptyPartialIsStillApplied() {
        let h = Harness()
        h.coalescer.offer("")
        h.runTurn()
        XCTAssertEqual(h.applied, [""])
    }

    // MARK: - Append vs replace

    func testGrowthIsAppendedExactly() {
        XCTAssertEqual(AIPreviewPartialCoalescer.appendedTail(from: "", to: "hello"), "hello")
        XCTAssertEqual(AIPreviewPartialCoalescer.appendedTail(from: "hello", to: "hello world"), " world")
        XCTAssertEqual(AIPreviewPartialCoalescer.appendedTail(from: "same", to: "same"), "")
    }

    func testRevisionOfEarlierTextReplacesInsteadOfAppending() {
        XCTAssertNil(AIPreviewPartialCoalescer.appendedTail(from: "hello world", to: "hello"))
        XCTAssertNil(AIPreviewPartialCoalescer.appendedTail(from: "helo", to: "hello world"))
        XCTAssertNil(AIPreviewPartialCoalescer.appendedTail(from: "abc", to: "xyz"))
    }

    func testUnicodeStreamReassemblesByteExact() {
        let finalText = "日本語のテキスト 👨‍👩‍👧‍👦 e\u{301}clair 🇯🇵 العربية"
        // Stream grapheme by grapheme, then also scalar by scalar (splits clusters mid-way).
        for pieces in [finalText.map(String.init), finalText.unicodeScalars.map { String($0) }] {
            var shown = ""
            var prefix = ""
            for piece in pieces {
                prefix += piece
                if let tail = AIPreviewPartialCoalescer.appendedTail(from: shown, to: prefix) {
                    shown += tail
                } else {
                    shown = prefix
                }
                XCTAssertEqual(shown.unicodeScalars.map(\.value), prefix.unicodeScalars.map(\.value))
            }
            XCTAssertEqual(shown, finalText)
        }
    }

    func testOutOfOrderAndDuplicatePartialsEndOnTheLastOffered() {
        let h = Harness()
        for text in ["abc", "ab", "abc", "abc", "abcd", "abc"] { h.coalescer.offer(text) }
        h.runTurn()
        XCTAssertEqual(h.applied, ["abc"])
    }
}
