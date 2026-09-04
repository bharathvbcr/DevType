import Foundation
import XCTest
@testable import ExpanderEngine

final class GeminiSpeechAdapterPrivacyTests: XCTestCase {
    func testRevokedCloudConsentRefusesBeforeAudioReadOrTransport() async {
        let consent = MutableConsent(true)
        let transports = ThreadSafeCounter()
        let adapter = GeminiSpeechAdapter(
            consentGranted: { consent.value },
            transcribe: { _, _, _, _, _, _ in
                transports.increment()
                return GeminiTranscriptionResult(text: "must not run", rawText: "must not run")
            }
        )
        consent.value = false

        let missingAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("revoked-consent-must-not-be-read.caf")
        let request = SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: AudioArtifact(
                fileURL: missingAudio,
                format: "caf",
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 16,
                durationSeconds: 0.001,
                byteCount: 32,
                sha256Hex: "redacted",
                gapCount: 0
            ),
            deadline: Date().addingTimeInterval(1),
            privacyRoute: .cloudPermitted
        )

        var failure: VoiceFailure?
        do {
            for try await _ in adapter.transcribe(request) {}
            XCTFail("Revoked consent must refuse cloud audio egress")
        } catch let voiceFailure as VoiceFailure {
            failure = voiceFailure
        } catch {
            XCTFail("Expected a structured VoiceFailure, got \(error)")
        }

        XCTAssertEqual(failure?.code, .cloudAudioConsentRequired)
        XCTAssertEqual(failure?.userAction, .retryWithOtherProvider)
        XCTAssertEqual(transports.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingAudio.path))
    }

    func testConsentRevokedDuringPayloadPreparationRefusesFinalTransport() async throws {
        let consent = MutableConsent(true)
        let transports = ThreadSafeCounter()
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-consent-recheck-\(UUID().uuidString).invalid")
        try Data([0, 1, 2, 3]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let adapter = GeminiSpeechAdapter(
            consentGranted: { consent.value },
            credentialState: { .available("test-key-never-sent") },
            afterPayloadPrepared: { consent.value = false },
            transcribe: { _, _, _, _, _, _ in
                transports.increment()
                return GeminiTranscriptionResult(text: "must not run", rawText: "must not run")
            }
        )

        let failure = await transcriptionFailure(
            from: adapter,
            request: makeRequest(audioURL: audioURL, byteCount: 4)
        )
        XCTAssertEqual(failure?.code, .cloudAudioConsentRequired)
        XCTAssertEqual(transports.value, 0)
    }

    func testRetryBoundaryConsentFailureMapsToDurableUserAction() async throws {
        let consent = MutableConsent(true)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-retry-consent-\(UUID().uuidString).invalid")
        try Data([0, 1, 2, 3]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let adapter = GeminiSpeechAdapter(
            consentGranted: { consent.value },
            credentialState: { .available("test-key-never-sent") },
            transcribe: { _, _, _, _, _, uploadAuthorized in
                consent.value = false
                guard uploadAuthorized() else {
                    throw GeminiTranscriptionError.uploadNotAuthorized
                }
                return GeminiTranscriptionResult(text: "must not run", rawText: "must not run")
            }
        )

        let failure = await transcriptionFailure(
            from: adapter,
            request: makeRequest(audioURL: audioURL, byteCount: 4)
        )
        XCTAssertEqual(failure?.code, .cloudAudioConsentRequired)
        XCTAssertEqual(failure?.retryClass, .afterUserAction)
        XCTAssertEqual(failure?.artifactState, .durable)
        XCTAssertEqual(failure?.userAction, .retryWithOtherProvider)
    }

    func testOversizedSparseAudioIsRejectedBeforeTransport() async throws {
        let transports = ThreadSafeCounter()
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-oversized-\(UUID().uuidString).invalid")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: audioURL)
        try handle.truncate(atOffset: UInt64(GeminiTranscriptionClient.maxPayloadSizeBytes + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let adapter = GeminiSpeechAdapter(
            consentGranted: { true },
            credentialState: { .available("test-key-never-sent") },
            transcribe: { _, _, _, _, _, _ in
                transports.increment()
                return GeminiTranscriptionResult(text: "must not run", rawText: "must not run")
            }
        )

        let failure = await transcriptionFailure(
            from: adapter,
            request: makeRequest(
                audioURL: audioURL,
                byteCount: Int64(GeminiTranscriptionClient.maxPayloadSizeBytes + 1)
            )
        )
        XCTAssertEqual(failure?.code, .captureBackpressure)
        XCTAssertEqual(transports.value, 0)
    }

    func testBoundedPayloadReaderAcceptsExactLimitAndRejectsLimitPlusOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-bounded-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let exact = directory.appendingPathComponent("exact.bin")
        let oversized = directory.appendingPathComponent("oversized.bin")
        try Data(repeating: 7, count: 8).write(to: exact)
        try Data(repeating: 9, count: 9).write(to: oversized)

        XCTAssertEqual(
            try GeminiSpeechAdapter.boundedPayloadData(from: exact, maximumBytes: 8),
            Data(repeating: 7, count: 8)
        )
        XCTAssertThrowsError(
            try GeminiSpeechAdapter.boundedPayloadData(from: oversized, maximumBytes: 8)
        ) { error in
            XCTAssertEqual(error as? GeminiTranscriptionError, .payloadTooLarge)
        }
    }

    private func transcriptionFailure(
        from adapter: GeminiSpeechAdapter,
        request: SpeechRequest
    ) async -> VoiceFailure? {
        do {
            for try await _ in adapter.transcribe(request) {}
            XCTFail("Expected transcription to fail closed")
        } catch let failure as VoiceFailure {
            return failure
        } catch {
            XCTFail("Expected a structured VoiceFailure, got \(error)")
        }
        return nil
    }

    private func makeRequest(audioURL: URL, byteCount: Int64) -> SpeechRequest {
        SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: AudioArtifact(
                fileURL: audioURL,
                format: audioURL.pathExtension,
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 16,
                durationSeconds: 0.001,
                byteCount: byteCount,
                sha256Hex: "redacted",
                gapCount: 0
            ),
            deadline: Date().addingTimeInterval(1),
            privacyRoute: .cloudPermitted
        )
    }
}

private final class MutableConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) { storage = value }

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
