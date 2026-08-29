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

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        self.session = URLSession(configuration: config)
    }

    public func fetchAvailableLocalModels(endpoint: URL) async -> [String] {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return []
        }

        var discovered: [String] = []

        // 1. Try Ollama /api/tags
        components.path = "/api/tags"
        if let ollamaURL = components.url {
            var req = URLRequest(url: ollamaURL)
            req.timeoutInterval = 2.0
            if let (data, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                for m in models {
                    if let name = m["name"] as? String {
                        discovered.append(name)
                    }
                }
            }
        }

        // 2. If no models from Ollama, try OpenAI-compatible /v1/models (LM Studio, vLLM, LocalAI)
        if discovered.isEmpty {
            components.path = "/v1/models"
            if let modelsURL = components.url {
                var req = URLRequest(url: modelsURL)
                req.timeoutInterval = 2.0
                if let (data, resp) = try? await session.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArr = json["data"] as? [[String: Any]] {
                    for m in dataArr {
                        if let id = m["id"] as? String {
                            discovered.append(id)
                        }
                    }
                }
            }
        }

        return discovered
    }
}
