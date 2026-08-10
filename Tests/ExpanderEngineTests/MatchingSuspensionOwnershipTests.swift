import XCTest
@testable import ExpanderEngine

/// Ownership of the matching-suspend reference count.
///
/// The bug these tests exist for: `suspendMatching()` / `resumeMatching()` was a bare global
/// count with no record of who held it, and every panel in the app incremented it on open and
/// decremented it on close. Two unbalanced sequences are reachable from ordinary UI, and both are
/// silent catastrophes rather than glitches:
///
///   * **one suspend too many** — the panel `isOpen` checks read `panel?.isVisible`, which is
///     already false while a panel animates out, so a second `open()` suspends again while the
///     first suspension is still standing. The count never returns to zero. The event tap keeps
///     running, the engine stays enabled, every permission stays granted, no counter moves, and
///     not one typed trigger expands until the app is relaunched.
///   * **one resume too many** — a `close()` with no matching `open()` (a dismiss watcher racing
///     `onPick`) decrements someone else's suspension, resuming matching underneath a fill-in
///     panel that is still collecting keystrokes.
///
/// `MatchingSuspension` makes both unrepresentable, and these tests hold it to that.
final class MatchingSuspensionOwnershipTests: XCTestCase {

    private func makeEngine() -> EventTapEngine {
        EventTapEngine()
    }

    // MARK: - The leak that stopped expansions

    /// The double-open case, which is what a panel reopened mid-animation does.
    func testDroppingATokenWithoutReleasingItStillResumesMatching() {
        let engine = makeEngine()
        autoreleasepool {
            var first: EventTapEngine.MatchingSuspension? =
                engine.suspendMatching(reason: "PanelA")
            XCTAssertTrue(engine.matchingSuspended)
            // Second open overwrites the stored token — exactly what the panels do.
            first = engine.suspendMatching(reason: "PanelA")
            _ = first
            first = nil
        }
        XCTAssertFalse(
            engine.matchingSuspended,
            "A token dropped without release must not pin matching off forever."
        )
    }

    /// One open, one close, count back to zero — the base case, which also has to keep working.
    func testBalancedSuspendAndReleaseResumesMatching() {
        let engine = makeEngine()
        let suspension = engine.suspendMatching(reason: "FillInPanel")
        XCTAssertTrue(engine.matchingSuspended)
        suspension.release()
        XCTAssertFalse(engine.matchingSuspended)
    }

    /// Nested panels: the inner one closing must not resume matching for the outer one.
    func testNestedSuspensionsOnlyResumeWhenAllAreReleased() {
        let engine = makeEngine()
        let outer = engine.suspendMatching(reason: "InlineSearchPanel")
        let inner = engine.suspendMatching(reason: "FillInPanel")
        XCTAssertTrue(engine.matchingSuspended)

        inner.release()
        XCTAssertTrue(
            engine.matchingSuspended,
            "The outer panel is still open — matching must stay suspended."
        )

        outer.release()
        XCTAssertFalse(engine.matchingSuspended)
    }

    // MARK: - The theft that resumed matching under an open panel

    /// A double `close()` must not consume a suspension it does not own.
    func testReleasingTheSameTokenTwiceIsANoOp() {
        let engine = makeEngine()
        let victim = engine.suspendMatching(reason: "FillInPanel")
        let doubleClosed = engine.suspendMatching(reason: "AIActionPanel")

        doubleClosed.release()
        doubleClosed.release()   // dismiss watcher racing onPick

        XCTAssertTrue(
            engine.matchingSuspended,
            "The second release must not steal the fill-in panel's suspension."
        )
        victim.release()
        XCTAssertFalse(engine.matchingSuspended)
    }

    /// Releases can arrive out of order — a preview panel closing after the search panel that
    /// opened it. Ownership means order does not matter.
    func testSuspensionsMayBeReleasedOutOfOrder() {
        let engine = makeEngine()
        let first = engine.suspendMatching(reason: "InlineSearchPanel")
        let second = engine.suspendMatching(reason: "AIPreviewPanel")

        first.release()
        XCTAssertTrue(engine.matchingSuspended)
        second.release()
        XCTAssertFalse(engine.matchingSuspended)
    }

    // MARK: - Diagnostics

    /// The report has to name the holder. "Matching is suspended" without a culprit is what made
    /// the original outage take a day to find.
    func testDiagnosticsNameTheSuspensionHolder() {
        let engine = makeEngine()
        XCTAssertEqual(engine.matchingSuspensionDiagnostics(), ["Matching: running (not suspended)"])

        let suspension = engine.suspendMatching(reason: "AIPreviewPanel")
        let lines = engine.matchingSuspensionDiagnostics()
        XCTAssertTrue(
            lines.first?.contains("SUSPENDED") == true,
            "A suspended engine must say so unambiguously: \(lines)"
        )
        XCTAssertTrue(
            lines.contains { $0.contains("AIPreviewPanel") },
            "The holder must be named: \(lines)"
        )
        suspension.release()
    }

    // MARK: - Orphan recovery

    /// A suspension older than the timeout with DevType in the background cannot belong to a live
    /// panel — no DevType panel is receiving keystrokes — so it is recovered rather than left to
    /// suppress every expansion indefinitely.
    func testOrphanedSuspensionIsRecoveredWhenDevTypeIsNotFrontmost() {
        let engine = makeEngine()
        let leaked = engine.suspendMatching(reason: "AIActionPanel")
        withExtendedLifetime(leaked) {
            let future = Date().addingTimeInterval(EventTapEngine.orphanedSuspensionTimeout + 1)
            let recovered = engine.recoverOrphanedSuspensions(
                isDevTypeFrontmost: false,
                now: future
            )
            XCTAssertEqual(recovered, 1)
            XCTAssertFalse(
                engine.matchingSuspended,
                "An orphaned suspension must not keep matching off forever."
            )
            XCTAssertEqual(engine.matchDropCounters.orphanedSuspensionsRecovered, 1)
        }
    }

    /// The inverse, and the reason recovery is not simply time-based: while DevType *is*
    /// frontmost the suspension may be a fill-in panel the user is still typing into. Resuming
    /// there would match their panel keystrokes as triggers.
    func testSuspensionIsNotRecoveredWhileDevTypeIsFrontmost() {
        let engine = makeEngine()
        let live = engine.suspendMatching(reason: "FillInPanel")
        withExtendedLifetime(live) {
            let future = Date().addingTimeInterval(EventTapEngine.orphanedSuspensionTimeout + 60)
            let recovered = engine.recoverOrphanedSuspensions(
                isDevTypeFrontmost: true,
                now: future
            )
            XCTAssertEqual(recovered, 0)
            XCTAssertTrue(
                engine.matchingSuspended,
                "A panel that is frontmost may legitimately still hold matching."
            )
        }
    }

    /// A young suspension is never recovered, however the frontmost app looks — panels open and
    /// close faster than the timeout constantly.
    func testFreshSuspensionIsNeverRecovered() {
        let engine = makeEngine()
        let fresh = engine.suspendMatching(reason: "AIActionPanel")
        withExtendedLifetime(fresh) {
            XCTAssertEqual(engine.recoverOrphanedSuspensions(isDevTypeFrontmost: false), 0)
            XCTAssertTrue(engine.matchingSuspended)
        }
    }

    // MARK: - Legacy pair

    /// The unowned pair still has to behave for existing callers and tests.
    func testLegacySuspendResumePairStillBalances() {
        let engine = makeEngine()
        engine.suspendMatching()
        engine.suspendMatching()
        XCTAssertTrue(engine.matchingSuspended)
        engine.resumeMatching()
        XCTAssertTrue(engine.matchingSuspended)
        engine.resumeMatching()
        XCTAssertFalse(engine.matchingSuspended)
    }

    /// Resuming with nothing suspended must not underflow into a negative count that later
    /// swallows a real suspension.
    func testResumeWithNothingSuspendedCannotGoNegative() {
        let engine = makeEngine()
        engine.resumeMatching()
        engine.resumeMatching()
        XCTAssertFalse(engine.matchingSuspended)

        let suspension = engine.suspendMatching(reason: "FillInPanel")
        XCTAssertTrue(
            engine.matchingSuspended,
            "Earlier spurious resumes must not have banked credit against a later suspend."
        )
        suspension.release()
        XCTAssertFalse(engine.matchingSuspended)
    }

    // MARK: - Concurrency

    /// Panels open and close from the main queue, but transform completions and inject callbacks
    /// arrive on others. The count must survive concurrent traffic and land exactly on zero.
    func testConcurrentSuspendAndReleaseLandsOnZero() {
        let engine = makeEngine()
        let iterations = 500
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "suspension.stress", attributes: .concurrent)

        for index in 0..<iterations {
            group.enter()
            queue.async {
                // The pool is not decoration: a dropped token is released by ARC when the pool
                // drains, which would otherwise race `group.leave()` and make this flaky.
                autoreleasepool {
                    let suspension = engine.suspendMatching(reason: "stress-\(index % 7)")
                    // Half release explicitly, half drop the token and rely on `deinit`.
                    if index.isMultiple(of: 2) {
                        suspension.release()
                    } else {
                        _ = suspension
                    }
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertFalse(
            engine.matchingSuspended,
            "After equal suspends and releases the count must be exactly zero, not merely small."
        )
        XCTAssertTrue(engine.matchingSuspensionOwners().isEmpty)
    }
}
