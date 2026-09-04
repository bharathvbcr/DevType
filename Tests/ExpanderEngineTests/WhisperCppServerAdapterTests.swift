import Foundation
import XCTest
@testable import ExpanderEngine

final class WhisperCppServerAdapterTests: XCTestCase {
    func testOversizedConvertedAudioFailsBeforeTransport() async throws {
        let audioURL = try makeAudioFile(sampleCount: 100)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let transportCalls = LockedInt()
        let adapter = WhisperCppServerAdapter(
            endpointURL: URL(string: "http://127.0.0.1:8080/inference")!,
            maximumWAVBytes: 44 + 199,
            transport: { _, _ in
                transportCalls.increment()
                throw URLError(.badServerResponse)
            }
        )

        do {
            for try await _ in adapter.transcribe(makeRequest(audioURL: audioURL)) {}
            XCTFail("Oversized converted audio must fail before local HTTP egress")
        } catch let failure as VoiceFailure {
            XCTAssertEqual(failure.code, .captureBackpressure)
            XCTAssertEqual(failure.artifactState, .durable)
        } catch {
            XCTFail("Expected a typed VoiceFailure, got \(error)")
        }
        XCTAssertEqual(transportCalls.value, 0)
    }

    func testConsumerCancellationCancelsTransportWork() async throws {
        let audioURL = try makeAudioFile(sampleCount: 100)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let transportStarted = expectation(description: "Whisper transport started")
        let transportCancelled = expectation(description: "Whisper transport cancelled")
        let adapter = WhisperCppServerAdapter(
            endpointURL: URL(string: "http://127.0.0.1:8080/inference")!,
            transport: { request, _ in
                transportStarted.fulfill()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    transportCancelled.fulfill()
                    throw CancellationError()
                }
                throw URLError(.timedOut)
            }
        )
        let consumer = Task {
            do {
                for try await _ in adapter.transcribe(makeRequest(audioURL: audioURL)) {}
            } catch {
                // Cancellation may finish an AsyncThrowingStream or surface the producer error.
            }
        }

        await fulfillment(of: [transportStarted], timeout: 1)
        consumer.cancel()
        await fulfillment(of: [transportCancelled], timeout: 1)
        await consumer.value
    }

    private func makeAudioFile(sampleCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-adapter-\(UUID().uuidString).wav")
        let pcm = Data(repeating: 0, count: sampleCount * MemoryLayout<Int16>.size)
        try WhisperAudioPayload.wavContainer(
            pcm: pcm,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        ).write(to: url)
        return url
    }

    private func makeRequest(audioURL: URL) -> SpeechRequest {
        SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: AudioArtifact(
                fileURL: audioURL,
                format: "wav",
                sampleRate: 16000,
                channelCount: 1,
                frameCount: 100,
                durationSeconds: 0.01,
                byteCount: 244,
                sha256Hex: "redacted",
                gapCount: 0
            ),
            deadline: Date().addingTimeInterval(10),
            privacyRoute: .localNetworkOnly
        )
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
