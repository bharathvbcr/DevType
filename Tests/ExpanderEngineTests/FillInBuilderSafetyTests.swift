import XCTest
@testable import ExpanderEngine

// `FillInBuilder.fillPart` splices raw content between `%fillpart:…%` and
// `%fillpartend%`. MacroParser resolves `%%` as an escaped `%` only *inside* a
// macro body (`scanBody`); at statement level there is no escape — a spliced
// `%fillpartend%`, `%fillpart:`, `%case:upper%` or `%caseend%` parses as real
// structure and corrupts section pairing / case blocks. Content carrying such
// sequences is rejected outright (verified pre-fix: it used to restructure the
// emitted macro — "before  after", "price LOW%").

final class FillInBuilderSafetyTests: XCTestCase {

    private func fillPartEndCount(in tokens: [MacroToken]) -> Int {
        tokens.filter { token in
            if case .fillPartEnd = token { return true }
            return false
        }.count
    }

    // MARK: - Rejection of structural content

    func testFillPartRejectsStructuralSequences() {
        let hostile: [String] = [
            "before %fillpartend% after",
            "%fillpartend%",
            "%fillpart:name=Inner:default=yes%",
            "price %case:upper%low%",
            "%caseend%",
        ]
        for content in hostile {
            XCTAssertThrowsError(
                try FillInBuilder.fillPart(name: "Sec", includeByDefault: true, content: content),
                "content \(content) must be rejected"
            ) { error in
                XCTAssertEqual(error as? FillInBuilder.BuilderError,
                               .contentNotRepresentable)
            }
            XCTAssertFalse(FillInBuilder.contentIsRepresentable(content),
                           "representability predicate must agree for \(content)")
        }
    }

    // MARK: - Safe content round-trips

    /// A lone `%` (or even `%%`) in ordinary text is safe: the parser keeps
    /// unknown %-sequences literal. It must round-trip untouched.
    func testPercentLiteralsInContentRoundTrip() throws {
        let macro = try FillInBuilder.fillPart(name: "Pct", includeByDefault: true, content: "50% off")
        let tokens = MacroParser.parse(macro)

        XCTAssertEqual(fillPartEndCount(in: tokens), 1,
                       "the only structural end marker must be the builder's own")

        let rendered = MacroParser.render(tokens: tokens, fillValues: [0: "yes"]).text
        XCTAssertEqual(rendered, "50% off",
                       "ordinary text with percent signs must survive render→parse")
        XCTAssertTrue(FillInBuilder.contentIsRepresentable("50% off"))
        XCTAssertTrue(FillInBuilder.contentIsRepresentable("100%% sure"))
    }

    func testHappyPathRoundTripsThroughParser() throws {
        let macro = try FillInBuilder.fillPart(name: "Notes", includeByDefault: false, content: "plain content")
        XCTAssertEqual(macro, "%fillpart:name=Notes:default=no%plain content%fillpartend%")

        let declined = MacroParser.render(tokens: MacroParser.parse(macro), fillValues: [0: "no"]).text
        XCTAssertEqual(declined, "", "default-off section renders empty when declined")

        let accepted = MacroParser.render(tokens: MacroParser.parse(macro), fillValues: [0: "yes"]).text
        XCTAssertEqual(accepted, "plain content")
    }
}
