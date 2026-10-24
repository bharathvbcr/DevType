import XCTest
@testable import ExpanderEngine

/// Prefix shadowing must see a longer trigger that differs only in case, without treating two
/// case-sensitive triggers that differ only in case as a prefix of each other.
///
/// `TriggerPrefixScan` compares with `String.hasPrefix`, which is case-sensitive. Folding only
/// the case-insensitive side therefore misses `;sig` against `;Signature` and `;Sig` against
/// `;signature`. Folding every key into one scan would invent a shadow between case-sensitive
/// `` `SLM `` and `` `slmabout ``.
final class PrefixShadowCaseFoldTests: XCTestCase {

    private func conflicts(_ snippets: [SnippetModel]) -> [SnippetStore.TriggerConflict] {
        SnippetStore.triggerConflicts(in: [SnippetGroup(name: "G", snippets: snippets)])
            .filter { $0.kind == .prefixShadow }
    }

    func testCaseInsensitiveImmediateShadowsCaseSensitiveLongerTrigger() {
        let found = conflicts([
            prefixTriggerSnippet("`sig", caseSensitive: false),
            prefixTriggerSnippet("`Signature", caseSensitive: true)
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.trigger, "`sig")
        XCTAssertEqual(found.first?.blockedTriggers, ["`Signature"])
    }

    func testCaseSensitiveImmediateShadowsCaseInsensitiveLongerTrigger() {
        let found = conflicts([
            prefixTriggerSnippet("`Sig", caseSensitive: true),
            prefixTriggerSnippet("`signature", caseSensitive: false)
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.trigger, "`Sig")
        XCTAssertEqual(found.first?.blockedTriggers, ["`signature"])
    }

    func testBothCaseSensitiveDifferentCasingIsNotPrefixShadow() {
        let found = conflicts([
            prefixTriggerSnippet("`SLM", caseSensitive: true),
            prefixTriggerSnippet("`slmabout", caseSensitive: true)
        ])
        XCTAssertTrue(found.isEmpty)
    }

    func testBothCaseInsensitiveStillReportPrefixShadow() {
        let found = conflicts([
            prefixTriggerSnippet("`SLM", caseSensitive: false),
            prefixTriggerSnippet("`slmabout", caseSensitive: false)
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.blockedTriggers, ["`slmabout"])
    }

    func testEqualLengthOppositeCaseIsNotPrefixShadow() {
        let found = conflicts([
            prefixTriggerSnippet("`sig", caseSensitive: false),
            prefixTriggerSnippet("`Sig", caseSensitive: true)
        ])
        XCTAssertTrue(
            found.isEmpty,
            "Equal folded keys are a case shadow, not a prefix shadow."
        )
    }

    func testDisabledSnippetNeitherShadowsNorIsShadowedAcrossCase() {
        XCTAssertTrue(
            conflicts([
                prefixTriggerSnippet("`sig", caseSensitive: false, enabled: false),
                prefixTriggerSnippet("`Signature", caseSensitive: true)
            ]).isEmpty
        )
        XCTAssertTrue(
            conflicts([
                prefixTriggerSnippet("`sig", caseSensitive: false),
                prefixTriggerSnippet("`Signature", caseSensitive: true, enabled: false)
            ]).isEmpty
        )
        XCTAssertTrue(
            conflicts([
                prefixTriggerSnippet("`Sig", caseSensitive: true, enabled: false),
                prefixTriggerSnippet("`signature", caseSensitive: false)
            ]).isEmpty
        )
        XCTAssertTrue(
            conflicts([
                prefixTriggerSnippet("`Sig", caseSensitive: true),
                prefixTriggerSnippet("`signature", caseSensitive: false, enabled: false)
            ]).isEmpty
        )
    }

    func testSecretAndEmptyTriggerAreAbsentFromPrefixShadow() {
        var secretShort = prefixTriggerSnippet("`sig", caseSensitive: false)
        secretShort.isSecret = true
        var secretLong = prefixTriggerSnippet("`Signature", caseSensitive: true)
        secretLong.isSecret = true

        let secretShadows = conflicts([
            secretShort,
            prefixTriggerSnippet("`Signature", caseSensitive: true)
        ])
        XCTAssertTrue(secretShadows.isEmpty, "A secret never reaches the matcher, so it cannot shadow.")

        let secretShadowed = conflicts([
            prefixTriggerSnippet("`sig", caseSensitive: false),
            secretLong
        ])
        XCTAssertTrue(secretShadowed.isEmpty, "A secret is not a reachable longer trigger.")

        let withEmpty = conflicts([
            prefixTriggerSnippet(""),
            prefixTriggerSnippet("`sig", caseSensitive: false),
            prefixTriggerSnippet("`Signature", caseSensitive: true)
        ])
        XCTAssertFalse(withEmpty.contains { $0.trigger.isEmpty || $0.blockedTriggers.contains("") })
        XCTAssertEqual(withEmpty.first?.blockedTriggers, ["`Signature"])
    }

    func testDottedCapitalIDoesNotFoldToAsciiI() {
        // U+0130 lowercases to "i" + combining dot, not ASCII "i". Stripping marks would
        // invent a prefix of "isignature". The shadower must be immediate or the gate hides
        // a bad fold.
        let dotted = conflicts([
            prefixTriggerSnippet("İ", caseSensitive: false, requireWordBoundary: false),
            prefixTriggerSnippet("isignature", caseSensitive: false)
        ])
        XCTAssertTrue(dotted.isEmpty, "İ is not a prefix of isignature under String.lowercased().")

        let plain = conflicts([
            prefixTriggerSnippet("i", caseSensitive: false, requireWordBoundary: false),
            prefixTriggerSnippet("isignature", caseSensitive: false)
        ])
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain.first?.trigger, "i")
        XCTAssertEqual(plain.first?.blockedTriggers, ["isignature"])
    }
}
