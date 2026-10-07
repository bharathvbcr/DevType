import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// §2.2: an expansion resolves the focused element once and threads it through.
///
/// The budget is documented on `TextInjectionPipeline.injectOnMain`: one resolution, plus live
/// re-checks that exist to catch the user moving (`PasteTarget.liveMismatch`,
/// `DeliveryVerifier.verifyFocusedTextDelivery`) and the erase guard's settle retry.
///
/// No test here drives a whole inject — that needs AX trust and a live host. The budget is held
/// compositionally instead: `FocusQueryProbe` counts at the single choke point every query passes
/// through, every collaborator the inject hands its element to is shown to issue **zero** queries
/// with it, and the pipeline source is shown to resolve focus in exactly one place.
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

    private func pipelineSource() throws -> String {
        SourceContractTests.strippingComments(try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift"),
            encoding: .utf8
        ))
    }

    func testTheInjectResolvesFocusInExactlyOnePlace() throws {
        let source = try pipelineSource()
        let start = try XCTUnwrap(source.range(of: "private func injectOnMain("))
        let end = try XCTUnwrap(source.range(of: "private func finishAbandonedPaste("))
        let inject = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertEqual(inject.components(separatedBy: "queryFocusedElement").count - 1, 1,
                       "One resolution per inject — the entry re-check's answer is the threaded element")
        for untracked in [
            "focusedElement()", "focusedElementRole()", "captureFocusedTextObservation()",
            "isFrontmostShellLikeContext()", "PasteTarget.capture()"
        ] {
            XCTAssertFalse(inject.contains(untracked), "\(untracked) re-resolves focus behind the threaded element")
        }
        XCTAssertFalse(inject.contains("focus: .live"), "A collaborator inside the inject must be handed the element")
    }
}
