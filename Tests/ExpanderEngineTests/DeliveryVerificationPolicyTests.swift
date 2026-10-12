import XCTest
@testable import ExpanderEngine

final class DeliveryVerificationPolicyTests: XCTestCase {

    func testTerminalBundleIDsIncludeWarp() {
        let checker = AXContextChecker()
        XCTAssertTrue(checker.isTerminalBundleID("com.apple.Terminal"))
        XCTAssertTrue(checker.isTerminalBundleID("dev.warp.Warp-Stable"))
        XCTAssertTrue(checker.isTerminalBundleID("dev.warp.Warp"))
        XCTAssertTrue(checker.isTerminalBundleID("co.zeit.hyper"))
        XCTAssertTrue(checker.isTerminalBundleID("com.cmuxterm.app"))
        XCTAssertFalse(checker.isTerminalBundleID("com.apple.Safari"))
    }

    func testIDEBundleIDsIncludeCursorAndVSCode() {
        let checker = AXContextChecker()
        XCTAssertTrue(checker.isIDEBundleID("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(checker.isIDEBundleID("com.microsoft.VSCode"))
        XCTAssertTrue(checker.isIDEBundleID("com.apple.dt.Xcode"))
        XCTAssertFalse(checker.isIDEBundleID("com.apple.Terminal"))
        XCTAssertFalse(checker.isIDEBundleID("com.apple.Safari"))
    }

    func testVerifyTextDeliverySucceedsWhenValueChangesToContainExpectedText() {
        let before = DeliveryObservationFixture.at("abc", 3)
        let after = DeliveryObservationFixture.at("abcHello", 8)

        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "Hello",
                baseline: before,
                after: after
            ),
            .delivered
        )
    }

    func testReadableAbsenceRemainsUnverified() {
        let before = DeliveryVerifier.FocusedTextObservation(
            value: "abc",
            selectedText: nil
        )
        let after = DeliveryVerifier.FocusedTextObservation(
            value: "abc",
            selectedText: nil
        )

        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "Hello",
                baseline: before,
                after: after
            ),
            .unavailable
        )
    }

    func testVerifyTextDeliveryReturnsUnavailableWhenExpectedWasAlreadyPresentWithoutObservableChange() {
        let before = DeliveryVerifier.FocusedTextObservation(
            value: "Hello",
            selectedText: nil
        )
        let after = DeliveryVerifier.FocusedTextObservation(
            value: "Hello",
            selectedText: nil
        )

        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "Hello",
                baseline: before,
                after: after
            ),
            .unavailable
        )
    }

    func testSelectedTextAloneCannotConfirmDelivery() {
        // Matching selection without a relevant observed transition is ambiguous.
        let after = DeliveryVerifier.FocusedTextObservation(
            value: nil,
            selectedText: "Hello"
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "Hello",
                baseline: nil,
                after: after
            ),
            .unavailable
        )
    }

    func testVerifyTextDeliveryReturnsUnavailableWhenAfterIsNil() {
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "Hello",
                baseline: nil,
                after: nil
            ),
            .unavailable
        )
    }

    func testVerifyTextDeliveryTreatsEmptyExpectedAsDelivered() {
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "",
                baseline: nil,
                after: nil
            ),
            .delivered
        )
    }

    func testPasteReverifyDelayIsReasonable() {
        // The deferred re-check delay must be short enough to feel instant but long enough
        // for slow apps to process the paste (100–500 ms range is acceptable).
        XCTAssertGreaterThanOrEqual(InjectTiming.pasteReverifyDelay, 0.10)
        XCTAssertLessThanOrEqual(InjectTiming.pasteReverifyDelay, 0.50)
    }

    func testDecidePasteHoldSucceedsWhenDelivered() {
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .delivered,
                pasteAttemptsCompleted: 1,
                elapsed: 0.01,
                holdTimeout: 0.35
            ),
            .succeed
        )
    }

    func testRepeatedMissesDoNotAuthorizeReplay() {
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 1,
                elapsed: 0.05,
                holdTimeout: 0.35
            ),
            .waitMore
        )
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 2,
                elapsed: 0.10,
                holdTimeout: 0.35
            ),
            .waitMore
        )
    }

    func testDecidePasteHoldWaitsThenGivesUpWhenUnavailable() {
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .unavailable,
                pasteAttemptsCompleted: 1,
                elapsed: 0.10,
                holdTimeout: 0.35
            ),
            .waitMore
        )
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .unavailable,
                pasteAttemptsCompleted: 1,
                elapsed: 0.35,
                holdTimeout: 0.35
            ),
            .giveUpUnverified
        )
    }

    func testPasteDeliverySettleDelayIsShort() {
        XCTAssertGreaterThan(InjectTiming.pasteDeliverySettleDelay, 0)
        XCTAssertLessThanOrEqual(InjectTiming.pasteDeliverySettleDelay, 0.12)
        XCTAssertEqual(InjectTiming.pasteDeliveryMaxAttempts, 2)
    }

    func testSecureFieldHelperFailClosedWithoutFocusedElement() {
        // Unit-test process: AX untrusted and/or no focused element → fail-closed (true = block expand).
        let checker = AXContextChecker.shared
        if checker.isProcessTrusted(), checker.focusedElement() != nil {
            // Rare in CI: if we somehow have focus, just assert the helpers return a Bool.
            _ = checker.isFocusedElementSecure()
            _ = checker.hasActiveIMEMarkedText()
        } else {
            XCTAssertTrue(checker.isFocusedElementSecure())
            XCTAssertTrue(checker.hasActiveIMEMarkedText())
        }
        XCTAssertTrue(checker.shouldBlockExpand(canUseAX: false))
    }

    func testAXMessagingTimeoutConstant() {
        XCTAssertEqual(AXContextChecker.messagingTimeoutSeconds, 0.05, accuracy: 0.0001)
    }

    func testAXFailClosedNilFocusedPolicy() {
        XCTAssertTrue(
            AXContextChecker.mustRefuseExpandWhenFocusedUnknown(
                axTrusted: false,
                focusedElementAvailable: false
            )
        )
        XCTAssertTrue(
            AXContextChecker.mustRefuseExpandWhenFocusedUnknown(
                axTrusted: true,
                focusedElementAvailable: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mustRefuseExpandWhenFocusedUnknown(
                axTrusted: true,
                focusedElementAvailable: true
            )
        )
    }

    func testAXContextCheckerOptimizedGateAndIDEBundle() {
        let checker = AXContextChecker()
        XCTAssertTrue(checker.isIDEBundleID("com.todesktop.test"))
        XCTAssertTrue(checker.isIDEBundleID("com.todesktop."))
        XCTAssertTrue(checker.shouldBlockExpand(canUseAX: false))
    }
}
