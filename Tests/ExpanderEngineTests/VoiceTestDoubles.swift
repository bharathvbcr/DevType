import Foundation
@testable import ExpanderEngine

// Test doubles for the voice pipeline.
//
// The shipping providers all reach outside the process — a microphone, a local server, a
// cloud API — so none of them can be driven deterministically. These stubs implement the
// same protocols and are installed through the registries' `register(_:)`, which is what
// makes the pipeline testable end to end rather than only in pieces.

/// A speech provider whose behaviour is scripted.
final class StubSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {
    enum Behavior {
        /// Emit these segments, then complete with their concatenation.
        case segments([SpeechSegment])
        /// Fail with this error.
        case failure(VoiceFailure)
        /// Never yield and never finish — models a wedged provider.
        case hang
        /// Yield after a delay, to race the watchdog.
        case slow(seconds: Double, text: String)
    }

    let descriptor: SpeechProviderDescriptor
    private let behavior: Behavior
    private let readiness: ProviderReadiness

    /// Number of times `transcribe` was entered, for asserting fallback behaviour.
    private(set) var transcribeCallCount = 0
    private let lock = UnfairLock()

    init(
        id: String = "stub.speech",
        privacyRoute: PrivacyRoute = .onDeviceOnly,
        readiness: ProviderReadiness? = nil,
        behavior: Behavior = .segments([])
    ) {
        self.descriptor = SpeechProviderDescriptor(
            id: id,
            displayName: "Stub \(id)",
            modelVersion: "stub",
            privacyRoute: privacyRoute,
            supportsStreaming: true,
            supportsContextualStrings: true
        )
        self.behavior = behavior
        self.readiness = readiness ?? .ready(ProviderEvidence(
            providerID: id,
            modelVersion: "stub",
            probeTimestamp: Date(),
            capabilities: ["stub"]
        ))
    }

    func probe() async -> ProviderReadiness { readiness }

    func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        lock.withLock { transcribeCallCount += 1 }

        return AsyncThrowingStream { continuation in
            Task { [behavior, descriptor] in
                switch behavior {
                case .hang:
                    return   // deliberately never finishes

                case .failure(let error):
                    continuation.finish(throwing: error)

                case .slow(let seconds, let text):
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    continuation.yield(.completed(Self.completion(text: text, provider: descriptor.id, request: request)))
                    continuation.finish()

                case .segments(let segments):
                    for segment in segments {
                        continuation.yield(.segment(segment))
                    }
                    let text = segments
                        .filter { $0.finality == .final }
                        .map(\.text)
                        .joined(separator: " ")
                    continuation.yield(.completed(Self.completion(text: text, provider: descriptor.id, request: request)))
                    continuation.finish()
                }
            }
        }
    }

    func cancel(sessionID: VoiceSessionID) async {}

    private static func completion(
        text: String,
        provider: String,
        request: SpeechRequest
    ) -> SpeechCompletion {
        SpeechCompletion(
            rawTranscript: RawTranscript(
                text: text,
                localeIdentifier: request.locale.identifier,
                providerID: provider,
                modelVersion: "stub"
            ),
            finalSegmentCount: 1,
            totalDurationSeconds: request.audio.durationSeconds
        )
    }
}

/// A corrector whose output is scripted, including the ways real models misbehave.
final class StubCorrector: TranscriptCorrector, @unchecked Sendable {
    enum Behavior {
        /// Return this text verbatim.
        case returns(String)
        /// Apply a transform to the raw transcript.
        case transform(@Sendable (String) -> String)
        /// Throw.
        case throws_(VoiceFailure)
        /// Sleep past the deadline before answering.
        case slow(seconds: Double, text: String)
    }

    let descriptor: CorrectionProviderDescriptor
    private let behavior: Behavior
    private let readiness: ProviderReadiness

    private(set) var correctCallCount = 0
    private(set) var lastRequest: CorrectionRequest?
    private let lock = UnfairLock()

    init(
        id: String = "stub.corrector",
        privacyRoute: PrivacyRoute = .onDeviceOnly,
        readiness: ProviderReadiness? = nil,
        behavior: Behavior = .transform { $0 }
    ) {
        self.descriptor = CorrectionProviderDescriptor(
            id: id,
            displayName: "Stub \(id)",
            modelVersion: "stub",
            privacyRoute: privacyRoute,
            supportsStructuredOutput: false
        )
        self.behavior = behavior
        self.readiness = readiness ?? .ready(ProviderEvidence(
            providerID: id,
            modelVersion: "stub",
            probeTimestamp: Date(),
            capabilities: ["stub"]
        ))
    }

    func probe() async -> ProviderReadiness { readiness }

    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        lock.withLock {
            correctCallCount += 1
            lastRequest = request
        }

        let text: String
        switch behavior {
        case .returns(let value):
            text = value
        case .transform(let block):
            text = block(request.rawTranscript)
        case .throws_(let error):
            throw error
        case .slow(let seconds, let value):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            text = value
        }

        return CorrectionCandidate(
            text: text,
            providerID: descriptor.id,
            modelVersion: "stub"
        )
    }

    func cancel(sessionID: VoiceSessionID) async {}
}

// MARK: - Fixtures

enum VoiceFixtures {

    static func audioArtifact(durationSeconds: Double = 2.0) -> AudioArtifact {
        AudioArtifact(
            fileURL: URL(fileURLWithPath: "/tmp/devtype-test.caf"),
            format: "caf",
            sampleRate: 16000,
            channelCount: 1,
            frameCount: Int64(durationSeconds * 16000),
            durationSeconds: durationSeconds,
            byteCount: Int64(durationSeconds * 32000),
            sha256Hex: "test",
            gapCount: 0
        )
    }

    static func snapshot(
        speechProviderID: String = "stub.speech",
        correctionProviderID: String = "stub.corrector",
        privacyRoute: PrivacyRoute = .onDeviceOnly,
        policy: CorrectionPolicy = CorrectionPolicy(),
        generation: UInt64 = 1,
        timeoutSeconds: Double = 30
    ) -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            generation: SessionGeneration(rawValue: generation),
            speechProvider: SpeechProviderDescriptor(
                id: speechProviderID,
                displayName: "Test",
                modelVersion: "1",
                privacyRoute: privacyRoute,
                supportsStreaming: true,
                supportsContextualStrings: true
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: correctionProviderID,
                displayName: "Test",
                modelVersion: "1",
                privacyRoute: privacyRoute,
                supportsStructuredOutput: false
            ),
            privacyRoute: privacyRoute,
            correctionPolicy: policy,
            targetLease: TargetLease(bundleIdentifier: "com.test.app", processIdentifier: 4242),
            timeoutSeconds: timeoutSeconds
        )
    }

    static func rawTranscript(_ text: String) -> RawTranscript {
        RawTranscript(text: text, localeIdentifier: "en_US", providerID: "test", modelVersion: "1")
    }

    static func correctionRequest(
        _ text: String,
        policy: CorrectionPolicy = CorrectionPolicy(),
        deadlineSeconds: Double = 5,
        privacyRoute: PrivacyRoute = .onDeviceOnly
    ) -> CorrectionRequest {
        CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: text,
            policy: policy,
            protectedSpans: ProtectedSpanExtractor.extract(from: text),
            deadline: Date().addingTimeInterval(deadlineSeconds),
            privacyRoute: privacyRoute
        )
    }
}
