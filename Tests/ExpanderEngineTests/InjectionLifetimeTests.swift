import XCTest
@testable import ExpanderEngine

final class InjectionLifetimeTests: XCTestCase {
    func testCancelAndTimeoutPermanentlyRevokeEffectsAndObservations() {
        for timeout in [false, true] {
            let operation = InjectCompletionGuard()
            XCTAssertTrue(operation.allowsContinuation())
            if timeout { operation.markTimedOut() } else { operation.cancel() }
            XCTAssertFalse(operation.allowsContinuation())
            XCTAssertFalse(operation.allowsContinuation(observationOnly: true))
            XCTAssertEqual(operation.markCompleted(.succeeded), 1)
            XCTAssertFalse(operation.allowsContinuation())
            XCTAssertFalse(operation.allowsContinuation(observationOnly: true))
            if timeout { XCTAssertEqual(operation.terminalOutcome, .failedSilent) }
        }
    }

    func testCompletionEndsEffectsButPermitsReadOnlyConfirmationUntilSuperseded() {
        let operation = InjectCompletionGuard()
        XCTAssertEqual(operation.markCompleted(.postedUnverified), 1)
        XCTAssertFalse(operation.allowsContinuation())
        XCTAssertTrue(operation.allowsContinuation(observationOnly: true))
        XCTAssertEqual(operation.markCompleted(.succeeded), 2)
        XCTAssertEqual(operation.terminalOutcome, .postedUnverified)
        operation.cancel()
        XCTAssertFalse(operation.allowsContinuation(observationOnly: true))
    }

    func testCancelledOperationCannotPostVDuringModifierGap() {
        let operation = InjectCompletionGuard()
        var callbacks: [() -> Void] = []
        var events: [String] = []
        HIDKeyPoster.performCommandChord(
            shouldContinue: { operation.allowsContinuation() }, canPost: { true },
            postCommandDown: { events.append("command-down"); return true },
            postLetter: { events.append("v"); return true },
            releaseCommand: { events.append("command-up") },
            schedule: { callbacks.append($0) }, completion: { events.append("completed-\($0)") }
        )
        operation.cancel()
        callbacks.removeFirst()()
        XCTAssertEqual(events, ["command-down", "command-up", "completed-false"])
        XCTAssertTrue(callbacks.isEmpty)
    }
}
