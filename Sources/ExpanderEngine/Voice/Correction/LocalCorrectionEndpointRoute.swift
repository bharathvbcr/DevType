import Foundation

/// Canonical interpretation of a configured loopback correction endpoint.
///
/// The TCP port says nothing about the HTTP contract: Ollama exposes both its native API and an
/// OpenAI-compatible API on the same default port. Routing therefore follows the terminal API path
/// while retaining any deployment prefix and query supplied by the user.
struct LocalCorrectionEndpointRoute: Equatable, Sendable {
    enum API: Equatable, Sendable {
        case ollamaChat
        case ollamaGenerate
        case openAIChatCompletions
    }

    enum RouteError: Error, Equatable, Sendable {
        case unsupportedPath
    }

    let api: API
    let correctionURL: URL
    let readinessURL: URL

    static func resolve(_ endpoint: URL) throws -> LocalCorrectionEndpointRoute {
        let validated = try LocalEndpointSecurity.validated(endpoint)
        guard var components = URLComponents(url: validated, resolvingAgainstBaseURL: false) else {
            throw RouteError.unsupportedPath
        }

        let pathComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        let api: API
        let readinessComponents: [String]
        if pathComponents.suffix(2) == ["api", "chat"] {
            api = .ollamaChat
            readinessComponents = Array(pathComponents.dropLast()) + ["tags"]
        } else if pathComponents.suffix(2) == ["api", "generate"] {
            api = .ollamaGenerate
            readinessComponents = Array(pathComponents.dropLast()) + ["tags"]
        } else if pathComponents.suffix(3) == ["v1", "chat", "completions"] {
            api = .openAIChatCompletions
            readinessComponents = Array(pathComponents.dropLast(2)) + ["models"]
        } else {
            throw RouteError.unsupportedPath
        }

        components.percentEncodedPath = "/" + readinessComponents.joined(separator: "/")
        guard let readinessURL = components.url else {
            throw RouteError.unsupportedPath
        }
        return LocalCorrectionEndpointRoute(
            api: api,
            correctionURL: validated,
            readinessURL: readinessURL
        )
    }

    var isOllamaNative: Bool {
        switch api {
        case .ollamaChat, .ollamaGenerate: return true
        case .openAIChatCompletions: return false
        }
    }
}
