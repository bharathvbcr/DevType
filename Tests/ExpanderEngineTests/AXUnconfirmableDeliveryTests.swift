import XCTest
@testable import ExpanderEngine

/// The duplicate-expansion paths `UntrustedPasteRetryTests` does not reach.
///
/// That suite proves the paste-hold loop no longer re-pastes on an AX-unverifiable host. But the
/// same false negative is read a second time, ~1 s later, by the deferred re-verify in
/// `finishPasteDelivery` — and acting on it there writes the trigger back *after* an expansion
/// that did land. Suppressing only the re-paste turns "text twice" into "text plus trigger".
///
/// So the question "may this app be believed when it says the text is missing?" has to be asked
/// once, in one place, by both callers: `canConfirmDelivery`.
final class AXUnconfirmableDeliveryTests: XCTestCase {

    // MARK: - Who may testify about delivery

    func testCondemnedElectronHostsCannotConfirmDelivery() {
        let store = AXWriteCapabilityStore()
        for bundle in [
            "com.anthropic.claudefordesktop",
            "com.tinyspeck.slackmacgap",
            "com.google.Chrome",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92"
        ] {
            XCTAssertFalse(
                store.canConfirmDelivery(bundleID: bundle),
                "\(bundle) reports AX writes it never performs; its 'text missing' verdict is a false negative"
            )
        }
    }

    func testNativeAndUnknownHostsStayTrusted() {
        let store = AXWriteCapabilityStore()
        XCTAssertTrue(store.canConfirmDelivery(bundleID: "com.apple.TextEdit"))
        XCTAssertTrue(store.canConfirmDelivery(bundleID: "com.example.unheard-of"))
        // Having no app to judge is not evidence against the verdict — keep prior behaviour.
        XCTAssertTrue(store.canConfirmDelivery(bundleID: nil))
        XCTAssertTrue(store.canConfirmDelivery(bundleID: ""))
    }

    func testLearnedFalseSuccessRevokesTestimony() {
        let store = AXWriteCapabilityStore()
        XCTAssertTrue(store.canConfirmDelivery(bundleID: "com.example.app"))
        store.recordFalseSuccess(bundleID: "com.example.app")
        XCTAssertFalse(
            store.canConfirmDelivery(bundleID: "com.example.app"),
            "an app caught faking a write must stop being believed about delivery too"
        )
    }

    /// An untrusted host that has already burned its retries must still not report `.failed` —
    /// that outcome is what restores the trigger.
    func testUntrustedHostWithRetriesExhaustedStillEndsUnverified() {
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: InjectTiming.pasteDeliveryMaxAttempts,
                elapsed: InjectTiming.pasteDeliveryHoldTimeout + 1,
                consecutiveFailures: 99,
                trustFailureVerdict: false
            ),
            .giveUpUnverified
        )
    }

    // MARK: - Reporting

    /// One expansion that duplicates text is still one `Entry`, which is why the diagnostic report
    /// read `succeeded=14 failedSilent=1` while the user was looking at doubled text. The actions
    /// that write text twice are therefore counted separately from inject outcomes.
    func testDuplicateRiskCountersSurfaceInTheDiagnosticSummary() {
        let log = InjectTelemetryLog()
        log.record(outcome: .postedUnverified, bundleID: "com.anthropic.claudefordesktop", path: "hidPaste")
        log.recordPasteRetry(bundleID: "com.anthropic.claudefordesktop")
        log.recordTriggerRestore(bundleID: "com.anthropic.claudefordesktop")
        log.recordSuppressedMissVerdict(bundleID: "com.anthropic.claudefordesktop")

        let counters = log.duplicateRiskByBundle()["com.anthropic.claudefordesktop"]
        XCTAssertEqual(counters?.pasteRetries, 1)
        XCTAssertEqual(counters?.triggerRestores, 1)
        XCTAssertEqual(counters?.suppressedMissVerdicts, 1)

        let summary = log.summaryLines().joined(separator: "\n")
        XCTAssertTrue(summary.contains("Duplicate risk"), summary)
        XCTAssertTrue(summary.contains("re-pastes=1"), summary)
        XCTAssertTrue(summary.contains("trigger-restores=1"), summary)
    }

    func testQuietSessionsDoNotPrintADuplicateRiskBlock() {
        let log = InjectTelemetryLog()
        log.record(outcome: .succeeded, bundleID: "com.apple.TextEdit", path: "axDirect")
        XCTAssertFalse(log.summaryLines().joined(separator: "\n").contains("Duplicate risk"))
    }

    func testResetClearsDuplicateRisk() {
        let log = InjectTelemetryLog()
        log.recordPasteRetry(bundleID: "com.example.app")
        log.reset()
        XCTAssertTrue(log.duplicateRiskByBundle().isEmpty)
    }
}
