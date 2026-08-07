import XCTest
import ApplicationServices
@testable import ExpanderEngine

final class AIPlumbingTests: XCTestCase {

    // MARK: - Token budget refusal

    func testTokenBudgetRefusesOversizedInput() {
        XCTAssertThrowsError(
            try AITokenBudget.evaluate(
                inputTokens: 6000,
                instructionTokens: 200,
                framingTokens: 10,
                contextSize: 8192,
                tokenBudgetMultiplier: 2.0
            )
        ) { error in
            guard let ai = error as? AITransformError,
                  case .inputTooLarge(let estimated, let context) = ai else {
                return XCTFail("expected inputTooLarge, got \(error)")
            }
            XCTAssertEqual(context, 8192)
            XCTAssertGreaterThan(estimated, context)
        }
    }

    func testTokenBudgetAllowsModestInput() throws {
        let maxResponse = try AITokenBudget.evaluate(
            inputTokens: 100,
            instructionTokens: 50,
            framingTokens: 5,
            contextSize: 8192,
            tokenBudgetMultiplier: AITransformKind.proofread.tokenBudgetMultiplier
        )
        XCTAssertGreaterThanOrEqual(maxResponse, AITokenBudget.minimumResponseTokens)
        XCTAssertLessThanOrEqual(maxResponse, 8192)
    }

    func testChunkSafetyFlagsMatchCatalog() {
        XCTAssertTrue(AITransformKind.proofread.isChunkSafe)
        XCTAssertTrue(AITransformKind.formal.isChunkSafe)
        XCTAssertFalse(AITransformKind.expand.isChunkSafe)
        XCTAssertFalse(AITransformKind.condense.isChunkSafe)
        XCTAssertFalse(AITransformKind.promptEnhance.isChunkSafe)
        XCTAssertFalse(AITransformKind.custom.isChunkSafe)
        XCTAssertTrue(
            AITransformKind.translate.isChunkSafe,
            "A paragraph translated alone means the same as one translated in context."
        )
        XCTAssertTrue(AITransformKind.refine.isChunkSafe)
    }

    // MARK: - Telugu / Hindi (usually typed in English letters)

    /// Both actions read a *guessed* source language and rewrite the text wholesale.
    /// Direct injection would land a wrong-language guess in the field with no warning.
    func testIndicKindsArePreviewedNotInjected() {
        XCTAssertEqual(AITransformKind.translate.defaultOutputMode, .preview)
        XCTAssertEqual(AITransformKind.refine.defaultOutputMode, .preview)
    }

    /// A creative temperature paraphrases instead of translating or correcting.
    func testIndicKindsAreLowTemperature() {
        XCTAssertLessThanOrEqual(AITransformKind.translate.temperature, 0.3)
        XCTAssertLessThanOrEqual(AITransformKind.refine.temperature, 0.3)
    }

    /// Romanized Telugu / Hindi tokenizes badly, so the response budget must exceed input.
    func testIndicKindsBudgetRoomForALongerOutput() {
        XCTAssertGreaterThan(AITransformKind.translate.tokenBudgetMultiplier, 1.0)
        XCTAssertGreaterThan(AITransformKind.refine.tokenBudgetMultiplier, 1.0)
    }

    func testTranslateCatalogDefaults() {
        let kind = AITransformKind.translate
        XCTAssertEqual(AITransformKind.named("translate"), kind)
        XCTAssertEqual(AITransformKind.named("Translate"), kind)
        XCTAssertEqual(kind.localizationKey, "ai.kind.translate")
        XCTAssertTrue(AITransformKind.builtInPalette.contains(kind))
    }

    func testRefineCatalogDefaults() {
        let kind = AITransformKind.refine
        XCTAssertEqual(AITransformKind.named("refine"), kind)
        XCTAssertEqual(AITransformKind.named("Refine"), kind)
        XCTAssertEqual(kind.localizationKey, "ai.kind.refine")
        XCTAssertTrue(AITransformKind.builtInPalette.contains(kind))
    }

    /// The instructions carry the whole feature: without the romanized framing the model
    /// reads "nenu intiki veltunnanu" as broken English and hands it back unchanged.
    func testTranslateInstructionsNameBothLanguagesAndEnglishOutput() {
        let instructions = AITransformKind.translate.instructions.lowercased()
        XCTAssertTrue(instructions.contains("telugu"))
        XCTAssertTrue(instructions.contains("hindi"))
        XCTAssertTrue(
            instructions.contains("english letters"),
            "The input is romanized, not native script — the model has to be told."
        )
        XCTAssertTrue(
            instructions.contains("only"),
            "The model must return the translation alone — no commentary or labels."
        )
    }

    /// Refine's one failure mode is quietly becoming Translate. The instructions must
    /// forbid that outright, or a Telugu grammar fix comes back as English.
    func testRefineInstructionsForbidTranslating() {
        let instructions = AITransformKind.refine.instructions.lowercased()
        XCTAssertTrue(instructions.contains("telugu"))
        XCTAssertTrue(instructions.contains("hindi"))
        XCTAssertTrue(instructions.contains("same language"))
        XCTAssertTrue(
            instructions.contains("never translate"),
            "Refine must keep the text in its own language."
        )
    }

    /// Translate and Refine are opposites; identical instructions would mean one of the
    /// two palette rows silently does the other one's job.
    func testTranslateAndRefineDoNotShareInstructions() {
        XCTAssertNotEqual(
            AITransformKind.translate.instructions,
            AITransformKind.refine.instructions
        )
    }

    func testPromptEnhanceCatalogDefaults() {
        let kind = AITransformKind.promptEnhance
        XCTAssertEqual(AITransformKind.named("promptEnhance"), kind)
        XCTAssertEqual(AITransformKind.named("promptenhance"), kind)
        XCTAssertEqual(kind.defaultOutputMode, .preview)
        XCTAssertEqual(kind.temperature, 0.35, accuracy: 0.001)
        XCTAssertTrue(AITransformKind.builtInPalette.contains(kind))
        XCTAssertEqual(kind.localizationKey, "ai.kind.promptenhance")
    }

    // MARK: - Selection TTL / staleness

    func testCachedSelectionFreshnessTTL() {
        let now = Date()
        let fresh = SelectionMonitor.CachedSelection(
            text: "hello",
            bundleID: "com.apple.TextEdit",
            changeToken: 1,
            timestamp: now
        )
        XCTAssertTrue(fresh.isFresh(asOf: now, maxAge: SelectionMonitor.defaultTTL))
        XCTAssertEqual(SelectionMonitor.defaultTTL, 6.0, accuracy: 0.001)
        XCTAssertTrue(fresh.isFresh(asOf: now.addingTimeInterval(5.0), maxAge: SelectionMonitor.defaultTTL))
        XCTAssertFalse(fresh.isFresh(asOf: now.addingTimeInterval(7.0), maxAge: SelectionMonitor.defaultTTL))
        // Explicit short maxAge still works for callers that tighten the window.
        XCTAssertFalse(fresh.isFresh(asOf: now.addingTimeInterval(2.0), maxAge: 1.5))
    }

    func testSelectionMonitorRejectsStaleSeed() {
        let suiteName = "devtype.ai.plumbing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = SelectionMonitor(defaults: defaults)
        let stale = SelectionMonitor.CachedSelection(
            text: "stale selection",
            bundleID: "com.apple.TextEdit",
            changeToken: 2,
            timestamp: Date().addingTimeInterval(-10)
        )
        monitor.seedCacheForTesting(stale)
        XCTAssertNil(monitor.cachedSelection(maxAge: SelectionMonitor.defaultTTL, rejectWeakAX: false))
    }

    func testSelectionMonitorKeepsCacheOnEmptySelectionRefresh() {
        let suiteName = "devtype.ai.plumbing.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = SelectionMonitor(defaults: defaults)
        let element = AXUIElementCreateApplication(getpid())
        let bundleID = "com.apple.TextEdit"

        // Non-empty → cache populated (notification-shaped path, not seedCacheForTesting).
        monitor.testingApplySelectionRefresh(
            text: "selected paragraph",
            bundleID: bundleID,
            element: element
        )
        XCTAssertEqual(
            monitor.cachedSelection(rejectWeakAX: false)?.text,
            "selected paragraph"
        )

        // Empty selection on the same element must KEEP last-known-good (the typed-path blocker).
        monitor.testingApplySelectionRefresh(
            text: nil,
            bundleID: bundleID,
            element: element
        )
        XCTAssertEqual(
            monitor.cachedSelection(rejectWeakAX: false)?.text,
            "selected paragraph"
        )

        monitor.testingApplySelectionRefresh(
            text: "",
            bundleID: bundleID,
            element: element
        )
        XCTAssertEqual(
            monitor.cachedSelection(rejectWeakAX: false)?.text,
            "selected paragraph"
        )
    }

    func testSelectionMonitorClearsOnDifferentElement() {
        let suiteName = "devtype.ai.plumbing.focus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = SelectionMonitor(defaults: defaults)
        let elementA = AXUIElementCreateApplication(getpid())
        // A second application element for a different PID is a distinct AXUIElement.
        let elementB = AXUIElementCreateApplication(0)

        monitor.testingApplySelectionRefresh(
            text: "from A",
            bundleID: "com.apple.TextEdit",
            element: elementA
        )
        XCTAssertNotNil(monitor.cachedSelection(rejectWeakAX: false))

        // Focus moved to a different element with empty selection → clear.
        monitor.testingApplySelectionRefresh(
            text: nil,
            bundleID: "com.apple.TextEdit",
            element: elementB
        )
        XCTAssertNil(monitor.cachedSelection(rejectWeakAX: false))
    }

    func testConsumeSelectionIsSingleUse() {
        let suiteName = "devtype.ai.plumbing.consume.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = SelectionMonitor(defaults: defaults)
        let now = Date()
        monitor.seedCacheForTesting(
            SelectionMonitor.CachedSelection(
                text: "once only",
                bundleID: "com.apple.TextEdit",
                changeToken: 1,
                timestamp: now
            )
        )

        let first = monitor.consumeSelection(
            asOf: now,
            rejectWeakAX: false,
            requireSameElement: false
        )
        XCTAssertEqual(first?.text, "once only")

        let second = monitor.consumeSelection(
            asOf: now,
            rejectWeakAX: false,
            requireSameElement: false
        )
        XCTAssertNil(second)
        XCTAssertNil(monitor.cachedSelection(asOf: now, rejectWeakAX: false))
    }

    func testHasWeakAXBlockedSelection() {
        let suiteName = "devtype.ai.plumbing.weakax.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = SelectionMonitor(defaults: defaults)
        let now = Date()
        // Chrome is seeded as false-success / weak-AX.
        monitor.seedCacheForTesting(
            SelectionMonitor.CachedSelection(
                text: "chrome selection",
                bundleID: "com.google.Chrome",
                changeToken: 1,
                timestamp: now
            )
        )

        XCTAssertTrue(monitor.hasWeakAXBlockedSelection(asOf: now))
        XCTAssertNil(monitor.cachedSelection(asOf: now, rejectWeakAX: true))
        XCTAssertNotNil(monitor.cachedSelection(asOf: now, rejectWeakAX: false))
        XCTAssertEqual(EventTapEngine.aiWeakAXHintKey, "ai.typed.weakAX")
    }

    // MARK: - Suspend-count nesting

    func testSuspendMatchingNestingBalance() {
        let engine = EventTapEngine.shared
        // Drain any leftover count from other tests (clamped floor).
        for _ in 0..<8 where engine.matchingSuspended {
            engine.resumeMatching()
        }
        XCTAssertFalse(engine.matchingSuspended)

        engine.suspendMatching()
        XCTAssertTrue(engine.matchingSuspended)
        engine.suspendMatching()
        XCTAssertTrue(engine.matchingSuspended)

        // Inner resume must not clear the outer suspend.
        engine.resumeMatching()
        XCTAssertTrue(engine.matchingSuspended)

        engine.resumeMatching()
        XCTAssertFalse(engine.matchingSuspended)

        // Extra resume clamps at zero.
        engine.resumeMatching()
        XCTAssertFalse(engine.matchingSuspended)
    }

    // MARK: - Single-flight guard

    func testSingleFlightGuardRejectsSecondRequest() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("AI transforms require macOS 26+")
        }
        let transformer = AITextTransformer()
        let acquired = await transformer.testingAcquireFlight()
        XCTAssertTrue(acquired)
        let second = await transformer.transform(kind: .proofread, input: "hello world")
        guard case .failure(let error) = second else {
            await transformer.testingReleaseFlight()
            return XCTFail("expected busy failure, got \(second)")
        }
        XCTAssertEqual(error, .busy)
        await transformer.testingReleaseFlight()

        // Latch free again — empty input still refuses without claiming live model output.
        let empty = await transformer.transform(kind: .proofread, input: "   ")
        guard case .failure(let emptyError) = empty else {
            return XCTFail("expected emptyInput, got \(empty)")
        }
        XCTAssertEqual(emptyError, .emptyInput)
        #else
        throw XCTSkip("FoundationModels unavailable at compile time")
        #endif
    }
}
