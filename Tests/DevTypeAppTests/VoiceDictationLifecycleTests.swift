import XCTest
@testable import DevTypeAppCore

final class VoiceDictationLifecycleTests: XCTestCase {
    func testSecondToggleCancelsAPendingPermissionAttempt() {
        var lifecycle = VoiceDictationLifecycle()

        XCTAssertEqual(lifecycle.toggle(), .begin(attempt: 1))
        XCTAssertEqual(lifecycle.toggle(), .cancelPreparation(attempt: 1))
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertNil(
            lifecycle.beginCoordinatorStart(attempt: 1),
            "A permission continuation from a cancelled attempt must not start recording."
        )
    }

    func testSecondToggleDuringCoordinatorStartRequestsOneOrderedStop() {
        var lifecycle = VoiceDictationLifecycle()

        XCTAssertEqual(lifecycle.toggle(), .begin(attempt: 1))
        XCTAssertEqual(lifecycle.beginCoordinatorStart(attempt: 1)?.rawValue, 1)
        XCTAssertEqual(lifecycle.toggle(), .stop(attempt: 1))
        XCTAssertEqual(lifecycle.phase, .finishing(attempt: 1))
        XCTAssertFalse(
            lifecycle.coordinatorDidStart(attempt: 1),
            "A start that finishes after Stop was requested must not reactivate the controller."
        )
        XCTAssertEqual(lifecycle.toggle(), .ignore)
    }

    func testTerminalCompletionReleasesSingleFlightForANewerGeneration() {
        var lifecycle = VoiceDictationLifecycle()

        XCTAssertEqual(lifecycle.toggle(), .begin(attempt: 1))
        XCTAssertEqual(lifecycle.beginCoordinatorStart(attempt: 1)?.rawValue, 1)
        XCTAssertTrue(lifecycle.coordinatorDidStart(attempt: 1))
        XCTAssertEqual(lifecycle.phase, .active(attempt: 1))

        lifecycle.finishCurrentSession()

        XCTAssertEqual(lifecycle.toggle(), .begin(attempt: 2))
    }

    func testLateTerminalFromAnOlderAttemptCannotClearANewerAttempt() {
        var lifecycle = VoiceDictationLifecycle()

        XCTAssertEqual(lifecycle.toggle(), .begin(attempt: 1))
        XCTAssertNotNil(lifecycle.finish(attempt: 1))
        XCTAssertEqual(lifecycle.toggle(), .begin(attempt: 2))

        XCTAssertNil(lifecycle.finish(attempt: 1))
        XCTAssertEqual(lifecycle.phase, .preparing(attempt: 2))
        XCTAssertTrue(lifecycle.isLatestAttempt(2))
        XCTAssertFalse(lifecycle.isLatestAttempt(1))
    }

    func testSupersededVoiceAICompletionCannotClaimANewerOperation() {
        var lifecycle = VoiceAITransformLifecycle()

        let first = lifecycle.begin()
        XCTAssertEqual(lifecycle.invalidate(), first)

        let second = lifecycle.begin()
        XCTAssertFalse(
            lifecycle.claimCompletion(first),
            "A stale transform must not update the HUD, restore text, or inject into a newer target."
        )
        XCTAssertTrue(lifecycle.claimCompletion(second))
        XCTAssertFalse(
            lifecycle.claimCompletion(second),
            "A provider completion must be single-consumption even if it fires twice."
        )
    }
}
