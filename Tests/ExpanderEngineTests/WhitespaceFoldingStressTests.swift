import XCTest
@testable import ExpanderEngine

/// Stress and property coverage for the whitespace-folding comparison class (the "`slm
/// incident": ProseMirror stored a typed trailing space as U+00A0 and the erase precondition
/// refused, logging two identical-looking strings).
///
/// The fold's contract has three parts, each attacked here:
///  1. **Complete** — every Unicode separator folds; proven by sweeping the entire BMP against
///     the platform's live Unicode tables, not a hand-copied list.
///  2. **Conservative** — nothing that is not a separator (or CR) changes, and folding is 1:1
///     in UTF-16 units, so every caret/erase-count computed on raw text stays valid.
///  3. **Bounded** — huge fields never pay a full-value fold on the caret-window path.
final class WhitespaceFoldingStressTests: XCTestCase {

    /// Deterministic PRNG — every fuzz failure reproduces byte-for-byte from the seed.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Every BMP Zs member, for substitution fuzzing.
    private static let spaceSeparators: [Character] = [
        "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}",
        "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}",
        "\u{205F}", "\u{3000}",
    ]

    /// Mixed alphabet: ASCII, backtick-free words, emoji (single + ZWJ family + flag),
    /// combining marks, CJK, Hangul, separators, controls.
    private static let fuzzAlphabet: [Character] = Array("abcXYZ09._-") + [
        "👍", "👨‍👩‍👧‍👦", "🇯🇵", "e\u{0301}", "漢", "한", "ß", "\t", "\n", "\r",
        "\u{00A0}", "\u{202F}", "\u{3000}", "\u{2028}", "\u{2029}",
    ]

    // MARK: - 1. Completeness: exhaustive BMP sweep against the live Unicode tables

    func testFoldCoversEveryBMPSeparatorAndTouchesNothingElse() {
        for u in UInt32(0)...0xFFFF {
            let unit = UInt16(u)
            let folded = String.foldedWhitespaceUnit(unit)
            guard let scalar = Unicode.Scalar(u) else {
                // Surrogate halves — must pass through untouched.
                XCTAssertEqual(folded, unit, "surrogate half U+\(String(format: "%04X", u))")
                continue
            }
            switch scalar.properties.generalCategory {
            case .spaceSeparator:
                XCTAssertEqual(
                    folded, 0x0020,
                    "Zs U+\(String(format: "%04X", u)) must fold to space — fold table has a gap"
                )
            case .lineSeparator, .paragraphSeparator:
                XCTAssertEqual(
                    folded, 0x000A,
                    "Zl/Zp U+\(String(format: "%04X", u)) must fold to LF"
                )
            default:
                if unit == 0x000D {
                    XCTAssertEqual(folded, 0x000A, "CR folds to LF (Word-for-Mac paragraph breaks)")
                } else {
                    XCTAssertEqual(
                        folded, unit,
                        "U+\(String(format: "%04X", u)) is not a separator and must not change"
                    )
                }
            }
        }
    }

    // MARK: - 2. Conservation properties under fuzz

    func testFoldPreservesUTF16CountAndIsIdempotentUnderFuzz() {
        var rng = SplitMix64(seed: 0xD3B_7A9E)
        for _ in 0..<2_000 {
            let length = Int.random(in: 0..<60, using: &rng)
            let s = String((0..<length).map { _ in Self.fuzzAlphabet.randomElement(using: &rng)! })
            let folded = s.normalizedWhitespace
            XCTAssertEqual(
                folded.utf16.count, s.utf16.count,
                "fold changed UTF-16 length for \(s.unicodeScalars.map { String(format: "U+%04X", $0.value) })"
            )
            XCTAssertEqual(folded.normalizedWhitespace, folded, "fold must be idempotent")
        }
    }

    func testFoldIsIdentityWhenNothingIsFoldable() {
        let clean = "plain ascii with spaces\tand\ntabs 👍 漢字"
        XCTAssertEqual(clean.normalizedWhitespace, clean)
    }

    // MARK: - 3. Precondition fuzz: separator substitutions pass, visible corruption refuses

    func testPreconditionAcceptsAnySeparatorSubstitutionUnderFuzz() {
        var rng = SplitMix64(seed: 0x51AB_1E)
        for _ in 0..<1_000 {
            let trigger = "`fz trig x "   // multi-space trigger; backtick keeps it unique
            var mutated = ""
            for ch in trigger {
                if ch == " ", Bool.random(using: &rng) {
                    mutated.append(Self.spaceSeparators.randomElement(using: &rng)!)
                } else {
                    mutated.append(ch)
                }
            }
            let prefixLen = Int.random(in: 0..<30, using: &rng)
            let prefix = String((0..<prefixLen).map { _ in "abcdefgh 👍漢".randomElement(using: &rng)! })
            let value = prefix + mutated
            let result = ErasePreconditionChecker.evaluate(
                plan: ErasePlan(text: trigger),
                value: value,
                caretLocation: value.utf16.count,
                selectionLength: 0
            )
            XCTAssertEqual(
                result, .ok,
                "substituted separators must match; field=\(mutated.unicodeScalars.map { String(format: "U+%04X", $0.value) })"
            )
        }
    }

    func testPreconditionRefusesVisibleCorruptionUnderFuzz() {
        var rng = SplitMix64(seed: 0xBAD_C0DE)
        for _ in 0..<1_000 {
            let trigger = "`fz trig "
            // Corrupt one visible (non-space, non-backtick) character.
            var chars = Array(trigger)
            let corruptible = chars.indices.filter { chars[$0] != " " && chars[$0] != "`" }
            let idx = corruptible.randomElement(using: &rng)!
            chars[idx] = chars[idx] == "z" ? "q" : "z"
            let corrupted = String(chars)
            // Backtick-free prefix so the intact trigger cannot appear anywhere else in the
            // value — otherwise the §8.6 geometry downgrade legitimately absorbs the mismatch.
            let prefix = String((0..<Int.random(in: 0..<30, using: &rng)).map { _ in "abcdefgh ".randomElement(using: &rng)! })
            let value = prefix + corrupted
            let result = ErasePreconditionChecker.evaluate(
                plan: ErasePlan(text: trigger),
                value: value,
                caretLocation: value.utf16.count,
                selectionLength: 0
            )
            XCTAssertTrue(
                result.blocksErase,
                "visible corruption \(corrupted) must refuse, got \(result)"
            )
        }
    }

    /// Whitespace folding must fold symmetrically: a snippet-defined trigger carrying an NBSP
    /// matches a field where the host stored a plain space.
    func testPreconditionAcceptsReverseDirectionSubstitution() {
        let value = "note `fz trig "
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "`fz\u{00A0}trig\u{202F}"),
            value: value,
            caretLocation: value.utf16.count,
            selectionLength: 0
        )
        XCTAssertEqual(result, .ok)
    }

    /// Word for Mac reports paragraph breaks as CR; a multiline expected text must still verify.
    func testPreconditionAcceptsCarriageReturnForLineFeed() {
        let value = "line1\rline2"
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "line1\nline2"),
            value: value,
            caretLocation: value.utf16.count,
            selectionLength: 0
        )
        XCTAssertEqual(result, .ok)
    }

    /// The fold must never turn a genuinely different whitespace COUNT into a match — "`slm  "
    /// (two spaces) is not "`slm " no matter how the spaces are encoded.
    func testFoldDoesNotMaskWhitespaceCountDifferences() {
        let value = "`slm\u{00A0}\u{00A0}"
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "`slm "),
            value: value,
            caretLocation: value.utf16.count,
            selectionLength: 0
        )
        XCTAssertNotEqual(result, .ok, "two NBSPs must not match one expected space")
    }

    // MARK: - 4. Garbage caret geometry degrades, never refuses

    func testNegativeCaretDegradesToUnavailable() {
        // CFRange kCFNotFound (-1) is a real host answer for "no selection info" — refusing
        // would block every expansion in that host.
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "`slm "),
            value: "some field text `slm ",
            caretLocation: -1,
            selectionLength: 0
        )
        guard case .unavailable = result else {
            return XCTFail("negative caret is unparseable geometry, not a mismatch — got \(result)")
        }
    }

    func testNegativeSelectionLengthDegradesToUnavailable() {
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "`slm "),
            value: "some field text `slm ",
            caretLocation: 21,
            selectionLength: -1
        )
        guard case .unavailable = result else {
            return XCTFail("negative selection length is unparseable geometry — got \(result)")
        }
    }

    /// A caret landing mid-surrogate-pair must never crash and never falsely pass — the sliced
    /// lone surrogate reconstructs as U+FFFD, which cannot equal any expected text.
    func testCaretMidSurrogatePairNeverPassesOrCrashes() {
        let value = String(repeating: "👍", count: 8) // 16 units
        for caret in 0...value.utf16.count {
            let result = ErasePreconditionChecker.evaluate(
                plan: ErasePlan(text: "ab"),
                value: value,
                caretLocation: caret,
                selectionLength: 0
            )
            XCTAssertNotEqual(result, .ok, "caret \(caret) sliced emoji must never read as \"ab\"")
        }
    }

    // MARK: - 5. boundedContains adversarial

    func testBoundedContainsFindsFoldedNeedleInHugeFieldNearCaret() {
        // > maxVerificationScanUTF16, forcing the caret-window path.
        let filler = String(repeating: "x", count: DeliveryVerifier.maxVerificationScanUTF16)
        let value = filler + "`slm\u{00A0}tail"
        let caret = value.utf16.count - 4
        XCTAssertEqual(
            DeliveryVerifier.boundedContains("`slm ", in: value, caretLocation: caret), true
        )
    }

    func testBoundedContainsHugeEmojiFieldWithMidPairCaretDoesNotCrash() {
        let value = String(repeating: "👍", count: 20_000) // 40k units, every offset mid-pair risk
        for caret in [0, 1, 3, 20_001, 39_999, 40_000] {
            _ = DeliveryVerifier.boundedContains("👍👍", in: value, caretLocation: caret)
        }
        XCTAssertEqual(
            DeliveryVerifier.boundedContains("👍👍", in: value, caretLocation: 39_999), true
        )
    }

    func testBoundedContainsCaretOutOfRangeIsUnjudgeableNotMiss() {
        let value = String(repeating: "y", count: DeliveryVerifier.maxVerificationScanUTF16 + 10)
        XCTAssertNil(DeliveryVerifier.boundedContains("needle", in: value, caretLocation: nil))
        XCTAssertNil(DeliveryVerifier.boundedContains("needle", in: value, caretLocation: -5))
        XCTAssertNil(
            DeliveryVerifier.boundedContains("needle", in: value, caretLocation: value.utf16.count + 1)
        )
    }

    func testBoundedContainsSmallFieldFastPathFoldsBothSides() {
        XCTAssertEqual(DeliveryVerifier.boundedContains("a b", in: "xa\u{3000}bz", caretLocation: nil), true)
        XCTAssertEqual(DeliveryVerifier.boundedContains("a\u{2009}b", in: "xa bz", caretLocation: nil), true)
    }

    /// The §2.6 bound must hold after folding was added: the caret-window path on a multi-
    /// megabyte NBSP-bearing field must not fold the whole value per call. 300 calls complete
    /// in well under the budget when bounded (~µs each); a full-value fold per call (~10 ms+
    /// each on 8M units) blows through it by an order of magnitude.
    func testBoundedContainsHugeFieldStaysBounded() {
        let value = String(repeating: "abc\u{00A0}efgh", count: 1_000_000) // 8M units, NBSP-laden
        let caret = value.utf16.count - 100
        let start = Date()
        for _ in 0..<300 {
            _ = DeliveryVerifier.boundedContains("abc efgh", in: value, caretLocation: caret)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, StressWallClock.quadraticCanary,
            "caret-window scan is folding the full value again — §2.6 regression"
        )
    }

    // MARK: - 6. Undo path under folding

    func testWidenedUndoLocatesNBSPifiedInjectedText() {
        let injected = "Kind regards Bharath"
        let fieldStored = "Kind\u{00A0}regards\u{00A0}Bharath" // host re-encoded the spaces
        let value = "prefix " + fieldStored + "ab"
        let widened = TextInjectionPipeline.widenedUndo(
            injectedText: injected,
            triggerText: "`kr",
            value: value,
            caretLocation: value.utf16.count
        )
        XCTAssertNotNil(widened, "NBSP re-encoding must not hide the injected text from undo")
        XCTAssertEqual(widened?.plan.expectedText, injected + "ab")
        XCTAssertEqual(widened?.restore, "`kr" + "ab")
    }

    func testWidenedUndoStillRefusesCorruptedInjectedText() {
        let value = "prefix KIND regards Bharathab"   // case differs — not our injected text
        XCTAssertNil(TextInjectionPipeline.widenedUndo(
            injectedText: "Kind regards Bharath",
            triggerText: "`kr",
            value: value,
            caretLocation: value.utf16.count
        ))
    }

    /// Undo strict mode + folding together: an NBSP-stored injected text at the caret passes
    /// even with the §8.6 downgrade opted out.
    func testUndoModePassesOnFoldedMatchAtCaret() {
        let value = "ScholarLM\u{00A0}Rocks"
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "ScholarLM Rocks"),
            value: value,
            caretLocation: value.utf16.count,
            selectionLength: 0,
            insertionPointFollowsExpectedText: false
        )
        XCTAssertEqual(result, .ok)
    }

    // MARK: - 7. Delivery verification under folding

    func testVerifyTextDeliveryAcceptsSeparatorReencodedSelectedText() {
        let verification = DeliveryVerifier.verifyTextDelivery(
            expectedText: "pasted text ",
            baseline: DeliveryObservationFixture.at("", 0),
            after: DeliveryObservationFixture.at("pasted\u{00A0}text\u{202F}", 0, 12, selectedText: "pasted\u{00A0}text\u{202F}")
        )
        XCTAssertEqual(verification, .delivered)
    }

    func testVerifyTextDeliveryAcceptsParagraphSeparatorForNewline() {
        let verification = DeliveryVerifier.verifyTextDelivery(
            expectedText: "line1\nline2",
            baseline: DeliveryObservationFixture.at("doc: ", 5),
            after: DeliveryObservationFixture.at("doc: line1\u{2029}line2", 16)
        )
        XCTAssertEqual(verification, .delivered)
    }
}
