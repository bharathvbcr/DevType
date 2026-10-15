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

    func testPreparePayloadRemovesSeededScratchWhenEncodingFails() throws {
        let sessionID = VoiceSessionID()
        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-\(sessionID.rawValue.uuidString).flac")
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).caf")
        try Data("seeded-scratch".utf8).write(to: scratchURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: captureURL.path, contents: Data()))
        defer {
            try? FileManager.default.removeItem(at: scratchURL)
            try? FileManager.default.removeItem(at: captureURL)
        }

        let payload = makeAdapter().preparePayload(for: makeRequest(sessionID: sessionID, audioURL: captureURL, byteCount: 0))

        XCTAssertNil(payload.scratchURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL.path))
        XCTAssertEqual(payload.fileURL, captureURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testPreparePayloadDoesNotDeleteCaptureWhenItIsTheScratchPath() throws {
        let sessionID = VoiceSessionID()
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-\(sessionID.rawValue.uuidString).flac")
        let marker = Data("not-a-capture-to-delete".utf8)
        try marker.write(to: captureURL)
        defer { try? FileManager.default.removeItem(at: captureURL) }

        let payload = makeAdapter().preparePayload(
            for: makeRequest(sessionID: sessionID, audioURL: captureURL, byteCount: Int64(marker.count))
        )

        XCTAssertNil(payload.scratchURL)
        XCTAssertEqual(payload.fileURL, captureURL)
        XCTAssertEqual(try Data(contentsOf: captureURL), marker)
    }

    func testPreparePayloadRemovesScratchSymlinkAndKeepsItsTarget() throws {
        let sessionID = VoiceSessionID()
        let scratchURL = scratchURL(for: sessionID)
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-target-\(UUID().uuidString).bin")
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-capture-\(UUID().uuidString).caf")
        let targetBytes = Data("target-bytes-must-remain".utf8)
        try targetBytes.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: scratchURL, withDestinationURL: targetURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: captureURL.path, contents: Data()))
        defer {
            try? FileManager.default.removeItem(at: scratchURL)
            try? FileManager.default.removeItem(at: targetURL)
            try? FileManager.default.removeItem(at: captureURL)
        }

        let payload = makeAdapter().preparePayload(
            for: makeRequest(sessionID: sessionID, audioURL: captureURL, byteCount: 0)
        )

        XCTAssertNil(payload.scratchURL)
        XCTAssertEqual(payload.fileURL, captureURL)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: scratchURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL.path))
        XCTAssertEqual(try Data(contentsOf: targetURL), targetBytes)
        XCTAssertEqual(try Data(contentsOf: captureURL), Data())
    }

    func testPreparePayloadKeepsCaptureBytesWhenScratchSymlinkPointsAtCapture() throws {
        let sessionID = VoiceSessionID()
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-capture-\(UUID().uuidString).caf")
        let scratchURL = scratchURL(for: sessionID)
        let marker = Data("capture-bytes-stay".utf8)
        try marker.write(to: captureURL)
        try FileManager.default.createSymbolicLink(at: scratchURL, withDestinationURL: captureURL)
        defer {
            try? FileManager.default.removeItem(at: scratchURL)
            try? FileManager.default.removeItem(at: captureURL)
        }

        let payload = makeAdapter().preparePayload(
            for: makeRequest(sessionID: sessionID, audioURL: captureURL, byteCount: Int64(marker.count))
        )

        XCTAssertNil(payload.scratchURL)
        XCTAssertEqual(payload.fileURL, captureURL)
        XCTAssertEqual(try Data(contentsOf: captureURL), marker)
    }

    func testPreparePayloadDoesNotDeleteAnotherSessionsScratchFile() throws {
        let failingSession = VoiceSessionID()
        let otherSession = VoiceSessionID()
        let failingScratch = scratchURL(for: failingSession)
        let otherScratch = scratchURL(for: otherSession)
        let otherBytes = Data("other-session-scratch".utf8)
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("other-session-capture-\(UUID().uuidString).caf")
        try Data("failing-session-scratch".utf8).write(to: failingScratch)
        try otherBytes.write(to: otherScratch)
        XCTAssertTrue(FileManager.default.createFile(atPath: captureURL.path, contents: Data()))
        defer {
            try? FileManager.default.removeItem(at: failingScratch)
            try? FileManager.default.removeItem(at: otherScratch)
            try? FileManager.default.removeItem(at: captureURL)
        }

        _ = makeAdapter().preparePayload(
            for: makeRequest(sessionID: failingSession, audioURL: captureURL, byteCount: 0)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: failingScratch.path))
        XCTAssertEqual(try Data(contentsOf: otherScratch), otherBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testPreparePayloadPreservesOddCaptureNamesAndUuidSibling() throws {
        let temporary = FileManager.default.temporaryDirectory
        let names = [
            "spaced capture \(UUID().uuidString).caf",
            "録音 \(UUID().uuidString).caf",
            "clip.\(UUID().uuidString).flac"
        ]
        for name in names {
            let sessionID = VoiceSessionID()
            let captureURL = temporary.appendingPathComponent(name)
            let captureBytes = Data("capture-\(name)".utf8)
            let siblingURL = temporary.appendingPathComponent(
                "not-the-scratch-\(sessionID.rawValue.uuidString).flac"
            )
            let siblingBytes = Data("sibling-of-\(sessionID.rawValue.uuidString)".utf8)
            try captureBytes.write(to: captureURL)
            try siblingBytes.write(to: siblingURL)
            defer {
                try? FileManager.default.removeItem(at: captureURL)
                try? FileManager.default.removeItem(at: siblingURL)
                try? FileManager.default.removeItem(at: scratchURL(for: sessionID))
            }

            let payload = makeAdapter().preparePayload(
                for: makeRequest(sessionID: sessionID, audioURL: captureURL, byteCount: Int64(captureBytes.count))
            )

            XCTAssertEqual(try Data(contentsOf: captureURL), captureBytes, name)
            XCTAssertEqual(try Data(contentsOf: siblingURL), siblingBytes, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
            XCTAssertTrue(
                payload.fileURL == captureURL || payload.fileURL == scratchURL(for: sessionID),
                "payload left the capture directory for \(name)"
            )
        }
    }

    func testPreparePayloadFailureModesDoNotHangOrDeleteTemporaryDirectory() {
        let temporary = FileManager.default.temporaryDirectory
        let sentinelURL = temporary.appendingPathComponent("sentinel-\(UUID().uuidString).keep")
        let sentinel = Data("temporary-directory-sentinel".utf8)
        XCTAssertNoThrow(try sentinel.write(to: sentinelURL))
        defer { try? FileManager.default.removeItem(at: sentinelURL) }

        let emptyCapture = temporary.appendingPathComponent("empty-\(UUID().uuidString).caf")
        XCTAssertTrue(FileManager.default.createFile(atPath: emptyCapture.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: emptyCapture) }
        let emptySession = VoiceSessionID()
        let emptyPayload = preparePayloadWithoutHanging(
            for: makeRequest(sessionID: emptySession, audioURL: emptyCapture, byteCount: 0)
        )
        XCTAssertNotNil(emptyPayload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyCapture.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(for: emptySession).path))

        let missingCapture = temporary.appendingPathComponent("missing-\(UUID().uuidString).caf")
        let missingSession = VoiceSessionID()
        let missingPayload = preparePayloadWithoutHanging(
            for: makeRequest(sessionID: missingSession, audioURL: missingCapture, byteCount: 0)
        )
        XCTAssertNotNil(missingPayload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingCapture.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(for: missingSession).path))

        let captureDirectory = temporary.appendingPathComponent(
            "capture-dir-\(UUID().uuidString)",
            isDirectory: true
        )
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true))
        let insideURL = captureDirectory.appendingPathComponent("inside.txt")
        let insideBytes = Data("inside-capture-directory".utf8)
        XCTAssertNoThrow(try insideBytes.write(to: insideURL))
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let directorySession = VoiceSessionID()
        let directoryPayload = preparePayloadWithoutHanging(
            for: makeRequest(sessionID: directorySession, audioURL: captureDirectory, byteCount: 0)
        )
        XCTAssertNotNil(directoryPayload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path))
        XCTAssertEqual(try? Data(contentsOf: insideURL), insideBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(for: directorySession).path))

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try? Data(contentsOf: sentinelURL), sentinel)
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

    private func scratchURL(for sessionID: VoiceSessionID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-\(sessionID.rawValue.uuidString).flac")
    }

    private func preparePayloadWithoutHanging(for request: SpeechRequest) -> GeminiSpeechAdapter.PayloadSource? {
        let finished = expectation(description: "preparePayload returned")
        let box = PayloadBox()
        let adapter = makeAdapter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.payload = adapter.preparePayload(for: request)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        return box.payload
    }

    private func makeAdapter() -> GeminiSpeechAdapter {
        GeminiSpeechAdapter(
            consentGranted: { false },
            transcribe: { _, _, _, _, _, _ in
                GeminiTranscriptionResult(text: "unused", rawText: "unused")
            }
        )
    }

    private func makeRequest(sessionID: VoiceSessionID = VoiceSessionID(), audioURL: URL, byteCount: Int64) -> SpeechRequest {
        SpeechRequest(
            sessionID: sessionID,
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

private final class PayloadBox {
    var payload: GeminiSpeechAdapter.PayloadSource?
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
