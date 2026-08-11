import XCTest
@testable import ExpanderEngine

/// Adversarial sweeps over the erase-precondition / undo-widening / bounded-scan machinery.
///
/// These are property tests, not example tests: each run throws thousands of hostile inputs —
/// NBSP variants, surrogate pairs, combining marks, carets off both ends, selections, empty and
/// oversized values — at the pure functions and asserts invariants that must hold for *every*
/// input. Seeded (`SplitMix64`) so a failure reproduces exactly.
final class EraseUndoStressTests: XCTestCase {

    /// Building blocks chosen to hit every comparison path: plain ASCII, foldable whitespace
    /// (NBSP / narrow NBSP / figure space), astral-plane emoji (surrogate pairs), combining
    /// marks, and newline family characters.
    private static let fragments: [String] = [
        "a", "B", "`", "slm", "Scholar", " ",
        "\u{00A0}", "\u{202F}", "\u{2007}",
        "🎓", "👩‍💻", "é", "e\u{0301}",
        "\n", "\r", "\u{2028}",
    ]

    private func randomText(_ rng: inout SplitMix64, maxFragments: Int) -> String {
        let count = Int(rng.next() % UInt64(maxFragments + 1))
        return (0..<count).map { _ in
            Self.fragments[Int(rng.next() % UInt64(Self.fragments.count))]
        }.joined()
    }

    // MARK: - ErasePreconditionChecker.evaluate

    /// For any input whatsoever: never crash, and honour the two mode contracts —
    /// strict mode (undo) never emits the §8.6 best-effort downgrade, and a strict `.ok` is
    /// only ever returned when the folded slice genuinely equals the folded expected text.
    func testEvaluateInvariantsUnderFuzz() {
        var rng = SplitMix64(seed: 0xE5A5_2026_0811)
        for iteration in 0..<4_000 {
            let expected = randomText(&rng, maxFragments: 4)
            let value = randomText(&rng, maxFragments: 12)
            let valueUnits = value.utf16.count
            // Carets deliberately off both ends; selections deliberately negative sometimes.
            let caret = Int(rng.next() % 64) - 8
            let selection = Int(rng.next() % 16) - 4
            let caseInsensitive = rng.next() % 2 == 0
            let plan = ErasePlan(text: expected, caseInsensitive: caseInsensitive)

            for strictMode in [true, false] {
                let result = ErasePreconditionChecker.evaluate(
                    plan: plan,
                    value: value,
                    caretLocation: caret,
                    selectionLength: selection,
                    insertionPointFollowsExpectedText: !strictMode
                )
                if strictMode, case .unavailable(let why) = result {
                    XCTAssertFalse(
                        why.contains("best-effort"),
                        "iter \(iteration): strict mode leaked the §8.6 downgrade — \(why)"
                    )
                }
                if strictMode, case .ok = result, !expected.isEmpty,
                   caret >= plan.utf16Count, caret <= valueUnits {
                    let units = Array(value.utf16)
                    let slice = Array(units[(caret - plan.utf16Count)..<caret])
                    let actual = String(utf16CodeUnits: slice, count: slice.count).normalizedWhitespace
                    let want = expected.normalizedWhitespace
                    let matches = caseInsensitive
                        ? actual.lowercased() == want.lowercased()
                        : actual == want
                    XCTAssertTrue(
                        matches,
                        "iter \(iteration): strict .ok but slice \(actual.debugDescription) ≠ expected \(want.debugDescription)"
                    )
                }
            }
        }
    }

    /// The exact incident geometry, swept: injected text at the head of the field, 0–16 units of
    /// tail between it and the caret. Strict mode must never say "proceed" with a non-empty tail
    /// (that is the blind erase that produced "Sch`slm"); lenient mode documents the §8.6
    /// downgrade for the same shapes.
    func testStrictModeBlocksEveryTailLengthOfTheIncidentShape() {
        let injected = "ScholarLM"
        for tailLength in 1...16 {
            let tail = String(repeating: "x", count: tailLength)
            let value = injected + tail
            let caret = value.utf16.count
            let strict = ErasePreconditionChecker.evaluate(
                plan: ErasePlan(text: injected),
                value: value,
                caretLocation: caret,
                selectionLength: 0,
                insertionPointFollowsExpectedText: false
            )
            XCTAssertTrue(
                strict.blocksErase,
                "tail of \(tailLength): strict undo mode must refuse, got \(strict)"
            )
            let lenient = ErasePreconditionChecker.evaluate(
                plan: ErasePlan(text: injected),
                value: value,
                caretLocation: caret,
                selectionLength: 0
            )
            XCTAssertFalse(
                lenient.blocksErase,
                "tail of \(tailLength): expand mode keeps the §8.6 downgrade, got \(lenient)"
            )
        }
    }

    // MARK: - widenedUndo

    /// For any field state: a non-nil widening must (a) span exactly injected+tail ending at the
    /// caret, (b) restore exactly trigger+tail, (c) never include a newline in the tail, (d) have
    /// located the injected text under whitespace folding at the position it claims.
    ///
    /// Half the iterations are constructed positives — prefix + injected (with spaces swapped for
    /// NBSP variants, as a folding host would store them) + printable tail, caret at the end — so
    /// the non-nil branch is provably exercised; `widenings` asserts that at the bottom. The other
    /// half are pure noise probing for crashes and false positives.
    func testWidenedUndoInvariantsUnderFuzz() {
        var rng = SplitMix64(seed: 0x51D3_2026_0811)
        var widenings = 0
        for iteration in 0..<8_000 {
            let trigger = "`t"
            let injected: String
            let value: String
            let caret: Int
            if iteration % 2 == 0 {
                // Constructed positive. Tail is printable-only and 1...16 chars so the match is
                // *expected* — any nil here would itself be a bug, caught by the hit-count floor.
                injected = ["ScholarLM", "Kind regards", "a b\u{00A0}c", "🎓 cap"][Int(rng.next() % 4)]
                let prefix = randomText(&rng, maxFragments: 3)
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\u{2028}", with: "")
                let tailLength = 1 + Int(rng.next() % 16)
                let tail = String(repeating: "x", count: tailLength)
                // A folding host stores our spaces as NBSP variants — swap some in.
                let storedInjected = rng.next() % 2 == 0
                    ? injected.replacingOccurrences(of: " ", with: "\u{00A0}")
                    : injected
                value = prefix + storedInjected + tail
                caret = value.utf16.count
            } else {
                injected = randomText(&rng, maxFragments: 3)
                value = randomText(&rng, maxFragments: 10)
                caret = Int(rng.next() % 48) - 4
            }

            let result = TextInjectionPipeline.widenedUndo(
                injectedText: injected,
                triggerText: trigger,
                value: value,
                caretLocation: caret
            )
            guard let (plan, restore) = result else {
                XCTAssertNotEqual(
                    iteration % 2, 0,
                    "iter \(iteration): constructed positive failed to widen — injected \(injected.debugDescription) in \(value.debugDescription)"
                )
                continue
            }
            widenings += 1

            let injectedUnits = injected.utf16.count
            let tailUnits = plan.utf16Count - injectedUnits
            XCTAssertGreaterThan(tailUnits, 0, "iter \(iteration): k starts at 1 — a zero tail is the plain plan's job")
            XCTAssertLessThanOrEqual(tailUnits, TextInjectionPipeline.undoMaxTypedAfter, "iter \(iteration): unbounded widening")
            XCTAssertLessThanOrEqual(plan.utf16Count, caret, "iter \(iteration): widened span runs past the caret")

            let units = Array(value.utf16)
            let start = caret - plan.utf16Count
            XCTAssertGreaterThanOrEqual(start, 0, "iter \(iteration): span runs off the front")

            let tailSlice = Array(units[(start + injectedUnits)..<caret])
            let tail = String(utf16CodeUnits: tailSlice, count: tailSlice.count)
            XCTAssertEqual(restore, trigger + tail, "iter \(iteration): restore must be trigger+tail, byte for byte")
            XCTAssertFalse(tail.contains(where: \.isNewline), "iter \(iteration): newline tail must abort widening")

            let locatedSlice = Array(units[start..<(start + injectedUnits)])
            let located = String(utf16CodeUnits: locatedSlice, count: locatedSlice.count)
            XCTAssertEqual(
                located.normalizedWhitespace, injected.normalizedWhitespace,
                "iter \(iteration): widening claims a position where the folded injected text is not"
            )
        }
        // Every constructed positive must have widened — if this floor is missed, the invariants
        // above were vacuous and the test is theater.
        XCTAssertGreaterThanOrEqual(
            widenings, 4_000,
            "constructed positives failed to widen — the interesting branch went unexercised"
        )
    }

    // MARK: - boundedContains at surrogate boundaries

    /// Values past `maxVerificationScanUTF16` take the caret-windowed path, whose window edges are
    /// raw UTF-16 offsets that can land mid-surrogate-pair. Sweep carets across a giant emoji
    /// field: no crash, and a needle physically at the caret is always found.
    func testBoundedContainsSurvivesSurrogateBoundariesInHugeValues() {
        let needle = "`slm "
        // ~40k units of surrogate pairs, above the 32_768 full-scan threshold.
        let filler = String(repeating: "🎓", count: 20_500)
        let value = filler + needle + filler
        let total = value.utf16.count
        let needleEnd = filler.utf16.count + needle.utf16.count

        // Sweep the caret across the needle *and* deep into surrogate territory on both sides —
        // odd offsets land mid-pair by construction.
        for delta in -700...700 {
            let caret = needleEnd + delta
            guard caret >= 0, caret <= total else { continue }
            _ = DeliveryVerifier.boundedContains(needle, in: value, caretLocation: caret)
        }

        // With the caret at the needle, the windowed scan must find it (slack is ±512 units).
        XCTAssertEqual(
            DeliveryVerifier.boundedContains(needle, in: value, caretLocation: needleEnd),
            true,
            "A needle inside the caret window must be found in the windowed path"
        )
        // NBSP-folded variant of the same needle, same window.
        XCTAssertEqual(
            DeliveryVerifier.boundedContains("`slm\u{00A0}", in: value, caretLocation: needleEnd),
            true,
            "Whitespace folding must apply inside the windowed path too"
        )
    }

    /// The windowed path with no caret must answer nil (unknowable), never a confident miss —
    /// a wrong "missing" re-pastes and duplicates.
    func testOversizedValueWithoutCaretIsUnknowableNotMissing() {
        let value = String(repeating: "x", count: DeliveryVerifier.maxVerificationScanUTF16 + 1)
        XCTAssertNil(DeliveryVerifier.boundedContains("needle", in: value, caretLocation: nil))
    }
}
