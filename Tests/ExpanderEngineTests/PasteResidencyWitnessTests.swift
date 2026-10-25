import AppKit
import CoreGraphics
import XCTest
@testable import ExpanderEngine

// MARK: - A late host read must still get the snippet
//
// Field report, build 1.3.0 (389): Safari 19 unverified holds, longest 475 ms; Chrome 7, longest
// 462 ms; neither with a stall extension. Every one of those holds ended on the 450 ms residency
// floor, which is a timer — nothing proved the host had read the board. WebKit and Chromium read
// the pasteboard from a content process that can sit behind a busy UI process for far longer than
// that, and the stall probe cannot see it (the UI process still answers AX). A host that reads at
// 600 ms read the user's *previous clipboard*.
//
// These drive the real `pasteViaClipboard` → ⌘V → hold → release sequence end to end, on a
// uniquely named pasteboard, with ⌘V posting and the target check stubbed. The test plays the
// host. Reading the board is exactly what a host does, and it is the only observation that proves
// what a host would have pasted — so ownership is peeked through `changeCount`, never by reading.
final class PasteResidencyWitnessTests: XCTestCase {
    private struct NoLayout: KeyboardLayoutProviding {
        func currentSourceID() -> String? { nil }
        func keyCode(for character: Character) -> CGKeyCode? { nil }
    }

    private final class Harness {
        let board = NSPasteboard.withUniqueName()
        let broker: PasteboardBroker
        private(set) var chords = 0
        private let chordLock = NSLock()

        init(snapshot: ((NSPasteboard) -> PasteboardBroker.PasteboardSnapshot?)? = nil) {
            let board = board
            let hid = HIDKeyPoster(
                commandEventIO: .init(canPost: { true }, post: { _ in }, pause: {}),
                layout: KeyboardLayoutState(provider: NoLayout())
            )
            var environment = PasteboardBroker.Environment()
            environment.pasteboard = { board }
            environment.canPostEvents = { true }
            environment.secureInputActive = { false }
            environment.targetCurrent = { _, _, _ in true }
            if let snapshot { environment.snapshot = snapshot }
            broker = PasteboardBroker(hid: hid, timing: InjectTimingStore(), environment: environment)
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
            let done = test.expectation(description: "host read")
            var value: String?
            let board = board
            DispatchQueue.global().async {
                value = board.string(forType: .string)
                done.fulfill()
            }
            test.wait(for: [done], timeout: 5)
            return value
        }
    }

    /// Runs the main run loop (where the broker's timers live) until `deadline`.
    private func pump(until deadline: TimeInterval) {
        while InputClock.monotonicNow() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Policy, as pure functions

    private let residency = PasteboardBroker.PayloadResidency(
        postedAt: 100, unverifiedHold: 0.45, ceiling: 2.0, targetPID: nil,
        hostRespondedAtPaste: false, bundleID: nil
    )

    private func remaining(
        _ result: PasteboardBroker.PasteDeliveryResult, witness: Bool = true, read: TimeInterval? = nil,
        ours: Bool = true, now: TimeInterval
    ) -> TimeInterval {
        PasteboardBroker.witnessHoldRemaining(
            result: result, hasWitness: witness, firstRead: read, boardStillOurs: ours,
            now: now, residency: residency
        )
    }

    func testAnUnreadPayloadIsOwedUntilTheHardDeadlineAndNoLonger() {
        XCTAssertEqual(remaining(.unavailable, now: 100.50), 1.50, accuracy: 1e-9)
        XCTAssertEqual(remaining(.failed, now: 101.00), 1.00, accuracy: 1e-9)
        XCTAssertEqual(remaining(.unavailable, now: 102.00), 0)
        XCTAssertEqual(remaining(.unavailable, now: 130.00), 0, "never a negative interval")
    }

    func testAReadPayloadIsOwedOnlyTheGraceAfterTheFirstRead() {
        XCTAssertEqual(remaining(.unavailable, read: 100.60, now: 100.62),
                       InjectTiming.payloadReadGrace - 0.02, accuracy: 1e-9)
        XCTAssertEqual(remaining(.unavailable, read: 100.60, now: 100.70), 0)
    }

    func testNoWitnessEvidenceOrOwnershipMeansNoExtraHold() {
        XCTAssertEqual(remaining(.delivered, now: 100.5), 0, "AX already proved the read")
        XCTAssertEqual(remaining(.notPosted, now: 100.5), 0, "no ⌘V, nothing to be read")
        XCTAssertEqual(remaining(.unavailable, witness: false, now: 100.5), 0, "a payload with no witness keeps the timer")
        XCTAssertEqual(remaining(.unavailable, ours: false, now: 100.5), 0, "the user already replaced the board")
    }

    func testPublicationGateWaitsOnlyForOurOwnUnreadPendingPayload() {
        func gate(ours: Bool = true, witness: Bool = true, read: TimeInterval? = nil,
                  lease: TimeInterval? = 102, now: TimeInterval) -> TimeInterval {
            PasteboardBroker.publicationGateWait(
                boardStillOurs: ours, hasWitness: witness, firstRead: read, leaseDeadline: lease, now: now
            )
        }
        XCTAssertEqual(gate(now: 100.5), 1.5, accuracy: 1e-9)
        XCTAssertEqual(gate(read: 100.4, now: 100.42), InjectTiming.payloadReadGrace - 0.02, accuracy: 1e-9)
        XCTAssertEqual(gate(read: 100.4, now: 100.5), 0)
        XCTAssertEqual(gate(now: 103), 0, "bounded by the lease")
        XCTAssertEqual(gate(ours: false, now: 100.5), 0, "the user's copy is not ours to protect")
        XCTAssertEqual(gate(witness: false, now: 100.5), 0)
        XCTAssertEqual(gate(lease: nil, now: 100.5), 0, "⌘V never went out")
    }

    // MARK: - The late reader

    func testHostThatReadsAfterTheResidencyFloorStillGetsTheSnippet() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        let postedAt = harness.paste("SNIPPET", in: self)

        pump(until: postedAt + 0.70)   // well past the 450 ms floor, inside the ceiling

        XCTAssertEqual(
            harness.hostRead(in: self), "SNIPPET",
            "a host that reads at 700 ms pasted the user's previous clipboard: the hold ended on a timer"
        )
    }

    /// Reading is the proof. Once it has happened the board is the user's again — promptly, not at
    /// the ceiling.
    func testReadPayloadIsReleasedPromptlyAfterTheRead() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        let postedAt = harness.paste("SNIPPET", in: self)

        pump(until: postedAt + 0.70)
        XCTAssertEqual(harness.hostRead(in: self), "SNIPPET")
        pump(until: postedAt + 1.10)

        XCTAssertEqual(harness.board.string(forType: .string), "USER-OLD",
                       "the user's clipboard comes back once the host has read the snippet")
    }

    /// Nobody ever reads it (⌘V dropped, no text field): the hold is bounded by the ceiling, and it
    /// is held that long — an unread payload is not evidence the host is done with it.
    func testPayloadNobodyReadsIsHeldPastTheFloorButReleasedAtTheCeiling() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        let postedAt = harness.paste("SNIPPET", in: self)
        let owned = harness.board.changeCount

        pump(until: postedAt + 1.20)
        XCTAssertEqual(harness.board.changeCount, owned,
                       "no read has been seen, so the payload is still ours at 1.2 s")

        pump(until: postedAt + InjectTiming.unverifiedPayloadResidencyCeiling + 0.40)
        XCTAssertNotEqual(harness.board.changeCount, owned, "the ceiling bounds the hold")
        XCTAssertEqual(harness.board.string(forType: .string), "USER-OLD")
    }

    /// A read does not shorten the floor: a clipboard manager that ignores the Transient marker
    /// reads at once, and must not be able to pull the hold below what the host is owed.
    func testAnEarlyReadDoesNotShortenTheFloor() {
        let harness = Harness()
        harness.seedUserClipboard("USER-OLD")
        let postedAt = harness.paste("SNIPPET", in: self)
        let owned = harness.board.changeCount

        pump(until: postedAt + 0.05)
        XCTAssertEqual(harness.hostRead(in: self), "SNIPPET")
        pump(until: postedAt + 0.30)
        XCTAssertEqual(harness.board.changeCount, owned, "still inside the 450 ms floor")

        pump(until: postedAt + 0.80)
        XCTAssertNotEqual(harness.board.changeCount, owned)
        XCTAssertEqual(harness.board.string(forType: .string), "USER-OLD")
    }

    // MARK: - Two expansions back to back

    /// Expansion #2 started while #1's ⌘V had not been read. Writing #2's text over the board
    /// makes #1's host paste #2's text (twice over, once for each ⌘V) and loses #1.
    func testSecondExpansionDoesNotOverwriteAPayloadTheFirstHostHasNotRead() {
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
