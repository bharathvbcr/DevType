import XCTest
@testable import ExpanderEngine

/// End-to-end stress for progressive typing: a simulated recognizer drives
/// `LiveTranscriptAssembler` → `VoiceTranscriptReconciler` → a modelled document.
///
/// This is the path the pause bug lived on, so it is exercised against the ways a real
/// recognizer actually misbehaves: re-punctuating an utterance when it endpoints, revising
/// out of order, re-sending finals, finalizing empty, and interleaving all of that with the
/// user's own pre-existing text in the field.
///
/// The document is modelled explicitly — erase N, then type S — so an over-erase shows up
/// as real text loss rather than as bookkeeping that merely agrees with itself.
final class LiveTypingIntegrationStressTests: XCTestCase {

    /// Applies an edit the way the injector would, asserting it never reaches past what
    /// exists.
    private func apply(_ edit: VoiceReconciledEdit, to document: inout String) {
        XCTAssertLessThanOrEqual(
            edit.eraseCount, document.count,
            "Erase of \(edit.eraseCount) exceeds the document (\(document.count))"
        )
        document.removeLast(min(edit.eraseCount, document.count))
        document += edit.textToInject
    }

    /// One dictation: feed segments, apply every edit, and return the final document.
    private func runSession(
        segments: [SpeechSegment],
        preexisting: String = "",
        assertInvariant: (String) -> Void = { _ in }
    ) -> (document: String, owned: String) {
        var assembler = LiveTranscriptAssembler()
        let reconciler = VoiceTranscriptReconciler()
        var document = preexisting

        for segment in segments {
            guard assembler.ingest(segment) else { continue }
            let edit = reconciler.reconcile(target: assembler.cumulativeText)
            apply(edit, to: &document)

            if segment.finality == .final {
                reconciler.commitBoundary()
            }

            XCTAssertEqual(
                document, preexisting + reconciler.ownedText,
                "Document drifted from what the reconciler believes it owns"
            )
            assertInvariant(document)
        }

        return (document, reconciler.ownedText)
    }

    /// Builds the segment stream for one utterance the way `LiveSpeechStream` does:
    /// lowercase unpunctuated partials, then a finalized form with case and punctuation.
    private func utterance(index: Int, words: [String], finalized: String) -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        for count in 1...words.count {
            segments.append(SpeechSegment(
                segmentID: "live-\(index)",
                revision: UInt64(count),
                text: words.prefix(count).joined(separator: " "),
                finality: .volatile
            ))
        }
        segments.append(SpeechSegment(
            segmentID: "live-\(index)",
            revision: UInt64(words.count + 1),
            text: finalized,
            finality: .final
        ))
        return segments
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 1. The reported bug, end to end
    // ═══════════════════════════════════════════════════════════════

    func testPauseNeverReplacesEarlierText() {
        let segments =
            utterance(index: 0, words: ["hello", "world", "this", "is", "a", "test"],
                      finalized: "Hello, world. This is a test.")
            + utterance(index: 1, words: ["and", "here", "is", "more"],
                        finalized: "And here is more.")
            + utterance(index: 2, words: ["finally", "we", "are", "done"],
                        finalized: "Finally, we are done.")

        var sawFirstUtterance = false
        let result = runSession(segments: segments) { document in
            if document.contains("Hello, world.") { sawFirstUtterance = true }
            if sawFirstUtterance {
                XCTAssertTrue(
                    document.contains("Hello, world."),
                    "The first utterance disappeared after a pause: \(document)"
                )
            }
        }

        XCTAssertTrue(result.document.contains("Hello, world."))
        XCTAssertTrue(result.document.contains("And here is more."))
        XCTAssertTrue(result.document.contains("Finally, we are done."))
    }

    func testPreexistingDocumentTextIsNeverTouched() {
        let preexisting = "The user already wrote this. "
        let segments = (0..<8).flatMap { index in
            utterance(index: index,
                      words: ["sentence", "number", "\(index)"],
                      finalized: "Sentence number \(index).")
        }

        let result = runSession(segments: segments, preexisting: preexisting) { document in
            XCTAssertTrue(
                document.hasPrefix(preexisting),
                "Dictation ate the user's own text: \(document)"
            )
        }
        XCTAssertTrue(result.document.hasPrefix(preexisting))
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 2. Recognizer misbehaviour
    // ═══════════════════════════════════════════════════════════════

    /// A finalized segment re-sent verbatim must be a no-op, not a second copy.
    func testDuplicateFinalSegmentIsNotAppendedTwice() {
        let final = SpeechSegment(segmentID: "live-0", revision: 9, text: "Hello there.", finality: .final)
        let result = runSession(segments: [
            SpeechSegment(segmentID: "live-0", revision: 1, text: "hello", finality: .volatile),
            final, final, final,
        ])

        XCTAssertEqual(result.document, "Hello there.")
    }

    /// A stray volatile update arriving after the segment finalized must be ignored — the
    /// text is settled and the user has seen it.
    func testVolatileAfterFinalIsIgnored() {
        let result = runSession(segments: [
            SpeechSegment(segmentID: "live-0", revision: 1, text: "hello", finality: .volatile),
            SpeechSegment(segmentID: "live-0", revision: 2, text: "Hello.", finality: .final),
            SpeechSegment(segmentID: "live-0", revision: 3, text: "hell", finality: .volatile),
        ])
        XCTAssertEqual(result.document, "Hello.")
    }

    func testOutOfOrderRevisionsNeverRegress() {
        let result = runSession(segments: [
            SpeechSegment(segmentID: "live-0", revision: 1, text: "one", finality: .volatile),
            SpeechSegment(segmentID: "live-0", revision: 5, text: "one two three", finality: .volatile),
            SpeechSegment(segmentID: "live-0", revision: 2, text: "one two", finality: .volatile),
        ])
        XCTAssertEqual(result.document, "one two three")
    }

    /// Silence at an endpoint finalizes an empty utterance. It must not create a gap, and
    /// — the part the rendered text cannot show — it must not consume a segment slot.
    /// A long quiet dictation endpoints repeatedly on silence, so recording those would
    /// exhaust `maxSegments` with nothing to show for it.
    func testEmptyFinalSegmentsCreateNoGapsAndConsumeNoBudget() {
        let result = runSession(segments: [
            SpeechSegment(segmentID: "live-0", revision: 1, text: "First.", finality: .final),
            SpeechSegment(segmentID: "live-1", revision: 1, text: "", finality: .final),
            SpeechSegment(segmentID: "live-2", revision: 1, text: "   ", finality: .final),
            SpeechSegment(segmentID: "live-3", revision: 1, text: "Second.", finality: .final),
        ])
        XCTAssertEqual(result.document, "First. Second.")
        XCTAssertFalse(result.document.contains("  "), "Empty utterance produced a double space")

        var assembler = LiveTranscriptAssembler()
        for segment in [
            SpeechSegment(segmentID: "live-0", revision: 1, text: "First.", finality: .final),
            SpeechSegment(segmentID: "live-1", revision: 1, text: "", finality: .final),
            SpeechSegment(segmentID: "live-2", revision: 1, text: "   ", finality: .final),
            SpeechSegment(segmentID: "live-3", revision: 1, text: "Second.", finality: .final),
        ] {
            _ = assembler.ingest(segment)
        }
        XCTAssertEqual(
            assembler.segmentCount, 2,
            "Silent endpoints consumed segment budget"
        )
    }

    /// Sustained silence must not exhaust the segment bound.
    func testProlongedSilenceDoesNotExhaustTheSegmentBound() {
        var assembler = LiveTranscriptAssembler()
        for index in 0..<(LiveTranscriptAssembler.maxSegments * 2) {
            _ = assembler.ingest(SpeechSegment(
                segmentID: "live-\(index)", revision: 1, text: "", finality: .final
            ))
        }
        XCTAssertEqual(assembler.segmentCount, 0)

        // Real speech afterwards still lands.
        XCTAssertTrue(assembler.ingest(SpeechSegment(
            segmentID: "live-final", revision: 1, text: "Spoken at last.", finality: .final
        )))
        XCTAssertEqual(assembler.cumulativeText, "Spoken at last.")
    }

    /// The recognizer sometimes shortens an in-flight utterance as its acoustic model
    /// revises. Only the volatile tail may shrink.
    func testShrinkingVolatileTailOnlyErasesTheTail() {
        let result = runSession(segments: [
            SpeechSegment(segmentID: "live-0", revision: 1, text: "Committed.", finality: .final),
            SpeechSegment(segmentID: "live-1", revision: 1, text: "this is a long guess", finality: .volatile),
            SpeechSegment(segmentID: "live-1", revision: 2, text: "this is", finality: .volatile),
        ])
        XCTAssertEqual(result.document, "Committed. this is")
        XCTAssertTrue(result.document.hasPrefix("Committed."))
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 3. Randomised full-session fuzz
    // ═══════════════════════════════════════════════════════════════

    /// 300 randomised sessions. Every recognizer behaviour above is mixed in at random,
    /// against a document that already contains the user's text.
    func testRandomisedSessionsPreserveCommittedText() {
        let vocabulary = ["deploy", "parser", "roadmap", "latency", "kubectl", "review", "cache"]

        for seed in UInt64(1)...300 {
            var rng = SplitMix64(seed: seed)
            var assembler = LiveTranscriptAssembler()
            let reconciler = VoiceTranscriptReconciler()

            let preexisting = "USER TEXT. "
            var document = preexisting
            var sealed = ""

            let utteranceCount = Int(rng.next() % 5) + 1
            for index in 0..<utteranceCount {
                let wordCount = Int(rng.next() % 5) + 1
                let words = (0..<wordCount).map { _ in vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }

                var revision: UInt64 = 0
                for count in 1...wordCount {
                    revision += 1
                    let segment = SpeechSegment(
                        segmentID: "live-\(index)",
                        revision: revision,
                        text: words.prefix(count).joined(separator: " "),
                        finality: .volatile
                    )
                    if assembler.ingest(segment) {
                        apply(reconciler.reconcile(target: assembler.cumulativeText), to: &document)
                    }

                    // Occasionally replay an older revision.
                    if rng.next() % 4 == 0, revision > 1 {
                        let stale = SpeechSegment(
                            segmentID: "live-\(index)",
                            revision: revision - 1,
                            text: "STALE SHOULD NOT APPEAR",
                            finality: .volatile
                        )
                        if assembler.ingest(stale) {
                            apply(reconciler.reconcile(target: assembler.cumulativeText), to: &document)
                        }
                    }

                    XCTAssertTrue(
                        document.hasPrefix(preexisting + sealed),
                        "seed \(seed): a volatile update erased text behind the commit barrier"
                    )
                }

                // Endpoint: re-cased and punctuated, sometimes re-sent.
                revision += 1
                var finalized = words.joined(separator: " ")
                finalized = finalized.prefix(1).uppercased() + finalized.dropFirst() + "."
                let finalSegment = SpeechSegment(
                    segmentID: "live-\(index)", revision: revision, text: finalized, finality: .final
                )

                let repeats = Int(rng.next() % 3) + 1
                for _ in 0..<repeats where assembler.ingest(finalSegment) {
                    apply(reconciler.reconcile(target: assembler.cumulativeText), to: &document)
                }
                reconciler.commitBoundary()
                sealed = reconciler.committedText

                XCTAssertTrue(
                    document.hasPrefix(preexisting + sealed),
                    "seed \(seed): finalization destroyed committed text"
                )
                XCTAssertFalse(
                    document.contains("STALE SHOULD NOT APPEAR"),
                    "seed \(seed): a stale revision reached the document"
                )
                XCTAssertEqual(
                    document, preexisting + reconciler.ownedText,
                    "seed \(seed): document drifted from reconciler state"
                )
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 4. Final delivery reconciles against live text
    // ═══════════════════════════════════════════════════════════════

    /// After live typing, the corrected transcript is delivered. It must edit what is on
    /// screen, never retype the whole thing on top of it.
    func testFinalDeliveryDoesNotDuplicateLiveText() {
        var assembler = LiveTranscriptAssembler()
        let reconciler = VoiceTranscriptReconciler()
        var document = ""

        for segment in utterance(index: 0, words: ["deploy", "the", "gateway"],
                                 finalized: "Deploy the gateway.") {
            guard assembler.ingest(segment) else { continue }
            apply(reconciler.reconcile(target: assembler.cumulativeText), to: &document)
            if segment.finality == .final { reconciler.commitBoundary() }
        }
        XCTAssertEqual(document, "Deploy the gateway.")

        // The corrected transcript agrees with what was typed — nothing to do.
        let identical = reconciler.reconcile(target: "Deploy the gateway.")
        XCTAssertTrue(identical.isNoop, "Identical final transcript must be a no-op")

        // A cleanup that rewrites committed text is absorbed, not replayed destructively.
        let rewritten = reconciler.reconcile(target: "Deploy the API gateway.")
        apply(rewritten, to: &document)
        XCTAssertEqual(document, "Deploy the gateway.",
            "A revision of committed text must not rewrite the document")
        XCTAssertTrue(rewritten.suppressedCommittedRevision)
    }

    /// Cancelling erases exactly what dictation owns, and nothing of the user's text.
    func testCancelRollbackLeavesPreexistingTextIntact() {
        var assembler = LiveTranscriptAssembler()
        let reconciler = VoiceTranscriptReconciler()
        let preexisting = "Keep me. "
        var document = preexisting

        for segment in utterance(index: 0, words: ["draft", "text", "here"],
                                 finalized: "Draft text here.") {
            guard assembler.ingest(segment) else { continue }
            apply(reconciler.reconcile(target: assembler.cumulativeText), to: &document)
            if segment.finality == .final { reconciler.commitBoundary() }
        }
        XCTAssertTrue(document.count > preexisting.count)

        apply(reconciler.rollbackAll(), to: &document)
        XCTAssertEqual(document, preexisting, "Rollback removed the user's own text")
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 5. Assembler bounds
    // ═══════════════════════════════════════════════════════════════

    func testAssemblerIsBounded() {
        var assembler = LiveTranscriptAssembler()
        for index in 0..<(LiveTranscriptAssembler.maxSegments + 100) {
            _ = assembler.ingest(SpeechSegment(
                segmentID: "live-\(index)", revision: 1, text: "word", finality: .final
            ))
        }
        XCTAssertEqual(assembler.segmentCount, LiveTranscriptAssembler.maxSegments)
    }

    func testResetClearsEverything() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.ingest(SpeechSegment(segmentID: "live-0", text: "hello", finality: .final))
        XCTAssertFalse(assembler.cumulativeText.isEmpty)

        assembler.reset()
        XCTAssertTrue(assembler.cumulativeText.isEmpty)
        XCTAssertEqual(assembler.segmentCount, 0)
    }
}
