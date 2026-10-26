import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

/// The type-ahead hold gives up (past its deadline, on a key whose order it cannot honour, on a
/// click). If the in-flight inject has not yet written anything, the terminator the tap swallowed
/// for it must go back to the field FIRST, then the keys the hold released, in the order the user
/// typed them — and the inject must be abandoned. Before, the inject was abandoned and the
/// terminator was never typed: the held keys were already in the field, so replaying it later
/// would have been out of order, and the refusal path (correctly) no longer replayed it.
///
/// Everything here runs through the real `handleTapEvent` and the shared pipeline ledger the tap
/// writes. The two posters are recorders: no test posts a keystroke to the machine it runs on.
final class TapHoldSurrenderTests: TapEventTestCase {

    private let terminator = SwallowedKey(didSwallow: true, unicode: " ", keyCode: Int64(kVK_Space), flags: [])
    private var claimed: (operation: InjectCompletionGuard, revision: UInt64)!
    /// Everything posted back to the field, in order, each with whether the in-flight inject was
    /// still current at the moment it was posted.
    private var posted: [(what: String, injectStillCurrent: Bool)] = []

    /// The hold's clock, stepped by hand: a deadline is passed by advancing it, never by sleeping.
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() {
        super.setUp()
        engine.now = { [unowned self] in clock }
        engine.swallowedKeyPoster = { [unowned self] key in
            posted.append(("terminator:" + key.unicode, stillCurrent))
        }
        engine.typeAheadReplayPoster = { [unowned self] character in
            posted.append((character, stillCurrent))
        }
        beginDelivery()
    }

    override func tearDown() {
        abandonExpansion()
        pipeline.cancelCurrentInjection()
        claimed = nil
        super.tearDown()
    }

    /// The tap claims the expansion, swallows `terminator`, and the pipeline claims its operation.
    private func beginDelivery(holdWindow: TimeInterval = TypeAheadBuffer.defaultDeadline, capacity: Int = TypeAheadBuffer.defaultCapacity) {
        abandonExpansion()
        XCTAssertTrue(engine.tryBeginExpansion())
        engine.lock.lock()
        engine._typeAhead = TypeAheadBuffer(capacity: capacity, holdWindow: holdWindow)
        engine._typeAhead.beginExpansion(focusPID: 735, now: clock)
        engine.lock.unlock()
        pipeline.oweSwallowedKey(terminator)
        claimed = pipeline.claimOperationForTesting()
        posted = []
    }

    private var stillCurrent: Bool {
        pipeline.operationIsCurrentForTesting(claimed.operation, revision: claimed.revision)
    }

    private var order: [String] { posted.map(\.what) }

    private func surrenderByDeadline(held: String) {
        beginDelivery(holdWindow: 0.04)
        for character in held { XCTAssertNil(key(String(character)), "inside the window the key is held") }
        clock += 0.08
    }

    // Note: `surrenderByDeadline` re-arms the delivery, so a test that needs the first write to
    // have begun arms its own (see `testSurrenderAfterTheFirstWriteKeepsTodaysBehaviour`).

    // MARK: - The terminator goes back first

    func testSurrenderBeforeAnyWriteReplaysTheTerminatorAheadOfTheHeldKeys() {
        surrenderByDeadline(held: "ab")
        let passedThrough = key("c") != nil
        XCTAssertTrue(passedThrough, "the key that forced the surrender passes through, last")
        XCTAssertEqual(order, ["terminator: ", "a", "b"],
                       "terminator first, then the held keys, in the order typed")
        XCTAssertEqual(posted.map(\.injectStillCurrent), [false, false, false],
                       "the inject is already abandoned by the time the first key goes back")
        XCTAssertFalse(pipeline.beginMutationForTesting(claimed.operation, revision: claimed.revision),
                       "an abandoned inject can never start writing")
    }

    func testSurrenderWithNothingHeldStillReplaysTheTerminator() {
        key("", keyCode: Int64(kVK_LeftArrow))
        XCTAssertEqual(order, ["terminator: "])
        XCTAssertFalse(stillCurrent)
    }

    /// `Return`, `Tab`, a chord, backspace and a capacity overflow all end the hold the same way.
    func testEveryKindOfSurrenderPutsTheTerminatorBackFirst() {
        let causes: [(String, () -> Void)] = [
            ("return", { self.key("\r", keyCode: Int64(kVK_Return)) }),
            ("tab", { self.key("\t", keyCode: Int64(kVK_Tab)) }),
            ("chord", { self.key("k", keyCode: Int64(kVK_ANSI_K), flags: .maskCommand) }),
            ("backspace", { self.key("\u{7F}", keyCode: Int64(kVK_Delete)) }),
            ("arrow", { self.key("", keyCode: Int64(kVK_RightArrow)) })
        ]
        for (name, cause) in causes {
            beginDelivery()
            XCTAssertNil(key("x"), name)
            cause()
            XCTAssertEqual(order, ["terminator: ", "x"], name)
            XCTAssertFalse(stillCurrent, name)
        }
        beginDelivery(capacity: 1)
        XCTAssertNil(key("x"))
        key("y")
        XCTAssertEqual(order, ["terminator: ", "x"], "capacity overflow")
        XCTAssertFalse(stillCurrent, "capacity overflow")
    }

    func testAClickSurrendersLikeAKey() {
        XCTAssertNil(key("x"))
        click()
        XCTAssertEqual(order, ["terminator: ", "x"], "the click lands after both, at the caret they were typed at")
        XCTAssertFalse(stillCurrent)
    }

    /// A click with no expansion in flight is not a surrender and owes nothing.
    func testAClickOutsideAnExpansionReplaysNothing() {
        abandonExpansion()
        posted = []
        click()
        XCTAssertEqual(order, [])
    }

    // MARK: - Once the pipeline is writing, nothing changes

    func testSurrenderAfterTheFirstWriteKeepsTodaysBehaviour() {
        beginDelivery(holdWindow: 0.04)
        for character in "ab" { XCTAssertNil(key(String(character))) }
        XCTAssertTrue(pipeline.beginMutationForTesting(claimed.operation, revision: claimed.revision))
        clock += 0.08
        key("c")
        XCTAssertEqual(order, ["a", "b"], "mid-erase the terminator's place is undefined: only the held keys go back")
        XCTAssertFalse(stillCurrent, "and the keys that reached the field still abort the rest of the erase")
    }

    // MARK: - Exactly once

    /// The refusal that follows an abandoned inject must not type the terminator a second time.
    func testASurrenderedTerminatorIsNotReinjectedByARefusal() {
        key("", keyCode: Int64(kVK_LeftArrow))
        XCTAssertEqual(order, ["terminator: "])
        XCTAssertFalse(pipeline.reinjectSwallowedKey(terminator),
                       "already put back ahead of the held keys — posting it again would type it twice")
    }

    /// Focus left the app the keys were held for: nothing is replayed into the app that took focus,
    /// and the hold is not surrendered — the inject's own focus gates judge a target that moved,
    /// and the terminator stays with the refusal that checks the target before replaying it.
    func testAFocusChangeDropsTheHeldKeysWithoutSurrenderingTheHold() {
        XCTAssertNil(key("x"))
        setFrontmost(pid: 999, bundleID: "com.example.Other")
        key("y")
        XCTAssertEqual(order, [], "replaying either into the app that took focus would leak the user's typing")
        XCTAssertFalse(stillCurrent, "the keys that reached another app still move the revision")
        let next = pipeline.claimOperationForTesting()
        XCTAssertTrue(pipeline.operationIsCurrentForTesting(next.operation, revision: next.revision),
                      "no surrender is latched: the next inject is not cancelled at birth")
    }

    /// The field report this guards: a fill-in snippet opens DevType's own panel while the
    /// expansion is in flight. The first key or click in the panel (past the deadline, or simply
    /// in another process) used to surrender the hold; the inject the panel completes was then
    /// cancelled at birth and its terminator lost — every fill-in snippet refused.
    func testTypingInDevTypesOwnPanelNeitherSurrendersNorCancelsTheInjectItCompletes() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        setFrontmost(pid: ownPID, bundleID: "com.devtype.app")
        clock += 1
        key("v")
        key("\r", keyCode: Int64(kVK_Return))
        click()
        XCTAssertEqual(order, [], "nothing typed in the panel is posted back into the source app")
        // The panel completes: focus returns and the pipeline claims the inject that pastes.
        setFrontmost(pid: 735, bundleID: "com.apple.Safari")
        let inject = pipeline.claimOperationForTesting()
        XCTAssertTrue(pipeline.operationIsCurrentForTesting(inject.operation, revision: inject.revision),
                      "the inject the panel completes must not be cancelled at birth")
        XCTAssertTrue(pipeline.beginMutationForTesting(inject.operation, revision: inject.revision),
                      "and it may write")
    }

    // MARK: - What does not surrender

    func testKeysHeldInsideTheWindowReplayNothingAndLeaveTheInjectCurrent() {
        XCTAssertNil(key("a"))
        XCTAssertNil(key("b"))
        XCTAssertEqual(order, [])
        XCTAssertTrue(stillCurrent)
        XCTAssertTrue(pipeline.beginMutationForTesting(claimed.operation, revision: claimed.revision))
    }

    func testOurOwnSyntheticKeysNeverSurrender() {
        key("\u{8}", keyCode: Int64(kVK_Delete), synthetic: true)
        XCTAssertEqual(order, [])
        XCTAssertTrue(stillCurrent, "our own erase must not abort itself")
    }

    // MARK: - The erase cannot run over a key the tap saw reach the field

    /// A key with no character and no caret move the tap can name (a dead key's marked accent, an
    /// F-key) reached the field. It used to leave the revision alone, so an erase planned against
    /// the old field ran over it.
    func testACharacterlessKeyThatReachesTheFieldMovesTheRevision() {
        // Surrender before any write.
        deadKey()
        XCTAssertFalse(stillCurrent)

        // After the first write begins the surrender no longer cancels, but the revision still moves.
        beginDelivery()
        XCTAssertTrue(pipeline.beginMutationForTesting(claimed.operation, revision: claimed.revision))
        deadKey()
        XCTAssertFalse(stillCurrent, "a mid-erase dead key must abort the rest of the erase")
    }

    func testACharacterlessKeyDoesNotCostTheUndoCounters() {
        let before = pipeline.deliveryInputUnitsForTesting
        deadKey()
        XCTAssertEqual(pipeline.deliveryInputUnitsForTesting, before)
    }

    /// A keyDown that produces no character and is not navigation or a chord — what a dead key
    /// looks like to the tap (the accent only shows once the next key composes it). A synthetic
    /// event cannot be given an empty unicode string (the layout fills it in from the key code),
    /// so this uses a key the layout gives none: Fn.
    private func deadKey() {
        key("", keyCode: Int64(kVK_Function))
    }

    /// The ordering proof for "no text key can reach the field between the trigger and the erase":
    /// for each way a typed key can leave the hold, the revision has already moved before the
    /// first replayed character is posted, so the erase's own continue-checks refuse.
    func testNoTextKeyReachesTheFieldBeforeTheInjectIsAbandoned() {
        let causes: [(String, () -> Void)] = [
            ("deadline", { self.clock += 0.08; self.key("y") }),
            ("return", { self.key("\r", keyCode: Int64(kVK_Return)) }),
            ("backspace", { self.key("\u{7F}", keyCode: Int64(kVK_Delete)) }),
            ("chord", { self.key("k", keyCode: Int64(kVK_ANSI_K), flags: .maskCommand) })
        ]
        for (name, cause) in causes {
            beginDelivery(holdWindow: 0.04)
            XCTAssertNil(key("x"), name)
            cause()
            XCTAssertFalse(posted.isEmpty, name)
            XCTAssertTrue(posted.allSatisfy { !$0.injectStillCurrent }, "\(name): \(posted)")
        }
    }
}
