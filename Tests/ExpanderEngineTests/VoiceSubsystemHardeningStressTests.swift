import XCTest
@testable import ExpanderEngine
import AVFoundation

final class VoiceSubsystemHardeningStressTests: XCTestCase {

    // MARK: - 1. Adversarial Validation Gate & Reasoning Tag Fuzzing

    func testReasoningTagsAndPreambleStripping() {
        let inputsWithReasoning = [
            "<think>\nLet's format this dictation properly.\n</think>Let's meet at 2:00 PM tomorrow.",
            "<thought>Preserving camelCase</thought>userControllerProfile",
            "[think]Thinking about grammar[/think]Thank you for your assistance.",
            "```swift\nlet x = 42\n```",
            "CLEAN: Ship the update tonight.",
            "Transcript: \"Let's review the PR.\""
        ]

        let expected = [
            "Let's meet at 2:00 PM tomorrow.",
            "userControllerProfile",
            "Thank you for your assistance.",
            "let x = 42",
            "Ship the update tonight.",
            "Let's review the PR."
        ]

        for (input, exp) in zip(inputsWithReasoning, expected) {
            let stripped = CorrectionOutputSanitizer.sanitize(input)
            XCTAssertEqual(stripped, exp)
        }
    }

    /// Ported from the retired `TranscriptionValidationGate` onto `CorrectionValidator`,
    /// which is the gate that actually runs in the correction pipeline.
    private func outcome(raw: String, cleaned: String) -> ValidationOutcome {
        let rawTranscript = RawTranscript(
            text: raw, localeIdentifier: "en_US", providerID: "test", modelVersion: "1"
        )
        let candidate = CorrectionCandidate(
            text: cleaned, providerID: "test", modelVersion: "1"
        )
        return CorrectionValidator.validate(
            candidate: candidate,
            raw: rawTranscript,
            policy: CorrectionPolicy(),
            protectedSpans: ProtectedSpanExtractor.extract(from: raw)
        )
    }

    private func isAccepted(_ outcome: ValidationOutcome) -> Bool {
        if case .accepted = outcome { return true }
        return false
    }

    func testShortUtteranceFastPath() {
        let shortPairs = [
            ("yes", "Yes."),
            ("no", "No."),
            ("ok", "OK."),
            ("sure", "Sure."),
            ("cancel that", "Cancel that.")
        ]

        for (raw, cleaned) in shortPairs {
            XCTAssertTrue(
                isAccepted(outcome(raw: raw, cleaned: cleaned)),
                "Short utterance '\(raw)' should be accepted"
            )
        }
    }

    func testAdversarialHallucinationsAndAnswerDivergence() {
        let testCases = [
            // The model answered the dictation instead of cleaning it.
            (raw: "What is the capital of Japan?",
             cleaned: "Tokyo is the capital of Japan and has a population of over 13 million."),
            // Complete rewrite / conversation drift.
            (raw: "Please write a test",
             cleaned: "Here is a test: func testExample() { XCTAssert(true) }"),
            // Length explosion.
            (raw: "Hello world",
             cleaned: "Hello world this is an AI model generating lots and lots of extra redundant words."),
        ]

        for testCase in testCases {
            XCTAssertFalse(
                isAccepted(outcome(raw: testCase.raw, cleaned: testCase.cleaned)),
                "Hallucination should be rejected: raw='\(testCase.raw)', cleaned='\(testCase.cleaned)'"
            )
        }
    }

    func testLegitimateCleanupIsStillAccepted() {
        XCTAssertTrue(isAccepted(outcome(
            raw: "um lets meet at 2 pm tomorrow to discuss the project",
            cleaned: "Let's meet at 2 PM tomorrow to discuss the project."
        )))
    }

    // MARK: - 2. Punctuation-Agnostic Transcript Diff Fuzzing

    func testPunctuationAgnosticLCSDiff() {
        // Model adds punctuation to words: "meet", "tomorrow." -> should match verbatim "meet", "tomorrow"
        let verbatim = "umm let's meet at 2pm tomorrow"
        let cleaned = "Let's meet at 2:00 PM tomorrow."

        let segments = TranscriptDiffEngine.segments(verbatim: verbatim, cleaned: cleaned)
        XCTAssertFalse(segments.isEmpty)

        // The filler "umm" must be marked as cut
        let cutSegment = segments.first { $0.isCut }
        XCTAssertNotNil(cutSegment)
        XCTAssertEqual(cutSegment?.text, "umm")
    }

    func testTranscriptDiffFuzzing() {
        for length in [1, 5, 20, 100] {
            let words = (0..<length).map { "word\($0)" }
            let verbatim = words.joined(separator: " ")
            let cleaned = words.filter { Int($0.dropFirst(4))! % 2 == 0 }.joined(separator: ", ")

            let segments = TranscriptDiffEngine.segments(verbatim: verbatim, cleaned: cleaned)
            XCTAssertFalse(segments.isEmpty)
        }
    }

    // MARK: - 3. FLAC Encoder Boundary & Conversion Hardening

    func testFLACEncoderZeroLengthAudioThrows() {
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("test_empty_\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertThrowsError(
            try FLACEncoder.encode(pcmData: Data(), sampleRate: 16000.0, outputURL: outputURL)
        )
    }

    func testFLACEncoderNonStandardSampleRateConversion() throws {
        // Create 48kHz Stereo PCM data
        let sampleRate: Double = 48000.0
        let durationSeconds: Double = 0.05
        let sampleCount = Int(sampleRate * durationSeconds) * 2 // Stereo = 2 channels
        var pcmData = Data(capacity: sampleCount * 2)

        for i in 0..<sampleCount {
            let sample = Int16((sin(Double(i)) * 20000.0))
            pcmData.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }

        let tempDir = FileManager.default.temporaryDirectory
        let wavURL = tempDir.appendingPathComponent("test_48k_\(UUID().uuidString).wav")
        let flacURL = tempDir.appendingPathComponent("test_48k_\(UUID().uuidString).flac")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: flacURL)
        }

        // Write as 48kHz stereo WAV file
        let wavData = WavTestData.createWavData(fromPCM: pcmData, sampleRate: 48000, channels: 2, bitsPerSample: 16)
        try wavData.write(to: wavURL)

        // Encode 48kHz stereo WAV to 16kHz mono FLAC using dynamic converter
        let result = try FLACEncoder.encode(inputURL: wavURL, outputURL: flacURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flacURL.path))
        XCTAssertGreaterThan(result.byteCount, 0)
    }

    // MARK: - 4. Session Reducer Concurrent Burst Fuzzing

    /// Ported from the deleted `DictationStateMachine` onto `VoiceSessionReducer`.
    ///
    /// Hammers the reducer with out-of-order events from many threads. The reducer is a
    /// pure function over `inout` state, so each worker owns its own state value; what is
    /// being checked is that no event sequence can drive it into an undefined phase, and
    /// that terminal phases stay terminal.
    func testSessionReducerMassiveConcurrentFuzzing() {
        let artifact = AudioArtifact(
            fileURL: URL(fileURLWithPath: "/tmp/fuzz.caf"),
            format: "caf",
            sampleRate: 16000,
            channelCount: 1,
            frameCount: 1000,
            durationSeconds: 1.0,
            byteCount: 2000,
            sha256Hex: "deadbeef",
            gapCount: 0
        )
        let raw = RawTranscript(
            text: "fuzz transcript",
            localeIdentifier: "en-US",
            providerID: "test",
            modelVersion: "1"
        )
        let allEvents: [VoiceSessionEvent] = [
            .startCapture(mode: .hold),
            .lockInHandsFree,
            .liveSegmentReceived(SpeechSegment(segmentID: "live-0", text: "hello", finality: .volatile)),
            .liveSegmentReceived(SpeechSegment(segmentID: "live-0", text: "Hello.", finality: .final)),
            .stopCapture,
            .audioFinalized(artifact),
            .speechSegmentReceived(SpeechSegment(segmentID: "s0", text: "seg", finality: .final)),
            .speechCompleted(SpeechCompletion(rawTranscript: raw, finalSegmentCount: 1, totalDurationSeconds: 1)),
            .rawValidationPassed(raw),
            .targetLeaseInvalidated(reason: "fuzz"),
            .cancel,
            .failureOccurred(VoiceFailure(stage: .recognition, code: .requestTimeout))
        ]

        DispatchQueue.concurrentPerform(iterations: 50) { iteration in
            let generation = SessionGeneration(rawValue: 1)
            let snapshot = VoiceSessionSnapshot(
                generation: generation,
                speechProvider: SpeechProviderDescriptor(
                    id: "test", displayName: "Test", modelVersion: "1",
                    privacyRoute: .onDeviceOnly, supportsStreaming: true,
                    supportsContextualStrings: false
                ),
                correctionProvider: CorrectionProviderDescriptor(
                    id: "deterministic.none", displayName: "None", modelVersion: "1",
                    privacyRoute: .onDeviceOnly, supportsStructuredOutput: false
                ),
                privacyRoute: .onDeviceOnly,
                targetLease: TargetLease(bundleIdentifier: "com.test", processIdentifier: 1)
            )
            var state = VoiceSessionState(snapshot: snapshot, phase: .preparing)

            for step in 0..<100 {
                let event = allEvents[(iteration * 31 + step * 7) % allEvents.count]
                let wasTerminal = Self.isTerminal(state.phase)
                let before = state.phase

                _ = VoiceSessionReducer.reduce(state: &state, event: event, eventGeneration: generation)

                if wasTerminal {
                    XCTAssertEqual(
                        state.phase, before,
                        "A terminal phase must never be reopened by a later event"
                    )
                }
            }
        }
    }

    private static func isTerminal(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    // MARK: - 5. Gemini Client Payload Limits & Security

    func testGeminiClientRejectsOversizedPayloads() async {
        let client = GeminiTranscriptionClient()
        // Create 26MB of dummy data (> 25MB limit)
        let oversizedData = Data(repeating: 0x41, count: 26 * 1024 * 1024)

        do {
            _ = try await client.transcribe(
                audioData: oversizedData,
                mimeType: "audio/flac",
                audioDurationSeconds: 10.0,
                steeringPrompt: "Test",
                apiKey: "dummy-key",
                uploadAuthorized: { true }
            )
            XCTFail("Expected payloadTooLarge error")
        } catch let error as GeminiTranscriptionError {
            XCTAssertEqual(error, .payloadTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGeminiClientRejectsEmptyPayload() async {
        let client = GeminiTranscriptionClient()
        do {
            _ = try await client.transcribe(
                audioData: Data(),
                mimeType: "audio/flac",
                audioDurationSeconds: 1.0,
                steeringPrompt: "Test",
                apiKey: "dummy-key",
                uploadAuthorized: { true }
            )
            XCTFail("Expected emptyTranscript error")
        } catch let error as GeminiTranscriptionError {
            XCTAssertEqual(error, .emptyTranscript)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
