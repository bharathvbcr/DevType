import XCTest
import CryptoKit
@testable import ExpanderEngine

final class VoiceStressTests: XCTestCase {

    // MARK: - 1. Concurrent Burst Toggles Stress Test

    func testConcurrentBurstToggles() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceStress_\(UUID().uuidString)")
        let recorder = VoiceAudioRecorder(cacheDirectory: tempDir)

        for _ in 0..<15 {
            do {
                try recorder.startRecording()
                _ = recorder.stopRecording()
            } catch {
                recorder.cancelRecording()
            }
            recorder.cancelRecording()
        }

        recorder.cleanupOldJournals()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 2. Zero-Byte & Corrupt Audio Handling

    func testZeroByteAndCorruptAudioTranscription() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zeroByteURL = tempDir.appendingPathComponent("empty.wav")
        FileManager.default.createFile(atPath: zeroByteURL.path, contents: Data())

        let corruptURL = tempDir.appendingPathComponent("corrupt.wav")
        FileManager.default.createFile(atPath: corruptURL.path, contents: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22]))

        let transcriber = VoiceTranscriber()

        let exp1 = expectation(description: "Zero byte audio should fail fast")
        transcriber.transcribe(audioURL: zeroByteURL) { res in
            switch res {
            case .success:
                XCTFail("Zero byte audio must not succeed")
            case .failure(let err):
                XCTAssertNotNil(err)
            }
            exp1.fulfill()
        }

        let exp2 = expectation(description: "Corrupt audio should fail fast")
        transcriber.transcribe(audioURL: corruptURL) { res in
            switch res {
            case .success:
                XCTFail("Corrupt audio must not succeed")
            case .failure(let err):
                XCTAssertNotNil(err)
            }
            exp2.fulfill()
        }

        let nonExistentURL = tempDir.appendingPathComponent("missing.wav")
        let exp3 = expectation(description: "Missing audio should fail fast")
        transcriber.transcribe(audioURL: nonExistentURL) { res in
            switch res {
            case .success:
                XCTFail("Missing audio must not succeed")
            case .failure(let err):
                XCTAssertNotNil(err)
            }
            exp3.fulfill()
        }

        wait(for: [exp1, exp2, exp3], timeout: 5.0)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 3. Hostile & Adversarial String Fuzzing

    func testAdversarialStringFuzzingInSmartDictation() {
        // Massive string
        let massive = String(repeating: "um like hello world actually test ", count: 200)
        let processedMassive = SmartDictationEngine.process(rawTranscript: massive)
        XCTAssertFalse(processedMassive.isEmpty)

        // Emoji sequences and zero-width joiners
        let emojiInput = "👨‍👩‍👧‍👦 um like 🏳️‍⚧️ actually 🚀"
        let processedEmoji = SmartDictationEngine.process(rawTranscript: emojiInput)
        XCTAssertTrue(processedEmoji.contains("🚀"))

        // Whitespace and punctuation only
        XCTAssertEqual(SmartDictationEngine.process(rawTranscript: ""), "")
        XCTAssertEqual(SmartDictationEngine.process(rawTranscript: "   \n\t  "), "")
        XCTAssertEqual(SmartDictationEngine.process(rawTranscript: ",,, ... ???"), "")

        // Extreme self corrections
        let nestedCorrections = "let us meet at one... actually two... no wait three... make that four pm"
        let corrected = SmartDictationEngine.resolveSelfCorrections(nestedCorrections)
        XCTAssertEqual(corrected, "four pm")
    }

    // MARK: - 4. Complex Programming Syntax Cases

    func testProgrammingSyntaxFormatting() {
        // Screaming Snake Case
        let screaming = SmartDictationEngine.applyTone("screaming snake case max retry count", tone: .code)
        XCTAssertEqual(screaming, "MAX_RETRY_COUNT")

        // Constant Case
        let constant = SmartDictationEngine.applyTone("constant case api base url", tone: .code)
        XCTAssertEqual(constant, "API_BASE_URL")

        // Pascal Case
        let pascal = SmartDictationEngine.applyTone("pascal case user authentication service", tone: .code)
        XCTAssertEqual(pascal, "UserAuthenticationService")

        // Kebab Case
        let kebab = SmartDictationEngine.applyTone("kebab case btn submit action", tone: .code)
        XCTAssertEqual(kebab, "btn-submit-action")

        // Symbols & Operators
        let operators = "a fat arrow b strict equal c logical and d"
        let styledOperators = SmartDictationEngine.applyTone(operators, tone: .code)
        XCTAssertEqual(styledOperators, "a => b === c && d")
    }

    // MARK: - 5. Multilingual Disfluency Filtering

    func testMultilingualDisfluencyFiltering() {
        // English
        let en = "I think, um, we should, like, launch tomorrow."
        XCTAssertEqual(SmartDictationEngine.filterDisfluencies(en), "I think we should launch tomorrow.")

        // Korean
        let ko = "음 저기 우리 어 내일 만나자"
        let cleanedKo = SmartDictationEngine.filterDisfluencies(ko)
        XCTAssertEqual(cleanedKo, "우리 내일 만나자")

        // Japanese
        let ja = "えーと あの 明日 会いましょう"
        let cleanedJa = SmartDictationEngine.filterDisfluencies(ja)
        XCTAssertEqual(cleanedJa, "明日 会いましょう")
    }

    // MARK: - 6. Checksum Integrity Verification

    func testChecksumIntegrityVerification() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sampleData = "DevType Verified Model Binary".data(using: .utf8)!
        let expectedDigest = SHA256.hash(data: sampleData).map { String(format: "%02x", $0) }.joined()

        let fileURL = tempDir.appendingPathComponent("model.gguf")
        try? sampleData.write(to: fileURL)

        XCTAssertTrue(VoiceModelManager.verifyChecksum(fileURL: fileURL, expectedHex: expectedDigest))
        XCTAssertFalse(VoiceModelManager.verifyChecksum(fileURL: fileURL, expectedHex: "0000000000000000000000000000000000000000000000000000000000000000"))

        try? FileManager.default.removeItem(at: tempDir)
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

            let diff = VoiceProgressiveTypingEngine.computeDiff(
                currentInjectedText: currentText,
                targetTranscript: targetText
            )

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

        for (index, utterance) in utterances.enumerated() {
            // Simulate progressive partials within the utterance
            let words = utterance.split(separator: " ")
            for wordIndex in 1...words.count {
                let partial = words.prefix(wordIndex).joined(separator: " ")
                let combined = VoiceProgressiveTypingEngine.combineUtterances(
                    committed: committed,
                    activePartial: partial
                )

                let diff = VoiceProgressiveTypingEngine.computeDiff(
                    currentInjectedText: documentState,
                    targetTranscript: combined
                )

                // Verify invariant: previous committed utterances are NEVER erased
                if index > 0 {
                    let firstUtterance = utterances[0]
                    XCTAssertTrue(
                        combined.hasPrefix(firstUtterance),
                        "Cumulative text must preserve first utterance across all pauses"
                    )
                }

                // Apply diff
                let preservedCount = documentState.count - diff.eraseCount
                documentState = String(documentState.prefix(preservedCount)) + diff.textToInject
                XCTAssertEqual(documentState, combined)
            }

            // Pause: Utterance completes and is committed
            committed.append(utterance)
        }

        XCTAssertTrue(documentState.contains("Today we are shipping the new release."))
        XCTAssertTrue(documentState.contains("All unit tests and integration tests have passed."))
        XCTAssertTrue(documentState.contains("The performance benchmarks look excellent."))
        XCTAssertTrue(documentState.contains("Please review the PR and approve."))
    }
}
