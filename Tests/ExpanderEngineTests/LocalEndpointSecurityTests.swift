import Foundation
import XCTest
@testable import ExpanderEngine

final class LocalEndpointSecurityTests: XCTestCase {
    override func tearDown() {
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
}

private final class BoundedLocalResponseURLProtocol: URLProtocol, @unchecked Sendable {
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

        let responseURL: URL
        let headers: [String: String]?
        let body: Data
        let shouldFinish: Bool
        switch requestURL.path {
        case "/exact":
            responseURL = requestURL
            headers = ["Content-Length": "8"]
            body = Data(repeating: 0x41, count: 8)
            shouldFinish = true
        case "/limit-plus-one":
            responseURL = requestURL
            headers = nil
            body = Data(repeating: 0x42, count: 9)
            shouldFinish = true
        case "/declared-oversize":
            responseURL = requestURL
            headers = ["Content-Length": "9"]
            body = Data()
            shouldFinish = true
        case "/missing-length":
            responseURL = requestURL
            headers = nil
            body = Data(repeating: 0x43, count: 9)
            shouldFinish = true
        case "/lying-length":
            responseURL = requestURL
            headers = ["Content-Length": "1"]
            body = Data(repeating: 0x44, count: 9)
            shouldFinish = true
        case "/hanging":
            responseURL = requestURL
            headers = nil
            body = Data(repeating: 0x45, count: 1)
            shouldFinish = false
        case "/remote-response":
            responseURL = URL(string: "https://example.invalid/collect")!
            headers = nil
            body = Data(repeating: 0x46, count: 1)
            shouldFinish = true
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        if shouldFinish {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
