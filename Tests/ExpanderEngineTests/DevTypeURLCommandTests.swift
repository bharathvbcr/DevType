import XCTest
@testable import ExpanderEngine

final class DevTypeURLCommandTests: XCTestCase {

    func testEachAllowlistedAction() {
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?title=Hello&trigger=%3Bhi&text=Body"),
            .command(.newSnippet(title: "Hello", trigger: ";hi", text: "Body"))
        )
        XCTAssertEqual(DevTypeURLParser.parse("devtype://palette"), .command(.palette))
        XCTAssertEqual(
            DevTypeURLParser.parse("DEVTYPE://Preferences?tab=Voice"),
            .command(.preferences(tab: .voice))
        )
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://preferences"),
            .command(.preferences(tab: nil))
        )
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://dictation/toggle"),
            .command(.toggleDictation)
        )
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://copy?trigger=%3Bsig"),
            .command(.copy(trigger: ";sig"))
        )
    }

    func testUnknownActionAndForeignHost() {
        XCTAssertEqual(DevTypeURLParser.parse("devtype://expand"), .failure(.unknownAction))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://expand?text=hi"), .failure(.unknownAction))
        XCTAssertEqual(DevTypeURLParser.parse("https://example.com/palette"), .failure(.foreignHost))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://evil.example/new"), .failure(.foreignHost))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://not.an.action"), .failure(.foreignHost))
    }

    func testUnknownPreferencesTabOpensTheDefaultSection() {
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://preferences?tab=nope"),
            .command(.preferences(tab: nil))
        )
    }

    func testMalformedShapes() {
        XCTAssertEqual(DevTypeURLParser.parse("devtype://dictation"), .failure(.malformed))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://dictation/toggle/now"), .failure(.malformed))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://palette/extra"), .failure(.malformed))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://copy"), .failure(.malformed))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://copy?trigger="), .failure(.malformed))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://user@palette"), .failure(.malformed))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://palette:9"), .failure(.malformed))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://"), .failure(.malformed))
    }

    func testUnknownQueryKeysAreIgnored() {
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://palette?unused=1"),
            .command(.palette)
        )
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?text=hi&extra=no"),
            .command(.newSnippet(title: "", trigger: "", text: "hi"))
        )
    }

    func testPercentDecodingHappensOnce() {
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?text=hello%2520world"),
            .command(.newSnippet(title: "", trigger: "", text: "hello%20world"))
        )
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?text=hello%20world"),
            .command(.newSnippet(title: "", trigger: "", text: "hello world"))
        )
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?text=a+b"),
            .command(.newSnippet(title: "", trigger: "", text: "a+b"))
        )
        // application(_:open:) parses URL.absoluteString, not the caller's raw spelling.
        let raw = "devtype://new?text=hello%2520world"
        guard let opened = URL(string: raw)?.absoluteString else {
            return XCTFail("URL(string:) rejected the double-encoded sample")
        }
        XCTAssertEqual(
            DevTypeURLParser.parse(opened),
            .command(.newSnippet(title: "", trigger: "", text: "hello%20world"))
        )
    }

    func testTrailingSlashAndPathCaseStayOnTheAllowlist() {
        XCTAssertEqual(DevTypeURLParser.parse("devtype://palette/"), .command(.palette))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://dictation/toggle/"), .command(.toggleDictation))
        XCTAssertEqual(DevTypeURLParser.parse("devtype://dictation/Toggle"), .command(.toggleDictation))
    }

    func testNewURLDraftIsCaseSensitiveAndNotASecret() {
        let draft = DevTypeURLCommand.editorDraft(title: "ZqSecretName9", trigger: ";hi", text: "body")
        XCTAssertEqual(draft.title, "ZqSecretName9")
        XCTAssertEqual(draft.triggerKeyword, ";hi")
        XCTAssertEqual(draft.replacementText, "body")
        XCTAssertEqual(draft.isCaseSensitive, true)
        XCTAssertEqual(draft.isSecret, false)
    }

    func testOversizedFieldsAndTheRawCap() {
        let limits = SnippetImporter.SnippetImportLimits.self
        let exactText = String(repeating: "a", count: limits.maxReplacementCharacters)
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?text=\(exactText)"),
            .command(.newSnippet(title: "", trigger: "", text: exactText))
        )
        let hugeText = String(repeating: "b", count: limits.maxReplacementCharacters + 1)
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?text=\(hugeText)"),
            .failure(.oversized)
        )

        let exactTrigger = String(repeating: "t", count: limits.maxTriggerCharacters)
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://copy?trigger=\(exactTrigger)"),
            .command(.copy(trigger: exactTrigger))
        )
        let hugeTrigger = String(repeating: "t", count: limits.maxTriggerCharacters + 1)
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?trigger=\(hugeTrigger)"),
            .failure(.oversized)
        )
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://new?title=\(hugeTrigger)"),
            .failure(.oversized)
        )

        let exactTab = String(repeating: "p", count: DevTypeURLParser.maxPreferencesTabCharacters)
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://preferences?tab=\(exactTab)"),
            .command(.preferences(tab: nil))
        )
        let hugeTab = String(repeating: "p", count: DevTypeURLParser.maxPreferencesTabCharacters + 1)
        XCTAssertEqual(
            DevTypeURLParser.parse("devtype://preferences?tab=\(hugeTab)"),
            .failure(.oversized)
        )

        let raw = String(repeating: "z", count: DevTypeURLParser.maxRawURLCharacters + 1)
        XCTAssertEqual(DevTypeURLParser.parse(raw), .failure(.oversized))
    }

    func testCopyRefusesASecretWithoutPuttingItsNameInTheLog() {
        let secret = SnippetModel(
            title: "ZqSecretName9",
            triggerKeyword: "ZqSecretTrigger9",
            replacementText: "must-not-be-read",
            enabled: false,
            isSecret: true
        )
        XCTAssertEqual(
            DevTypeURLCopy.decide(trigger: "ZqSecretTrigger9", in: [secret]),
            .refusedSecret
        )
        let line = DevTypeURLCopyAudit.line(result: .refusedSecret, originBundleIdentifier: "com.example.sender")
        XCTAssertEqual(line, "action=copy result=refused-secret origin=com.example.sender")
        XCTAssertFalse(line.contains(secret.title))
        XCTAssertFalse(line.contains(secret.triggerKeyword))
        XCTAssertFalse(line.contains("must-not-be-read"))
    }

    func testCopyDecisionCases() {
        let plain = SnippetModel(title: "Hello", triggerKeyword: ";hi", replacementText: "there")
        let other = SnippetModel(title: "Other", triggerKeyword: ";hi", replacementText: "else")
        let solo = SnippetModel(title: "Solo", triggerKeyword: ";solo", replacementText: "one")
        let emptyTrigger = SnippetModel(title: "Blank", triggerKeyword: "", replacementText: "nope")

        XCTAssertEqual(DevTypeURLCopy.decide(trigger: ";solo", in: [solo, emptyTrigger]), .confirm(solo))
        XCTAssertEqual(DevTypeURLCopy.decide(trigger: ";missing", in: [plain]), .notFound)
        XCTAssertEqual(DevTypeURLCopy.decide(trigger: ";hi", in: [plain, other]), .ambiguous)
        XCTAssertEqual(DevTypeURLCopy.decide(trigger: "", in: [emptyTrigger]), .notFound)

        // Schema 3 secrets have no trigger. An empty trigger must not copy one, and the
        // secret's title is not a trigger either.
        let adapter = SecretModel(title: "ZqSecretName9").snippetAdapter
        XCTAssertTrue(adapter.isSecret)
        XCTAssertEqual(adapter.triggerKeyword, "")
        XCTAssertEqual(adapter.replacementText, "")
        XCTAssertEqual(DevTypeURLCopy.decide(trigger: "ZqSecretName9", in: [adapter]), .notFound)
        XCTAssertEqual(DevTypeURLCopy.decide(trigger: "", in: [adapter]), .notFound)

        let secret = SnippetModel(
            title: "ZqSecretName9",
            triggerKeyword: ";hi",
            replacementText: "",
            isSecret: true
        )
        XCTAssertEqual(DevTypeURLCopy.decide(trigger: ";hi", in: [plain, secret]), .refusedSecret)

        let confirmed = DevTypeURLCopyAudit.line(result: .needsConfirm, originBundleIdentifier: "com.apple.shortcuts")
        XCTAssertEqual(confirmed, "action=copy result=needs-confirm origin=com.apple.shortcuts")
        XCTAssertFalse(confirmed.contains(";hi"))
        XCTAssertFalse(confirmed.contains("Hello"))
    }
}
