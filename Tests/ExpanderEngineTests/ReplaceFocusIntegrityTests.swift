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

    private let replacementNode = AXUIElementCreateApplication(6003)
    private let elsewhere = AXUIElementCreateApplication(6004)

    private final class Page {
        var frames: [String: CGRect] = [:]
        var roles: [String: String] = [:]
        var pids: [String: pid_t] = [:]
        var attributes: [String: ControlIdentity.Attributes] = [:]
        func key(_ element: AXUIElement) -> String { String(describing: element) }
        func access() -> DeliveryVerifier.TextAccess {
            .init(
                focusedElement: { nil },
                numberOfCharacters: { _ in nil },
                selectedRange: { _ in nil },
                stringForRange: { _, _ in nil },
                observation: { .init(value: nil, selectedText: nil, target: $0) },
                frame: { [unowned self] in self.frames[self.key($0)] },
                role: { [unowned self] in self.roles[self.key($0)] },
                pid: { [unowned self] in self.pids[self.key($0)] },
                attributes: { [unowned self] in self.attributes[self.key($0)] ?? .none }
            )
        }
    }

    private struct Outcome {
        var outcome: PermissionCoordinator.InjectOutcome?
        var kept: [String]
        var confirmedOn: [String]
        var queries: Int
    }

    /// Replace in `field`; the confirm has to wait one settle, and by the time it is done the
    /// host's focus is `liveAfterWait`. `frameOfLive` decides whether that node is the same control.
    private func replaceThenSwap(
        to live: AXUIElement, frameOfLive: CGRect,
        attributesOfField: ControlIdentity.Attributes = .none,
        attributesOfLive: ControlIdentity.Attributes = .none
    ) throws -> Outcome {
        let page = Page()
        page.attributes[page.key(field)] = attributesOfField
        page.attributes[page.key(live)] = attributesOfLive
        let controlFrame = CGRect(x: 10, y: 20, width: 500, height: 200)
        for element in [field, replacementNode, elsewhere] {
            page.roles[page.key(element)] = "AXTextArea"
            page.pids[page.key(element)] = 321
        }
        page.frames[page.key(field)] = controlFrame
        page.frames[page.key(replacementNode)] = frameOfLive
        page.frames[page.key(elsewhere)] = frameOfLive

        var observedField = 0
        var confirmedOn: [String] = []
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { [unowned self] candidate in
                confirmedOn.append(page.key(candidate))
                if CFEqual(candidate, self.field) {
                    // Blank once — the host publishing the selection a moment late — so the
                    // confirm waits a settle and the live re-check runs.
                    observedField += 1
                    return observedField == 1
                        ? .init(value: nil, selectedText: nil)
                        : .init(value: nil, selectedText: self.original)
                }
                return .init(value: nil, selectedText: self.original)
            },
            select: { _, _ in false },
            schedule: { _, action in action() },
            role: { _ in "AXTextArea" }
        )

        let suite = "ReplaceFocusIntegrityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var kept: [String] = []
        var queries = 0
        let pipeline = TextInjectionPipeline(
            defaults: defaults,
            selectionConfirmer: SelectionReplacementGuard.Confirmer(access: access),
            keepRefusedReplacement: { kept.append($0); return true },
            focusQuery: { completion in
                queries += 1
                completion(queries == 1 ? .available(self.field) : .available(live))
            },
            verifier: DeliveryVerifier(access: page.access())
        )

        var outcome: PermissionCoordinator.InjectOutcome?
        let done = expectation(description: "inject completed")
        pipeline.inject(
            snippet: SnippetModel(title: "AI", triggerKeyword: "", replacementText: result),
            triggerLength: 0,
            swallowed: .notSwallowed,
            erasePlan: .empty,
            preResolvedText: result,
            secureClipboardPaste: true,
            targetFocus: .resolved(field),
            replacingSelection: SelectionReplacement(original: original)
        ) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        if queries < 2 {
            throw XCTSkip("entry gate refused before the confirm ran: \(String(describing: outcome))")
        }
        return Outcome(outcome: outcome, kept: kept, confirmedOn: confirmedOn, queries: queries)
    }

    /// The proceed branch. Where the paste itself goes after that depends on this machine's
    /// permissions, so the assertions are about what this change decides: the node swap is not
    /// refused as a move, the result is not diverted to the clipboard, and the selection was
    /// confirmed again on the new node.
    func testASwappedNodeOfTheSameControlIsConfirmedAgainNotRefused() throws {
        let run = try replaceThenSwap(to: replacementNode, frameOfLive: CGRect(x: 10, y: 20, width: 500, height: 200))
        XCTAssertNotEqual(run.outcome, .refused(SelectionReplacementGuard.Refusal.focusMoved.reason))
        XCTAssertEqual(run.kept, [])
        XCTAssertTrue(
            run.confirmedOn.contains(String(describing: replacementNode)),
            "vouching proves the control, not the selection in it: the replace is confirmed on the new node"
        )
    }

    /// A single-page app re-renders another control at the very same frame while the confirm waits.
    /// Frame, role and process all agree; the DOM identifier is the only thing that does not.
    func testAnotherControlAtTheSameFrameIsAMoveAndKeepsTheResult() throws {
        let run = try replaceThenSwap(
            to: replacementNode, frameOfLive: CGRect(x: 10, y: 20, width: 500, height: 200),
            attributesOfField: .init(domIdentifier: "search"),
            attributesOfLive: .init(domIdentifier: "inline-editor")
        )
        XCTAssertEqual(run.outcome, .refused(SelectionReplacementGuard.Refusal.focusMoved.reason))
        XCTAssertEqual(run.kept, [result], "the generated result is kept for a manual paste")
        XCTAssertFalse(run.confirmedOn.contains(String(describing: replacementNode)))
    }

    func testTheSameDOMIdentifierOnTheSwappedNodeIsConfirmedAgainNotRefused() throws {
        let run = try replaceThenSwap(
            to: replacementNode, frameOfLive: CGRect(x: 10, y: 20, width: 500, height: 200),
            attributesOfField: .init(domIdentifier: "search"),
            attributesOfLive: .init(domIdentifier: "search")
        )
        XCTAssertNotEqual(run.outcome, .refused(SelectionReplacementGuard.Refusal.focusMoved.reason))
        XCTAssertEqual(run.kept, [])
        XCTAssertTrue(run.confirmedOn.contains(String(describing: replacementNode)))
    }

    func testAnotherFieldIsStillAMoveAndKeepsTheResult() throws {
        let run = try replaceThenSwap(to: elsewhere, frameOfLive: CGRect(x: 10, y: 400, width: 500, height: 200))
        XCTAssertEqual(run.outcome, .refused(SelectionReplacementGuard.Refusal.focusMoved.reason))
        XCTAssertEqual(run.kept, [result])
        XCTAssertFalse(run.confirmedOn.contains(String(describing: elsewhere)))
    }
}
