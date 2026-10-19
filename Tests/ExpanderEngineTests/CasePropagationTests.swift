import XCTest
import SourceTreeTestSupport
@testable import ExpanderEngine

/// Enhancement plan 1.4: `sig` / `Sig` / `SIG` shapes the expansion.
///
/// The shape rule is Espanso's `calculate_casing_style` so imported `propagate_case` matches keep
/// their behaviour; the application is narrower than Espanso's on purpose — template text only,
/// never fill-in values, the clipboard or generated values.
final class CasePropagationTests: XCTestCase {

    // MARK: - Shape derivation (matcher side)

    func testTheThreeShapes() {
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "sig"), .asWritten)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "Sig"), .firstUpper)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "SIG"), .allUpper)
    }

    func testNonLettersAreSkippedWhenReadingTheShape() {
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: ":Sig"), .firstUpper)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: ";;SIG"), .allUpper)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: ":👍Sig"), .firstUpper)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "1st"), .asWritten)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: ":123"), .asWritten, "No letter, no request")
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: ""), .asWritten)
    }

    /// Mixed triggers that start lowercase stay as written; like Espanso, only the first two
    /// letters are read, so `SiG` is Capitalized.
    func testMixedCaseTriggersThatStartLowercaseStayAsWritten() {
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "sIG"), .asWritten)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "siG"), .asWritten)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "iOS"), .asWritten)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "SiG"), .firstUpper)
    }

    /// Espanso's default `uppercase_style` treats a lone capital as ALL CAPS.
    func testASingleCapitalLetterMeansAllUpper() {
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: ":S"), .allUpper)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: ":s"), .asWritten)
    }

    /// Deseret has real case mappings outside the BMP: a UTF-16 reading would see surrogates.
    func testAstralLettersAreReadAsLetters() {
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "𐐀𐐁x"), .allUpper)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "𐐀𐐩𐐻"), .firstUpper)
        XCTAssertEqual(TriggerCaseShape.of(typedTrigger: "𐐨𐐁"), .asWritten)
    }

    func testOnlyAnOptedInCaseInsensitiveSnippetPropagates() {
        let optedIn = SnippetModel(title: "s", triggerKeyword: "sig", replacementText: "x", propagateCase: true)
        let sensitive = SnippetModel(title: "s", triggerKeyword: "sig", replacementText: "x",
                                     isCaseSensitive: true, propagateCase: true)
        let off = SnippetModel(title: "s", triggerKeyword: "sig", replacementText: "x")
        XCTAssertEqual(TriggerCaseShape.forExpansion(of: optedIn, typedTrigger: "SIG"), .allUpper)
        XCTAssertEqual(TriggerCaseShape.forExpansion(of: sensitive, typedTrigger: "SIG"), .asWritten)
        XCTAssertEqual(TriggerCaseShape.forExpansion(of: off, typedTrigger: "SIG"), .asWritten)
        XCTAssertEqual(TriggerCaseShape.forExpansion(of: optedIn, typedTrigger: nil), .asWritten,
                       "A trigger that cannot be reconstructed (physical Hangul) asks for nothing")
    }

    func testTheMatcherHandsOverTheTriggerAsTyped() throws {
        let snippet = SnippetModel(title: "s", triggerKeyword: ";sig", replacementText: "best, sam",
                                   propagateCase: true, requireWordBoundary: false)
        let matcher = AbbreviationMatcher(snippets: [snippet])
        let cases: [(String, TriggerCaseShape)] = [(";sig", .asWritten), (";Sig", .firstUpper), (";SIG", .allUpper)]
        for (typed, shape) in cases {
            let found = try XCTUnwrap(matcher.match(buffer: "x " + typed), typed)
            let match = SnippetMatch(snippet: found.snippet, triggerLength: found.triggerLength,
                                     fieldText: found.matchedText)
            XCTAssertEqual(match.caseShape, shape, typed)
        }
    }

    // MARK: - Application (render side)

    private func render(
        _ content: String, _ shape: TriggerCaseShape,
        fillValues: [Int: String] = [:], clipboard: String = ""
    ) -> MacroExpansionResult {
        MacroRenderer.expand(content: content, fillValues: fillValues, clipboardText: clipboard, caseShape: shape)
    }

    func testTheShapesApplyToTemplateText() {
        XCTAssertEqual(render("best regards", .asWritten).text, "best regards")
        XCTAssertEqual(render("best regards", .firstUpper).text, "Best regards")
        XCTAssertEqual(render("best regards", .allUpper).text, "BEST REGARDS")
    }

    func testClipboardContentKeepsItsCase() {
        XCTAssertEqual(render("see {{clipboard}} now", .allUpper, clipboard: "mixed Case").text,
                       "SEE mixed Case NOW")
        XCTAssertEqual(render("{{clipboard}} rest", .firstUpper, clipboard: "abc").text, "abc rest",
                       "First Upper never reaches into a pasted value")
        XCTAssertEqual(render("%clipboard tail", .allUpper, clipboard: "x").text, "x TAIL")
    }

    func testFillInValuesKeepTheirCase() {
        let content = "dear %filltext:name=who%, thanks"
        XCTAssertEqual(render(content, .allUpper, fillValues: [0: "ada Lovelace"]).text,
                       "DEAR ada Lovelace, THANKS")
        XCTAssertEqual(render("%filltext:name=who% wrote", .firstUpper, fillValues: [0: "ada"]).text,
                       "ada wrote")
    }

    func testGeneratedValuesAndExplicitTransformsKeepTheirCase() {
        let id = render("id {{uuid:lower}}", .allUpper).text
        XCTAssertTrue(id.hasPrefix("ID "))
        XCTAssertEqual(String(id.dropFirst(3)), String(id.dropFirst(3)).lowercased())
        XCTAssertEqual(render("{{lower:ABC}} def", .allUpper).text, "abc DEF",
                       "An author's explicit transform outranks the typed trigger")
    }

    /// Uppercasing can lengthen text (ß → SS); the caret anchor must move with it.
    func testTheCursorFollowsALengthChangingShape() {
        let shaped = render("straße{{cursor}} end", .allUpper)
        XCTAssertEqual(shaped.text, "STRASSE END")
        XCTAssertEqual(shaped.cursorOffset, "STRASSE".utf16.count)
        XCTAssertEqual(render("straße{{cursor}} end", .asWritten).cursorOffset, "straße".utf16.count)
    }

    func testAstralOutputIsShapedWhole() {
        XCTAssertEqual(render("𐐨ab", .allUpper).text, "𐐀AB")
        XCTAssertEqual(render("𐐨ab", .firstUpper).text, "𐐀ab")
        let anchored = render("𐐨{{cursor}}b", .allUpper)
        XCTAssertEqual(anchored.text, "𐐀B")
        XCTAssertEqual(anchored.cursorOffset, 2, "UTF-16 offset past one surrogate pair")
    }

    func testAsWrittenIsTheIdentity() {
        let source = "Mixed {{clipboard}} %filltext:name=x% End"
        let plain = MacroRenderer.expand(content: source, fillValues: [0: "v"], clipboardText: "c")
        XCTAssertEqual(render(source, .asWritten, fillValues: [0: "v"], clipboard: "c"), plain)
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        SourceContractTests.strippingComments(try SourceTree.text(path))
    }

    /// The typed path renders twice when a fill-in panel intervenes; a shape that reached only
    /// the first pass would vanish exactly when the user filled a field in.
    func testTheTypedPathShapesBothRenderPasses() throws {
        let tap = try source("Sources/ExpanderEngine/Engine/EventTapEngine.swift")
        let body = try SourceTree.functionBody("func performDeferredExpand(", in: tap)
        XCTAssertEqual(body.components(separatedBy: "MacroRenderer.expand(").count - 1, 2)
        XCTAssertEqual(body.components(separatedBy: "caseShape: caseShape").count - 1, 2)
        XCTAssertTrue(tap.contains("caseShape: match.caseShape"), "The immediate expansion")
        XCTAssertTrue(tap.contains("caseShape: TriggerCaseShape.forExpansion(of: snippet, typedTrigger: trigger)"),
                      "The prefix-debounce fire")
    }

    func testTheEditorOffersTheToggleOnlyForCaseInsensitiveSnippets() throws {
        let editor = try source("Sources/DevTypeAppCore/SnippetEditorSheet.swift")
        XCTAssertEqual(editor.components(separatedBy: "propagateCaseChip.isHidden = caseChip.isOn").count - 1, 2,
                       "Hidden at build time and whenever Case Sensitive is toggled")
        XCTAssertTrue(editor.contains("snippet.propagateCase = !caseSensitive && propagateCaseChip.isOn"))
    }

    // MARK: - Persistence

    func testTheFlagRoundTripsThroughJSON() throws {
        let snippet = SnippetModel(title: "s", triggerKeyword: "sig", replacementText: "x", propagateCase: true)
        let data = try JSONEncoder().encode(snippet)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["propagateCase"] as? Bool, true)
        XCTAssertTrue(try JSONDecoder().decode(SnippetModel.self, from: data).propagateCase)
    }

    func testALibraryWrittenBeforeTheFlagDecodesItAsOff() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"s","triggerKeyword":"sig","replacementText":"x"}
        """
        XCTAssertFalse(try JSONDecoder().decode(SnippetModel.self, from: Data(legacy.utf8)).propagateCase)
    }

    func testEqualitySeesTheFlag() {
        let local = SnippetModel(title: "s", triggerKeyword: "sig", replacementText: "x")
        var incoming = local
        incoming.propagateCase = true
        XCTAssertNotEqual(local, incoming, "Hashable/Equatable must see the field")
    }

    // MARK: - Espanso

    private func importEspanso(_ yaml: String) throws -> EspansoImporter.ImportResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try yaml.write(to: root.appendingPathComponent("base.yml"), atomically: true, encoding: .utf8)
        return try EspansoImporter.importFrom(root)
    }

    /// Espanso's documented example: `alh` → although / Although / ALTHOUGH.
    func testAnImportedPropagateCaseMatchBehavesAsInEspanso() throws {
        let result = try importEspanso("""
        matches:
          - trigger: "alh"
            replace: "although"
            propagate_case: true
            word: true
        """)
        let snippet = try XCTUnwrap(result.groups.flatMap(\.snippets).first { $0.triggerKeyword == "alh" })
        XCTAssertTrue(snippet.propagateCase)
        XCTAssertFalse(snippet.isCaseSensitive, "propagate_case implies case-insensitive matching")
        XCTAssertEqual(result.uppercaseStyleNotAdaptedCount, 0)

        let matcher = AbbreviationMatcher(snippets: [snippet])
        for (typed, expected) in [("alh", "although"), ("Alh", "Although"), ("ALH", "ALTHOUGH")] {
            let found = try XCTUnwrap(matcher.match(buffer: "x \(typed) "), typed)
            let match = SnippetMatch(snippet: found.snippet, triggerLength: found.triggerLength,
                                     terminator: found.terminator, fieldText: found.matchedText)
            XCTAssertEqual(
                MacroRenderer.expand(content: snippet.replacementText, clipboardText: "",
                                     caseShape: match.caseShape).text,
                expected, typed
            )
        }
    }

    func testUnadaptedUppercaseStylesAreReportedNotHidden() throws {
        let result = try importEspanso("""
        matches:
          - trigger: ";ols"
            replace: "ordinary least squares"
            propagate_case: true
            uppercase_style: capitalize_words
          - trigger: ";a"
            replace: "alpha"
            propagate_case: true
            uppercase_style: capitalize
          - trigger: ";b"
            replace: "beta"
            propagate_case: true
            uppercase_style: uppercase
          - trigger: ";c"
            replace: "gamma"
        """)
        XCTAssertEqual(result.uppercaseStyleNotAdaptedCount, 2)
        let flags = Dictionary(uniqueKeysWithValues: result.groups.flatMap(\.snippets).map {
            ($0.triggerKeyword, $0.propagateCase)
        })
        XCTAssertEqual(flags, [";ols": true, ";a": true, ";b": true, ";c": false])
    }
}
