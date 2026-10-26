import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// §2.2: an expansion resolves the focused element once and threads it through.
///
/// The budget is documented on `TextInjectionPipeline.injectOnMain`: one resolution, plus live
/// re-checks that exist to catch the user moving (`PasteTarget.liveMismatch`,
/// `DeliveryVerifier.verifyFocusedTextDelivery`) and the erase guard's settle retry.
///
/// The budget is held two ways. Compositionally: `FocusQueryProbe` counts at the single choke point
/// every query passes through, and every collaborator the inject hands its element to is shown to
/// issue **zero** queries with it. And end to end: a whole inject runs through the pipeline's
/// `focusQuery:` seam on the shared `InjectionHarness`, which counts the actual queries and places
/// them in the ordered log relative to the confirm, the erase and the paste.
final class FocusThreadingTests: XCTestCase {

    private let element = AXUIElementCreateApplication(1234)

    private final class RecordingBackspaces: BackspacePosting {
        var posted = 0
        func sendBackspaces(count: Int) -> Int {
            posted += count
            return count
        }
        func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void) {
            posted += count
            completion(true)
        }
    }

    private func inertSettle() -> AXSettleRetry {
        AXSettleRetry(isMainThread: { true }, sleep: { _ in }, scheduleOnMain: { _, work in work() })
    }

    func testTheProbeCountsALiveQuery() {
        let queries = FocusQueryProbe.counting {
            _ = FocusedElementSource.live.element
        }
        XCTAssertEqual(queries, 1, "The seam must see the query it exists to count")
    }

    func testTheProbeIsOffOutsideACountingScope() {
        _ = FocusedElementSource.live.element
        XCTAssertEqual(FocusQueryProbe.counting {}, 0)
    }

    func testEveryCollaboratorHandedTheElementIssuesNoQuery() {
        let writer = AXTextWriter.shared
        let resolved = FocusedElementSource.resolved(element)
        let queries = FocusQueryProbe.counting {
            _ = writer.attemptAXCaretPosition(utf16OffsetFromEnd: 3, focus: resolved)
            _ = writer.performAXRangeReplace(text: "x", eraseCount: 1, bundleID: nil, focus: resolved)
            _ = writer.attemptAXDirectInjection(text: "x", bundleID: nil, focus: resolved)
            _ = DeliveryVerifier().captureFocusedTextObservation(focus: resolved)
            _ = PasteboardBroker.PasteTarget.capture(focus: resolved)
            _ = EraseExecutor(
                textAccess: .init(value: { _ in "abc" }, selectedRange: { _ in NSRange(location: 3, length: 0) },
                                  stringForRange: { _, _ in "c" }),
                settle: inertSettle()
            ).evaluateErasePrecondition(plan: ErasePlan(text: "c"), focus: resolved, retryOnMismatch: false)
            _ = AXContextChecker.shared.evaluateExpandGate(
                canUseAX: true, canPostEvents: true, focus: .available(element)
            )
        }
        XCTAssertEqual(queries, 0)
    }

    /// The HID-only path: the inject resolved focus and there was none. A collaborator that
    /// "helpfully" re-queried would act on an element no gate approved.
    func testAResolvedAbsenceIsNotReplacedByAFreshQuery() {
        let none = FocusedElementSource.resolved(nil)
        let queries = FocusQueryProbe.counting {
            XCTAssertFalse(AXTextWriter.shared.attemptAXCaretPosition(utf16OffsetFromEnd: 3, focus: none))
            XCTAssertEqual(
                AXTextWriter.shared.performAXRangeReplace(text: "x", eraseCount: 1, bundleID: nil, focus: none),
                .notAttempted("no focused element")
            )
            XCTAssertFalse(AXTextWriter.shared.attemptAXDirectInjection(text: "x", focus: none))
            XCTAssertNil(DeliveryVerifier().captureFocusedTextObservation(focus: none))
            XCTAssertNil(PasteboardBroker.PasteTarget.capture(focus: none).element)
            XCTAssertFalse(AXContextChecker.shared.focusedElementLooksLikeTerminal(focus: none))
        }
        XCTAssertEqual(queries, 0)
    }

    /// The two collaborators that used to query behind the threaded element through a default
    /// argument: the IDE shell-like probe at the top of `performInject`, and the clipboard paste's
    /// target capture when it has no baseline (secure paste, trigger restore).
    func testTheShellProbeAndTheClipboardCaptureUseTheHandedElement() {
        var result: PasteboardBroker.PasteDeliveryResult?
        let queries = FocusQueryProbe.counting {
            _ = AXContextChecker.shared.isFrontmostShellLikeContext(focus: .resolved(element))
            _ = AXContextChecker.shared.isFrontmostShellLikeContext(focus: .resolved(nil))
            // `shouldContinue: false` stops it right after the capture, before any live re-check
            // or pasteboard write.
            PasteboardBroker.shared.pasteViaClipboard(
                text: "x", expectedText: nil, baseline: nil, focus: .resolved(nil),
                shouldContinue: { false }
            ) { result = $0 }
        }
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(result, .notPosted)
    }

    func testTheGuardedEraseUsesTheThreadedElement() {
        let backspaces = RecordingBackspaces()
        let executor = EraseExecutor(
            hid: backspaces,
            textAccess: .init(value: { _ in nil }, selectedRange: { _ in nil }, stringForRange: { _, _ in nil }),
            settle: inertSettle()
        )
        var erased: Bool?
        let queries = FocusQueryProbe.counting {
            executor.performGuardedErase(plan: ErasePlan(text: "ab"), focus: .resolved(nil)) { erased = $0 }
        }
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(erased, true, "An unreadable field degrades to a best-effort HID erase")
        XCTAssertEqual(backspaces.posted, 2)
    }

    // MARK: - The pipeline resolves once

    /// A confirmer whose first reading of the field is blank (the host publishing the selection a
    /// moment late), so the confirm waits a settle. Every read it makes lands in the harness's
    /// ordered log, which is what places the focus queries relative to the confirm.
    private func makeReplaceHarness(readsBlankOnce: Bool, original: String) throws -> InjectionHarness {
        final class Link { var harness: InjectionHarness? }
        let link = Link()
        var reads = 0
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { _ in
                link.harness?.note(.selectionRead)
                reads += 1
                return readsBlankOnce && reads == 1
                    ? .init(value: nil, selectedText: nil)
                    : .init(value: nil, selectedText: original)
            },
            select: { _, _ in false },
            schedule: { _, action in action() },
            role: { _ in "AXTextArea" }
        )
        let harness = try InjectionHarness(selectionConfirmer: SelectionReplacementGuard.Confirmer(access: access))
        link.harness = harness
        return harness
    }

    private func firstIndex(of event: InjectionHarness.Event, in order: [InjectionHarness.Event]) -> Int? {
        order.firstIndex(of: event)
    }

    /// A typed expansion resolves focus once, and does it before anything is erased: every gate,
    /// the precondition, the erase and the paste are handed that element, none re-queries.
    func testATypedExpansionResolvesFocusOnceAndBeforeItErasesAnything() throws {
        let harness = try InjectionHarness()
        let run = harness.typeExpansion(in: self)

        XCTAssertNotNil(run.outcome)
        XCTAssertEqual(run.text, "say: Sincerely, Slim", "the run reached the paste, so the budget covers all of it")
        XCTAssertEqual(harness.focusQueries, 1, "\(harness.order)")
        XCTAssertEqual(harness.order.first, .focusQuery, "focus is resolved before the first backspace")
        XCTAssertLessThan(
            try XCTUnwrap(firstIndex(of: .focusQuery, in: harness.order)),
            try XCTUnwrap(firstIndex(of: .backspace, in: harness.order))
        )
    }

    /// A replace whose selection is read correctly the first time has nothing to cover: it keeps
    /// the focus it resolved and queries once.
    func testAReplaceThatConfirmedAtOnceResolvesFocusOnce() throws {
        let original = "teh quick brown fox"
        let harness = try makeReplaceHarness(readsBlankOnce: false, original: original)
        harness.seed("say: \(original) now", caret: 5, selection: (original as NSString).length)
        let outcome = harness.injectReplace(in: self, original: original, result: "the quick brown fox")

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(harness.focusQueries, 1, "\(harness.order)")
        XCTAssertLessThan(
            try XCTUnwrap(firstIndex(of: .selectionRead, in: harness.order)),
            try XCTUnwrap(harness.order.firstIndex { if case .paste = $0 { true } else { false } }),
            "the selection is confirmed before ⌘V can go out"
        )
    }

    /// A confirm that waited resolves focus again — the focus it was handed predates the wait —
    /// and does it after the confirm's own reads and before ⌘V, so the entry gate judges where
    /// focus is now. That is the documented second query; there is no third.
    func testAReplaceThatWaitedResolvesFocusAgainAfterTheConfirmAndBeforeThePaste() throws {
        let original = "teh quick brown fox"
        let harness = try makeReplaceHarness(readsBlankOnce: true, original: original)
        harness.seed("say: \(original) now", caret: 5, selection: (original as NSString).length)
        let outcome = harness.injectReplace(in: self, original: original, result: "the quick brown fox")

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(harness.focusQueries, 2, "\(harness.order)")
        let order = harness.order
        let queries = order.indices.filter { order[$0] == .focusQuery }
        let lastRead = try XCTUnwrap(order.lastIndex(of: .selectionRead))
        let paste = try XCTUnwrap(order.firstIndex { if case .paste = $0 { true } else { false } })
        XCTAssertLessThan(queries[0], order.firstIndex(of: .selectionRead)!, "the inject's own query comes first")
        XCTAssertGreaterThan(queries[1], lastRead, "the re-read follows the confirm that waited")
        XCTAssertLessThan(queries[1], paste, "and precedes the paste")
    }
}
