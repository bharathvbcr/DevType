import XCTest
@testable import ExpanderEngine

// Adversarial stress over every surface hardened in this audit: nested-snippet
// graphs (cycles, diamonds, mixed syntax), counter specs, and AX range math.
// All randomness is seeded (SplitMix64) so any failure reproduces exactly.

final class HardeningStressTests: XCTestCase {

    private func timed(_ body: () -> Void) -> TimeInterval {
        let started = Date()
        body()
        return Date().timeIntervalSince(started)
    }

    // MARK: - Nested snippet graphs

    /// Two-node cycle: a → b → a. Depth cap ends it; budget keeps output bounded.
    func testCycleGraphTerminatesAndStaysBounded() {
        let table = [
            "a": "%snippet:b%",
            "b": "%snippet:a% some ",
        ]
        let elapsed = timed {
            let result = MacroRenderer.expand(content: table["a"]!, lookup: { table[$0] })
            XCTAssertLessThanOrEqual(result.text.utf16.count, MacroParser.NestedSnippetBudget.defaultMaxOutputUTF16Count)
        }
        XCTAssertLessThan(elapsed, StressWallClock.terminationGuard)
    }

    /// Diamond: a → {b, c}, b → d ×N, c → d ×N — shared subtree resolved many
    /// times must not multiply past the budget.
    func testDiamondGraphTerminatesAndStaysBounded() {
        let table = [
            "a": "%snippet:b% %snippet:c%",
            "b": Array(repeating: "%snippet:d%", count: 50).joined(separator: " "),
            "c": Array(repeating: "%snippet:d%", count: 50).joined(separator: " "),
            "d": String(repeating: "leaf ", count: 20),
        ]
        let elapsed = timed {
            let result = MacroRenderer.expand(content: table["a"]!, lookup: { table[$0] })
            XCTAssertLessThanOrEqual(result.text.utf16.count, MacroParser.NestedSnippetBudget.defaultMaxOutputUTF16Count)
        }
        XCTAssertLessThan(elapsed, StressWallClock.terminationGuard)
    }

    /// Mixed TE + mustache syntax referencing each other across engines.
    func testCrossSyntaxCycleTerminates() {
        let table = [
            "te": "{{snippet:mus}} te-tail",
            "mus": "%snippet:te% mus-tail",
        ]
        let elapsed = timed {
            let result = MacroRenderer.expand(content: table["te"]!, lookup: { table[$0] })
            XCTAssertLessThanOrEqual(result.text.utf16.count, MacroParser.NestedSnippetBudget.defaultMaxOutputUTF16Count)
        }
        XCTAssertLessThan(elapsed, StressWallClock.terminationGuard)
    }

    /// Seeded random reference graphs: every expansion terminates quickly and
    /// never exceeds the ceiling.
    func testRandomReferenceGraphsStayBounded() {
        for seed: UInt64 in [1, 7, 42, 2026, 0xDEADBEEF] {
            var rng = SplitMix64(seed: seed)
            let names = (0..<40).map { "s\($0)" }
            var table: [String: String] = [:]
            for name in names {
                let refs = (0..<Int(rng.next() % 8)).map { _ in names[Int(rng.next() % UInt64(names.count))] }
                table[name] = refs.isEmpty
                    ? String(repeating: "x", count: Int(rng.next() % 200))
                    : refs.map { rng.next() % 2 == 0 ? "%snippet:\($0)%" : "{{snippet:\($0)}}" }
                        .joined(separator: " ")
            }
            let entry = names[Int(rng.next() % UInt64(names.count))]

            let elapsed = timed {
                let result = MacroRenderer.expand(content: table[entry]!, lookup: { table[$0] })
                XCTAssertLessThanOrEqual(
                    result.text.utf16.count,
                    MacroParser.NestedSnippetBudget.defaultMaxOutputUTF16Count,
                    "seed \(seed): output exceeded the ceiling"
                )
            }
            XCTAssertLessThan(elapsed, StressWallClock.terminationGuard, "seed \(seed) took \(elapsed)s")
        }
    }

    // MARK: - Counter spec fuzz

    /// Random spec strings must parse without trapping and keep steps bounded.
    func testCounterSpecFuzzNeverProducesUnboundedStep() {
        var rng = SplitMix64(seed: 99)
        let pieces = ["invoice", ":", "+", "-", "9", "2147483647", "9223372036854775807",
                      "-9223372036854775808", " ", "abc", "%", ""]
        for _ in 0..<10_000 {
            let parts = (0..<(Int(rng.next() % 6) + 1)).map { _ in pieces[Int(rng.next() % UInt64(pieces.count))] }
            let spec = parts.joined()
            let parsed = MacroCounterSpec.parse(spec)
            XCTAssertLessThanOrEqual(abs(parsed.step), MacroCounterSpec.maxStepMagnitude, "spec '\(spec)'")
        }
    }

    /// A counter driven to the edge by extreme steps matches an independent
    /// saturating-arithmetic reference exactly (no traps, no drift).
    func testExtremeAdvanceSequencesRemainSane() {
        let store = MacroCounterStore(
            defaults: UserDefaults(suiteName: "devtype.tests.stress.counter")!,
            defaultsKey: "stress.\(UUID().uuidString)"
        )
        // Reference model — written with reporting arithmetic so the test itself
        // can never trap (abs(Int.min) would).
        func saturating(_ a: Int, _ b: Int) -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            return overflow ? (b > 0 ? .max : .min) : sum
        }
        let steps: [Int] = [.max, .min, .max, 1, -1, .max, .min, 1_000_000]
        var expected = 0
        for step in steps {
            expected = saturating(expected, step)
            XCTAssertEqual(
                store.advance("edge", by: step), expected,
                "advance(\(step)) diverged from the saturating reference"
            )
        }
    }

    // MARK: - AX range fuzz

    /// Random ranges — including sentinel extremes — never trap and only ever
    /// produce valid widened ranges.
    func testWidenedRangeFuzzNeverTrapsAndHonorsInvariants() {
        var rng = SplitMix64(seed: 314159)
        let extremes: [Int] = [0, 1, -1, Int.max, Int.min, Int.max / 2,
                               AXTextWriter.maxPlausibleAXUTF16Units,
                               AXTextWriter.maxPlausibleAXUTF16Units + 1]
        for _ in 0..<100_000 {
            let location = rng.next() % 3 == 0
                ? extremes[Int(rng.next() % UInt64(extremes.count))]
                : Int(bitPattern: rng.next() & 0xFFFF_FFFF_FFFF)
            let length = rng.next() % 3 == 0
                ? extremes[Int(rng.next() % UInt64(extremes.count))]
                : Int(bitPattern: rng.next() & 0xFFFF_FFFF_FFFF)
            let erase = Int(bitPattern: rng.next() & 0xFFFF)

            if let widened = AXTextWriter.widenedRange(from: CFRange(location: location, length: length), eraseCount: erase) {
                // Any produced range must be a legal selection: non-negative and
                // covering at least what the original selection claimed.
                XCTAssertGreaterThanOrEqual(widened.location, 0, "location \(location)/\(length)/\(erase)")
                XCTAssertGreaterThanOrEqual(widened.length, 0, "length \(location)/\(length)/\(erase)")
                XCTAssertGreaterThanOrEqual(widened.length, length, "widening lost selection \(location)/\(length)/\(erase)")
            } else {
                // Refusal is only allowed for unusable inputs.
                XCTAssertFalse(
                    location >= 0 && length >= 0
                        && location <= AXTextWriter.maxPlausibleAXUTF16Units
                        && length <= AXTextWriter.maxPlausibleAXUTF16Units,
                    "usable range (\(location), \(length)) was refused"
                )
            }
        }
    }

    // MARK: - Import limits under fuzz

    /// Boundary values around every limit behave exactly as documented.
    func testImportLimitBoundariesAreExact() {
        let limits = SnippetImporter.SnippetImportLimits.self
        XCTAssertEqual(
            limits.isOversized(trigger: String(repeating: "t", count: limits.maxTriggerCharacters),
                               replacement: ""),
            false
        )
        XCTAssertEqual(
            limits.isOversized(trigger: String(repeating: "t", count: limits.maxTriggerCharacters + 1),
                               replacement: ""),
            true
        )
        XCTAssertEqual(
            limits.isOversized(trigger: "",
                               replacement: String(repeating: "r", count: limits.maxReplacementCharacters)),
            false
        )
        XCTAssertEqual(
            limits.isOversized(trigger: "",
                               replacement: String(repeating: "r", count: limits.maxReplacementCharacters + 1)),
            true
        )
    }
}
