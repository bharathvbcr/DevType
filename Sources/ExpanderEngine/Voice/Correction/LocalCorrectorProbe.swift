import Foundation

/// Readiness probing shared by the two local HTTP correctors.
///
/// `OllamaCorrector.probe()` and `OpenAICompatibleCorrector.probe()` were the largest
/// structural clone in the engine (286 parse nodes) and differed in exactly one value: the
/// capability strings recorded on the evidence. The endpoint validation, the bounded read,
/// the status-code check and both failure classifications were identical.
///
/// Keeping this in one place matters more than the line count: an unreachable local
/// endpoint must report `temporarilyUnavailable` (retry, keep the preference) while a
/// malformed one must report `requiresConfiguration` (stop, the user has to fix it). Two
/// copies is two chances to get that distinction wrong.
enum LocalCorrectorProbe {
    /// Seconds before a readiness retry is worth attempting. A local server that is
    /// starting up is back within seconds; polling faster just burns the main actor.
    static let retryAfterSeconds: Double = 5.0

    static func readiness(
        endpoint: URL,
        providerID: String,
        modelVersion: String,
        capabilities: [String],
        makeRequest: (URL) throws -> URLRequest
    ) async -> ProviderReadiness {
        guard LocalEndpointSecurity.isValid(endpoint) else {
            return .requiresConfiguration(.invalidEndpointFormat)
        }
        do {
            let request = try makeRequest(endpoint)
            let (_, response) = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: LocalEndpointSecurity.maximumReadinessResponseBytes
            )
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return .temporarilyUnavailable(
                    retryAfterSeconds: retryAfterSeconds, reason: .endpointUnreachable
                )
            }
            return .ready(ProviderEvidence(
                providerID: providerID,
                modelVersion: modelVersion,
                probeTimestamp: Date(),
                capabilities: capabilities
            ))
        } catch {
            return .temporarilyUnavailable(
                retryAfterSeconds: retryAfterSeconds, reason: .endpointUnreachable
            )
        }
    }

    /// The readiness `GET` for a route, once the caller has checked the route is the shape
    /// it serves. Two seconds: a local server either answers immediately or is not running,
    /// and a dictation must not stall on finding out.
    static func request(for route: LocalCorrectionEndpointRoute) -> URLRequest {
        var request = URLRequest(url: route.readinessURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        return request
    }
}
