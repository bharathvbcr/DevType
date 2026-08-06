import XCTest
@testable import ExpanderEngine

/// §3.4 — every injection timing constant used to be a fixed guess. `InjectTimingStore` replaces
/// the two that matter with a measured per-bundle value. This covers the pure math; the
/// in-memory `init()` keeps the tests off the shared JSON file.
final class InjectTimingStoreTests: XCTestCase {

    // MARK: - percentile

    func testPercentileOfEmptyIsNil() {
        XCTAssertNil(InjectTimingStore.percentile(0.9, of: []))
    }

    func testPercentileOfSingleValue() {
        XCTAssertEqual(InjectTimingStore.percentile(0.9, of: [0.2]), 0.2)
        XCTAssertEqual(InjectTimingStore.percentile(0.0, of: [0.2]), 0.2)
        XCTAssertEqual(InjectTimingStore.percentile(1.0, of: [0.2]), 0.2)
    }

    func testPercentileIsNearestRankOverSortedInput() {
        let values: [Double] = [10, 1, 5, 3, 9, 7, 2, 8, 4, 6]  // 1…10 shuffled
        XCTAssertEqual(InjectTimingStore.percentile(0.0, of: values), 1)
        XCTAssertEqual(InjectTimingStore.percentile(1.0, of: values), 10)
        // rank = round(0.9 * 9) = 8 → sorted[8] == 9
        XCTAssertEqual(InjectTimingStore.percentile(0.9, of: values), 9)
        // rank = round(0.5 * 9) = 5 (Swift rounds .5 away from zero) → sorted[5] == 6
        XCTAssertEqual(InjectTimingStore.percentile(0.5, of: values), 6)
    }

    func testPercentileClampsFractionOutOfRange() {
        let values: [Double] = [1, 2, 3]
        XCTAssertEqual(InjectTimingStore.percentile(-4.0, of: values), 1)
        XCTAssertEqual(InjectTimingStore.percentile(9.0, of: values), 3)
    }

    func testPercentileIgnoresOriginalOrdering() {
        let ascending: [Double] = [0.01, 0.02, 0.30, 0.31]
        let descending: [Double] = Array(ascending.reversed())
        XCTAssertEqual(
            InjectTimingStore.percentile(0.9, of: ascending),
            InjectTimingStore.percentile(0.9, of: descending)
        )
    }

    // MARK: - blindRestoreDelay (the pre-§3.4 behaviour, kept for unknown apps)

    func testBlindRestoreDelayClampsToFloorForSmallPayloads() {
        XCTAssertEqual(InjectTimingStore.blindRestoreDelay(payloadBytes: 0), InjectTiming.restoreDelayFloor)
        XCTAssertEqual(InjectTimingStore.blindRestoreDelay(payloadBytes: 12), InjectTiming.restoreDelayFloor)
        // Negative bytes cannot happen, but must not produce a negative delay.
        XCTAssertEqual(InjectTimingStore.blindRestoreDelay(payloadBytes: -100), InjectTiming.restoreDelayFloor)
    }

    func testBlindRestoreDelayClampsToCeilingForHugePayloads() {
        XCTAssertEqual(
            InjectTimingStore.blindRestoreDelay(payloadBytes: 10_000_000),
            InjectTiming.restoreDelayCeiling
        )
    }

    func testBlindRestoreDelayScalesLinearlyInsideTheBand() {
        // 12_000 bytes / 40_000 B/s = 0.30 s — between the 0.15 floor and the 0.45 ceiling.
        let delay = InjectTimingStore.blindRestoreDelay(payloadBytes: 12_000)
        XCTAssertEqual(delay, 0.30, accuracy: 1e-9)
        XCTAssertGreaterThan(delay, InjectTiming.restoreDelayFloor)
        XCTAssertLessThan(delay, InjectTiming.restoreDelayCeiling)
    }

    func testBlindRestoreDelayIsMonotonic() {
        var previous = 0.0
        for bytes in stride(from: 0, through: 40_000, by: 2_000) {
            let delay = InjectTimingStore.blindRestoreDelay(payloadBytes: bytes)
            XCTAssertGreaterThanOrEqual(delay, previous)
            previous = delay
        }
    }

    // MARK: - Adaptation

    func testUnknownBundleGetsExactlyTheBlindDefaults() {
        let store = InjectTimingStore()
        XCTAssertNil(store.p90DeliveryLatency(bundleID: "com.example.never-seen"))
        XCTAssertEqual(
            store.restoreDelay(bundleID: "com.example.never-seen", payloadBytes: 4_000),
            InjectTimingStore.blindRestoreDelay(payloadBytes: 4_000)
        )
        XCTAssertEqual(
            store.holdTimeout(bundleID: "com.example.never-seen"),
            InjectTiming.pasteDeliveryHoldTimeout
        )
        // A nil / placeholder bundle ID must never learn or adapt.
        XCTAssertNil(store.p90DeliveryLatency(bundleID: nil))
        XCTAssertNil(store.p90DeliveryLatency(bundleID: ""))
    }

    func testTooFewSamplesStayOnTheBlindDefaults() {
        let store = InjectTimingStore()
        for _ in 0..<(InjectTimingStore.minSamplesForConfidence - 1) {
            store.recordDeliveryLatency(0.01, bundleID: "com.example.fast")
        }
        XCTAssertNil(store.p90DeliveryLatency(bundleID: "com.example.fast"))
        XCTAssertEqual(
            store.restoreDelay(bundleID: "com.example.fast", payloadBytes: 0),
            InjectTiming.restoreDelayFloor
        )
    }

    func testFastAppDropsBelowTheBlindFloorButNeverBelowTheAdaptiveFloor() {
        let store = InjectTimingStore()
        for _ in 0..<InjectTimingStore.minSamplesForConfidence {
            store.recordDeliveryLatency(0.001, bundleID: "com.example.fast")
        }
        let delay = store.restoreDelay(bundleID: "com.example.fast", payloadBytes: 0)
        XCTAssertLessThan(delay, InjectTiming.restoreDelayFloor)
        XCTAssertGreaterThanOrEqual(delay, InjectTiming.restoreDelayAdaptiveFloor)
    }

    func testSlowElectronHostGetsALongerHoldTimeout() {
        let store = InjectTimingStore()
        for _ in 0..<InjectTimingStore.minSamplesForConfidence {
            store.recordDeliveryLatency(0.30, bundleID: "com.example.slow")
        }
        let timeout = store.holdTimeout(bundleID: "com.example.slow")
        XCTAssertGreaterThan(timeout, InjectTiming.pasteDeliveryHoldTimeout)
        XCTAssertLessThanOrEqual(timeout, InjectTiming.pasteDeliveryHoldTimeoutCeiling)
    }

    func testImplausibleSamplesAreDiscarded() {
        let store = InjectTimingStore()
        for _ in 0..<(InjectTimingStore.minSamplesForConfidence + 2) {
            // Debugger stop / machine sleep artifacts.
            store.recordDeliveryLatency(InjectTimingStore.maxPlausibleLatency + 1, bundleID: "com.example.x")
            store.recordDeliveryLatency(-1, bundleID: "com.example.x")
        }
        XCTAssertNil(store.p90DeliveryLatency(bundleID: "com.example.x"))
    }

    func testSampleRingIsBounded() {
        let store = InjectTimingStore()
        for index in 0..<(InjectTimingStore.maxSamplesPerBundle * 3) {
            store.recordDeliveryLatency(Double(index % 5) / 100.0, bundleID: "com.example.ring")
        }
        // Still answers, and the summary reports at most the ring capacity.
        XCTAssertNotNil(store.p90DeliveryLatency(bundleID: "com.example.ring"))
        let line = store.summaryLines().first { $0.contains("com.example.ring") }
        XCTAssertNotNil(line)
        XCTAssertEqual(line?.contains("over \(InjectTimingStore.maxSamplesPerBundle) samples"), true)
    }

    // MARK: - §3.4 image bug

    func testImageRestoreDelayDoesNotSaturateInstantly() {
        // The text formula (bytes / 40_000) computed 25 s for a 1 MB image and clamped to the
        // 0.45 s ceiling — the number carried no information at all.
        let oneMegabyte = 1_000_000
        let delay = InjectTimingStore.imageRestoreDelay(payloadBytes: oneMegabyte)
        XCTAssertGreaterThanOrEqual(delay, InjectTiming.imageRestoreDelayFloor)
        XCTAssertLessThanOrEqual(delay, InjectTiming.imageRestoreDelayCeiling)
        XCTAssertNotEqual(
            delay,
            InjectTiming.imageRestoreDelayCeiling,
            "A 1 MB image must not saturate the image restore window."
        )
    }
}
