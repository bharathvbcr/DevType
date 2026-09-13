import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// Adversarial coverage of the two gates that decide whether an already-generated payload is
/// written into the user's field: the focus wait (`sourceFocusRetryDecision`) and the entry-gate
/// target comparison (`PasteTarget.mismatch` / `entryGateRefusal`).
///
/// Both are pure, and both have small finite input domains, so these enumerate the domains
/// *exhaustively* rather than sampling. A property that holds across the whole space is worth
/// more than a handful of hand-picked cases — the bug these exist for (focus arriving read as
/// focus changing) lived in exactly the corner nobody hand-picked.
final class SourceFocusGateStressTests: XCTestCase {

    private static let sourcePID: pid_t = 20
    private static let ownPID: pid_t = 10
    private static let thirdPID: pid_t = 30

    private static let focusStates: [SelectionReader.AXFocusObservation] = [
        .notObserved, .unfocused, .ownProcess,
        .external(element: 1), .external(element: 2),
    ]

    /// Every combination the decision can be handed, including invalid ones.
    private static func allInputs() -> [(
        sourcePID: pid_t, frontmostPID: pid_t?, terminated: Bool, remainingPolls: Int,
        focus: SelectionReader.AXFocusObservation, previous: SelectionReader.AXFocusObservation
    )] {
        var inputs: [(pid_t, pid_t?, Bool, Int, SelectionReader.AXFocusObservation, SelectionReader.AXFocusObservation)] = []
        for source in [-1, 0, 1, sourcePID] as [pid_t] {
            for frontmost in [nil, ownPID, sourcePID, thirdPID] as [pid_t?] {
                for terminated in [false, true] {
                    for remaining in [-1, 0, 1, 2, SelectionReader.sourceFocusMaxPolls - 1,
                                      SelectionReader.sourceFocusMaxPolls,
                                      SelectionReader.sourceFocusMaxPolls + 1] {
                        for focus in focusStates {
                            for previous in focusStates {
                                inputs.append((source, frontmost, terminated, remaining, focus, previous))
                            }
                        }
                    }
                }
            }
        }
        return inputs.map {
            (sourcePID: $0.0, frontmostPID: $0.1, terminated: $0.2,
             remainingPolls: $0.3, focus: $0.4, previous: $0.5)
        }
    }

    private static func decide(
        _ input: (sourcePID: pid_t, frontmostPID: pid_t?, terminated: Bool, remainingPolls: Int,
                  focus: SelectionReader.AXFocusObservation, previous: SelectionReader.AXFocusObservation)
    ) -> SelectionReader.SourceFocusRetryDecision {
        SelectionReader.sourceFocusRetryDecision(
            sourcePID: input.sourcePID,
            frontmostPID: input.frontmostPID,
            sourceTerminated: input.terminated,
            remainingPolls: input.remainingPolls,
            axFocus: input.focus,
            previousAXFocus: input.previous
        )
    }

    // MARK: - Exhaustive invariants

    /// The safety property the whole wait exists to protect: a target is never captured while
    /// some app other than the source is in front. Capturing there would pin the paste to
    /// whatever the user switched to.
    func testNeverReadsWhileAnotherAppIsFrontmost() {
        for input in Self.allInputs() where input.frontmostPID != input.sourcePID {
            XCTAssertNotEqual(
                Self.decide(input), .read,
                "read with frontmost=\(String(describing: input.frontmostPID)) source=\(input.sourcePID)"
            )
        }
    }

    /// Invalid inputs fail closed, never "read anyway". A negative or oversized budget is a
    /// caller bug, and guessing past it would deliver input into an unknown state.
    func testInvalidInputsAlwaysFailClosed() {
        for input in Self.allInputs() {
            let invalid = input.sourcePID <= 0
                || input.terminated
                || input.remainingPolls < 0
                || input.remainingPolls > SelectionReader.sourceFocusMaxPolls
            guard invalid else { continue }
            XCTAssertEqual(Self.decide(input), .fail, "\(input)")
        }
    }

    /// A wait always spends exactly one poll and never hands back a budget it was not given.
    /// This is what makes the loop terminate; an off-by-one here is an infinite poll.
    func testWaitStrictlyConsumesBudgetAndStaysInRange() {
        for input in Self.allInputs() {
            guard case .wait(let next) = Self.decide(input) else { continue }
            XCTAssertEqual(next, input.remainingPolls - 1, "\(input)")
            XCTAssertGreaterThanOrEqual(next, 0, "\(input)")
            XCTAssertLessThan(next, SelectionReader.sourceFocusMaxPolls + 1, "\(input)")
        }
    }

    /// With the budget spent the decision must be terminal — never another wait.
    func testExhaustedBudgetNeverWaits() {
        for input in Self.allInputs() where input.remainingPolls == 0 {
            if case .wait = Self.decide(input) { XCTFail("waited with no budget: \(input)") }
        }
    }

    /// Focus inside DevType, or nowhere at all, is focus that has not arrived. Reading there is
    /// what produced a captured target of our own panel — or of nothing — and a refused inject.
    /// Only the spent budget may override it, and then it is a deliberate best-effort read.
    func testFocusThatHasNotLeftUsOnlyReadsWhenTheBudgetIsSpent() {
        for input in Self.allInputs() {
            guard input.sourcePID > 0, !input.terminated,
                  (0...SelectionReader.sourceFocusMaxPolls).contains(input.remainingPolls),
                  input.frontmostPID == input.sourcePID,
                  input.focus == .unfocused || input.focus == .ownProcess else { continue }
            let decision = Self.decide(input)
            if input.remainingPolls > 0 {
                XCTAssertEqual(decision, .wait(remainingPolls: input.remainingPolls - 1), "\(input)")
            } else {
                XCTAssertEqual(decision, .read, "the wait is bounded, never a refusal: \(input)")
            }
        }
    }

    /// The fix, stated as a property over the whole space: an external element read on its own
    /// is focus arriving. It may only be captured once the *same* element answered twice, or
    /// once the budget is spent.
    func testExternalFocusOnlyReadsOnceSettledOrOutOfBudget() {
        for input in Self.allInputs() {
            guard input.sourcePID > 0, !input.terminated,
                  (0...SelectionReader.sourceFocusMaxPolls).contains(input.remainingPolls),
                  input.frontmostPID == input.sourcePID,
                  case .external(let element) = input.focus else { continue }
            let settled = input.previous == .external(element: element)
            let decision = Self.decide(input)
            if settled || input.remainingPolls == 0 {
                XCTAssertEqual(decision, .read, "\(input)")
            } else {
                XCTAssertEqual(decision, .wait(remainingPolls: input.remainingPolls - 1), "\(input)")
            }
        }
    }

    /// A caller that does not probe focus keeps the pre-wait contract exactly. This is the
    /// clause that stops `retryPaletteAISelectionAfterFocus` from silently inheriting a budget
    /// it never asked for.
    func testUnobservedFocusKeepsTheOriginalContract() {
        for input in Self.allInputs() {
            guard input.sourcePID > 0, !input.terminated,
                  (0...SelectionReader.sourceFocusMaxPolls).contains(input.remainingPolls),
                  input.frontmostPID == input.sourcePID,
                  input.focus == .notObserved else { continue }
            XCTAssertEqual(Self.decide(input), .read, "\(input)")
        }
    }

    /// Pure means pure: the same inputs answer the same way every time. A decision that
    /// consulted live state would make the refusal label disagree with the refusal.
    func testDecisionIsDeterministic() {
        for input in Self.allInputs() {
            XCTAssertEqual(Self.decide(input), Self.decide(input), "\(input)")
        }
    }

    // MARK: - Termination under an adversarial focus oracle

    /// Drive the loop the way `SourceAppDelivery` drives it, against an oracle that answers
    /// with whatever is worst at each step, and prove it always stops.
    ///
    /// Seeded so any failure reproduces. The adversary may flip frontmost, withhold focus
    /// forever, or republish a new element on every single poll — the shape that made the
    /// original bug — and none of it may produce an unbounded loop.
    func testAdversarialFocusSequencesAlwaysTerminate() {
        var rng = SplitMix64(seed: 0xF0C5)
        let multiplier = ProcessInfo.processInfo.environment["DEVTYPE_FOCUS_STRESS"]
            .flatMap(Int.init) ?? 1
        for _ in 0..<(2_000 * max(1, multiplier)) {
            var remaining = SelectionReader.sourceFocusMaxPolls
            var previous = SelectionReader.AXFocusObservation.notObserved
            var steps = 0
            var terminated: SelectionReader.SourceFocusRetryDecision?
            while terminated == nil {
                steps += 1
                XCTAssertLessThanOrEqual(
                    steps, SelectionReader.sourceFocusMaxPolls + 1,
                    "focus polling must have a finite budget"
                )
                guard steps <= SelectionReader.sourceFocusMaxPolls + 1 else { return }

                let frontmost: pid_t? = [nil, Self.ownPID, Self.sourcePID, Self.thirdPID]
                    .randomElement(using: &rng)!
                let focus: SelectionReader.AXFocusObservation = [
                    .notObserved, .unfocused, .ownProcess,
                    .external(element: UInt64.random(in: 0...3, using: &rng)),
                ].randomElement(using: &rng)!

                let decision = SelectionReader.sourceFocusRetryDecision(
                    sourcePID: Self.sourcePID,
                    frontmostPID: frontmost,
                    sourceTerminated: false,
                    remainingPolls: remaining,
                    axFocus: focus,
                    previousAXFocus: previous
                )
                switch decision {
                case .wait(let next):
                    XCTAssertLessThan(next, remaining, "a wait must consume budget")
                    remaining = next
                    previous = focus
                case .read, .fail:
                    terminated = decision
                }
            }
        }
    }

    /// Repeating one element forever must settle promptly rather than ride the budget out —
    /// the WebKit / helper-process case, where the element is stable but never owned by the
    /// source app. Burning 500 ms on every delivery there is what the pid-keyed wait did.
    func testStableExternalFocusSettlesWithinTwoPolls() {
        var remaining = SelectionReader.sourceFocusMaxPolls
        var previous = SelectionReader.AXFocusObservation.notObserved
        let focus = SelectionReader.AXFocusObservation.external(element: 0xABCD)
        var polls = 0
        while true {
            polls += 1
            let decision = SelectionReader.sourceFocusRetryDecision(
                sourcePID: Self.sourcePID,
                frontmostPID: Self.sourcePID,
                sourceTerminated: false,
                remainingPolls: remaining,
                axFocus: focus,
                previousAXFocus: previous
            )
            if case .wait(let next) = decision {
                remaining = next
                previous = focus
                XCTAssertLessThanOrEqual(polls, 2, "a stable element must not ride out the budget")
                continue
            }
            XCTAssertEqual(decision, .read)
            XCTAssertEqual(polls, 2, "one poll to observe, one to confirm")
            return
        }
    }

    // MARK: - Entry-gate target comparison

    /// `mismatch` is total and deterministic across the whole comparison space, and `matches`
    /// is exactly its absence — so a refusal can never be labelled with a condition other than
    /// the one that caused it.
    func testTargetComparisonIsTotalDeterministicAndAgreesWithMatches() {
        let mine = AXUIElementCreateApplication(getpid())
        let other = AXUIElementCreateApplication(1)
        let ranges: [NSRange?] = [nil, NSRange(location: 0, length: 0), NSRange(location: 3, length: 4)]
        let pids: [pid_t?] = [nil, 0, -1, getpid(), 1]
        let elements: [AXUIElement?] = [nil, mine, other]

        for capturedPID in pids {
            for capturedElement in elements {
                for capturedRange in ranges {
                    let target = PasteboardBroker.PasteTarget(
                        pid: capturedPID, element: capturedElement, range: capturedRange
                    )
                    for observedPID in pids {
                        for observedElement in elements {
                            for observedRange in ranges {
                                for checkRange in [true, false] {
                                    for checkElement in [true, false] {
                                        let first = target.mismatch(
                                            pid: observedPID, element: observedElement,
                                            range: observedRange, checkRange: checkRange,
                                            checkElement: checkElement
                                        )
                                        let second = target.mismatch(
                                            pid: observedPID, element: observedElement,
                                            range: observedRange, checkRange: checkRange,
                                            checkElement: checkElement
                                        )
                                        XCTAssertEqual(first, second, "mismatch must be deterministic")
                                        XCTAssertEqual(
                                            target.matches(
                                                pid: observedPID, element: observedElement,
                                                range: observedRange, checkRange: checkRange,
                                                checkElement: checkElement
                                            ),
                                            first == nil
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A target that was never pinned to a process can never match, whatever is observed.
    /// Fail-closed: an unpinned target is not evidence that the field is unchanged.
    func testUnpinnedTargetNeverMatches() {
        let element = AXUIElementCreateApplication(getpid())
        for capturedPID in [nil, 0, -1] as [pid_t?] {
            let target = PasteboardBroker.PasteTarget(pid: capturedPID, element: element, range: nil)
            for checkRange in [true, false] {
                for checkElement in [true, false] {
                    XCTAssertEqual(
                        target.mismatch(pid: capturedPID, element: element, range: nil,
                                        checkRange: checkRange, checkElement: checkElement),
                        .noCapturedProcess,
                        "captured pid \(String(describing: capturedPID))"
                    )
                }
            }
        }
    }

    /// Turning a check off must only ever *remove* a reason to refuse, never invent one. If
    /// `checkElement: false` could produce a mismatch that `checkElement: true` did not, the
    /// post-mutation paste guards would refuse more than the pre-mutation ones.
    func testDisablingACheckNeverIntroducesAMismatch() {
        let mine = AXUIElementCreateApplication(getpid())
        let other = AXUIElementCreateApplication(1)
        let ranges: [NSRange?] = [nil, NSRange(location: 1, length: 1), NSRange(location: 9, length: 0)]
        for capturedElement in [nil, mine, other] as [AXUIElement?] {
            for capturedRange in ranges {
                let target = PasteboardBroker.PasteTarget(
                    pid: getpid(), element: capturedElement, range: capturedRange
                )
                for observedElement in [nil, mine, other] as [AXUIElement?] {
                    for observedRange in ranges {
                        let strict = target.mismatch(
                            pid: getpid(), element: observedElement, range: observedRange,
                            checkRange: true, checkElement: true
                        )
                        let looseElement = target.mismatch(
                            pid: getpid(), element: observedElement, range: observedRange,
                            checkRange: true, checkElement: false
                        )
                        let looseRange = target.mismatch(
                            pid: getpid(), element: observedElement, range: observedRange,
                            checkRange: false, checkElement: true
                        )
                        if strict == nil {
                            XCTAssertNil(looseElement, "relaxing the element check invented a refusal")
                            XCTAssertNil(looseRange, "relaxing the range check invented a refusal")
                        }
                        if looseElement != nil {
                            XCTAssertNotNil(strict, "the strict check must refuse at least as often")
                        }
                        if looseRange != nil {
                            XCTAssertNotNil(strict, "the strict check must refuse at least as often")
                        }
                    }
                }
            }
        }
    }

    /// A mismatch is evidence for exactly one label, and is recorded against exactly that one.
    ///
    /// The gate reads the target before it knows which condition will win, so a supersession or
    /// a Secure Input block can easily coincide with a target that also moved. Recording the
    /// mismatch against those refusals would print `Refuse reason: superseded` beside
    /// `Target mismatch: elementChanged` and send the next reader after a focus bug that had
    /// nothing to do with the refusal — the exact misdirection this field exists to remove.
    func testOnlyATargetRefusalCarriesATargetMismatch() {
        let everyMismatch: [PasteboardBroker.PasteTarget.Mismatch?] = [
            nil, .noCapturedProcess, .processChanged, .focusLost, .focusArrived,
            .elementChanged, .rangeChanged,
        ]
        let everyRefusal: [TextInjectionPipeline.EntryGateRefusal] = [
            .superseded, .continuation, .secureInput, .accessibility, .targetChanged, .unreproduced,
        ]
        for refusal in everyRefusal {
            for mismatch in everyMismatch {
                let recorded = TextInjectionPipeline.recordedTargetMismatch(
                    refusal: refusal, mismatch: mismatch
                )
                if refusal == .targetChanged {
                    XCTAssertEqual(recorded, mismatch?.rawValue, "\(refusal) / \(String(describing: mismatch))")
                } else {
                    XCTAssertNil(recorded, "\(refusal) must not borrow the target's evidence")
                }
            }
        }
    }

    /// Every entry-gate condition maps to its own label, in gate order, across the whole space.
    /// Collapsing any two would put the next bug report back where this one started: one
    /// sentence covering an app switch, a moved caret, and focus that had not arrived.
    func testEntryGateRefusalLabelsArePreciseAcrossTheWholeSpace() {
        let blocks: [InjectCompletionGuard.ContinuationBlock?] =
            [nil, .cancelled, .timedOut, .alreadyCompleted, .callerStopped]
        var seen = Set<TextInjectionPipeline.EntryGateRefusal>()
        for revisionCurrent in [true, false] {
            for block in blocks {
                for secureInput in [true, false] {
                    for axUntrusted in [true, false] {
                        for targetCurrent in [true, false] {
                            let refusal = TextInjectionPipeline.entryGateRefusal(
                                revisionCurrent: revisionCurrent,
                                continuationBlock: block,
                                secureInputBlocked: secureInput,
                                axUntrusted: axUntrusted,
                                targetCurrent: targetCurrent
                            )
                            seen.insert(refusal)
                            let expected: TextInjectionPipeline.EntryGateRefusal
                            if !revisionCurrent {
                                expected = .superseded
                            } else if let block {
                                expected = block == .callerStopped ? .continuation : .superseded
                            } else if secureInput {
                                expected = .secureInput
                            } else if axUntrusted {
                                expected = .accessibility
                            } else if !targetCurrent {
                                expected = .targetChanged
                            } else {
                                expected = .unreproduced
                            }
                            XCTAssertEqual(refusal, expected)
                            XCTAssertFalse(refusal.reason.isEmpty)
                            XCTAssertTrue(refusal.path.hasPrefix("entryGate_"))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(
            seen.count, 6,
            "every entry-gate label must be reachable, or it is documentation rather than code"
        )
        XCTAssertEqual(
            Set(seen.map(\.reason)).count, 6,
            "two labels sharing a sentence is the failure this enum exists to prevent"
        )
    }
}
