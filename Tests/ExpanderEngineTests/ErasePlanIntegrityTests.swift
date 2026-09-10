import XCTest
@testable import ExpanderEngine

final class ErasePlanIntegrityTests: XCTestCase {
    private final class Poster: BackspacePosting {
        var counts: [Int] = []
        func sendBackspaces(count: Int) -> Int { counts.append(count); return count }
        func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void) {
            counts.append(count)
            completion(true)
        }
    }

    private var invalidPlans: [ErasePlan] {
        [ErasePlan(expectedText: "abc", utf16Count: 3, backspaceCount: 4),
         ErasePlan(expectedText: "abc", utf16Count: 3, backspaceCount: 0),
         ErasePlan(expectedText: "abc", utf16Count: 0, backspaceCount: 0),
         ErasePlan(expectedText: "", utf16Count: 0, backspaceCount: 3),
         ErasePlan(expectedText: nil, utf16Count: 1, backspaceCount: 4),
         ErasePlan(expectedText: "🎓", utf16Count: 2, backspaceCount: 2)]
    }

    func testContradictoryCountsRefuseEvenWithMatchingOrUnavailableField() {
        for plan in invalidPlans {
            for value: String? in [nil, plan.expectedText] {
                XCTAssertTrue(ErasePreconditionChecker.evaluate(
                    plan: plan, value: value, caretLocation: value?.utf16.count,
                    selectionLength: 0
                ).blocksErase, "Contradictory plan must fail before field evidence: \(plan)")
            }
        }
    }

    func testPostingBoundaryCannotTrustAStaleOrForgedPassingResult() {
        for plan in invalidPlans {
            for result: ErasePreconditionResult in [.ok, .unavailable("opaque field")] {
                let poster = Poster()
                var completions: [Bool] = []
                EraseExecutor(hid: poster).finishGuardedErase(
                    plan: plan, afterPossibleWrite: false, result: result,
                    onUnverifiableAfterWrite: nil, completion: { completions.append($0) }
                )
                XCTAssertEqual(completions, [false])
                XCTAssertTrue(poster.counts.isEmpty)
            }
        }
    }

    func testNoopFastPathCannotApproveContradictoryText() {
        var completions: [Bool] = []
        EraseExecutor(hid: Poster()).performGuardedErase(
            plan: ErasePlan(expectedText: "abc", utf16Count: 3, backspaceCount: 0),
            completion: { completions.append($0) }
        )
        XCTAssertEqual(completions, [false])
    }

    func testTextDerivedPlansPreserveBothUnitSystemsAcrossUnicodeStress() {
        let alphabet = ["a", "🎓", "e\u{0301}", "👨‍👩‍👧‍👦", "한", "\r\n", "🇮🇳"]
        for length in 0..<512 {
            let text = (0..<length).map { alphabet[($0 + length) % alphabet.count] }.joined()
            let plan = ErasePlan(text: text)
            XCTAssertEqual(plan.utf16Count, text.utf16.count)
            XCTAssertEqual(plan.backspaceCount, text.count)
            XCTAssertEqual(ErasePreconditionChecker.evaluate(
                plan: plan, value: "prefix" + text, caretLocation: 6 + text.utf16.count,
                selectionLength: 0, insertionPointFollowsExpectedText: false
            ), .ok)
        }
    }
}
