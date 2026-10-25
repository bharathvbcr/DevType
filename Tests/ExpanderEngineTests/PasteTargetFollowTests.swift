import AppKit
import CoreGraphics
import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

/// WebKit replaces the focused text node under a typed expansion. The erase continuation and the
/// delivery verifier already accept a replacement the pipeline vouches for; the paste used to pin its
/// target by element identity with no way to follow, so a swap between the post-erase check and ⌘V
/// refused the paste with the trigger already gone — no trigger and no expansion.
///
/// These run the real `pasteViaClipboard` → ⌘V sequence on a named pasteboard. Which target is "the
/// focused control" is the stubbed `targetCurrent`; a target is told apart by its selected range.
final class PasteTargetFollowTests: XCTestCase {
    private struct NoLayout: KeyboardLayoutProviding {
        func currentSourceID() -> String? { nil }
        func keyCode(for character: Character) -> CGKeyCode? { nil }
    }

    private static let stale = NSRange(location: 1, length: 0)
    private static let replacement = PasteboardBroker.PasteTarget(
        pid: 1, element: nil, range: NSRange(location: 7, length: 0)
    )

    private final class Harness {
        let board = NSPasteboard.withUniqueName()
        let broker: PasteboardBroker
        final class Counter { var events = 0; var checks = 0 }
        let counter = Counter()

        /// `focused` answers which range is the live focus at the n-th target check (1-based), so a
        /// swap is scripted at an exact point in the sequence.
        init(focused: @escaping (_ check: Int) -> Int) {
            let board = board
            let counter = counter
            let hid = HIDKeyPoster(
                commandEventIO: .init(canPost: { true }, post: { _ in counter.events += 1 }, pause: {}),
                layout: KeyboardLayoutState(provider: NoLayout())
            )
            var environment = PasteboardBroker.Environment()
            environment.pasteboard = { board }
            environment.canPostEvents = { true }
            environment.secureInputActive = { false }
            environment.targetCurrent = { target, _, _ in
                counter.checks += 1
                return target.range?.location == focused(counter.checks)
            }
            broker = PasteboardBroker(
                hid: hid, verifier: DeliveryVerifier.shared, timing: InjectTimingStore(), environment: environment
            )
        }

        deinit { board.releaseGlobally() }

        func paste(
            in test: XCTestCase,
            follow: (() -> PasteboardBroker.PasteTarget?)?
        ) -> PasteboardBroker.PasteDeliveryResult {
            board.clearContents()
            board.setString("USER-OLD", forType: .string)
            let done = test.expectation(description: "paste finished")
            var outcome: PasteboardBroker.PasteDeliveryResult = .failed
            // `capture` takes its range from the baseline, which is how the captured target is
            // told apart from the replacement.
            let baseline = DeliveryVerifier.FocusedTextObservation(
                value: nil, selectedText: nil, selectedRange: PasteTargetFollowTests.stale
            )
            broker.pasteViaClipboard(
                text: "SNIPPET", expectedText: nil, baseline: baseline, focus: .resolved(nil),
                completeBeforeRestore: true, followVouchedReplacement: follow
            ) {
                outcome = $0
                done.fulfill()
            }
            test.wait(for: [done], timeout: 5)
            return outcome
        }
    }

    // MARK: - Fail closed

    /// Nothing vouches for a different node: the paste is refused, as before.
    func testASwapNobodyVouchesForRefusesThePaste() {
        let harness = Harness(focused: { _ in 7 })
        XCTAssertEqual(harness.paste(in: self, follow: nil), .notPosted)
        XCTAssertEqual(harness.counter.events, 0, "no ⌘V may be posted into an unvouched node")
    }

    func testAReplacementTheCallerOffersButTheScreenDoesNotShowRefusesThePaste() {
        let harness = Harness(focused: { _ in 99 })
        XCTAssertEqual(
            harness.paste(in: self, follow: { Self.replacement }), .notPosted,
            "an offered target is verified against the live focus, never taken on trust"
        )
        XCTAssertEqual(harness.counter.events, 0)
    }

    func testACallerThatVouchesForNothingRefusesThePaste() {
        let harness = Harness(focused: { _ in 7 })
        XCTAssertEqual(harness.paste(in: self, follow: { nil }), .notPosted)
        XCTAssertEqual(harness.counter.events, 0)
    }

    // MARK: - Follow

    /// The node was already swapped when the paste began.
    func testAVouchedReplacementThatIsFocusedIsFollowedBeforePublication() {
        let harness = Harness(focused: { _ in 7 })
        XCTAssertEqual(harness.paste(in: self, follow: { Self.replacement }), .unavailable)
        XCTAssertEqual(harness.counter.events, 4, "the whole ⌘V chord went to the replacement")
    }

    /// The node is swapped after the payload is published and before ⌘V — the window the pre-paste
    /// settle opens. The first check (before publication) passes on the captured node; every later
    /// one finds it gone and the replacement focused.
    func testASwapBetweenPublicationAndCmdVIsFollowedWhenVouched() {
        let harness = Harness(focused: { check in check == 1 ? 1 : 7 })
        XCTAssertEqual(harness.paste(in: self, follow: { Self.replacement }), .unavailable)
        XCTAssertEqual(harness.counter.events, 4)
    }

    func testTheSameSwapWithNobodyVouchingLosesTheExpansionAndRestoresTheClipboard() {
        let harness = Harness(focused: { check in check == 1 ? 1 : 7 })
        XCTAssertEqual(harness.paste(in: self, follow: nil), .notPosted)
        XCTAssertEqual(harness.counter.events, 0)
        XCTAssertEqual(harness.board.string(forType: .string), "USER-OLD")
    }

    // MARK: - Wiring (the pipeline has no AX seam to run it against; these pin who owns the vouching)

    /// One owner for "is this the same control": the paste, the post-erase continue-check and the
    /// restore all ask `adoptVouchedContinuation`, which is `EraseContinuation`'s policy — none of
    /// them has a vouching rule of its own.
    func testThePasteTheContinueCheckAndTheRestoreAllFollowTheEraseContinuationsVouching() throws {
        let pipeline = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        )
        let follows = try SourceTree.functionBody("private func followsVouchedReplacement(", in: pipeline)
        XCTAssertTrue(follows.contains("adoptVouchedContinuation("))
        XCTAssertTrue(follows.contains("continuation: .beforeInsertion"))
        let vouched = try SourceTree.functionBody("private func vouchedPasteTarget(", in: pipeline)
        XCTAssertTrue(vouched.contains("followsVouchedReplacement(context)"))

        let perform = try SourceTree.functionBody("private func performInject(", in: pipeline)
        XCTAssertTrue(
            perform.contains("let canProceedAfterMutation = {\n            self.followsVouchedReplacement(context)"),
            "the post-erase continue-check must follow a vouched replacement, not re-pin identity"
        )
        XCTAssertTrue(
            perform.contains("followVouchedReplacement: { self.vouchedPasteTarget(context) }"),
            "the typed paste must be offered the replacement the continuation vouches for"
        )

        let finish = try SourceTree.functionBody("private func finishPasteDelivery(", in: pipeline)
        XCTAssertTrue(finish.contains("followsVouchedReplacement(context)"))
        XCTAssertTrue(
            finish.contains("followVouchedReplacement: { self.vouchedPasteTarget(context) }"),
            "the restore follows the same replacement the paste would have"
        )
        let guardAt = try XCTUnwrap(finish.range(of: "guard stillOurs()"))
        let focusAt = try XCTUnwrap(finish.range(of: "let focus = FocusedElementSource.resolved(context.focusedElement)"))
        XCTAssertLessThan(guardAt.lowerBound, focusAt.lowerBound, "the element is read after the guard may have re-pointed it")
    }

    func testAnUnswappedTargetNeverAsksTheCallerToVouch() {
        var asked = 0
        let harness = Harness(focused: { _ in 1 })
        XCTAssertEqual(
            harness.paste(in: self, follow: { asked += 1; return Self.replacement }), .unavailable
        )
        XCTAssertEqual(asked, 0, "a vouching read costs AX queries; it runs only on a mismatch")
    }
}
