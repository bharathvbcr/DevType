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
        isSecret: Bool = false,
        enabled: Bool = true,
        includeApps: [String] = [],
        excludeApps: [String] = []
    ) -> SnippetModel {
        var model = SnippetModel(
            title: trigger,
            triggerKeyword: trigger,
            replacementText: isSecret ? "" : body,
            isCaseSensitive: caseSensitive,
            requireWordBoundary: true,
            enabled: enabled,
            includeApps: includeApps,
            excludeApps: excludeApps
        )
        model.isSecret = isSecret
        return model
    }

    /// The scan every call site used to run, verbatim — with the secret exclusion the resolver
    /// now applies unconditionally.
    private func referenceLookup(_ snippets: [SnippetModel]) -> (String) -> String? {
        { trigger in
            snippets.first {
                !$0.isSecret
                    && ($0.triggerKeyword == trigger
                        || (!$0.isCaseSensitive
                            && $0.triggerKeyword.lowercased() == trigger.lowercased()))
            }?.replacementText
        }
    }

    private func assertAgrees(
        _ snippets: [SnippetModel],
        _ queries: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reference = referenceLookup(snippets)
        let resolver = NestedSnippetResolver(snippets: snippets)
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
    /// The plain initialiser — the one a new call site writes without thinking — must already
    /// exclude secrets. Against the pre-fix code this failed: `excludingSecrets` defaulted to
    /// `false`, the secret claimed the `;pw` slot first, and the nested reference resolved to the
    /// secret's empty body instead of the ordinary snippet behind it.
    func testTheDefaultInitialiserExcludesSecretsWithNoFlagToForget() {
        let library = [snippet(";pw", "", isSecret: true), snippet(";pw", "public fallback")]
        assertAgrees(library, [";pw"])
        XCTAssertEqual(NestedSnippetResolver(snippets: library).replacement(for: ";pw"),
                       "public fallback")
    }

    /// A secret carries no trigger of its own, so it must not answer the empty key either.
    func testATriggerlessSecretCannotAnswerTheEmptyReference() {
        let library = [snippet("", "", isSecret: true)]
        XCTAssertNil(NestedSnippetResolver(snippets: library).replacement(for: ""))
    }

    /// Even a secret that somehow still carries a trigger and a body is unreachable by nesting.
    func testASecretRetainingATriggerAndBodyIsStillUnreachable() {
        var leaky = snippet(";pw", "hunter2")
        leaky.isSecret = true
        XCTAssertNil(NestedSnippetResolver(snippets: [leaky]).replacement(for: ";pw"))
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
            assertAgrees(library, spellings)
        }
    }

    // MARK: - Disabled snippets must not keep the slot

    func testDisabledSnippetDoesNotAnswerAndLaterEnabledDoes() {
        let library = [
            snippet(";t", "off", enabled: false),
            snippet(";t", "on")
        ]
        let resolver = NestedSnippetResolver(snippets: library)
        XCTAssertNil(
            NestedSnippetResolver(snippets: [snippet(";t", "off", enabled: false)])
                .replacement(for: ";t")
        )
        XCTAssertEqual(resolver.replacement(for: ";t"), "on")
        XCTAssertEqual(resolver.replacement(for: ";T"), "on")
        XCTAssertEqual(resolver.lookup(";t"), "on")
    }

    /// A disabled case-insensitive snippet is not in the folded table, so it cannot beat a
    /// later case-sensitive exact match — and a folded query it would have claimed is unanswered.
    func testDisabledFoldedSnippetDoesNotShadowLaterExactMatch() {
        let resolver = NestedSnippetResolver(snippets: [
            snippet(";Ab", "off", enabled: false),
            snippet(";ab", "exact", caseSensitive: true)
        ])
        XCTAssertEqual(resolver.replacement(for: ";ab"), "exact")
        XCTAssertNil(resolver.replacement(for: ";AB"))
    }

    // MARK: - App scope is decided at lookup

    func testExcludedOrIncludeRestrictedSnippetDoesNotShadowALaterEligibleOne() {
        let safari = "com.apple.Safari"
        let chrome = "com.google.Chrome"
        let mail = "com.apple.mail"
        let library = [
            snippet(";go", "safari only", includeApps: ["COM.APPLE.SAFARI"]),
            snippet(";go", "not in mail", excludeApps: [mail]),
            snippet(";go", "everywhere")
        ]

        func resolve(_ bundle: String?) -> String? {
            NestedSnippetResolver(snippets: library, frontmostBundleID: { bundle })
                .replacement(for: ";go")
        }

        XCTAssertEqual(resolve(safari), "safari only", "include list matches case-insensitively")
        XCTAssertEqual(resolve("com.apple.safari"), "safari only")
        XCTAssertEqual(resolve(chrome), "not in mail", "the include-restricted snippet must not keep the slot")
        XCTAssertEqual(resolve(mail), "everywhere", "exclusion wins, then the next eligible snippet")
        XCTAssertEqual(
            resolve(nil), "not in mail",
            "unknown app: include-restricted does not answer; exclude-only still does"
        )
        XCTAssertEqual(
            NestedSnippetResolver(snippets: library, frontmostBundleID: { "" }).replacement(for: ";go"),
            "not in mail",
            "an empty bundle is an unknown app, same as nil"
        )
    }

    func testSameTriggerAnswersInTheAppWhereTheEarlierSnippetApplies() {
        let library = [
            snippet(";app", "in safari", includeApps: ["com.apple.Safari"]),
            snippet(";app", "in mail", includeApps: ["com.apple.mail"])
        ]
        let safari = NestedSnippetResolver(snippets: library) { "com.apple.Safari" }
        let mail = NestedSnippetResolver(snippets: library, frontmostBundleID: { "com.apple.mail" })
        let chrome = NestedSnippetResolver(snippets: library, frontmostBundleID: { "com.google.Chrome" })
        XCTAssertEqual(safari.replacement(for: ";app"), "in safari")
        XCTAssertEqual(mail.lookup(";app"), "in mail")
        XCTAssertNil(chrome.replacement(for: ";app"))
        XCTAssertNil(
            NestedSnippetResolver(snippets: library).replacement(for: ";app"),
            "nil bundle does not satisfy an include list"
        )
    }

    /// Library order still decides once ineligible snippets are skipped. An excluded earlier
    /// folded match must not beat a later exact one, and must beat it again where it applies.
    func testIneligibleEarlierFoldedMatchDoesNotKeepTheSlot() {
        let library = [
            snippet(";Y", "folded first", excludeApps: ["com.apple.Safari"]),
            snippet(";y", "exact later", caseSensitive: true)
        ]
        let safari = NestedSnippetResolver(
            snippets: library,
            frontmostBundleID: { "com.apple.Safari" }
        )
        let textEdit = NestedSnippetResolver(
            snippets: library,
            frontmostBundleID: { "com.apple.TextEdit" }
        )
        XCTAssertEqual(safari.replacement(for: ";y"), "exact later")
        XCTAssertEqual(
            textEdit.replacement(for: ";y"), "folded first",
            "where the earlier folded snippet applies, library order still beats the exact table"
        )
        XCTAssertEqual(
            NestedSnippetResolver(snippets: library).replacement(for: ";y"), "folded first",
            "exclude-only still answers when the app is unknown"
        )
    }

    func testExclusionWinsOverInclusionForTheSameBundle() {
        let library = [
            snippet(
                ";x", "blocked",
                includeApps: ["com.apple.Safari"],
                excludeApps: ["com.apple.Safari"]
            ),
            snippet(";x", "fallback")
        ]
        let resolver = NestedSnippetResolver(snippets: library) { "com.apple.Safari" }
        XCTAssertEqual(resolver.replacement(for: ";x"), "fallback")
    }

    func testBundleProviderIsReadOnEachLookup() {
        var bundle: String? = "com.apple.Safari"
        let resolver = NestedSnippetResolver(
            snippets: [
                snippet(";live", "safari", includeApps: ["com.apple.Safari"]),
                snippet(";live", "other")
            ],
            frontmostBundleID: { bundle }
        )
        XCTAssertEqual(resolver.lookup(";live"), "safari")
        bundle = "com.google.Chrome"
        XCTAssertEqual(resolver.replacement(for: ";live"), "other")
        bundle = nil
        XCTAssertEqual(resolver.lookup(";live"), "other")
    }

    func testSnapshotForwardsTheBundleProvider() {
        var bundle: String? = "com.apple.mail"
        let snapshot = SnippetMatchSnapshot(
            snippets: [
                snippet(";m", "mail", excludeApps: ["com.google.Chrome"]),
                snippet(";m", "fallback")
            ],
            frontmostBundleID: { bundle }
        )
        XCTAssertEqual(snapshot.snippets.count, 2, "app scope is not filtered when the snapshot is built")
        XCTAssertEqual(snapshot.nestedResolver.lookup(";m"), "mail")
        bundle = "com.google.Chrome"
        XCTAssertEqual(snapshot.nestedResolver.replacement(for: ";m"), "fallback")
    }

    func testEngineNestedLookupReadsTheCachedFrontmostBundle() {
        let engine = EventTapEngine()
        let disabled = snippet(";d", "off", enabled: false)
        let safari = snippet(";d", "safari", includeApps: ["com.apple.Safari"])
        let other = snippet(";d", "other")
        engine.snippets = [disabled, safari, other]
        XCTAssertEqual(
            engine.matchSnapshot.snippets.map(\.replacementText),
            ["off", "safari", "other"],
            "the shared snapshot still holds disabled and app-scoped snippets"
        )

        func setBundle(_ bundleID: String?) {
            engine.contextLock.lock()
            engine._frontmostContext = EventTapEngine.FrontmostContext(bundleID: bundleID)
            engine.contextLock.unlock()
        }

        setBundle("com.apple.Safari")
        XCTAssertEqual(engine.matchSnapshot.nestedResolver.lookup(";d"), "safari")
        setBundle("com.google.Chrome")
        XCTAssertEqual(engine.matchSnapshot.nestedResolver.replacement(for: ";d"), "other")
        setBundle(nil)
        XCTAssertEqual(
            engine.matchSnapshot.nestedResolver.replacement(for: ";d"), "other",
            "include-restricted does not answer an unknown app; the disabled snippet still must not"
        )
    }

    // MARK: - Unicode and empty triggers

    func testUnicodeTriggersAndEmptyTriggerSkipIneligibleEarlierSnippets() {
        let library = [
            snippet("café", "off", enabled: false),
            snippet("café", "coffee"),
            snippet("→go", "off", enabled: false),
            snippet("→go", "arrow", caseSensitive: true),
            snippet("", "off", enabled: false),
            snippet("", "restricted", includeApps: ["com.apple.Safari"]),
            snippet("", "blank")
        ]
        let resolver = NestedSnippetResolver(snippets: library, frontmostBundleID: { nil })
        XCTAssertEqual(resolver.replacement(for: "CAFÉ"), "coffee")
        XCTAssertEqual(resolver.replacement(for: "Café"), "coffee")
        XCTAssertEqual(resolver.replacement(for: "café"), "coffee")
        XCTAssertEqual(resolver.replacement(for: "→go"), "arrow")
        XCTAssertNil(resolver.replacement(for: "→GO"), "the case-sensitive unicode trigger does not fold")
        XCTAssertEqual(
            resolver.replacement(for: ""), "blank",
            "nil bundle: the include-restricted empty trigger does not answer, and the disabled one does not either"
        )
        let safari = NestedSnippetResolver(
            snippets: library,
            frontmostBundleID: { "com.apple.Safari" }
        )
        XCTAssertEqual(safari.replacement(for: ""), "restricted")
    }

    func testExcludeOnlyUnicodeTriggerStillAnswersWhenTheAppIsUnknown() {
        let resolver = NestedSnippetResolver(snippets: [
            snippet("café", "not in mail", excludeApps: ["com.apple.mail"])
        ])
        XCTAssertEqual(resolver.replacement(for: "CAFÉ"), "not in mail")
        let mail = NestedSnippetResolver(snippets: [
            snippet("café", "not in mail", excludeApps: ["com.apple.mail"]),
            snippet("café", "fallback")
        ], frontmostBundleID: { "com.apple.mail" })
        XCTAssertEqual(mail.replacement(for: "café"), "fallback")
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
