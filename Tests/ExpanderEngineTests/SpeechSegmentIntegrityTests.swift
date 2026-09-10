import XCTest
@testable import ExpanderEngine

final class SpeechSegmentIntegrityTests: XCTestCase {
    private func receive(_ segment: SpeechSegment, live: Bool, state: inout VoiceSessionState) throws -> [VoiceSessionCommand] {
        try VoiceSessionReducer.reduce(
            state: &state, event: live ? .liveSegmentReceived(segment) : .speechSegmentReceived(segment),
            eventGeneration: state.snapshot.generation
        ).get()
    }

    func testLiveAndBatchRejectStaleConflictingAndDowngradedRevisions() throws {
        for live in [false, true] {
            for finality: Finality in [.volatile, .final] {
                let accepted = SpeechSegment(segmentID: "phrase", revision: 9, text: "accepted words", finality: finality)
                var state = VoiceSessionState(snapshot: VoiceFixtures.snapshot(), phase: live ? .capturing(mode: .hold) : .recognizing)
                _ = try receive(accepted, live: live, state: &state)
                var rejected = [accepted,
                    SpeechSegment(segmentID: "phrase", revision: 8, text: "older", finality: finality),
                    SpeechSegment(segmentID: "phrase", revision: 9, text: "conflicting replay", finality: finality)]
                if finality == .final {
                    rejected.append(SpeechSegment(segmentID: "phrase", revision: 10, text: "downgrade", finality: .volatile))
                }
                for segment in rejected {
                    XCTAssertEqual(try receive(segment, live: live, state: &state), [])
                    XCTAssertEqual(state.segments, [accepted])
                }
            }
        }
    }

    func testSameRevisionFinalPromotionRemainsSupported() throws {
        for live in [false, true] {
            var state = VoiceSessionState(snapshot: VoiceFixtures.snapshot(), phase: live ? .capturing(mode: .hold) : .recognizing)
            _ = try receive(SpeechSegment(segmentID: "phrase", text: "hello"), live: live, state: &state)
            let final = SpeechSegment(segmentID: "phrase", text: "Hello.", finality: .final)
            _ = try receive(final, live: live, state: &state)
            XCTAssertEqual(state.segments, [final])
        }
    }

    func testAssemblerRejectsConflictingEqualRevision() {
        var assembler = LiveTranscriptAssembler()
        XCTAssertTrue(assembler.ingest(SpeechSegment(segmentID: "phrase", revision: 2, text: "keep")))
        let before = assembler
        XCTAssertFalse(assembler.ingest(SpeechSegment(segmentID: "phrase", revision: 2, text: "replace")))
        XCTAssertEqual(assembler, before)
    }

    func testAssemblerOverflowDoesNotMutateCommitBarrier() {
        var assembler = LiveTranscriptAssembler()
        for index in 0..<LiveTranscriptAssembler.maxSegments {
            XCTAssertTrue(assembler.ingest(SpeechSegment(segmentID: "\(index)", text: "word \(index)")))
        }
        let before = assembler
        XCTAssertFalse(assembler.ingest(SpeechSegment(segmentID: "overflow", text: "extra")))
        XCTAssertEqual(assembler, before)
        XCTAssertFalse(assembler.lastSegmentWasFinal)
    }

    func testEmptyFinalThatSealsPriorWordsReportsTheBarrierChange() {
        var assembler = LiveTranscriptAssembler()
        XCTAssertTrue(assembler.ingest(SpeechSegment(segmentID: "first", text: "spoken words")))
        XCTAssertTrue(assembler.ingest(SpeechSegment(segmentID: "silence", text: "", finality: .final)))
        XCTAssertEqual(assembler.settledText, "spoken words")
        XCTAssertEqual(assembler.segmentCount, 1)
    }

    func testProviderPayloadOverflowFailsSessionBeforeRetentionOrDelivery() throws {
        for live in [false, true] {
            var state = VoiceSessionState(snapshot: VoiceFixtures.snapshot(), phase: live ? .capturing(mode: .hold) : .recognizing)
            let commands = try receive(SpeechSegment(segmentID: "large", text: String(repeating: "x", count: 131_073)), live: live, state: &state)
            XCTAssertTrue(state.segments.isEmpty)
            XCTAssertEqual(state.failure?.code, .speechProtocolViolation)
            XCTAssertTrue(commands.contains(.cleanupResources))
            XCTAssertFalse(commands.contains { if case .applyLiveSegment = $0 { return true }; return false })
        }
    }

    func testBatchCompletionChecksEveryAcceptedSegmentBeyondLivePreviewLimit() {
        let segments = (0..<600).map {
            SpeechSegment(segmentID: "\($0)", text: "utterance \($0)", finality: .final)
        }
        let completion = SpeechCompletion(rawTranscript: VoiceFixtures.rawTranscript("utterance 599"),
                                          finalSegmentCount: 600, totalDurationSeconds: 600)
        let repaired = VoiceSessionReducer.reconcileCompletion(completion, against: segments)
        XCTAssertEqual(repaired.text, segments.map(\.text).joined(separator: " "))
        XCTAssertTrue(repaired.text.hasSuffix("utterance 599"))
    }

    func testFailedDeliveryEvidenceCannotBecomeInsertedOutcome() throws {
        for quality: DeliveryEvidenceQuality in [.failed, .cancelled, .timedOut, .permissionDenied,
                                                  .secureInputRefused, .targetMismatch, .clipboardOnly] {
            let snapshot = VoiceFixtures.snapshot()
            var state = VoiceSessionState(snapshot: snapshot, phase: .readyForDelivery)
            let receipt = DeliveryReceipt(sessionID: snapshot.sessionID, generation: snapshot.generation,
                                          targetLease: snapshot.targetLease, deliveredTextLength: 0,
                                          evidenceQuality: quality)
            let commands = try VoiceSessionReducer.reduce(state: &state, event: .deliveryCompleted(receipt),
                                                          eventGeneration: snapshot.generation).get()
            guard case .completed(.savedButNotInserted) = state.phase else {
                XCTFail("Non-delivery became insertion: \(quality)")
                continue
            }
            XCTAssertTrue(commands.contains(.persistReceipt(receipt)))
            XCTAssertTrue(commands.contains(.cleanupResources))
        }
    }

    func testMalformedProviderMetadataAndAlternativesAreRejectedAtomically() throws {
        let invalid = [
            SpeechSegment(segmentID: "", text: "words"),
            SpeechSegment(segmentID: String(repeating: "x", count: 257), text: "words"),
            SpeechSegment(segmentID: "time", startSeconds: .nan, text: "words"),
            SpeechSegment(segmentID: "time", durationSeconds: .infinity, text: "words"),
            SpeechSegment(segmentID: "time", durationSeconds: -1, text: "words"),
            SpeechSegment(segmentID: "confidence", text: "words", confidence: .nan),
            SpeechSegment(segmentID: "confidence", text: "words", confidence: 1.01),
            SpeechSegment(segmentID: "alternatives", text: "words", alternatives: Array(repeating: SpeechAlternative(text: "alt"), count: 33)),
            SpeechSegment(segmentID: "alternatives", text: "words", alternatives: [SpeechAlternative(text: String(repeating: "x", count: 131_072))])
        ]
        for segment in invalid {
            var state = VoiceSessionState(snapshot: VoiceFixtures.snapshot(), phase: .recognizing)
            let commands = try receive(segment, live: false, state: &state)
            XCTAssertEqual(state.failure?.code, .speechProtocolViolation)
            XCTAssertTrue(state.segments.isEmpty)
            XCTAssertTrue(commands.contains(.cleanupResources))
            var assembler = LiveTranscriptAssembler()
            XCTAssertFalse(assembler.ingest(segment))
            XCTAssertEqual(assembler.segmentCount, 0)
        }
    }

    func testAggregatePayloadBudgetCountsRetainedAlternativesAndIDs() throws {
        var state = VoiceSessionState(snapshot: VoiceFixtures.snapshot(), phase: .recognizing)
        for index in 0..<7 {
            _ = try receive(SpeechSegment(segmentID: "\(index)", text: "words", alternatives: [
                SpeechAlternative(text: String(repeating: "x", count: 131_067))
            ]), live: false, state: &state)
        }
        XCTAssertNil(state.failure)
        let before = state.segments
        let commands = try receive(SpeechSegment(segmentID: "overflow", text: String(repeating: "x", count: 131_072)),
                                   live: false, state: &state)
        XCTAssertEqual(state.segments, before)
        XCTAssertEqual(state.failure?.code, .speechProtocolViolation)
        XCTAssertTrue(commands.contains(.cleanupResources))
    }

    func testCountBudgetAllowsRevisionsButRefusesANewSegmentWithoutTruncation() throws {
        for live in [false, true] {
            let limit = live ? LiveTranscriptAssembler.maxSegments : SpeechSegment.maximumSegments
            var state = VoiceSessionState(snapshot: VoiceFixtures.snapshot(), phase: live ? .capturing(mode: .hold) : .recognizing,
                                          segments: (0..<limit).map { SpeechSegment(segmentID: "\($0)", text: "word") })
            _ = try receive(SpeechSegment(segmentID: "0", revision: 2, text: "revised"), live: live, state: &state)
            XCTAssertNil(state.failure)
            XCTAssertEqual(state.segments[0].text, "revised")
            _ = try receive(SpeechSegment(segmentID: "overflow", text: "word"), live: live, state: &state)
            XCTAssertEqual(state.failure?.code, .speechProtocolViolation)
            XCTAssertEqual(state.segments.count, limit)
        }
    }

    func testOversizedCompletionIsRejectedBeforeReconciliationAndPersistence() throws {
        var state = VoiceSessionState(snapshot: VoiceFixtures.snapshot(), phase: .recognizing)
        let completion = SpeechCompletion(rawTranscript: VoiceFixtures.rawTranscript(String(repeating: "x", count: 1_048_577)),
                                          finalSegmentCount: 1, totalDurationSeconds: 1)
        let commands = try VoiceSessionReducer.reduce(state: &state, event: .speechCompleted(completion),
                                                       eventGeneration: state.snapshot.generation).get()
        XCTAssertEqual(state.failure?.code, .speechProtocolViolation)
        XCTAssertTrue(state.rawTranscript == nil, "Oversized transcript must not be retained")
        XCTAssertFalse(commands.contains { if case .persistRaw = $0 { return true }; return false })
    }
}
