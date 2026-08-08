import XCTest
@testable import ExpanderEngine

/// Adversarial tests for `HeldExpansionCoordinator` — the serialization layer that makes the
/// prefix-debounce state machine safe against its three concurrent writers (tap thread,
/// debounce timer, cancel paths).
///
/// The invariant everything here hammers: **each armed generation is consumed at most once** —
/// one fire or one cancel, never both, never twice. The specific regression this guards:
/// the engine used to read the hold, unlock, compute the keystroke decision, then re-store the
/// result; a debounce timer firing in that gap expanded the trigger *and* the keystroke path
/// re-armed a ghost hold for the already-erased text, which could fire a second expansion.
final class HeldExpansionCoordinatorTests: XCTestCase {

    private typealias Coordinator = HeldExpansionCoordinator<Int>

    /// Lock-guarded mutable cell so concurrent test closures never mutate a captured `var`
    /// (an error once dispatch closures are `@Sendable`).
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
        func mutate(_ body: (inout T) -> Void) {
            lock.lock(); body(&_value); lock.unlock()
        }
    }

    private func snippet(
        _ trigger: String,
        requireWordBoundary: Bool = false
    ) -> SnippetModel {
        SnippetModel(
            title: trigger,
            triggerKeyword: trigger,
            replacementText: "x",
            isCaseSensitive: false,
            requireWordBoundary: requireWordBoundary
        )
    }

    /// `` `slm `` is a strict prefix of `` `slmabout `` — the ambiguity under test throughout.
    private var index: TriggerPrefixIndex {
        TriggerPrefixIndex(snippets: [snippet("`slm"), snippet("`slmabout")])
    }

    // MARK: - Single-threaded lifecycle

    func testTimeoutClaimFiresAFreshHoldExactlyOnce() {
        let coordinator = Coordinator()
        let hold = coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)

        let claimed = coordinator.claimForTimeout(generation: hold.generation)
        XCTAssertEqual(claimed?.payload, 1)
        XCTAssertFalse(coordinator.hasHold)

        XCTAssertNil(
            coordinator.claimForTimeout(generation: hold.generation),
            "A generation must be claimable at most once."
        )
        XCTAssertEqual(coordinator.telemetry.firedByTimeout, 1)
    }

    func testExtensionKeystrokeInvalidatesThePendingTimer() {
        let coordinator = Coordinator()
        let hold = coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)

        guard case .rearmed(let rearmed) = coordinator.resolveKeystroke(
            typedNow: "a", isDelete: false, prefixIndex: index
        ) else {
            return XCTFail("`slma is still on the way to `slmabout — expected .rearmed.")
        }
        XCTAssertEqual(rearmed.state.typedAfter, "a")

        XCTAssertNil(
            coordinator.claimForTimeout(generation: hold.generation),
            "The old generation's timer must be a no-op after the timer reset."
        )
        XCTAssertNil(
            coordinator.claimForTimeout(generation: rearmed.generation),
            "An extended hold has no firing timer — `mayFireOnTimeout` is false — so even the"
                + " correct generation must not claim it."
        )
        XCTAssertTrue(coordinator.hasHold, "Refused claims must not consume the hold.")
        XCTAssertEqual(coordinator.telemetry.racesAbsorbed, 2)
    }

    func testDivergentKeystrokeFiresWithTheAccumulatedSuffix() {
        let coordinator = Coordinator()
        let hold = coordinator.arm(payload: 7, trigger: "`slm", focusPID: nil)

        _ = coordinator.resolveKeystroke(typedNow: "a", isDelete: false, prefixIndex: index)
        _ = coordinator.resolveKeystroke(typedNow: "b", isDelete: false, prefixIndex: index)
        guard case .fire(let fired, let suffix) = coordinator.resolveKeystroke(
            typedNow: "!", isDelete: false, prefixIndex: index
        ) else {
            return XCTFail("`slmab! diverges from every trigger — expected .fire.")
        }
        XCTAssertEqual(fired.payload, 7)
        XCTAssertEqual(suffix, "ab!", "The whole typed-during-hold suffix must fire, or text is lost.")
        XCTAssertFalse(coordinator.hasHold)
        XCTAssertNil(
            coordinator.claimForTimeout(generation: hold.generation),
            "A fired hold must be gone for every pending timer."
        )
    }

    /// Paste / IME commit: several characters can arrive in one event.
    ///
    /// §8.5 split the outcome in two:
    ///  * an event that lands EXACTLY on a longer trigger is a completion — the matcher owns
    ///    expanding it, so the resolve path must keep the hold (and never fire the shorter over
    ///    text that spells the longer trigger in full);
    ///  * an event that overshoots past every trigger is a divergence — the hold fires in one
    ///    step with the whole suffix, exactly as immediate firing would have left the field.
    func testMultiCharacterEventResolvesInOneStep() {
        let exact = Coordinator()
        exact.arm(payload: 1, trigger: "`slm", focusPID: nil)
        guard case .rearmed(let hold) = exact.resolveKeystroke(
            typedNow: "about", isDelete: false, prefixIndex: index
        ) else {
            return XCTFail("`slmabout is a complete trigger — the shorter must not fire over it.")
        }
        XCTAssertTrue(hold.state.passedThroughLongerTrigger)

        let overshoot = Coordinator()
        overshoot.arm(payload: 1, trigger: "`slm", focusPID: nil)
        guard case .fire(_, let suffix) = overshoot.resolveKeystroke(
            typedNow: "abouz", isDelete: false, prefixIndex: index
        ) else {
            return XCTFail("Nothing extends or equals `slmabouz — expected .fire.")
        }
        XCTAssertEqual(suffix, "abouz")
    }

    func testBackspaceReturnTabAndBareChordsCancel() {
        for (typedNow, isDelete) in [("", true), ("\n", false), ("\t", false), ("", false)] {
            let coordinator = Coordinator()
            let hold = coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)
            guard case .cancelled(.editOrCaretMove) = coordinator.resolveKeystroke(
                typedNow: typedNow, isDelete: isDelete, prefixIndex: index
            ) else {
                return XCTFail("typedNow=\(typedNow.debugDescription) isDelete=\(isDelete) must cancel.")
            }
            XCTAssertFalse(coordinator.hasHold)
            XCTAssertNil(
                coordinator.claimForTimeout(generation: hold.generation),
                "A cancelled hold must never fire from a stale timer."
            )
        }
    }

    func testStaleExpiryCancelsOnlyItsOwnGeneration() {
        let coordinator = Coordinator()
        let first = coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)
        guard case .rearmed(let rearmed) = coordinator.resolveKeystroke(
            typedNow: "a", isDelete: false, prefixIndex: index
        ) else {
            return XCTFail("Expected .rearmed.")
        }

        XCTAssertFalse(
            coordinator.cancel(generation: first.generation, reason: .stale),
            "An expiry timer from before the re-arm must not cancel the newer hold."
        )
        XCTAssertTrue(coordinator.hasHold)
        XCTAssertTrue(coordinator.cancel(generation: rearmed.generation, reason: .stale))
        XCTAssertFalse(coordinator.hasHold)
        XCTAssertEqual(coordinator.telemetry.expiredStale, 1)
    }

    func testKeystrokeAfterConsumptionSeesNoHold() {
        let coordinator = Coordinator()
        let hold = coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)
        _ = coordinator.claimForTimeout(generation: hold.generation)
        guard case .noHold = coordinator.resolveKeystroke(
            typedNow: "a", isDelete: false, prefixIndex: index
        ) else {
            return XCTFail("A consumed hold must not be advanced — that is the ghost-hold bug.")
        }
    }

    // MARK: - The race this design exists to close

    /// The regression: a keystroke extending the hold races the debounce timer at the deadline.
    /// Exactly one of the two may win, and the loser must observe a world in which it lost:
    /// either the timer claims and the keystroke sees no hold, or the keystroke re-arms and the
    /// timer's claim is refused. Both winning re-arms a ghost of an already-expanded trigger —
    /// a later second expansion of text that is no longer in the field.
    func testTimerVersusExtensionKeystrokeNeverBothWin() {
        for _ in 0..<2000 {
            let coordinator = Coordinator()
            let hold = coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)

            let claimed = Box<Bool>(false)
            let rearmed = Box<Bool>(false)
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "race", attributes: .concurrent)
            let prefixIndex = index

            queue.async(group: group) {
                claimed.value = coordinator.claimForTimeout(generation: hold.generation) != nil
            }
            queue.async(group: group) {
                if case .rearmed = coordinator.resolveKeystroke(
                    typedNow: "a", isDelete: false, prefixIndex: prefixIndex
                ) {
                    rearmed.value = true
                }
            }
            group.wait()

            if claimed.value {
                XCTAssertFalse(
                    rearmed.value,
                    "Timer claimed the hold AND the keystroke re-armed it — ghost hold resurrected."
                )
                XCTAssertFalse(coordinator.hasHold)
            } else {
                XCTAssertTrue(
                    rearmed.value,
                    "Someone must win: claim refused implies the keystroke re-armed."
                )
                XCTAssertTrue(coordinator.hasHold)
            }
        }
    }

    /// Many timers (duplicate asyncAfter deliveries, re-entrant health paths) plus a decisive
    /// keystroke all racing for one hold: the total number of successful consumptions must be
    /// exactly one.
    func testManyClaimantsProduceExactlyOneFire() {
        for _ in 0..<500 {
            let coordinator = Coordinator()
            let hold = coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)

            let fires = Box<Int>(0)
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "claimants", attributes: .concurrent)
            let prefixIndex = index

            for _ in 0..<4 {
                queue.async(group: group) {
                    if coordinator.claimForTimeout(generation: hold.generation) != nil {
                        fires.mutate { $0 += 1 }
                    }
                }
            }
            queue.async(group: group) {
                if case .fire = coordinator.resolveKeystroke(
                    typedNow: "!", isDelete: false, prefixIndex: prefixIndex
                ) {
                    fires.mutate { $0 += 1 }
                }
            }
            group.wait()

            XCTAssertEqual(fires.value, 1, "One hold, several claimants — exactly one expansion.")
            XCTAssertFalse(coordinator.hasHold)
        }
    }

    /// `cancelAll` (mouse click / focus switch / longer trigger) racing a timer claim: a fire
    /// after cancellation would erase at a caret the user has since moved. Either the cancel
    /// consumed the hold and the claim gets nothing, or the claim fired first — never both.
    func testCancelVersusClaimIsConsumedExactlyOnce() {
        for _ in 0..<2000 {
            let coordinator = Coordinator()
            let hold = coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)

            let claimed = Box<Bool>(false)
            let cancelled = Box<Bool>(false)
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "cancel-race", attributes: .concurrent)

            queue.async(group: group) {
                claimed.value = coordinator.claimForTimeout(generation: hold.generation) != nil
            }
            queue.async(group: group) {
                cancelled.value = coordinator.cancelAll(reason: .bufferReset)
            }
            group.wait()

            XCTAssertTrue(
                claimed.value != cancelled.value,
                "The hold must be consumed by exactly one side."
            )
            XCTAssertFalse(coordinator.hasHold)
        }
    }

    // MARK: - Fuzzed typing storm

    /// Ultra-fast typing with randomized interleaving: one writer hammers keystrokes (matching
    /// characters, divergent characters, backspaces, submits), while timers claim stale and
    /// current generations and resets strike at random. Invariants:
    ///   * consumptions (fires + cancels) never exceed arms,
    ///   * a fired suffix is always a subsequence the state machine actually accumulated,
    ///   * the coordinator never wedges: after the storm it can arm and fire cleanly.
    func testFuzzedStormMaintainsAtMostOneConsumptionPerArm() {
        let coordinator = Coordinator()
        let prefixIndex = index

        let arms = Box<Int>(0)
        let consumptions = Box<Int>(0)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "storm", attributes: .concurrent)

        // Deterministic pseudo-random stream per thread; seeds differ so schedules diverge.
        func makeStream(_ seed: UInt64) -> () -> UInt64 {
            var state = seed
            return {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return state
            }
        }

        for thread in 0..<4 {
            queue.async(group: group) {
                let next = makeStream(UInt64(thread) &* 0x9E3779B97F4A7C15 &+ 1)
                for _ in 0..<2500 {
                    switch next() % 10 {
                    case 0, 1:
                        let hold = coordinator.arm(payload: thread, trigger: "`slm", focusPID: nil)
                        arms.mutate { $0 += 1 }
                        // Sometimes let a "timer" for this very generation race the others.
                        if next() % 2 == 0,
                           coordinator.claimForTimeout(generation: hold.generation) != nil {
                            consumptions.mutate { $0 += 1 }
                        }
                    case 2, 3, 4, 5:
                        let inputs = ["a", "b", "o", "u", "t", "x", " ", "\n", "\t", ""]
                        let typed = inputs[Int(next() % UInt64(inputs.count))]
                        let isDelete = next() % 7 == 0
                        switch coordinator.resolveKeystroke(
                            typedNow: isDelete ? "" : typed,
                            isDelete: isDelete,
                            prefixIndex: prefixIndex
                        ) {
                        case .fire, .cancelled:
                            consumptions.mutate { $0 += 1 }
                        case .noHold, .rearmed:
                            break
                        }
                    case 6, 7:
                        // Late timers firing against an old generation. A low number is only
                        // *usually* stale: at the start of the storm the live generation is a low
                        // number too, so this claim sometimes lands on a real hold and consumes
                        // it. Counting it is what makes the accounting below exact — discarding
                        // the result made this test fail on roughly one schedule in three, with
                        // telemetry one ahead of the tally, and the product code innocent.
                        if coordinator.claimForTimeout(generation: next() % 50) != nil {
                            consumptions.mutate { $0 += 1 }
                        }
                        // A generation that can never have been issued must always be a no-op —
                        // the original intent of this case, now stated so it cannot drift.
                        XCTAssertNil(
                            coordinator.claimForTimeout(generation: UInt64.max - next() % 1000)
                        )
                    default:
                        if coordinator.cancelAll(reason: .bufferReset) {
                            consumptions.mutate { $0 += 1 }
                        }
                    }
                }
            }
        }
        group.wait()

        // Drain any survivor so the accounting below is exact.
        if coordinator.cancelAll(reason: .bufferReset) { consumptions.mutate { $0 += 1 } }

        XCTAssertLessThanOrEqual(
            consumptions.value, arms.value,
            "More consumptions than arms means some hold fired or cancelled twice."
        )
        let telemetry = coordinator.telemetry
        XCTAssertEqual(telemetry.armed, arms.value)
        XCTAssertEqual(
            telemetry.firedByTimeout + telemetry.firedByKeystroke
                + telemetry.cancelledByEdit + telemetry.cancelledByReset
                + telemetry.cancelledLongerWon
                + telemetry.expiredStale + telemetry.cancelledUnobserved,
            consumptions.value,
            "Telemetry must account for every consumption exactly once."
        )

        // The coordinator must come out of the storm fully functional.
        let hold = coordinator.arm(payload: 99, trigger: "`slm", focusPID: nil)
        XCTAssertEqual(coordinator.claimForTimeout(generation: hold.generation)?.payload, 99)
    }

    // MARK: - Suffix integrity under sequential fast typing

    /// Fast typing with no pauses: `` `slm `` then `a b o u` then a divergent `!`. The fired
    /// suffix must be exactly the characters typed during the hold, in order — the erase plan
    /// and the re-appended text both depend on it byte-for-byte.
    func testSequentialFastTypingPreservesSuffixOrder() {
        let coordinator = Coordinator()
        coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)
        for character in ["a", "b", "o", "u"] {
            guard case .rearmed = coordinator.resolveKeystroke(
                typedNow: character, isDelete: false, prefixIndex: index
            ) else {
                return XCTFail("`slm\(character)… is still viable — expected .rearmed.")
            }
        }
        guard case .fire(_, let suffix) = coordinator.resolveKeystroke(
            typedNow: "!", isDelete: false, prefixIndex: index
        ) else {
            return XCTFail("Expected the divergent keystroke to fire the hold.")
        }
        XCTAssertEqual(suffix, "abou!")
    }
}
