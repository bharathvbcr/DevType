import XCTest
@testable import ExpanderEngine

final class GeminiTranscriptionClientTests: XCTestCase {

    func testMissingAPIKeyThrowsError() async {
        let client = GeminiTranscriptionClient()
        let dummyData = Data([0x00, 0x01, 0x02])

        do {
            _ = try await client.transcribe(
                audioData: dummyData,
                mimeType: "audio/flac",
                audioDurationSeconds: 1.0,
                steeringPrompt: "Transcribe",
                apiKey: "",
                uploadAuthorized: { true }
            )
            XCTFail("Expected noAPIKey error")
        } catch let error as GeminiTranscriptionError {
            XCTAssertEqual(error, .noAPIKey)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testErrorEnumEquality() {
        XCTAssertEqual(GeminiTranscriptionError.noAPIKey, GeminiTranscriptionError.noAPIKey)
        XCTAssertEqual(GeminiTranscriptionError.invalidAPIKey, GeminiTranscriptionError.invalidAPIKey)
        XCTAssertEqual(GeminiTranscriptionError.modelAccessDenied, GeminiTranscriptionError.modelAccessDenied)
        XCTAssertEqual(GeminiTranscriptionError.rateLimited, GeminiTranscriptionError.rateLimited)
        XCTAssertEqual(GeminiTranscriptionError.quotaExhausted, GeminiTranscriptionError.quotaExhausted)
        XCTAssertEqual(GeminiTranscriptionError.timeout, GeminiTranscriptionError.timeout)
        XCTAssertEqual(GeminiTranscriptionError.safetyBlocked, GeminiTranscriptionError.safetyBlocked)
        XCTAssertEqual(GeminiTranscriptionError.emptyTranscript, GeminiTranscriptionError.emptyTranscript)
        XCTAssertEqual(
            GeminiTranscriptionError.uploadNotAuthorized,
            GeminiTranscriptionError.uploadNotAuthorized
        )
    }

    func testAPIKeyValidationResultProperties() {
        let valid = APIKeyValidationResult.valid(modelName: "gemini-3.5-transcribe")
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.userMessage, "Key Valid & Saved")

        let invalid = APIKeyValidationResult.invalidKey(reason: "API key is invalid")
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.userMessage, "API key is invalid")

        let rateLimited = APIKeyValidationResult.rateLimited
        XCTAssertFalse(rateLimited.isValid)
        XCTAssertEqual(rateLimited.userMessage, "API Rate Limited (429)")

        let quota = APIKeyValidationResult.quotaExhausted
        XCTAssertFalse(quota.isValid)
        XCTAssertEqual(quota.userMessage, "Quota Exhausted")

        let network = APIKeyValidationResult.networkError(reason: "No connection")
        XCTAssertFalse(network.isValid)
        XCTAssertEqual(network.userMessage, "Network Error: No connection")
    }

    func testEmptyAndMalformedAPIKeyValidation() async {
        let client = GeminiTranscriptionClient()

        let emptyResult = await client.validateAPIKeyDetailed("")
        XCTAssertFalse(emptyResult.isValid)
        if case .invalidKey(let reason) = emptyResult {
            XCTAssertTrue(reason.contains("empty"))
        } else {
            XCTFail("Expected invalidKey for empty input")
        }

        let whitespaceResult = await client.validateAPIKeyDetailed("   ")
        XCTAssertFalse(whitespaceResult.isValid)

        let malformedResult = await client.validateAPIKeyDetailed("key with spaces")
        XCTAssertFalse(malformedResult.isValid)

        let shortResult = await client.validateAPIKeyDetailed("short")
        XCTAssertFalse(shortResult.isValid)
    }

    func testAPIKeyValidationBoundsResponseAndDoesNotSurfaceProviderBody() async {
        let exactBody = GeminiSSEURLProtocol.responseBody(for: "/validation-valid")
        let exactClient = makeValidationClient(
            path: "/validation-valid",
            maximumResponseBytes: exactBody.count
        )
        let exact = await exactClient.validateAPIKeyDetailed("test-key-long-enough")
        XCTAssertEqual(exact, .valid(modelName: "gemini-3.5-transcribe"))

        let oversizedClient = makeValidationClient(
            path: "/validation-valid",
            maximumResponseBytes: exactBody.count - 1
        )
        let oversized = await oversizedClient.validateAPIKeyDetailed("test-key-long-enough")
        XCTAssertEqual(
            oversized,
            .networkError(reason: "Validation response exceeded the safe size limit")
        )

        let rejectedClient = makeValidationClient(
            path: "/validation-invalid",
            maximumResponseBytes: 1_024
        )
        let rejected = await rejectedClient.validateAPIKeyDetailed("test-key-long-enough")
        XCTAssertEqual(rejected, .invalidKey(reason: "API key is invalid or unauthorized"))
        XCTAssertFalse(rejected.userMessage.contains("provider-controlled-secret"))
    }

    func testSSETransportAcceptsAnExactResponseBudget() async throws {
        let body = GeminiSSEURLProtocol.responseBody(for: "/exact")
        let client = makeClient(path: "/exact", maximumResponseBytes: body.count)

        let result = try await client.transcribe(
            audioData: Data([1]),
            mimeType: "audio/flac",
            audioDurationSeconds: 0.01,
            steeringPrompt: "Transcribe",
            apiKey: "test-key",
            uploadAuthorized: { true }
        )

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.rawText, "hello")
    }

    func testSSETransportRejectsLimitPlusOneWithoutRetrying() async throws {
        let body = GeminiSSEURLProtocol.responseBody(for: "/exact")
        let client = makeClient(path: "/exact", maximumResponseBytes: body.count - 1)

        do {
            _ = try await client.transcribe(
                audioData: Data([1]),
                mimeType: "audio/flac",
                audioDurationSeconds: 0.01,
                steeringPrompt: "Transcribe",
                apiKey: "test-key",
                uploadAuthorized: { true }
            )
            XCTFail("An oversized SSE response must be rejected")
        } catch let error as GeminiTranscriptionError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testMalformedSSEFixtureFailsAsAnEmptyTranscript() async throws {
        let body = GeminiSSEURLProtocol.responseBody(for: "/malformed")
        let client = makeClient(path: "/malformed", maximumResponseBytes: body.count)

        do {
            _ = try await client.transcribe(
                audioData: Data([1]),
                mimeType: "audio/flac",
                audioDurationSeconds: 0.01,
                steeringPrompt: "Transcribe",
                apiKey: "test-key",
                uploadAuthorized: { true }
            )
            XCTFail("Malformed SSE must not produce a transcript")
        } catch let error as GeminiTranscriptionError {
            XCTAssertEqual(error, .emptyTranscript)
        }
    }

    func testValidSSEWithoutTerminalMarkerStillReturnsTranscriptAtEOF() async throws {
        let body = GeminiSSEURLProtocol.responseBody(for: "/no-terminal")
        let client = makeClient(path: "/no-terminal", maximumResponseBytes: body.count)

        let result = try await client.transcribe(
            audioData: Data([1]),
            mimeType: "audio/flac",
            audioDurationSeconds: 0.01,
            steeringPrompt: "Transcribe",
            apiKey: "test-key",
            uploadAuthorized: { true }
        )

        XCTAssertEqual(result.text, "complete without marker")
    }

    func testSSETransportPreservesStructuredCancellation() async throws {
        let client = makeClient(path: "/hanging", maximumResponseBytes: 1024)
        let task = Task {
            try await client.transcribe(
                audioData: Data([1]),
                mimeType: "audio/flac",
                audioDurationSeconds: 0.01,
                steeringPrompt: "Transcribe",
                apiKey: "test-key",
                uploadAuthorized: { true }
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled SSE work must not retry or become a network failure")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Cancellation was rewritten as \(error)")
        }
    }

    func testRejectedHTTPResponsesCancelEachBodyBeforeRetrying() async throws {
        let path = "/server-error-\(UUID().uuidString)"
        let stopped = expectation(description: "Both rejected response bodies were cancelled")
        stopped.expectedFulfillmentCount = 2
        GeminiSSEProtocolState.shared.observeStops(for: path, expectation: stopped)
        defer { GeminiSSEProtocolState.shared.reset(path: path) }
        let client = makeClient(path: path, maximumResponseBytes: 1024)

        do {
            _ = try await client.transcribe(
                audioData: Data([1]),
                mimeType: "audio/flac",
                audioDurationSeconds: 0.01,
                steeringPrompt: "Transcribe",
                apiKey: "test-key",
                uploadAuthorized: { true }
            )
            XCTFail("A 5xx response must fail after the bounded retry")
        } catch let error as GeminiTranscriptionError {
            guard case .networkError = error else {
                return XCTFail("Unexpected typed error: \(error)")
            }
        }

        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(GeminiSSEProtocolState.shared.starts(for: path), 2)
        XCTAssertEqual(GeminiSSEProtocolState.shared.stops(for: path), 2)
    }

    func testRevokedUploadAuthorizationStopsBeforeRetryingAudio() async throws {
        let path = "/server-error-consent-\(UUID().uuidString)"
        defer { GeminiSSEProtocolState.shared.reset(path: path) }
        let client = makeClient(path: path, maximumResponseBytes: 1_024)

        do {
            _ = try await client.transcribe(
                audioData: Data([1]),
                mimeType: "audio/flac",
                audioDurationSeconds: 0.01,
                steeringPrompt: "Transcribe",
                apiKey: "test-key",
                uploadAuthorized: {
                    GeminiSSEProtocolState.shared.starts(for: path) == 0
                }
            )
            XCTFail("Revoked consent must prevent the retry upload")
        } catch let error as GeminiTranscriptionError {
            XCTAssertEqual(error, .uploadNotAuthorized)
        }

        XCTAssertEqual(GeminiSSEProtocolState.shared.starts(for: path), 1)
    }

    func testCancellationDuringRetryAuthorizationWinsBeforeAnotherUpload() async throws {
        let path = "/server-error-cancel-auth-\(UUID().uuidString)"
        let secondCheckEntered = expectation(description: "retry authorization check entered")
        let authorization = RetryUploadAuthorization(secondCheckEntered: secondCheckEntered)
        defer {
            authorization.releaseSecondCheck()
            GeminiSSEProtocolState.shared.reset(path: path)
        }
        let client = makeClient(path: path, maximumResponseBytes: 1_024)
        let task = Task {
            try await client.transcribe(
                audioData: Data([1]),
                mimeType: "audio/flac",
                audioDurationSeconds: 0.01,
                steeringPrompt: "Transcribe",
                apiKey: "test-key",
                uploadAuthorized: { authorization.check() }
            )
        }

        await fulfillment(of: [secondCheckEntered], timeout: 1)
        task.cancel()
        authorization.releaseSecondCheck()

        do {
            _ = try await task.value
            XCTFail("Cancellation during authorization must stop before the retry upload")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Cancellation was rewritten as \(error)")
        }
        XCTAssertEqual(GeminiSSEProtocolState.shared.starts(for: path), 1)
    }

    private func makeClient(path: String, maximumResponseBytes: Int) -> GeminiTranscriptionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiSSEURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return GeminiTranscriptionClient(
            session: session,
            baseURL: URL(string: "https://generativelanguage.googleapis.com\(path)")!,
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private func makeValidationClient(
        path: String,
        maximumResponseBytes: Int
    ) -> GeminiTranscriptionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiSSEURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return GeminiTranscriptionClient(
            session: session,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/transcribe")!,
            maximumResponseBytes: 1_024,
            validationURL: URL(string: "https://generativelanguage.googleapis.com\(path)")!,
            maximumValidationResponseBytes: maximumResponseBytes
        )
    }
}

private final class RetryUploadAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var checkCount = 0
    private let secondCheckEntered: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)

    init(secondCheckEntered: XCTestExpectation) {
        self.secondCheckEntered = secondCheckEntered
    }

    func check() -> Bool {
        let count = lock.withLock {
            checkCount += 1
            return checkCount
        }
        if count == 2 {
            secondCheckEntered.fulfill()
            release.wait()
        }
        return true
    }

    func releaseSecondCheck() {
        release.signal()
    }
}

private final class GeminiSSEURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func responseBody(for path: String) -> Data {
        let line: String
        switch path {
        case "/exact":
            line = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hello\"}]}}]}\n\ndata: [DONE]\n\n"
        case "/malformed":
            line = "data: {not-json}\n\n"
        case "/no-terminal":
            line = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"complete without marker\"}]}}]}\n\n"
        case "/validation-valid":
            line = "{\"models\":[]}"
        case "/validation-invalid":
            line = "{\"error\":{\"message\":\"provider-controlled-secret\"}}"
        default:
            line = ""
        }
        return Data(line.utf8)
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isServerError = url.path.hasPrefix("/server-error-")
        let isInvalidValidation = url.path == "/validation-invalid"
        GeminiSSEProtocolState.shared.recordStart(path: url.path)
        let response = HTTPURLResponse(
            url: url,
            statusCode: isServerError ? 500 : (isInvalidValidation ? 401 : 200),
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/hanging" || isServerError {
            client?.urlProtocol(self, didLoad: Data("data: ".utf8))
            return
        }
        client?.urlProtocol(self, didLoad: Self.responseBody(for: url.path))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if let path = request.url?.path {
            GeminiSSEProtocolState.shared.recordStop(path: path)
        }
    }
}

private final class GeminiSSEProtocolState: @unchecked Sendable {
    static let shared = GeminiSSEProtocolState()

    private let lock = NSLock()
    private var startCounts: [String: Int] = [:]
    private var stopCounts: [String: Int] = [:]
    private var stopExpectations: [String: XCTestExpectation] = [:]

    func observeStops(for path: String, expectation: XCTestExpectation) {
        lock.withLock { stopExpectations[path] = expectation }
    }

    func recordStart(path: String) {
        lock.withLock { startCounts[path, default: 0] += 1 }
    }

    func recordStop(path: String) {
        let expectation = lock.withLock { () -> XCTestExpectation? in
            stopCounts[path, default: 0] += 1
            return stopExpectations[path]
        }
        expectation?.fulfill()
    }

    func starts(for path: String) -> Int { lock.withLock { startCounts[path, default: 0] } }
    func stops(for path: String) -> Int { lock.withLock { stopCounts[path, default: 0] } }

    func reset(path: String) {
        lock.withLock {
            startCounts[path] = nil
            stopCounts[path] = nil
            stopExpectations[path] = nil
        }
    }
}
