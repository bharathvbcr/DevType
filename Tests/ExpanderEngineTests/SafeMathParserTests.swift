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

    // MARK: - §Calc regressions

    /// `Double(Int64.max)` rounds *up* to 2^63, one past `Int64.max`, so the old
    /// `val <= Double(Int64.max)` bound admitted exactly 2^63 — and `Int64(2^63)` traps.
    /// `{{calc: 2^63}}` crashed the app inside a keystroke interceptor, mid-expansion. If this
    /// regresses the test process dies rather than failing, which is the point.
    func testTwoToThe63DoesNotTrap() {
        let value = SafeMathParser.evaluate("2^63")
        XCTAssertNotNil(value)
        let rendered = SafeMathParser.format(value!)
        XCTAssertFalse(rendered.isEmpty)
        XCTAssertEqual(DynamicTemplateEngine.shared.resolve("{{calc:2^63}}").text, rendered)
    }

    /// The boundaries either side must still take the integer path.
    func testTheIntegerBoundariesStillRenderAsIntegers() {
        XCTAssertEqual(SafeMathParser.format(SafeMathParser.evaluate("2^62")!), "4611686018427387904")
        XCTAssertEqual(SafeMathParser.format(SafeMathParser.evaluate("-2^63")!), "-9223372036854775808")
    }

    /// Unary minus binds looser than `^`, so `-2^2` is -(2^2). The tokenizer used to glue the
    /// sign onto the literal, making it (-2)^2 = 4 — silently wrong arithmetic, which is the
    /// worst failure a calculator can have.
    func testUnaryMinusBindsLooserThanExponent() {
        XCTAssertEqual(SafeMathParser.evaluate("-2^2"), -4)
        XCTAssertEqual(SafeMathParser.evaluate("-3^2"), -9)
        XCTAssertEqual(SafeMathParser.evaluate("(-2)^2"), 4, "explicit parentheses still group")
    }

    /// A negative exponent still has to work — it is why the sign was glued on in the first place.
    func testNegativeExponentsStillWork() {
        XCTAssertEqual(SafeMathParser.evaluate("2^-1"), 0.5)
        XCTAssertEqual(SafeMathParser.evaluate("2^3^2"), 512, "power stays right-associative")
    }

    /// Negating a parenthesised expression was rejected outright: the sign had no digits to
    /// glue to, so `-(3+4)` rendered the raw `{{calc:…}}` tag.
    func testNegationOfAParenthesisedExpression() {
        XCTAssertEqual(SafeMathParser.evaluate("-(3+4)"), -7)
        XCTAssertEqual(SafeMathParser.evaluate("-(3)"), -3)
        XCTAssertEqual(SafeMathParser.evaluate("- (3+4)"), -7)
        XCTAssertEqual(SafeMathParser.evaluate("2*-(3)"), -6)
    }

    func testRepeatedSignsFold() {
        XCTAssertEqual(SafeMathParser.evaluate("--3"), 3)
        XCTAssertEqual(SafeMathParser.evaluate("- -3"), 3)
    }

    /// `String(someDouble)` prints the exact binary value, so `0.1 + 0.2` typed
    /// `0.30000000000000004` into the user's document.
    func testFloatingNoiseIsNotTypedIntoTheDocument() {
        XCTAssertEqual(SafeMathParser.format(SafeMathParser.evaluate("0.1 + 0.2")!), "0.3")
        XCTAssertEqual(DynamicTemplateEngine.shared.resolve("{{calc:0.1+0.2}}").text, "0.3")
    }

    func testNonTerminatingDivisionIsTruncatedNotDumped() {
        let third = SafeMathParser.format(SafeMathParser.evaluate("1/3")!)
        XCTAssertLessThanOrEqual(third.count, 16, "got \(third)")
        XCTAssertTrue(third.hasPrefix("0.3333"))
    }

    /// Exact decimals must not be mangled by the rounding that absorbs the noise.
    func testExactValuesAreUnchanged() {
        XCTAssertEqual(SafeMathParser.format(SafeMathParser.evaluate("10/4")!), "2.5")
        XCTAssertEqual(SafeMathParser.format(SafeMathParser.evaluate("7/2")!), "3.5")
        XCTAssertEqual(SafeMathParser.format(SafeMathParser.evaluate("2+2")!), "4")
    }

    /// Removing the sign-gluing must not have opened the door to malformed input.
    func testMalformedExpressionsAreStillRejected() {
        for bad in ["3+", "2--", "+", "-", "2(3)", "1.2.3", "1e3", "*", "()", "(", ")"] {
            XCTAssertNil(SafeMathParser.evaluate(bad), "\"\(bad)\" should not evaluate")
        }
    }
}
