import Foundation

/// Discovers which models a local LLM server is currently serving, so Preferences can
/// offer a real list instead of a free-text field.
///
/// All that remains of the former `LocalLLMCleanupClient`. Its correction path is gone:
/// cleanup now runs through `TranscriptCorrector` implementations behind
/// `CorrectionProviderRegistry`, which apply the session's policy, protect spans and are
/// validated. Keeping a second, unvalidated cleanup path beside that one was the
/// duplication — this type does the one job the other path was still needed for.
public actor LocalLLMModelCatalog {
    public static let shared = LocalLLMModelCatalog()

    public init() {}

    public func fetchAvailableLocalModels(endpoint: URL) async -> [String] {
        guard let route = try? LocalCorrectionEndpointRoute.resolve(endpoint),
              let request = try? Self.modelRequest(endpoint: endpoint),
              let (data, response) = try? await LocalEndpointSecurity.data(
                  for: request,
                  maximumResponseBytes: LocalEndpointSecurity.maximumModelCatalogResponseBytes
              ),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        switch route.api {
        case .ollamaChat, .ollamaGenerate:
            guard let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        case .openAIChatCompletions:
            guard let models = json["data"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["id"] as? String }
        }
    }

    static func modelRequest(endpoint: URL) throws -> URLRequest {
        let route = try LocalCorrectionEndpointRoute.resolve(endpoint)
        var request = URLRequest(url: route.readinessURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        return request
    }
}
