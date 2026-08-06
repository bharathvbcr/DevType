import XCTest
@testable import ExpanderEngine

/// §3.6 — `SafeMathParser` used to silently accept malformed input.
///
/// `tokenize` had no `else` for an unparseable sign, so `{{calc:2--}}` dropped the trailing
/// operator and rendered a bare `2`. And an over-long expression returned `nil`, which the
/// template engine turned into the **empty string** — silent content deletion mid-expansion.
/// Both are now refusals that leave the original tag text in place.
final class SafeMathParserTests: XCTestCase {

    private let engine = DynamicTemplateEngine()

    // MARK: - Well-formed expressions still evaluate

    func testBasicArithmetic() {
        XCTAssertEqual(SafeMathParser.evaluate("2+2"), 4)
        XCTAssertEqual(SafeMathParser.evaluate(" 7 - 3 "), 4)
        XCTAssertEqual(SafeMathParser.evaluate("6*7"), 42)
        XCTAssertEqual(SafeMathParser.evaluate("9/3"), 3)
        XCTAssertEqual(SafeMathParser.evaluate("2^10"), 1024)
        XCTAssertEqual(SafeMathParser.evaluate("(1+2)*3"), 9)
        XCTAssertEqual(SafeMathParser.evaluate("10%3"), 1)
    }

    func testUnarySignsAreAccepted() {
        XCTAssertEqual(SafeMathParser.evaluate("-5"), -5)
        XCTAssertEqual(SafeMathParser.evaluate("+5"), 5)
        XCTAssertEqual(SafeMathParser.evaluate("3*-2"), -6)
        XCTAssertEqual(SafeMathParser.evaluate("(-4)+1"), -3)
    }

    func testDecimalsAreAccepted() {
        XCTAssertEqual(SafeMathParser.evaluate("1.5+1.5"), 3)
    }

    // MARK: - Malformed input must be refused, not "mostly evaluated"

    func testDanglingOperatorsAreRefused() {
        // The §3.6 headline: this used to render `2`.
        XCTAssertNil(SafeMathParser.evaluate("2--"))
        XCTAssertNil(SafeMathParser.evaluate("2+"))
        XCTAssertNil(SafeMathParser.evaluate("2*"))
        XCTAssertNil(SafeMathParser.evaluate("*2"))
        XCTAssertNil(SafeMathParser.evaluate("2++"))
        XCTAssertNil(SafeMathParser.evaluate("/"))
    }

    func testMalformedNumbersAreRefused() {
        XCTAssertNil(SafeMathParser.evaluate("1.2.3"))
        XCTAssertNil(SafeMathParser.evaluate("."))
        XCTAssertNil(SafeMathParser.evaluate("１+１"), "Full-width digits are not ASCII numerals")
    }

    func testUnknownCharactersAreRefused() {
        XCTAssertNil(SafeMathParser.evaluate("2 + two"))
        XCTAssertNil(SafeMathParser.evaluate("sin(1)"))
        XCTAssertNil(SafeMathParser.evaluate("$5 + 5"))
        XCTAssertNil(SafeMathParser.evaluate("2;2"))
    }

    func testUnbalancedParenthesesAreRefused() {
        XCTAssertNil(SafeMathParser.evaluate("(1+2"))
        XCTAssertNil(SafeMathParser.evaluate("1+2)"))
        XCTAssertNil(SafeMathParser.evaluate("()"))
    }

    func testEmptyInputIsRefused() {
        XCTAssertNil(SafeMathParser.evaluate(""))
        XCTAssertNil(SafeMathParser.evaluate("   "))
    }

    func testDivisionAndModuloByZeroAreRefused() {
        XCTAssertNil(SafeMathParser.evaluate("1/0"))
        XCTAssertNil(SafeMathParser.evaluate("1%0"))
    }

    func testNonFiniteResultsAreRefused() {
        XCTAssertNil(SafeMathParser.evaluate("2^99999"), "inf is not a usable expansion")
    }

    // MARK: - Bounds

    func testOverlongExpressionsAreRefused() {
        let long = String(repeating: "1+", count: SafeMathParser.maxExpressionLength) + "1"
        XCTAssertGreaterThan(long.count, SafeMathParser.maxExpressionLength)
        XCTAssertNil(SafeMathParser.evaluate(long))
    }

    func testExpressionAtTheLengthLimitIsStillAccepted() {
        // Exactly `maxExpressionLength` characters, well inside `maxTokenCount` — the length
        // limit itself is inclusive.
        let left = String(repeating: "1", count: 31)
        let right = String(repeating: "2", count: 32)
        let expression = left + "+" + right
        XCTAssertEqual(expression.count, SafeMathParser.maxExpressionLength)
        XCTAssertNotNil(SafeMathParser.evaluate(expression))
    }

    func testTooManyTokensAreRefused() {
        // Short enough to pass the length check, dense enough to blow the token budget:
        // 25 numbers + 24 operators = 49 tokens in 49 characters.
        let expression = "1" + String(repeating: "+1", count: 24)
        XCTAssertEqual(expression.count, 49)
        XCTAssertLessThanOrEqual(expression.count, SafeMathParser.maxExpressionLength)
        XCTAssertNil(SafeMathParser.evaluate(expression))
    }

    // MARK: - What the template engine does with a refusal (§3.6)

    func testMalformedCalcTagIsLeftIntactRatherThanRenderedAsTwo() {
        let result = engine.resolve("total {{calc:2--}} end")
        XCTAssertEqual(
            result.text,
            "total {{calc:2--}} end",
            "A malformed expression must leave its tag alone, never render a partial result"
        )
        XCTAssertFalse(result.text.contains("total 2 end"))
    }

    func testOverlongCalcTagDoesNotDeleteContent() {
        let long = String(repeating: "1+", count: SafeMathParser.maxExpressionLength) + "1"
        let template = "before {{calc:\(long)}} after"
        let result = engine.resolve(template)
        XCTAssertEqual(
            result.text,
            template,
            "An over-length expression used to become the empty string — silent content deletion"
        )
        XCTAssertTrue(result.text.contains("before"))
        XCTAssertTrue(result.text.contains("after"))
    }

    func testValidCalcTagStillRenders() {
        XCTAssertEqual(engine.resolve("{{calc:2+2}}").text, "4")
        XCTAssertEqual(engine.resolve("{{calc: 10 / 4 }}").text, "2.5")
    }

    func testIntegerResultsRenderWithoutADecimalPoint() {
        XCTAssertEqual(engine.resolve("{{calc:6*7}}").text, "42")
        XCTAssertEqual(engine.resolve("{{calc:-3-3}}").text, "-6")
    }

    func testAValidAndAnInvalidTagInTheSameTemplateAreIndependent() {
        let result = engine.resolve("{{calc:1+1}} / {{calc:2--}}")
        XCTAssertEqual(result.text, "2 / {{calc:2--}}")
    }
}
