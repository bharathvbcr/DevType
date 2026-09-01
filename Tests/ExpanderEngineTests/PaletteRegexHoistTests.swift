import XCTest
@testable import ExpanderEngine

/// The `date+N` patterns are compiled once, not once per keystroke.
///
/// `matchCommands` → `parseTypedQuery` → `parseRelativeDayQuery` runs on every character typed
/// into the command palette, and the two `NSRegularExpression`s used to be constructed inside
/// that last function. Compiling a regex parses the pattern and builds an automaton; doing it
/// twice per keystroke is the same shape of defect as rebuilding the abbreviation matcher.
final class PaletteRegexHoistTests: XCTestCase {

    /// Identity, not equality: the point is that no new object is built per call.
    func testThePatternsAreTheSameInstancesOnEveryAccess() {
        let first = CommandPaletteCatalog.relativeDayPatterns
        let second = CommandPaletteCatalog.relativeDayPatterns
        XCTAssertEqual(first.count, 2)
        for (a, b) in zip(first, second) {
            XCTAssertTrue(a === b, "each pattern must be compiled once and reused")
        }
    }

    func testParsingDoesNotRebuildThePatterns() {
        let before = CommandPaletteCatalog.relativeDayPatterns
        _ = CommandPaletteCatalog.parseRelativeDayQuery("date+3")
        _ = CommandPaletteCatalog.parseRelativeDayQuery("+5d")
        let after = CommandPaletteCatalog.relativeDayPatterns
        for (a, b) in zip(before, after) {
            XCTAssertTrue(a === b, "parsing must not replace the shared patterns")
        }
    }

    // MARK: - Behaviour is unchanged by the hoist

    func testDatePlusNStillParses() {
        XCTAssertEqual(CommandPaletteCatalog.parseRelativeDayQuery("date+3")?.days, 3)
        XCTAssertEqual(CommandPaletteCatalog.parseRelativeDayQuery("date-2")?.days, -2)
        XCTAssertEqual(CommandPaletteCatalog.parseRelativeDayQuery("date+7d")?.days, 7)
    }

    func testBareOffsetStillRequiresTheDaySuffix() {
        XCTAssertEqual(CommandPaletteCatalog.parseRelativeDayQuery("+5d")?.days, 5)
        XCTAssertEqual(CommandPaletteCatalog.parseRelativeDayQuery("-5d")?.days, -5)
        XCTAssertNil(CommandPaletteCatalog.parseRelativeDayQuery("+5"))
    }

    func testNonMatchingQueriesStillReturnNil() {
        // `date+0` is deliberately excluded by a `days != 0` guard that predates this change:
        // a zero offset means "today", which has its own handler.
        for query in ["", "date", "date+", "date+abc", "date+9999", "hello", "date+0", "date-0"] {
            XCTAssertNil(
                CommandPaletteCatalog.parseRelativeDayQuery(query),
                "\"\(query)\" should not parse as a relative day"
            )
        }
    }

    /// A shared, mutable-looking global used from a per-keystroke path across threads:
    /// `NSRegularExpression` is documented as thread-safe for matching, and this pins that the
    /// hoist did not introduce a data race.
    func testConcurrentParsingIsSafe() {
        let done = expectation(description: "concurrent parses")
        done.expectedFulfillmentCount = 50
        for index in 0..<50 {
            // 1-based: `date+0` is rejected by the `days != 0` guard, not by the regex.
            let offset = index + 1
            DispatchQueue.global().async {
                XCTAssertEqual(
                    CommandPaletteCatalog.parseRelativeDayQuery("date+\(offset)")?.days,
                    offset
                )
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
    }
}
