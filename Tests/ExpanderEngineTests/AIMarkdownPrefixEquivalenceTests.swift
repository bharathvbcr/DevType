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
    /// Doubling the input doubles linear work and quadruples quadratic work. The threshold sits
    /// between the two so an accidental return to per-pass copying fails here.
    func testStackedHeadingsScaleSubQuadratically() {
        func elapsed(markers: Int) -> TimeInterval {
            let line = String(repeating: "# ", count: markers) + "payload"
            _ = AIMarkdownStripper.strippingBlockPrefixes(line, allowed: .all)  // warm
            let started = Date()
            let stripped = AIMarkdownStripper.strippingBlockPrefixes(line, allowed: .all)
            let took = Date().timeIntervalSince(started)
            XCTAssertEqual(stripped, "payload")
            return took
        }

        let single = max(elapsed(markers: 25_000), 0.0005)
        let double = elapsed(markers: 50_000)

        XCTAssertLessThan(
            double / single,
            3.0,
            "doubling the markers must not quadruple the work — \(single)s → \(double)s"
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
