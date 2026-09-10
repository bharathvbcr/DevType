import XCTest
@testable import ExpanderEngine

final class AIPreferencesCoverageTests: XCTestCase {
    // MARK: - AIPreferences

    func testAIPreferencesOutputMode() {
        let original = AIPreferences.outputMode(for: .proofread)
        AIPreferences.setOutputMode(.direct, for: .proofread)
        XCTAssertEqual(AIPreferences.outputMode(for: .proofread), .direct)

        AIPreferences.resetOutputMode(for: .proofread)
        XCTAssertEqual(AIPreferences.outputMode(for: .proofread), original)
    }

    func testAIPreferencesMarkdownRemoval() {
        let original = AIPreferences.removesMarkdown
        defer { AIPreferences.removesMarkdown = original }

        AIPreferences.removesMarkdown = true
        XCTAssertTrue(AIPreferences.removesMarkdown)
        XCTAssertEqual(AIPreferences.voiceMarkdownPolicy, .strip)

        AIPreferences.removesMarkdown = false
        XCTAssertFalse(AIPreferences.removesMarkdown)
        XCTAssertEqual(AIPreferences.voiceMarkdownPolicy, .preserve)
    }

    func testAIPreferencesTypedPathAllowlist() {
        let original = AIPreferences.typedPathAllowlist
        defer { AIPreferences.typedPathAllowlist = original }

        AIPreferences.typedPathAllowlist = []
        XCTAssertTrue(AIPreferences.isTypedPathAllowed(bundleID: "com.apple.Safari"))

        AIPreferences.addTypedPathApp("com.apple.Safari")
        XCTAssertTrue(AIPreferences.isTypedPathAllowed(bundleID: "com.apple.safari"))
        XCTAssertFalse(AIPreferences.isTypedPathAllowed(bundleID: "com.apple.Notes"))
        XCTAssertFalse(AIPreferences.isTypedPathAllowed(bundleID: ""))

        AIPreferences.removeTypedPathApps(["com.apple.Safari"])
        XCTAssertTrue(AIPreferences.typedPathAllowlist.isEmpty)
    }

    func testAIPreferencesSemanticRouting() {
        let original = AIPreferences.isSemanticRoutingEnabled
        defer { AIPreferences.isSemanticRoutingEnabled = original }

        AIPreferences.isSemanticRoutingEnabled = true
        XCTAssertTrue(AIPreferences.isSemanticRoutingEnabled)
        AIPreferences.isSemanticRoutingEnabled = false
        XCTAssertFalse(AIPreferences.isSemanticRoutingEnabled)
    }

    func testLocalizationKeys() {
        let avail: AIModelAvailability = .available
        XCTAssertEqual(avail.localizationKey, "ai.availability.available")
        XCTAssertEqual(AIModelAvailability.unavailable(.unsupportedOS).localizationKey, "ai.availability.unsupportedOS")
        XCTAssertEqual(AIModelAvailability.unavailable(.buildLacksFoundationModels).localizationKey, "ai.availability.buildLacksFoundationModels")
        XCTAssertEqual(AIModelAvailability.unavailable(.deviceNotEligible).localizationKey, "ai.availability.deviceNotEligible")
        XCTAssertEqual(AIModelAvailability.unavailable(.appleIntelligenceNotEnabled).localizationKey, "ai.availability.notEnabled")
        XCTAssertEqual(AIModelAvailability.unavailable(.modelNotReady).localizationKey, "ai.availability.modelNotReady")

        let errs: [AITransformError] = [
            .unavailable(.unsupportedOS), .busy, .concurrentRequests, .emptyInput,
            .missingInstructions, .inputTooLarge(estimatedTokens: 10, contextSize: 5),
            .guardrailViolation, .exceededContextWindowSize, .rateLimited,
            .unsupportedLanguageOrLocale, .assetsUnavailable, .decodingFailure,
            .refusal, .unsupportedGuide, .languageDrift, .unexpectedRewrite,
            .promptEcho, .discarded, .unknown("err")
        ]
        for err in errs {
            XCTAssertFalse(err.localizationKey.isEmpty)
        }
    }

    // MARK: - PaletteToolRouter

    func testPaletteToolRouterSanitize() {
        XCTAssertEqual(PaletteToolRouter.sanitize("  valid single line  "), "valid single line")
        XCTAssertNil(PaletteToolRouter.sanitize(""))
        XCTAssertNil(PaletteToolRouter.sanitize("   \n   "))
        XCTAssertNil(PaletteToolRouter.sanitize("line1\nline2"))
        XCTAssertNil(PaletteToolRouter.sanitize(String(repeating: "a", count: 401)))
    }

    func testPaletteToolRouterShouldAttemptRouting() {
        let origMaster = AIPreferences.isEnabled
        let origSemantic = AIPreferences.isSemanticRoutingEnabled
        defer {
            AIPreferences.isEnabled = origMaster
            AIPreferences.isSemanticRoutingEnabled = origSemantic
        }

        AIPreferences.isEnabled = false
        AIPreferences.isSemanticRoutingEnabled = false
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "valid query"))

        AIPreferences.isEnabled = true
        AIPreferences.isSemanticRoutingEnabled = true
        XCTAssertTrue(PaletteToolRouter.shouldAttemptRouting(query: "valid query"))
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "abc"))
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "= 1 + 2"))
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "> prompt"))
    }

    func testPaletteToolRouterRouteWithEngine() async {
        let origMaster = AIPreferences.isEnabled
        let origSemantic = AIPreferences.isSemanticRoutingEnabled
        defer {
            AIPreferences.isEnabled = origMaster
            AIPreferences.isSemanticRoutingEnabled = origSemantic
        }

        AIPreferences.isEnabled = true
        AIPreferences.isSemanticRoutingEnabled = true

        let engine: PaletteToolRouter.RoutingEngine = { query in
            return "routed result for \(query)"
        }

        let result = await PaletteToolRouter.route(query: "what day is today?", engine: engine)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "routed result for what day is today?")

        // Engine returns prose with newlines -> rejected
        let multilineEngine: PaletteToolRouter.RoutingEngine = { _ in "line 1\nline 2" }
        let multilineResult = await PaletteToolRouter.route(query: "what day is today?", engine: multilineEngine)
        XCTAssertNil(multilineResult)
    }

    // MARK: - SnippetTagSuggester

    func testSnippetTagSuggesterShouldSuggest() {
        XCTAssertFalse(SnippetTagSuggester.shouldSuggest(body: "too short", isSecret: false))
        XCTAssertFalse(SnippetTagSuggester.shouldSuggest(body: "a sufficiently long snippet body to suggest", isSecret: true))
        XCTAssertTrue(SnippetTagSuggester.shouldSuggest(body: "a sufficiently long snippet body to suggest", isSecret: false))
    }

    func testSnippetTagSuggesterNormalizedTags() {
        let raw = ["#Swift", "iOS-Dev", "a very long tag exceeding the max length by far", "has;semicolon", "too many words in this tag here", "duplicate", "DUPLICATE"]
        let tags = SnippetTagSuggester.normalizedTags(raw, existing: [])
        XCTAssertTrue(tags.contains("swift"))
        XCTAssertTrue(tags.contains("ios-dev"))
        XCTAssertFalse(tags.contains("has;semicolon"))
        XCTAssertEqual(tags.filter { $0 == "duplicate" }.count, 1)
    }

    func testSnippetTagSuggesterResolvedGroupName() {
        let groups = ["Work", "Personal", "Code Snippets"]
        XCTAssertEqual(SnippetTagSuggester.resolvedGroupName("work", in: groups), "Work")
        XCTAssertEqual(SnippetTagSuggester.resolvedGroupName("PERSONAL", in: groups), "Personal")
        XCTAssertNil(SnippetTagSuggester.resolvedGroupName("Unknown", in: groups))
        XCTAssertNil(SnippetTagSuggester.resolvedGroupName(nil, in: groups))
    }

    func testSnippetTagSuggesterSuggestWithMockEngine() async {
        let origMaster = AIPreferences.isEnabled
        let origSuggest = SnippetTagSuggester.isEnabled
        defer {
            AIPreferences.isEnabled = origMaster
            SnippetTagSuggester.isEnabled = origSuggest
        }

        AIPreferences.isEnabled = true
        SnippetTagSuggester.isEnabled = true

        let mockEngine: SnippetTagSuggester.TaggingEngine = { _ in
            return SnippetTagSuggester.RawTagging(tags: ["swift", "macos"], group: "work")
        }

        let suggestion = await SnippetTagSuggester.suggest(
            title: "Test",
            body: "A long enough body for snippet suggestion testing",
            isSecret: false,
            existingTags: [],
            groupNames: ["Work"],
            engine: mockEngine
        )

        XCTAssertEqual(suggestion.tags, ["swift", "macos"])
        XCTAssertEqual(suggestion.groupName, "Work")
    }
}
