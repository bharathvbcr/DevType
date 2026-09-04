import XCTest
import AVFoundation
@testable import ExpanderEngine

final class VoiceSessionRedesignTests: XCTestCase {

    func testCorrectionFallbackPlanRoundTripsAndLegacySnapshotDecodesEmpty() throws {
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(
                id: "speech",
                displayName: "Speech",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: VoiceSessionSnapshotFactory.ProviderID.appleFoundationModels,
                displayName: "Apple Intelligence",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            correctionFallbackProviderIDs: [
                VoiceSessionSnapshotFactory.ProviderID.openAICompatibleCorrector
            ],
            privacyRoute: .localNetworkOnly,
            targetLease: TargetLease(bundleIdentifier: "com.example.Target", processIdentifier: 42)
        )

        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(VoiceSessionSnapshot.self, from: encoded), snapshot)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "correctionFallbackProviderIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder().decode(VoiceSessionSnapshot.self, from: legacyData)
        XCTAssertEqual(decodedLegacy.correctionFallbackProviderIDs, [])
    }

    // MARK: - Reducer Tests

    func testReducerHappyPath() {
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(id: "test.speech", displayName: "Test", modelVersion: "1.0", privacyRoute: .onDeviceOnly),
            correctionProvider: CorrectionProviderDescriptor(id: "deterministic.local", displayName: "Deterministic", modelVersion: "1.0", privacyRoute: .onDeviceOnly),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 1234)
        )

        var state = VoiceSessionState(snapshot: snapshot, phase: .preparing)
        let gen = snapshot.generation

        // 1. Start Capture
        let r1 = VoiceSessionReducer.reduce(state: &state, event: .startCapture(mode: .hold), eventGeneration: gen)
        XCTAssertTrue(try! r1.get().contains(.startAudioCapture(mode: .hold)))
        XCTAssertEqual(state.phase, .capturing(mode: .hold))

        // 2. Stop Capture
        let r2 = VoiceSessionReducer.reduce(state: &state, event: .stopCapture, eventGeneration: gen)
        XCTAssertTrue(try! r2.get().contains(.finalizeAudioCapture))
        XCTAssertEqual(state.phase, .finalizingAudio)

        // 3. Audio Finalized
        let artifact = AudioArtifact(fileURL: URL(fileURLWithPath: "/tmp/test.caf"), frameCount: 16000, durationSeconds: 1.0)
        let r3 = VoiceSessionReducer.reduce(state: &state, event: .audioFinalized(artifact), eventGeneration: gen)
        XCTAssertTrue(try! r3.get().contains(.transcribeAudio(audio: artifact)))
        XCTAssertEqual(state.phase, .recognizing)

        // 4. Speech Completed
        let raw = RawTranscript(text: "hello world", localeIdentifier: "en_US", providerID: "test.speech", modelVersion: "1.0")
        let comp = SpeechCompletion(rawTranscript: raw, finalSegmentCount: 1, totalDurationSeconds: 1.0)
        let r4 = VoiceSessionReducer.reduce(state: &state, event: .speechCompleted(comp), eventGeneration: gen)
        XCTAssertTrue(try! r4.get().contains(.validateRawTranscript(raw)))
        XCTAssertEqual(state.phase, .validatingRaw)

        // 5. Raw Validation Passed -> Correcting
        let r5 = VoiceSessionReducer.reduce(state: &state, event: .rawValidationPassed(raw), eventGeneration: gen)
        XCTAssertTrue(try! r5.get().contains(.correctTranscript(raw: raw)))
        XCTAssertEqual(state.phase, .correcting)

        // 6. Correction Candidate Received -> Validating Correction
        let candidate = CorrectionCandidate(text: "Hello, world.", providerID: "deterministic.local", modelVersion: "1.0")
        _ = VoiceSessionReducer.reduce(state: &state, event: .correctionCandidateReceived(candidate), eventGeneration: gen)
        XCTAssertEqual(state.phase, .validatingCorrection)

        // 7. Correction Validation Passed -> Ready for Delivery
        let final = FinalTranscript(text: "Hello, world.", rawTranscript: raw, correctionCandidate: candidate, validationOutcome: .accepted(metrics: [:]))
        let r7 = VoiceSessionReducer.reduce(state: &state, event: .correctionValidationPassed(final), eventGeneration: gen)
        XCTAssertTrue(try! r7.get().contains(.deliverTranscript(finalTranscript: final, lease: snapshot.targetLease)))
        XCTAssertEqual(state.phase, .readyForDelivery)

        // 8. Delivery Completed -> Completed
        let receipt = DeliveryReceipt(sessionID: snapshot.sessionID, generation: gen, targetLease: snapshot.targetLease, deliveredTextLength: 13, evidenceQuality: .verifiedDirectAX)
        _ = VoiceSessionReducer.reduce(state: &state, event: .deliveryCompleted(receipt), eventGeneration: gen)
        XCTAssertEqual(state.phase, .completed(.inserted(receipt)))
    }

    func testReducerRejectsStaleGeneration() {
        let snapshot = VoiceSessionSnapshot(
            generation: SessionGeneration(rawValue: 5),
            speechProvider: SpeechProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            correctionProvider: CorrectionProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        )
        var state = VoiceSessionState(snapshot: snapshot, phase: .preparing)

        // Event from stale generation 4
        let result = VoiceSessionReducer.reduce(state: &state, event: .startCapture(mode: .hold), eventGeneration: SessionGeneration(rawValue: 4))
        switch result {
        case .failure(let error):
            XCTAssertEqual(error, .staleGeneration(current: SessionGeneration(rawValue: 5), received: SessionGeneration(rawValue: 4)))
        case .success:
            XCTFail("Should have failed on stale generation")
        }
    }

    func testMissingRawCorrectionCandidateUsesCompleteTerminalCommandPath() throws {
        let snapshot = VoiceFixtures.snapshot()
        var state = VoiceSessionState(snapshot: snapshot, phase: .correcting)
        let candidate = CorrectionCandidate(
            text: "must-not-enter-diagnostics",
            providerID: "stub.corrector",
            modelVersion: "1"
        )

        let commands = try VoiceSessionReducer.reduce(
            state: &state,
            event: .correctionCandidateReceived(candidate),
            eventGeneration: snapshot.generation
        ).get()

        guard case .failed(let failure) = state.phase else {
            return XCTFail("Missing raw transcript must terminally fail the session")
        }
        XCTAssertEqual(failure.stage, .correctionValidation)
        XCTAssertTrue(commands.contains(.notifyHUD(phase: .failed(failure))))
        XCTAssertTrue(commands.contains(.persistManifest(phase: .failed(failure))))
        XCTAssertTrue(commands.contains(.cleanupResources))
    }

    func testReducerDeliversRawFallbackWithoutInventingCandidate() {
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            correctionProvider: CorrectionProviderDescriptor(id: "unavailable", displayName: "Unavailable", modelVersion: "1", privacyRoute: .onDeviceOnly),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        )
        let raw = RawTranscript(text: "raw transcript", localeIdentifier: "en_US", providerID: "test", modelVersion: "1")
        let final = FinalTranscript(
            text: raw.text,
            rawTranscript: raw,
            correctionCandidate: nil,
            validationOutcome: .fallbackToRaw(reason: .correctionTimeout)
        )
        var state = VoiceSessionState(
            snapshot: snapshot,
            phase: .correcting,
            rawTranscript: raw
        )

        let result = VoiceSessionReducer.reduce(
            state: &state,
            event: .correctionValidationPassed(final),
            eventGeneration: snapshot.generation
        )

        XCTAssertTrue(try! result.get().contains(.deliverTranscript(
            finalTranscript: final,
            lease: snapshot.targetLease
        )))
        XCTAssertEqual(state.phase, .readyForDelivery)
    }

    func testReducerTerminalStateCannotReopen() {
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            correctionProvider: CorrectionProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        )
        var state = VoiceSessionState(snapshot: snapshot, phase: .cancelled)

        let result = VoiceSessionReducer.reduce(state: &state, event: .startCapture(mode: .hold), eventGeneration: snapshot.generation)
        switch result {
        case .failure(let error):
            XCTAssertEqual(error, .terminalStateCannotReopen(phase: .cancelled))
        case .success:
            XCTFail("Terminal state must not reopen")
        }
    }

    func testReducerCancellationFromAnyPhase() {
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            correctionProvider: CorrectionProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        )
        var state = VoiceSessionState(snapshot: snapshot, phase: .recognizing)

        let result = VoiceSessionReducer.reduce(state: &state, event: .cancel, eventGeneration: snapshot.generation)
        XCTAssertTrue(try! result.get().contains(.cleanupResources))
        XCTAssertEqual(state.phase, .cancelled)
    }

    // MARK: - Protected Span Extractor Tests

    func testProtectedSpanExtraction() {
        let text = "Check out https://github.com/apple/swift or email test@example.com at /var/log/system.log with --verbose flag and 100px width for $50"
        let spans = ProtectedSpanExtractor.extract(from: text, dictionaryTerms: ["apple"])

        let kinds = Set(spans.map { $0.kind })
        XCTAssertTrue(kinds.contains(.url))
        XCTAssertTrue(kinds.contains(.email))
        XCTAssertTrue(kinds.contains(.filePath))
        XCTAssertTrue(kinds.contains(.shellFlag))
        XCTAssertTrue(kinds.contains(.numberWithUnit))
        XCTAssertTrue(kinds.contains(.currency))
    }

    // MARK: - Correction Validator Tests

    func testCorrectionValidatorRejectsRefusal() {
        let raw = RawTranscript(text: "hello world", localeIdentifier: "en_US", providerID: "test", modelVersion: "1")
        let candidate = CorrectionCandidate(text: "I am an AI and cannot transcribe this.", providerID: "test", modelVersion: "1")
        let policy = CorrectionPolicy()

        let outcome = CorrectionValidator.validate(candidate: candidate, raw: raw, policy: policy, protectedSpans: [])
        XCTAssertEqual(outcome, .fallbackToRaw(reason: .correctionRefusal))
    }

    func testCorrectionValidatorRejectsMarkdownFences() {
        let raw = RawTranscript(text: "func test()", localeIdentifier: "en_US", providerID: "test", modelVersion: "1")
        let candidate = CorrectionCandidate(text: "```swift\nfunc test()\n```", providerID: "test", modelVersion: "1")

        let outcome = CorrectionValidator.validate(candidate: candidate, raw: raw, policy: CorrectionPolicy(), protectedSpans: [])
        XCTAssertEqual(outcome, .fallbackToRaw(reason: .correctionRefusal))
    }

    func testCorrectionValidatorRejectsAlteredProtectedSpans() {
        let raw = RawTranscript(text: "Download at https://example.com/v1", localeIdentifier: "en_US", providerID: "test", modelVersion: "1")
        let spans = ProtectedSpanExtractor.extract(from: raw.text)
        let candidate = CorrectionCandidate(text: "Download at https://different-url.org", providerID: "test", modelVersion: "1")

        let outcome = CorrectionValidator.validate(candidate: candidate, raw: raw, policy: CorrectionPolicy(), protectedSpans: spans)
        XCTAssertEqual(outcome, .fallbackToRaw(reason: .correctionProtectedSpanAltered))
    }

    func testCorrectionValidatorAcceptsCleanCandidate() {
        let raw = RawTranscript(text: "hello world period", localeIdentifier: "en_US", providerID: "test", modelVersion: "1")
        let candidate = CorrectionCandidate(text: "Hello, world.", providerID: "test", modelVersion: "1")

        let outcome = CorrectionValidator.validate(candidate: candidate, raw: raw, policy: CorrectionPolicy(), protectedSpans: [])
        if case .accepted = outcome {
            // Expected
        } else {
            XCTFail("Clean candidate should be accepted")
        }
    }

    // MARK: - Deterministic Corrector Tests

    func testDeterministicCorrectorPunctuationAndDisfluency() async throws {
        let corrector = DeterministicCorrector()
        let request = CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: "um hello world period new line this is a test comma right question mark",
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .onDeviceOnly
        )

        let candidate = try await corrector.correct(request)
        XCTAssertEqual(candidate.text, "Hello world.\nThis is a test, right?")
    }

    func testDeterministicCorrectorSelfCorrection() async throws {
        let corrector = DeterministicCorrector()
        let request = CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: "let's meet on Tuesday -- sorry, Thursday morning",
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .onDeviceOnly
        )

        let candidate = try await corrector.correct(request)
        XCTAssertEqual(candidate.text, "Let's meet on Thursday morning")
    }

    // MARK: - Audio Buffer Pool Tests

    func testAudioBufferPoolFIFO() {
        let pool = AudioBufferPool(capacity: 10, maxChunkFrames: 1024, bytesPerFrame: 4)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else {
            XCTFail("Failed to create test buffer")
            return
        }
        buffer.frameLength = 512

        let enqueued = pool.enqueue(buffer: buffer, sampleTime: 100.0)
        XCTAssertTrue(enqueued)

        let chunks = pool.dequeueAll()
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.sequence, 1)
        XCTAssertEqual(chunks.first?.sampleTime, 100.0)
    }

    func testAudioBufferPoolClampsZeroCapacityBeforeModulo() {
        let pool = AudioBufferPool(capacity: 0, maxChunkFrames: 1024, bytesPerFrame: 4)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            XCTFail("Failed to create test buffer")
            return
        }
        buffer.frameLength = 1

        XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: 0))
        XCTAssertEqual(pool.dequeueAll().count, 1)
    }

    // MARK: - Recovery Service Tests

    func testRecoveryServiceScansDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestVoiceSessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionStore = VoiceSessionStore(baseDirectory: tempDir)
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            correctionProvider: CorrectionProviderDescriptor(id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 999)
        )

        _ = try sessionStore.createSession(snapshot: snapshot)
        let raw = RawTranscript(text: "recovered speech", localeIdentifier: "en_US", providerID: "test", modelVersion: "1")
        try sessionStore.saveRawTranscript(raw, for: snapshot.sessionID)

        let recovery = VoiceRecoveryService(sessionStore: sessionStore)
        let recovered = recovery.scanRecoverableSessions(baseDirectory: tempDir)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.rawTranscript?.text, "recovered speech")
        XCTAssertFalse(recovered.first?.isDelivered ?? true)
    }

    func testSessionStorePersistsAudioArtifactMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestVoiceArtifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionStore = VoiceSessionStore(baseDirectory: tempDir)
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(
                id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: "test", displayName: "Test", modelVersion: "1", privacyRoute: .onDeviceOnly
            ),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        )
        _ = try sessionStore.createSession(snapshot: snapshot)

        let artifact = AudioArtifact(
            fileURL: tempDir.appendingPathComponent("capture.caf"),
            frameCount: 16_000,
            durationSeconds: 1,
            byteCount: 32_000,
            sha256Hex: String(repeating: "a", count: 64),
            gapCount: 2
        )
        try sessionStore.saveAudioArtifact(artifact, for: snapshot.sessionID)

        let metadataURL = tempDir
            .appendingPathComponent(snapshot.sessionID.description)
            .appendingPathComponent("audio-artifact.json")
        let decoded = try JSONDecoder().decode(AudioArtifact.self, from: Data(contentsOf: metadataURL))
        XCTAssertEqual(decoded, artifact)
    }

    // MARK: - Voice Insertion Service Tests

    @MainActor
    func testVoiceInsertionServiceTargetMismatch() async {
        let lease = TargetLease(bundleIdentifier: "com.nonexistent.app", processIdentifier: 999999)
        let receipt = await VoiceInsertionService.shared.deliver(
            text: "test message",
            targetLease: lease,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )

        XCTAssertEqual(receipt.evidenceQuality, .targetMismatch)
        XCTAssertEqual(receipt.deliveredTextLength, 0)
    }
}
