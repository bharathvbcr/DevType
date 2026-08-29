import XCTest
@testable import ExpanderEngine

/// Contract for `AIMarkdownStripper` — the one place that decides what DevType does with
/// the Markdown a model volunteers.
///
/// The suite is organised around what can go wrong, in order of how much it costs the user:
///
/// 1. **Damage** — a rule that eats a filename, an identifier, a regex, or a URL. These
///    tests are the reason the boundary rules are stricter than CommonMark.
/// 2. **Ownership** — stripping Markdown the *author* wrote. Proofreading a README must
///    give the README back.
/// 3. **Invariants** — never grows, never empties, idempotent, layout preserved. Fuzzed,
///    because the interesting inputs are the ones nobody thought to write down.
/// 4. **Removal** — the feature itself, per construct.
final class AIMarkdownStripperTests: XCTestCase {

    private func strip(
        _ text: String,
        policy: AIMarkdownPolicy = .strip,
        original: String = ""
    ) -> String {
        AIMarkdownStripper.strip(text, policy: policy, original: original)
    }

    // MARK: - 1. Content that must survive untouched

    /// A double-underscore run around a bare identifier stays. `__strong__` and
    /// `__init__` are the same string, and only one of them can win: a model that wanted
    /// emphasis had `**` available and overwhelmingly uses it, while `__init__` has no
    /// other spelling. Leaving two underscores on screen is noise; turning `__init__`
    /// into `init` is a wrong word in someone's document.
    func testDunderIdentifiersOutrankUnderscoreEmphasis() {
        XCTAssertEqual(strip("the __init__ method"), "the __init__ method")
        XCTAssertEqual(strip("__all__ and __repr__"), "__all__ and __repr__")
        // The guard is exactly that narrow: more than one word, and it is emphasis again.
        XCTAssertEqual(strip("this is __very important__ news"), "this is very important news")
        // A single underscore run never needed the guard.
        XCTAssertEqual(strip("read _this_ first"), "read this first")
    }

    /// Identifiers are the single most likely thing to be destroyed by an emphasis rule,
    /// and DevType's users type them all day.
    func testIdentifiersAreNotEmphasis() {
        let cases = [
            "call snake_case_name before user_id is set",
            "the __init__ method and the __main__ guard",
            "USER_ID_HEADER and MAX_RETRY_COUNT",
            "_leadingUnderscore stays",
            "a_b_c_d_e",
            "__private__ and __dunder__ both survive"
        ]
        for text in cases {
            XCTAssertEqual(strip(text), text, "Damaged identifiers in: \(text)")
        }
    }

    /// Globs, multiplication, and pointer syntax all use `*` without meaning emphasis.
    func testAsteriskContentIsNotEmphasis() {
        let cases = [
            "rm -rf build/*.o and src/*.swift",
            "the area is 2 * 3 * 4 units",
            "char *buffer = NULL;",
            "SELECT * FROM users WHERE id = 1",
            "match a*b*c against the pattern"
        ]
        for text in cases {
            XCTAssertEqual(strip(text), text, "Damaged asterisk content in: \(text)")
        }
    }

    /// An escaped delimiter is not a delimiter, and the backslash stays put: unescaping
    /// would rewrite `\d` in a regex explanation and `\*` in a shell quote.
    func testEscapesAreNeitherDelimitersNorRewritten() {
        XCTAssertEqual(strip("literal \\*asterisks\\* here"), "literal \\*asterisks\\* here")
        XCTAssertEqual(strip("the \\d token matches a digit"), "the \\d token matches a digit")
        XCTAssertEqual(strip("escape it as \\* in a glob"), "escape it as \\* in a glob")
    }

    func testComparisonsAndGenericsAreNotAutolinks() {
        let cases = [
            "assert x < y and b > c",
            "an Array<Int> of values",
            "if count<max { return }"
        ]
        for text in cases {
            XCTAssertEqual(strip(text), text, "Damaged angle brackets in: \(text)")
        }
    }

    /// A URL is full of characters the stripper cares about. It must come out identical.
    func testURLsSurvive() {
        let cases = [
            "see https://example.com/a_b_c/d-e#frag?x=1 for details",
            "path is /var/log/system_daemon.log",
            "C:\\Users\\dev\\Documents"
        ]
        for text in cases {
            XCTAssertEqual(strip(text), text, "Damaged URL/path in: \(text)")
        }
    }

    /// A stray pipe is prose. Only a run of pipe lines carrying a `|---|` rule is a table.
    func testStrayPipesAreNotTables() {
        let text = "run ls | grep swift | wc -l to count them"
        XCTAssertEqual(strip(text), text)
    }

    func testUnmatchedDelimitersAreLeftAlone() {
        let cases = [
            "the file is 50% done *and counting",
            "an unclosed `backtick here",
            "a [bracket] with no target",
            "2 ** 3 is exponentiation"
        ]
        for text in cases {
            XCTAssertEqual(strip(text), text, "Damaged unmatched delimiter in: \(text)")
        }
    }

    // MARK: - 2. Ownership — the author's own Markdown is not the model's

    func testAuthorsMarkdownIsPreservedConstructByConstruct() {
        // The selection was already a Markdown document: proofreading it must not
        // quietly delete its formatting.
        let original = "## Setup\n\nRun the **installer** first.\n"
        let output = "## Setup\n\nRun the **installer** first, then reboot.\n"
        XCTAssertEqual(strip(output, original: original), output)
    }

    /// Ownership is per construct, not all-or-nothing: a bulleted selection keeps its
    /// bullets and still loses emphasis the model invented.
    func testOnlyTheConstructsTheInputUsesArePreserved() {
        let original = "- first item\n- second item"
        let output = "- first **item**\n- second item"
        XCTAssertEqual(strip(output, original: original), "- first item\n- second item")
    }

    func testConstructDetectionMatchesWhatTheStripperWouldRemove() {
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "a **bold** word").contains(.emphasis))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "# Title").contains(.heading))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "see `code`").contains(.codeSpan))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "```\nx\n```").contains(.codeFence))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "[a](https://b.c)").contains(.link))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "> quoted").contains(.blockquote))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "* item").contains(.list))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "| a | b |\n| - | - |").contains(.table))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "text\n\n---\n\nmore").contains(.thematicBreak))
        XCTAssertTrue(AIMarkdownStripper.constructs(in: "~~gone~~").contains(.strikethrough))

        // And the converse: plain prose owns nothing, so nothing is protected.
        XCTAssertEqual(AIMarkdownStripper.constructs(in: "just some plain words"), [])
        // snake_case is not emphasis to the detector for the same reason it is not
        // emphasis to the remover — they are the same code.
        XCTAssertFalse(AIMarkdownStripper.constructs(in: "user_id and post_id").contains(.emphasis))
    }

    // MARK: - 3. Invariants

    /// The three properties the call sites rely on, over structured fuzz built from real
    /// Markdown fragments rather than random bytes — random bytes almost never form a
    /// delimiter pair, which is exactly where the bugs are.
    func testInvariantsHoldUnderFuzz() {
        var rng = SplitMix64(seed: 0x4D41524B_444F574E)
        // No fence or code-span fragments here: those free their content, and a second
        // pass legitimately reads the freed code as prose. That exception is pinned down
        // on its own in `testIdempotenceIsScopedToTextWithoutCodeConstructs`.
        let fragments = [
            "**", "*", "_", "__", "~~", "#", "## ", "> ", ">  > ", "- ", "* ", "+ ",
            "[a]", "(https://x.y)", "![alt]", "|", "|---|", "---", "===", "\\*", "\n", "\r\n",
            " ", "word", "user_id", "🚀", "a", "<https://z.z>", "[r]: https://q.q", "\t", ":",
            "build/*.o", "2 * 3", "x < y"
        ]

        for iteration in 0..<4000 {
            let count = Int(rng.next() % 24)
            let text = (0..<count)
                .map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }
                .joined()

            for policy in [AIMarkdownPolicy.strip, .stripPreservingLayout] {
                let once = strip(text, policy: policy)

                XCTAssertLessThanOrEqual(
                    once.count, text.count,
                    "Grew the text (iteration \(iteration), policy \(policy)): \(text.debugDescription)"
                )
                XCTAssertEqual(
                    strip(once, policy: policy), once,
                    "Not idempotent (iteration \(iteration), policy \(policy)): \(text.debugDescription)"
                )
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    XCTAssertFalse(
                        once.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "Emptied the text (iteration \(iteration), policy \(policy)): \(text.debugDescription)"
                    )
                }
                if policy == .stripPreservingLayout {
                    XCTAssertEqual(
                        once.filter(\.isNewline).count, text.filter(\.isNewline).count,
                        "Changed the line count under .stripPreservingLayout: \(text.debugDescription)"
                    )
                }
            }
        }
    }

    /// The one place idempotence does not hold, stated rather than hidden.
    ///
    /// Opening a fence frees its body, and a second call has no way to know that body was
    /// ever code — so it strips it like prose. The fix is not a cleverer rule, it is that
    /// no call site runs the stripper twice: `AITransformCorrector` passes `.preserve`
    /// because the transformer already stripped, and `CorrectionOutputSanitizer` runs a
    /// single Markdown pass between two wrapper passes.
    func testIdempotenceIsScopedToTextWithoutCodeConstructs() {
        let freed = "```\nlet a = b_c_d\n```"
        let once = strip(freed)
        XCTAssertEqual(once, "let a = b_c_d", "First pass frees the body untouched")
        XCTAssertEqual(strip(once), "let a = b_c_d", "and this body happens to survive a second")

        // The case that does not survive one — the reason for the single-pass rule.
        let fenced = "```\nname = *value*\n```"
        XCTAssertEqual(strip(fenced), "name = *value*")
        XCTAssertEqual(strip(strip(fenced)), "name = value")
    }

    /// Ownership under fuzz: whatever the input owns is still in the output. Feeding the
    /// same text as both answer and source must be a no-op, whatever it contains.
    func testStrippingIsANoOpWhenTheInputOwnsEverything() {
        var rng = SplitMix64(seed: 0xFEED_FACE)
        let fragments = [
            "**bold**", "# h", "`c`", "- i", "> q", "[a](b)", "\n", "text",
            "|a|b|", "|-|-|", "~~s~~", "---", "_e_", "```", "<https://a.b>"
        ]

        for _ in 0..<1500 {
            let count = Int(rng.next() % 16)
            let text = (0..<count)
                .map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }
                .joined()
            XCTAssertEqual(
                strip(text, original: text), text,
                "Stripped a construct the source itself uses: \(text.debugDescription)"
            )
        }
    }

    /// Adversarial shapes that a line-scoped scanner could plausibly choke on. The bar is
    /// "returns, in bounded time, without corrupting" — not "removes everything".
    func testHostileInputIsSurvivable() {
        let cases = [
            String(repeating: "*", count: 5000),
            String(repeating: "*a", count: 4000),
            String(repeating: "[", count: 4000),
            String(repeating: "[a](", count: 2000),
            String(repeating: "`", count: 4000),
            String(repeating: "> ", count: 4000),
            String(repeating: "#", count: 4000),
            String(repeating: "|", count: 4000),
            "```" + String(repeating: "\nline", count: 2000),
            String(repeating: "_x_", count: 3000),
            String(repeating: "🚀**", count: 2000)
        ]
        for text in cases {
            let out = strip(text)
            XCTAssertLessThanOrEqual(out.count, text.count, "Grew hostile input")
            XCTAssertEqual(strip(out), out, "Not idempotent on hostile input")
        }
    }

    /// Past the size ceiling the stripper declines rather than scanning; the answer is
    /// handed back exactly as generated.
    func testOversizedInputIsReturnedUntouched() {
        let huge = String(repeating: "**bold** ", count: 80_000)
        XCTAssertGreaterThan(huge.utf8.count, AIMarkdownStripper.maximumInputBytes)
        XCTAssertEqual(strip(huge), huge)
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(strip(""), "")
        XCTAssertEqual(strip("   \n\t "), "   \n\t ")
    }

    /// Line terminators are content: a `\r\n` answer must not come back `\n`.
    func testLineTerminatorsRoundTrip() {
        XCTAssertEqual(strip("**a**\r\n**b**\r\n"), "a\r\nb\r\n")
        XCTAssertEqual(strip("a\n\nb\n"), "a\n\nb\n")
    }

    // MARK: - 4. Removal, per construct

    func testEmphasisIsRemoved() {
        XCTAssertEqual(strip("The **launch** is Friday."), "The launch is Friday.")
        XCTAssertEqual(strip("The *deck* is ready."), "The deck is ready.")
        XCTAssertEqual(strip("This is __really important__ news."), "This is really important news.")
        XCTAssertEqual(strip("Read _the whole thing_ first."), "Read the whole thing first.")
        XCTAssertEqual(strip("***Everything*** at once."), "Everything at once.")
        XCTAssertEqual(strip("~~Cancelled~~ moved to Monday."), "Cancelled moved to Monday.")
        XCTAssertEqual(strip("**bold _and_ italic**"), "bold and italic")
        XCTAssertEqual(strip("(**parenthesised**), and **punctuated**!"), "(parenthesised), and punctuated!")
    }

    func testHeadingsAreRemoved() {
        XCTAssertEqual(strip("# Title\nbody"), "Title\nbody")
        XCTAssertEqual(strip("###### Deep\nbody"), "Deep\nbody")
        XCTAssertEqual(strip("## Title ##\nbody"), "Title\nbody")
        XCTAssertEqual(strip("Title\n=====\nbody"), "Title\nbody")
        XCTAssertEqual(strip("####### Not a heading"), "####### Not a heading")
        XCTAssertEqual(strip("#hashtag stays"), "#hashtag stays")
    }

    func testCodeSpansAndFencesKeepTheirContent() {
        XCTAssertEqual(strip("Call `parseToken()` first."), "Call parseToken() first.")
        XCTAssertEqual(strip("Use ``a ` b`` here."), "Use a ` b here.")
        XCTAssertEqual(strip("Here:\n\n```swift\nlet x = 1\n```\n\nDone."), "Here:\n\nlet x = 1\n\nDone.")
        XCTAssertEqual(strip("~~~\nplain\n~~~"), "plain")
        // An unterminated fence still gives the body back — the body is the answer.
        XCTAssertEqual(strip("```python\nprint(1)"), "print(1)")
    }

    func testLinksKeepTheirText() {
        XCTAssertEqual(strip("See [the docs](https://example.com) now."), "See the docs now.")
        XCTAssertEqual(strip("An ![alt text](img.png) image."), "An alt text image.")
        XCTAssertEqual(strip("A [ref link][docs] here."), "A ref link here.")
        XCTAssertEqual(strip("Go to <https://example.com> now."), "Go to https://example.com now.")
        XCTAssertEqual(strip("Read [**this**](https://x.y)."), "Read this.")
        XCTAssertEqual(strip("Link with [parens](https://x.y/a(b)) inside."), "Link with parens inside.")
        XCTAssertEqual(strip("body\n\n[docs]: https://example.com\n"), "body\n")
    }

    func testBlockquotesListsAndRulesAreNormalised() {
        XCTAssertEqual(strip("> quoted line\nplain"), "quoted line\nplain")
        XCTAssertEqual(strip("> > nested"), "nested")
        // Bullets stay — a list with its markers pulled off is not plain text.
        XCTAssertEqual(strip("* one\n* two"), "- one\n- two")
        XCTAssertEqual(strip("+ one\n+ two"), "- one\n- two")
        XCTAssertEqual(strip("1. one\n2. two"), "1. one\n2. two")
        XCTAssertEqual(strip("before\n\n---\n\nafter"), "before\n\nafter")
        XCTAssertEqual(strip("before\n\n***\n\nafter"), "before\n\nafter")
    }

    func testTablesLoseTheirRuleAndOuterPipes() {
        XCTAssertEqual(
            strip("| Name | Age |\n|------|-----|\n| Ada  | 36  |"),
            "Name | Age\nAda  | 36"
        )
    }

    /// The realistic failure: a model answering a rewrite with a formatted report.
    func testWholeAnswerFromAModelThatIgnoredThePrompt() {
        let output = """
        ## Q3 Summary

        The **launch** shipped on time. Key points:

        * Revenue up `12%`
        * See [the deck](https://example.com/deck)

        ---

        _Prepared by the team._
        """
        let expected = """
        Q3 Summary

        The launch shipped on time. Key points:

        - Revenue up 12%
        - See the deck

        Prepared by the team.
        """
        XCTAssertEqual(strip(output, original: "q3 summary notes"), expected)
    }

    // MARK: - 5. Layout-preserving policy

    /// `.stripPreservingLayout` exists so `proofread` can keep its promise: the answer has
    /// the same lines the selection did. Inline markers still come off.
    func testLayoutPolicyNeverChangesTheLineCount() {
        let output = "# Heading\n\n---\n\n**bold** line\n\n```\nfenced\n```"
        let result = strip(output, policy: .stripPreservingLayout)
        XCTAssertEqual(result.filter(\.isNewline).count, output.filter(\.isNewline).count)
        XCTAssertFalse(result.contains("**"), "Inline emphasis should still be removed")
        XCTAssertTrue(result.contains("---"), "A rule may not be deleted under this policy")
        XCTAssertTrue(result.contains("```"), "A fence line may not be deleted under this policy")
    }

    func testLayoutPolicyStillStripsInlineAndPrefixes() {
        XCTAssertEqual(
            strip("# Notes\n- a **bold** point\n> quoted", policy: .stripPreservingLayout),
            "Notes\n- a bold point\nquoted"
        )
    }

    func testPreservePolicyIsAnExactIdentity() {
        let output = "## Heading\n\n**bold** and `code`\n\n| a | b |\n|---|---|"
        XCTAssertEqual(strip(output, policy: .preserve), output)
    }

    // MARK: - 6. Per-kind policy

    func testEveryKindHasADeliberatePolicy() {
        // Code and structured output: `*`, `_`, `#` and backticks are the program.
        for kind in [AITransformKind.fixCode, .generateDocstring, .toJson,
                     .generateUnitTests, .sqlQuery, .promptEnhance, .toMarkdown] {
            XCTAssertEqual(kind.markdownPolicy, .preserve, "\(kind.rawValue) must not be stripped")
        }
        // Kinds that owe the author their layout.
        for kind in [AITransformKind.proofread, .translate, .translateTelugu,
                     .translateHindi, .bulletize] {
            XCTAssertEqual(kind.markdownPolicy, .stripPreservingLayout, "\(kind.rawValue)")
        }
        // Prose.
        for kind in [AITransformKind.rewrite, .paraphrase, .expand, .condense, .formal,
                     .friendly, .explainCode, .explainRegex, .gitCommitMessage, .custom,
                     .removeMarkdown] {
            XCTAssertEqual(kind.markdownPolicy, .strip, "\(kind.rawValue)")
        }
        // And no kind is left undecided. A new case fails here until it is classified
        // above — the policy is a decision, not something to inherit by accident.
        XCTAssertEqual(AITransformKind.allCases.count, 23)
    }

    /// A layout-preserving kind must never break the line-structure contract that the
    /// transformer checks immediately afterwards.
    func testLayoutKindsCannotBreakTheLineStructureContract() {
        let answers = [
            "# One\n\n---\n\nTwo",
            "```\na\nb\n```",
            "| a | b |\n|---|---|\n| 1 | 2 |",
            "**a**\n_b_\n`c`"
        ]
        for kind in AITransformKind.allCases where kind.preservesLineStructure {
            XCTAssertEqual(kind.markdownPolicy, .stripPreservingLayout, "\(kind.rawValue)")
            for answer in answers {
                let result = strip(answer, policy: kind.markdownPolicy)
                XCTAssertTrue(
                    AITransformText.preservesLineStructure(input: answer, output: result),
                    "\(kind.rawValue) broke line structure on \(answer.debugDescription)"
                )
            }
        }
    }

    func testCustomInstructionsThatAskForMarkdownWin() {
        XCTAssertEqual(
            AIMarkdownStripper.policy(for: .custom, customInstructions: "Format this as a markdown table"),
            .preserve
        )
        XCTAssertEqual(
            AIMarkdownStripper.policy(for: .custom, customInstructions: "Make the key terms bold"),
            .preserve
        )
        XCTAssertEqual(
            AIMarkdownStripper.policy(for: .custom, customInstructions: "Translate to French"),
            .strip
        )
        // The override is scoped to `custom`; it cannot re-enable Markdown for a kind
        // whose contract forbids it.
        XCTAssertEqual(
            AIMarkdownStripper.policy(for: .proofread, customInstructions: "use markdown"),
            .stripPreservingLayout
        )
    }

    func testDisablingTheFeatureIsAFullPassthrough() {
        for kind in AITransformKind.allCases {
            XCTAssertEqual(AIMarkdownStripper.policy(for: kind, enabled: false), .preserve, "\(kind.rawValue)")
        }
    }
}
