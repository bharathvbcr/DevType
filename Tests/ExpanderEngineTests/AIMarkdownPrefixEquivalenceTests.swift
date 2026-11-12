import XCTest
@testable import ExpanderEngine

/// The block-prefix stripper was rewritten to walk slices instead of rebuilding the remainder of
/// the line on every layer. The old shape looked linear — its comment said so — but the layer
/// count is bounded by the marker count and each layer copied everything left, so a line of
/// nothing but markers was quadratic. `Remove Markdown` runs synchronously on selected text of up
/// to 200,000 characters, on the thread that then has to draw the preview.
///
/// A rewrite of text-processing logic this fiddly is only worth having if it produces exactly
/// what it replaced, so the previous algorithm is reproduced here verbatim and the two are
/// compared over generated marker soup.
final class AIMarkdownPrefixEquivalenceTests: XCTestCase {

    // MARK: - The previous implementation, kept verbatim as the oracle

    private func referenceStrippingBlockPrefixes(
        _ line: String,
        allowed: AIMarkdownConstruct
    ) -> String {
        var result = line
        for _ in 0..<max(1, line.count) {
            let next = referenceOneLayer(result, allowed: allowed)
            if next == result { break }
            result = next
        }
        return result
    }

    private func referenceOneLayer(_ line: String, allowed: AIMarkdownConstruct) -> String {
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        var rest = String(line.dropFirst(indent.count))

        if allowed.contains(.blockquote) {
            var scan = Substring(rest)
            var unwrapped = false
            while true {
                let afterSpaces = scan.drop(while: { $0 == " " || $0 == "\t" })
                guard afterSpaces.hasPrefix(">") else { break }
                scan = afterSpaces.dropFirst()
                if scan.hasPrefix(" ") { scan = scan.dropFirst() }
                unwrapped = true
            }
            if unwrapped { rest = String(scan) }
        }

        if allowed.contains(.heading), rest.hasPrefix("#") {
            let hashes = rest.prefix(while: { $0 == "#" }).count
            let after = rest.dropFirst(hashes)
            if hashes <= 6, after.isEmpty || after.first == " " || after.first == "\t" {
                rest = String(after.drop(while: { $0 == " " || $0 == "\t" }))
                let tail = rest.reversed().prefix(while: { $0 == "#" }).count
                if tail > 0 {
                    let withoutTail = String(rest.dropLast(tail))
                    if withoutTail.isEmpty || withoutTail.hasSuffix(" ") {
                        while rest.hasSuffix("#") { rest.removeLast() }
                        while rest.hasSuffix(" ") { rest.removeLast() }
                    }
                }
            }
        }

        if allowed.contains(.list), let marker = rest.first, marker == "*" || marker == "+" {
            let after = rest.dropFirst()
            if after.first == " " || after.first == "\t" {
                return indent + "-" + after
            }
        }

        return indent + rest
    }

    // MARK: - Equivalence

    private func assertMatchesReference(
        _ line: String,
        allowed: AIMarkdownConstruct = .all,
        file: StaticString = #filePath,
        line codeLine: UInt = #line
    ) {
        XCTAssertEqual(
            AIMarkdownStripper.strippingBlockPrefixes(line, allowed: allowed),
            referenceStrippingBlockPrefixes(line, allowed: allowed),
            "diverged on \(line.debugDescription)",
            file: file,
            line: codeLine
        )
    }

    func testKnownShapesMatchTheReference() {
        for line in [
            "# Title",
            "## Title ##",
            "###### deep",
            "####### too many hashes",
            "#nospace",
            "> quoted",
            ">  > nested with spaces",
            "> ## quoted heading",
            ">   # heading behind blockquote and indent",
            "  > indented quote",
            "\t> tab indented",
            "* item",
            "+ item",
            "*emphasis not a list",
            "> * quoted list",
            "  # # # stacked",
            "# ## ### mixed",
            "#",
            "# ",
            "   ",
            "",
            "plain text",
            "# Title #",
            "# Title ##  ",
            "> ",
            ">",
            "># tight",
            "#\t tab after hash",
        ] {
            assertMatchesReference(line)
        }
    }

    /// Every subset of the allowed-construct set matters: `original` text containing the author's
    /// own Markdown removes constructs from `allowed`, and the branches interact.
    func testEveryConstructSubsetMatchesTheReference() {
        let constructs: [AIMarkdownConstruct] = [.heading, .blockquote, .list]
        let samples = ["> # * x", "  >  ## * y ##", "# > + z", ">>> ## w"]
        for mask in 0..<8 {
            var allowed = AIMarkdownConstruct.all
            for (bit, construct) in constructs.enumerated() where mask & (1 << bit) != 0 {
                allowed.subtract(construct)
            }
            for sample in samples {
                assertMatchesReference(sample, allowed: allowed)
            }
        }
    }

    func testGeneratedMarkerSoupMatchesTheReference() {
        let alphabet: [String] = ["#", ">", "*", "+", " ", "\t", "a", "-", "#\t", "> ", "# "]
        for seed in 0..<200 {
            var rng = SplitMix64(seed: UInt64(seed))
            let length = 1 + Int(rng.next() % 18)
            var line = ""
            for _ in 0..<length {
                line += alphabet[Int(rng.next() % UInt64(alphabet.count))]
            }
            assertMatchesReference(line)
        }
    }

    // MARK: - The bound the rewrite exists for

    /// What the old shape actually cost, measured on this machine: one pass per marker, each
    /// copying the whole remainder. At the 200,000-character selection cap (100,000 stacked
    /// markers) that was 0.34s of synchronous work on the thread that then draws the preview,
    /// against 0.11s now — a hitch rather than the hang the shape suggests, because the line
    /// stays in cache. The defect is the growth curve, so that is what this pins: absolute
    /// timings just track whatever machine runs them.
    ///
    /// The old shape is quadratic in principle, but each layer's fixed cost dominates its copy
    /// until the line is long, so it grows only a little faster than linear at the sizes a unit
    /// test can afford. Thread CPU time in a debug build, least of several runs: this code costs
    /// 0.016s at 12,500 markers and 0.123s at 100,000 (×7.8, linear); the old per-layer copy
    /// costs 0.023s and 0.416s (×17.7). Doubling could not tell them apart (the old shape read
    /// ×2.2 to ×2.9 per doubling), so the input grows eightfold and the threshold sits between
    /// the two measured growths, not at the midpoint of ×8 and ×64, which the old shape never
    /// reaches. `testTheGrowthGateFlagsTheOldPerLayerCopy` fails if it stops separating them.
    /// Each size is timed the way `BenchmarkGate.growthMinimums` explains; one wall-clock sample
    /// per size made this test fail on linear code in loaded full-suite runs.
    private static let growthBaseMarkers = 12_500
    private static let growthScale = 8
    private static let growthThreshold = 12.0

    private func stackedHeadings(_ markers: Int) -> String {
        String(repeating: "# ", count: markers) + "payload"
    }

    func testStackedHeadingsScaleSubQuadratically() {
        let base = stackedHeadings(Self.growthBaseMarkers)
        let scaled = stackedHeadings(Self.growthBaseMarkers * Self.growthScale)
        XCTAssertEqual(AIMarkdownStripper.strippingBlockPrefixes(base, allowed: .all), "payload")
        XCTAssertEqual(AIMarkdownStripper.strippingBlockPrefixes(scaled, allowed: .all), "payload")

        let growth = BenchmarkGate.growthMinimums(base: base, scaled: scaled) {
            _ = AIMarkdownStripper.strippingBlockPrefixes($0, allowed: .all)
        }

        XCTAssertLessThan(
            growth.scaled / growth.base,
            Self.growthThreshold,
            "×\(Self.growthScale) the markers must cost about ×\(Self.growthScale) — \(growth.base)s → \(growth.scaled)s"
        )
    }

    /// The measurement above must be able to fail. The previous algorithm, kept verbatim as the
    /// oracle, copies the remainder on every layer; through the same gate it must read as
    /// quadratic, or the scaling test would pass a return to that shape.
    func testTheGrowthGateFlagsTheOldPerLayerCopy() {
        let base = stackedHeadings(Self.growthBaseMarkers)
        let scaled = stackedHeadings(Self.growthBaseMarkers * Self.growthScale)

        let growth = BenchmarkGate.growthMinimums(rounds: 3, base: base, scaled: scaled) {
            _ = referenceStrippingBlockPrefixes($0, allowed: .all)
        }

        XCTAssertGreaterThan(
            growth.scaled / growth.base,
            Self.growthThreshold,
            "the old per-layer copy must read as quadratic — \(growth.base)s → \(growth.scaled)s"
        )
    }

    /// The same input through the entry point the UI actually calls, at the largest selection
    /// `Remove Markdown` will accept. A generous ceiling: this is a guard against a return to
    /// unbounded work, not a benchmark.
    func testRemoveMarkdownAtTheSelectionCapStaysResponsive() {
        let input = String(repeating: "# ", count: 100_000) + "payload"

        let started = Date()
        let stripped = AIMarkdownStripper.strip(input, policy: .strip, original: "")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(stripped, "payload")
        XCTAssertLessThan(elapsed, 5.0, "Remove Markdown must stay bounded: took \(elapsed)s")
    }
}
