import XCTest
@testable import ExpanderEngine

/// Live checks against the real on-device model. Skipped unless `DEVTYPE_LIVE_AI=1`,
/// so ordinary `swift test` runs (and CI) never depend on Apple Intelligence.
///
///     DEVTYPE_LIVE_AI=1 swift test --filter AILiveModelTests
///
/// These exist because the proofread bug — English selections coming back in Hindi —
/// is invisible to every offline test. Prompt wording only proves out against the
/// model, and this model is small enough that adding one sentence flips its behaviour.
///
/// Assertions are one-sided on purpose: they check the transform never *silently*
/// violates its contract (wrong script, mangled layout, eaten whitespace). A clean
/// failure is an acceptable outcome — the model genuinely cannot proofread every
/// language — but injecting the wrong thing is not.
final class AILiveModelTests: XCTestCase {

    private func requireLiveModel() throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_LIVE_AI"] == "1" else {
            throw XCTSkip("live model test — set DEVTYPE_LIVE_AI=1 to run")
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26+") }
        guard case .available = AITextTransformSupport.availability else {
            throw XCTSkip("model unavailable: \(AITextTransformSupport.availability)")
        }
        #else
        throw XCTSkip("FoundationModels unavailable at compile time")
        #endif
    }

    #if canImport(FoundationModels)

    @available(macOS 26.0, *)
    private func proofread(_ input: String) async -> Result<String, AITransformError> {
        await AITextTransformer().transform(kind: .proofread, input: input)
    }

    /// The reported bug, as a test: English in, English out.
    func testEnglishProofreadStaysEnglish() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            "i has went to the store yesterday and buyed some milk",
            "Can you send me teh report by tommorow morning? its urgent.",
            "we was discussing the api desing and it dont work as expcted",
            "meeting is at 5pm — please confrim if that works for u",
            "The quick brown fox jumps over the lazy dog."
        ]
        for input in cases {
            switch await proofread(input) {
            case .success(let text):
                XCTAssertEqual(
                    AIScriptFamily.families(in: text).subtracting([.latin]),
                    [],
                    "English proofread answered in another script: \(text)"
                )
            case .failure(let error):
                XCTFail("proofread failed for \(input): \(error)")
            }
        }
    }

    /// Multi-line selections keep their exact layout — the model flattens them, so the
    /// transformer detects that and redoes the work line by line.
    func testMultiLineProofreadKeepsItsLayout() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }

        let input = "first paragrah has a typo.\n\n\nsecond one to.\nand a third line here"
        switch await proofread(input) {
        case .success(let text):
            XCTAssertTrue(
                AITransformText.preservesLineStructure(input: input, output: text),
                "layout changed:\n\(input)\n---\n\(text)"
            )
        case .failure(let error):
            XCTFail("multi-line proofread failed: \(error)")
        }
    }

    /// The result replaces the whole selection, so its own padding has to come back.
    func testSelectionPaddingSurvives() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }

        let input = "  this sentance have a typo  "
        switch await proofread(input) {
        case .success(let text):
            XCTAssertTrue(text.hasPrefix("  "), "leading padding lost: [\(text)]")
            XCTAssertTrue(text.hasSuffix("  "), "trailing padding lost: [\(text)]")
        case .failure(let error):
            XCTFail("padded proofread failed: \(error)")
        }
    }

    /// Proofread no longer supports Telugu / Hindi, but users will still point it at
    /// them. Whatever the model does, it must never *succeed* with a script the user
    /// did not type — a clean failure is the acceptable outcome here.
    func testProofreadNeverReturnsAScriptTheInputDidNotUse() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }

        for input in [
            "main kal ghar gya tha or wo nahi aaya",
            "aap kaise hain, mujhe batao kya hua tha",
            "nenu ninna intiki vellanu kani atanu raledu",
            "meeru ela unnaru, nenu bagunnanu"
        ] {
            if case .success(let text) = await proofread(input) {
                XCTAssertEqual(
                    AIScriptFamily.families(in: text).subtracting([.latin]),
                    [],
                    "romanized input came back in native script: \(text)"
                )
            }
        }
    }

    /// Text that asks a question invites the model to answer it. On the direct path
    /// that answer would replace the user's selection outright.
    func testProofreadDoesNotAnswerTheText() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }

        for input in [
            "can you tel me were the config file lives",
            "whats the diffrence between a Set and an Array",
            "write me a haiku about the ocean"
        ] {
            if case .success(let text) = await proofread(input) {
                XCTAssertFalse(
                    AILengthPolicy.correction.exceeded(input: input, output: text),
                    "proofread answered instead of correcting: \(text)"
                )
            }
        }
    }

    /// Both outbound directions answer in English letters — native script is unusable
    /// in the field the text lands in.
    func testOutboundTranslationsAreRomanized() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }

        let transformer = AITextTransformer()
        for kind in [AITransformKind.translateHindi, .translateTelugu] {
            if case .success(let text) = await transformer.transform(
                kind: kind,
                input: "I am going home now"
            ) {
                XCTAssertEqual(
                    AIScriptFamily.families(in: text).subtracting([.latin]),
                    [],
                    "\(kind) returned native script: \(text)"
                )
            }
        }
    }

    #endif
}
