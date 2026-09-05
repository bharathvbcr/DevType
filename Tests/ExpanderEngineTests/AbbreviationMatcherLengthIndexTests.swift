import XCTest
@testable import ExpanderEngine

/// `AbbreviationMatcher.match` used to try every trigger length from the longest in the library
/// down to 1, building a `String` for each — up to three allocations per candidate length, on
/// every keystroke, inside the CGEventTap callback. Measured at 63 µs per keystroke when the
/// longest trigger was 64 characters, and paid whether or not that trigger was anywhere near
/// the buffer.
///
/// It now consults an index of trigger lengths keyed by final character. That is only sound if
/// it returns *exactly* what the exhaustive scan returned, so these tests hold the new matcher
/// against a reference implementation of the old loop.
final class AbbreviationMatcherLengthIndexTests: XCTestCase {

    private func snippet(
        _ trigger: String,
        caseSensitive: Bool = false,
        requireWordBoundary: Bool = true
    ) -> SnippetModel {
        SnippetModel(
            title: trigger,
            triggerKeyword: trigger,
            replacementText: "→\(trigger)",
            isCaseSensitive: caseSensitive,
            requireWordBoundary: requireWordBoundary
        )
    }

    /// The pre-index loop, verbatim in shape: every length, longest first, both rules.
    private func referenceMatch(
        _ matcher: AbbreviationMatcher,
        _ chars: [Character]
    ) -> AbbreviationMatch? {
        guard matcher.maxLength > 0, !chars.isEmpty else { return nil }
        let n = chars.count
        let upper = min(matcher.maxLength, n)

        func lookup(_ key: String) -> SnippetModel? {
            if let hit = matcher.exact[key] { return hit }
            return matcher.insensitive[key.lowercased()]
        }

        for len in stride(from: upper, through: 1, by: -1) {
            let start = n - len
            let suffixKey = String(chars[start..<n])
            if let hit = lookup(suffixKey) {
                if !AbbreviationMatcher.isWordCharacter(chars[start]) {
                    return AbbreviationMatch(
                        snippet: hit, backspaces: len, terminator: "",
                        triggerLength: len, matchedText: suffixKey
                    )
                }
                if !hit.requireWordBoundary {
                    return AbbreviationMatch(
                        snippet: hit, backspaces: len, terminator: "",
                        triggerLength: len, matchedText: suffixKey
                    )
                }
            }
            let abbrevEnd = n - 1
            let abbrevStart = abbrevEnd - len
            if abbrevStart >= 0,
               !AbbreviationMatcher.isWordCharacter(chars[abbrevEnd]),
               AbbreviationMatcher.isWordCharacter(chars[abbrevStart]),
               abbrevStart == 0 || !AbbreviationMatcher.isWordCharacter(chars[abbrevStart - 1]) {
                let innerKey = String(chars[abbrevStart..<abbrevEnd])
                if let hit = lookup(innerKey), hit.requireWordBoundary {
                    let terminator = String(chars[abbrevEnd])
                    return AbbreviationMatch(
                        snippet: hit, backspaces: len + terminator.count, terminator: terminator,
                        triggerLength: len, matchedText: innerKey
                    )
                }
            }
        }
        return nil
    }

    private func assertAgrees(
        _ snippets: [SnippetModel],
        _ buffers: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matcher = AbbreviationMatcher(snippets: snippets)
        for buffer in buffers {
            let chars = Array(buffer)
            let expected = referenceMatch(matcher, chars)
            let actual = matcher.match(characters: chars)
            XCTAssertEqual(
                actual?.snippet.triggerKeyword, expected?.snippet.triggerKeyword,
                "trigger for buffer \"\(buffer)\"", file: file, line: line
            )
            XCTAssertEqual(
                actual?.matchedText, expected?.matchedText,
                "matchedText for buffer \"\(buffer)\"", file: file, line: line
            )
            XCTAssertEqual(
                actual?.terminator, expected?.terminator,
                "terminator for buffer \"\(buffer)\"", file: file, line: line
            )
            XCTAssertEqual(
                actual?.backspaces, expected?.backspaces,
                "backspaces for buffer \"\(buffer)\"", file: file, line: line
            )
            XCTAssertEqual(
                actual?.triggerLength, expected?.triggerLength,
                "triggerLength for buffer \"\(buffer)\"", file: file, line: line
            )
        }
    }

    // MARK: - The three firing rules still fire

    func testPunctuationStartedTriggerStillFires() {
        assertAgrees(
            [snippet(";sig"), snippet(";sigma")],
            ["hello ;sig", ";sig", "x;sig", ";sigma", ";sigm", ";si"]
        )
    }

    func testWordBoundaryTriggerStillNeedsItsTerminator() {
        assertAgrees(
            [snippet("btw", requireWordBoundary: true)],
            ["btw", "btw ", "btw.", " btw ", "abtw ", "btw\n"]
        )
    }

    func testSuffixTriggerWithoutWordBoundaryStillFiresInstantly() {
        assertAgrees(
            [snippet("btw", requireWordBoundary: false)],
            ["btw", "abtw", "the btw", "bt"]
        )
    }

    /// The merged descending walk exists so a rule (3) match of length L keeps beating a rule
    /// (1)/(2) match of length L-1. Two lengths, two different rules, one buffer.
    func testLongerBoundaryMatchStillBeatsShorterSuffixMatch() {
        assertAgrees(
            [snippet("abcd", requireWordBoundary: true), snippet("bcd.", requireWordBoundary: false)],
            ["abcd.", "xabcd.", " abcd."]
        )
    }

    // MARK: - Case folding

    func testCaseInsensitiveTriggersMatchAnyCasing() {
        assertAgrees(
            [snippet(";Sig", caseSensitive: false)],
            [";sig", ";SIG", ";Sig", ";sIg"]
        )
    }

    func testCaseSensitiveTriggersDoNotMatchOtherCasings() {
        assertAgrees(
            [snippet(";Sig", caseSensitive: true)],
            [";sig", ";SIG", ";Sig"]
        )
    }

    /// The index files a trigger under both its raw final character *and* the final character
    /// of its lowercased form, so folding can never drop a candidate length. Every trigger
    /// ending in an uppercase letter exercises the two-key path.
    ///
    /// Greek pins the boundary of what case-insensitive matching has ever meant here: Swift's
    /// `lowercased()` is character-wise and does not apply the final-sigma rule, so `;ΑΣ` folds
    /// to `;ασ` and a buffer of `;ας` has never matched it. That is unchanged — the point of
    /// this test is that the index did not change it in either direction.
    func testGreekTriggersMatchExactlyAsBefore() {
        assertAgrees(
            [snippet(";ΑΣ", caseSensitive: false, requireWordBoundary: false)],
            [";ΑΣ", ";ας", ";Ας", ";ασ"]
        )
        let matcher = AbbreviationMatcher(
            snippets: [snippet(";ΑΣ", caseSensitive: false, requireWordBoundary: false)]
        )
        XCTAssertNotNil(matcher.match(characters: Array(";ασ")), "character-wise fold still matches")
        XCTAssertNil(matcher.match(characters: Array(";ας")), "final-sigma form has never matched")
    }

    /// The two-key path in the ordinary case: an uppercase final letter is filed under both
    /// spellings, and the buffer is probed with both, so either casing finds the trigger.
    func testUppercaseFinalCharacterIsReachableFromEitherCasing() {
        assertAgrees(
            [snippet(";SIG", caseSensitive: false, requireWordBoundary: false)],
            [";SIG", ";sig", ";Sig", ";siG"]
        )
        let matcher = AbbreviationMatcher(
            snippets: [snippet(";SIG", caseSensitive: false, requireWordBoundary: false)]
        )
        XCTAssertNotNil(matcher.match(characters: Array(";sig")))
        XCTAssertNotNil(matcher.match(characters: Array(";SIG")))
    }

    func testNonLatinTriggersStillMatch() {
        assertAgrees(
            [snippet(";안녕", requireWordBoundary: false), snippet(";こんにちは", requireWordBoundary: false)],
            [";안녕", ";こんにちは", ";안", "안녕"]
        )
    }

    /// An emoji trigger exercises the grapheme-cluster path through the same index.
    func testEmojiTriggerStillMatches() {
        assertAgrees(
            [snippet(";🎉", requireWordBoundary: false), snippet(";👍🏽", requireWordBoundary: false)],
            [";🎉", ";👍🏽", "party ;🎉"]
        )
    }

    // MARK: - App scoping and collisions are unaffected

    func testAppScopedTriggersStillResolveThroughTheIndex() {
        var scoped = snippet(";only", requireWordBoundary: false)
        scoped.includeApps = ["com.example.editor"]
        let matcher = AbbreviationMatcher(snippets: [scoped])
        XCTAssertNotNil(matcher.match(characters: Array(";only"), bundleID: "com.example.editor"))
        XCTAssertNil(matcher.match(characters: Array(";only"), bundleID: "com.example.other"))
    }

    func testCollidingTriggersStillPreferTheFirst() {
        var first = snippet(";dup", requireWordBoundary: false)
        first.replacementText = "first"
        var second = snippet(";dup", requireWordBoundary: false)
        second.replacementText = "second"
        let matcher = AbbreviationMatcher(snippets: [first, second])
        XCTAssertEqual(matcher.match(characters: Array(";dup"))?.snippet.replacementText, "first")
    }

    /// The dictionary-backed initializer is handed tables rather than snippets, and the
    /// insensitive table is keyed lowercased — so the index has to be built from both the key
    /// and the snippet's own trigger or a hand-built matcher silently stops matching.
    func testDictionaryInitializerStillMatches() {
        let snip = snippet(";Sig", caseSensitive: false, requireWordBoundary: false)
        let matcher = AbbreviationMatcher(
            maxLength: 4, exact: [:], insensitive: [";sig": snip]
        )
        XCTAssertNotNil(matcher.match(characters: Array(";sig")))
        XCTAssertNotNil(matcher.match(characters: Array(";SIG")))
    }

    // MARK: - Differential fuzz

    /// The real guarantee: over randomly generated libraries and buffers, the indexed matcher
    /// and the exhaustive scan never disagree.
    func testAgreesWithExhaustiveScanUnderFuzz() {
        var seed: UInt64 = 0xA5A5_1234_DEAD_BEEF
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let letters = Array("abcXY")
        let sigils = Array(";:~ .")

        for _ in 0..<150 {
            var library: [SnippetModel] = []
            for _ in 0..<(1 + next(6)) {
                var trigger = ""
                if next(2) == 0 { trigger.append(sigils[next(sigils.count)]) }
                for _ in 0..<(1 + next(4)) { trigger.append(letters[next(letters.count)]) }
                guard !trigger.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                library.append(snippet(
                    trigger,
                    caseSensitive: next(3) == 0,
                    requireWordBoundary: next(2) == 0
                ))
            }
            guard !library.isEmpty else { continue }

            var buffers: [String] = []
            for _ in 0..<6 {
                var buffer = ""
                for _ in 0..<next(10) {
                    buffer.append(next(3) == 0 ? sigils[next(sigils.count)] : letters[next(letters.count)])
                }
                buffers.append(buffer)
                // Also probe buffers built from a real trigger, where matches actually happen.
                buffers.append(library[next(library.count)].triggerKeyword + (next(2) == 0 ? " " : ""))
            }
            assertAgrees(library, buffers)
        }
    }

    // MARK: - The cost that motivated the index

    /// One long trigger used to set the price of every keystroke in the library, whether or not
    /// it was anywhere near the buffer. The bound is loose on purpose: it catches a return to
    /// per-length scanning, not a particular speed.
    func testOneLongTriggerDoesNotTaxEveryKeystroke() {
        var library = (0..<500).map { snippet(";trg\($0)", requireWordBoundary: false) }
        library.append(snippet(";" + String(repeating: "z", count: 60), requireWordBoundary: false))
        let matcher = AbbreviationMatcher(snippets: library)
        // A buffer that completes nothing — the overwhelmingly common keystroke.
        let chars = Array("hello world this is what a user types while working ok now!")

        let started = Date()
        for _ in 0..<20_000 { _ = matcher.match(characters: chars) }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 0.5,
            "20k non-matching keystrokes took \(elapsed)s — per-length scanning is back"
        )
    }
}
