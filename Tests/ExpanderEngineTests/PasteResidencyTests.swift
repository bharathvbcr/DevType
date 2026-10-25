import AppKit
import CoreGraphics
import XCTest
@testable import ExpanderEngine

// MARK: - The payload stays readable for its residency, and nothing waits on us to read it
//
// Field report, build 1.3.0 (389): Safari 19 unverified holds, longest 475 ms; Chrome 7, longest
// 462 ms; neither with a stall extension. Every one of those holds ended on the 450 ms residency
// floor, which is a timer. Whether a host ever read *later* than that was not observed — the
// maximum is the floor itself — so the answer here is the floor plus the stall probe, and a
// payload that is concrete data on the board: lazily providing it (to see the host's read) made
// every host's read depend on this process's main thread, which makes synchronous AX calls into
// that same host (see `PasteReentrancyAndQuitTests`).
//
// These drive the real `pasteViaClipboard` → ⌘V → hold → release sequence end to end, on a
// uniquely named pasteboard, with ⌘V posting and the target check stubbed. The test plays the
// host.
final class PasteResidencyTests: XCTestCase {
    struct NoLayout: KeyboardLayoutProviding {
        func currentSourceID() -> String? { nil }
        func keyCode(for character: Character) -> CGKeyCode? { nil }
    }

    final class Harness {
        let board = NSPasteboard.withUniqueName()
        let broker: PasteboardBroker
        /// CGEvents the ⌘V chord has posted so far (Command down, V down, V up, Command up).
        final class Posted { var events = 0 }
        let posted = Posted()

        init(
            snapshot: ((NSPasteboard) -> PasteboardBroker.PasteboardSnapshot?)? = nil,
            verifier: DeliveryVerifier? = nil,
            targetCurrent: ((PasteboardBroker.PasteTarget, Bool, Bool) -> Bool)? = nil
        ) {
            let board = board
            let posted = posted
            let hid = HIDKeyPoster(
                commandEventIO: .init(canPost: { true }, post: { _ in posted.events += 1 }, pause: {}),
                layout: KeyboardLayoutState(provider: NoLayout())
            )
            var environment = PasteboardBroker.Environment()
            environment.pasteboard = { board }
            environment.canPostEvents = { true }
            environment.secureInputActive = { false }
            environment.targetCurrent = targetCurrent ?? { _, _, _ in true }
            if let snapshot { environment.snapshot = snapshot }
            broker = PasteboardBroker(
                hid: hid, verifier: verifier ?? DeliveryVerifier.shared,
                timing: InjectTimingStore(), environment: environment
            )
        }

        deinit { board.releaseGlobally() }

        func seedUserClipboard(_ text: String) {
            board.clearContents()
            board.setString(text, forType: .string)
        }

        /// Publishes `text` and posts ⌘V; returns once ⌘V has gone out, with the time it did.
        @discardableResult
        func paste(_ text: String, in test: XCTestCase) -> TimeInterval {
            let posted = test.expectation(description: "⌘V posted for \(text)")
            var postedAt = 0.0
            broker.pasteViaClipboard(
                text: text, expectedText: nil, baseline: nil, focus: .resolved(nil),
                completeBeforeRestore: true
            ) { result in
                XCTAssertEqual(result, .unavailable, "an unverifiable paste reports `unavailable`")
                postedAt = InputClock.monotonicNow()
                posted.fulfill()
            }
            test.wait(for: [posted], timeout: 5)
            return postedAt
        }

        /// What a host would paste right now. Run off the main thread, as a host process would:
        /// a lazily provided payload is fulfilled by the owner's main run loop, which this call
        /// must not be blocking.
        func hostRead(in test: XCTestCase) -> String? {
            hostRead(in: test) { $0.string(forType: .string) }
        }

        /// A host read by any API, off the main thread, with how long it waited for the owner.
        @discardableResult
        func hostRead<Value>(in test: XCTestCase, _ read: @escaping (NSPasteboard) -> Value) -> Value {
            hostReadTimed(in: test, read).value
        }

        func hostReadTimed<Value>(
            in test: XCTestCase, _ read: @escaping (NSPasteboard) -> Value
        ) -> (value: Value, waited: TimeInterval) {
            let done = test.expectation(description: "host read")
            var value: Value?
            var waited = 0.0
            let board = board
            DispatchQueue.global().async {
                let start = InputClock.monotonicNow()
                value = read(board)
                waited = InputClock.monotonicNow() - start
                done.fulfill()
            }
            test.wait(for: [done], timeout: 5)
            return (value!, waited)
        }
    }

    /// Runs the main run loop (where the broker's timers live) until `deadline`.
    private func pump(until deadline: TimeInterval) {
        while InputClock.monotonicNow() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Residency

    func testTheGateWaitsOnlyForOurOwnPendingPayloadInsideItsLease() {
        func gate(ours: Bool = true, lease: TimeInterval? = 100.45, now: TimeInterval) -> TimeInterval {
            PasteboardBroker.publicationGateWait(boardStillOurs: ours, leaseDeadline: lease, now: now)
        }
        XCTAssertEqual(gate(now: 100.10), 0.35, accuracy: 1e-9)
        XCTAssertEqual(gate(now: 100.45), 0)
        XCTAssertEqual(gate(now: 130), 0, "never a negative interval")
        XCTAssertEqual(gate(ours: false, now: 100.10), 0, "the user's copy is not ours to protect")
        XCTAssertEqual(gate(lease: nil, now: 100.10), 0, "⌘V never went out")
    }

    /// The payload is on the board for the whole floor and gone — the user's clipboard back — after.
    /// (A host that reads later than the floor reads the user's clipboard; none was ever observed
    /// doing so, and the cost of holding longer is the user's own ⌘V pasting the snippet.)
    func testThePayloadStaysThroughTheFloorAndTheUsersClipboardReturnsAfter() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        let postedAt = harness.paste("SNIPPET", in: self)
        let owned = harness.board.changeCount

        pump(until: postedAt + 0.30)
        XCTAssertEqual(harness.hostRead(in: self), "SNIPPET")
        XCTAssertEqual(harness.board.changeCount, owned, "reading does not move the count, and is not a release")

        pump(until: postedAt + 0.90)
        XCTAssertNotEqual(harness.board.changeCount, owned)
        XCTAssertEqual(harness.board.string(forType: .string), "USER-OLD")
    }

    /// A reader gets the payload without this process's main thread: it is data on the board, not a
    /// promise this process must fulfil. A provider-backed payload made this read wait for the whole
    /// block (measured in a separate process: 1.5 s of blocked main was a 1.57 s read), and main
    /// is what makes synchronous AX calls into the host that is reading.
    func testAHostReadDoesNotWaitForOurMainThread() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        harness.paste("SNIPPET", in: self)

        let done = expectation(description: "host read")
        var value: String?
        var waited = 0.0
        let board = harness.board
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.05)   // main is blocked by now
            let start = InputClock.monotonicNow()
            value = board.string(forType: .string)
            waited = InputClock.monotonicNow() - start
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.30)   // main busy, as inside a synchronous AX call
        wait(for: [done], timeout: 5)

        XCTAssertEqual(value, "SNIPPET")
        XCTAssertLessThan(waited, 0.15, "the reader waited \(waited) s for our main thread")
    }

    // MARK: - The publication gate

    /// What a second expansion's paste saw while the first payload was still inside its lease.
    private final class Refusals {
        var cancelled = false
        var targetChanged = false
        var continueCalls = 0
    }

    func testTheGateIsReportedAndLiftsWhenTheLeaseEnds() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        XCTAssertEqual(harness.broker.publicationGateRemaining(), 0, "nothing pending")
        let postedAt = harness.paste("SNIPPET", in: self)

        let remaining = harness.broker.publicationGateRemaining()
        XCTAssertGreaterThan(remaining, 0.20)
        XCTAssertLessThanOrEqual(remaining, InjectTiming.unverifiedPayloadResidencyCeiling)

        pump(until: postedAt + 0.90)
        XCTAssertEqual(harness.broker.publicationGateRemaining(), 0, "the lease is over and the board released")
    }

    /// The pipeline has already erased the trigger when it pastes. A paste that is going to be
    /// refused must say so now, not after sitting out the previous payload's lease.
    func testARefusedPasteDoesNotWaitBehindAnotherPayload() {
        let refusals = Refusals()
        let harness = Harness(targetCurrent: { _, _, _ in !refusals.targetChanged })
        harness.seedUserClipboard("USER-OLD")
        harness.paste("FIRST", in: self)
        XCTAssertGreaterThan(harness.broker.publicationGateRemaining(), 0.2)

        for (label, arm) in [
            ("cancelled", { refusals.cancelled = true }),
            ("target changed", { refusals.cancelled = false; refusals.targetChanged = true }),
        ] as [(String, () -> Void)] {
            arm()
            let refused = expectation(description: "\(label) refusal reported")
            let askedAt = InputClock.monotonicNow()
            var result: PasteboardBroker.PasteDeliveryResult?
            var reportedAt = 0.0
            harness.broker.pasteViaClipboard(
                text: "SECOND", expectedText: nil, baseline: nil, focus: .resolved(nil),
                shouldContinue: { !refusals.cancelled }
            ) {
                result = $0
                reportedAt = InputClock.monotonicNow()
                refused.fulfill()
            }
            wait(for: [refused], timeout: 5)
            XCTAssertEqual(result, .notPosted, label)
            XCTAssertLessThan(reportedAt - askedAt, 0.15,
                              "a \(label) paste waited \(reportedAt - askedAt) s behind the first payload's lease")
        }
        XCTAssertEqual(harness.hostRead(in: self), "FIRST", "a refused paste never touches the board")
    }

    /// A paste that waited is judged at the moment it publishes: a refusal that arises during the
    /// wait still refuses, and nothing is written over the first payload.
    func testAPasteRunsItsRefusalsAgainAfterTheWait() {
        let refusals = Refusals()
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        let firstPostedAt = harness.paste("FIRST", in: self)

        let done = expectation(description: "second paste ended")
        var result: PasteboardBroker.PasteDeliveryResult?
        harness.broker.pasteViaClipboard(
            text: "SECOND", expectedText: nil, baseline: nil, focus: .resolved(nil),
            shouldContinue: {
                refusals.continueCalls += 1
                return !refusals.cancelled
            }
        ) {
            result = $0
            done.fulfill()
        }
        // Not refused when it asked; cancelled while it waits for the first payload's lease.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { refusals.cancelled = true }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result, .notPosted)
        XCTAssertGreaterThanOrEqual(refusals.continueCalls, 2, "the refusal was not re-made after the wait")
        XCTAssertEqual(harness.posted.events, 4, "a second ⌘V went out for a paste cancelled during the wait")
        pump(until: firstPostedAt + 0.9)
        XCTAssertEqual(harness.board.string(forType: .string), "USER-OLD")
    }

    /// Restoring the trigger after a failed paste replaces the same expansion's own payload. It must
    /// not queue behind that payload's lease — and it must not forget the user's real clipboard,
    /// which is what `invalidatePendingRestore()` would do.
    func testAPasteSupersedingItsOwnPayloadDoesNotWaitAndKeepsTheUsersClipboard() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        harness.paste("FIRST", in: self)

        let posted = expectation(description: "restore paste posted")
        let askedAt = InputClock.monotonicNow()
        var postedAt = 0.0
        harness.broker.pasteViaClipboard(
            text: "TRIGGER", expectedText: nil, baseline: nil, focus: .resolved(nil),
            completeBeforeRestore: true, publicationGate: .supersedesOwnPayload
        ) { _ in
            postedAt = InputClock.monotonicNow()
            posted.fulfill()
        }
        wait(for: [posted], timeout: 5)
        XCTAssertLessThan(postedAt - askedAt, 0.25, "waited \(postedAt - askedAt) s on its own expansion's lease")
        XCTAssertEqual(harness.hostRead(in: self), "TRIGGER")

        pump(until: postedAt + 1.0)
        XCTAssertEqual(harness.board.string(forType: .string), "USER-OLD",
                       "the user's clipboard, not FIRST or TRIGGER, comes back")
    }

    /// Two expansions back to back: #2 started while #1's payload was inside its lease. Writing
    /// #2's text over the board makes #1's host paste #2's text and loses #1.
    func testSecondExpansionDoesNotOverwriteAPayloadStillInsideItsLease() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        let firstPostedAt = harness.paste("FIRST", in: self)

        pump(until: firstPostedAt + 0.10)
        var secondPostedAt = 0.0
        let secondPosted = expectation(description: "second ⌘V posted")
        harness.broker.pasteViaClipboard(
            text: "SECOND", expectedText: nil, baseline: nil, focus: .resolved(nil),
            completeBeforeRestore: true
        ) { _ in
            secondPostedAt = InputClock.monotonicNow()
            secondPosted.fulfill()
        }

        pump(until: firstPostedAt + 0.30)
        XCTAssertEqual(harness.hostRead(in: self), "FIRST",
                       "the first host's late read pasted the second expansion's text")

        wait(for: [secondPosted], timeout: 5)
        XCTAssertEqual(harness.hostRead(in: self), "SECOND", "the second expansion still pastes its own text")

        pump(until: secondPostedAt + 1.10)
        XCTAssertEqual(harness.board.string(forType: .string), "USER-OLD",
                       "the user's clipboard — not FIRST — is what comes back at the end")
    }

    // MARK: - Type-ahead replay

    /// `EventTapEngine.endExpansion` replays the keystrokes it held when the pipeline's completion
    /// fires. That is only ordering-safe if completion can never precede ⌘V: a replayed key is an
    /// HID post, and everything posted after the chord is queued behind it in the host's own event
    /// stream — whenever the host gets round to *reading the board*. (Completion at 350 ms with a
    /// read at 700 ms does not transpose anything; the key is behind the paste either way.)
    /// The held keys' surrender deadline matters only before ⌘V, where this does not apply.
    ///
    /// Characterization — it passes against the unmodified code. It pins the one property the
    /// replay's ordering rests on, in both completion paths.
    func testCompletionIsNeverReportedBeforeTheWholeChordWasPosted() {
        // Path 1: nothing to verify; completion is reported right after ⌘V.
        let direct = Harness()
        direct.seedUserClipboard("USER-OLD")
        var chordsAtCompletion = -1
        let reported = expectation(description: "completion")
        direct.broker.pasteViaClipboard(
            text: "SNIPPET", expectedText: nil, baseline: nil, focus: .resolved(nil),
            completeBeforeRestore: true
        ) { _ in
            chordsAtCompletion = direct.posted.events
            reported.fulfill()
        }
        wait(for: [reported], timeout: 5)
        XCTAssertEqual(chordsAtCompletion, 4, "completion preceded the end of the ⌘V chord")

        // Path 2: the hold loop polls AX (here: nothing readable) and gives up unverified.
        let unreadable = DeliveryVerifier(access: .init(
            focusedElement: { nil }, numberOfCharacters: { _ in nil }, selectedRange: { _ in nil },
            stringForRange: { _, _ in nil },
            observation: { DeliveryVerifier.FocusedTextObservation(value: nil, selectedText: nil, target: $0) }
        ))
        let verified = Harness(verifier: unreadable)
        verified.seedUserClipboard("USER-OLD")
        var chordsAtVerifiedCompletion = -1
        var result: PasteboardBroker.PasteDeliveryResult?
        let verifiedReported = expectation(description: "verified completion")
        verified.broker.pasteViaClipboard(
            text: "SNIPPET", expectedText: "SNIPPET", baseline: nil, focus: .resolved(nil)
        ) {
            result = $0
            chordsAtVerifiedCompletion = verified.posted.events
            verifiedReported.fulfill()
        }
        wait(for: [verifiedReported], timeout: 5)
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(chordsAtVerifiedCompletion, 4, "completion preceded the end of the ⌘V chord")
    }

    // MARK: - The user copies something themselves

    func testACopyTheUserMakesDuringTheHoldIsNeverClobbered() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        let postedAt = harness.paste("SNIPPET", in: self)

        pump(until: postedAt + 0.20)
        harness.board.clearContents()
        harness.board.setString("USER-NEW", forType: .string)
        pump(until: postedAt + 2.60)

        XCTAssertEqual(harness.board.string(forType: .string), "USER-NEW")
    }

    /// The user's ⌘C lands after the snapshot of their old clipboard was read and before our
    /// payload is written. The old snapshot is stale: restoring it later replaces their new copy.
    func testACopyThatLandsBetweenTheSnapshotAndThePublicationSurvives() {
        var injected = false
        var harness: Harness!
        harness = Harness(snapshot: { board in
            if !injected {
                injected = true
                let stale = PasteboardBroker.snapshotPasteboard(board)
                board.clearContents()
                board.setString("USER-NEW", forType: .string)
                return stale
            }
            return PasteboardBroker.snapshotPasteboard(board)
        })
        harness.seedUserClipboard("USER-OLD")
        let postedAt = harness.paste("SNIPPET", in: self)

        pump(until: postedAt + 0.20)
        XCTAssertEqual(harness.hostRead(in: self), "SNIPPET", "the expansion still pastes")
        pump(until: postedAt + 1.30)

        XCTAssertEqual(harness.board.string(forType: .string), "USER-NEW",
                       "the user's new copy was replaced by the older clipboard we had snapshotted")
    }
}
