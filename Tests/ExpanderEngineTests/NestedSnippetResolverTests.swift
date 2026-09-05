import XCTest
@testable import ExpanderEngine

/// Five call sites had hand-written the same `{{snippet:…}}` lookup as a linear scan with a
/// `lowercased()` allocation per candidate — one of them inside the CGEventTap callback, where
/// the cost scaled with the whole library on the keystroke that expands a snippet.
///
/// The precedence rule they implemented is subtle: the **first snippet in library order** that
/// matches either exactly or case-folded. That is deliberately not "exact table first, then the
/// folded one", and these tests hold the replacement to the original scan's answers — including
/// the orderings where the two differ.
final class NestedSnippetResolverTests: XCTestCase {

    private func snippet(
        _ trigger: String,
        _ body: String,
        caseSensitive: Bool = false,
        isSecret: Bool = false
    ) -> SnippetModel {
        var model = SnippetModel(
            title: trigger,
            triggerKeyword: trigger,
            replacementText: isSecret ? "" : body,
            isCaseSensitive: caseSensitive,
            requireWordBoundary: true
        )
        model.isSecret = isSecret
        return model
    }

    /// The scan every call site used to run, verbatim.
    private func referenceLookup(
        _ snippets: [SnippetModel],
        excludingSecrets: Bool
    ) -> (String) -> String? {
        { trigger in
            snippets.first {
                (!excludingSecrets || !$0.isSecret)
                    && ($0.triggerKeyword == trigger
                        || (!$0.isCaseSensitive
                            && $0.triggerKeyword.lowercased() == trigger.lowercased()))
            }?.replacementText
        }
    }

    private func assertAgrees(
        _ snippets: [SnippetModel],
        _ queries: [String],
        excludingSecrets: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reference = referenceLookup(snippets, excludingSecrets: excludingSecrets)
        let resolver = NestedSnippetResolver(snippets: snippets, excludingSecrets: excludingSecrets)
        for query in queries {
            XCTAssertEqual(
                resolver.replacement(for: query), reference(query),
                "lookup(\"\(query)\")", file: file, line: line
            )
        }
    }

    // MARK: - Ordinary resolution

    func testResolvesExactAndFoldedTriggers() {
        assertAgrees(
            [snippet(";sig", "Signature"), snippet(";eml", "user@example.com")],
            [";sig", ";SIG", ";Sig", ";eml", ";missing", ""]
        )
    }

    func testCaseSensitiveTriggerDoesNotAnswerFoldedQueries() {
        assertAgrees(
            [snippet(";Sig", "Exact only", caseSensitive: true)],
            [";Sig", ";sig", ";SIG"]
        )
    }

    // MARK: - The orderings where naive table precedence goes wrong

    /// A case-sensitive snippet appearing *first* occupies the folded key in a naive two-table
    /// scheme, and would wrongly answer a query that differs from it only in case.
    func testEarlierCaseSensitiveTriggerDoesNotShadowLaterFoldedMatch() {
        assertAgrees(
            [snippet(";ab", "case sensitive", caseSensitive: true),
             snippet(";AB", "case insensitive", caseSensitive: false)],
            [";ab", ";AB", ";Ab", ";aB"]
        )
        let resolver = NestedSnippetResolver(snippets: [
            snippet(";ab", "case sensitive", caseSensitive: true),
            snippet(";AB", "case insensitive", caseSensitive: false)
        ])
        XCTAssertEqual(resolver.replacement(for: ";ab"), "case sensitive", "exact match wins")
        XCTAssertEqual(resolver.replacement(for: ";Ab"), "case insensitive", "only the folded one can match")
    }

    /// The mirror: a case-insensitive snippet appearing first must win a query that a later
    /// case-sensitive snippet matches exactly.
    func testEarlierFoldedMatchBeatsLaterExactMatch() {
        assertAgrees(
            [snippet(";Y", "folded first", caseSensitive: false),
             snippet(";y", "exact later", caseSensitive: true)],
            [";y", ";Y"]
        )
        let resolver = NestedSnippetResolver(snippets: [
            snippet(";Y", "folded first", caseSensitive: false),
            snippet(";y", "exact later", caseSensitive: true)
        ])
        XCTAssertEqual(
            resolver.replacement(for: ";y"), "folded first",
            "library order decides, not which table the key lives in"
        )
    }

    func testDuplicateTriggersKeepTheFirst() {
        assertAgrees(
            [snippet(";dup", "first"), snippet(";dup", "second")],
            [";dup", ";DUP"]
        )
    }

    // MARK: - Secrets

    /// Resolving a secret inside another snippet would paste a password into whatever document
    /// the outer snippet lands in, with no explicit gesture naming it.
    func testSecretsAreExcludedWhenAsked() {
        let library = [snippet(";pw", "", isSecret: true), snippet(";pw", "public fallback")]
        assertAgrees(library, [";pw"], excludingSecrets: true)
        let resolver = NestedSnippetResolver(snippets: library, excludingSecrets: true)
        XCTAssertEqual(resolver.replacement(for: ";pw"), "public fallback")
    }

    func testSecretsAreIncludedWhenNotExcluded() {
        let library = [snippet(";pw", "", isSecret: true), snippet(";pw", "public fallback")]
        assertAgrees(library, [";pw"], excludingSecrets: false)
    }

    func testEmptyLibraryResolvesNothing() {
        let resolver = NestedSnippetResolver(snippets: [])
        XCTAssertNil(resolver.replacement(for: ";anything"))
    }

    // MARK: - Differential fuzz

    func testAgreesWithTheLinearScanUnderFuzz() {
        var seed: UInt64 = 0xC0FF_EE00_1234_5678
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let spellings = [";ab", ";AB", ";Ab", ";aB", ";x", ";X", "y", "Y"]

        for _ in 0..<300 {
            var library: [SnippetModel] = []
            for index in 0..<(1 + next(6)) {
                library.append(snippet(
                    spellings[next(spellings.count)],
                    "body\(index)",
                    caseSensitive: next(2) == 0,
                    isSecret: next(5) == 0
                ))
            }
            assertAgrees(library, spellings, excludingSecrets: next(2) == 0)
        }
    }

    // MARK: - The cost that motivated it

    /// The scan was linear in the library per nested reference. Resolution is now a dictionary
    /// read, so a snippet chaining many references no longer multiplies by the library size.
    func testManyLookupsOverALargeLibraryStayFast() {
        let library = (0..<2_000).map { snippet(";trg\($0)", "body\($0)") }
        let resolver = NestedSnippetResolver(snippets: library)
        let started = Date()
        for index in 0..<20_000 {
            _ = resolver.replacement(for: ";trg\(index % 2_000)")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 1.0,
            "20k nested lookups over 2,000 snippets took \(elapsed)s — the linear scan is back"
        )
    }
}
