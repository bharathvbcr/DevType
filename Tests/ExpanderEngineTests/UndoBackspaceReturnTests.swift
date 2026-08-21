import XCTest
@testable import ExpanderEngine

/// Backspace-after-expansion hardening — pieces not covered by
/// `UndoBackspaceReinjectTests` (§3.1d predicate, §3.1e exit classifier) or
/// `DiagnosticLogRetrievalTests` (§9.1 mirror / log window):
///
///  1. The undo window is user-tunable within hard bounds
///     (`InjectTiming.clampedUndoWindow`, `LastExpansion.isFresh`).
///  2. The §3.1d delivery-input counter is scoped to one delivery
///     (`beginDeliveryWindow` discards stale counts).
///  3. `DiagnosticReport.makeLogStore` falls back to the current-process store when the
///     system-wide scope is refused, so previous-launch history degrades gracefully.
final class UndoBackspaceReturnTests: XCTestCase {

    // MARK: - Undo window bounds

    func testClampPassthroughInsideBounds() {
        XCTAssertEqual(InjectTiming.clampedUndoWindow(1.0), 1.0)
        XCTAssertEqual(InjectTiming.clampedUndoWindow(2.0), 2.0)
        XCTAssertEqual(InjectTiming.clampedUndoWindow(4.5), 4.5)
    }

    func testClampSnapsOutOfBoundsValues() {
        XCTAssertEqual(InjectTiming.clampedUndoWindow(0.1), InjectTiming.undoWindowFloor)
        XCTAssertEqual(InjectTiming.clampedUndoWindow(60), InjectTiming.undoWindowCeiling)
    }

    func testClampFallsBackToDefaultOnGarbage() {
        XCTAssertEqual(InjectTiming.clampedUndoWindow(0), InjectTiming.undoExpansionWindow)
        XCTAssertEqual(InjectTiming.clampedUndoWindow(-3), InjectTiming.undoExpansionWindow)
        XCTAssertEqual(InjectTiming.clampedUndoWindow(.infinity), InjectTiming.undoExpansionWindow)
        XCTAssertFalse(InjectTiming.clampedUndoWindow(.nan).isNaN)
    }

    func testFreshnessHonoursAnExplicitWindow() {
        let record = TextInjectionPipeline.LastExpansion(
            erasePlan: .empty,
            injectedText: "Expanded text",
            triggerText: "xt",
            bundleID: nil,
            timestamp: Date().addingTimeInterval(-3)
        )
        // Shipped default is 2 s: a 3-second-old record is stale…
        XCTAssertFalse(record.isFresh(window: InjectTiming.undoExpansionWindow))
        // …but a user who raised the window to 5 s gets their undo back.
        XCTAssertTrue(record.isFresh(window: 5.0))
    }

    // MARK: - §3.1d delivery-window scoping

    func testDeliveryWindowDrainsIntoTheRecordNotPastIt() {
        // The counter must be scoped to one delivery: increments outside a window are
        // discarded at the next begin, never attributed to a later expansion's record.
        let pipeline = TextInjectionPipeline()
        pipeline.noteDeliveryInput(units: 5) // outside any window — must be discarded
        pipeline.beginDeliveryWindow()
        XCTAssertEqual(pipeline.deliveryInputUnitsForTesting, 0,
                       "beginDeliveryWindow discards stale counts")
        pipeline.noteDeliveryInput(units: 2)
        XCTAssertEqual(pipeline.deliveryInputUnitsForTesting, 2)
        pipeline.beginDeliveryWindow()       // new delivery discards the previous count
        XCTAssertEqual(pipeline.deliveryInputUnitsForTesting, 0,
                       "each delivery opens with a clean window")
    }

    // MARK: - Log-store construction fallback

    func testMakeLogStoreFallsBackWhenSystemScopeIsRefused() {
        // The system scope can be refused on locked-down hosts; construction must still
        // succeed via the current-process store so the report keeps its log section.
        do {
            let store = try DiagnosticReport.makeLogStore(preferSystemScope: true)
            _ = store.position(date: Date().addingTimeInterval(-60))
        } catch {
            XCTFail("fallback chain must not throw outright: \(error)")
        }
        XCTAssertNoThrow(try DiagnosticReport.makeLogStore(preferSystemScope: false))
    }
}
