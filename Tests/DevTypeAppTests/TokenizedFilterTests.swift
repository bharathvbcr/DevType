import XCTest
@testable import DevTypeAppCore

/// The AI action panel and the shortcut reference each tested the *whole* query against each
/// field, so a multi-word query only matched when those words sat adjacent, in that order,
/// inside one field — and no query could ever span two fields.
final class TokenizedFilterTests: XCTestCase {

    private let fields = ["Make Formal", "Rewrites the selection in a professional tone", "on-device"]

    func testAnEmptyQueryMatchesEverything() {
        XCTAssertTrue(TokenizedFilter.matches(query: "", fields: fields))
        XCTAssertTrue(TokenizedFilter.matches(query: "   ", fields: fields))
    }

    func testSingleWordBehaviourIsUnchanged() {
        XCTAssertTrue(TokenizedFilter.matches(query: "formal", fields: fields))
        XCTAssertTrue(TokenizedFilter.matches(query: "professional", fields: fields))
        XCTAssertFalse(TokenizedFilter.matches(query: "zzzz", fields: fields))
    }

    /// The gap. Both of these failed before: word order, and a query spanning two fields.
    func testWordOrderAndCrossFieldQueriesMatch() {
        XCTAssertTrue(
            TokenizedFilter.matches(query: "formal make", fields: fields),
            "Word order must not decide whether a row matches."
        )
        XCTAssertTrue(
            TokenizedFilter.matches(query: "formal device", fields: fields),
            "A query spanning the title and the behaviour tag must match."
        )
    }

    /// Narrowing, not relevance: every word still has to land somewhere.
    func testAnUnmatchedWordStillExcludesTheRow() {
        XCTAssertFalse(TokenizedFilter.matches(query: "formal zzzz", fields: fields))
    }

    func testMatchingIsCaseInsensitiveOnBothSides() {
        XCTAssertTrue(TokenizedFilter.matches(query: "MAKE Formal", fields: fields))
    }

    /// Empty fields are common (an optional note) and must not throw off the match.
    func testEmptyFieldsAreHarmless() {
        XCTAssertTrue(TokenizedFilter.matches(query: "formal", fields: ["Make Formal", ""]))
        XCTAssertFalse(TokenizedFilter.matches(query: "formal", fields: ["", ""]))
    }

    /// Every term is scanned against every field of every row, so the term count needs the
    /// same ceiling the palette uses — a paste into a search field should not become
    /// list-sized work.
    func testTermCountIsCapped() {
        let huge = (0..<5000).map { "w\($0)" }.joined(separator: " ")
        let start = Date()
        _ = TokenizedFilter.matches(query: huge, fields: fields)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(TokenizedFilter.maximumQueryTerms, 12)
    }

    /// Capping drops trailing words, which can only widen the match. It must never narrow one
    /// that used to succeed.
    func testCappingNeverExcludesAPreviouslyMatchingRow() {
        let padded = "formal " + (0..<50).map { "w\($0)" }.joined(separator: " ")
        XCTAssertTrue(TokenizedFilter.matches(query: "formal", fields: fields))
        XCTAssertFalse(
            TokenizedFilter.matches(query: padded, fields: fields),
            "Words inside the cap that do not match must still exclude the row."
        )
    }
}
