import XCTest
@testable import ExpanderEngine

/// Accessibility misses cannot prove that an asynchronous paste will never arrive.
/// The old confirmation-count and timeout expectations intentionally change: repeated
/// observations and historical host trust must not authorize automatic replay.
final class PasteRetryConfirmationTests: XCTestCase {

    private func decide(
        _ delivery: DeliveryVerifier.TextDeliveryVerification,
        attempts: Int = 1,
        elapsed: TimeInterval = 0.05,
        failures: Int
    ) -> PasteboardBroker.PasteHoldDecision {
        PasteboardBroker.decidePasteHold(
            delivery: delivery,
            pasteAttemptsCompleted: attempts,
            elapsed: elapsed,
            consecutiveFailures: failures
        )
    }

    // MARK: - The regression

    /// The exact shape of the double-paste bug: one stale read must not re-paste.
    func testSingleFailedObservationDoesNotRetry() {
        XCTAssertEqual(
            decide(.failed, failures: 1),
            .waitMore,
            "One `.failed` may be a stale AX read; re-reading is cheap, re-pasting duplicates text."
        )
    }

    /// Repeated readable misses still cannot exclude a pending paste.
    func testRepeatedFailuresStillWaitForEvidence() {
        XCTAssertEqual(
            decide(.failed, failures: PasteboardBroker.requiredFailureConfirmations),
            .waitMore
        )
    }

    func testAttemptCountCannotManufactureFailureProof() {
        XCTAssertEqual(
            decide(.failed, attempts: InjectTiming.pasteDeliveryMaxAttempts, failures: 2),
            .waitMore,
            "Attempt counts do not establish current-operation non-application."
        )
    }

    /// Waiting is bounded: an unconfirmed failure past the hold timeout must not wait forever.
    func testUnconfirmedFailurePastTimeoutStopsUnverified() {
        let decision = decide(
            .failed,
            elapsed: InjectTiming.pasteDeliveryHoldTimeout + 1,
            failures: 1
        )
        XCTAssertNotEqual(decision, .waitMore, "The confirmation wait must be time-bounded.")
        XCTAssertEqual(decision, .giveUpUnverified)
    }

    // MARK: - Unchanged behaviour

    func testDeliveredSucceedsRegardlessOfPriorFailures() {
        // A stale read followed by a good one is the expected happy path on slow hosts.
        XCTAssertEqual(decide(.delivered, failures: 1), .succeed)
        XCTAssertEqual(decide(.delivered, failures: 5), .succeed)
    }

    func testUnavailableWaitsThenGivesUpUnverified() {
        XCTAssertEqual(decide(.unavailable, elapsed: 0.01, failures: 0), .waitMore)
        XCTAssertEqual(
            decide(.unavailable, elapsed: InjectTiming.pasteDeliveryHoldTimeout + 1, failures: 0),
            .giveUpUnverified,
            "Unverifiable is not failure — it must never re-paste."
        )
    }

    /// `.unavailable` must never reach a retry at any failure count: an unreadable field is not
    /// evidence the paste missed, and re-pasting there is how weak-AX apps get duplicates.
    func testUnavailableNeverRetriesAtAnyFailureCount() {
        for failures in 0...5 {
            for elapsed: TimeInterval in [0.0, 0.5, InjectTiming.pasteDeliveryHoldTimeout + 1] {
                XCTAssertNotEqual(
                    decide(.unavailable, elapsed: elapsed, failures: failures),
                    .retryPaste,
                    "unavailable must not re-paste (failures=\(failures), elapsed=\(elapsed))."
                )
            }
        }
    }

    /// Legacy callers also receive the conservative evidence policy.
    func testLegacyDefaultCannotAuthorizeReplay() {
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 1,
                elapsed: 0.05
            ),
            .waitMore
        )
    }

    func testConfirmationThresholdIsAtLeastTwo() {
        XCTAssertGreaterThanOrEqual(
            PasteboardBroker.requiredFailureConfirmations, 2,
            "A threshold of 1 would restore the double-paste bug."
        )
    }

    // MARK: - The verifier behaviour that made this necessary

    /// Stale reads and still-pending delivery remain indistinguishable.
    func testStaleReadableValueIsReportedAsUnverified() {
        let baseline = DeliveryVerifier.FocusedTextObservation(
            value: "`slm",
            selectedText: nil,
            caretLocation: 4
        )
        // The paste landed, but AX still returns the pre-paste text.
        let stale = DeliveryVerifier.FocusedTextObservation(
            value: "`slm",
            selectedText: nil,
            caretLocation: 4
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "ScholarLM",
                baseline: baseline,
                after: stale
            ),
            .unavailable,
            "A stale read must not become authorization for another paste."
        )
    }

    func testGenuineDeliveryIsReportedAsDelivered() {
        let baseline = DeliveryObservationFixture.at("`slm", 0, 4)
        let after = DeliveryObservationFixture.at("ScholarLM", 9)
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "ScholarLM", baseline: baseline, after: after
            ),
            .delivered
        )
    }

    /// The doubled state itself must not read as "needs another paste" — otherwise a duplicate
    /// could cascade into a third copy.
    func testAlreadyDoubledTextIsNotReportedAsFailed() {
        let baseline = DeliveryVerifier.FocusedTextObservation(
            value: "`slm", selectedText: nil, caretLocation: 4
        )
        let doubled = DeliveryVerifier.FocusedTextObservation(
            value: "ScholarLMScholarLM", selectedText: nil, caretLocation: 18
        )
        XCTAssertNotEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "ScholarLM", baseline: baseline, after: doubled
            ),
            .failed,
            "Text that is already present twice must never trigger a third paste."
        )
    }
}

// MARK: - Untrusted hosts must never re-paste

/// Confirmation alone was not enough. In Claude Desktop the AXValue is readable and *never*
/// contains the pasted text, so `.failed` is permanent: it survives any number of confirming
/// re-reads and then re-pastes, duplicating the expansion every single time.
///
/// Two independent guards now stop that — the verifier no longer calls a changed field
/// `.failed`, and a host whose AX is condemned cannot authorise a retry at all.
final class UntrustedPasteRetryTests: XCTestCase {

    private func decide(
        _ delivery: DeliveryVerifier.TextDeliveryVerification,
        elapsed: TimeInterval = 0.05,
        failures: Int = 99,
        trust: Bool
    ) -> PasteboardBroker.PasteHoldDecision {
        PasteboardBroker.decidePasteHold(
            delivery: delivery,
            pasteAttemptsCompleted: 1,
            elapsed: elapsed,
            consecutiveFailures: failures,
            trustFailureVerdict: trust
        )
    }

    func testUntrustedHostNeverRetriesNoMatterHowManyFailures() {
        for failures in [1, 2, 5, 50] {
            XCTAssertNotEqual(
                decide(.failed, failures: failures, trust: false),
                .retryPaste,
                "A host that cannot judge delivery must never authorise a re-paste (failures=\(failures))."
            )
        }
    }

    func testUntrustedHostEndsUnverifiedRatherThanFailed() {
        XCTAssertEqual(
            decide(.failed, elapsed: InjectTiming.pasteDeliveryHoldTimeout + 1, failures: 99, trust: false),
            .giveUpUnverified,
            "Unverifiable is the honest outcome — reporting failure would restore the trigger on "
                + "top of text that actually landed."
        )
    }

    func testHistoricalTrustCannotAuthorizeReplay() {
        XCTAssertEqual(
            decide(.failed, failures: PasteboardBroker.requiredFailureConfirmations, trust: true),
            .waitMore,
            "Historical trust is not proof that this paste cannot still arrive."
        )
    }

    func testClaudeDesktopIsSeededAsUnverifiable() {
        XCTAssertTrue(
            AXWriteCapabilityStore.shared.shouldSkipAXSelectedText(bundleID: "com.anthropic.claudefordesktop"),
            "The app the duplicate expansions were reported in must be seeded as AX-false-success."
        )
    }

    // MARK: - Verifier no longer calls a changed field a failure

    /// The general guard: expected text absent, but the field moved — something landed, so
    /// re-pasting would duplicate it.
    func testChangedFieldWithoutExpectedTextIsUnverifiedNotFailed() {
        let baseline = DeliveryVerifier.FocusedTextObservation(
            value: "`slm", selectedText: nil, caretLocation: 4
        )
        // Field changed (the paste did something) but AX does not surface our text.
        let after = DeliveryVerifier.FocusedTextObservation(
            value: "something else", selectedText: nil, caretLocation: 14
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "ScholarLM", baseline: baseline, after: after
            ),
            .unavailable,
            "A changed field is not evidence the paste missed."
        )
    }

    /// Nothing moving can simply mean that the host has not consumed the event yet.
    func testUnchangedFieldCannotProveNonApplication() {
        let observation = DeliveryVerifier.FocusedTextObservation(
            value: "`slm", selectedText: nil, caretLocation: 4
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "ScholarLM", baseline: observation, after: observation
            ),
            .unavailable,
            "An untouched field cannot distinguish a pending paste from a missed paste."
        )
    }

    func testChangedSelectionAloneAlsoBlocksTheFailureVerdict() {
        let baseline = DeliveryVerifier.FocusedTextObservation(
            value: "`slm", selectedText: nil, caretLocation: 4
        )
        let after = DeliveryVerifier.FocusedTextObservation(
            value: "`slm", selectedText: "sel", caretLocation: 4
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "ScholarLM", baseline: baseline, after: after
            ),
            .unavailable
        )
    }
}
