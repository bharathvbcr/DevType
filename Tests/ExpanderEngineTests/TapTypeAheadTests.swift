import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

/// Keys typed while an expansion is in flight: what they do to the quiescence guard that decides
/// whether the expansion may still run, and what the buffer knows of them afterwards.
final class TapTypeAheadTests: TapEventTestCase {

    /// A key typed while an expansion is in flight is *held* by the type-ahead buffer and never
    /// reaches the field, so it cannot invalidate the erase the expansion is about to perform.
    /// It used to mark the input clock anyway, and the pre-inject quiescence check then aborted the
    /// expansion (`User input after arm`) for any typist faster than the AX probe.
    func testTypeAheadKeyDoesNotAbortTheExpansionItIsWaitingOn() {
        XCTAssertTrue(engine.tryBeginExpansion())
        defer { abandonExpansion() }
        let armed = engine.inputClock.arm()
        let result = key("a")
        XCTAssertNil(result, "the key is swallowed into type-ahead")
        XCTAssertEqual(engine.inputClock.decide(armed), .proceed)
        XCTAssertEqual(abandonExpansion(), "a")
    }

    /// A key that *does* reach the field mid-delivery still has to abort it.
    func testPassThroughKeyDuringDeliveryStillAbortsTheExpansion() {
        XCTAssertTrue(engine.tryBeginExpansion())
        defer { abandonExpansion() }
        let armed = engine.inputClock.arm()
        key("", keyCode: Int64(kVK_LeftArrow))
        if case .abort = engine.inputClock.decide(armed) { return }
        XCTFail("an arrow key moves the caret under the erase and must abort the expansion")
    }

    func testClickDuringDeliveryStillAbortsTheExpansion() {
        XCTAssertTrue(engine.tryBeginExpansion())
        defer { abandonExpansion() }
        let armed = engine.inputClock.arm()
        click()
        if case .abort = engine.inputClock.decide(armed) { return }
        XCTFail("a click moves the caret and must abort the expansion")
    }

    /// Retraction undoes one mark and nothing else: a later key's mark must survive it.
    func testRetractingAnOlderMarkKeepsALaterOne() {
        let clock = InputClock(now: { 0 })
        let first = clock.mark(at: 10)
        let second = clock.mark(at: 20)
        clock.retract(first)
        XCTAssertEqual(clock.lastInputAt, 20)
        clock.retract(second)
        XCTAssertEqual(clock.lastInputAt, 10, "the second mark restores what stood before it")
    }

    // MARK: - Characters replayed from type-ahead

    /// Replayed characters are posted as synthetic events, which the callback ignores, so the
    /// buffer never sees them. Two triggers typed back to back lose the first characters of the
    /// second one — they were typed during the first expansion's delivery.
    func testReplayedTypeAheadSeedsTheBufferForTheNextTrigger() {
        XCTAssertTrue(engine.tryBeginExpansion())
        type("`s")
        var posted: [String] = []
        engine.typeAheadReplayPoster = { posted.append($0) }
        engine.endExpansion()
        XCTAssertEqual(posted.joined(), "`s")
        type("lm")
        XCTAssertTrue(hasHold, "`s was replayed into the field; `lm completes the trigger")
    }

    func testReplayDroppedForAFocusChangeDoesNotSeedTheBuffer() {
        XCTAssertTrue(engine.tryBeginExpansion())
        type("`s")
        var posted: [String] = []
        engine.typeAheadReplayPoster = { posted.append($0) }
        setFrontmost(pid: 999, bundleID: "com.apple.Notes")
        engine.endExpansion()
        XCTAssertTrue(posted.isEmpty, "characters typed in Safari are not replayed into Notes")
        type("lm")
        XCTAssertFalse(hasHold)
        XCTAssertEqual(ring, "lm")
    }
}
