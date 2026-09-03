import ApplicationServices
import XCTest
@testable import ExpanderEngine

final class ExpandGateDecisionTests: XCTestCase {
    func testFocusBlockReasonMapsTimeoutVsMissingVsOtherFailure() {
        XCTAssertEqual(
            AXContextChecker.focusBlockReason(for: .missing),
            "No focused AX element — expand blocked (fail-closed)"
        )
        XCTAssertEqual(
            AXContextChecker.focusBlockReason(for: .axFailure(.cannotComplete)),
            "AX focus query timed out — expand blocked (fail-closed)"
        )
        XCTAssertEqual(
            AXContextChecker.focusBlockReason(for: .axFailure(.failure)),
            "AX focus query failed (code \(AXError.failure.rawValue)) — expand blocked (fail-closed)"
        )
        XCTAssertEqual(
            AXContextChecker.focusBlockReason(for: .untrusted),
            "AXIsProcessTrusted false — expand blocked (fail-closed)"
        )
        XCTAssertNil(AXContextChecker.focusBlockReason(for: .available(AXUIElementCreateSystemWide())))
    }

    func testShouldRetryFocusQueryOnlyOnceOnCannotComplete() {
        XCTAssertTrue(
            AXContextChecker.shouldRetryFocusQuery(error: .cannotComplete, attemptIndex: 0)
        )
        XCTAssertFalse(
            AXContextChecker.shouldRetryFocusQuery(error: .cannotComplete, attemptIndex: 1)
        )
        XCTAssertFalse(
            AXContextChecker.shouldRetryFocusQuery(error: .noValue, attemptIndex: 0)
        )
        XCTAssertFalse(
            AXContextChecker.shouldRetryFocusQuery(error: .failure, attemptIndex: 0)
        )
    }

    func testReasonForFocusQueryFailureStableStrings() {
        XCTAssertEqual(
            AXContextChecker.reasonForFocusQueryFailure(.cannotComplete),
            "AX focus query timed out — expand blocked (fail-closed)"
        )
        let other = AXError.invalidUIElement
        XCTAssertEqual(
            AXContextChecker.reasonForFocusQueryFailure(other),
            "AX focus query failed (code \(other.rawValue)) — expand blocked (fail-closed)"
        )
    }

    func testSecureInputActiveReasonIsSpecific() {
        XCTAssertEqual(
            AXContextChecker.secureInputActiveReason,
            "Secure Input active — expand blocked"
        )
        XCTAssertFalse(
            AXContextChecker.secureInputActiveReason.contains("IME")
        )
        XCTAssertFalse(
            AXContextChecker.secureInputActiveReason.localizedCaseInsensitiveContains("missing focus")
        )
    }

    func testShouldBlockExpandAgreesWithEvaluateWhenAXUnavailable() {
        let checker = AXContextChecker()
        let decision = checker.evaluateExpandGate(canUseAX: false)
        XCTAssertTrue(decision.shouldBlock)
        XCTAssertTrue(checker.shouldBlockExpand(canUseAX: false))
        XCTAssertEqual(decision.reason, decision.snapshot.blockReason)
        XCTAssertEqual(
            decision.snapshot.blockReason,
            "Accessibility unavailable — expand blocked (fail-closed)"
        )
        XCTAssertEqual(checker.expandGateSnapshot(canUseAX: false), decision.snapshot)
    }

    func testMayAllowHIDExpandWithoutAXFocusForAnyAppWithPostAndNoSecure() {
        // Chrome / Messages / Notes — IDE no longer required.
        XCTAssertTrue(
            AXContextChecker.mayAllowHIDExpandWithoutAXFocus(
                focus: .missing,
                canPostEvents: true,
                secureInputEnabled: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowHIDExpandWithoutAXFocus(
                focus: .missing,
                canPostEvents: false,
                secureInputEnabled: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowHIDExpandWithoutAXFocus(
                focus: .missing,
                canPostEvents: true,
                secureInputEnabled: true
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowHIDExpandWithoutAXFocus(
                focus: .axFailure(.cannotComplete),
                canPostEvents: true,
                secureInputEnabled: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowHIDExpandWithoutAXFocus(
                focus: .untrusted,
                canPostEvents: true,
                secureInputEnabled: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowHIDExpandWithoutAXFocus(
                focus: .available(AXUIElementCreateSystemWide()),
                canPostEvents: true,
                secureInputEnabled: false
            )
        )
    }

    func testMayAllowSecureClipboardPasteRequiresIntentPostEmptyEraseNoIME() {
        XCTAssertTrue(
            AXContextChecker.mayAllowSecureClipboardPaste(
                intent: true,
                canPostEvents: true,
                eraseEmpty: true,
                hasIME: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowSecureClipboardPaste(
                intent: false,
                canPostEvents: true,
                eraseEmpty: true,
                hasIME: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowSecureClipboardPaste(
                intent: true,
                canPostEvents: false,
                eraseEmpty: true,
                hasIME: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowSecureClipboardPaste(
                intent: true,
                canPostEvents: true,
                eraseEmpty: false,
                hasIME: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mayAllowSecureClipboardPaste(
                intent: true,
                canPostEvents: true,
                eraseEmpty: true,
                hasIME: true
            )
        )
    }

    func testHIDWithoutAXFocusAllowReasonIsDocumented() {
        XCTAssertEqual(
            AXContextChecker.hidWithoutAXFocusAllowReason,
            "ok (AX focus unavailable — HID allowed with Post Events)"
        )
        XCTAssertTrue(AXContextChecker.hidWithoutAXFocusAllowReason.hasPrefix("ok"))
        XCTAssertEqual(
            AXContextChecker.focusBlockReason(for: .missing),
            "No focused AX element — expand blocked (fail-closed)"
        )
    }

    func testFocusBlockReasonUnchangedForFailures() {
        XCTAssertEqual(
            AXContextChecker.focusBlockReason(for: .axFailure(.cannotComplete)),
            "AX focus query timed out — expand blocked (fail-closed)"
        )
        XCTAssertEqual(
            AXContextChecker.focusBlockReason(for: .untrusted),
            "AXIsProcessTrusted false — expand blocked (fail-closed)"
        )
    }

    func testMessagingTimeoutUnchanged() {
        XCTAssertEqual(AXContextChecker.messagingTimeoutSeconds, 0.05, accuracy: 0.0001)
        XCTAssertEqual(AXContextChecker.focusQueryRetryDelaySeconds, 0.03, accuracy: 0.0001)
    }

    func testWeakAXAppsPreferHIDPaste() {
        XCTAssertTrue(
            TextInjectionPipeline.prefersHIDPasteOverAXSelectedText(bundleID: "com.apple.MobileSMS")
        )
        XCTAssertTrue(
            TextInjectionPipeline.prefersHIDPasteOverAXSelectedText(bundleID: "com.google.Chrome")
        )
        XCTAssertTrue(
            TextInjectionPipeline.prefersHIDPasteOverAXSelectedText(bundleID: "com.tinyspeck.slackmacgap")
        )
        XCTAssertTrue(
            TextInjectionPipeline.prefersHIDPasteOverAXSelectedText(
                bundleID: "com.todesktop.230313mzl4w4u92"
            )
        )
        // GitHub Desktop reports setSelectedText success without mutating the field.
        XCTAssertTrue(
            TextInjectionPipeline.prefersHIDPasteOverAXSelectedText(bundleID: "com.github.githubapp")
        )
        XCTAssertFalse(
            TextInjectionPipeline.prefersHIDPasteOverAXSelectedText(bundleID: "com.apple.Notes")
        )
        XCTAssertFalse(
            TextInjectionPipeline.prefersHIDPasteOverAXSelectedText(bundleID: "com.apple.TextEdit")
        )
    }
}

/// The refuse path itself, hardened: a fail-closed gate is only as good as its last attempt and
/// its explanation. Field report (2026-09-03): two expansions refused in WhatsApp with
/// "AX focus query timed out", and nothing in the report could say whether the app was hung or
/// whether the 50 ms budget was simply too small for an Electron shell under load.
final class FocusQueryEscalationTests: XCTestCase {

    /// A retry that repeats the budget that just expired asks the same question of the same busy
    /// app. The escalation is what makes the retry worth its own latency.
    func testTheRetryGetsABiggerBudgetThanTheAttemptThatTimedOut() {
        let first = AXContextChecker.focusQueryTimeout(attemptIndex: 0)
        let retry = AXContextChecker.focusQueryTimeout(attemptIndex: 1)

        XCTAssertEqual(first, AXContextChecker.messagingTimeoutSeconds)
        XCTAssertGreaterThan(
            retry, first,
            "Repeating an expired budget spends the retry without buying information."
        )
        // Bounded: the whole point is to stay well inside a human-noticeable pause. Worst case
        // is three probes at each budget plus the inter-attempt delay.
        let worstCase = Double(first + retry) * 3 + AXContextChecker.focusQueryRetryDelaySeconds
        XCTAssertLessThan(worstCase, 0.7, "The escalated path must not become a visible stall.")
    }

    /// Escalating must not quietly widen *which* failures get retried — that policy is separate
    /// and stays exactly as fail-closed as it was.
    func testEscalationDidNotWidenTheRetryPolicy() {
        XCTAssertTrue(AXContextChecker.shouldRetryFocusQuery(error: .cannotComplete, attemptIndex: 0))
        XCTAssertFalse(AXContextChecker.shouldRetryFocusQuery(error: .cannotComplete, attemptIndex: 1))
        XCTAssertFalse(AXContextChecker.shouldRetryFocusQuery(error: .apiDisabled, attemptIndex: 0))
        XCTAssertFalse(AXContextChecker.shouldRetryFocusQuery(error: .invalidUIElement, attemptIndex: 0))
    }

    /// A timeout with no corroboration reads the same whether the host is wedged or merely slow.
    func testTheRefusalNamesWhetherTheAppWasAnsweringAtAll() {
        let hung = AXContextChecker.reasonForFocusQueryFailure(.cannotComplete, appResponding: false)
        let slow = AXContextChecker.reasonForFocusQueryFailure(.cannotComplete, appResponding: true)
        let unknown = AXContextChecker.reasonForFocusQueryFailure(.cannotComplete)

        XCTAssertNotEqual(hung, slow, "The two causes have different fixes and must not read alike.")
        XCTAssertTrue(hung.contains("not answering AX at all"))
        XCTAssertTrue(slow.contains("focus query specifically timed out"))
        // The un-corroborated form stays byte-identical to the historical string, so anything
        // matching on it (and the fail-closed suffix) keeps working.
        XCTAssertEqual(unknown, "AX focus query timed out — expand blocked (fail-closed)")
        for reason in [hung, slow, unknown] {
            XCTAssertTrue(reason.hasSuffix("expand blocked (fail-closed)"))
        }
    }

    /// Corroboration is diagnosis, never permission: every `.axFailure` still blocks.
    func testCorroborationNeverTurnsARefusalIntoAnAllow() {
        for responding in [true, false] {
            let reason = AXContextChecker.focusBlockReason(
                for: .axFailure(.cannotComplete), appResponding: responding
            )
            XCTAssertNotNil(reason, "An AX failure must stay fail-closed regardless of the witness.")
        }
        XCTAssertNil(AXContextChecker.focusBlockReason(for: .available(AXUIElementCreateSystemWide())))
        // And the documented asymmetry is deliberate: `.missing` may proceed on HID, a failure
        // may not — a probe that answered "no focus" is evidence, one that never answered is not.
        XCTAssertFalse(
            AXContextChecker.mayAllowHIDExpandWithoutAXFocus(
                focus: .axFailure(.cannotComplete), canPostEvents: true, secureInputEnabled: false
            )
        )
        XCTAssertTrue(
            AXContextChecker.mayAllowHIDExpandWithoutAXFocus(
                focus: .missing, canPostEvents: true, secureInputEnabled: false
            )
        )
    }
}
