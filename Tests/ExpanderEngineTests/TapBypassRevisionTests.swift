import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

/// A real key that reaches the field while an operation is in flight must move the input revision,
/// whatever the tap decided about matching it. Only a key swallowed into type-ahead never reaches the
/// field (`TapTypeAheadRevisionTests`). Matching is suspended for the whole of an AI delivery and
/// the replace confirmer's focus write is guarded by that revision, so a focus-moving key (⌘L, ⌘T,
/// Tab) typed then used to be invisible to it: the bypass branches returned the key before anything
/// noted it.
final class TapBypassRevisionTests: TapEventTestCase {

    private var claimed: (operation: InjectCompletionGuard, revision: UInt64)!

    override func setUp() {
        super.setUp()
        claimed = pipeline.claimOperationForTesting()
    }

    override func tearDown() {
        pipeline.cancelCurrentInjection()
        claimed = nil
        super.tearDown()
    }

    private var stillCurrent: Bool {
        pipeline.operationIsCurrentForTesting(
            claimed.operation, revision: claimed.revision
        )
    }

    func testAKeyTypedWhileMatchingIsSuspendedMovesTheRevision() {
        let suspension = engine.suspendMatching(reason: "test")
        defer { suspension.release() }
        key("a")
        XCTAssertFalse(stillCurrent, "the suspended branch passed a real key to the field unnoted")
    }

    func testAFocusMovingChordWhileMatchingIsSuspendedMovesTheRevision() {
        let suspension = engine.suspendMatching(reason: "test")
        defer { suspension.release() }
        key("l", keyCode: Int64(kVK_ANSI_L), flags: .maskCommand)
        XCTAssertFalse(stillCurrent)
    }

    func testTabWhileMatchingIsSuspendedMovesTheRevision() {
        let suspension = engine.suspendMatching(reason: "test")
        defer { suspension.release() }
        key("\t", keyCode: Int64(kVK_Tab))
        XCTAssertFalse(stillCurrent)
    }

    func testAKeyTypedWhileTheEngineIsDisabledMovesTheRevision() {
        engine.lock.lock()
        engine._isEnabled = false
        engine.lock.unlock()
        key("a")
        XCTAssertFalse(stillCurrent)
    }

    func testAnAutorepeatKeyMovesTheRevision() {
        key("a", autorepeat: true)
        XCTAssertFalse(stillCurrent)
    }

    func testABufferResettingKeyMovesTheRevision() {
        key("", keyCode: Int64(kVK_Escape))
        XCTAssertFalse(stillCurrent)
        let chord = pipeline.claimOperationForTesting()
        key("t", keyCode: Int64(kVK_ANSI_T), flags: .maskCommand)
        XCTAssertFalse(pipeline.operationIsCurrentForTesting(
            chord.operation, revision: chord.revision
        ))
    }

    /// A synthetic key is DevType's own output and never counts.
    func testASyntheticKeyLeavesTheRevisionAlone() {
        let suspension = engine.suspendMatching(reason: "test")
        defer { suspension.release() }
        key("a", synthetic: true)
        XCTAssertTrue(stillCurrent)
    }
}
