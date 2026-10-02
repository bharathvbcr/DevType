import XCTest
@testable import ExpanderEngine

/// Macro scanning is bounded per document.
///
/// `%%` reads as an escaped percent *inside* a macro body (§3.6), so `%case:upper%%case:upper%…`
/// is one body with no terminator: the scan runs to the end of the input, builds the whole
/// remainder as it goes, and the parser then restarts it at the next `%`. One full-length scan
/// per marker.
///
/// That is reachable without any privilege. An imported snippet's replacement may be 100,000
/// characters, `MacroPreview.render` is called synchronously for every row of the inline search
/// list and again on each keystroke in the editor, and neither truncates before rendering. At the
/// cap this measured 6.4 seconds of main-thread work; it is 0.05 now.
final class MacroParserScanBoundTests: XCTestCase {

    /// The shape that cost seconds: markers packed end to end so every `%%` pair reads as an
    /// escape, followed by a payload for each restarted scan to walk.
    private func markerSoup(markers: Int, payload: Int) -> String {
        String(repeating: "%case:upper%", count: markers) + String(repeating: "a", count: payload)
    }

    func testMarkerDenseSourceDoesNotStallTheCaller() {
        let source = markerSoup(markers: 7_000, payload: 14_000)
        XCTAssertLessThanOrEqual(
            source.count, 100_000,
            "must stay inside the replacement cap the importer already accepts"
        )

        let started = Date()
        _ = MacroPreview.render(source)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.0, "preview must not stall the main thread: took \(elapsed)s")
    }

    /// How much the scaled-up document costs relative to the base one.
    ///
    /// Absolute timings track whatever machine runs them; the defect was the growth curve. The
    /// whole document is scaled — markers *and* payload — because the cost is markers × length:
    /// scaling only the markers over a fixed payload grows that product linearly, so a quadratic
    /// implementation passes. Scaled by four, linear work grows ×4 and quadratic ×16; the
    /// threshold sits at the geometric midpoint, eight. The bounded paths measure nearer ×2.7,
    /// because the fixed case budget and the allowance floor weigh the small document more.
    ///
    /// The clock is the thread's CPU time, not elapsed time: a full suite on a loaded machine
    /// deschedules the test and pages it in from swap, and wall-clock charged that to whichever
    /// size it landed on — once reading ×8 for work that was ×2.6. Each size is still measured
    /// several times, interleaved, keeping the least, because CPU time alone does not even out
    /// which core the thread ran on or what it was contending with.
    private static let growthScale = 4
    private static let growthThreshold = 8.0

    private func growthRatio(
        rounds: Int = 7,
        document: (_ scale: Int) -> String,
        _ run: (String) -> Void
    ) -> (base: Double, scaled: Double) {
        // Built up front so only `run` is timed.
        let small = document(1)
        let large = document(Self.growthScale)
        func seconds(_ source: String) -> Double {
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            run(source)
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1_000_000_000
        }

        run(small)  // warm
        run(large)
        var base = Double.infinity
        var scaled = Double.infinity
        for _ in 0..<rounds {
            base = min(base, seconds(small))
            scaled = min(scaled, seconds(large))
        }
        // The minimum shrinks the base reading, so the floor keeps timer resolution from
        // dominating the ratio on a fast machine.
        return (max(base, 0.0005), scaled)
    }

    func testScanCostScalesSubQuadraticallyWithMarkerCount() {
        let (base, scaled) = growthRatio(
            document: { markerSoup(markers: 1_000 * $0, payload: 5_000 * $0) },
            { _ = MacroParser.parse($0) }
        )

        XCTAssertLessThan(
            scaled / base, Self.growthThreshold,
            "×\(Self.growthScale) the document must not cost ×\(Self.growthScale * Self.growthScale) — \(base)s → \(scaled)s"
        )
    }

    /// `resolveNested` scans for `%snippet:` exactly the same way and needed the same ceiling.
    func testNestedSnippetMarkerSoupIsBounded() {
        let source = String(repeating: "%snippet:a%", count: 8_000)

        let started = Date()
        _ = MacroParser.resolveNested(source) { _ in "x" }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.0, "nested resolution must stay bounded: took \(elapsed)s")
    }

    // MARK: - What the allowance must never cost ordinary content

    /// The allowance is sized so no plausible document reaches it. A `%` only reaches the body
    /// scanner when it already looks like `%keyword:` or `%@`, and real bodies are short.
    func testOrdinaryMacrosStillParse() {
        let tokens = MacroParser.parse("Hi %filltext:name=first%, today is %date:yyyy-MM-dd% %|")

        guard tokens.count == 6 else {
            return XCTFail("expected text/fill/text/date/text/cursor, got \(tokens)")
        }
        guard case .text(let lead) = tokens[0] else { return XCTFail("expected leading text") }
        XCTAssertEqual(lead, "Hi ")
        guard case .fillText(let name, _) = tokens[1] else { return XCTFail("expected fill field") }
        XCTAssertEqual(name, "first")
        guard case .date(let format) = tokens[3] else { return XCTFail("expected date") }
        XCTAssertEqual(format, "yyyy-MM-dd")
        guard case .cursor = tokens[5] else { return XCTFail("expected cursor") }
    }

    /// §3.6's escape inside a body, which is what makes the unterminated scan possible in the
    /// first place, still resolves for any body a person would actually write.
    func testEscapedPercentInsideABodyStillResolves() {
        let tokens = MacroParser.parse("%filltext:name=rate:default=50%% off%")

        guard tokens.count == 1, case .fillText(let name, let value) = tokens[0] else {
            return XCTFail("expected a single fill field, got \(tokens)")
        }
        XCTAssertEqual(name, "rate")
        XCTAssertEqual(value, "50% off", "the escape must still collapse to one percent sign")
    }

    /// A single long macro body is one scan, not many, so it stays well inside the allowance.
    func testOneVeryLongBodyIsStillParsed() {
        let body = String(repeating: "x", count: 50_000)
        let tokens = MacroParser.parse("%filltext:name=n:default=\(body)%")

        guard tokens.count == 1, case .fillText(_, let value) = tokens[0] else {
            return XCTFail("a long body must still parse, got \(tokens.count) tokens")
        }
        XCTAssertEqual(value.count, body.count)
    }

    // MARK: - Case blocks, the other k·n path

    /// Separated by whitespace so each `%case:…%` parses as its own block rather than merging
    /// into one escaped body. Each open block re-transforms everything written since it opened,
    /// and they need not be closed — so 2,000 of them over 75,000 characters of output was 1.7
    /// seconds on the main thread, per row of the inline search list.
    func testManyOpenCaseBlocksDoNotStallThePreview() {
        let opens = String(repeating: "%case:upper% ", count: 2_000)
        let source = opens + String(repeating: "a", count: 99_000 - opens.count)
        XCTAssertLessThanOrEqual(source.count, 100_000)

        let started = Date()
        let rendered = MacroPreview.render(source)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.0, "preview must not stall: took \(elapsed)s")
        XCTAssertFalse(rendered.isEmpty, "the budget must never drop the snippet's text")
    }

    /// Blocks × output, scaled together for the reason `growthRatio` gives. The scaled document is
    /// 79,000 characters, inside the replacement cap.
    func testCaseBlockCostScalesSubQuadratically() {
        let (base, scaled) = growthRatio(
            document: {
                String(repeating: "%case:upper% ", count: 750 * $0) + String(repeating: "a", count: 10_000 * $0)
            },
            { _ = MacroPreview.render($0) }
        )

        XCTAssertLessThan(
            scaled / base, Self.growthThreshold,
            "×\(Self.growthScale) the document must not cost ×\(Self.growthScale * Self.growthScale) — \(base)s → \(scaled)s"
        )
    }

    /// The budget bounds re-casing, never the text. Whatever the snippet produces is still shown.
    func testCaseBudgetNeverDropsOutput() {
        let blocks = 3_000
        let opens = String(repeating: "%case:upper% ", count: blocks)
        let payload = String(repeating: "a", count: 20_000)

        let rendered = MacroPreview.render(opens + payload)

        // The payload plus the separating space each block contributed. Case blocks themselves
        // emit nothing, so nothing else should be there — and nothing should be missing.
        XCTAssertEqual(
            rendered.count, payload.count + blocks,
            "every character the snippet produces must survive, cased or not"
        )
        // Case-insensitively: the blocks that ran before the budget was spent did their job, so
        // some of this is uppercase. What matters is that all of it is still here.
        XCTAssertTrue(
            rendered.lowercased().hasSuffix(payload),
            "the payload must be intact and untruncated"
        )
    }

    /// Ordinary nesting is thousands of times under the ceiling and must still transform.
    func testOrdinaryCaseBlocksStillTransform() {
        XCTAssertEqual(MacroPreview.render("%case:upper%hello%caseend% world"), "HELLO world")
        XCTAssertEqual(MacroPreview.render("%case:upper%a%case:lower%B%caseend%c%caseend%"), "ABC")
        XCTAssertEqual(MacroPreview.render("%case:upper%unclosed"), "UNCLOSED")
    }

    func testAllowanceScalesWithInputAndHasAFloor() {
        XCTAssertEqual(MacroParser.scanAllowance(for: ""), 200_000, "short input still gets a floor")
        XCTAssertEqual(MacroParser.scanAllowance(for: String(repeating: "a", count: 100_000)), 400_000)
    }
}
