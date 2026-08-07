import XCTest
@testable import ExpanderEngine

final class CommandPaletteMatchingTests: XCTestCase {

    private let posix = Locale(identifier: "en_US_POSIX")
    private let utc = TimeZone(secondsFromGMT: 0)!

    /// Fixed noon UTC on 2024-06-15 so date+1 / yesterday assertions stay stable.
    private var base: Date {
        var components = DateComponents()
        components.year = 2024
        components.month = 6
        components.day = 15
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private var savedLanguage: String?

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.string(forKey: LocalizationManager.deviceKey)
        UserDefaults.standard.set(AppLanguage.en.rawValue, forKey: LocalizationManager.deviceKey)
        LocalizationManager.shared.language = .en
    }

    override func tearDown() {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
        super.tearDown()
    }

    // MARK: - Relative date parsing

    func testParseDatePlusOne() {
        let parsed = CommandPaletteCatalog.parseRelativeDayQuery("date+1")
        XCTAssertEqual(parsed?.days, 1)
        XCTAssertEqual(parsed?.trigger, "date+1")
        XCTAssertTrue(parsed?.exactQuery == true)
    }

    func testParseDateMinusTwo() {
        let parsed = CommandPaletteCatalog.parseRelativeDayQuery("date-2")
        XCTAssertEqual(parsed?.days, -2)
    }

    func testParseBarePlusOneD() {
        let parsed = CommandPaletteCatalog.parseRelativeDayQuery("+1d")
        XCTAssertEqual(parsed?.days, 1)
    }

    func testParseNextFullDate() {
        let parsed = CommandPaletteCatalog.parseRelativeDayQuery("next full date")
        XCTAssertEqual(parsed?.days, 1)
        XCTAssertEqual(parsed?.format, "full")
    }

    func testResolveDatePlusOneISOPath() {
        let text = CommandPaletteCatalog.resolveDate(
            .offsetDays(1, format: "iso"),
            now: base,
            locale: posix,
            timeZone: utc
        )
        XCTAssertEqual(text, "2024-06-16")
    }

    func testResolveYesterday() {
        let text = CommandPaletteCatalog.resolveDate(
            .offsetDays(-1, format: "iso"),
            now: base,
            locale: posix,
            timeZone: utc
        )
        XCTAssertEqual(text, "2024-06-14")
    }

    // MARK: - Alias / NL matching

    func testMakeThisFormalSurfacesFormalAI() {
        let hits = CommandPaletteCatalog.matchCommands(
            query: "make this formal",
            loc: .shared,
            now: base,
            locale: posix,
            timeZone: utc
        )
        XCTAssertTrue(
            hits.contains { hit in
                if case .ai(.formal) = hit.command.action { return true }
                return false
            },
            "Expected formal AI in \(hits.map(\.command.id))"
        )
        XCTAssertEqual(hits.first?.command.id, "ai.formal")
    }

    func testProofReadSurfacesProofread() {
        let hits = CommandPaletteCatalog.matchCommands(query: "proof read", loc: .shared)
        XCTAssertTrue(hits.contains { $0.command.id == "ai.proofread" })
    }

    func testEnhancePromptSurfacesPromptEnhance() {
        let hits = CommandPaletteCatalog.matchCommands(query: "enhance prompt", loc: .shared)
        XCTAssertTrue(hits.contains { $0.command.id == "ai.promptenhance" })
    }

    /// The phrasings someone reaching for Telugu/Hindi → English would actually type.
    func testTranslateIsReachableByItsEverydayPhrasings() {
        for query in [
            "translate", "translation", "to english", "telugu to english",
            "hindi to english", "tenglish", "hinglish"
        ] {
            let hits = CommandPaletteCatalog.matchCommands(query: query, loc: .shared)
            XCTAssertTrue(
                hits.contains { $0.command.id == "ai.translate" },
                "\(query) should surface the translate action."
            )
        }
    }

    func testRefineIsReachableByItsEverydayPhrasings() {
        for query in [
            "refine", "fix telugu", "fix hindi", "telugu grammar", "hindi grammar",
            "correct telugu", "proofread hindi"
        ] {
            let hits = CommandPaletteCatalog.matchCommands(query: query, loc: .shared)
            XCTAssertTrue(
                hits.contains { $0.command.id == "ai.refine" },
                "\(query) should surface the refine action."
            )
        }
    }

    /// A bare language name is ambiguous between the two, so both must be offered
    /// rather than one of them being unreachable.
    func testBareLanguageNameOffersBothTranslateAndRefine() {
        for language in ["telugu", "hindi"] {
            let ids = Set(
                CommandPaletteCatalog.matchCommands(query: language, loc: .shared)
                    .map(\.command.id)
            )
            XCTAssertTrue(ids.contains("ai.translate"), "\(language) should offer translate.")
            XCTAssertTrue(ids.contains("ai.refine"), "\(language) should offer refine.")
        }
    }

    /// "fix telugu" is a correction request, not a translation request — if translate
    /// outranks refine here, the user's Telugu silently comes back as English.
    func testFixTeluguRanksRefineAboveTranslate() {
        let hits = CommandPaletteCatalog.matchCommands(query: "fix telugu", loc: .shared)
        let refine = hits.firstIndex { $0.command.id == "ai.refine" }
        let translate = hits.firstIndex { $0.command.id == "ai.translate" }
        guard let refine else { return XCTFail("expected refine for 'fix telugu'") }
        if let translate {
            XCTAssertLessThan(refine, translate)
        }
    }

    /// The mirror case: an explicit translation request must not surface refine first.
    func testTeluguToEnglishRanksTranslateAboveRefine() {
        let hits = CommandPaletteCatalog.matchCommands(query: "telugu to english", loc: .shared)
        let translate = hits.firstIndex { $0.command.id == "ai.translate" }
        let refine = hits.firstIndex { $0.command.id == "ai.refine" }
        guard let translate else { return XCTFail("expected translate for 'telugu to english'") }
        if let refine {
            XCTAssertLessThan(translate, refine)
        }
    }

    func testTomorrowsDateSurfacesTomorrow() {
        let hits = CommandPaletteCatalog.matchCommands(
            query: "tomorrow's date",
            loc: .shared,
            now: base,
            locale: posix,
            timeZone: utc
        )
        XCTAssertTrue(
            hits.contains {
                if case .date(.offsetDays(1, _)) = $0.command.action { return true }
                return false
            }
        )
    }

    func testDatePlusOneQueryInsertsTomorrow() {
        let hits = CommandPaletteCatalog.matchCommands(
            query: "date+1",
            loc: .shared,
            now: base,
            locale: posix,
            timeZone: utc
        )
        guard let top = hits.first else {
            return XCTFail("expected hits for date+1")
        }
        XCTAssertFalse(top.insertText.isEmpty)
        // Medium format for dynamic relative; value must be 16 June in some form.
        XCTAssertTrue(
            top.insertText.contains("16") || top.insertText.contains("2024-06-16"),
            "unexpected insertText: \(top.insertText)"
        )
    }

    func testClipboardAndNavAreReachable() {
        let clip = CommandPaletteCatalog.matchCommands(query: "clipboard", loc: .shared)
        XCTAssertTrue(clip.contains { $0.command.id == "tool.clipboard" })

        let prefs = CommandPaletteCatalog.matchCommands(query: "preferences", loc: .shared)
        XCTAssertTrue(prefs.contains { $0.command.id == "nav.preferences" })
    }

    func testCustomPrefixCreatesOneshootAI() {
        let hits = CommandPaletteCatalog.matchCommands(
            query: "> make this sound like Slack",
            loc: .shared
        )
        guard let top = hits.first else {
            return XCTFail("expected custom AI hit")
        }
        guard case .aiCustom(let instructions) = top.command.action else {
            return XCTFail("expected aiCustom, got \(top.command.action)")
        }
        XCTAssertEqual(instructions, "make this sound like Slack")
        XCTAssertEqual(top.score, 1200)
    }

    func testMathPrefixEvaluatesExpression() {
        let hits = CommandPaletteCatalog.matchCommands(query: "= 12 * 10", loc: .shared)
        guard let top = hits.first else {
            return XCTFail("expected math hit")
        }
        XCTAssertEqual(top.insertText, "120")
    }

    func testTextOpsUpperAndSort() {
        XCTAssertEqual(PaletteTextOps.apply(.upper, to: "Hi"), "HI")
        XCTAssertEqual(
            PaletteTextOps.apply(.sortLines, to: "b\na\nc"),
            "a\nb\nc"
        )
    }

    func testAIUndoStoreRoundTrip() {
        AIUndoStore.clear()
        XCTAssertFalse(AIUndoStore.hasUndo)
        AIUndoStore.stash("original")
        XCTAssertTrue(AIUndoStore.hasUndo)
        XCTAssertEqual(AIUndoStore.consume(), "original")
        XCTAssertFalse(AIUndoStore.hasUndo)
    }

    func testCatalogIncludesEveryBuiltInAITransform() {
        let aiIDs = Set(CommandPaletteCatalog.commands.compactMap { command -> String? in
            if case .ai(let kind) = command.action { return kind.rawValue }
            return nil
        })
        for kind in AITransformKind.builtInPalette {
            XCTAssertTrue(aiIDs.contains(kind.rawValue), "missing \(kind.rawValue)")
        }
    }

    func testBuildRowsSectionsKeepSnippetSearch() {
        let group = SnippetGroup(
            name: "Work",
            snippets: [
                SnippetModel(title: "Signature", triggerKeyword: ":sig", replacementText: "Best,\nAlex")
            ]
        )
        let rows = CommandPaletteCatalog.buildRows(
            query: "sig",
            groups: [group],
            loc: .shared
        )
        XCTAssertTrue(rows.contains {
            if case .snippet(let hit) = $0 { return hit.snippet.triggerKeyword == ":sig" }
            return false
        })
        XCTAssertTrue(rows.contains {
            if case .header(.snippets) = $0 { return true }
            return false
        })
    }
}
