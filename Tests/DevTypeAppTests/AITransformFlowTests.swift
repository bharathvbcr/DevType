import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

@MainActor
final class AITransformFlowTests: XCTestCase {
    private var previousLanguage: AppLanguage?

    override func setUp() {
        super.setUp()
        previousLanguage = LocalizationManager.shared.language
        LocalizationManager.shared.language = .en
    }

    override func tearDown() {
        if let previousLanguage {
            LocalizationManager.shared.language = previousLanguage
        } else {
            LocalizationManager.shared.language = .system
        }
        super.tearDown()
    }

    func testLocalizedAvailabilityMapsReasonsToLocalizedStrings() {
        let loc = LocalizationManager.shared

        XCTAssertEqual(
            AITransformFlow.localizedAvailability(.unsupportedOS, loc: loc),
            loc.s("ai.availability.unsupportedOS")
        )
        XCTAssertEqual(
            AITransformFlow.localizedAvailability(.buildLacksFoundationModels, loc: loc),
            loc.s("ai.availability.buildLacksFoundationModels")
        )
        XCTAssertEqual(
            AITransformFlow.localizedAvailability(.deviceNotEligible, loc: loc),
            loc.s("ai.availability.deviceNotEligible")
        )
        XCTAssertEqual(
            AITransformFlow.localizedAvailability(.appleIntelligenceNotEnabled, loc: loc),
            loc.s("ai.availability.notEnabled")
        )
        XCTAssertEqual(
            AITransformFlow.localizedAvailability(.modelNotReady, loc: loc),
            loc.s("ai.availability.modelNotReady")
        )
    }

    func testLocalizedErrorMapsErrorsToLocalizedStrings() {
        let loc = LocalizationManager.shared

        XCTAssertEqual(
            AITransformFlow.localizedError(.unavailable(.unsupportedOS), loc: loc),
            loc.s("ai.availability.unsupportedOS")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.busy, loc: loc),
            loc.s("ai.error.busy")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.emptyInput, loc: loc),
            loc.s("ai.error.emptyInput")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.missingInstructions, loc: loc),
            loc.s("ai.error.missingInstructions")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.inputTooLarge(estimatedTokens: 123, contextSize: 45), loc: loc),
            loc.s("ai.error.inputTooLarge", 123, 45)
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.guardrailViolation, loc: loc),
            loc.s("ai.error.guardrail")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.exceededContextWindowSize, loc: loc),
            loc.s("ai.error.contextWindow")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.rateLimited, loc: loc),
            loc.s("ai.error.rateLimited")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.unsupportedLanguageOrLocale, loc: loc),
            loc.s("ai.error.language")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.assetsUnavailable, loc: loc),
            loc.s("ai.error.assets")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.decodingFailure, loc: loc),
            loc.s("ai.error.decoding")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.refusal, loc: loc),
            loc.s("ai.error.refusal")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.concurrentRequests, loc: loc),
            loc.s("ai.error.busy")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.unsupportedGuide, loc: loc),
            loc.s("ai.error.unsupportedGuide")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.languageDrift, loc: loc),
            loc.s("ai.error.languageDrift")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.unexpectedRewrite, loc: loc),
            loc.s("ai.error.unexpectedRewrite")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.promptEcho, loc: loc),
            loc.s("ai.error.promptEcho")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.discarded, loc: loc),
            loc.s("ai.error.discarded")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.unknown("prompt copied"), loc: loc),
            loc.s("ai.error.unknown", "prompt copied")
        )
        XCTAssertEqual(
            AITransformFlow.localizedError(.unknown(""), loc: loc),
            loc.s("ai.error.unknown", "—")
        )
    }

    func testRunUsesLocalTransformOnDirectMode() {
        AIUndoStore.clear()
        AIPreferences.setOutputMode(.direct, for: .removeMarkdown)
        defer {
            AIPreferences.resetOutputMode(for: .removeMarkdown)
            AIUndoStore.clear()
        }

        let input = "**hello**"
        var injected: String?
        AITransformFlow.run(
            input: input,
            kind: .removeMarkdown,
            sourceApp: nil,
            customInstructions: nil,
            forcePreview: false,
            onInject: { text, _ in
                injected = text
            }
        )

        XCTAssertEqual(injected, "hello")
        XCTAssertTrue(AIUndoStore.hasUndo)
        XCTAssertEqual(AIUndoStore.stashedOriginal(), input)
    }

    func testPresentFromHotkeyWhenAIDisabled() {
        let original = AIPreferences.isEnabled
        AIPreferences.isEnabled = false
        defer { AIPreferences.isEnabled = original }

        var alertShown = false
        DevTypeAlert.presenterOverride = { _, _, _, _, _, _ in
            alertShown = true
        }
        defer { DevTypeAlert.presenterOverride = nil }

        AITransformFlow.presentFromHotkey { _, _ in }
        XCTAssertTrue(alertShown)
    }

    func testPresentFromEngineForcesPreview() {
        AITransformFlow.presentFromEngine(
            input: "test text",
            kind: .removeMarkdown,
            sourceApp: nil,
            customInstructions: nil
        ) { _, _ in }
    }

    func testRunDirectWithEmptyTextAlert() {
        AIPreferences.setOutputMode(.direct, for: .removeMarkdown)
        defer { AIPreferences.resetOutputMode(for: .removeMarkdown) }

        var alertShown = false
        DevTypeAlert.presenterOverride = { _, _, _, _, _, _ in
            alertShown = true
        }
        defer { DevTypeAlert.presenterOverride = nil }

        AITransformFlow.run(
            input: "   ",
            kind: .removeMarkdown,
            sourceApp: nil,
            customInstructions: nil,
            forcePreview: false
        ) { _, _ in }
        XCTAssertTrue(alertShown)
    }

    func testRunDirectFailureAlert() {
        AIPreferences.setOutputMode(.direct, for: .custom)
        defer { AIPreferences.resetOutputMode(for: .custom) }

        let exp = expectation(description: "alert shown")
        DevTypeAlert.presenterOverride = { _, _, _, _, _, _ in
            exp.fulfill()
        }
        defer { DevTypeAlert.presenterOverride = nil }

        AITransformFlow.run(
            input: "hello",
            kind: .custom,
            sourceApp: nil,
            customInstructions: nil,
            forcePreview: false
        ) { _, _ in }
        waitForExpectations(timeout: 5.0)
    }
}
