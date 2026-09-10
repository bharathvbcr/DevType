import Foundation
import XCTest
@testable import ExpanderEngine

final class VoiceSubsystemCoverageTests: XCTestCase {

    private final class MockCorrector: TranscriptCorrector, @unchecked Sendable {
        let descriptor: CorrectionProviderDescriptor
        var candidateToReturn: CorrectionCandidate?
        var errorToThrow: Error?

        init(id: String = "test.mock", candidate: CorrectionCandidate? = nil, error: Error? = nil) {
            self.descriptor = CorrectionProviderDescriptor(
                id: id,
                displayName: "Mock",
                modelVersion: "v1",
                privacyRoute: .onDeviceOnly,
                supportsStructuredOutput: false
            )
            self.candidateToReturn = candidate
            self.errorToThrow = error
        }

        func probe() async -> ProviderReadiness {
            .ready(ProviderEvidence(
                providerID: descriptor.id,
                modelVersion: descriptor.modelVersion,
                probeTimestamp: Date(),
                capabilities: []
            ))
        }

        func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
            if let errorToThrow { throw errorToThrow }
            return candidateToReturn ?? CorrectionCandidate(
                text: request.rawTranscript,
                providerID: descriptor.id,
                modelVersion: "v1",
                promptVersion: "v1"
            )
        }

        func cancel(sessionID: VoiceSessionID) async {}
    }

    // MARK: - CorrectionPipeline

    func testCorrectionPipelineAccepted() async {
        let raw = RawTranscript(
            text: "hello world",
            localeIdentifier: "en_US",
            providerID: "p1",
            modelVersion: "m1"
        )
        let candidate = CorrectionCandidate(
            text: "Hello world.",
            providerID: "test.mock",
            modelVersion: "v1",
            promptVersion: "v1"
        )
        let mock = MockCorrector(candidate: candidate)
        let finalTranscript = await CorrectionPipeline.execute(
            rawTranscript: raw,
            corrector: mock,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5.0),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )

        XCTAssertEqual(finalTranscript.text, "Hello world.")
        if case .accepted = finalTranscript.validationOutcome {
            // Expected
        } else {
            XCTFail("Expected accepted but got \(finalTranscript.validationOutcome)")
        }
    }

    func testCorrectionPipelineRejectedFallback() async {
        let raw = RawTranscript(
            text: "hello world",
            localeIdentifier: "en_US",
            providerID: "p1",
            modelVersion: "m1"
        )
        // Excessively long addition or completely divergent edit rejected by validator
        let candidate = CorrectionCandidate(
            text: "This is a completely fabricated sentence that should be rejected by the validation rules.",
            providerID: "test.mock",
            modelVersion: "v1",
            promptVersion: "v1"
        )
        let mock = MockCorrector(candidate: candidate)
        let finalTranscript = await CorrectionPipeline.execute(
            rawTranscript: raw,
            corrector: mock,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5.0),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )

        XCTAssertEqual(finalTranscript.text, raw.text)
        switch finalTranscript.validationOutcome {
        case .fallbackToRaw:
            break // Expected
        default:
            XCTFail("Expected fallbackToRaw but got \(finalTranscript.validationOutcome)")
        }

        // Test explicit .rejected with non-empty reason
        let rejectedCustom = await CorrectionPipeline.execute(
            rawTranscript: raw,
            corrector: mock,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5.0),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            validator: { _, _, _, _ in .rejected(reasons: [.correctionHallucination]) }
        )
        if case .fallbackToRaw(let reason) = rejectedCustom.validationOutcome {
            XCTAssertEqual(reason, .correctionHallucination)
        } else {
            XCTFail("Expected fallbackToRaw(.correctionHallucination) but got \(rejectedCustom.validationOutcome)")
        }

        // Test explicit .rejected with empty reason list
        let rejectedEmpty = await CorrectionPipeline.execute(
            rawTranscript: raw,
            corrector: mock,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5.0),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            validator: { _, _, _, _ in .rejected(reasons: []) }
        )
        if case .fallbackToRaw(let reason) = rejectedEmpty.validationOutcome {
            XCTAssertEqual(reason, .correctionUnsupportedEdit)
        } else {
            XCTFail("Expected fallbackToRaw(.correctionUnsupportedEdit) but got \(rejectedEmpty.validationOutcome)")
        }

        // Test explicit .notApplicable
        let notApplicable = await CorrectionPipeline.execute(
            rawTranscript: raw,
            corrector: mock,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5.0),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            validator: { _, _, _, _ in .notApplicable }
        )
        XCTAssertEqual(notApplicable.validationOutcome, .notApplicable)
    }

    func testCorrectionPipelineErrorFallback() async {
        let raw = RawTranscript(
            text: "hello world",
            localeIdentifier: "en_US",
            providerID: "p1",
            modelVersion: "m1"
        )
        let mock = MockCorrector(error: NSError(domain: "test", code: -1))
        let finalTranscript = await CorrectionPipeline.execute(
            rawTranscript: raw,
            corrector: mock,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5.0),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )

        XCTAssertEqual(finalTranscript.text, raw.text)
        if case .fallbackToRaw(let reason) = finalTranscript.validationOutcome {
            XCTAssertEqual(reason, .correctionTimeout)
        } else {
            XCTFail("Expected fallbackToRaw(correctionTimeout) but got \(finalTranscript.validationOutcome)")
        }
    }

    // MARK: - AITransformCorrector

    func testAITransformCorrectorBasics() async throws {
        XCTAssertEqual(AITransformCorrector.id(for: .proofread), "apple.transform.proofread")
        XCTAssertEqual(AITransformCorrector.id(for: .condense), "apple.transform.condense")
        XCTAssertTrue(AITransformCorrector.isTransformProvider("apple.transform.proofread"))
        XCTAssertFalse(AITransformCorrector.isTransformProvider("ollama.chat"))

        let corrector = AITransformCorrector(kind: .proofread)
        XCTAssertEqual(corrector.descriptor.id, "apple.transform.proofread")
        XCTAssertEqual(corrector.descriptor.privacyRoute, .onDeviceOnly)

        await corrector.cancel(sessionID: VoiceSessionID())
        _ = await corrector.probe()

        let request = CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: "hello there",
            locale: Locale(identifier: "en_US"),
            policy: CorrectionPolicy(),
            protectedSpans: [],
            deadline: Date().addingTimeInterval(5.0),
            privacyRoute: .onDeviceOnly
        )
        let candidate = try await corrector.correct(request)
        XCTAssertFalse(candidate.text.isEmpty)
    }

    // MARK: - CorrectionProviderRegistry

    func testCorrectionProviderRegistryOperations() async {
        let registry = CorrectionProviderRegistry()
        let descriptors = await registry.descriptors()
        XCTAssertFalse(descriptors.isEmpty)

        let det = await registry.corrector(for: DeterministicCorrector.providerID)
        XCTAssertNotNil(det)

        let unknown = await registry.corrector(for: "nonexistent.corrector")
        XCTAssertNil(unknown)

        let available = await registry.availableProviders(for: .onDeviceOnly)
        XCTAssertFalse(available.isEmpty)

        let disabled = await registry.resolveActiveCorrector(
            preferredID: CorrectionProviderRegistry.disabledID,
            privacyRoute: .onDeviceOnly
        )
        XCTAssertNil(disabled)

        let nilPreferred = await registry.resolveActiveCorrector(
            preferredID: nil,
            privacyRoute: .onDeviceOnly
        )
        XCTAssertNil(nilPreferred)

        let resolved = await registry.resolveActiveCorrector(
            preferredID: DeterministicCorrector.providerID,
            privacyRoute: .onDeviceOnly
        )
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.descriptor.id, DeterministicCorrector.providerID)

        let mock = MockCorrector(id: "custom.mock")
        let customRegistry = CorrectionProviderRegistry(providers: [mock])
        let customDesc = await customRegistry.descriptors()
        XCTAssertEqual(customDesc.count, 1)

        let mock2 = MockCorrector(id: "custom.mock2")
        await customRegistry.register(mock2)
        let customDesc2 = await customRegistry.descriptors()
        XCTAssertEqual(customDesc2.count, 2)
    }

    // MARK: - LocalCorrectorProbe

    func testLocalCorrectorProbe() async throws {
        let invalidEndpoint = URL(string: "ftp://127.0.0.1:11434")!
        let readinessInvalid = await LocalCorrectorProbe.readiness(
            endpoint: invalidEndpoint,
            providerID: "ollama",
            modelVersion: "v1",
            capabilities: []
        ) { url in
            URLRequest(url: url)
        }
        XCTAssertEqual(readinessInvalid, .requiresConfiguration(.invalidEndpointFormat))

        let unreachableEndpoint = URL(string: "http://127.0.0.1:54321")!
        let readinessUnreachable = await LocalCorrectorProbe.readiness(
            endpoint: unreachableEndpoint,
            providerID: "ollama",
            modelVersion: "v1",
            capabilities: []
        ) { url in
            URLRequest(url: url)
        }
        XCTAssertEqual(
            readinessUnreachable,
            .temporarilyUnavailable(retryAfterSeconds: 5.0, reason: .endpointUnreachable)
        )

        let route = try LocalCorrectionEndpointRoute.resolve(URL(string: "http://127.0.0.1:11434/api/chat")!)
        let request = LocalCorrectorProbe.request(for: route)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 2.0)

        // Test ready state via session override
        let config = LocalEndpointSecurity.makeSessionConfiguration()
        config.protocolClasses = [MockProbeURLProtocol.self]
        let session = URLSession(configuration: config)
        LocalEndpointSecurity.sessionOverride = session
        defer { LocalEndpointSecurity.sessionOverride = nil }

        MockProbeURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"status\":\"ok\"}".utf8), response)
        }

        let readyEndpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
        let readinessReady = await LocalCorrectorProbe.readiness(
            endpoint: readyEndpoint,
            providerID: "ollama",
            modelVersion: "v1",
            capabilities: []
        ) { _ in request }
        if case .ready(let evidence) = readinessReady {
            XCTAssertEqual(evidence.providerID, "ollama")
        } else {
            XCTFail("Expected .ready but got \(readinessReady)")
        }
    }

    // MARK: - LocalLLMModelCatalog

    func testLocalLLMModelCatalog() async throws {
        let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
        let request = try LocalLLMModelCatalog.modelRequest(endpoint: endpoint)
        XCTAssertEqual(request.httpMethod, "GET")

        let unreachable = URL(string: "http://127.0.0.1:54321/api/chat")!
        let models = await LocalLLMModelCatalog.shared.fetchAvailableLocalModels(endpoint: unreachable)
        XCTAssertTrue(models.isEmpty)

        // Test Ollama catalog response parsing
        let config = LocalEndpointSecurity.makeSessionConfiguration()
        config.protocolClasses = [MockProbeURLProtocol.self]
        let session = URLSession(configuration: config)
        LocalEndpointSecurity.sessionOverride = session
        defer { LocalEndpointSecurity.sessionOverride = nil }

        MockProbeURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = "{\"models\": [{\"name\": \"llama3:latest\"}, {\"name\": \"mistral:latest\"}]}"
            return (Data(json.utf8), response)
        }

        let discoveredOllama = await LocalLLMModelCatalog.shared.fetchAvailableLocalModels(endpoint: endpoint)
        XCTAssertEqual(discoveredOllama, ["llama3:latest", "mistral:latest"])

        // Test OpenAI catalog response parsing
        MockProbeURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = "{\"data\": [{\"id\": \"gpt-4o-mini\"}, {\"id\": \"gpt-4o\"}]}"
            return (Data(json.utf8), response)
        }

        let openAIEndpoint = URL(string: "http://127.0.0.1:11434/v1/chat/completions")!
        let discoveredOpenAI = await LocalLLMModelCatalog.shared.fetchAvailableLocalModels(endpoint: openAIEndpoint)
        XCTAssertEqual(discoveredOpenAI, ["gpt-4o-mini", "gpt-4o"])
    }

    // MARK: - SpeechAuthorization

    func testSpeechAuthorization() async {
        XCTAssertEqual(SpeechAuthorization.Status.authorized.diagnosticLabel, "authorized")
        XCTAssertEqual(SpeechAuthorization.Status.notDetermined.diagnosticLabel, "notDetermined")
        XCTAssertEqual(SpeechAuthorization.Status.denied.diagnosticLabel, "denied")
        XCTAssertEqual(SpeechAuthorization.Status.restricted.diagnosticLabel, "restricted")

        XCTAssertEqual(SpeechAuthorization.status(from: .authorized), .authorized)
        XCTAssertEqual(SpeechAuthorization.status(from: .notDetermined), .notDetermined)
        XCTAssertEqual(SpeechAuthorization.status(from: .denied), .denied)
        XCTAssertEqual(SpeechAuthorization.status(from: .restricted), .restricted)

        let current = SpeechAuthorization.status()
        let validStatuses: [SpeechAuthorization.Status] = [.authorized, .notDetermined, .denied, .restricted]
        XCTAssertTrue(validStatuses.contains(current))

        // Fast path when already decided
        SpeechAuthorization.statusOverride = .denied
        let deniedRequest = await SpeechAuthorization.request()
        XCTAssertEqual(deniedRequest, .denied)

        // Request path with prompt simulation
        SpeechAuthorization.statusOverride = .notDetermined
        SpeechAuthorization.requestOverride = { completion in
            completion(.authorized)
        }
        let promptedRequest = await SpeechAuthorization.request()
        XCTAssertEqual(promptedRequest, .authorized)

        SpeechAuthorization.statusOverride = nil
        SpeechAuthorization.requestOverride = nil
    }
}

private final class MockProbeURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
