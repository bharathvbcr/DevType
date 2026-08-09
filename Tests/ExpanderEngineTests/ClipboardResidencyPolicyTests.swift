import XCTest
@testable import ExpanderEngine

// MARK: - §8.12: behavioural tests for the extracted payload-residency policy
//
// `ClipboardResidencyTests` pins the defect at the source level (the release policy used to be
// inline control flow with no seam). These test the policy itself, including the cases built to
// break it: stale learned samples, an app that never speaks AX, a frozen app, a clock that stops.
final class ClipboardResidencyPolicyTests: XCTestCase {

    private let claudeDesktop = "com.anthropic.claudefordesktop"

    private func storeWithSamples(_ latency: TimeInterval, bundle: String) -> InjectTimingStore {
        let store = InjectTimingStore()
        for _ in 0..<(InjectTimingStore.minSamplesForConfidence + 4) {
            store.recordDeliveryLatency(latency, bundleID: bundle)
        }
        return store
    }

    // MARK: - The reported regression

    /// The bug, stated as an invariant: a host whose historical samples are fast must still hold
    /// the payload for the unknown-app residency. Learned evidence may shorten a wait; the memory
    /// of evidence, recorded when AX could still confirm, may not.
    func testLearnedFastSamplesCanNoLongerShrinkTheResidency() {
        let store = storeWithSamples(0.02, bundle: claudeDesktop)

        // The inputs that produced the failure are unchanged…
        XCTAssertLessThan(store.holdTimeout(bundleID: claudeDesktop), InjectTiming.pasteDeliveryHoldTimeout)
        XCTAssertLessThan(
            store.restoreDelay(bundleID: claudeDesktop, payloadBytes: 200),
            InjectTiming.restoreDelayFloor
        )

        // …but the payload no longer leaves the board on that basis.
        XCTAssertEqual(
            store.unverifiedPayloadResidency(bundleID: claudeDesktop, payloadBytes: 200),
            InjectTiming.unverifiedPayloadResidencyFloor,
            accuracy: 0.0001,
            "a host with fast historical samples must still owe the full unverified residency"
        )
    }

    /// The whole point of separating the two numbers: the payload must outlive the AX polling
    /// window, otherwise the outcome that ends the polling also ends the paste's chance of landing.
    func testResidencyFloorOutlivesTheAXHoldWindow() {
        XCTAssertGreaterThan(
            InjectTiming.unverifiedPayloadResidencyFloor,
            InjectTiming.pasteDeliveryHoldTimeout,
            "residency answers 'has the host read the bytes', not 'has AX confirmed' — it must be the longer of the two"
        )
        XCTAssertGreaterThan(
            InjectTiming.unverifiedPayloadResidencyFloor,
            InjectTiming.restoreDelayFloor
        )
        XCTAssertGreaterThanOrEqual(
            InjectTiming.unverifiedPayloadResidencyCeiling,
            InjectTiming.unverifiedPayloadResidencyFloor
        )
    }

    // MARK: - Residency arithmetic

    func testUnknownAppGetsTheFloor() {
        let store = InjectTimingStore()
        XCTAssertEqual(
            store.unverifiedPayloadResidency(bundleID: "com.example.never-seen", payloadBytes: 40),
            InjectTiming.unverifiedPayloadResidencyFloor,
            accuracy: 0.0001
        )
    }

    func testSlowHostLengthensTheResidency() {
        let store = storeWithSamples(0.5, bundle: "com.example.slow")
        let residency = store.unverifiedPayloadResidency(bundleID: "com.example.slow", payloadBytes: 40)
        XCTAssertGreaterThan(residency, InjectTiming.unverifiedPayloadResidencyFloor)
        XCTAssertEqual(residency, 0.5 * InjectTiming.deliverySafetyFactor, accuracy: 0.0001)
    }

    func testAbsurdlySlowHostIsClampedToTheCeiling() {
        let store = storeWithSamples(4.0, bundle: "com.example.glacial")
        XCTAssertEqual(
            store.unverifiedPayloadResidency(bundleID: "com.example.glacial", payloadBytes: 40),
            InjectTiming.unverifiedPayloadResidencyCeiling,
            accuracy: 0.0001,
            "a wrong clipboard forever is worse than a dropped paste"
        )
    }

    /// Adversarial: nonsense inputs must not produce a negative or NaN hold.
    func testDegenerateInputsStayInsideTheBounds() {
        for p90 in [nil, -1.0, 0.0, Double.leastNonzeroMagnitude, 1_000.0] as [Double?] {
            for bytes in [-5, 0, 1, Int.max / 2] {
                let value = InjectTimingStore.unverifiedPayloadResidency(
                    blindDelay: InjectTimingStore.blindRestoreDelay(payloadBytes: bytes),
                    p90: p90
                )
                XCTAssertGreaterThanOrEqual(value, InjectTiming.unverifiedPayloadResidencyFloor)
                XCTAssertLessThanOrEqual(value, InjectTiming.unverifiedPayloadResidencyCeiling)
            }
        }
    }

    /// A caller-committed window (the 8 s secure-clipboard manual-⌘V hold) must survive the
    /// ceiling clamp. This is why `atLeast` is a parameter rather than a `max` at the call site.
    func testCallerCommittedWindowIsNeverClampedDown() {
        let store = InjectTimingStore()
        let secureWindow = InjectTiming.secureClipboardPasteHoldTimeout
        XCTAssertGreaterThan(secureWindow, InjectTiming.unverifiedPayloadResidencyCeiling)
        XCTAssertEqual(
            store.unverifiedPayloadResidency(
                bundleID: claudeDesktop,
                payloadBytes: 40,
                atLeast: secureWindow
            ),
            secureWindow,
            accuracy: 0.0001,
            "the secure-clipboard paste keeps the payload up for a manual ⌘V; residency may lengthen that, never shorten it"
        )
    }

    // MARK: - Remaining residency by outcome

    func testDeliveredReleasesImmediatelyBecauseTheReadIsProven() {
        for elapsed in [0.0, 0.01, 5.0] {
            XCTAssertEqual(
                PasteboardBroker.remainingPayloadResidency(
                    result: .delivered,
                    elapsedSincePaste: elapsed,
                    unverifiedHold: 0.45
                ),
                0,
                "AX found the text in the field, so the host demonstrably read the board"
            )
        }
    }

    func testNotPostedReleasesImmediatelyBecauseThereIsNoKeystroke() {
        XCTAssertEqual(
            PasteboardBroker.remainingPayloadResidency(
                result: .notPosted,
                elapsedSincePaste: 0,
                unverifiedHold: 0.45
            ),
            0
        )
    }

    /// The failure the user saw: ⌘V posted, AX said nothing, and the hold ended after 0.15 s.
    func testUnverifiedPasteStillOwesTheRestOfItsResidency() {
        XCTAssertEqual(
            PasteboardBroker.remainingPayloadResidency(
                result: .unavailable,
                elapsedSincePaste: 0.15,
                unverifiedHold: 0.45
            ),
            0.30,
            accuracy: 0.0001,
            "the AX hold ending is not the host having read the board"
        )
    }

    /// A readable-but-unchanged field is evidence about the field, not about the pasteboard: a
    /// host that has not dequeued the keystroke yet reads exactly the same.
    func testConfirmedMissAlsoOwesItsResidency() {
        XCTAssertEqual(
            PasteboardBroker.remainingPayloadResidency(
                result: .failed,
                elapsedSincePaste: 0.10,
                unverifiedHold: 0.45
            ),
            0.35,
            accuracy: 0.0001
        )
    }

    func testResidencyAlreadySpentReleasesNow() {
        XCTAssertEqual(
            PasteboardBroker.remainingPayloadResidency(
                result: .unavailable,
                elapsedSincePaste: 0.9,
                unverifiedHold: 0.45
            ),
            0
        )
    }

    /// Adversarial: a clock that appears to run backwards must not produce a negative wait (which
    /// `asyncAfter` would treat as "now" anyway) nor an overlong one.
    func testNegativeElapsedIsTreatedAsZeroNotAsCredit() {
        XCTAssertEqual(
            PasteboardBroker.remainingPayloadResidency(
                result: .unavailable,
                elapsedSincePaste: -10,
                unverifiedHold: 0.45
            ),
            0.45,
            accuracy: 0.0001
        )
    }

    // MARK: - Stall extension

    /// The important negative case. An app that never answers AX (many terminals, hardened
    /// Electron shells) must not be treated as frozen, or every expansion there would pin the
    /// user's clipboard until the ceiling.
    func testSilentAppWithNoBaselineIsNotTreatedAsStalled() {
        XCTAssertFalse(
            PasteboardBroker.shouldExtendResidencyForStalledHost(
                hostRespondedAtPaste: false,
                hostRespondsNow: false,
                elapsedSincePaste: 0.5
            ),
            "no baseline means the probe never ran — that must not read the same as a probe that ran and found a stall"
        )
    }

    func testHealthyAppIsNotExtended() {
        XCTAssertFalse(
            PasteboardBroker.shouldExtendResidencyForStalledHost(
                hostRespondedAtPaste: true,
                hostRespondsNow: true,
                elapsedSincePaste: 0.5
            )
        )
    }

    func testFrozenAppKeepsThePayload() {
        XCTAssertTrue(
            PasteboardBroker.shouldExtendResidencyForStalledHost(
                hostRespondedAtPaste: true,
                hostRespondsNow: false,
                elapsedSincePaste: 0.5
            ),
            "an app not servicing AX is not servicing its event queue either — ⌘V has not been consumed"
        )
    }

    func testStallExtensionIsBoundedByTheCeiling() {
        XCTAssertFalse(
            PasteboardBroker.shouldExtendResidencyForStalledHost(
                hostRespondedAtPaste: true,
                hostRespondsNow: false,
                elapsedSincePaste: InjectTiming.unverifiedPayloadResidencyCeiling
            )
        )
        XCTAssertFalse(
            PasteboardBroker.shouldExtendResidencyForStalledHost(
                hostRespondedAtPaste: true,
                hostRespondsNow: false,
                elapsedSincePaste: 30
            ),
            "a host frozen this long has dropped the keystroke; the user's clipboard wins"
        )
    }

    /// A stalled host is re-probed on an interval, so the extension count must be bounded
    /// independently of the wall clock the ceiling is expressed in.
    func testStallExtensionsHaveACountBoundNotOnlyATimeBound() {
        XCTAssertGreaterThan(PasteboardBroker.maxStallExtensions, 0)
        XCTAssertLessThanOrEqual(
            Double(PasteboardBroker.maxStallExtensions) * InjectTiming.stalledHostResidencyProbeInterval,
            InjectTiming.unverifiedPayloadResidencyCeiling * 2,
            "the count bound must be the same order as the time bound, not a second, looser ceiling"
        )
    }

    // MARK: - Telemetry

    /// The bug was invisible in every existing counter — the expansion recorded a normal-looking
    /// `postedUnverified` while the user watched their old clipboard appear.
    func testResidencyIsReportable() {
        let log = InjectTelemetryLog()
        log.recordUnverifiedClipboardHold(bundleID: claudeDesktop, heldFor: 0.45)
        log.recordUnverifiedClipboardHold(bundleID: claudeDesktop, heldFor: 1.2)
        log.recordClipboardHoldExtension(bundleID: claudeDesktop)

        let counters = log.clipboardHoldsByBundle()[claudeDesktop]
        XCTAssertEqual(counters?.unverifiedHolds, 2)
        XCTAssertEqual(counters?.stallExtensions, 1)
        XCTAssertEqual(counters?.maxHeldMillis, 1200)
        XCTAssertFalse(counters?.isEmpty ?? true)
    }

    func testNegativeHoldDurationIsNotRecordedAsTime() {
        let log = InjectTelemetryLog()
        log.recordUnverifiedClipboardHold(bundleID: "com.example.app", heldFor: -3)
        XCTAssertEqual(log.clipboardHoldsByBundle()["com.example.app"]?.maxHeldMillis, 0)
    }
}
