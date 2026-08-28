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
            let stripped = TranscriptionValidationGate.stripArtifacts(input)
            XCTAssertEqual(stripped, exp)
        }
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
            let verdict = TranscriptionValidationGate.validate(raw: raw, cleaned: cleaned)
            XCTAssertTrue(verdict.accepted, "Short utterance '\(raw)' should be accepted: \(verdict.reason ?? "")")
        }
    }

    func testAdversarialHallucinationsAndAnswerDivergence() {
        let testCases = [
            // Question answering hallucination
            (raw: "What is the capital of Japan?", cleaned: "Tokyo is the capital of Japan and has a population of over 13 million."),
            // Complete rewrite / conversation drift
            (raw: "Please write a test", cleaned: "Here is a test: func testExample() { XCTAssert(true) }"),
            // Out of bounds length explosion
            (raw: "Hello world", cleaned: "Hello world this is an AI model generating lots and lots of extra redundant words.")
        ]

        for testCase in testCases {
            let verdict = TranscriptionValidationGate.validate(raw: testCase.raw, cleaned: testCase.cleaned)
            XCTAssertFalse(verdict.accepted, "Hallucination should be rejected: raw='\(testCase.raw)', cleaned='\(testCase.cleaned)'")
        }
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
        let wavData = VoiceAudioRecorder.createWavData(fromPCM: pcmData, sampleRate: 48000, channels: 2, bitsPerSample: 16)
        try wavData.write(to: wavURL)

        // Encode 48kHz stereo WAV to 16kHz mono FLAC using dynamic converter
        let result = try FLACEncoder.encode(inputURL: wavURL, outputURL: flacURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flacURL.path))
        XCTAssertGreaterThan(result.byteCount, 0)
    }

    // MARK: - 4. State Machine Concurrent Burst Fuzzing

    func testStateMachineMassiveConcurrentFuzzing() {
        let allEvents: [DictationEvent] = [
            .hotkeyDown,
            .hotkeyUp,
            .lockIn,
            .cancel,
            .encodingComplete(URL(fileURLWithPath: "/tmp/a.flac")),
            .transcriptReady("Test transcript"),
            .insertionComplete(.inserted),
            .error(.network("fuzz error")),
            .error(.timeout),
            .error(.auth)
        ]

        DispatchQueue.concurrentPerform(iterations: 50) { iteration in
            var state: DictationState = .idle
            for step in 0..<100 {
                let event = allEvents[(iteration * 31 + step * 7) % allEvents.count]
                state = DictationStateMachine.transition(state, on: event)
            }
            // Must end in a valid defined state without crashing
            XCTAssertNotNil(state)
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
                apiKey: "dummy-key"
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
                apiKey: "dummy-key"
            )
            XCTFail("Expected emptyTranscript error")
        } catch let error as GeminiTranscriptionError {
            XCTAssertEqual(error, .emptyTranscript)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
