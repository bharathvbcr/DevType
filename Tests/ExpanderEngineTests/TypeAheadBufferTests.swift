import XCTest
@testable import ExpanderEngine

/// Adversarial tests for §8.3 type-ahead holding.
///
/// The bug: typing `` `slmabout `` in an Electron host produced `aScholarLM`. The trigger fired,
/// the erase ran, and the replacement went out as an async paste — and the `a` typed next reached
/// the field first, because the tap passed real keystrokes straight through during delivery.
///
/// The fix holds those keystrokes and replays them after. That trades one bug for a far worse
/// class of bug if it is ever wrong, so these tests are written to break the invariant rather than
/// to confirm the happy path:
///
///     **every admitted keystroke is replayed exactly once**
///
/// A test here that fails means characters the user typed were eaten, duplicated, or reordered.
final class TypeAheadBufferTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func admit(
        _ buffer: inout TypeAheadBuffer,
        _ text: String,
        synthetic: Bool = false,
        resets: Bool = false,
        pid: pid_t? = 42,
        at offset: TimeInterval = 0
    ) -> TypeAheadBuffer.Decision {
        buffer.admit(
            unicode: text,
            isSynthetic: synthetic,
            resetsBuffer: resets,
            focusPID: pid,
            now: t0.addingTimeInterval(offset)
        )
    }

    // MARK: - The regression

    /// The exact `aScholarLM` sequence: expansion in flight, user types on.
    func testKeystrokesDuringDeliveryAreHeldNotPassedThrough() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)

        XCTAssertEqual(admit(&buffer, "a", at: 0.01), .swallow)
        XCTAssertEqual(admit(&buffer, "b", at: 0.02), .swallow)

        XCTAssertEqual(
            buffer.endExpansion(), "ab",
            "held characters must come back in typing order, after the expansion"
        )
    }

    func testNothingIsHeldWhenNoExpansionIsInFlight() {
        var buffer = TypeAheadBuffer()
        XCTAssertEqual(admit(&buffer, "a"), .passThrough)
        XCTAssertTrue(buffer.isEmpty)
    }

    /// Our own backspaces and ⌘V must reach the app, or the expansion deadlocks behind its output.
    func testSyntheticEventsAreNeverHeld() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        XCTAssertEqual(admit(&buffer, "\u{8}", synthetic: true, at: 0.01), .passThrough)
        XCTAssertTrue(buffer.isEmpty)
    }

    // MARK: - The invariant: nothing may be eaten

    /// A hung injection must not swallow the user's typing forever.
    func testDeadlineReleasesEverythingHeld() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        XCTAssertEqual(admit(&buffer, "a", at: 0.01), .swallow)

        XCTAssertEqual(
            admit(&buffer, "b", at: TypeAheadBuffer.defaultDeadline + 0.01),
            .flushThenPassThrough(replay: "a"),
            "past the deadline the hold gives up ordering — but never the characters"
        )
        XCTAssertFalse(buffer.isHolding, "a flush must end the hold, not leave it half-open")
        XCTAssertEqual(admit(&buffer, "c", at: 1.0), .passThrough)
    }

    /// A burst longer than the queue must release what it has rather than drop the overflow.
    func testCapacityOverflowFlushesRatherThanDropping() {
        var buffer = TypeAheadBuffer(capacity: 3)
        buffer.beginExpansion(focusPID: 42, now: t0)
        XCTAssertEqual(admit(&buffer, "a", at: 0.01), .swallow)
        XCTAssertEqual(admit(&buffer, "b", at: 0.02), .swallow)
        XCTAssertEqual(admit(&buffer, "c", at: 0.03), .swallow)
        XCTAssertEqual(
            admit(&buffer, "d", at: 0.04),
            .flushThenPassThrough(replay: "abc"),
            "the overflowing key passes through; the three before it are replayed first"
        )
    }

    /// Every exit returns the queue exactly once — a second call must not replay it again.
    func testEndExpansionIsIdempotentAndDoesNotDuplicate() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        _ = admit(&buffer, "a", at: 0.01)
        XCTAssertEqual(buffer.endExpansion(), "a")
        XCTAssertEqual(buffer.endExpansion(), "", "a second end must not replay the same keys")
    }

    func testFlushedKeysAreNotAlsoReturnedByEndExpansion() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        _ = admit(&buffer, "a", at: 0.01)
        guard case .flushThenPassThrough(let replay) = admit(&buffer, "\r", at: 0.02) else {
            return XCTFail("Return must flush")
        }
        XCTAssertEqual(replay, "a")
        XCTAssertEqual(
            buffer.endExpansion(), "",
            "characters already replayed by a flush must not be replayed again at end"
        )
    }

    // MARK: - Keys whose ordering cannot be honoured

    /// Return/Tab submit in a chat box; a replay after submission types into the *next* message.
    func testReturnAndTabFlushInsteadOfBeingHeld() {
        for terminator in ["\r", "\n", "\t"] {
            var buffer = TypeAheadBuffer()
            buffer.beginExpansion(focusPID: 42, now: t0)
            _ = admit(&buffer, "x", at: 0.01)
            XCTAssertEqual(
                admit(&buffer, terminator, at: 0.02),
                .flushThenPassThrough(replay: "x"),
                "\(terminator.debugDescription) must not be held"
            )
        }
    }

    /// Arrows/Escape/⌘-chords move the caret, so "after the expansion" stops being a position.
    func testCaretMovingKeysFlush() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        _ = admit(&buffer, "x", at: 0.01)
        XCTAssertEqual(
            admit(&buffer, "", resets: true, at: 0.02),
            .flushThenPassThrough(replay: "x")
        )
    }

    /// Backspace during delivery would otherwise be replayed *after* the expansion and delete the
    /// end of it, instead of deleting what the user was actually looking at.
    func testBackspaceFlushesRatherThanBeingHeld() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        _ = admit(&buffer, "x", at: 0.01)
        XCTAssertEqual(
            admit(&buffer, "\u{8}", at: 0.02),
            .flushThenPassThrough(replay: "x")
        )
    }

    /// Replaying into an app the user switched to would type their characters somewhere they
    /// never typed them.
    func testFocusChangeFlushes() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        _ = admit(&buffer, "x", at: 0.01)
        XCTAssertEqual(
            admit(&buffer, "y", pid: 99, at: 0.02),
            .flushThenPassThrough(replay: "x"),
            "a hold belongs to the app it began in"
        )
    }

    /// An unknown PID is not evidence of a switch — it must not trigger a spurious flush.
    func testUnknownFocusPIDDoesNotFlush() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        XCTAssertEqual(admit(&buffer, "x", pid: nil, at: 0.01), .swallow)
    }

    // MARK: - Caret moves the tap sees, but `admit` never does

    /// A mouse click is not a `keyDown`, so it never reaches `admit` — the engine has to flush
    /// explicitly. Without this the held characters are replayed *after* the click, landing
    /// wherever the user clicked instead of where they typed them. Passing them straight through
    /// would at least have put them at the old caret; holding moves them, which is worse.
    func testCaretChangeFlushesHeldKeys() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        _ = admit(&buffer, "a", at: 0.01)

        XCTAssertEqual(
            buffer.flushForCaretChange(), "a",
            "a click during delivery must release held keys, not relocate them"
        )
        XCTAssertFalse(buffer.isHolding)
        XCTAssertEqual(
            buffer.endExpansion(), "",
            "already-flushed keys must not be replayed a second time when the expansion ends"
        )
    }

    func testCaretChangeWithNothingHeldIsHarmless() {
        var buffer = TypeAheadBuffer()
        XCTAssertEqual(buffer.flushForCaretChange(), "")
        buffer.beginExpansion(focusPID: 42, now: t0)
        XCTAssertEqual(buffer.flushForCaretChange(), "")
    }

    // MARK: - Boundaries

    func testDeadlineIsExclusiveAtTheInstantItExpires() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        XCTAssertEqual(
            admit(&buffer, "a", at: TypeAheadBuffer.defaultDeadline),
            .flushThenPassThrough(replay: ""),
            "exactly at the deadline the hold is over"
        )
    }

    func testMultiCharacterKeystrokeCountsTowardCapacity() {
        var buffer = TypeAheadBuffer(capacity: 3)
        buffer.beginExpansion(focusPID: 42, now: t0)
        XCTAssertEqual(admit(&buffer, "ab", at: 0.01), .swallow)
        XCTAssertEqual(
            admit(&buffer, "cd", at: 0.02),
            .flushThenPassThrough(replay: "ab"),
            "capacity counts characters, not keystrokes"
        )
    }

    func testBeginExpansionDiscardsNothingFromAPriorCompletedHold() {
        var buffer = TypeAheadBuffer()
        buffer.beginExpansion(focusPID: 42, now: t0)
        _ = admit(&buffer, "a", at: 0.01)
        XCTAssertEqual(buffer.endExpansion(), "a")
        buffer.beginExpansion(focusPID: 42, now: t0.addingTimeInterval(1))
        XCTAssertTrue(buffer.isEmpty, "a new hold starts clean")
    }

    /// Exhaustive: whatever the sequence, the characters that come out equal the characters that
    /// were swallowed — never more, never fewer, never reordered.
    func testNoSequenceOfEventsEverLosesOrDuplicatesACharacter() {
        let alphabet = ["a", "b", "\r", "\u{8}", "", "cd"]
        for seed in 0..<4_000 {
            var rng = SplitMix64(seed: UInt64(seed))
            var buffer = TypeAheadBuffer(capacity: 4, holdWindow: 0.2)
            buffer.beginExpansion(focusPID: 42, now: t0)

            var swallowed = ""
            var replayed = ""
            var clock: TimeInterval = 0

            for _ in 0..<12 {
                clock += Double(rng.next() % 60) / 1000.0
                let text = alphabet[Int(rng.next() % UInt64(alphabet.count))]
                let resets = rng.next() % 8 == 0
                let pid: pid_t? = rng.next() % 10 == 0 ? 99 : 42

                switch admit(&buffer, text, resets: resets, pid: pid, at: clock) {
                case .swallow:
                    swallowed += text
                case .flushThenPassThrough(let replay):
                    replayed += replay
                case .passThrough:
                    break
                }
            }
            replayed += buffer.endExpansion()

            XCTAssertEqual(
                replayed, swallowed,
                "seed \(seed): everything swallowed must come back, in order, exactly once"
            )
        }
    }
}

/// Deterministic RNG — the randomised test must reproduce exactly when it fails.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
