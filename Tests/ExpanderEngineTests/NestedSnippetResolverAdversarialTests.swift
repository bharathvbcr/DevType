import XCTest
import SourceTreeTestSupport
@testable import ExpanderEngine

/// Attacks nested `{{snippet:}}` lookup beyond the cases the fix already names.
///
/// The rule under test is the old library-order scan, plus eligibility: secrets and disabled
/// snippets never answer, and a snippet that does not `appliesTo` the bundle read on that call
/// never keeps the slot. An earlier folded match still beats a later exact one once both are
/// eligible. `appliesTo` itself is the oracle — these tests do not restate a second scope rule.
final class NestedSnippetResolverAdversarialTests: XCTestCase {

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
            replacementText: body,
            isCaseSensitive: caseSensitive,
            enabled: enabled,
            includeApps: includeApps,
            excludeApps: excludeApps
        )
        // Set after init. The initialiser wipes a secret's body, and a wiped body would hide a
        // resolver that still returned the secret.
        if isSecret {
            model.isSecret = true
            model.replacementText = body
        }
        return model
    }

    /// First eligible library-order hit, exact or case-folded. Same predicate the pre-index scan
    /// used, with secrets, `enabled`, and `appliesTo` applied.
    private func oracle(
        _ snippets: [SnippetModel],
        _ trigger: String,
        bundleID: String?
    ) -> String? {
        snippets.first { candidate in
            !candidate.isSecret
                && candidate.enabled
                && candidate.appliesTo(bundleID: bundleID)
                && (candidate.triggerKeyword == trigger
                    || (!candidate.isCaseSensitive
                        && candidate.triggerKeyword.lowercased() == trigger.lowercased()))
        }?.replacementText
    }

    private func assertMatchesOracle(
        _ snippets: [SnippetModel],
        _ queries: [String],
        bundleID: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolver = NestedSnippetResolver(snippets: snippets) { bundleID }
        for query in queries {
            XCTAssertEqual(
                resolver.replacement(for: query),
                oracle(snippets, query, bundleID: bundleID),
                "bundle=\(String(describing: bundleID)) query=\(query.debugDescription)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Disabled duplicates

    func testDisabledEarlierDuplicateDoesNotAnswer() {
        let library = [
            snippet(";t", "off", enabled: false),
            snippet(";t", "on")
        ]
        XCTAssertNil(
            NestedSnippetResolver(snippets: [library[0]]).replacement(for: ";t")
        )
        XCTAssertNil(
            NestedSnippetResolver(snippets: [library[0]]).replacement(for: ";T")
        )
        assertMatchesOracle(library, [";t", ";T", ";t "], bundleID: nil)
        XCTAssertEqual(
            NestedSnippetResolver(snippets: library).lookup(";t"),
            "on"
        )
    }

    func testDisabledFoldedTriggerDoesNotShadowLaterExactMatch() {
        let library = [
            snippet(";Ab", "off", enabled: false),
            snippet(";ab", "exact", caseSensitive: true)
        ]
        assertMatchesOracle(library, [";ab", ";AB", ";Ab", ";aB"], bundleID: nil)
        let resolver = NestedSnippetResolver(snippets: library)
        XCTAssertEqual(resolver.replacement(for: ";ab"), "exact")
        XCTAssertNil(resolver.replacement(for: ";AB"))
        XCTAssertNil(resolver.replacement(for: ";Ab"))
    }

    /// A disabled case-sensitive snippet used to occupy the exact slot and beat a later
    /// case-insensitive duplicate via library position, including on a folded query.
    func testCaseSensitiveDisabledDuplicateDoesNotKeepTheExactSlot() {
        let library = [
            snippet(";ab", "off", caseSensitive: true, enabled: false),
            snippet(";ab", "on")
        ]
        assertMatchesOracle(library, [";ab", ";AB", ";Ab"], bundleID: nil)
        let resolver = NestedSnippetResolver(snippets: library)
        XCTAssertEqual(resolver.replacement(for: ";ab"), "on")
        XCTAssertEqual(resolver.replacement(for: ";AB"), "on")
    }

    // MARK: - App scope

    func testIncludeAndExcludeThatRejectTheBundleDoNotShadowLaterEligible() {
        let safari = "com.apple.Safari"
        let mail = "com.apple.mail"
        let library = [
            snippet(";go", "safari-only", includeApps: ["COM.APPLE.SAFARI"]),
            snippet(";go", "not-mail", excludeApps: [mail]),
            snippet(";go", "everywhere"),
            snippet(
                ";both", "blocked",
                includeApps: [safari],
                excludeApps: [safari]
            ),
            snippet(";both", "fallback")
        ]
        let queries = [";go", ";GO", ";both", ";missing"]
        for bundle in [safari, "com.apple.safari", mail, "com.google.Chrome", " \(safari)", "\(safari) ", nil, ""] {
            assertMatchesOracle(library, queries, bundleID: bundle)
        }

        let chrome = NestedSnippetResolver(snippets: library) { "com.google.Chrome" }
        XCTAssertEqual(chrome.replacement(for: ";go"), "not-mail")
        XCTAssertEqual(chrome.replacement(for: ";both"), "fallback")
        let spaced = NestedSnippetResolver(snippets: library) { " \(safari)" }
        XCTAssertEqual(
            spaced.replacement(for: ";go"), "not-mail",
            "a bundle that differs by whitespace does not satisfy the include list"
        )
        XCTAssertFalse(library[0].appliesTo(bundleID: " \(safari)"))
    }

    func testSameTriggerAnswersInTheAppWhereItApplies() {
        let library = [
            snippet(";app", "in safari", includeApps: ["com.apple.Safari"]),
            snippet(";app", "in mail", includeApps: ["com.apple.mail"])
        ]
        var bundle: String? = "com.apple.Safari"
        let resolver = NestedSnippetResolver(snippets: library) { bundle }
        XCTAssertEqual(resolver.replacement(for: ";app"), "in safari")
        bundle = "com.apple.mail"
        XCTAssertEqual(resolver.lookup(";APP"), "in mail")
        bundle = "com.google.Chrome"
        XCTAssertNil(resolver.replacement(for: ";app"))
        bundle = nil
        XCTAssertNil(resolver.replacement(for: ";app"))
    }

    func testNilBundleSkipsIncludeRestrictedAndKeepsExcludeOnly() {
        let includeOnly = snippet(";i", "inc", includeApps: ["com.apple.Safari"])
        let excludeOnly = snippet(";e", "exc", excludeApps: ["com.apple.mail"])
        let emptyInclude = snippet(";z", "nope", includeApps: [""])
        let excludeEmptyToken = snippet(";empty-ex", "kept", excludeApps: [""])
        XCTAssertFalse(includeOnly.appliesTo(bundleID: nil))
        XCTAssertFalse(includeOnly.appliesTo(bundleID: ""))
        XCTAssertTrue(excludeOnly.appliesTo(bundleID: nil))
        XCTAssertTrue(excludeOnly.appliesTo(bundleID: ""))
        XCTAssertFalse(excludeOnly.appliesTo(bundleID: "com.apple.mail"))
        XCTAssertFalse(excludeOnly.appliesTo(bundleID: "COM.APPLE.MAIL"))
        XCTAssertFalse(emptyInclude.appliesTo(bundleID: nil))
        XCTAssertTrue(excludeEmptyToken.appliesTo(bundleID: nil))

        let library = [includeOnly, emptyInclude, excludeOnly, excludeEmptyToken, snippet(";i", "after-include"), snippet(";z", "after-empty-include")]
        assertMatchesOracle(library, [";i", ";e", ";z", ";empty-ex", ";E"], bundleID: nil)
        assertMatchesOracle(library, [";i", ";e", ";z", ";empty-ex"], bundleID: "")
        let unknown = NestedSnippetResolver(snippets: library)
        XCTAssertEqual(unknown.replacement(for: ";i"), "after-include")
        XCTAssertEqual(unknown.replacement(for: ";e"), "exc")
        XCTAssertEqual(unknown.replacement(for: ";z"), "after-empty-include")
        XCTAssertEqual(unknown.replacement(for: ";empty-ex"), "kept")
        XCTAssertNil(
            NestedSnippetResolver(snippets: [includeOnly]).replacement(for: ";i")
        )
    }

    // MARK: - Unicode, Turkish case fold, whitespace

    /// Swift `String` equates canonically equivalent scalars, and the resolver's tables use that
    /// equality. A decomposed trigger and its precomposed twin are one slot; a disabled earlier
    /// twin must not keep it. A sequence that is not equivalent stays a different trigger.
    func testCanonicalCombiningMarksShareASlotAndDisabledDoesNotShadow() {
        let precomposed = "\u{00E9}"
        let precomposedUpper = "\u{00C9}"
        let decomposed = "e\u{0301}"
        let decomposedUpper = "E\u{0301}"
        XCTAssertEqual(precomposed, decomposed)
        XCTAssertEqual(precomposedUpper, decomposedUpper)
        XCTAssertNotEqual("e", decomposed)
        XCTAssertNotEqual("cafe", "caf\u{00E9}")
        XCTAssertNotEqual("q\u{0301}", "q")

        let library = [
            snippet(decomposedUpper, "off", enabled: false),
            snippet(precomposed, "on"),
            snippet("cafe\u{0301}", "cafe-off", enabled: false),
            snippet("caf\u{00E9}", "accented"),
            snippet("cafe", "plain"),
            snippet("q\u{0301}", "q-off", enabled: false),
            snippet("q\u{0301}", "q-acute"),
            snippet("q", "q-plain"),
            snippet("\u{0301}", "mark-off", enabled: false),
            snippet("\u{0301}", "mark")
        ]
        let queries = [
            precomposed, precomposedUpper, decomposed, decomposedUpper, "e",
            "caf\u{00E9}", "cafe\u{0301}", "CAF\u{00C9}", "CAFE\u{0301}", "cafe", "CAFE",
            "q\u{0301}", "Q\u{0301}", "q", "Q", "\u{0301}", ""
        ]
        assertMatchesOracle(library, queries, bundleID: nil)
        let resolver = NestedSnippetResolver(snippets: library)
        XCTAssertEqual(resolver.replacement(for: decomposed), "on")
        XCTAssertEqual(resolver.replacement(for: precomposedUpper), "on")
        XCTAssertNil(resolver.replacement(for: "e"))
        XCTAssertEqual(resolver.replacement(for: "cafe\u{0301}"), "accented")
        XCTAssertEqual(resolver.replacement(for: "CAF\u{00C9}"), "accented")
        XCTAssertEqual(resolver.replacement(for: "cafe"), "plain")
        XCTAssertEqual(resolver.replacement(for: "CAFE"), "plain")
        XCTAssertEqual(resolver.replacement(for: "q\u{0301}"), "q-acute")
        XCTAssertEqual(resolver.replacement(for: "q"), "q-plain")
        XCTAssertEqual(resolver.replacement(for: "\u{0301}"), "mark")

        let earlierEquivalentWins = NestedSnippetResolver(snippets: [
            snippet(decomposed, "first"),
            snippet(precomposed, "second")
        ])
        XCTAssertEqual(earlierEquivalentWins.replacement(for: precomposedUpper), "first")
    }

    func testTurkishDotlessAndDottedIDoNotFoldIntoLatinI() {
        let dottedCapital = "\u{0130}"
        let dotless = "\u{0131}"
        let dottedFold = "i\u{0307}"
        XCTAssertEqual(dottedCapital.lowercased(), dottedFold)
        XCTAssertNotEqual(dottedCapital.lowercased(), "i")
        XCTAssertNotEqual("I".lowercased(), dotless)
        XCTAssertNotEqual(dotless.lowercased(), "i")

        let latin = NestedSnippetResolver(snippets: [snippet("I", "latin")])
        XCTAssertEqual(latin.replacement(for: "i"), "latin")
        XCTAssertEqual(latin.replacement(for: "I"), "latin")
        XCTAssertNil(latin.replacement(for: dottedCapital))
        XCTAssertNil(latin.replacement(for: dotless))
        XCTAssertNil(latin.replacement(for: dottedFold))

        let dotted = NestedSnippetResolver(snippets: [snippet(dottedCapital, "dotted")])
        XCTAssertEqual(dotted.replacement(for: dottedCapital), "dotted")
        XCTAssertEqual(dotted.replacement(for: dottedFold), "dotted")
        XCTAssertNil(dotted.replacement(for: "i"))
        XCTAssertNil(dotted.replacement(for: "I"))
        XCTAssertNil(dotted.replacement(for: dotless))

        let dotlessSnippet = NestedSnippetResolver(snippets: [snippet(dotless, "dotless", caseSensitive: true)])
        XCTAssertEqual(dotlessSnippet.replacement(for: dotless), "dotless")
        XCTAssertNil(dotlessSnippet.replacement(for: "I"))
        XCTAssertNil(dotlessSnippet.replacement(for: "i"))

        let mixed = [
            snippet("I", "latin-off", enabled: false),
            snippet(dotless, "dotless-on"),
            snippet("a\(dottedCapital)b", "word-off", enabled: false),
            snippet("a\(dottedFold)b", "word-on")
        ]
        assertMatchesOracle(
            mixed,
            ["i", "I", dotless, dottedCapital, dottedFold, "a\(dottedCapital)b", "aib", "a\(dottedFold)b"],
            bundleID: nil
        )
        let resolver = NestedSnippetResolver(snippets: mixed)
        XCTAssertNil(resolver.replacement(for: "i"), "the disabled Latin I must not answer")
        XCTAssertEqual(resolver.replacement(for: dotless), "dotless-on")
        XCTAssertEqual(resolver.replacement(for: "a\(dottedFold)b"), "word-on")
        XCTAssertEqual(resolver.replacement(for: "a\(dottedCapital)b"), "word-on")
        XCTAssertNil(resolver.replacement(for: "aib"))
    }

    func testDisabledTurkishFoldedTriggerDoesNotShadowLaterMatch() {
        let dottedCapital = "\u{0130}"
        let dottedFold = "i\u{0307}"
        let library = [
            snippet(dottedCapital, "off", enabled: false),
            snippet(dottedFold, "on", caseSensitive: true)
        ]
        assertMatchesOracle(library, [dottedCapital, dottedFold, "i", "I", "\u{0131}"], bundleID: nil)
        let resolver = NestedSnippetResolver(snippets: library)
        XCTAssertNil(resolver.replacement(for: dottedCapital))
        XCTAssertEqual(resolver.replacement(for: dottedFold), "on")
        XCTAssertNil(resolver.replacement(for: "i"))

        let foldedLater = NestedSnippetResolver(snippets: [
            snippet(dottedCapital, "off", enabled: false),
            snippet(dottedFold, "folded-on")
        ])
        XCTAssertEqual(foldedLater.replacement(for: dottedCapital), "folded-on")
        XCTAssertEqual(foldedLater.replacement(for: dottedFold), "folded-on")
        XCTAssertNil(foldedLater.replacement(for: "i"))
    }

    func testTriggersThatDifferOnlyByWhitespaceDoNotMatch() {
        let leading = " sig"
        let tab = "sig\t"
        let newline = "sig\n"
        let nbsp = "sig\u{00A0}"
        let inner = "s ig"
        let em = "sig\u{2003}"
        let ideographic = "\u{3000}sig"
        let library = [
            snippet("sig", "off", enabled: false),
            snippet("SIG ", "spaced-off", enabled: false),
            snippet("sig ", "spaced-exact", caseSensitive: true),
            snippet(leading, "leading"),
            snippet(tab, "tab"),
            snippet(newline, "newline"),
            snippet(nbsp, "nbsp"),
            snippet(inner, "inner"),
            snippet(em, "em"),
            snippet(ideographic, "ideographic"),
            snippet(" ", "one-space"),
            snippet("", "empty"),
            snippet("sig", "plain")
        ]
        let queries = [
            "sig", "SIG", "sig ", "SIG ", "sig  ", leading, leading.uppercased(),
            tab, newline, nbsp, nbsp.uppercased(), inner, inner.uppercased(),
            em, ideographic, " ", "", "\t"
        ]
        assertMatchesOracle(library, queries, bundleID: nil)

        let resolver = NestedSnippetResolver(snippets: library)
        XCTAssertEqual(resolver.replacement(for: "sig"), "plain")
        XCTAssertEqual(resolver.replacement(for: "SIG"), "plain")
        XCTAssertEqual(resolver.replacement(for: "sig "), "spaced-exact")
        XCTAssertNil(
            resolver.replacement(for: "SIG "),
            "the disabled folded spaced trigger must not answer, and the later one is case-sensitive"
        )
        XCTAssertEqual(resolver.replacement(for: leading), "leading")
        XCTAssertEqual(resolver.replacement(for: tab), "tab")
        XCTAssertEqual(resolver.replacement(for: newline), "newline")
        XCTAssertEqual(resolver.replacement(for: nbsp), "nbsp")
        XCTAssertEqual(resolver.replacement(for: inner), "inner")
        XCTAssertNil(resolver.replacement(for: "sig  "))
        XCTAssertEqual(resolver.replacement(for: " "), "one-space")
        XCTAssertEqual(resolver.replacement(for: ""), "empty")
        XCTAssertNotEqual(resolver.replacement(for: " "), resolver.replacement(for: ""))
    }

    // MARK: - Bundle closure and snapshot default

    func testBundleProviderIsReadOnEveryLookupIncludingAMiss() {
        var calls = 0
        let resolver = NestedSnippetResolver(
            snippets: [
                snippet(";live", "safari", includeApps: ["com.apple.Safari"]),
                snippet(";live", "other", excludeApps: ["com.apple.mail"])
            ],
            frontmostBundleID: {
                calls += 1
                switch calls {
                case 1: return "com.apple.Safari"
                case 2: return "com.google.Chrome"
                case 3, 4: return nil
                default: return "com.apple.mail"
                }
            }
        )
        XCTAssertEqual(calls, 0, "the provider is not read while indexing")
        XCTAssertEqual(resolver.replacement(for: ";live"), "safari")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(resolver.lookup(";live"), "other")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(resolver.replacement(for: ";missing"), nil)
        XCTAssertEqual(calls, 3, "a miss still reads the provider for that call")
        XCTAssertEqual(resolver.lookup(";LIVE"), "other", "nil bundle: the exclude-only snippet still answers")
        XCTAssertEqual(calls, 4)
        XCTAssertNil(
            resolver.replacement(for: ";live"),
            "the next call is Mail, which the exclude-only snippet rejects and the include list does not name"
        )
        XCTAssertEqual(calls, 5)
    }

    func testSnippetMatchSnapshotWithoutBundleProviderResolvesOnlyUnscoped() {
        let includeOnly = snippet(";r", "restricted", includeApps: ["com.apple.Safari"])
        let excludeOnly = snippet(";e", "excluded-mail", excludeApps: ["com.apple.mail"])
        let unscoped = snippet(";u", "open")
        let snapshot = SnippetMatchSnapshot(snippets: [
            snippet(";s", "off", enabled: false),
            includeOnly,
            snippet(";s", "open-same"),
            excludeOnly,
            unscoped
        ])
        XCTAssertEqual(snapshot.snippets.count, 5, "building the snapshot does not drop scoped snippets")
        XCTAssertNil(snapshot.nestedResolver.replacement(for: ";r"))
        XCTAssertEqual(snapshot.nestedResolver.replacement(for: ";u"), "open")
        XCTAssertEqual(snapshot.nestedResolver.lookup(";s"), "open-same")
        XCTAssertEqual(snapshot.nestedResolver.replacement(for: ";e"), "excluded-mail")
        XCTAssertEqual(snapshot.nestedResolver.replacement(for: ";E"), "excluded-mail")
        XCTAssertFalse(includeOnly.appliesTo(bundleID: nil))
        XCTAssertTrue(excludeOnly.appliesTo(bundleID: nil))
        XCTAssertTrue(unscoped.appliesTo(bundleID: nil))
    }

    func testSecretsNeverResolveEvenWhenTheyWouldOtherwiseWinTheSlot() {
        var secret = snippet(";pw", "hunter2", includeApps: ["com.apple.Safari"])
        secret.isSecret = true
        let library = [
            secret,
            snippet(";pw", "off", enabled: false),
            snippet(";pw", "not-here", excludeApps: ["com.apple.Safari"]),
            snippet(";pw", "public")
        ]
        assertMatchesOracle(library, [";pw", ";PW", ""], bundleID: "com.apple.Safari")
        assertMatchesOracle(library, [";pw"], bundleID: nil)
        let safari = NestedSnippetResolver(snippets: library) { "com.apple.Safari" }
        XCTAssertEqual(safari.replacement(for: ";pw"), "public")
        XCTAssertNil(
            NestedSnippetResolver(snippets: [secret]).replacement(for: ";pw")
        )
        XCTAssertNotEqual(safari.replacement(for: ";pw"), "hunter2")
    }

    // MARK: - Differential fuzz

    func testEligibilityAgreesWithLibraryOrderScanUnderFuzz() {
        var seed: UInt64 = 0xA11CE_5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let spellings = [
            ";ab", ";AB", ";Ab", "é", "É", "e\u{0301}", "E\u{0301}",
            "İ", "i", "I", "ı", "i\u{0307}",
            "sig", "sig ", " sig", "", " ", "→go", "→GO"
        ]
        let bundles: [String?] = [
            nil, "", "com.apple.Safari", "com.apple.mail", "com.google.Chrome", " COM.APPLE.SAFARI"
        ]
        let scopeChoices: [(include: [String], exclude: [String])] = [
            ([], []),
            (["com.apple.Safari"], []),
            ([], ["com.apple.mail"]),
            (["com.apple.Safari"], ["com.apple.Safari"]),
            (["com.apple.mail"], ["com.google.Chrome"]),
            ([""], [])
        ]

        for _ in 0..<200 {
            var library: [SnippetModel] = []
            let count = 1 + next(8)
            for index in 0..<count {
                let scope = scopeChoices[next(scopeChoices.count)]
                library.append(snippet(
                    spellings[next(spellings.count)],
                    "body\(index)",
                    caseSensitive: next(2) == 0,
                    isSecret: next(6) == 0,
                    enabled: next(4) != 0,
                    includeApps: scope.include,
                    excludeApps: scope.exclude
                ))
            }
            var bundle: String? = nil
            let resolver = NestedSnippetResolver(snippets: library) { bundle }
            for candidate in bundles {
                bundle = candidate
                for query in spellings {
                    XCTAssertEqual(
                        resolver.replacement(for: query),
                        oracle(library, query, bundleID: candidate),
                        "bundle=\(String(describing: candidate)) query=\(query.debugDescription) count=\(count)"
                    )
                }
            }
        }
    }

    // MARK: - One trigger, many copies, and the unique-trigger cost

    func testOneThousandCopiesOnlyTheLastEligibleAnswers() {
        let safari = "com.apple.Safari"
        var onlyLast: [SnippetModel] = (0..<999).map { index in
            snippet(";same", "copy-\(index)", includeApps: ["com.apple.Mail"])
        }
        onlyLast.append(snippet(";same", "last"))
        XCTAssertEqual(onlyLast.count, 1_000)

        let safariResolver = NestedSnippetResolver(snippets: onlyLast) { safari }
        XCTAssertEqual(safariResolver.replacement(for: ";same"), "last")
        XCTAssertEqual(safariResolver.lookup(";SAME"), "last")
        let mailResolver = NestedSnippetResolver(snippets: onlyLast) { "com.apple.Mail" }
        XCTAssertEqual(mailResolver.replacement(for: ";same"), "copy-0")
        let unknown = NestedSnippetResolver(snippets: onlyLast)
        XCTAssertEqual(
            unknown.replacement(for: ";same"), "last",
            "nil bundle: every include-restricted copy declines, so the last unscoped snippet answers"
        )

        var earlierWins = [snippet(";same", "first")]
        for index in 1..<1_000 {
            earlierWins.append(snippet(";same", "no-\(index)", excludeApps: [safari]))
        }
        XCTAssertEqual(
            NestedSnippetResolver(snippets: earlierWins) { safari }.replacement(for: ";same"),
            "first"
        )
        XCTAssertEqual(
            NestedSnippetResolver(snippets: earlierWins) { nil }.replacement(for: ";SAME"),
            "first",
            "exclude-only copies still answer when the app is unknown, and the earlier one wins"
        )

        let distinct = (0..<1_000).map { snippet("t\($0)", "v\($0)") }
        let distinctResolver = NestedSnippetResolver(snippets: distinct)
        XCTAssertEqual(distinctResolver.replacement(for: "t0"), "v0")
        XCTAssertEqual(distinctResolver.replacement(for: "t999"), "v999")
        XCTAssertNil(distinctResolver.replacement(for: "t1000"))

        var oneCandidate: [String: String] = [:]
        oneCandidate.reserveCapacity(distinct.count)
        for item in distinct {
            oneCandidate[item.triggerKeyword] = item.replacementText
        }
        let distinctQueries = distinct.map(\.triggerKeyword)
        let sink = BenchSink()
        let uniquePasses = 20
        let duplicateLookups = 400

        func warmup() {
            for query in distinctQueries {
                sink.eat(distinctResolver.replacement(for: query))
                sink.eat(oneCandidate[query])
            }
            for _ in 0..<20 {
                sink.eat(safariResolver.replacement(for: ";same"))
            }
        }
        warmup()

        let uniqueSeconds = minSeconds(rounds: 5) {
            for _ in 0..<uniquePasses {
                for query in distinctQueries {
                    sink.eat(distinctResolver.replacement(for: query))
                }
            }
        }
        let mapSeconds = minSeconds(rounds: 5) {
            for _ in 0..<uniquePasses {
                for query in distinctQueries {
                    sink.eat(oneCandidate[query])
                }
            }
        }
        let duplicateSeconds = minSeconds(rounds: 5) {
            for _ in 0..<duplicateLookups {
                sink.eat(safariResolver.replacement(for: ";same"))
            }
        }
        XCTAssertGreaterThan(sink.hash, 0)

        let uniqueLookups = uniquePasses * distinctQueries.count
        let uniqueNs = uniqueSeconds / Double(uniqueLookups) * 1e9
        let mapNs = mapSeconds / Double(uniqueLookups) * 1e9
        let duplicateNs = duplicateSeconds / Double(duplicateLookups) * 1e9
        let uniqueOverMap = mapNs > 0 ? uniqueNs / mapNs : -1
        let duplicateOverUnique = uniqueNs > 0 ? duplicateNs / uniqueNs : -1
        fputs(
            "ADVERSARIAL_BENCH unique_ns=\(Int(uniqueNs)) map_ns=\(Int(mapNs)) duplicate_ns=\(Int(duplicateNs)) unique_over_map=\(String(format: "%.3f", uniqueOverMap)) duplicate_over_unique=\(String(format: "%.3f", duplicateOverUnique)) unique_lookups=\(uniqueLookups) duplicate_lookups=\(duplicateLookups)\n",
            stderr
        )
    }

    // MARK: - Locks the fix was not allowed to move

    func testNestedMatchingSourceDoesNotReferenceEventTapEngine() throws {
        for path in [
            "Sources/ExpanderEngine/Matching/NestedSnippetResolver.swift",
            "Sources/ExpanderEngine/Matching/SnippetMatchSnapshot.swift"
        ] {
            let text = try SourceTree.text(path)
            XCTAssertFalse(text.contains("EventTapEngine"), path)
        }
    }

    func testCaseOrderAssertionsAreUnchanged() throws {
        let text = try SourceTree.text("Tests/ExpanderEngineTests/NestedSnippetResolverTests.swift")
        let required = [
            "func testEarlierFoldedMatchBeatsLaterExactMatch()",
            "snippet(\";Y\", \"folded first\", caseSensitive: false)",
            "snippet(\";y\", \"exact later\", caseSensitive: true)",
            "[\";y\", \";Y\"]",
            "resolver.replacement(for: \";y\"), \"folded first\"",
            "library order decides, not which table the key lives in",
            "func testEarlierCaseSensitiveTriggerDoesNotShadowLaterFoldedMatch()",
            "snippet(\";ab\", \"case sensitive\", caseSensitive: true)",
            "snippet(\";AB\", \"case insensitive\", caseSensitive: false)",
            "[\";ab\", \";AB\", \";Ab\", \";aB\"]",
            "resolver.replacement(for: \";ab\"), \"case sensitive\", \"exact match wins\"",
            "resolver.replacement(for: \";Ab\"), \"case insensitive\", \"only the folded one can match\""
        ]
        for assertion in required {
            XCTAssertTrue(text.contains(assertion), assertion)
        }
    }
}

private final class BenchSink {
    var hash: UInt64 = 0

    func eat(_ value: String?) {
        hash = hash &* 1_099_511_628_211 &+ UInt64(value?.utf8.count ?? 0)
    }
}

private func minSeconds(rounds: Int, _ body: () -> Void) -> Double {
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<rounds {
        let elapsed = ContinuousClock().measure(body)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if seconds < best {
            best = seconds
        }
    }
    return best
}
