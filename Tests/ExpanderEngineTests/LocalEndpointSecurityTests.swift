import Foundation
import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

final class LocalEndpointSecurityTests: XCTestCase {
    override func tearDown() {
        BoundedLocalResponseURLProtocol.resetStops()
        VoicePreferences.resetAllForTesting()
        super.tearDown()
    }

    func testStrictValidatorAcceptsOnlyExactLoopbackHTTPHostsAndPreservesEndpointShape() throws {
        let accepted = [
            "http://localhost:11434/v1/chat/completions",
            "https://LOCALHOST:8443/custom/path?mode=fast",
            "http://127.0.0.1:8080/inference",
            "http://[::1]:8080/api/inference",
        ]

        for raw in accepted {
            let endpoint = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(
                try LocalEndpointSecurity.validated(endpoint).absoluteString,
                endpoint.absoluteString,
                "A valid loopback endpoint must retain its scheme, host, port, path, and query: \(raw)"
            )
        }
    }

    func testStrictValidatorRejectsRemoteAndAmbiguousAuthorities() throws {
        let rejected = [
            "https://example.com/v1/chat/completions",
            "http://192.168.1.10:11434/api/generate",
            "http://8.8.8.8/inference",
            "http://[2001:4860:4860::8888]/inference",
            "http://localhost.example.com/inference",
            "http://localhost./inference",
            "http://127.0.0.2/inference",
            "http://2130706433/inference",
            "http://localhost@evil.example/inference",
            "file://localhost/tmp/transcript",
            "ftp://127.0.0.1/inference",
        ]

        for raw in rejected {
            let endpoint = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(
                try LocalEndpointSecurity.validated(endpoint),
                "A local-only route accepted \(raw)"
            )
        }
    }

    func testLocalTransportRefusesRedirectsInsteadOfFollowingTheProposedRequest() throws {
        let delegate = LocalEndpointURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/inference")))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/inference")),
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://example.com/collect"]
            )
        )
        let proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/collect")))
        let completion = expectation(description: "redirect decision")

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposed
        ) { replacement in
            XCTAssertNil(replacement, "A local-only session must never follow a redirect.")
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
    }

    func testLocalTransportDoesNotInheritProxyCookiesOrCredentialStorage() {
        let configuration = LocalEndpointSecurity.makeSessionConfiguration()

        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
    }

    func testBoundedTransportAcceptsAResponseAtTheExactLimit() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/exact")))

        let (data, response) = try await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: 8,
            using: session
        )

        XCTAssertEqual(data, Data(repeating: 0x41, count: 8))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testBoundedTransportRejectsLimitPlusOneAndDeclaredOversizeResponses() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }

        for path in ["limit-plus-one", "declared-oversize"] {
            let request = URLRequest(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1/\(path)"))
            )
            do {
                _ = try await LocalEndpointSecurity.data(
                    for: request,
                    maximumResponseBytes: 8,
                    using: session
                )
                XCTFail("Expected \(path) to be rejected")
            } catch let violation as LocalEndpointSecurity.Violation {
                XCTAssertEqual(violation, .responseTooLarge)
            }
        }
    }

    func testBoundedTransportEnforcesLimitWhenContentLengthIsMissingOrLies() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }

        for path in ["missing-length", "lying-length"] {
            let request = URLRequest(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1/\(path)"))
            )
            do {
                _ = try await LocalEndpointSecurity.data(
                    for: request,
                    maximumResponseBytes: 8,
                    using: session
                )
                XCTFail("Expected \(path) to be rejected")
            } catch let violation as LocalEndpointSecurity.Violation {
                XCTAssertEqual(violation, .responseTooLarge)
            }
        }
    }

    func testBoundedTransportPreservesTaskCancellation() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/hanging")))
        let task = Task {
            try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled local response read must not complete successfully")
        } catch is CancellationError {
            // Expected: callers use structured cancellation to invalidate stale voice work.
        } catch {
            XCTFail("Cancellation was rewritten as \(error)")
        }
    }

    func testBoundedTransportRevalidatesTheResponseURLBeforeReadingItsBody() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/remote-response"))
        )

        do {
            _ = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("A response attributed to a remote URL must be refused")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .nonLoopbackHost)
        }
    }

    func testEmptyBodyReturnsEmptyData() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/empty")))

        let (data, response) = try await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: 8,
            using: session
        )

        XCTAssertEqual(data, Data())
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testChunkedBodyAtTheExactLimitSucceeds() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/chunked-exact")))

        let (data, _) = try await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: 8,
            using: session
        )

        XCTAssertEqual(data, Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    func testChunkedBodyOneByteOverTheCapCancels() async throws {
        BoundedLocalResponseURLProtocol.resetStops()
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/chunked-over")))

        do {
            _ = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("A body split across chunks must still stop at the cap")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .responseTooLarge)
        }

        let clock = ContinuousClock()
        let started = clock.now
        while !BoundedLocalResponseURLProtocol.didStop("/chunked-over") {
            if clock.now - started > .seconds(1) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            BoundedLocalResponseURLProtocol.didStop("/chunked-over"),
            "Crossing the cap must cancel the task, not keep the extra chunk"
        )
    }

    func testInvalidResponseLimitAndMissingURLAreRejectedBeforeTransport() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1/exact"))

        for limit in [0, -1] {
            do {
                _ = try await LocalEndpointSecurity.data(
                    for: URLRequest(url: url),
                    maximumResponseBytes: limit,
                    using: session
                )
                XCTFail("A non-positive limit must be rejected")
            } catch let violation as LocalEndpointSecurity.Violation {
                XCTAssertEqual(violation, .invalidResponseLimit)
            }
        }

        var missing = URLRequest(url: url)
        missing.url = nil
        do {
            _ = try await LocalEndpointSecurity.data(
                for: missing,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("A request without a URL must be rejected")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .missingURL)
        }
    }

    func testDelegateBearingSessionEnforcesTheCap() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }

        let exact = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/exact")))
        let (data, _) = try await LocalEndpointSecurity.data(
            for: exact,
            maximumResponseBytes: 8,
            using: session
        )
        XCTAssertEqual(data, Data(repeating: 0x41, count: 8))

        let over = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/limit-plus-one")))
        do {
            _ = try await LocalEndpointSecurity.data(
                for: over,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("The production delegate must reject limit + 1")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .responseTooLarge)
        }
    }

    func testProductionReadDoesNotAwaitEachByte() throws {
        let source = try SourceTree.text("Sources/ExpanderEngine/Voice/LocalEndpointSecurity.swift")
        let body = try SourceTree.functionBody("using session: URLSession", in: source)
        XCTAssertFalse(
            body.contains("for try await byte"),
            "The bounded read must await one buffer at a time, not one byte"
        )
    }

    /// Min of 10 interleaved runs. The byte arm is the old per-byte loop, kept only here.
    /// Payload is 1 MiB. Final run on 2026-11-02: byteMinMs=26.086, bufferMinMs=0.185,
    /// byteSpreadMs=1.997, bufferSpreadMs=0.166. The gap is larger than either spread.
    func testBoundedReadIsNotSlowerThanTheOneByteLoop() async throws {
        let payload = BoundedLocalResponseURLProtocol.benchmarkPayload
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedLocalResponseURLProtocol.self]
        let byteSession = URLSession(configuration: configuration)
        let bufferSession = makeDelegateBearingSession()
        defer {
            byteSession.invalidateAndCancel()
            bufferSession.invalidateAndCancel()
        }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/benchmark")))
        let limit = payload.count

        let warmedByte = try await readOneByteAtATime(
            request,
            maximumResponseBytes: limit,
            session: byteSession
        )
        let (warmedBuffer, _) = try await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: limit,
            using: bufferSession
        )
        XCTAssertEqual(warmedByte, payload)
        XCTAssertEqual(warmedBuffer, payload)

        let rounds = 10
        var byteSamples: [Duration] = []
        var bufferSamples: [Duration] = []
        byteSamples.reserveCapacity(rounds)
        bufferSamples.reserveCapacity(rounds)
        let clock = ContinuousClock()

        for index in 0..<rounds {
            let measureByte = {
                try await self.timed(clock) {
                    try await self.readOneByteAtATime(
                        request,
                        maximumResponseBytes: limit,
                        session: byteSession
                    )
                }
            }
            let measureBuffer = {
                try await self.timed(clock) {
                    let (data, _) = try await LocalEndpointSecurity.data(
                        for: request,
                        maximumResponseBytes: limit,
                        using: bufferSession
                    )
                    return data
                }
            }
            if index.isMultiple(of: 2) {
                byteSamples.append(try await measureByte())
                bufferSamples.append(try await measureBuffer())
            } else {
                bufferSamples.append(try await measureBuffer())
                byteSamples.append(try await measureByte())
            }
        }

        let byteMs = byteSamples.map(Self.milliseconds)
        let bufferMs = bufferSamples.map(Self.milliseconds)
        let byteMin = try XCTUnwrap(byteMs.min())
        let bufferMin = try XCTUnwrap(bufferMs.min())
        let byteSpread = (byteMs.max() ?? byteMin) - byteMin
        let bufferSpread = (bufferMs.max() ?? bufferMin) - bufferMin
        print(String(
            format: "endpoint-chunk-bench n=%d payload=%d byteMinMs=%.3f bufferMinMs=%.3f byteSpreadMs=%.3f bufferSpreadMs=%.3f",
            rounds,
            payload.count,
            byteMin,
            bufferMin,
            byteSpread,
            bufferSpread
        ))
        XCTAssertLessThanOrEqual(
            bufferMin,
            byteMin * 1.05,
            String(
                format: "buffer min %.3f ms was more than 5%% slower than the byte-loop min %.3f ms (spreads %.3f / %.3f)",
                bufferMin,
                byteMin,
                bufferSpread,
                byteSpread
            )
        )
    }

    func testPreferencesRejectRemoteWritesAndHealStaleRemoteDefaults() throws {
        let local = try XCTUnwrap(URL(string: "http://localhost:1234/v1/chat/completions"))
        let remote = try XCTUnwrap(URL(string: "https://example.com/v1/chat/completions"))

        XCTAssertTrue(VoicePreferences.setLocalLLMEndpoint(local))
        XCTAssertFalse(VoicePreferences.setLocalLLMEndpoint(remote))
        XCTAssertEqual(VoicePreferences.localLLMEndpoint, local)

        UserDefaults.standard.set(remote.absoluteString, forKey: VoicePreferences.localLLMEndpointKey)
        XCTAssertEqual(VoicePreferences.localLLMEndpoint, VoicePreferences.defaultLocalLLMEndpoint)
        XCTAssertNil(UserDefaults.standard.string(forKey: VoicePreferences.localLLMEndpointKey))

        UserDefaults.standard.set(remote.absoluteString, forKey: VoicePreferences.whisperEndpointKey)
        XCTAssertEqual(VoicePreferences.whisperEndpoint, VoicePreferences.defaultWhisperEndpoint)
        XCTAssertNil(UserDefaults.standard.string(forKey: VoicePreferences.whisperEndpointKey))
    }

    func testEveryLocalProviderRefusesRemoteEndpointBeforeReadinessOrContentEgress() async throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/collect"))
        let correctors: [any TranscriptCorrector] = [
            OllamaCorrector(endpointURL: remote),
            OpenAICompatibleCorrector(endpointURL: remote),
        ]

        for corrector in correctors {
            let readiness = await corrector.probe()
            XCTAssertEqual(readiness, .requiresConfiguration(.invalidEndpointFormat))
            do {
                _ = try await corrector.correct(
                    VoiceFixtures.correctionRequest("private dictated transcript", privacyRoute: .localNetworkOnly)
                )
                XCTFail("\(corrector.descriptor.id) sent content to a non-loopback endpoint")
            } catch let failure as VoiceFailure {
                XCTAssertEqual(failure.code, .endpointUnreachable)
                XCTAssertEqual(failure.userAction, .configureEndpoint)
            } catch {
                XCTFail("Expected a structured local-endpoint refusal, got \(error)")
            }
        }

        let whisperReachable = await WhisperServerSetup.isReachable(endpoint: remote, timeout: 30)
        XCTAssertFalse(whisperReachable)
        let models = await LocalLLMModelCatalog.shared.fetchAvailableLocalModels(endpoint: remote)
        XCTAssertEqual(models, [])

        let serverStart = await WhisperServerController.shared.start(endpoint: remote)
        guard case .failure(.invalidEndpoint) = serverStart else {
            return XCTFail("A remote endpoint reached Whisper server startup: \(serverStart)")
        }
    }

    private func makeBoundedTransportSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedLocalResponseURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Same protocol stack as the injected session, but with the production data delegate so the
    /// benchmark and the cap tests exercise the session shape `LocalEndpointSecurity.session` uses.
    private func makeDelegateBearingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedLocalResponseURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: LocalEndpointURLSessionDelegate.shared,
            delegateQueue: nil
        )
    }

    /// The pre-change read. Production must not keep this loop; the benchmark compares against it.
    private func readOneByteAtATime(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        session: URLSession
    ) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            bytes.task.cancel()
            throw LocalEndpointSecurity.Violation.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 16 * 1024))
        for try await byte in bytes {
            if Task.isCancelled {
                bytes.task.cancel()
                throw CancellationError()
            }
            guard data.count < maximumResponseBytes else {
                bytes.task.cancel()
                throw LocalEndpointSecurity.Violation.responseTooLarge
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    private func timed(
        _ clock: ContinuousClock,
        _ body: () async throws -> Data
    ) async throws -> Duration {
        let start = clock.now
        let data = try await body()
        let elapsed = clock.now - start
        XCTAssertEqual(data.count, BoundedLocalResponseURLProtocol.benchmarkPayload.count)
        return elapsed
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

private final class BoundedLocalResponseURLProtocol: URLProtocol, @unchecked Sendable {
    static let benchmarkPayload = Data(repeating: 0x5A, count: 1024 * 1024)

    private static let stopLock = NSLock()
    private static var stoppedPaths = Set<String>()

    static func resetStops() {
        stopLock.lock()
        stoppedPaths.removeAll()
        stopLock.unlock()
    }

    static func didStop(_ path: String) -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stoppedPaths.contains(path)
    }

    private let gate = NSLock()
    private var closed = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch requestURL.path {
        case "/exact":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "8"],
                chunks: [Data(repeating: 0x41, count: 8)],
                staggerTail: false
            )
        case "/limit-plus-one":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x42, count: 9)],
                staggerTail: false
            )
        case "/declared-oversize":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "9"],
                chunks: [],
                staggerTail: false
            )
        case "/missing-length":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x43, count: 9)],
                staggerTail: false
            )
        case "/lying-length":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "1"],
                chunks: [Data(repeating: 0x44, count: 9)],
                staggerTail: false
            )
        case "/hanging":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x45, count: 1)],
                staggerTail: false,
                finish: false
            )
        case "/remote-response":
            deliver(
                responseURL: URL(string: "https://example.invalid/collect")!,
                headers: nil,
                chunks: [Data(repeating: 0x46, count: 1)],
                staggerTail: false
            )
        case "/empty":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "0"],
                chunks: [],
                staggerTail: false
            )
        case "/chunked-exact":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "8"],
                chunks: [Data([1, 2, 3]), Data([4, 5, 6, 7, 8])],
                staggerTail: true
            )
        case "/chunked-over":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x47, count: 4), Data(repeating: 0x47, count: 5)],
                staggerTail: true
            )
        case "/benchmark":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": String(Self.benchmarkPayload.count)],
                chunks: [Self.benchmarkPayload],
                staggerTail: false
            )
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }

    override func stopLoading() {
        if let path = request.url?.path {
            Self.stopLock.lock()
            Self.stoppedPaths.insert(path)
            Self.stopLock.unlock()
        }
        guard markClosed() else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    private func deliver(
        responseURL: URL,
        headers: [String: String]?,
        chunks: [Data],
        staggerTail: Bool,
        finish: Bool = true
    ) {
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let client = self.client
        let send: (Data) -> Void = { chunk in
            if !chunk.isEmpty {
                client?.urlProtocol(self, didLoad: chunk)
            }
        }
        if !staggerTail || chunks.count < 2 {
            for chunk in chunks {
                send(chunk)
            }
            if finish {
                finishIfOpen()
            }
            return
        }
        send(chunks[0])
        let tail = Array(chunks.dropFirst())
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(30)) {
            for chunk in tail {
                send(chunk)
            }
            if finish {
                self.finishIfOpen()
            }
        }
    }

    private func finishIfOpen() {
        guard markClosed() else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func markClosed() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        if closed { return false }
        closed = true
        return true
    }
}
