import ApplicationServices
import Foundation
import XCTest
@testable import ExpanderEngine

final class UndoAuditRegressionTests: XCTestCase {
    func testUnverifiableUndoMustNotClaimTheTextChanged() {
        for path in ["undo", "undoAXRange", "undoAXDirect", "undoPaste"] {
            let message = PermissionCoordinator.sanitizedRefusalReason(
                "field unverifiable (no focused element) and 2 input events", path: path
            )
            XCTAssertEqual(message, "Undo refused — safe reversal could not be verified")
        }
    }

    func testWideningHonorsZeroAndNegativeLimits() {
        for limit in [0, -1, Int.min] {
            XCTAssertNil(TextInjectionPipeline.widenedUndo(
                injectedText: "abc", triggerText: "x", value: "abcd",
                caretLocation: 4, maxTypedAfter: limit
            ))
        }
    }

    func testWideningCannotExceedItsHardLimit() {
        XCTAssertNil(TextInjectionPipeline.widenedUndo(
            injectedText: "abc", triggerText: "x", value: "abc" + String(repeating: "d", count: 17),
            caretLocation: 20, maxTypedAfter: Int.max
        ))
    }

    func testFreshnessRejectsInvalidWindowsAndCapsStaleRecords() {
        let now = Date(timeIntervalSince1970: 100)
        let record = TextInjectionPipeline.LastExpansion(
            erasePlan: .empty, injectedText: "abc", triggerText: "x", bundleID: nil,
            timestamp: now.addingTimeInterval(-6)
        )
        for window in [Double.infinity, .nan, -1, 0, 60] {
            XCTAssertFalse(record.isFresh(now: now, window: window))
        }
    }

    func testUndoUsesTheGuardedInjectionOwner() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift"
        ), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    private func performUndo("))
        let end = try XCTUnwrap(source.range(of: "    // MARK: - Inject (main thread)", range: start.upperBound..<source.endIndex))
        let undo = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(undo.contains("enqueueInjection("))
        XCTAssertFalse(undo.contains("pasteViaClipboard("))
        XCTAssertFalse(undo.contains("performGuardedErase("))
        XCTAssertFalse(undo.contains("attemptAXDirectInjection("))
    }

    func testDeliveryContaminationSaturatesInsteadOfTrapping() {
        XCTAssertEqual(TextInjectionPipeline.deliveryInputUnits(
            keyContaminates: true, flushReplayCount: Int.max
        ), Int.max)
        let pipeline = TextInjectionPipeline()
        pipeline.noteDeliveryInput(units: Int.max)
        pipeline.noteDeliveryInput()
        XCTAssertEqual(pipeline.deliveryInputUnitsForTesting, Int.max)
    }

    func testWideningRejectsCaretInsideASurrogatePair() {
        XCTAssertNil(TextInjectionPipeline.widenedUndo(
            injectedText: "abc", triggerText: "x", value: "abc🎓", caretLocation: 4
        ))
    }

    func testWideningMustNotGuessBetweenRepeatedMatches() {
        XCTAssertNil(TextInjectionPipeline.widenedUndo(
            injectedText: "aa", triggerText: "x", value: "aaaa", caretLocation: 4
        ))
    }

    func testEraseNeverApprovesAPartialGraphemeWindow() {
        for (expected, value, caret) in [("�", "🎓", 1), ("\u{0301}", "a\u{0301}", 2),
                                          ("👩", "👩‍💻", 2)] {
            for vouched in [false, true] {
                XCTAssertTrue(ErasePreconditionChecker.evaluate(
                    plan: ErasePlan(text: expected), value: value, caretLocation: caret,
                    selectionLength: 0, insertionPointFollowsExpectedText: vouched
                ).blocksErase)
            }
        }
    }

    func testMatchingBypassesAndAppSwitchesInvalidateUndoBeforeReturning() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/ExpanderEngine/Engine/EventTapEngine.swift"
        ), encoding: .utf8)
        for marker in ["guard enabled && !secureFlag && !suspended else {",
                       "if EventTapEngine.shouldIgnoreForMatching(isAutorepeat: isAutorepeat) {"] {
            let start = try XCTUnwrap(source.range(of: marker))
            let end = try XCTUnwrap(source.range(of: "return Unmanaged.passUnretained(event)",
                                                range: start.upperBound..<source.endIndex))
            XCTAssertTrue(source[start.upperBound..<end.lowerBound].contains("clearLastExpansion()"))
        }
        let observer = try XCTUnwrap(source.range(of: "private func installAppSwitchObserver()"))
        XCTAssertTrue(source[observer.upperBound...].contains("TextInjectionPipeline.shared.clearLastExpansion()"))
        let pause = try XCTUnwrap(source.range(of: "public var isEnabled: Bool"))
        let end = try XCTUnwrap(source.range(of: "UserDefaults.standard.set(!newValue", range: pause.upperBound..<source.endIndex))
        XCTAssertTrue(source[pause.upperBound..<end.lowerBound].contains("cancelCurrentInjection()"))
    }

    func testRangeCorroborationCannotOverrideAPartialCharacterRefusal() {
        let executor = EraseExecutor(textAccess: .init(
            value: { _ in "👩‍💻" }, selectedRange: { _ in NSRange(location: 2, length: 0) },
            stringForRange: { _, _ in "👩" }
        ))
        XCTAssertTrue(executor.evaluateErasePrecondition(
            plan: ErasePlan(text: "👩"), element: AXUIElementCreateApplication(1234),
            retryOnMismatch: false, insertionPointFollowsExpectedText: true
        ).blocksErase)
    }
}
