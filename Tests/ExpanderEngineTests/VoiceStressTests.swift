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
}
