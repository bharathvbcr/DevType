import XCTest
@testable import ExpanderEngine

/// What the event tap asks: `isAmbiguous(trigger: fieldText, caseSensitive: snippet.isCaseSensitive)`.
/// `fieldText` is the trigger as typed, not the library spelling.
final class TriggerPrefixHoldAdversarialTests: XCTestCase {

    // MARK: - Acceptance lookup

    func testTypedSemicolonSigIsHeldAndTheLongerCaseSensitiveTriggerIsNot() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";Signature", caseSensitive: true),
            prefixTriggerSnippet(";sig", caseSensitive: false)
        ])
        XCTAssertTrue(index.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";Signature", caseSensitive: true))
        XCTAssertFalse(
            index.isAmbiguous(trigger: ";signature", caseSensitive: true),
            "A case-sensitive lookup must not fold."
        )
    }

    func testTypedBacktickSigIsHeldAndTheLongerCaseSensitiveTriggerIsNot() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet("`sig", caseSensitive: false),
            prefixTriggerSnippet("`Signature", caseSensitive: true)
        ])
        XCTAssertTrue(index.isAmbiguous(trigger: "`Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: "`Signature", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: "`signature", caseSensitive: true))
    }

    /// The library keyword may itself be upper case. The tap still passes the typed spelling.
    func testCaseInsensitiveKeywordStoredInUpperCaseStillHoldsTheTypedSpelling() {
        for punctuation in [";", "`"] {
            let index = TriggerPrefixIndex(snippets: [
                prefixTriggerSnippet("\(punctuation)SIG", caseSensitive: false),
                prefixTriggerSnippet("\(punctuation)Signature", caseSensitive: true)
            ])
            XCTAssertTrue(index.isAmbiguous(trigger: "\(punctuation)Sig", caseSensitive: false))
            XCTAssertFalse(index.isAmbiguous(trigger: "\(punctuation)Signature", caseSensitive: true))
            XCTAssertFalse(index.isAmbiguous(trigger: "\(punctuation)signature", caseSensitive: true))
        }
    }

    func testSameCasePrefixPairsStayHeldForTheTypedSpelling() {
        let insensitive = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";signature", caseSensitive: false),
            prefixTriggerSnippet(";sig", caseSensitive: false)
        ])
        XCTAssertTrue(insensitive.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(insensitive.isAmbiguous(trigger: ";signature", caseSensitive: false))
        XCTAssertFalse(insensitive.isAmbiguous(trigger: ";signature", caseSensitive: true))

        let sensitive = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";Signature", caseSensitive: true),
            prefixTriggerSnippet(";Sig", caseSensitive: true)
        ])
        XCTAssertTrue(sensitive.isAmbiguous(trigger: ";Sig", caseSensitive: true))
        XCTAssertFalse(
            sensitive.isAmbiguous(trigger: ";sig", caseSensitive: true),
            "The case-sensitive short key is stored as `;Sig`, not `;sig`."
        )
        XCTAssertFalse(sensitive.isAmbiguous(trigger: ";Signature", caseSensitive: true))
        XCTAssertFalse(sensitive.isAmbiguous(trigger: ";signature", caseSensitive: true))
    }

    // MARK: - Not an extension

    func testPunctuationWithNoLongerSiblingDoesNotHold() {
        let alone = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";sig", caseSensitive: false)
        ])
        XCTAssertFalse(alone.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(alone.isAmbiguous(trigger: ";sig", caseSensitive: true))
        XCTAssertFalse(alone.hasAnyAmbiguity)

        let unrelated = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";other", caseSensitive: true),
            prefixTriggerSnippet("`sig", caseSensitive: false),
            prefixTriggerSnippet(";si", caseSensitive: false)
        ])
        XCTAssertFalse(unrelated.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(unrelated.isAmbiguous(trigger: ";other", caseSensitive: true))
        XCTAssertFalse(unrelated.isAmbiguous(trigger: "`Sig", caseSensitive: false))
        XCTAssertFalse(unrelated.hasAnyAmbiguity)
    }

    /// `;Sig` and `;sig` are one folded key. Neither strictly extends the other.
    func testEqualFoldedPunctuationPairDoesNotHoldEitherSpelling() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";Sig", caseSensitive: true),
            prefixTriggerSnippet(";sig", caseSensitive: false)
        ])
        XCTAssertFalse(index.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";Sig", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";sig", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";SIG", caseSensitive: false))
        XCTAssertFalse(index.hasAnyAmbiguity)
    }

    func testEqualLengthDifferentCaseAmongManyIsNotAnExtension() {
        var snippets: [SnippetModel] = []
        for i in 0..<64 {
            let digits = String(format: "%04d", i)
            snippets.append(prefixTriggerSnippet(";e\(digits)", caseSensitive: false))
            snippets.append(prefixTriggerSnippet(";E\(digits)", caseSensitive: true))
        }
        let index = TriggerPrefixIndex(snippets: snippets)
        XCTAssertFalse(index.hasAnyAmbiguity)
        XCTAssertFalse(index.isAmbiguous(trigger: ";e0007", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";E0007", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";E0007", caseSensitive: false))
    }

    func testWordBoundaryAlphabeticTriggerIsNotHeldForALongerFoldedSibling() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet("Signature", caseSensitive: true, requireWordBoundary: true),
            prefixTriggerSnippet("sig", caseSensitive: false, requireWordBoundary: true),
            prefixTriggerSnippet("", caseSensitive: false),
            prefixTriggerSnippet("signatureextra", caseSensitive: false, enabled: false)
        ])
        XCTAssertFalse(index.isAmbiguous(trigger: "Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: "sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: "Signature", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: "signature", caseSensitive: true))
        XCTAssertFalse(index.hasAnyAmbiguity)
    }

    /// Dropping the boundary on the longer trigger must not start holding the shorter one.
    func testWordBoundaryShortTriggerStaysOutEvenIfTheLongerOneFiresImmediately() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet("sig", caseSensitive: false, requireWordBoundary: true),
            prefixTriggerSnippet("Signature", caseSensitive: true, requireWordBoundary: false)
        ])
        XCTAssertFalse(index.isAmbiguous(trigger: "Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: "Signature", caseSensitive: true))
        XCTAssertFalse(index.hasAnyAmbiguity)
    }

    /// The short trigger is the one that fires on the keystroke. The longer one's boundary
    /// does not remove it from the scan.
    func testImmediateAlphabeticShortTriggerIsHeldWhenABoundaryLongerSiblingExists() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet("Signature", caseSensitive: true, requireWordBoundary: true),
            prefixTriggerSnippet("sig", caseSensitive: false, requireWordBoundary: false)
        ])
        XCTAssertTrue(index.isAmbiguous(trigger: "Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: "Signature", caseSensitive: true))
        XCTAssertFalse(
            index.isAmbiguous(trigger: "SIG", caseSensitive: true),
            "A case-sensitive lookup must not fold SIG into the stored sig key."
        )
    }

    // MARK: - Disabled, empty, and holes in the list

    func testDisabledAndEmptyTriggersDoNotCreateAmbiguity() {
        let disabledLonger = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";sig", caseSensitive: false),
            prefixTriggerSnippet(";Signature", caseSensitive: true, enabled: false),
            prefixTriggerSnippet("", caseSensitive: true),
            prefixTriggerSnippet("", caseSensitive: false)
        ])
        XCTAssertFalse(disabledLonger.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(disabledLonger.isAmbiguous(trigger: ";Signature", caseSensitive: true))
        XCTAssertFalse(disabledLonger.hasAnyAmbiguity)

        let disabledShort = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";sig", caseSensitive: false, enabled: false),
            prefixTriggerSnippet("", caseSensitive: false),
            prefixTriggerSnippet(";Signature", caseSensitive: true)
        ])
        XCTAssertFalse(disabledShort.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(disabledShort.isAmbiguous(trigger: ";Signature", caseSensitive: true))
        XCTAssertFalse(disabledShort.hasAnyAmbiguity)

        let onlyEmpty = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(""),
            prefixTriggerSnippet("", caseSensitive: true, enabled: false)
        ])
        XCTAssertFalse(onlyEmpty.hasAnyAmbiguity)
        XCTAssertFalse(onlyEmpty.isAmbiguous(trigger: "", caseSensitive: false))
        XCTAssertFalse(onlyEmpty.isAmbiguous(trigger: ";", caseSensitive: false))
    }

    /// A disabled row between the pair must not shift which key is marked.
    func testDisabledHoleDoesNotMoveTheAmbiguousKey() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";aaa", caseSensitive: true, enabled: false),
            prefixTriggerSnippet("", caseSensitive: false),
            prefixTriggerSnippet(";Signature", caseSensitive: true),
            prefixTriggerSnippet(";sigextra", caseSensitive: false, enabled: false),
            prefixTriggerSnippet(";sig", caseSensitive: false),
            prefixTriggerSnippet(";other", caseSensitive: true)
        ])
        XCTAssertTrue(index.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";Signature", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";other", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";sigextra", caseSensitive: false))
    }

    // MARK: - String.lowercased(), not a new fold

    func testStandardLibraryCasefoldForTurkishLetters() {
        XCTAssertNotEqual("İ".lowercased(), "i")
        XCTAssertEqual("İ".lowercased(), "i\u{0307}")
        XCTAssertEqual("İ".lowercased().count, 1)
        XCTAssertEqual("I".lowercased(), "i")
        XCTAssertEqual("ı".lowercased(), "ı")
        XCTAssertNotEqual("ı".lowercased(), "i")
        XCTAssertFalse(";İstanbul".lowercased().hasPrefix(";i"))
        XCTAssertTrue(";İstanbul".lowercased().hasPrefix(";İ".lowercased()))
        XCTAssertTrue(";ışık".lowercased().hasPrefix(";ı".lowercased()))
        XCTAssertFalse(";Işık".lowercased().hasPrefix(";ı".lowercased()))
    }

    func testDottedCapitalIIsNotTreatedAsPlainI() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";İstanbul", caseSensitive: true),
            prefixTriggerSnippet(";i", caseSensitive: false)
        ])
        XCTAssertFalse(index.isAmbiguous(trigger: ";i", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";İ", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";I", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";İstanbul", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";istanbul", caseSensitive: true))
        XCTAssertFalse(index.hasAnyAmbiguity)
    }

    func testFoldOfDottedCapitalIDoesExtendFoldOfIstanbul() {
        let index = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";İstanbul", caseSensitive: true),
            prefixTriggerSnippet(";İ", caseSensitive: false)
        ])
        XCTAssertTrue(index.isAmbiguous(trigger: ";İ", caseSensitive: false))
        XCTAssertTrue(index.isAmbiguous(trigger: ";i\u{0307}", caseSensitive: false))
        XCTAssertFalse(
            index.isAmbiguous(trigger: ";i", caseSensitive: false),
            "Plain i is not the fold of İ, so it is not the stored key."
        )
        XCTAssertFalse(index.isAmbiguous(trigger: ";İstanbul", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";istanbul", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";i\u{0307}stanbul", caseSensitive: true))
    }

    func testAsciiIFoldsToIAndDotlessIDoesNot() {
        let ascii = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";I", caseSensitive: true),
            prefixTriggerSnippet(";istanbul", caseSensitive: false)
        ])
        XCTAssertTrue(ascii.isAmbiguous(trigger: ";I", caseSensitive: true))
        XCTAssertFalse(ascii.isAmbiguous(trigger: ";i", caseSensitive: true))
        XCTAssertFalse(ascii.isAmbiguous(trigger: ";istanbul", caseSensitive: false))

        let dotlessAgainstI = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";ı", caseSensitive: false, requireWordBoundary: false),
            prefixTriggerSnippet(";istanbul", caseSensitive: true, requireWordBoundary: false)
        ])
        XCTAssertFalse(dotlessAgainstI.isAmbiguous(trigger: ";ı", caseSensitive: false))
        XCTAssertFalse(dotlessAgainstI.isAmbiguous(trigger: ";i", caseSensitive: false))
        XCTAssertFalse(dotlessAgainstI.hasAnyAmbiguity)

        let dotlessPair = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";ışık", caseSensitive: true, requireWordBoundary: false),
            prefixTriggerSnippet(";ı", caseSensitive: false, requireWordBoundary: false)
        ])
        XCTAssertTrue(dotlessPair.isAmbiguous(trigger: ";ı", caseSensitive: false))
        XCTAssertFalse(dotlessPair.isAmbiguous(trigger: ";i", caseSensitive: false))
        XCTAssertFalse(dotlessPair.isAmbiguous(trigger: ";ışık", caseSensitive: true))

        let dottedWord = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet(";ı", caseSensitive: false, requireWordBoundary: false),
            prefixTriggerSnippet(";Işık", caseSensitive: true, requireWordBoundary: false)
        ])
        XCTAssertFalse(
            dottedWord.isAmbiguous(trigger: ";ı", caseSensitive: false),
            "Işık.lowercased() is işık, which does not start with ı."
        )
        XCTAssertFalse(dottedWord.hasAnyAmbiguity)

        let boundaryBlocksDotless = TriggerPrefixIndex(snippets: [
            prefixTriggerSnippet("ı", caseSensitive: false, requireWordBoundary: true),
            prefixTriggerSnippet("ışık", caseSensitive: true, requireWordBoundary: true)
        ])
        XCTAssertFalse(boundaryBlocksDotless.isAmbiguous(trigger: "ı", caseSensitive: false))
        XCTAssertFalse(boundaryBlocksDotless.isAmbiguous(trigger: "ışık", caseSensitive: true))
        XCTAssertFalse(boundaryBlocksDotless.hasAnyAmbiguity)
    }

    // MARK: - A few thousand keys

    /// Fixed-width ids so `;k0001` is not a prefix of `;k0002`. One buried strict extension,
    /// one disabled extension, and the mixed-case semicolon pair.
    func testThousandsOfTriggersHoldOnlyAStrictlyLongerFoldedKey() {
        let count = 3_000
        var snippets: [SnippetModel] = []
        snippets.reserveCapacity(count * 2 + 8)
        for i in 0..<count {
            let digits = String(format: "%04d", i)
            snippets.append(prefixTriggerSnippet(";k\(digits)", caseSensitive: false))
            snippets.append(prefixTriggerSnippet(";K\(digits)", caseSensitive: true))
        }
        snippets.insert(prefixTriggerSnippet(";Signature", caseSensitive: true), at: 0)
        snippets.insert(prefixTriggerSnippet("", caseSensitive: false), at: 1)
        snippets.insert(
            prefixTriggerSnippet(";k0001extra", caseSensitive: true, enabled: false),
            at: 2
        )
        snippets.append(prefixTriggerSnippet(";k0042more", caseSensitive: true))
        snippets.append(prefixTriggerSnippet(";sig", caseSensitive: false))
        snippets.append(prefixTriggerSnippet("sig", caseSensitive: false, requireWordBoundary: true))
        snippets.append(prefixTriggerSnippet("Signature", caseSensitive: true, requireWordBoundary: true))

        let started = Date()
        let index = TriggerPrefixIndex(snippets: snippets)
        let elapsed = Date().timeIntervalSince(started)
        print("TriggerPrefixIndex init \(snippets.count) snippets in \(elapsed)s")
        XCTAssertLessThan(elapsed, 1.0, "Index init took \(elapsed)s for \(snippets.count) snippets.")

        XCTAssertTrue(index.isAmbiguous(trigger: ";Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";Signature", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";signature", caseSensitive: true))

        XCTAssertFalse(index.isAmbiguous(trigger: ";k0002", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";K0002", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";K0002", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";k0001", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: ";K0001", caseSensitive: true))

        XCTAssertTrue(index.isAmbiguous(trigger: ";k0042", caseSensitive: false))
        XCTAssertTrue(index.isAmbiguous(trigger: ";K0042", caseSensitive: true))
        XCTAssertTrue(
            index.isAmbiguous(trigger: ";k0042", caseSensitive: true),
            "The case-insensitive snippet stores `;k0042` itself, so the verbatim key is present."
        )
        XCTAssertFalse(index.isAmbiguous(trigger: ";k0042more", caseSensitive: true))
        XCTAssertFalse(index.isAmbiguous(trigger: ";k0042more", caseSensitive: false))

        XCTAssertFalse(index.isAmbiguous(trigger: "Sig", caseSensitive: false))
        XCTAssertFalse(index.isAmbiguous(trigger: "Signature", caseSensitive: true))
    }
}
