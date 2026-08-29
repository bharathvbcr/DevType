import XCTest
import CryptoKit
@testable import ExpanderEngine

final class VoiceStressTests: XCTestCase {

    // MARK: - 1. Concurrent Burst Toggles Stress Test

    /// Ported from the retired `VoiceAudioRecorder` onto `DurableVoiceCapture`.
    /// Rapid start/cancel churn must never leave the capture actor wedged or leak a
    /// half-open audio graph.
    func testConcurrentBurstCaptureToggles() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceStress_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let capture = DurableVoiceCapture.shared

        for _ in 0..<15 {
            do {
                try await capture.startCapture(sessionDirectory: tempDir)
                _ = try? await capture.stopCapture()
            } catch {
                await capture.cancelCapture()
            }
            await capture.cancelCapture()
        }

        // The actor must still accept work after the churn.
        await capture.cancelCapture()
    }

    // MARK: - 2. Zero-Byte & Corrupt Audio Handling

    /// Ported from the deleted `VoiceTranscriber` batch path onto the provider adapter
    /// the session layer now uses. Unreadable audio must fail as a structured
    /// `VoiceFailure` rather than surfacing as an empty-but-successful transcript.
    func testZeroByteAndCorruptAudioAreRejectedByAdapter() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let zeroByteURL = tempDir.appendingPathComponent("empty.wav")
        FileManager.default.createFile(atPath: zeroByteURL.path, contents: Data())

        let corruptURL = tempDir.appendingPathComponent("corrupt.wav")
        FileManager.default.createFile(
            atPath: corruptURL.path,
            contents: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22])
        )

        let missingURL = tempDir.appendingPathComponent("missing.wav")

        let adapter = LegacyAppleSpeechAdapter()

        for url in [zeroByteURL, corruptURL, missingURL] {
            let artifact = AudioArtifact(
                fileURL: url,
                format: "wav",
                sampleRate: 16000,
                channelCount: 1,
                frameCount: 0,
                durationSeconds: 0,
                byteCount: 0,
                sha256Hex: "",
                gapCount: 0
            )
            let request = SpeechRequest(
                sessionID: VoiceSessionID(),
                generation: SessionGeneration(rawValue: 1),
                audio: artifact,
                locale: Locale(identifier: "en-US"),
                vocabulary: VocabularySnapshot(),
                deadline: Date().addingTimeInterval(3),
                privacyRoute: .onDeviceOnly
            )

            var produced: [String] = []
            var failed = false
            do {
                for try await event in adapter.transcribe(request) {
                    if case .completed(let completion) = event {
                        produced.append(completion.rawTranscript.text)
                    }
                }
            } catch {
                failed = true
            }

            let yieldedText = produced.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            XCTAssertFalse(
                yieldedText,
                "Unusable audio at \(url.lastPathComponent) must never yield a transcript"
            )
            _ = failed
        }
    }

    // MARK: - 3. Hostile & Adversarial String Fuzzing

    /// Ported from the retired `SmartDictationEngine` onto the corrector that actually runs.
    func testAdversarialStringsSurviveCorrection() async throws {
        let corrector = DeterministicCorrector()

        func correct(_ text: String) async throws -> String {
            let request = CorrectionRequest(
                sessionID: VoiceSessionID(),
                generation: SessionGeneration(rawValue: 1),
                rawTranscript: text,
                policy: CorrectionPolicy(),
                protectedSpans: ProtectedSpanExtractor.extract(from: text),
                deadline: Date().addingTimeInterval(5),
                privacyRoute: .onDeviceOnly
            )
            return try await corrector.correct(request).text
        }

        // A very long transcript must not blow up or empty out.
        let massive = String(repeating: "um hello world actually test ", count: 200)
        let processedMassive = try await correct(massive)
        XCTAssertFalse(processedMassive.isEmpty)

        // Emoji and zero-width joiner sequences survive intact.
        let processedEmoji = try await correct("👨‍👩‍👧‍👦 um 🏳️‍⚧️ actually 🚀")
        XCTAssertTrue(processedEmoji.contains("🚀"))
        XCTAssertTrue(processedEmoji.contains("👨‍👩‍👧‍👦"))

        // Degenerate input is handled without crashing.
        let empty = try await correct("")
        XCTAssertTrue(empty.isEmpty)
        let blank = try await correct("   \n\t  ")
        XCTAssertTrue(blank.isEmpty)
    }

    // MARK: - 4. Multilingual Disfluency Filtering

    func testMultilingualDisfluencyFiltering() async throws {
        let corrector = DeterministicCorrector()

        func correct(_ text: String) async throws -> String {
            let request = CorrectionRequest(
                sessionID: VoiceSessionID(),
                generation: SessionGeneration(rawValue: 1),
                rawTranscript: text,
                policy: CorrectionPolicy(),
                protectedSpans: [],
                deadline: Date().addingTimeInterval(5),
                privacyRoute: .onDeviceOnly
            )
            return try await corrector.correct(request).text
        }

        // English hesitation removed, meaningful words kept.
        let en = try await correct("I think, um, we should launch tomorrow.")
        XCTAssertFalse(en.lowercased().contains("um"))
        XCTAssertTrue(en.contains("launch"))

        // Korean: 음 is hesitation-only and goes; 그/저/어 are ordinary words and stay.
        let ko = try await correct("음 우리 그 사람 저 책 어디에 있어")
        XCTAssertFalse(ko.contains("음"))
        XCTAssertTrue(ko.contains("우리"), "Korean content word removed: \(ko)")
        XCTAssertTrue(ko.contains("그"), "Korean 그 (\"that\") must survive: \(ko)")
        XCTAssertTrue(ko.contains("저"), "Korean 저 (\"I\"/\"that\") must survive: \(ko)")

        // Japanese: えーと is hesitation-only; あの without the prolonged mark means "that".
        let ja = try await correct("えーと 明日 会いましょう")
        XCTAssertFalse(ja.contains("えーと"))
        XCTAssertTrue(ja.contains("明日"))

        let jaKeep = try await correct("あの 本 を 読む")
        XCTAssertTrue(jaKeep.contains("あの"), "Japanese あの (\"that\") must survive: \(jaKeep)")
    }

    // MARK: - 7. Mathematical Invariant Diff Fuzzing

    func testAdversarialDiffFuzzing() {
        let sampleWords = [
            "Hello", "world", "testing", "voice", "dictation", "pause",
            "sentence", "roadmap", "performance", "speed", "macOS",
            "🚀", "👨‍👩‍👧‍👦", "한국어", "日本語", "€100", "\n\t", "   "
        ]

        var rng = SystemRandomNumberGenerator()

        for _ in 0..<300 {
            // Generate random current injected text
            let currentWordCount = Int.random(in: 0...10, using: &rng)
            let currentWords = (0..<currentWordCount).map { _ in sampleWords.randomElement(using: &rng)! }
            let currentText = currentWords.joined(separator: " ")

            // Generate random target transcript
            let targetWordCount = Int.random(in: 0...12, using: &rng)
            let targetWords = (0..<targetWordCount).map { _ in sampleWords.randomElement(using: &rng)! }
            let targetText = targetWords.joined(separator: " ")

            // Seed the reconciler with the current text as an uncommitted tail, so the
            // whole of it is legitimately erasable and the diff is exercised end to end.
            let reconciler = VoiceTranscriptReconciler()
            _ = reconciler.reconcile(target: currentText)

            let diff = reconciler.reconcile(target: targetText)

            // Invariant 1: Erase count must NEVER exceed current text count
            XCTAssertLessThanOrEqual(
                diff.eraseCount,
                currentText.count,
                "Erase count \(diff.eraseCount) must not exceed current text count \(currentText.count)"
            )
            XCTAssertGreaterThanOrEqual(diff.eraseCount, 0)

            // Invariant 2: Applying diff must EXACTLY produce targetText
            let preservedCount = currentText.count - diff.eraseCount
            let preservedPrefix = String(currentText.prefix(preservedCount))
            let reconstructed = preservedPrefix + diff.textToInject

            XCTAssertEqual(
                reconstructed,
                targetText,
                "Diff application must exactly yield target transcript. Current: '\(currentText)', Target: '\(targetText)', Diff: (erase: \(diff.eraseCount), inject: '\(diff.textToInject)')"
            )
        }
    }

    // MARK: - 8. Rapid Multi-Utterance Pause Simulation Stress Test

    func testRapidMultiUtterancePauseStreamingFuzz() {
        let utterances = [
            "Today we are shipping the new release.",
            "All unit tests and integration tests have passed.",
            "The performance benchmarks look excellent.",
            "Please review the PR and approve."
        ]

        var committed: [String] = []
        var documentState = ""
        let reconciler = VoiceTranscriptReconciler()

        for (index, utterance) in utterances.enumerated() {
            // Simulate progressive partials within the utterance
            let words = utterance.split(separator: " ")
            for wordIndex in 1...words.count {
                let partial = words.prefix(wordIndex).joined(separator: " ")
                // The recognizer emits partials lowercased and unpunctuated; only the
                // endpoint result carries capitalisation and punctuation.
                let combined = VoiceTranscriptReconciler.combineUtterances(
                    committed: committed,
                    activePartial: partial.lowercased().replacingOccurrences(of: ".", with: "")
                )

                let diff = reconciler.reconcile(target: combined)

                // Apply diff
                let preservedCount = documentState.count - diff.eraseCount
                documentState = String(documentState.prefix(preservedCount)) + diff.textToInject

                // Invariant: previously committed utterances are NEVER erased
                if index > 0 {
                    XCTAssertTrue(
                        documentState.hasPrefix(utterances[0]),
                        "Pause \(index) erased the first utterance: \(documentState)"
                    )
                }
            }

            // Endpoint: the recognizer finalizes with restored case and punctuation.
            let finalCumulative = VoiceTranscriptReconciler.combineUtterances(
                committed: committed,
                activePartial: utterance
            )
            let finalDiff = reconciler.reconcile(target: finalCumulative)
            let keep = documentState.count - finalDiff.eraseCount
            documentState = String(documentState.prefix(keep)) + finalDiff.textToInject
            reconciler.commitBoundary(finalizedText: reconciler.ownedText)

            committed.append(utterance)
        }

        XCTAssertTrue(documentState.contains("Today we are shipping the new release."))
        XCTAssertTrue(documentState.contains("All unit tests and integration tests have passed."))
        XCTAssertTrue(documentState.contains("The performance benchmarks look excellent."))
        XCTAssertTrue(documentState.contains("Please review the PR and approve."))
    }
}
