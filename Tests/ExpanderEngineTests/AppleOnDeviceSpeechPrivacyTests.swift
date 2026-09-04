import AVFoundation
import Foundation
import XCTest
@testable import ExpanderEngine

final class AppleOnDeviceSpeechPrivacyTests: XCTestCase {
    func testLegacyAppleProbeRejectsRecognizerThatRequiresNetwork() async {
        let starts = InvocationCounter()
        let runtime = unsupportedRuntime(starts: starts)
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtimeFactory: { _ in runtime }
        )

        let readiness = await adapter.probe()
        XCTAssertEqual(readiness, .incompatible(reason: .modelNotFound))
        XCTAssertEqual(starts.value, 0, "A readiness probe must never start recognition")
    }

    func testLegacyAppleTranscriptionNeverStartsNetworkRequiredRecognizer() async {
        let starts = InvocationCounter()
        let runtime = unsupportedRuntime(starts: starts)
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtimeFactory: { _ in runtime }
        )
        let request = SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: AudioArtifact(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("must-not-reach-apple-speech.wav"),
                format: "wav",
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 1,
                durationSeconds: 0.001,
                byteCount: 2,
                sha256Hex: "redacted",
                gapCount: 0
            ),
            locale: Locale(identifier: "en-US"),
            deadline: Date().addingTimeInterval(1),
            privacyRoute: .onDeviceOnly
        )

        var failure: VoiceFailure?
        do {
            for try await _ in adapter.transcribe(request) {}
            XCTFail("An on-device-only adapter must reject a network-required recognizer")
        } catch let voiceFailure as VoiceFailure {
            failure = voiceFailure
        } catch {
            XCTFail("Expected a structured VoiceFailure, got \(error)")
        }

        XCTAssertEqual(failure?.stage, .recognition)
        XCTAssertEqual(failure?.code, .modelNotFound)
        XCTAssertEqual(failure?.providerID, adapter.descriptor.id)
        XCTAssertEqual(starts.value, 0, "No Apple recognition task may start without on-device support")
    }

    func testLegacyAppleTranscriptionRefusesWhenSpeechAuthorizationIsDenied() async {
        let starts = InvocationCounter()
        let runtime = AppleOnDeviceSpeechRuntime(
            isAvailable: { true },
            supportsOnDeviceRecognition: { true },
            startRecognition: { _, resultHandler in
                starts.increment()
                resultHandler(nil, ExpectedRecognitionStop())
                return AppleSpeechTaskHandle(cancel: {})
            }
        )
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .denied },
            runtimeFactory: { _ in runtime }
        )

        var failure: VoiceFailure?
        do {
            for try await _ in adapter.transcribe(makeRequest()) {}
        } catch let voiceFailure as VoiceFailure {
            failure = voiceFailure
        } catch {
            XCTFail("Expected a structured VoiceFailure, got \(error)")
        }

        XCTAssertEqual(failure?.code, .speechRecognitionPermissionDenied)
        XCTAssertEqual(starts.value, 0, "Denied callers must never reach Apple's recognition task")
    }

    func testLivePreviewDisablesItselfWithoutFailingFinalProviderWhenOnDeviceIsUnsupported() {
        let starts = InvocationCounter()
        let failures = InvocationCounter()
        let runtime = unsupportedRuntime(starts: starts)
        let stream = LiveSpeechStream(
            runtime: runtime,
            contextualStrings: ["private vocabulary"],
            onSegment: { _ in },
            onFailure: { _ in failures.increment() }
        )

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        stream.append(buffer)
        stream.finish()
        stream.cancel()

        XCTAssertEqual(starts.value, 0, "Live microphone buffers must never reach network-required Apple Speech")
        XCTAssertEqual(
            failures.value,
            0,
            "Unavailable optional live preview must not abort a Local Whisper or Gemini final transcription"
        )
    }

    func testLivePreviewFailurePolicyDegradesOnlyForIndependentFinalProviders() {
        XCTAssertEqual(
            VoiceSessionCoordinator.liveRecognitionFailureDisposition(
                finalSpeechProviderID: VoiceSessionSnapshotFactory.ProviderID.gemini
            ),
            .disableOptionalPreview
        )
        XCTAssertEqual(
            VoiceSessionCoordinator.liveRecognitionFailureDisposition(
                finalSpeechProviderID: VoiceSessionSnapshotFactory.ProviderID.whisperServer
            ),
            .disableOptionalPreview
        )
        XCTAssertEqual(
            VoiceSessionCoordinator.liveRecognitionFailureDisposition(
                finalSpeechProviderID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy
            ),
            .failSession
        )
        XCTAssertEqual(
            VoiceSessionCoordinator.liveRecognitionFailureDisposition(
                finalSpeechProviderID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer
            ),
            .disableOptionalPreview,
            "SpeechAnalyzer consumes the durable recording independently of the legacy live preview"
        )
        XCTAssertEqual(
            VoiceSessionCoordinator.liveRecognitionFailureDisposition(
                finalSpeechProviderID: "unknown.future.provider"
            ),
            .failSession,
            "Unknown provider relationships must fail closed"
        )
    }

    func testLegacyAppleTranscriptionRequiresOnDeviceExecutionOnSupportedRecognizer() async {
        let flags = BooleanRecorder()
        let runtime = supportedRuntime(flags: flags, completeImmediately: true)
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtimeFactory: { _ in runtime }
        )

        do {
            for try await _ in adapter.transcribe(makeRequest()) {}
        } catch is ExpectedRecognitionStop {
            // The injected callback ends the stream after recording the privacy bit.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(flags.values, [true])
    }

    func testLivePreviewRequiresOnDeviceExecutionOnSupportedRecognizer() {
        let flags = BooleanRecorder()
        let runtime = supportedRuntime(flags: flags, completeImmediately: false)
        let stream = LiveSpeechStream(
            runtime: runtime,
            onSegment: { _ in },
            onFailure: { _ in }
        )
        stream.cancel()

        XCTAssertEqual(flags.values, [true])
    }

    private func unsupportedRuntime(starts: InvocationCounter) -> AppleOnDeviceSpeechRuntime {
        AppleOnDeviceSpeechRuntime(
            isAvailable: { true },
            supportsOnDeviceRecognition: { false },
            startRecognition: { _, _ in
                starts.increment()
                return AppleSpeechTaskHandle(cancel: {})
            }
        )
    }

    private func supportedRuntime(
        flags: BooleanRecorder,
        completeImmediately: Bool
    ) -> AppleOnDeviceSpeechRuntime {
        AppleOnDeviceSpeechRuntime(
            isAvailable: { true },
            supportsOnDeviceRecognition: { true },
            startRecognition: { request, resultHandler in
                flags.record(request.requiresOnDeviceRecognition)
                if completeImmediately {
                    resultHandler(nil, ExpectedRecognitionStop())
                }
                return AppleSpeechTaskHandle(cancel: {})
            }
        )
    }

    private func makeRequest() -> SpeechRequest {
        SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: AudioArtifact(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("on-device-policy-test.wav"),
                format: "wav",
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 1,
                durationSeconds: 0.001,
                byteCount: 2,
                sha256Hex: "redacted",
                gapCount: 0
            ),
            locale: Locale(identifier: "en-US"),
            deadline: Date().addingTimeInterval(1),
            privacyRoute: .onDeviceOnly
        )
    }
}

private struct ExpectedRecognitionStop: Error {}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class BooleanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
