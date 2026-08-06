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
