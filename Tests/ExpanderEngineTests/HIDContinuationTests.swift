import XCTest
@testable import ExpanderEngine

final class HIDContinuationTests: XCTestCase {
    func testCancellationAndPermissionRevocationInModifierGapReleaseCommandWithoutLetter() {
        for revokePermission in [false, true] {
            var current = true
            var permitted = true
            var events: [String] = []
            var scheduled: [() -> Void] = []
            var results: [Bool] = []
            HIDKeyPoster.performCommandChord(
                shouldContinue: { current }, canPost: { permitted },
                postCommandDown: { events.append("commandDown"); return true },
                postLetter: { events.append("V"); return true },
                releaseCommand: { events.append("commandUp") },
                schedule: { scheduled.append($0) }, completion: { results.append($0) }
            )
            XCTAssertEqual(events, ["commandDown"])
            if revokePermission { permitted = false } else { current = false }
            scheduled.removeFirst()()
            XCTAssertEqual(events, ["commandDown", "commandUp"])
            XCTAssertEqual(results, [false])
            XCTAssertTrue(scheduled.isEmpty)
        }
    }

    func testRefusedStartHasNoEffects() {
        var events = 0
        var results: [Bool] = []
        HIDKeyPoster.performCommandChord(
            shouldContinue: { false }, canPost: { true },
            postCommandDown: { events += 1; return true }, postLetter: { events += 1; return true },
            releaseCommand: { events += 1 }, schedule: { _ in XCTFail("No callback may be scheduled.") },
            completion: { results.append($0) }
        )
        XCTAssertEqual(events, 0)
        XCTAssertEqual(results, [false])
    }

    func testCancellationAfterLetterStillReleasesCommandAndReportsTheAttempt() {
        var current = true
        var scheduled: [() -> Void] = []
        var events: [String] = []
        var results: [Bool] = []
        HIDKeyPoster.performCommandChord(
            shouldContinue: { current }, canPost: { true },
            postCommandDown: { events.append("commandDown"); return true },
            postLetter: { events.append("V"); return true },
            releaseCommand: { events.append("commandUp") }, schedule: { scheduled.append($0) },
            completion: { results.append($0) }
        )
        scheduled.removeFirst()()
        current = false
        scheduled.removeFirst()()
        XCTAssertEqual(events, ["commandDown", "V", "commandUp"])
        XCTAssertEqual(results, [true], "The letter already posted; cancellation must not report notPosted.")
    }

    func testLetterFailureReleasesCommandAndCompletesOnce() {
        var scheduled: [() -> Void] = []
        var releases = 0
        var results: [Bool] = []
        HIDKeyPoster.performCommandChord(
            shouldContinue: { true }, canPost: { true }, postCommandDown: { true },
            postLetter: { false }, releaseCommand: { releases += 1 }, schedule: { scheduled.append($0) },
            completion: { results.append($0) }
        )
        scheduled.removeFirst()()
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(results, [false])
        XCTAssertTrue(scheduled.isEmpty)
    }
}
