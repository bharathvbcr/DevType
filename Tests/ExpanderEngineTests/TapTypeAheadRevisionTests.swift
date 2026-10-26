import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

/// The input revision is the hard stop every post-erase continue-check honours and
/// `EraseContinuation` never re-reads: once a key moves it, the expansion is refused with its
/// trigger already erased. A key the type-ahead buffer holds never reaches the field, so it must not
/// move it — and a key that does reach the field mid-delivery must.
///
/// The tap's gate runs these against the engine's own pipeline (`TapEventTestCase.pipeline`), the
/// ledger the engine writes.
final class TapTypeAheadRevisionTests: TapEventTestCase {

    private var claimed: (operation: InjectCompletionGuard, revision: UInt64)!

    override func setUp() {
        super.setUp()
        XCTAssertTrue(engine.tryBeginExpansion())
        claimed = pipeline.claimOperationForTesting()
    }

    override func tearDown() {
        abandonExpansion()
        pipeline.cancelCurrentInjection()
        claimed = nil
        super.tearDown()
    }

    private var stillCurrent: Bool {
        pipeline.operationIsCurrentForTesting(
            claimed.operation, revision: claimed.revision
        )
    }

    /// Held keys, however many, leave the revision and the delivery counter alone.
    func testKeysHeldForTypeAheadDoNotMoveTheRevision() {
        let unitsBefore = pipeline.deliveryInputUnitsForTesting
        for character in "abc" {
            XCTAssertNil(key(String(character)), "the key is swallowed into type-ahead")
        }
        XCTAssertTrue(stillCurrent, "a swallowed key never reaches the field: the erase it would abort is intact")
        XCTAssertEqual(pipeline.deliveryInputUnitsForTesting, unitsBefore)
    }

    func testAPassThroughKeyMovesTheRevision() {
        key("", keyCode: Int64(kVK_LeftArrow))
        XCTAssertFalse(stillCurrent, "an arrow key reaches the field mid-delivery")
    }

    func testAClickMovesTheRevision() {
        click()
        XCTAssertFalse(stillCurrent)
    }

    /// Past the hold's deadline the buffer gives up ordering: the queued keys are replayed and the
    /// key passes through, and both land in the field before whatever the expansion has yet to
    /// insert. That is input the expansion cannot be allowed to proceed over.
    func testKeysFlushedPastTheDeadlineMoveTheRevision() {
        // The hold's clock is the test's: the window is stepped past its deadline, never slept through.
        var clock = Date(timeIntervalSince1970: 1_000)
        engine.now = { clock }
        engine.lock.lock()
        engine._typeAhead = TypeAheadBuffer(holdWindow: 0.04)
        engine._typeAhead.beginExpansion(focusPID: 735, now: clock)
        engine.lock.unlock()
        var replayed: [String] = []
        engine.typeAheadReplayPoster = { replayed.append($0) }

        XCTAssertNil(key("x"), "inside the window the key is held")
        XCTAssertTrue(stillCurrent)
        clock = clock.addingTimeInterval(0.08)
        // Not `XCTAssertNotNil`: the returned reference is unretained and its event is gone by now.
        let passedThrough = key("y") != nil
        XCTAssertTrue(passedThrough, "past the deadline the key passes through")

        XCTAssertEqual(replayed, ["x"], "the held key is replayed ahead of the key that flushed it")
        XCTAssertFalse(stillCurrent)
    }
}
