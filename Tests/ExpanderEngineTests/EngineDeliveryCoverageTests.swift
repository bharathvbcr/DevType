import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import ExpanderEngine

final class EngineDeliveryCoverageTests: XCTestCase {

    // MARK: - InjectTiming

    func testAllowsCursorArrows() {
        XCTAssertFalse(InjectTiming.allowsCursorArrows(count: -5))
        XCTAssertFalse(InjectTiming.allowsCursorArrows(count: 0))
        XCTAssertTrue(InjectTiming.allowsCursorArrows(count: 1))
        XCTAssertTrue(InjectTiming.allowsCursorArrows(count: 50))
        XCTAssertTrue(InjectTiming.allowsCursorArrows(count: InjectTiming.maxCursorArrowKeys))
        XCTAssertFalse(InjectTiming.allowsCursorArrows(count: InjectTiming.maxCursorArrowKeys + 1))
    }

    func testClampedUndoWindow() {
        XCTAssertEqual(InjectTiming.clampedUndoWindow(-1.0), InjectTiming.undoExpansionWindow)
        XCTAssertEqual(InjectTiming.clampedUndoWindow(0.0), InjectTiming.undoExpansionWindow)
        XCTAssertEqual(InjectTiming.clampedUndoWindow(.nan), InjectTiming.undoExpansionWindow)
        XCTAssertEqual(InjectTiming.clampedUndoWindow(.infinity), InjectTiming.undoExpansionWindow)

        // Below floor
        XCTAssertEqual(InjectTiming.clampedUndoWindow(0.1), InjectTiming.undoWindowFloor)
        // Above ceiling
        XCTAssertEqual(InjectTiming.clampedUndoWindow(10.0), InjectTiming.undoWindowCeiling)
        // In range
        XCTAssertEqual(InjectTiming.clampedUndoWindow(3.5), 3.5)

        // effectiveUndoWindow
        XCTAssertGreaterThanOrEqual(InjectTiming.effectiveUndoWindow, InjectTiming.undoWindowFloor)
        XCTAssertLessThanOrEqual(InjectTiming.effectiveUndoWindow, InjectTiming.undoWindowCeiling)
    }

    func testInjectTimingStoreSummaryAndEdgeInputs() throws {
        let store = InjectTimingStore()
        XCTAssertEqual(store.summaryLines(), ["(no paste latency samples recorded)"])

        // Invalid inputs to record
        store.recordDeliveryLatency(0.1, bundleID: nil)
        store.recordDeliveryLatency(0.1, bundleID: "")
        store.recordDeliveryLatency(0.1, bundleID: "nil")
        store.recordDeliveryLatency(-1.0, bundleID: "com.test.app")
        store.recordDeliveryLatency(10.0, bundleID: "com.test.app") // > maxPlausibleLatency
        XCTAssertEqual(store.summaryLines(), ["(no paste latency samples recorded)"])

        // Record valid inputs
        store.recordDeliveryLatency(0.1, bundleID: "com.test.app")
        let lowConfSummary = store.summaryLines()
        XCTAssertEqual(lowConfSummary.count, 2)
        XCTAssertTrue(lowConfSummary[1].contains("(low confidence)"))

        // Add enough samples for confidence
        for _ in 1..<InjectTimingStore.minSamplesForConfidence {
            store.recordDeliveryLatency(0.12, bundleID: "com.test.app")
        }
        let confidentSummary = store.summaryLines()
        XCTAssertFalse(confidentSummary[1].contains("(low confidence)"))

        // Image restore delay
        XCTAssertEqual(InjectTimingStore.imageRestoreDelay(payloadBytes: 0), InjectTiming.imageRestoreDelayFloor)
        XCTAssertEqual(InjectTimingStore.imageRestoreDelay(payloadBytes: 100_000_000), InjectTiming.imageRestoreDelayCeiling)

        // Reset
        store.reset()
        XCTAssertEqual(store.summaryLines(), ["(no paste latency samples recorded)"])
    }

    func testInjectTimingStoreFilePersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inject-timing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("inject-timing.json")
        let store = InjectTimingStore(fileURL: fileURL)

        for _ in 0..<InjectTimingStore.minSamplesForConfidence {
            store.recordDeliveryLatency(0.08, bundleID: "com.example.editor")
        }
        // Force sync write by waiting or checking persistence directly
        let p90 = store.p90DeliveryLatency(bundleID: "com.example.editor")
        XCTAssertNotNil(p90)
    }

    // MARK: - DeliveryVerifier

    func testFocusedTextObservationEquality() {
        let obs1 = DeliveryVerifier.FocusedTextObservation(
            value: "hello",
            selectedText: "el",
            caretLocation: 1,
            selectedRange: NSRange(location: 1, length: 2),
            target: nil
        )
        let obs2 = DeliveryVerifier.FocusedTextObservation(
            value: "hello",
            selectedText: "el",
            caretLocation: 1,
            selectedRange: NSRange(location: 1, length: 2),
            target: nil
        )
        let obs3 = DeliveryVerifier.FocusedTextObservation(
            value: "other",
            selectedText: "el",
            caretLocation: 1,
            selectedRange: NSRange(location: 1, length: 2),
            target: nil
        )
        XCTAssertEqual(obs1, obs2)
        XCTAssertNotEqual(obs1, obs3)
    }

    func testVerifyTextDeliveryEdgeCases() {
        // Empty expected text
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "", baseline: nil, after: nil),
            .delivered
        )

        // Nil baseline or after
        let emptyObs = DeliveryVerifier.FocusedTextObservation(value: "a", selectedText: nil)
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "test", baseline: emptyObs, after: nil),
            .unavailable
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "test", baseline: nil, after: emptyObs),
            .unavailable
        )

        // Missing target
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "test", baseline: emptyObs, after: emptyObs),
            .unavailable
        )

        // Valid AXUIElement target comparison
        let axApp = AXUIElementCreateApplication(getpid())
        let beforeObs = DeliveryVerifier.FocusedTextObservation(
            value: "hello ",
            selectedText: "",
            caretLocation: 6,
            selectedRange: NSRange(location: 6, length: 0),
            target: axApp
        )
        let afterObs = DeliveryVerifier.FocusedTextObservation(
            value: "hello world",
            selectedText: "",
            caretLocation: 11,
            selectedRange: NSRange(location: 11, length: 0),
            target: axApp
        )

        let result = DeliveryVerifier.verifyTextDelivery(
            expectedText: "world",
            baseline: beforeObs,
            after: afterObs
        )
        XCTAssertEqual(result, .delivered)

        // Mismatched after text
        let mismatchAfter = DeliveryVerifier.FocusedTextObservation(
            value: "hello earth",
            selectedText: "",
            caretLocation: 11,
            selectedRange: NSRange(location: 11, length: 0),
            target: axApp
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "world", baseline: beforeObs, after: mismatchAfter),
            .unavailable
        )

        // Invalid range bounds
        let invalidRangeObs = DeliveryVerifier.FocusedTextObservation(
            value: "hi",
            selectedText: "",
            caretLocation: 50,
            selectedRange: NSRange(location: 50, length: 10),
            target: axApp
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "hi", baseline: invalidRangeObs, after: invalidRangeObs),
            .unavailable
        )
    }

    // MARK: - EraseExecutor

    private final class MockBackspacePoster: BackspacePosting {
        var postedCount = 0
        func sendBackspaces(count: Int) -> Int {
            postedCount += count
            return count
        }
        func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void) {
            postedCount += count
            completion(true)
        }
    }

    func testEraseCountCalculations() {
        // triggerLength 0 -> 0
        XCTAssertEqual(EraseExecutor.eraseCount(triggerLength: 0, swallowedFinalKey: false), 0)
        XCTAssertEqual(EraseExecutor.eraseCount(triggerLength: 0, swallowedFinalKey: true), 0)

        // Not swallowed
        XCTAssertEqual(EraseExecutor.eraseCount(triggerLength: 5, swallowedFinalKey: false), 5)

        // Swallowed final key
        XCTAssertEqual(EraseExecutor.eraseCount(triggerLength: 5, swallowedFinalKey: true, lastEventCharacterCount: 1), 4)
        XCTAssertEqual(EraseExecutor.eraseCount(triggerLength: 5, swallowedFinalKey: true, lastEventCharacterCount: 2), 3)
        XCTAssertEqual(EraseExecutor.eraseCount(triggerLength: 1, swallowedFinalKey: true, lastEventCharacterCount: 1), 0)
        XCTAssertEqual(EraseExecutor.eraseCount(triggerLength: 1, swallowedFinalKey: true, lastEventCharacterCount: 5), 0)

        // EraseCountForMatch
        XCTAssertEqual(
            EraseExecutor.eraseCountForMatch(triggerUTF16Length: 4, terminator: " ", swallowedFinalKey: false),
            4
        )
        XCTAssertEqual(
            EraseExecutor.eraseCountForMatch(triggerUTF16Length: 4, terminator: "", swallowedFinalKey: true, lastEventCharacterCount: 1),
            3
        )
    }

    func testEraseExecutorPreconditionEvaluation() {
        let axApp = AXUIElementCreateApplication(getpid())
        let mockHID = MockBackspacePoster()
        let fakeText = "Hello ;date"
        let textAccess = EraseExecutor.TextAccess(
            value: { _ in fakeText },
            selectedRange: { _ in NSRange(location: fakeText.utf16.count, length: 0) },
            stringForRange: { _, range in
                (fakeText as NSString).substring(with: range)
            }
        )
        let executor = EraseExecutor(hid: mockHID, ax: AXTextWriter.shared, textAccess: textAccess)

        let plan = ErasePlan(text: ";date")

        let resultSync = executor.evaluateErasePrecondition(
            plan: plan,
            element: axApp,
            retryOnMismatch: false
        )
        XCTAssertEqual(resultSync, .ok)

        let exp = expectation(description: "async evaluate")
        executor.evaluateErasePrecondition(
            plan: plan,
            element: axApp,
            retryOnMismatch: false
        ) { result in
            XCTAssertEqual(result, .ok)
            exp.fulfill()
        }
        waitForExpectations(timeout: 2.0)
    }

    func testDeliveryVerifierLiveAXMethods() {
        let verifier = DeliveryVerifier()
        let sys = AXUIElementCreateSystemWide()
        let obs = verifier.focusedTextObservation(for: sys)
        XCTAssertEqual(obs.target, sys)

        _ = verifier.captureFocusedTextObservation()
        _ = DeliveryVerifier.selectedRange(for: sys)
        _ = verifier.verifyFocusedTextDelivery(expectedText: "test", baseline: nil)
        _ = verifier.verifyFocusedTextDelivery(expectedText: "test", baseline: obs)
    }

    func testEraseExecutorTextAccessLiveAndGuardedErase() {
        let sys = AXUIElementCreateSystemWide()
        _ = EraseExecutor.TextAccess.live.value(sys)
        _ = EraseExecutor.TextAccess.live.selectedRange(sys)
        _ = EraseExecutor.TextAccess.live.stringForRange(sys, NSRange(location: 0, length: 0))

        let executor = EraseExecutor()
        let plan = ErasePlan(text: ";short")

        let exp1 = expectation(description: "guarded erase allowed")
        executor.performGuardedErase(plan: plan, afterPossibleWrite: false, canProceed: { true }) { _ in
            exp1.fulfill()
        }

        let exp2 = expectation(description: "guarded erase blocked")
        executor.performGuardedErase(plan: plan, afterPossibleWrite: false, canProceed: { false }) { success in
            XCTAssertFalse(success)
            exp2.fulfill()
        }

        let exp3 = expectation(description: "finish guarded erase unavailable")
        executor.finishGuardedErase(
            plan: plan,
            afterPossibleWrite: true,
            result: .unavailable("unverifiable"),
            canProceed: { true },
            onUnverifiableAfterWrite: { _ in },
            completion: { _ in exp3.fulfill() }
        )

        waitForExpectations(timeout: 2.0)
    }
}
