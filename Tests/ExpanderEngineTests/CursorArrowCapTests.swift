import XCTest
@testable import ExpanderEngine

/// Caret placement falls back to posting one left-arrow key per grapheme wherever AX cannot set
/// the caret — Chrome, VS Code, every Electron host, which is the majority path. Nothing used to
/// bound that. A 400-character snippet with the cursor macro near the start posted 400 arrow
/// keys and waited `count × arrowPerKeyDelay` (~600 ms) before completing.
///
/// The latency was the smaller problem: four hundred arrow presses into an editor with vim mode,
/// an open autocomplete popup, or a multi-cursor selection do something other than move the
/// caret, and the user has no way to tell that is what happened.
final class CursorArrowCapTests: XCTestCase {

    func testOrdinaryCursorPlacementIsStillPosted() {
        XCTAssertTrue(InjectTiming.allowsCursorArrows(count: 1))
        XCTAssertTrue(InjectTiming.allowsCursorArrows(count: 40))
        XCTAssertTrue(
            InjectTiming.allowsCursorArrows(count: InjectTiming.maxCursorArrowKeys),
            "the cap itself must still be allowed"
        )
    }

    func testOversizedBurstsAreRefused() {
        XCTAssertFalse(InjectTiming.allowsCursorArrows(count: InjectTiming.maxCursorArrowKeys + 1))
        XCTAssertFalse(InjectTiming.allowsCursorArrows(count: 400))
        XCTAssertFalse(InjectTiming.allowsCursorArrows(count: 100_000))
    }

    func testNothingToMoveIsNotAPost() {
        XCTAssertFalse(InjectTiming.allowsCursorArrows(count: 0))
        XCTAssertFalse(InjectTiming.allowsCursorArrows(count: -5))
    }

    /// The cap has to be large enough for what `%|` is actually used for — a line or two of
    /// prose — and small enough that the resulting settle stays under a noticeable pause.
    func testCapIsUsefulAndBounded() {
        XCTAssertGreaterThanOrEqual(InjectTiming.maxCursorArrowKeys, 80)
        let worstCaseSettle = Double(InjectTiming.maxCursorArrowKeys) * InjectTiming.arrowPerKeyDelay
            + InjectTiming.arrowTrailingDelay
        XCTAssertLessThan(
            worstCaseSettle, 0.25,
            "an allowed caret move should still complete faster than the user can notice"
        )
    }

    /// The count itself is measured in graphemes, so the cap bounds *keypresses* — which is what
    /// the host actually receives — rather than code units.
    func testCapCountsGraphemesNotCodeUnits() {
        let text = String(repeating: "👍🏽", count: 200) + "tail"
        let arrows = HIDKeyPoster.leftArrowCount(
            text: text,
            utf16OffsetFromEnd: text.utf16.count - "x".utf16.count
        )
        XCTAssertLessThanOrEqual(arrows, text.count)
        XCTAssertFalse(
            InjectTiming.allowsCursorArrows(count: arrows),
            "200 astral clusters is exactly the burst this cap exists to refuse"
        )
    }
}

/// The keystroke path used to render the entire snippet — macros, nested `{{snippet:…}}`
/// lookups and all — inside the CGEventTap callback, purely to derive `needsCursorHID` and
/// `isMultiLine` for `InjectionPlanner.plan`. The planner discards both.
///
/// These pin that: the plan is a function of AX, Post and terminal-ness alone, so removing the
/// render cannot have changed which expansions are allowed.
final class InjectionPlanIgnoresRenderedShapeTests: XCTestCase {

    private func snapshot(canUseAX: Bool, canPostEvents: Bool) -> PermissionSnapshot {
        PermissionSnapshot(
            canListenTap: true,
            canUseAX: canUseAX,
            canPostEvents: canPostEvents
        )
    }

    private func allShapes(
        _ snapshot: PermissionSnapshot,
        isTerminal: Bool
    ) -> [InjectionPlan] {
        let planner = InjectionPlanner()
        return [
            planner.plan(snapshot: snapshot, isTerminal: isTerminal),
            planner.plan(snapshot: snapshot, isTerminal: isTerminal, needsCursorHID: true),
            planner.plan(snapshot: snapshot, isTerminal: isTerminal, needsCursorHID: false),
            planner.plan(snapshot: snapshot, isTerminal: isTerminal, needsCursorHID: true, isMultiLine: true),
            planner.plan(snapshot: snapshot, isTerminal: isTerminal, needsCursorHID: false, isMultiLine: true)
        ]
    }

    func testPlanIsIdenticalForEveryRenderedShape() {
        for canUseAX in [true, false] {
            for canPostEvents in [true, false] {
                for isTerminal in [true, false] {
                    let plans = allShapes(
                        snapshot(canUseAX: canUseAX, canPostEvents: canPostEvents),
                        isTerminal: isTerminal
                    )
                    let first = plans[0]
                    for plan in plans.dropFirst() {
                        XCTAssertEqual(
                            String(describing: plan), String(describing: first),
                            "AX=\(canUseAX) Post=\(canPostEvents) terminal=\(isTerminal): the "
                                + "rendered shape must not change the plan"
                        )
                    }
                }
            }
        }
    }

    /// And the decision the tap callback actually acts on — whether to swallow the trigger —
    /// follows the plan alone.
    func testSwallowDecisionFollowsThePlanAlone() {
        for canUseAX in [true, false] {
            for canPostEvents in [true, false] {
                for isTerminal in [true, false] {
                    let decisions = allShapes(
                        snapshot(canUseAX: canUseAX, canPostEvents: canPostEvents),
                        isTerminal: isTerminal
                    ).map { EventTapEngine.shouldSwallowTrigger(plan: $0) }
                    XCTAssertEqual(Set(decisions).count, 1, "swallow must not depend on the render")
                }
            }
        }
    }
}
