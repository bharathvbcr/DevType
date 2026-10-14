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

    func testProductionSessionDoesNotFollowCrossHostRedirect() async {
        let id = UUID().uuidString
        let origin = URL(string: "https://generativelanguage.googleapis.com/redirect-cross/\(id)")!
        let location = URL(string: "https://evil.example/collect/\(id)")!
        await assertProductionSessionRefusesRedirect(from: origin, to: location)
    }

    func testProductionSessionDoesNotFollowSameHostRedirect() async {
        let id = UUID().uuidString
        let origin = URL(string: "https://generativelanguage.googleapis.com/redirect-same/\(id)")!
        let location = URL(string: "https://generativelanguage.googleapis.com/collect/\(id)")!
        await assertProductionSessionRefusesRedirect(from: origin, to: location)
    }

    func testProductionSessionDoesNotFollow301CrossHostRedirect() async {
        await assertAttackRedirectRefused(kind: "301-cross")
    }

    func testProductionSessionDoesNotFollow303CrossHostRedirect() async {
        await assertAttackRedirectRefused(kind: "303-cross")
    }

    func testProductionSessionDoesNotFollow307CrossHostRedirect() async {
        await assertAttackRedirectRefused(kind: "307-cross")
    }

    func testProductionSessionDoesNotFollow308CrossHostRedirect() async {
        await assertAttackRedirectRefused(kind: "308-cross")
    }

    func testProductionSessionDoesNotFollow307SameHostRedirect() async {
        await assertAttackRedirectRefused(kind: "307-same")
    }

    func testProductionSessionDoesNotFollowRelativeLocation() async {
        await assertAttackRedirectRefused(kind: "relative")
    }

    func testProductionSessionDoesNotFollowHTTPDowngrade() async {
        await assertAttackRedirectRefused(kind: "downgrade")
    }

    func testRedirectBodyIsNotReturnedAsTranscript() async {
        await assertAttackRedirectRefused(kind: "transcript")
    }

    func testAPIKeyHeaderIsRecordedOnlyForOriginURL() async {
        await assertAttackRedirectRefused(kind: "apikey")
    }

    func testRedirectLoopFinishesWithoutFollowing() async {
        let id = UUID().uuidString
        let origin = GeminiAttackRedirect.origin(kind: "loop", id: id)
        let location = GeminiAttackRedirect.location(kind: "loop", id: id)
        let apiKey = "gemini-key-\(id)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiRedirectURLProtocol.self]
        let session = GeminiTranscriptionClient.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GeminiTranscriptionClient(
            session: session,
            baseURL: origin,
            maximumResponseBytes: 1_024
        )

        let outcome = await withTaskGroup(of: GeminiRedirectCall.self) { group in
            group.addTask {
                await Self.transcribeAttack(client: client, apiKey: apiKey)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        let originHits = GeminiRedirectURLProtocol.hits(where: { $0.absoluteString == origin.absoluteString })
        let locationHits = GeminiRedirectURLProtocol.hits(where: {
            GeminiAttackRedirect.isLocation($0, id: id, location: location)
        })
        switch outcome {
        case .timedOut:
            XCTFail("redirect loop did not finish within 5s origin=\(originHits) location=\(locationHits)")
        case .transcript(let text):
            XCTFail("redirect loop returned transcript \(text)")
        case .other(let description):
            XCTFail("redirect loop failed as \(description)")
        case .network(let reason):
            XCTAssertEqual(reason, "HTTP status 302")
        }
        XCTAssertTrue((1...2).contains(originHits), "origin hits \(originHits)")
        XCTAssertEqual(locationHits, 0, "redirect loop followed \(location.absoluteString)")
        assertHeadersRecordedOnlyForOrigin(id: id, origin: origin, apiKey: apiKey)
    }

    private func assertProductionSessionRefusesRedirect(from origin: URL, to location: URL) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiRedirectURLProtocol.self]
        let session = GeminiTranscriptionClient.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        XCTAssertTrue(session.delegate === LocalEndpointURLSessionDelegate.shared)
        let client = GeminiTranscriptionClient(
            session: session,
            baseURL: origin,
            maximumResponseBytes: 1_024
        )

        do {
            _ = try await client.transcribe(
                audioData: Data([1]),
                mimeType: "audio/flac",
                audioDurationSeconds: 0.01,
                steeringPrompt: "Transcribe",
                apiKey: "test-key",
                uploadAuthorized: { true }
            )
            XCTFail("A 3xx response must fail the transcription")
        } catch let error as GeminiTranscriptionError {
            guard case .networkError(let reason) = error else {
                return XCTFail("A 3xx response must fail as a network error, got \(error)")
            }
            XCTAssertTrue(reason.contains("302"), "Unexpected failure: \(reason)")
        } catch {
            XCTFail("A 3xx response must fail as a network error, got \(error)")
        }

        XCTAssertEqual(
            GeminiRedirectURLProtocol.hits(where: { $0.absoluteString == location.absoluteString }),
            0,
            "Redirect target must receive zero requests: \(location.absoluteString)"
        )
    }

    private func assertAttackRedirectRefused(kind: String) async {
        let id = UUID().uuidString
        let origin = GeminiAttackRedirect.origin(kind: kind, id: id)
        let location = GeminiAttackRedirect.location(kind: kind, id: id)
        let status = GeminiAttackRedirect.status(kind: kind)
        let apiKey = "gemini-key-\(id)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiRedirectURLProtocol.self]
        let session = GeminiTranscriptionClient.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        XCTAssertTrue(session.delegate === LocalEndpointURLSessionDelegate.shared)
        let client = GeminiTranscriptionClient(
            session: session,
            baseURL: origin,
            maximumResponseBytes: 4_096
        )

        let outcome = await Self.transcribeAttack(client: client, apiKey: apiKey)
        switch outcome {
        case .network(let reason):
            XCTAssertEqual(reason, "HTTP status \(status)")
        case .transcript(let text):
            XCTFail("\(kind) redirect returned transcript \(text)")
        case .other(let description):
            XCTFail("\(kind) redirect failed as \(description)")
        case .timedOut:
            XCTFail("\(kind) redirect did not finish")
        }

        let originHits = GeminiRedirectURLProtocol.hits(where: { $0.absoluteString == origin.absoluteString })
        XCTAssertTrue((1...2).contains(originHits), "\(kind) origin hits \(originHits)")
        XCTAssertEqual(
            GeminiRedirectURLProtocol.hits(where: { GeminiAttackRedirect.isLocation($0, id: id, location: location) }),
            0,
            "\(kind) location received a request: \(location.absoluteString)"
        )
        assertHeadersRecordedOnlyForOrigin(id: id, origin: origin, apiKey: apiKey)
    }

    private func assertHeadersRecordedOnlyForOrigin(id: String, origin: URL, apiKey: String) {
        let relevant = GeminiRedirectURLProtocol.exchanges(where: { $0.url.absoluteString.contains(id) })
        XCTAssertFalse(relevant.isEmpty, "no request headers were recorded for \(id)")
        for exchange in relevant {
            XCTAssertEqual(
                exchange.url.absoluteString,
                origin.absoluteString,
                "headers recorded for non-origin \(exchange.url.absoluteString): \(exchange.headers)"
            )
            XCTAssertEqual(exchange.headers["x-goog-api-key"], apiKey)
        }
    }

    private static func transcribeAttack(
        client: GeminiTranscriptionClient,
        apiKey: String
    ) async -> GeminiRedirectCall {
        do {
            let result = try await client.transcribe(
                audioData: Data([1]),
                mimeType: "audio/flac",
                audioDurationSeconds: 0.01,
                steeringPrompt: "Transcribe",
                apiKey: apiKey,
                uploadAuthorized: { true }
            )
            return .transcript(result.text)
        } catch let error as GeminiTranscriptionError {
            if case .networkError(let reason) = error {
                return .network(reason)
            }
            return .other(String(describing: error))
        } catch {
            return .other(String(describing: error))
        }
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

private enum GeminiRedirectCall: Sendable {
    case network(String)
    case transcript(String)
    case other(String)
    case timedOut
}

private struct GeminiRedirectExchange: Equatable {
    let url: URL
    let headers: [String: String]
}

private enum GeminiAttackRedirect {
    static func origin(kind: String, id: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/attack-redirect/\(kind)/\(id)")!
    }

    static func status(kind: String) -> Int {
        switch kind {
        case "301-cross":
            return 301
        case "303-cross":
            return 303
        case "307-cross", "307-same":
            return 307
        case "308-cross":
            return 308
        default:
            return 302
        }
    }

    static func location(kind: String, id: String) -> URL {
        switch kind {
        case "301-cross", "303-cross", "307-cross", "308-cross", "transcript", "apikey":
            return URL(string: "https://evil.example/collect/\(id)")!
        case "307-same", "relative":
            return URL(string: "https://generativelanguage.googleapis.com/collect/\(id)")!
        case "downgrade":
            return URL(string: "http://generativelanguage.googleapis.com/collect/\(id)")!
        case "loop":
            return URL(string: "https://generativelanguage.googleapis.com/attack-redirect/loop-next/\(id)")!
        case "loop-next":
            return URL(string: "https://generativelanguage.googleapis.com/attack-redirect/loop/\(id)")!
        default:
            preconditionFailure("unknown redirect attack \(kind)")
        }
    }

    static func locationHeader(kind: String, id: String) -> String {
        if kind == "relative" {
            return "/collect/\(id)"
        }
        return location(kind: kind, id: id).absoluteString
    }

    static func body(kind: String) -> Data {
        guard kind == "transcript" else { return Data() }
        return Data(
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hello\"}]}}]}\n\n".utf8
        )
    }

    static func isLocation(_ url: URL, id: String, location: URL) -> Bool {
        let path = url.path.count > 1 && url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        if path == "/collect/\(id)" {
            return true
        }
        let locationPath = location.path.count > 1 && location.path.hasSuffix("/")
            ? String(location.path.dropLast())
            : location.path
        return url.scheme == location.scheme
            && url.host?.lowercased() == location.host?.lowercased()
            && path == locationPath
    }

    static func kindAndID(from url: URL) -> (kind: String, id: String)? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "attack-redirect" else { return nil }
        return (parts[1], parts[2])
    }
}

private final class GeminiRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var hitURLs: [URL] = []
    private static var recordedExchanges: [GeminiRedirectExchange] = []

    static func hits(where matches: (URL) -> Bool) -> Int {
        lock.withLock { hitURLs.filter(matches).count }
    }

    static func exchanges(where matches: (GeminiRedirectExchange) -> Bool) -> [GeminiRedirectExchange] {
        lock.withLock { recordedExchanges.filter(matches) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let headers = Self.headerFields(from: request)
        Self.lock.withLock {
            Self.hitURLs.append(url)
            Self.recordedExchanges.append(GeminiRedirectExchange(url: url, headers: headers))
        }
        if let attack = GeminiAttackRedirect.kindAndID(from: url) {
            let response = HTTPURLResponse(
                url: url,
                statusCode: GeminiAttackRedirect.status(kind: attack.kind),
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": GeminiAttackRedirect.locationHeader(kind: attack.kind, id: attack.id)]
            )!
            var redirected = URLRequest(url: GeminiAttackRedirect.location(kind: attack.kind, id: attack.id))
            redirected.httpMethod = request.httpMethod
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
            let body = GeminiAttackRedirect.body(kind: attack.kind)
            let client = self.client
            DispatchQueue.global().async {
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        if url.path.hasPrefix("/redirect-") {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectedLocation(for: url).absoluteString]
            )!
            let client = self.client
            let redirected = URLRequest(url: redirectedLocation(for: url))
            // wasRedirectedTo invokes the session delegate synchronously. Hopping off the
            // protocol's load stack lets that delegate refuse the redirect without deadlocking,
            // then delivers the original 302 when the refusal does not start a new load.
            DispatchQueue.global().async {
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("followed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func headerFields(from request: URLRequest) -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            fields[name.lowercased()] = value
        }
        if let apiKey = request.value(forHTTPHeaderField: "x-goog-api-key") {
            fields["x-goog-api-key"] = apiKey
        }
        return fields
    }

    private func redirectedLocation(for url: URL) -> URL {
        let id = url.lastPathComponent
        if url.path.contains("/redirect-cross/") {
            return URL(string: "https://evil.example/collect/\(id)")!
        }
        return URL(string: "https://generativelanguage.googleapis.com/collect/\(id)")!
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
