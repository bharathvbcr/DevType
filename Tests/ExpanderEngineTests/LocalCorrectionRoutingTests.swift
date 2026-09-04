import Foundation
import XCTest
@testable import ExpanderEngine

final class LocalCorrectionRoutingTests: XCTestCase {
    func testProviderSelectionUsesAPIPathInsteadOfOllamaPort() throws {
        let defaultEndpoint = VoicePreferences.defaultLocalLLMEndpoint
        XCTAssertEqual(
            VoiceSessionSnapshotFactory.localCorrectionProviderID(for: defaultEndpoint),
            VoiceSessionSnapshotFactory.ProviderID.openAICompatibleCorrector,
            "Ollama's /v1/chat/completions endpoint speaks the OpenAI-compatible contract"
        )

        let nativeOnArbitraryPort = try XCTUnwrap(
            URL(string: "http://127.0.0.1:43123/api/chat")
        )
        XCTAssertEqual(
            VoiceSessionSnapshotFactory.localCorrectionProviderID(for: nativeOnArbitraryPort),
            VoiceSessionSnapshotFactory.ProviderID.ollamaCorrector
        )
    }

    func testLocalAIPlanOrdersAppleThenConfiguredLoopbackThenRegistryFloor() throws {
        let endpoint = try XCTUnwrap(
            URL(string: "http://localhost:11434/v1/chat/completions")
        )
        XCTAssertEqual(
            VoiceSessionSnapshotFactory.localCorrectionProviderIDs(
                for: endpoint,
                preferAppleFoundationModels: true
            ),
            [
                VoiceSessionSnapshotFactory.ProviderID.appleFoundationModels,
                VoiceSessionSnapshotFactory.ProviderID.openAICompatibleCorrector,
            ]
        )
        XCTAssertEqual(
            VoiceSessionSnapshotFactory.localCorrectionProviderIDs(
                for: endpoint,
                preferAppleFoundationModels: false
            ),
            [VoiceSessionSnapshotFactory.ProviderID.openAICompatibleCorrector]
        )
    }

    func testProviderSpecificProbeRoutesPreserveCustomBasePathAndQuery() throws {
        let native = try XCTUnwrap(
            URL(string: "http://localhost:11434/team/a/api/chat?tenant=blue")
        )
        let nativeProbe = try OllamaCorrector.probeRequest(endpoint: native)
        XCTAssertEqual(nativeProbe.httpMethod, "GET")
        XCTAssertEqual(
            nativeProbe.url?.absoluteString,
            "http://localhost:11434/team/a/api/tags?tenant=blue"
        )

        let compatible = try XCTUnwrap(
            URL(string: "http://localhost:11434/team/a/v1/chat/completions?tenant=blue")
        )
        let compatibleProbe = try OpenAICompatibleCorrector.probeRequest(endpoint: compatible)
        XCTAssertEqual(compatibleProbe.httpMethod, "GET")
        XCTAssertEqual(
            compatibleProbe.url?.absoluteString,
            "http://localhost:11434/team/a/v1/models?tenant=blue"
        )

        XCTAssertEqual(
            try LocalLLMModelCatalog.modelRequest(endpoint: native).url,
            nativeProbe.url
        )
        XCTAssertEqual(
            try LocalLLMModelCatalog.modelRequest(endpoint: compatible).url,
            compatibleProbe.url
        )
    }

    func testOllamaNativeChatPOSTMatchesMessagesAndMessageResponseContract() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://localhost:11434/api/chat?tenant=blue"))
        let urlRequest = try OllamaCorrector.correctionRequest(
            makeCorrectionRequest(),
            endpoint: endpoint,
            model: "qwen3:8b"
        )
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url, endpoint)

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["prompt"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])

        let data = Data(#"{"message":{"role":"assistant","content":"Clean output"},"done":true}"#.utf8)
        XCTAssertEqual(
            try OllamaCorrector.responseText(from: data, endpoint: endpoint),
            "Clean output"
        )
    }

    func testOpenAICompatiblePOSTAndResponseContractUseConfiguredEndpoint() throws {
        let endpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:1234/team/v1/chat/completions?tenant=blue")
        )
        let urlRequest = try OpenAICompatibleCorrector.correctionRequest(
            makeCorrectionRequest(),
            endpoint: endpoint,
            model: "local-model"
        )
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url, endpoint)

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "local-model")
        XCTAssertNotNil(body["messages"])
        XCTAssertNil(body["prompt"])

        let data = Data(#"{"choices":[{"message":{"content":"Compatible output"}}]}"#.utf8)
        XCTAssertEqual(try OpenAICompatibleCorrector.responseText(from: data), "Compatible output")
    }

    private func makeCorrectionRequest() -> CorrectionRequest {
        CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: "raw transcript",
            locale: Locale(identifier: "en-US"),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .localNetworkOnly
        )
    }
}
