import Foundation
import Speech

public final class LegacyAppleSpeechAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor

    public init(locale: Locale = Locale.current) {
        self.descriptor = SpeechProviderDescriptor(
            id: "apple.speech.legacy",
            displayName: "Apple Speech (On-Device)",
            modelVersion: "system",
            privacyRoute: .onDeviceOnly,
            supportsStreaming: true,
            supportsContextualStrings: true
        )
    }

    public func probe() async -> ProviderReadiness {
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        switch authStatus {
        case .authorized:
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                return .temporarilyUnavailable(retryAfterSeconds: 2.0, reason: .endpointUnreachable)
            }
            let evidence = ProviderEvidence(
                providerID: descriptor.id,
                modelVersion: descriptor.modelVersion,
                probeTimestamp: Date(),
                capabilities: ["onDeviceRecognition", "contextualStrings", "offline"]
            )
            return .ready(evidence)
        case .denied, .restricted:
            return .requiresPermission(.speechRecognition)
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            if granted {
                return await probe()
            } else {
                return .requiresPermission(.speechRecognition)
            }
        @unknown default:
            return .unsupported(reason: .modelLoadFailed)
        }
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            let recognizer = SFSpeechRecognizer(locale: request.locale) ?? SFSpeechRecognizer()
            guard let recognizer = recognizer, recognizer.isAvailable else {
                continuation.finish(throwing: VoiceFailure(
                    stage: .recognition,
                    code: .endpointUnreachable,
                    providerID: descriptor.id,
                    redactedDetail: "SFSpeechRecognizer unavailable for locale \(request.locale.identifier)"
                ))
                return
            }

            let recognitionRequest = SFSpeechURLRecognitionRequest(url: request.audio.fileURL)
            if #available(macOS 10.15, *) {
                recognitionRequest.requiresOnDeviceRecognition = true
            }
            if #available(macOS 14.0, *), !request.vocabulary.terms.isEmpty {
                // Apple contextual strings guidance: max 100 entries
                let capped = Array(request.vocabulary.terms.prefix(100))
                recognitionRequest.contextualStrings = capped
            }

            let startTime = Date()
            let lastSegmentID = UUID().uuidString
            var segmentRevision: UInt64 = 0

            let task = recognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let error = error {
                    // Check if error is due to cancellation
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 203 {
                        // Empty speech / timeout
                        let raw = RawTranscript(
                            text: "",
                            localeIdentifier: request.locale.identifier,
                            confidence: 0,
                            providerID: self.descriptor.id,
                            modelVersion: self.descriptor.modelVersion,
                            latencyMs: Date().timeIntervalSince(startTime) * 1000,
                            audioSHA256: request.audio.sha256Hex,
                            isFinal: true
                        )
                        let completion = SpeechCompletion(
                            rawTranscript: raw,
                            finalSegmentCount: 0,
                            totalDurationSeconds: request.audio.durationSeconds
                        )
                        continuation.yield(.completed(completion))
                        continuation.finish()
                        return
                    }
                    continuation.finish(throwing: error)
                    return
                }

                guard let result = result else { return }

                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal

                segmentRevision += 1
                let segment = SpeechSegment(
                    segmentID: lastSegmentID,
                    revision: segmentRevision,
                    startSeconds: 0,
                    durationSeconds: request.audio.durationSeconds,
                    text: text,
                    alternatives: [],
                    confidence: 1.0,
                    finality: isFinal ? .final : .volatile
                )
                continuation.yield(.segment(segment))

                if isFinal {
                    let latency = Date().timeIntervalSince(startTime) * 1000
                    let raw = RawTranscript(
                        text: text,
                        localeIdentifier: request.locale.identifier,
                        confidence: 1.0,
                        providerID: self.descriptor.id,
                        modelVersion: self.descriptor.modelVersion,
                        latencyMs: latency,
                        audioSHA256: request.audio.sha256Hex,
                        isFinal: true
                    )
                    let completion = SpeechCompletion(
                        rawTranscript: raw,
                        finalSegmentCount: 1,
                        totalDurationSeconds: request.audio.durationSeconds
                    )
                    continuation.yield(.completed(completion))
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func cancel(sessionID: VoiceSessionID) async {
        // Handled via continuation.onTermination
    }
}
