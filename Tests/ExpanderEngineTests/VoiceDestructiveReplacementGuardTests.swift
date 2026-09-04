import Foundation
import XCTest
@testable import ExpanderEngine

/// The last line of defence before dictation deletes the user's words.
///
/// Final delivery is allowed to replace what live typing put on screen, because a proofread
/// pass legitimately rewrites text behind the commit barrier. The hazard is that a transcript
/// which has *lost* most of the session is indistinguishable from a proofread at that call
/// site. In session `AC699E95-6F04-4593-B482-C645CA2727D1` that is precisely what happened:
/// 293 characters were on screen, the finished transcript carried 145, and delivery erased the
/// difference.
///
/// `UtteranceAccumulator` fixes the cause. This guard exists because the cause is not the only
/// thing that can produce a short transcript, and no future one may be allowed to do this.
final class VoiceDestructiveReplacementGuardTests: XCTestCase {

    private let policyCeiling = CorrectionPolicy.defaultMaxDeletionRatio

    // MARK: - The production failure

    func testRefusesTheReplacementThatDeletedTwoThirdsOfARealSession() {
        let owned = """
            Voice typing has been the most unreliable thing so badly use it Because it's bad \
            and it needs a major revert or completely re-architect how it done Even the speech \
            recognition is not that great do you think he's it because of the Apple foundational \
            models or do I need to use expensive models?
            """
        let replacement = """
            Even the speech recognition is not that great. Do you think it is because of the \
            Apple foundational models, or do I need to use expensive models?
            """

        XCTAssertFalse(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned,
                replacement: replacement,
                maxDeletionRatio: policyCeiling
            ),
            "A transcript missing two of three utterances must never replace the text on screen"
        )
    }

    // MARK: - What must still be allowed

    func testAllowsAnOrdinaryProofread() {
        let owned = "even the speech recognition is not that great do you think is it because of the apple models"
        let replacement = "Even the speech recognition is not that great. Do you think it is because of the Apple models?"

        XCTAssertTrue(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned,
                replacement: replacement,
                maxDeletionRatio: policyCeiling
            ),
            "Re-casing and punctuation are the whole point of the correction pass"
        )
    }

    func testAllowsDisfluencyRemovalInsideThePolicyCeiling() {
        let owned = "um so I was thinking uh maybe we could ship the release on Friday you know"
        let replacement = "So I was thinking maybe we could ship the release on Friday."

        XCTAssertTrue(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned,
                replacement: replacement,
                maxDeletionRatio: policyCeiling
            ),
            "Filler stripping is sanctioned by the same policy this guard reads"
        )
    }

    func testAllowsAnythingOnTextTooShortToJudge() {
        XCTAssertTrue(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: "Send it.",
                replacement: "Sent.",
                maxDeletionRatio: policyCeiling
            ),
            "A few words carry no signal, and a wrong refusal costs more than a wrong acceptance"
        )
    }

    // MARK: - The boundary

    func testTheCeilingIsTheCorrectionPolicysOwnDeletionLimit() {
        // 100 content characters in, exactly at the limit out.
        let owned = String(repeating: "a", count: 100)
        let atCeiling = String(repeating: "a", count: Int(100 * (1 - policyCeiling)))
        let belowCeiling = String(repeating: "a", count: Int(100 * (1 - policyCeiling)) - 1)

        XCTAssertTrue(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned, replacement: atCeiling, maxDeletionRatio: policyCeiling
            )
        )
        XCTAssertFalse(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned, replacement: belowCeiling, maxDeletionRatio: policyCeiling
            )
        )
    }

    func testAnEmptyTranscriptNeverReplacesDictatedText() {
        XCTAssertFalse(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: "This is a sentence the user actually dictated out loud.",
                replacement: "",
                maxDeletionRatio: policyCeiling
            ),
            "An empty transcript erasing the session is the worst case of all"
        )
    }

    func testAStricterPolicyRefusesMore() {
        let owned = "the quick brown fox jumps over the lazy dog and keeps running onward"
        let replacement = "The quick brown fox jumps over the lazy dog."

        XCTAssertTrue(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned, replacement: replacement, maxDeletionRatio: 0.40
            )
        )
        XCTAssertFalse(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned, replacement: replacement, maxDeletionRatio: 0.10
            ),
            "The guard must track the session's declared policy, not a hardcoded number"
        )
    }

    func testPunctuationAndWhitespaceAreNotEvidenceOfLostWords() {
        let owned = "one two three four five six seven eight nine ten eleven twelve"
        let heavilyPunctuated = "One, two, three — four; five: six. Seven, eight, nine... ten! Eleven? Twelve."

        XCTAssertTrue(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned, replacement: heavilyPunctuated, maxDeletionRatio: policyCeiling
            ),
            "Only letters and digits count; adding punctuation must never look like a loss"
        )
    }

    func testADegenerateRatioCannotDisableTheGuardEntirely() {
        let owned = "This is a genuine sentence that the user dictated aloud just now."

        // A policy value outside [0, 1] must clamp rather than invert the comparison.
        XCTAssertFalse(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned, replacement: "", maxDeletionRatio: -5
            )
        )
        XCTAssertTrue(
            VoiceInsertionService.replacementPreservesDictatedText(
                owned: owned, replacement: "", maxDeletionRatio: 99
            ),
            "A policy that permits total deletion is honoured, but only by clamping to 1.0"
        )
    }
}
