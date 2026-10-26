import ApplicationServices
import XCTest
@testable import ExpanderEngine

// MARK: - Two ways a confirmed replace could still paste into the wrong place
//
// 1. The confirm's settle writes `AXFocused` to put focus back on the captured element whenever
//    focus resolves to a window. A user who clicked the toolbar or the tab bar during that wait
//    moved focus on purpose, and the write undid it — the paste then landed in a field they had
//    left. Input since the operation began now stops the settle before it touches the host.
// 2. WebKit swaps the focused text node when a selection changes: same control, new element. A
//    confirm that waited compared the live focus with the old element by identity and refused
//    `.focusMoved`, sending a result the paste would have landed to the clipboard instead.
final class ReplaceFocusIntegrityTests: XCTestCase {
    private let original = "teh quick brown fox"
    private let result = "the quick brown fox"

    private let window = AXUIElementCreateApplication(6001)
    private let field = AXUIElementCreateApplication(6002)

    // MARK: Input during the settle

    private final class Host {
        var focused: AXUIElement
        var focusWrites: [AXUIElement] = []
        let window: AXUIElement
        let field: AXUIElement
        init(window: AXUIElement, field: AXUIElement) {
            self.window = window
            self.field = field
            focused = window
        }

        var access: SelectionReplacementGuard.Confirmer.Access {
            SelectionReplacementGuard.Confirmer.Access(
                observe: { [unowned self] candidate in
                    CFEqual(candidate, self.field)
                        ? .init(value: nil, selectedText: "teh quick brown fox")
                        : .init(value: nil, selectedText: nil)
                },
                select: { _, _ in false },
                schedule: { _, action in action() },
                refocus: { [unowned self] in self.focused },
                role: { [unowned self] in CFEqual($0, self.field) ? "AXTextArea" : "AXWindow" },
                focus: { [unowned self] element in
                    self.focusWrites.append(element)
                    self.focused = element
                    return true
                }
            )
        }
    }

    func testTheSettleNeverWritesFocusOnceTheUserHasActed() {
        let host = Host(window: window, field: field)
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: host.access).confirm(
            SelectionReplacement(original: original, capturedElement: field)!,
            element: window,
            isCurrent: { false }
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .refused(.focusMoved))
        XCTAssertTrue(host.focusWrites.isEmpty, "a click on window chrome is not a host still restoring focus")
    }

    func testTheSettleStillRestoresFocusWhenNothingHappened() {
        let host = Host(window: window, field: field)
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: host.access).confirm(
            SelectionReplacement(original: original, capturedElement: field)!,
            element: window,
            isCurrent: { true }
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false, refocusedOn: field))
        XCTAssertEqual(host.focusWrites.count, 1)
    }

    /// Input that arrives *during* the wait, not before it: the first tick passes, the next does
    /// not, so the write that would have followed never happens.
    func testInputBetweenTwoTicksStopsTheNextWrite() {
        let host = Host(window: window, field: field)
        host.focused = window
        var ticks = 0
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        var access = host.access
        // The host ignores the first focus request, so a second tick is needed.
        var honours = false
        access.focus = { element in
            host.focusWrites.append(element)
            if honours { host.focused = element }
            honours = true
            return true
        }
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original, capturedElement: field)!,
            element: window,
            isCurrent: { ticks += 1; return ticks == 1 }
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .refused(.focusMoved))
        XCTAssertEqual(host.focusWrites.count, 1, "one write before the user acted, none after")
    }

    // MARK: A node swapped while the confirm waited

    private struct Outcome {
        var outcome: PermissionCoordinator.InjectOutcome?
        var kept: [String]
        var confirmedOn: [String]
        var queries: Int
        var finalText: String?
    }

    /// Replace in the harness's field; the confirm has to wait one settle, and by the time it is
    /// done the host's focus is `live`. `frameOfLive` decides whether that node is the same control.
    /// The page holds the original in both the field and the replacement node, so a paste that
    /// follows the swap lands in the node it was sent to.
    private func replaceThenSwap(
        _ harness: InjectionHarness, to live: AXUIElement, frameOfLive: CGRect, confirmedOn: Reads
    ) -> Outcome {
        let text = "say: \(original) now"
        let selection = NSRange(location: 5, length: (original as NSString).length)
        let controlFrame = CGRect(x: 10, y: 20, width: 500, height: 200)
        harness.page.frames[harness.page.key(harness.field)] = controlFrame
        harness.page.frames[harness.page.key(harness.replacementNode)] = frameOfLive
        harness.page.frames[harness.page.key(harness.elsewhere)] = frameOfLive
        for element in [harness.field, harness.replacementNode] {
            harness.page.values[harness.page.key(element)] = text
            harness.page.selections[harness.page.key(element)] = selection
        }
        harness.page.focused = harness.field
        harness.focusAnswer = { index in
            // The first query is the inject's own; every later one is after the confirm waited.
            if index > 1 { harness.page.focused = live }
            return .available(index == 1 ? harness.field : live)
        }

        let outcome = harness.injectReplace(in: self, original: original, result: result)
        return Outcome(
            outcome: outcome, kept: harness.kept, confirmedOn: confirmedOn.elements,
            queries: harness.focusQueries, finalText: harness.page.value(of: live)
        )
    }

    /// What the scripted confirmer saw: every element it read the selection from, and the field it blanks once.
    final class Reads {
        var elements: [String] = []
        var field: AXUIElement?
    }

    /// A confirmer that blanks the field once — the host publishing the selection a moment late —
    /// so the confirm waits a settle and the live re-check runs; every other read answers the
    /// original. `confirmedOn` records every element the selection was read from.
    private func makeHarness(confirmedOn: Reads) throws -> InjectionHarness {
        var observedField = 0
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { [original] candidate in
                confirmedOn.elements.append(String(describing: candidate))
                if let first = confirmedOn.field, CFEqual(candidate, first) {
                    observedField += 1
                    return observedField == 1
                        ? .init(value: nil, selectedText: nil)
                        : .init(value: nil, selectedText: original)
                }
                return .init(value: nil, selectedText: original)
            },
            select: { _, _ in false },
            schedule: { _, action in action() },
            role: { _ in "AXTextArea" }
        )
        let harness = try InjectionHarness(selectionConfirmer: SelectionReplacementGuard.Confirmer(access: access))
        confirmedOn.field = harness.field
        return harness
    }

    /// The proceed branch. The harness's host really pastes where focus is, so the assertions are
    /// about what the gate decided and what the field holds afterwards: the node swap is not
    /// refused as a move, the result is not diverted to the clipboard, the selection was
    /// confirmed again on the new node, and the result is in the node the paste was sent to.
    func testASwappedNodeOfTheSameControlIsConfirmedAgainNotRefused() throws {
        let confirmedOn = Reads()
        let harness = try makeHarness(confirmedOn: confirmedOn)
        let run = replaceThenSwap(
            harness, to: harness.replacementNode,
            frameOfLive: CGRect(x: 10, y: 20, width: 500, height: 200), confirmedOn: confirmedOn
        )
        XCTAssertGreaterThanOrEqual(run.queries, 2, "the confirm waited, so focus was resolved again")
        XCTAssertEqual(run.outcome, .succeeded)
        XCTAssertEqual(run.kept, [])
        XCTAssertTrue(
            run.confirmedOn.contains(String(describing: harness.replacementNode)),
            "vouching proves the control, not the selection in it: the replace is confirmed on the new node"
        )
        XCTAssertEqual(run.finalText, "say: \(result) now", "the result replaced the selection in the node swapped in")
    }

    func testAnotherFieldIsStillAMoveAndKeepsTheResult() throws {
        let confirmedOn = Reads()
        let harness = try makeHarness(confirmedOn: confirmedOn)
        let run = replaceThenSwap(
            harness, to: harness.elsewhere,
            frameOfLive: CGRect(x: 10, y: 400, width: 500, height: 200), confirmedOn: confirmedOn
        )
        XCTAssertGreaterThanOrEqual(run.queries, 2)
        XCTAssertEqual(run.outcome, .refused(SelectionReplacementGuard.Refusal.focusMoved.reason))
        XCTAssertEqual(run.kept, [result])
        XCTAssertFalse(run.confirmedOn.contains(String(describing: harness.elsewhere)))
        XCTAssertEqual(harness.chords, 0, "nothing was pasted into a field the user had left")
    }
}
