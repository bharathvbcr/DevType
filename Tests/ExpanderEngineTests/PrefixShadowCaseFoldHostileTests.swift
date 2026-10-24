import XCTest
@testable import ExpanderEngine

/// Hostile cases around the two prefix scans. Case-insensitive shadowers consult every
/// lowercased trigger; case-sensitive shadowers keep verbatim extensions and only take a
/// folded extension when the other snippet is case-insensitive.
final class PrefixShadowCaseFoldHostileTests: XCTestCase {

    private func conflicts(_ snippets: [SnippetModel]) -> [SnippetStore.TriggerConflict] {
        conflicts(in: [SnippetGroup(name: "G", snippets: snippets)])
    }

    private func conflicts(in groups: [SnippetGroup]) -> [SnippetStore.TriggerConflict] {
        SnippetStore.triggerConflicts(in: groups).filter { $0.kind == .prefixShadow }
    }

    func testCaseInsensitiveShortShadowsSensitiveAndInsensitiveInOneReport() {
        let short = prefixTriggerSnippet("`sig", caseSensitive: false)
        let sensitive = prefixTriggerSnippet("`Signature", caseSensitive: true)
        let insensitive = prefixTriggerSnippet("`signoff", caseSensitive: false)
        let found = conflicts([short, sensitive, insensitive])

        let report = found.first { $0.trigger == "`sig" }
        XCTAssertEqual(report?.blockedTriggers, ["`Signature", "`signoff"])
        XCTAssertEqual(report?.snippetIDs, [short.id, sensitive.id, insensitive.id])
        XCTAssertEqual(Set(report?.snippetIDs ?? []).count, report?.snippetIDs.count)
        XCTAssertFalse(
            found.contains { $0.blockedTriggers.contains("`sig") },
            "The longer trigger must not be reported as shadowing the shorter one."
        )
    }

    func testCaseSensitiveShortShadowsFoldedInsensitiveAndSameCaseOnly() {
        let short = prefixTriggerSnippet("`Sig", caseSensitive: true)
        let insensitive = prefixTriggerSnippet("`signature", caseSensitive: false)
        let differentCase = prefixTriggerSnippet("`signal", caseSensitive: true)
        let sameCase = prefixTriggerSnippet("`Signal", caseSensitive: true)
        let found = conflicts([short, insensitive, differentCase, sameCase])

        let report = found.first { $0.trigger == "`Sig" }
        XCTAssertEqual(report?.blockedTriggers, ["`Signal", "`signature"])
        XCTAssertEqual(report?.snippetIDs, [short.id, sameCase.id, insensitive.id])
        XCTAssertFalse(found.contains { $0.blockedTriggers.contains("`signal") })
        XCTAssertFalse(found.contains { $0.trigger == "`signature" || $0.trigger == "`Signal" && $0.blockedTriggers.contains("`Sig") })
    }

    func testWordBoundaryBlocksCaseSensitiveLetterButNotPunctuation() {
        XCTAssertTrue(
            conflicts([
                prefixTriggerSnippet("Sig", caseSensitive: true, requireWordBoundary: true),
                prefixTriggerSnippet("signature", caseSensitive: false)
            ]).isEmpty,
            "A case-sensitive letter trigger that waits for a terminator cannot shadow."
        )
        let found = conflicts([
            prefixTriggerSnippet("`Sig", caseSensitive: true, requireWordBoundary: true),
            prefixTriggerSnippet("`signature", caseSensitive: false)
        ])
        XCTAssertEqual(found.map(\.trigger), ["`Sig"])
        XCTAssertEqual(found.first?.blockedTriggers, ["`signature"])
    }

    func testEqualLengthOppositeCaseIsNotPrefixShadow() {
        XCTAssertTrue(conflicts([
            prefixTriggerSnippet("`sig", caseSensitive: false),
            prefixTriggerSnippet("`Sig", caseSensitive: true)
        ]).isEmpty)
        XCTAssertTrue(conflicts([
            prefixTriggerSnippet("`Sig", caseSensitive: true),
            prefixTriggerSnippet("`sig", caseSensitive: false)
        ]).isEmpty)
    }

    func testDisabledGroupAndDisabledSnippetStayOutAcrossCase() {
        let liveShort = SnippetGroup(
            name: "On",
            snippets: [prefixTriggerSnippet("`sig", caseSensitive: false)]
        )
        let deadLong = SnippetGroup(
            name: "Off",
            enabled: false,
            snippets: [prefixTriggerSnippet("`Signature", caseSensitive: true)]
        )
        XCTAssertTrue(conflicts(in: [liveShort, deadLong]).isEmpty)

        let deadShort = SnippetGroup(
            name: "Off",
            enabled: false,
            snippets: [prefixTriggerSnippet("`Sig", caseSensitive: true)]
        )
        let liveLong = SnippetGroup(
            name: "On",
            snippets: [prefixTriggerSnippet("`signature", caseSensitive: false)]
        )
        XCTAssertTrue(conflicts(in: [deadShort, liveLong]).isEmpty)

        XCTAssertTrue(conflicts([
            prefixTriggerSnippet("`sig", caseSensitive: false, enabled: false),
            prefixTriggerSnippet("`Signature", caseSensitive: true)
        ]).isEmpty)
        XCTAssertTrue(conflicts([
            prefixTriggerSnippet("`sig", caseSensitive: false),
            prefixTriggerSnippet("`Signature", caseSensitive: true, enabled: false)
        ]).isEmpty)
    }

    func testSecretAndEmptyTriggerAreAbsentAcrossCase() {
        var secretShort = prefixTriggerSnippet("`sig", caseSensitive: false)
        secretShort.isSecret = true
        var secretLong = prefixTriggerSnippet("`Signature", caseSensitive: true)
        secretLong.isSecret = true
        XCTAssertTrue(conflicts([
            secretShort,
            prefixTriggerSnippet("`Signature", caseSensitive: true)
        ]).isEmpty)
        XCTAssertTrue(conflicts([
            prefixTriggerSnippet("`sig", caseSensitive: false),
            secretLong
        ]).isEmpty)

        let found = conflicts([
            prefixTriggerSnippet(""),
            prefixTriggerSnippet("`sig", caseSensitive: false),
            prefixTriggerSnippet("`Signature", caseSensitive: true)
        ])
        XCTAssertEqual(found.map(\.trigger), ["`sig"])
        XCTAssertEqual(found.first?.blockedTriggers, ["`Signature"])
        XCTAssertFalse(found.contains { $0.trigger.isEmpty || $0.blockedTriggers.contains("") })
    }

    func testDottedAndDotlessIDoNotShadowIsignature() {
        // Shorter trigger only. İ (U+0130) lowercases to "i" + combining dot, and ı (U+0131)
        // stays ı. Neither is a String.hasPrefix of "isignature". No extra fold.
        let dotted = "\u{0130}"
        let dotless = "\u{0131}"
        let dottedReport = conflicts([
            prefixTriggerSnippet(dotted, caseSensitive: false, requireWordBoundary: false),
            prefixTriggerSnippet("isignature", caseSensitive: true)
        ])
        XCTAssertFalse(dottedReport.contains { $0.trigger == dotted })
        let dotlessReport = conflicts([
            prefixTriggerSnippet(dotless, caseSensitive: false, requireWordBoundary: false),
            prefixTriggerSnippet("isignature", caseSensitive: false)
        ])
        XCTAssertFalse(dotlessReport.contains { $0.trigger == dotless })
    }

    func testDecomposedPrefixMatchesPrecomposedLongerTrigger() {
        // lowercased() + hasPrefix: "e" + U+0301 is a prefix of precomposed U+00E9 + "signature".
        // The reverse comparison also matches. This pins that fact; it is not a normalization fold.
        let decomposed = "e\u{0301}"
        let precomposed = "\u{00E9}signature"
        let found = conflicts([
            prefixTriggerSnippet(decomposed, caseSensitive: false, requireWordBoundary: false),
            prefixTriggerSnippet(precomposed, caseSensitive: false)
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.trigger, decomposed)
        XCTAssertEqual(found.first?.blockedTriggers, [precomposed])
    }

    func testThreeHundredMixedCasePairsStayOneShadowEach() {
        var snippets: [SnippetModel] = []
        snippets.reserveCapacity(600)
        for index in 0..<300 {
            let stamp = String(format: "%03d", index)
            snippets.append(prefixTriggerSnippet("`s\(stamp)sig", caseSensitive: false))
            if index.isMultiple(of: 2) {
                snippets.append(prefixTriggerSnippet("`s\(stamp)Signature", caseSensitive: true))
            } else {
                snippets.append(prefixTriggerSnippet("`S\(stamp)signoff", caseSensitive: false))
            }
        }

        let clock = ContinuousClock()
        let started = clock.now
        let found = conflicts(snippets)
        let elapsed = clock.now - started

        XCTAssertEqual(found.count, 300)
        XCTAssertTrue(found.allSatisfy { $0.blockedTriggers.count == 1 })
        XCTAssertEqual(Set(found.map(\.trigger)).count, 300)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testDuplicateSnippetIDIsNotListedTwice() {
        let shared = UUID()
        let short = SnippetModel(
            id: shared,
            title: "`sig",
            triggerKeyword: "`sig",
            replacementText: "x",
            isCaseSensitive: true
        )
        let sameIdentity = SnippetModel(
            id: shared,
            title: "`signature",
            triggerKeyword: "`signature",
            replacementText: "x",
            isCaseSensitive: false
        )
        let other = prefixTriggerSnippet("`signoff", caseSensitive: false)
        let found = conflicts([short, sameIdentity, other])

        let report = found.first { $0.trigger == "`sig" }
        XCTAssertEqual(report?.blockedTriggers, ["`signoff"])
        XCTAssertEqual(report?.snippetIDs, [shared, other.id])
        XCTAssertEqual(report?.snippetIDs.filter { $0 == shared }.count, 1)
        XCTAssertEqual(Set(report?.snippetIDs ?? []).count, report?.snippetIDs.count)
    }
}
