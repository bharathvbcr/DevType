import XCTest
@testable import ExpanderEngine

/// Adversarial suite that models how `SFSpeechRecognizer` actually behaves at an
/// endpoint (pause): the finalized transcription for an utterance is re-cased and
/// re-punctuated relative to the partials that preceded it.
///
/// The pre-fix `VoiceProgressiveTypingEngine.computeDiff` is prefix-only (LCP), so a
/// single changed character at offset 0 forces `eraseCount == currentInjectedText.count`
/// — the entire session transcript is backspaced away and retyped. That is the
/// user-visible "pausing replaces my earlier text" defect.
///
/// Every test here asserts the *invariant we require*, not the behaviour we have.
final class VoicePrefixStabilityDisruptionTests: XCTestCase {

    // MARK: - D1. Endpoint re-punctuation must not wipe the session

    /// The production path: the same recognizer behaviour routed through the reconciler
    /// must not erase the utterance.
    func testEndpointRepunctuationDoesNotEraseWholeTranscript() {
        let reconciler = VoiceTranscriptReconciler()
        let live = "hello world this is a test of dictation"
        let finalized = "Hello, world. This is a test of dictation."

        _ = reconciler.reconcile(target: live)
        reconciler.commitBoundary()

        let edit = reconciler.reconcile(target: finalized)
        _ = live

        XCTAssertLessThan(
            edit.eraseCount, live.count,
            "Endpoint re-punctuation erased all \(live.count) live characters — the whole utterance was replaced."
        )
        XCTAssertEqual(edit.eraseCount, 0, "Committed text is immutable; the revision must be absorbed")
        XCTAssertEqual(edit.resultingText, live, "On-screen text must be preserved verbatim")
        XCTAssertTrue(edit.suppressedCommittedRevision)
    }

    // MARK: - D2. A committed utterance is immutable across a pause

    func testCommittedUtteranceSurvivesHeadRecasingAcrossPause() {
        let reconciler = VoiceTranscriptReconciler()

        _ = reconciler.reconcile(target: "We are discussing the roadmap")
        reconciler.commitBoundary(finalizedText: "We are discussing the roadmap.")

        // After the pause the recognizer emits the cumulative text with a re-cased head.
        let edit = reconciler.reconcile(target: "we are discussing the roadmap. Next week we deploy")

        XCTAssertEqual(edit.eraseCount, 0, "A cosmetic revision of committed text must never erase it")
        XCTAssertTrue(
            edit.resultingText.hasPrefix("We are discussing the roadmap."),
            "Committed text must remain an exact prefix; got \(edit.resultingText)"
        )
        XCTAssertEqual(edit.textToInject, " Next week we deploy")
    }

    // MARK: - D3. Hard bound: erase can never reach behind the commit barrier

    func testEraseIsAlwaysBoundedByVolatileTail() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "The first sentence is already typed.")
        reconciler.commitBoundary(finalizedText: "The first sentence is already typed.")

        _ = reconciler.reconcile(target: "The first sentence is already typed. and a tail")
        let volatileLength = reconciler.volatileText.count

        // A wildly divergent target must still not be allowed to eat committed text.
        let edit = reconciler.reconcile(target: "Completely unrelated recognizer output")

        XCTAssertLessThanOrEqual(
            edit.eraseCount, volatileLength,
            "eraseCount \(edit.eraseCount) exceeded the volatile tail (\(volatileLength)) — committed text was destroyed"
        )
        XCTAssertTrue(edit.resultingText.hasPrefix("The first sentence is already typed."))
    }

    // MARK: - D4. Final cleaned transcript must not blind-backspace the session

    func testFinalCleanupOfCommittedTextIsNotReplayedDestructively() {
        let reconciler = VoiceTranscriptReconciler()
        let live = "um so I need to fix the parser bug today"
        _ = reconciler.reconcile(target: live)
        reconciler.commitBoundary(finalizedText: live)

        // SmartDictationEngine strips the leading filler and repunctuates.
        let edit = reconciler.reconcile(target: "I need to fix the parser bug today.")

        XCTAssertEqual(edit.eraseCount, 0, "Cleanup of already-committed text must not backspace it")
        XCTAssertTrue(edit.suppressedCommittedRevision, "The suppressed revision must be reported, not silently dropped")
    }

    // MARK: - D5. Legitimate tail revision inside the live utterance still works

    func testVolatileTailRevisionStillAppliesMinimally() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "Hello world there")
        let edit = reconciler.reconcile(target: "Hello world here")

        XCTAssertEqual(edit.eraseCount, 5)
        XCTAssertEqual(edit.textToInject, "here")
        XCTAssertEqual(edit.resultingText, "Hello world here")
    }

    // MARK: - D6. Idempotence — replaying the same target is a no-op

    func testReconcileIsIdempotent() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "Stable text")
        let repeated = reconciler.reconcile(target: "Stable text")

        XCTAssertEqual(repeated.eraseCount, 0)
        XCTAssertTrue(repeated.textToInject.isEmpty)
    }

    // MARK: - D7. Monotonic growth across many pauses never erases

    func testManyPausesNeverEraseAnything() {
        let reconciler = VoiceTranscriptReconciler()
        var committed: [String] = []

        for i in 1...25 {
            let utterance = "Sentence number \(i) spoken aloud"
            let cumulative = VoiceTranscriptReconciler.combineUtterances(
                committed: committed,
                activePartial: utterance
            )
            let edit = reconciler.reconcile(target: cumulative)
            XCTAssertEqual(edit.eraseCount, 0, "Pause \(i) erased \(edit.eraseCount) committed characters")

            // Endpoint finalization re-cases and punctuates the utterance.
            let finalized = "Sentence number \(i) spoken aloud."
            let finalCumulative = VoiceTranscriptReconciler.combineUtterances(
                committed: committed,
                activePartial: finalized
            )
            let finalEdit = reconciler.reconcile(target: finalCumulative)
            XCTAssertLessThanOrEqual(
                finalEdit.eraseCount, utterance.count,
                "Finalizing utterance \(i) reached behind the current utterance"
            )
            reconciler.commitBoundary(finalizedText: finalCumulative)
            committed.append(finalized)
        }

        XCTAssertTrue(reconciler.committedText.hasPrefix("Sentence number 1 spoken aloud."))
    }

    // MARK: - D8. Grapheme safety — erase counts are in Characters, never scalars

    func testGraphemeClusterErasesAreCharacterCounted() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "Ship it 👨‍👩‍👧‍👦 now")
        let edit = reconciler.reconcile(target: "Ship it 👨‍👩‍👧‍👦 later")

        XCTAssertEqual(edit.eraseCount, 3, "Family emoji must count as one Character, not many scalars")
        XCTAssertEqual(edit.resultingText, "Ship it 👨‍👩‍👧‍👦 later")
    }

    // MARK: - D9. Cancellation only rolls back what dictation owns

    func testRollbackOnlyErasesOwnedText() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "Draft text that will be cancelled")
        let rollback = reconciler.rollbackAll()

        XCTAssertEqual(rollback.eraseCount, "Draft text that will be cancelled".count)
        XCTAssertTrue(rollback.textToInject.isEmpty)
        XCTAssertTrue(reconciler.ownedText.isEmpty)
    }

    // MARK: - D10. Monotonic append never erases (ported from VoiceStreamingDiffTests)

    func testMonotonicAppendHasZeroErase() {
        let reconciler = VoiceTranscriptReconciler()

        let step1 = reconciler.reconcile(target: "Hello")
        XCTAssertEqual(step1.eraseCount, 0)
        XCTAssertEqual(step1.textToInject, "Hello")

        let step2 = reconciler.reconcile(target: "Hello world")
        XCTAssertEqual(step2.eraseCount, 0)
        XCTAssertEqual(step2.textToInject, " world")

        let step3 = reconciler.reconcile(target: "Hello world, how are you?")
        XCTAssertEqual(step3.eraseCount, 0)
        XCTAssertEqual(step3.textToInject, ", how are you?")
        XCTAssertEqual(step3.resultingText, "Hello world, how are you?")
    }

    // MARK: - D11. Utterance assembly formatting (ported from VoiceStreamingDiffTests)

    func testUtteranceCombinationFormatting() {
        XCTAssertEqual(
            VoiceTranscriptReconciler.combineUtterances(
                committed: ["Hello world", "How are you"], activePartial: "I am fine"),
            "Hello world How are you I am fine"
        )
        XCTAssertEqual(
            VoiceTranscriptReconciler.combineUtterances(
                committed: ["First sentence.", "Second sentence."], activePartial: "Third sentence."),
            "First sentence. Second sentence. Third sentence."
        )
        XCTAssertEqual(
            VoiceTranscriptReconciler.combineUtterances(committed: [], activePartial: "Only partial"),
            "Only partial"
        )
        XCTAssertEqual(
            VoiceTranscriptReconciler.combineUtterances(
                committed: ["First.", "Second."], activePartial: ""),
            "First. Second."
        )
    }
}
