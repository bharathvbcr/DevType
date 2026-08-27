import XCTest
@testable import ExpanderEngine

final class VoiceAITriggerParserTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        VoicePreferences.resetAllForTesting()
    }

    func testPrefixWithSpokenPayload() {
        let command1 = VoiceAITriggerParser.parse(transcript: "rewrite: please make this concise")
        XCTAssertNotNil(command1)
        XCTAssertEqual(command1?.kind, .rewrite)
        XCTAssertEqual(command1?.payloadText, "please make this concise")
        XCTAssertFalse(command1?.requiresSelectionFallback ?? true)

        let command2 = VoiceAITriggerParser.parse(transcript: "rephrase: say hello in a friendly way")
        XCTAssertNotNil(command2)
        XCTAssertEqual(command2?.kind, .paraphrase)
        XCTAssertEqual(command2?.payloadText, "say hello in a friendly way")

        let command3 = VoiceAITriggerParser.parse(transcript: "ai expand: add three bullet points")
        XCTAssertNotNil(command3)
        XCTAssertEqual(command3?.kind, .expand)
        XCTAssertEqual(command3?.payloadText, "add three bullet points")

        let command4 = VoiceAITriggerParser.parse(transcript: "prompt enhance: create a rest api in swift")
        XCTAssertNotNil(command4)
        XCTAssertEqual(command4?.kind, .promptEnhance)
        XCTAssertEqual(command4?.payloadText, "create a rest api in swift")
    }

    func testDeveloperAITriggers() {
        let cmdCode = VoiceAITriggerParser.parse(transcript: "explain code: let total = items.reduce(0, +)")
        XCTAssertNotNil(cmdCode)
        XCTAssertEqual(cmdCode?.kind, .explainCode)
        XCTAssertEqual(cmdCode?.payloadText, "let total = items.reduce(0, +)")

        let cmdDoc = VoiceAITriggerParser.parse(transcript: "docstring: func processPayment(amount: Double) -> Bool")
        XCTAssertNotNil(cmdDoc)
        XCTAssertEqual(cmdDoc?.kind, .generateDocstring)

        let cmdFix = VoiceAITriggerParser.parse(transcript: "fix bug: array[index] causes crash when empty")
        XCTAssertNotNil(cmdFix)
        XCTAssertEqual(cmdFix?.kind, .fixCode)

        let cmdJson = VoiceAITriggerParser.parse(transcript: "to json: title: DevType, version: 1.0")
        XCTAssertNotNil(cmdJson)
        XCTAssertEqual(cmdJson?.kind, .toJson)

        let cmdTests = VoiceAITriggerParser.parse(transcript: "unit tests: func add(a: Int, b: Int) -> Int")
        XCTAssertNotNil(cmdTests)
        XCTAssertEqual(cmdTests?.kind, .generateUnitTests)

        let cmdCommit = VoiceAITriggerParser.parse(transcript: "git commit: added voice ai triggers and developer tools")
        XCTAssertNotNil(cmdCommit)
        XCTAssertEqual(cmdCommit?.kind, .gitCommitMessage)

        let cmdRegex = VoiceAITriggerParser.parse(transcript: "explain regex: ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$")
        XCTAssertNotNil(cmdRegex)
        XCTAssertEqual(cmdRegex?.kind, .explainRegex)

        let cmdSql = VoiceAITriggerParser.parse(transcript: "sql query: find all active users registered last week")
        XCTAssertNotNil(cmdSql)
        XCTAssertEqual(cmdSql?.kind, .sqlQuery)
    }

    func testSelectionFallbackTrigger() {
        let cmd1 = VoiceAITriggerParser.parse(transcript: "rephrase")
        XCTAssertNotNil(cmd1)
        XCTAssertEqual(cmd1?.kind, .paraphrase)
        XCTAssertTrue(cmd1?.requiresSelectionFallback ?? false)
        XCTAssertEqual(cmd1?.payloadText, "")

        let cmd2 = VoiceAITriggerParser.parse(transcript: "explain code")
        XCTAssertNotNil(cmd2)
        XCTAssertEqual(cmd2?.kind, .explainCode)
        XCTAssertTrue(cmd2?.requiresSelectionFallback ?? false)

        let cmd3 = VoiceAITriggerParser.parse(transcript: "prompt enhance this")
        XCTAssertNotNil(cmd3)
        XCTAssertEqual(cmd3?.kind, .promptEnhance)
        XCTAssertTrue(cmd3?.requiresSelectionFallback ?? false)
    }

    func testCustomTriggers() {
        let custom = ["polish": "proofread", "summarize": "condense"]
        let cmd = VoiceAITriggerParser.parse(transcript: "polish: here is some draft", customTriggers: custom)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.kind, .proofread)
        XCTAssertEqual(cmd?.payloadText, "here is some draft")
    }

    func testNonTriggerSpeechReturnsNil() {
        let cmd = VoiceAITriggerParser.parse(transcript: "Good morning team, let us review the sprint.")
        XCTAssertNil(cmd)
    }

    func testMacOS27RequirementConstants() {
        XCTAssertTrue(AITextTransformSupport.macOSRequirementDisclaimer.contains("macOS 27"))
        XCTAssertTrue(AITextTransformSupport.macOSRequirementDisclaimer.contains("macOS 26"))
    }
}
