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

    func testManagedLocalhostProbeAndTranscribeUseBoundIPv4() async throws {
        try await assertProbeAndTranscribe(
            savedRaw: "http://localhost:18181/inference",
            managed: true,
            probe: "http://127.0.0.1:18181/",
            transcribe: "http://127.0.0.1:18181/inference"
        )
    }

    func testManagedIPv6LoopbackProbeAndTranscribeUseBoundIPv4() async throws {
        try await assertProbeAndTranscribe(
            savedRaw: "http://[::1]:18182/inference",
            managed: true,
            probe: "http://127.0.0.1:18182/",
            transcribe: "http://127.0.0.1:18182/inference"
        )
    }

    func testDefaultIPv4EndpointIsUnchangedWhenManaged() async throws {
        try await assertProbeAndTranscribe(
            savedRaw: "http://127.0.0.1:8080/inference",
            managed: true,
            probe: "http://127.0.0.1:8080/",
            transcribe: "http://127.0.0.1:8080/inference"
        )
    }

    func testDefaultIPv4EndpointIsUnchangedWhenNotManaged() async throws {
        try await assertProbeAndTranscribe(
            savedRaw: VoicePreferences.defaultWhisperEndpoint.absoluteString,
            managed: false,
            probe: "http://127.0.0.1:8080/",
            transcribe: "http://127.0.0.1:8080/inference"
        )
    }

    func testUnmanagedLocalhostIsNotRewritten() async throws {
        try await assertProbeAndTranscribe(
            savedRaw: "http://localhost:18181/inference",
            managed: false,
            probe: "http://localhost:18181/",
            transcribe: "http://localhost:18181/inference"
        )
    }

    func testUnmanagedIPv6LoopbackIsNotRewritten() async throws {
        try await assertProbeAndTranscribe(
            savedRaw: "http://[::1]:18182/inference",
            managed: false,
            probe: "http://[::1]:18182/",
            transcribe: "http://[::1]:18182/inference"
        )
    }

    func testManagedCustomPathKeepsTheSavedPathOnBoundIPv4() async throws {
        try await assertProbeAndTranscribe(
            savedRaw: "http://localhost:18184/api/inference",
            managed: true,
            probe: "http://127.0.0.1:18184/api/",
            transcribe: "http://127.0.0.1:18184/api/inference"
        )
    }

    /// A bad preference must stay invalid. Rewriting it to the bound address would hide it.
    func testNonLoopbackEndpointIsNotRewrittenWhileAManagedURLExists() async throws {
        let transportCalls = LockedInt()
        let probed = LockedURLBox()
        let adapter = WhisperCppServerAdapter(
            endpointURL: URL(string: "https://example.invalid/inference")!,
            transport: { _, _ in
                transportCalls.increment()
                throw URLError(.badServerResponse)
            },
            managedInferenceURL: { URL(string: "http://127.0.0.1:8080/inference")! },
            reachability: { url in
                probed.set(url)
                return true
            }
        )

        let readiness = await adapter.probe()
        guard case .requiresConfiguration(.invalidEndpointFormat) = readiness else {
            return XCTFail("non-loopback probe was \(readiness)")
        }
        XCTAssertNil(probed.value)

        let audioURL = try makeAudioFile(sampleCount: 100)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            for try await _ in adapter.transcribe(makeRequest(audioURL: audioURL)) {}
            XCTFail("A non-loopback preference must not be rewritten onto 127.0.0.1")
        } catch let failure as VoiceFailure {
            XCTAssertEqual(failure.code, .endpointUnreachable)
            XCTAssertTrue(failure.redactedDetail?.contains("non-loopback") == true)
        } catch {
            XCTFail("Expected a typed VoiceFailure, got \(error)")
        }
        XCTAssertEqual(transportCalls.value, 0)
    }

    private func assertProbeAndTranscribe(
        savedRaw: String,
        managed: Bool,
        probe: String,
        transcribe: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let saved = try XCTUnwrap(URL(string: savedRaw), file: file, line: line)
        let bound = WhisperServerSetup.spawnedChildInferenceURL(
            port: saved.port ?? 8080,
            savedEndpoint: saved
        )
        if managed {
            XCTAssertEqual(bound.absoluteString, transcribe, file: file, line: line)
        }
        let probed = LockedURLBox()
        let posted = LockedURLBox()
        let audioURL = try makeAudioFile(sampleCount: 100)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let adapter = WhisperCppServerAdapter(
            endpointURL: saved,
            transport: { request, _ in
                posted.set(request.url)
                XCTAssertEqual(request.httpMethod, "POST", file: file, line: line)
                let url = request.url ?? saved
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data("{\"text\":\"ok\"}".utf8), response)
            },
            managedInferenceURL: { managed ? bound : nil },
            reachability: { url in
                probed.set(url)
                return true
            }
        )

        let readiness = await adapter.probe()
        XCTAssertTrue(readiness.isReady, "probe was \(readiness)", file: file, line: line)
        XCTAssertEqual(probed.value?.absoluteString, probe, file: file, line: line)

        var completed = false
        for try await event in adapter.transcribe(makeRequest(audioURL: audioURL)) {
            if case .completed = event { completed = true }
        }
        XCTAssertTrue(completed, file: file, line: line)
        XCTAssertEqual(posted.value?.absoluteString, transcribe, file: file, line: line)
        XCTAssertEqual(adapter.endpointURL.absoluteString, saved.absoluteString, file: file, line: line)
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

private final class LockedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?

    var value: URL? { lock.withLock { storage } }
    func set(_ url: URL?) { lock.withLock { storage = url } }
}
