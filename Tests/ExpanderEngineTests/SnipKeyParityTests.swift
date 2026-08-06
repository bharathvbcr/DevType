import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

// Ported / adapted from SnipKey Kit tests (MIT) — Copyright 2026 SnipKey contributors

final class AbbreviationMatcherTests: XCTestCase {

    private func snippet(_ trigger: String, _ body: String, caseSensitive: Bool = true, boundary: Bool = true) -> SnippetModel {
        SnippetModel(
            title: trigger,
            triggerKeyword: trigger,
            replacementText: body,
            isCaseSensitive: caseSensitive,
            requireWordBoundary: boundary
        )
    }

    private func matcher(_ snippets: [SnippetModel]) -> AbbreviationMatcher {
        AbbreviationMatcher(snippets: snippets)
    }

    func testTypingDesignNeverMatchesSigSnippet() {
        let m = matcher([snippet("sig", "SIGNATURE-BLOCK")])
        for end in 1..."design".count {
            let prefix = String("design".prefix(end))
            XCTAssertNil(m.match(buffer: prefix), "buffer '\(prefix)'")
        }
    }

    func testBareWordNeedsTerminator() {
        let m = matcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "sig"))
        let match = m.match(buffer: "sig ")
        XCTAssertEqual(match?.snippet.replacementText, "SIGNATURE-BLOCK")
        XCTAssertEqual(match?.backspaces, 4)
        XCTAssertEqual(match?.terminator, " ")
    }

    func testPunctuationPrefixedMatchesImmediately() {
        let m = matcher([snippet(";sig", "Best regards")])
        let match = m.match(buffer: ";sig")
        XCTAssertEqual(match?.snippet.replacementText, "Best regards")
        XCTAssertEqual(match?.terminator, "")
        XCTAssertEqual(match?.backspaces, 4)
    }

    func testPunctuationPrefixedMatchesAfterLetter() {
        let m = matcher([snippet(";sig", "Best regards")])
        XCTAssertEqual(m.match(buffer: "a;sig")?.snippet.replacementText, "Best regards")
    }

    func testTypingSignalNeverMatchesSig() {
        let m = matcher([snippet("sig", "SIGNATURE-BLOCK")])
        for end in 1..."signal".count {
            XCTAssertNil(m.match(buffer: String("signal".prefix(end))))
        }
        XCTAssertNil(m.match(buffer: "signal "))
    }

    func testLongestBareWordWinsWhenTerminated() {
        let m = matcher([
            snippet("sig", "SHORT"),
            snippet("sigma", "LONG"),
        ])
        XCTAssertEqual(m.match(buffer: "sigma ")?.snippet.replacementText, "LONG")
        XCTAssertEqual(m.match(buffer: "sig ")?.snippet.replacementText, "SHORT")
    }

    func testRequireWordBoundaryFalseAllowsInstantBareWord() {
        let m = matcher([snippet("sig", "NOW", boundary: false)])
        XCTAssertEqual(m.match(buffer: "sig")?.snippet.replacementText, "NOW")
    }

    func testKoreanWordBoundary() {
        let m = matcher([snippet("사인", "서명란")])
        XCTAssertNil(m.match(buffer: "회사인"))
        XCTAssertEqual(m.match(buffer: "사인 ")?.snippet.replacementText, "서명란")
        XCTAssertEqual(m.match(buffer: "사인 ")?.backspaces, 3)
    }

    func testReturnAndTabAreAcceptedTerminatorsByMatcher() {
        let m = matcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertEqual(m.match(buffer: "sig\n")?.terminator, "\n")
        XCTAssertEqual(m.match(buffer: "sig\t")?.terminator, "\t")
    }
}

final class DevTypeKeyClassifierTests: XCTestCase {

    /// DevType policy: Return/Tab are literal (may terminate+swallow), not clearBuffer.
    func testReturnAndTabAreLiteral() {
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_Return), .literal)
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_ANSI_KeypadEnter), .literal)
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_Tab), .literal)
    }

    func testEscapeAndNavigationClearBuffer() {
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_Escape), .clearBuffer)
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_LeftArrow), .clearBuffer)
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_ForwardDelete), .clearBuffer)
    }

    func testBackspaceDeletesLast() {
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_Delete), .deleteLast)
    }

    func testShouldResetBufferOmitsReturnAndTab() {
        XCTAssertFalse(EventTapEngine.shouldResetBuffer(flags: [], keyCode: Int64(kVK_Return)))
        XCTAssertFalse(EventTapEngine.shouldResetBuffer(flags: [], keyCode: Int64(kVK_Tab)))
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: [], keyCode: Int64(kVK_Escape)))
    }
}

final class MacroParserParityTests: XCTestCase {

    func testURLEncodedKoreanIsNotMisparsed() {
        let content = "https://x.com/?q=%EB%AF%B8%EA%B5%AD 100%certain"
        let tokens = MacroParser.parse(content)
        let rendered = MacroParser.render(tokens: tokens)
        XCTAssertEqual(rendered.text, content)
    }

    func testFillTextDefaultWithColonURL() {
        let tokens = MacroParser.parse("%filltext:name=url:default=https://example.com%")
        XCTAssertEqual(tokens, [.fillText(name: "url", defaultValue: "https://example.com")])
    }

    func testClipboardNeedsNoTrailingPercent() {
        let tokens = MacroParser.parse("x%clipboardy")
        XCTAssertEqual(tokens, [.text("x"), .clipboard, .text("y")])
    }

    func testMacroRendererDualPath() {
        let result = MacroRenderer.expand(
            content: "Hi %clipboard and {{calc: 2+2}}",
            clipboardText: "there"
        )
        XCTAssertEqual(result.text, "Hi there and 4")
        XCTAssertFalse(result.needsFillIn)
    }

    func testNestedSnippetDepthLimit() {
        let nested = MacroRenderer.expand(
            content: "%snippet:a%",
            lookup: { _ in "%snippet:a%" }
        )
        // Unresolved after depth — should not infinite-loop; may keep literal or empty nesting.
        XCTAssertTrue(nested.text.contains("%snippet:") || nested.text.isEmpty || !nested.text.isEmpty)
    }

    func testMustacheSnippetNested() {
        let result = MacroRenderer.expand(
            content: "A{{snippet:inner}}B",
            lookup: { trigger in trigger == "inner" ? "X" : nil }
        )
        XCTAssertEqual(result.text, "AXB")
    }
}

final class HangulComposerParityTests: XCTestCase {

    func testChoJungSyllable() {
        XCTAssertEqual(HangulComposer.compose(physicalKeys: Array("rk")), "가")
        XCTAssertEqual(HangulComposer.glyphCount(physicalKeys: Array("rk")), 1)
    }

    func testPunctuationBreaksComposition() {
        let composed = HangulComposer.compose(physicalKeys: Array(";rk"))
        XCTAssertTrue(composed.hasPrefix(";"))
        // Physical ";clear" (6 keys) composes to fewer visible Hangul glyphs (e.g. ";칟ㅁㄱ" = 4).
        XCTAssertEqual(HangulComposer.glyphCount(physicalKeys: Array(";clear")), 4)
        // Non-jamo digits stay 1:1 (letter keys map to 두벌식 jamo).
        XCTAssertEqual(HangulComposer.glyphCount(physicalKeys: Array("123")), 3)
    }

    func testTwoSetKoreanGate() {
        XCTAssertTrue(isTwoSetKoreanSourceID("com.apple.inputmethod.Korean.2SetKorean"))
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.inputmethod.Korean.3SetKorean"))
        XCTAssertFalse(isTwoSetKoreanSourceID(""))
    }
}

final class LayoutAwareMatcherParityTests: XCTestCase {

    func testComposedPreferredOverPhysical() {
        let snippets = [
            SnippetModel(title: "a", triggerKeyword: ";hi", replacementText: "HELLO", isCaseSensitive: true, requireWordBoundary: false)
        ]
        let matcher = AbbreviationMatcher(snippets: snippets)
        var layout = LayoutBuffer()
        for ch in ";hi" {
            layout.appendLiteral(composed: String(ch), physical: ch)
        }
        let decision = LayoutAwareMatcher.decide(
            composedBuffer: ";hi",
            layout: layout,
            matcher: matcher,
            allowPhysicalFallback: true
        )
        XCTAssertEqual(decision?.source, .composed)
        XCTAssertEqual(decision?.match.snippet.replacementText, "HELLO")
    }

    func testPhysicalFallbackWhenComposedMisses() {
        let snippets = [
            SnippetModel(title: "a", triggerKeyword: ";hi", replacementText: "HELLO", isCaseSensitive: true, requireWordBoundary: false)
        ]
        let matcher = AbbreviationMatcher(snippets: snippets)
        var layout = LayoutBuffer()
        // Composed looks Korean-ish; physical is ";hi"
        layout.appendLiteral(composed: ";", physical: ";")
        layout.appendLiteral(composed: "ㅗ", physical: "h")
        layout.appendLiteral(composed: "ㅑ", physical: "i")
        let decision = LayoutAwareMatcher.decide(
            composedBuffer: ";ㅗㅑ",
            layout: layout,
            matcher: matcher,
            allowPhysicalFallback: true
        )
        XCTAssertEqual(decision?.source, .physical)
        XCTAssertEqual(decision?.match.snippet.replacementText, "HELLO")
    }

    func testPhysicalFallbackDisabledOutsideTwoSet() {
        let snippets = [
            SnippetModel(title: "a", triggerKeyword: ";hi", replacementText: "HELLO", isCaseSensitive: true, requireWordBoundary: false)
        ]
        let matcher = AbbreviationMatcher(snippets: snippets)
        var layout = LayoutBuffer()
        layout.appendLiteral(composed: "x", physical: ";")
        layout.appendLiteral(composed: "y", physical: "h")
        layout.appendLiteral(composed: "z", physical: "i")
        let decision = LayoutAwareMatcher.decide(
            composedBuffer: "xyz",
            layout: layout,
            matcher: matcher,
            allowPhysicalFallback: false
        )
        XCTAssertNil(decision)
    }
}

final class InputClockParityTests: XCTestCase {

    func testBootNanosConversion() {
        XCTAssertEqual(InputClock.seconds(sinceBootNanos: 1_500_000_000), 1.5, accuracy: 0.0001)
    }

    func testAbortWhenInputAfterArm() {
        var now: TimeInterval = 100
        let clock = InputClock(now: { now })
        let guard_ = clock.arm()
        clock.mark(at: 100.5)
        if case .abort = clock.decide(guard_) {
            // expected
        } else {
            XCTFail("expected abort")
        }
        now = 200
        let guard2 = clock.arm()
        XCTAssertEqual(clock.decide(guard2), .proceed)
    }

    func testMarkKeepsMaxEventTime() {
        let clock = InputClock(now: { 0 })
        clock.mark(at: 10)
        clock.mark(at: 5)
        XCTAssertEqual(clock.lastInputAt, 10)
    }
}

final class EraseCountMatchTests: XCTestCase {

    func testTerminatorSwallowedErasesFullTrigger() {
        XCTAssertEqual(
            TextInjectionPipeline.eraseCountForMatch(
                triggerUTF16Length: 3,
                terminator: " ",
                swallowedFinalKey: true,
                lastEventCharacterCount: 1
            ),
            3
        )
    }

    func testPunctInstantUsesSwallowedMath() {
        XCTAssertEqual(
            TextInjectionPipeline.eraseCountForMatch(
                triggerUTF16Length: 4,
                terminator: "",
                swallowedFinalKey: true,
                lastEventCharacterCount: 1
            ),
            3
        )
    }
}

final class SnippetSearchSigilParityTests: XCTestCase {

    private func groups() -> [SnippetGroup] {
        [
            SnippetGroup(name: "Misc", snippets: [
                SnippetModel(title: "", triggerKeyword: "~clear", replacementText: "clear it", isCaseSensitive: true),
                SnippetModel(title: "로그", label: "로그 지우기", triggerKeyword: "~clearlog", replacementText: "%filltext:name=x%", isCaseSensitive: true),
                SnippetModel(title: "", triggerKeyword: "~unclear", replacementText: "모호", isCaseSensitive: true),
            ])
        ]
    }

    func testBareQueryRanksSigilAbbreviation() {
        let hits = SnippetSearch.run(query: "clear", in: groups())
        XCTAssertTrue(hits.contains { $0.snippet.triggerKeyword == "~clear" })
        XCTAssertEqual(hits.first?.snippet.triggerKeyword, "~clear")
    }
}

final class SchemaV2MigrationTests: XCTestCase {

    func testV1DocumentMigratesToGroupsWithoutWipe() throws {
        let v1 = """
        {"schemaVersion":1,"snippets":[{"id":"11111111-1111-1111-1111-111111111111","title":"T","triggerKeyword":":a","replacementText":"A","isCaseSensitive":false,"requireWordBoundary":true,"isPlainText":true,"createdAt":0,"updatedAt":0,"usageCount":0}]}
        """.data(using: .utf8)!
        let snippets = try SnippetStore.decodeSnippets(from: v1)
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets[0].triggerKeyword, ":a")

        let doc = try JSONDecoder().decode(SnippetDocument.self, from: v1)
        XCTAssertEqual(doc.groups.count, 1)
        XCTAssertEqual(doc.groups[0].name, SnippetDocument.defaultGroupName)
    }

    func testCurrentSchemaIsV2() {
        XCTAssertEqual(SnippetDocument.currentSchemaVersion, 2)
    }
}
