import XCTest
@testable import ExpanderEngine

/// `SnippetTagSuggester`'s trust boundary — the half that runs with no model present.
///
/// The model path itself needs macOS 26 and real hardware, so what is tested here is the part
/// that decides what a model is *allowed* to have said. That split is deliberate: every rule
/// that protects the library is on this side of it.
final class SnippetTagSuggesterTests: XCTestCase {

    // MARK: - The CSV round-trip that motivates the semicolon rule

    /// Demonstrates the defect first, against the real exporter's join, so the rule below is
    /// anchored to a format DevType actually writes rather than to a hunch.
    func testSemicolonInATagWouldSplitIntoTwoOnCSVRoundTrip() {
        let hostile = ["billing;urgent"]
        let encoded = hostile.joined(separator: ";")
        XCTAssertEqual(
            encoded.components(separatedBy: ";").count,
            2,
            "one tag containing ';' encodes indistinguishably from two tags"
        )
    }

    func testNormalizationRejectsEverySeparatorThatRoundTripsAmbiguously() {
        for hostile in ["billing;urgent", "billing,urgent", "say \"hi\""] {
            XCTAssertEqual(
                SnippetTagSuggester.normalizedTags([hostile]),
                [],
                "\"\(hostile)\" carries a delimiter that export would read back as structure"
            )
        }
    }

    /// Newlines and tabs would wreck a CSV row too, but they are handled by collapsing rather
    /// than by rejection — a model that returns `"meeting\nnotes"` meant two words. Asserted
    /// because the two mechanisms are easy to confuse, and only one of them runs on these.
    func testNewlinesAndTabsAreCollapsedRatherThanRejected() {
        XCTAssertEqual(SnippetTagSuggester.normalizedTags(["meeting\nnotes"]), ["meeting notes"])
        XCTAssertEqual(SnippetTagSuggester.normalizedTags(["work\ttravel"]), ["work travel"])
    }

    /// Whichever mechanism handled it, the output must contain no CSV structure at all.
    func testNoNormalizedTagEverContainsAStructuralCharacter() {
        let hostile = [
            "billing;urgent", "billing,urgent", "say \"hi\"", "two\nlines", "a\ttab",
            "carriage\rreturn", "  spaced  out  ", "#tagged",
        ]
        for tag in SnippetTagSuggester.normalizedTags(hostile) {
            XCTAssertNil(
                tag.rangeOfCharacter(from: CharacterSet(charactersIn: ";,\"\n\r\t")),
                "\"\(tag)\" reached storage still carrying a delimiter"
            )
        }
    }

    /// The rejection must not take the whole batch down with it.
    func testAHostileTagIsDroppedWithoutLosingItsNeighbours() {
        XCTAssertEqual(
            SnippetTagSuggester.normalizedTags(["email", "billing;urgent", "signature"]),
            ["email", "signature"]
        )
    }

    // MARK: - Shape

    func testTagsAreLowercasedAndInternallyCollapsed() {
        XCTAssertEqual(
            SnippetTagSuggester.normalizedTags(["  Meeting   Notes  ", "EMAIL"]),
            ["meeting notes", "email"]
        )
    }

    func testDecorativeAffixesAreStripped() {
        XCTAssertEqual(SnippetTagSuggester.normalizedTags(["#email", "_billing_"]), ["email", "billing"])
    }

    func testCountIsCappedAndOrderIsPreserved() {
        let raw = (1...12).map { "tag\($0)" }
        let result = SnippetTagSuggester.normalizedTags(raw)
        XCTAssertEqual(result.count, SnippetTagSuggester.maximumTags)
        XCTAssertEqual(
            result,
            Array(raw.prefix(SnippetTagSuggester.maximumTags)),
            "truncation must drop the model's lowest-ranked tags, not an arbitrary subset"
        )
    }

    func testOverlongTagsAreRejected() {
        let long = String(repeating: "a", count: SnippetTagSuggester.maximumTagLength + 1)
        let atLimit = String(repeating: "b", count: SnippetTagSuggester.maximumTagLength)
        XCTAssertEqual(SnippetTagSuggester.normalizedTags([long, atLimit]), [atLimit])
    }

    /// A returned sentence is the model ignoring the format, not a legitimate long tag.
    func testSentencesAreRejectedButTwoWordTagsAreKept() {
        XCTAssertEqual(
            SnippetTagSuggester.normalizedTags(["a note for later", "meeting notes"]),
            ["meeting notes"]
        )
    }

    func testEmptyAndWhitespaceOnlyTagsAreDropped() {
        XCTAssertEqual(SnippetTagSuggester.normalizedTags(["", "   ", "\n", "#", "email"]), ["email"])
    }

    // MARK: - Deduplication

    /// `SnippetStore`'s merge dedupes with a case-sensitive `contains`, so two casings of one
    /// idea would both survive a sync and show as two filters.
    func testDuplicatesAreRemovedCaseInsensitively() {
        XCTAssertEqual(SnippetTagSuggester.normalizedTags(["Email", "email", "EMAIL"]), ["email"])
    }

    func testTagsAlreadyOnTheSnippetAreNotSuggestedAgain() {
        XCTAssertEqual(
            SnippetTagSuggester.normalizedTags(["Email", "billing"], existing: ["email"]),
            ["billing"]
        )
    }

    /// The cap counts what is *returned*, so an existing-tag collision must not consume a slot.
    func testFilteredDuplicatesDoNotConsumeTheCap() {
        let result = SnippetTagSuggester.normalizedTags(
            ["email", "a", "b", "c", "d", "e"],
            existing: ["email"]
        )
        XCTAssertEqual(result, ["a", "b", "c", "d", "e"])
    }

    // MARK: - Group resolution

    func testGroupIsReturnedInTheLibrarySpellingNotTheModels() {
        XCTAssertEqual(
            SnippetTagSuggester.resolvedGroupName("work email", in: ["Personal", "Work Email"]),
            "Work Email",
            "echoing the model's casing back would make a suggestion a silent rename"
        )
    }

    func testAnInventedGroupIsRefused() {
        XCTAssertNil(SnippetTagSuggester.resolvedGroupName("Invoices", in: ["Personal", "Work"]))
    }

    func testBlankAndMissingGroupsAreNoOpinion() {
        XCTAssertNil(SnippetTagSuggester.resolvedGroupName(nil, in: ["Work"]))
        XCTAssertNil(SnippetTagSuggester.resolvedGroupName("", in: ["Work"]))
        XCTAssertNil(SnippetTagSuggester.resolvedGroupName("   ", in: ["Work"]))
        XCTAssertNil(SnippetTagSuggester.resolvedGroupName("Work", in: []))
    }

    func testSurroundingWhitespaceDoesNotDefeatTheMatch() {
        XCTAssertEqual(SnippetTagSuggester.resolvedGroupName("  Work \n", in: ["Work"]), "Work")
    }

    // MARK: - Eligibility

    func testASecretIsNeverEligibleHoweverLongItsBody() {
        let body = String(repeating: "x", count: 500)
        XCTAssertFalse(SnippetTagSuggester.shouldSuggest(body: body, isSecret: true))
        XCTAssertTrue(SnippetTagSuggester.shouldSuggest(body: body, isSecret: false))
    }

    func testShortBodiesAreNotWorthTagging() {
        let short = String(repeating: "x", count: SnippetTagSuggester.minimumBodyCharacters - 1)
        let atLimit = String(repeating: "x", count: SnippetTagSuggester.minimumBodyCharacters)
        XCTAssertFalse(SnippetTagSuggester.shouldSuggest(body: short, isSecret: false))
        XCTAssertTrue(SnippetTagSuggester.shouldSuggest(body: atLimit, isSecret: false))
    }

    /// Whitespace is not content: padding must not buy eligibility.
    func testWhitespacePaddingDoesNotMakeAShortBodyEligible() {
        let padded = "  hi  " + String(repeating: " ", count: 200)
        XCTAssertFalse(SnippetTagSuggester.shouldSuggest(body: padded, isSecret: false))
    }

    // MARK: - Prompt

    func testPromptTruncatesTheBody() {
        let body = String(repeating: "x", count: 5_000)
        let prompt = SnippetTagSuggester.prompt(title: "T", body: body, groupNames: [])
        XCTAssertLessThan(prompt.count, 800, "the whole snippet must not be sent for a topic read")
        XCTAssertFalse(prompt.contains(body))
    }

    func testPromptListsTheGroupsTheModelMayChooseFrom() {
        let prompt = SnippetTagSuggester.prompt(
            title: "Invoice reply",
            body: "Thanks for the invoice, it is approved and scheduled for payment.",
            groupNames: ["Work", "Personal"]
        )
        XCTAssertTrue(prompt.contains("Work"))
        XCTAssertTrue(prompt.contains("Personal"))
    }

    func testPromptOmitsTheGroupSectionEntirelyWhenThereAreNoGroups() {
        let prompt = SnippetTagSuggester.prompt(title: "T", body: "body text here", groupNames: [])
        XCTAssertFalse(prompt.lowercased().contains("existing groups"))
    }

    // MARK: - Gating

    func testSuggestionRequiresBothTheMasterSwitchAndItsOwn() {
        let savedMaster = UserDefaults.standard.object(forKey: AIPreferences.enabledKey)
        let savedOwn = UserDefaults.standard.object(forKey: SnippetTagSuggester.enabledKey)
        defer {
            UserDefaults.standard.set(savedMaster, forKey: AIPreferences.enabledKey)
            UserDefaults.standard.set(savedOwn, forKey: SnippetTagSuggester.enabledKey)
        }

        UserDefaults.standard.set(false, forKey: AIPreferences.enabledKey)
        UserDefaults.standard.set(true, forKey: SnippetTagSuggester.enabledKey)
        XCTAssertFalse(SnippetTagSuggester.isActive, "the master AI switch must veto")

        UserDefaults.standard.set(true, forKey: AIPreferences.enabledKey)
        UserDefaults.standard.set(false, forKey: SnippetTagSuggester.enabledKey)
        XCTAssertFalse(SnippetTagSuggester.isActive, "tagging is opt-in on its own key")

        UserDefaults.standard.set(true, forKey: SnippetTagSuggester.enabledKey)
        XCTAssertTrue(SnippetTagSuggester.isActive)
    }

    func testTagSuggestionsAreOffByDefault() {
        let saved = UserDefaults.standard.object(forKey: SnippetTagSuggester.enabledKey)
        defer { UserDefaults.standard.set(saved, forKey: SnippetTagSuggester.enabledKey) }
        UserDefaults.standard.removeObject(forKey: SnippetTagSuggester.enabledKey)
        XCTAssertFalse(SnippetTagSuggester.isEnabled)
    }

    // MARK: - End-to-end shape

    /// Normalized output must be assignable to `SnippetModel.tags` and survive the exporter's
    /// encoding unchanged — the property the individual rules exist to produce.
    func testNormalizedTagsSurviveTheExporterEncodingUnchanged() {
        let tags = SnippetTagSuggester.normalizedTags(
            ["Email", "billing;urgent", "  Meeting   Notes ", "email", "signature"]
        )
        var snippet = SnippetModel(title: "T", triggerKeyword: ":t", replacementText: "body")
        snippet.tags = tags
        let encoded = snippet.tags.joined(separator: ";")
        XCTAssertEqual(encoded.components(separatedBy: ";"), tags)
    }
}
