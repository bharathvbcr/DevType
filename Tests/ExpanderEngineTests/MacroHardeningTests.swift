import XCTest
@testable import ExpanderEngine

// Hardening regressions: crafted macro specs and pathological snippet libraries
// must never trap, hang, or inject unbounded text. Every test here encodes a
// defect found by audit (crash-looping counter, combinatorial nested fan-out)
// and pins the bounded, fail-safe behavior.

final class MacroCounterOverflowTests: XCTestCase {

    private func isolatedStore(_ label: String = #function) -> MacroCounterStore {
        let suite = "devtype.tests.counter.overflow.\(label)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MacroCounterStore(defaults: defaults, defaultsKey: suite + ".values")
    }

    /// `%counter:x:+9223372036854775807%`: the first expansion persists Int.max,
    /// the second used to trap (`Fatal error: Integer addition overflow`) and the
    /// poisoned value survived relaunch, making every retype of the abbreviation
    /// crash the app until the snippet was deleted.
    func testAdvancingByIntMaxTwiceSaturatesInsteadOfTrapping() {
        let store = isolatedStore()
        XCTAssertEqual(store.advance("bomb", by: .max), .max)
        XCTAssertEqual(store.advance("bomb", by: .max), .max, "second advance must saturate, not trap")
    }

    func testAdvancingBelowIntMinSaturatesInsteadOfTrapping() {
        let store = isolatedStore()
        XCTAssertEqual(store.advance("floor", by: .min), .min)
        XCTAssertEqual(store.advance("floor", by: .min), .min, "second advance must saturate, not trap")
    }

    /// A poisoned value already persisted in defaults (e.g. from an older build or
    /// hand-edited plist) must not trap the next ordinary advance.
    func testAdvanceFromPersistedMaxValueDoesNotTrap() {
        let store = isolatedStore()
        store.set("poison", to: .max)
        XCTAssertEqual(store.advance("poison", by: 1), .max)
    }

    func testSpecStepIsClampedToSaneMagnitude() {
        let huge = MacroCounterSpec.parse("invoice:+9223372036854775807")
        XCTAssertEqual(huge.name, "invoice")
        XCTAssertLessThanOrEqual(huge.step, MacroCounterSpec.maxStepMagnitude)

        let tiny = MacroCounterSpec.parse("invoice:-9223372036854775808")
        XCTAssertEqual(tiny.name, "invoice")
        XCTAssertGreaterThanOrEqual(tiny.step, -MacroCounterSpec.maxStepMagnitude)

        // Ordinary specs are untouched.
        XCTAssertEqual(MacroCounterSpec.parse("invoice:+3").step, 3)
        XCTAssertEqual(MacroCounterSpec.parse("invoice").step, 1)
    }
}

final class NestedSnippetFanOutTests: XCTestCase {

    private var table: [String: String] = [:]

    private func buildTable(syntax marker: (String) -> String, fanOut: Int, levels: Int, leafSize: Int) {
        table = [:]
        let names = (0..<levels).map { level in
            level == 0 ? "a" : String(UnicodeScalar(UInt8(97 + level)))
        }
        for (index, name) in names.enumerated() {
            if index + 1 < names.count {
                table[name] = Array(repeating: marker(names[index + 1]), count: fanOut).joined()
            } else {
                table[name] = String(repeating: "x", count: leafSize)
            }
        }
    }

    /// Branching nested references multiply: factor F over L levels costs F^L leaf
    /// expansions. Pre-fix there was no aggregate cap, so an ordinary-looking
    /// library (10 refs × 10 levels) turned one typed trigger into ~10¹⁰ substring
    /// builds inside the event-tap callback — a multi-second-to-permanent hang.
    func testBranchingTEChainStaysBoundedAndTerminates() {
        buildTable(syntax: { "%snippet:\($0)%" }, fanOut: 10, levels: 10, leafSize: 64)
        let started = Date()
        let result = MacroRenderer.expand(content: table["a"]!, lookup: { self.table[$0] })
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.0, "expansion took \(elapsed)s — fan-out is not bounded")
        XCTAssertLessThanOrEqual(
            result.text.utf16.count,
            MacroParser.NestedSnippetBudget.defaultMaxOutputUTF16Count,
            "injected output exceeded the hard ceiling"
        )
    }

    /// Same shape through the mustache engine (`{{snippet:x}}`), which resolves
    /// both TE and mustache passes per reference.
    func testBranchingMustacheChainStaysBoundedAndTerminates() {
        buildTable(syntax: { "{{snippet:\($0)}}" }, fanOut: 10, levels: 10, leafSize: 64)
        let started = Date()
        let result = MacroRenderer.expand(content: table["a"]!, lookup: { self.table[$0] })
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.0, "expansion took \(elapsed)s — fan-out is not bounded")
        XCTAssertLessThanOrEqual(
            result.text.utf16.count,
            MacroParser.NestedSnippetBudget.defaultMaxOutputUTF16Count,
            "injected output exceeded the hard ceiling"
        )
    }

    /// Moderate bomb whose full expansion (~3 MB) was cheap enough to compute
    /// pre-fix — proving the output-ceiling contract fails before the fix lands.
    func testModerateBombOutputExceedsCeilingPreFixAndIsCappedPostFix() {
        buildTable(syntax: { "%snippet:\($0)%" }, fanOut: 4, levels: 7, leafSize: 200)
        let result = MacroRenderer.expand(content: table["a"]!, lookup: { self.table[$0] })
        XCTAssertLessThanOrEqual(
            result.text.utf16.count,
            MacroParser.NestedSnippetBudget.defaultMaxOutputUTF16Count
        )
    }

    /// Budget exhaustion degrades gracefully: once spent, remaining references
    /// stay literal — the same contract as depth-cap exhaustion and unresolved
    /// references — instead of corrupting or dropping output.
    func testExhaustedBudgetLeavesRemainingReferencesLiteral() {
        // Note: adjacent `%snippet:a%%snippet:b%` is ONE macro body (`%%` is an
        // escaped literal percent per §3.6), so references here are separated.
        let table: [String: String] = [
            "leaf": "leaf-text",
            "many": Array(repeating: "%snippet:leaf%", count: 6).joined(separator: " "),
        ]
        let tinyBudget = MacroParser.NestedSnippetBudget(maxResolutions: 3)
        let result = MacroParser.resolveNested(
            table["many"]!,
            lookup: { table[$0] },
            budget: tinyBudget
        )

        XCTAssertEqual(tinyBudget.resolutionsPerformed, 3)
        XCTAssertEqual(tinyBudget.outputUTF16Count, "leaf-text".utf16.count * 3)
        XCTAssertEqual(
            result,
            "leaf-text leaf-text leaf-text %snippet:leaf% %snippet:leaf% %snippet:leaf%",
            "first three expand; over-budget references remain literal"
        )
    }

    /// Pins the §3.6 escape rule at nested-reference boundaries: `%%` between
    /// references is an escaped literal percent, not two adjacent macros.
    func testAdjacentSnippetReferencesFormOneEscapedBody() {
        let table: [String: String] = ["a": "A", "b": "B"]
        let result = MacroParser.resolveNested("%snippet:a%%snippet:b%", lookup: { table[$0] })
        XCTAssertTrue(result.contains("%snippet:"), "adjacent refs merge into one unresolved body: \(result)")
    }

    /// Legitimate linear nesting keeps working end to end.
    func testLinearNestingStillExpands() {
        let table: [String: String] = [
            "outer": "Hello %snippet:mid%!",
            "mid": "%snippet:inner% world",
            "inner": "brave",
        ]
        let result = MacroRenderer.expand(content: table["outer"]!, lookup: { table[$0] })
        XCTAssertEqual(result.text, "Hello brave world!")
    }
}
