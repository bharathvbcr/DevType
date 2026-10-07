import XCTest
@testable import ExpanderEngine

final class TriggerMatchingTests: XCTestCase {

    func testDynamicPasteboardRestoreDelayMath() {
        let pipeline = TextInjectionPipeline.shared

        let smallDelay = pipeline.calculateRestoreDelay(payloadBytes: 100)
        XCTAssertEqual(smallDelay, 0.15, accuracy: 0.001)

        let mediumDelay = pipeline.calculateRestoreDelay(payloadBytes: 4000)
        XCTAssertEqual(mediumDelay, 0.15, accuracy: 0.001)

        let hugeDelay = pipeline.calculateRestoreDelay(payloadBytes: 50000)
        XCTAssertEqual(hugeDelay, 0.45, accuracy: 0.001)
    }

    func testEraseCountWithSwallowedFinalKey() {
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 4, swallowedFinalKey: true), 3)
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 4, swallowedFinalKey: false), 4)
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 1, swallowedFinalKey: true), 0)
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 0, swallowedFinalKey: true), 0)
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 0, swallowedFinalKey: false), 0)
    }

    func testEraseCountUsesLastEventCharacterCount() {
        // Multi-scalar final key (e.g. composed character) swallowed → erase fewer code units.
        XCTAssertEqual(
            TextInjectionPipeline.eraseCount(triggerLength: 5, swallowedFinalKey: true, lastEventCharacterCount: 2),
            3
        )
        XCTAssertEqual(
            TextInjectionPipeline.eraseCount(triggerLength: 2, swallowedFinalKey: true, lastEventCharacterCount: 2),
            0
        )
        XCTAssertEqual(
            TextInjectionPipeline.eraseCount(triggerLength: 3, swallowedFinalKey: true, lastEventCharacterCount: 5),
            0
        )
    }

    func testRestoreGenerationTokenMonotonic() {
        XCTAssertEqual(TextInjectionPipeline.nextRestoreGeneration(current: 0), 1)
        XCTAssertEqual(TextInjectionPipeline.nextRestoreGeneration(current: 41), 42)
        XCTAssertEqual(TextInjectionPipeline.nextRestoreGeneration(current: UInt64.max), 0)
    }

    func testShouldResetBufferPolicy() {
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: .maskCommand, keyCode: 0))
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: .maskControl, keyCode: 0))
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: [], keyCode: 123)) // left arrow
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: .maskAlternate, keyCode: 51)) // Option+Delete
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: .maskShift, keyCode: 51))
        XCTAssertFalse(EventTapEngine.shouldResetBuffer(flags: [], keyCode: 51)) // plain backspace
        XCTAssertFalse(EventTapEngine.shouldResetBuffer(flags: [], keyCode: 0)) // plain key
    }

    func testEmptyTriggerNeverMatches() {
        let engine = EventTapEngine()
        engine.snippets = [
            SnippetModel(title: "Empty", triggerKeyword: "", replacementText: "nope", requireWordBoundary: false)
        ]
        XCTAssertNil(engine.findMatch(in: "anything"))
        XCTAssertNil(engine.findMatch(in: ""))
        XCTAssertFalse(engine.evaluateMatch(bufferSnapshot: "hello"))
    }

    func testDefaultHelloHasNoClipboardTemplate() {
        let hello = SnippetStore().defaultSnippets().first { $0.triggerKeyword == ":hello" }
        XCTAssertNotNil(hello)
        XCTAssertFalse(hello!.replacementText.contains("{{clipboard}}"))
    }

    func testSnippetMatchingLogic() {
        let engine = EventTapEngine()
        let snippet1 = SnippetModel(
            title: "Email",
            triggerKeyword: ":eml",
            replacementText: "user@example.com",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        let snippet2 = SnippetModel(
            title: "CaseSensitive",
            triggerKeyword: ":CODE",
            replacementText: "SECRET",
            isCaseSensitive: true,
            requireWordBoundary: false
        )

        engine.snippets = [snippet1, snippet2]

        // Pure findMatch / evaluateMatch — no inject, no pasteboard mutation
        XCTAssertNotNil(engine.findMatch(in: "hello :EML"))
        XCTAssertTrue(engine.evaluateMatch(bufferSnapshot: "hello :EML"))
        XCTAssertNil(engine.findMatch(in: "hello :code"))
        XCTAssertFalse(engine.evaluateMatch(bufferSnapshot: "hello :code"))
        XCTAssertEqual(engine.findMatch(in: "hello :CODE")?.snippet.triggerKeyword, ":CODE")
    }

    func testLongestMatchWinsAmongSuffixTriggers() {
        let engine = EventTapEngine()
        let short = SnippetModel(
            title: "Short",
            triggerKeyword: ":em",
            replacementText: "short",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        let long = SnippetModel(
            title: "Long",
            triggerKeyword: ":eml",
            replacementText: "long",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        // Short listed first — longest-match must still prefer :eml
        engine.snippets = [short, long]

        XCTAssertEqual(engine.findMatch(in: "hello :eml")?.snippet.triggerKeyword, ":eml")
        XCTAssertEqual(engine.findMatch(in: "hello :em")?.snippet.triggerKeyword, ":em")
    }

    func testEqualLengthMatchPrefersEarlierSnippet() {
        let engine = EventTapEngine()
        let first = SnippetModel(
            title: "First",
            triggerKeyword: ":ab",
            replacementText: "one",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        let second = SnippetModel(
            title: "Second",
            triggerKeyword: ":AB",
            replacementText: "two",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        engine.snippets = [first, second]

        XCTAssertEqual(engine.findMatch(in: "x :ab")?.snippet.title, "First")
    }

    func testRefuseMustNotSwallowContract() {
        let refuse = InjectionPlan.refuse(reason: "test")
        XCTAssertFalse(EventTapEngine.shouldSwallowTrigger(plan: refuse))
        XCTAssertTrue(EventTapEngine.shouldSwallowTrigger(plan: .axOnly))
        XCTAssertTrue(EventTapEngine.shouldSwallowTrigger(plan: .axPlusHID))
        XCTAssertTrue(EventTapEngine.mustReinjectOnRefuse(didSwallow: true))
        XCTAssertFalse(EventTapEngine.mustReinjectOnRefuse(didSwallow: false))
    }

    func testAutorepeatIgnoredForMatching() {
        XCTAssertTrue(EventTapEngine.shouldIgnoreForMatching(isAutorepeat: true))
        XCTAssertFalse(EventTapEngine.shouldIgnoreForMatching(isAutorepeat: false))
    }
}
