import Foundation

/// Single authority for every provider advertised as `localNetworkOnly`.
///
/// A local privacy label is a data-egress contract, not a hint. Callers must validate again at
/// the transport boundary because persisted defaults, tests, and direct provider construction can
/// bypass Preferences. The accompanying session refuses every HTTP redirect, including redirects
/// from loopback to another loopback URL, so a local server cannot forward audio or transcripts to
/// a second destination behind the user's back.
public enum LocalEndpointSecurity {
    public enum Violation: Error, Equatable, Sendable {
        case unsupportedScheme
        case credentialsNotAllowed
        case nonLoopbackHost
        case invalidPort
        case missingURL
        case invalidResponseURL
        case invalidResponseLimit
        case responseTooLarge
    }

    /// Response budgets are intentionally selected by operation. Readiness pages are never parsed,
    /// while model catalogs and inference results need more headroom. Every budget is still far
    /// below a size that could exhaust the app when a broken or hostile loopback process responds.
    public static let maximumReadinessResponseBytes = 64 * 1024
    public static let maximumModelCatalogResponseBytes = 2 * 1024 * 1024
    public static let maximumCorrectionResponseBytes = 1 * 1024 * 1024
    public static let maximumTranscriptionResponseBytes = 4 * 1024 * 1024

    /// Accepts only an absolute HTTP(S) URL whose authority is exactly one of the three supported
    /// loopback spellings. Paths, queries, and valid ports are preserved unchanged.
    @discardableResult
    public static func validated(_ endpoint: URL) throws -> URL {
        guard endpoint.baseURL == nil,
              let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw Violation.nonLoopbackHost
        }
        guard scheme == "http" || scheme == "https" else {
            throw Violation.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw Violation.credentialsNotAllowed
        }

        let isExactLoopback = host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
        guard isExactLoopback else {
            throw Violation.nonLoopbackHost
        }
        if let port = components.port, !(1 ... 65_535).contains(port) {
            throw Violation.invalidPort
        }
        return endpoint
    }

    public static func isValid(_ endpoint: URL) -> Bool {
        (try? validated(endpoint)) != nil
    }

    /// The only URLSession entry point local-only providers should use. The body is streamed and
    /// abandoned as soon as it crosses the caller's operation-specific response budget.
    public static func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        try await data(
            for: request,
            maximumResponseBytes: maximumResponseBytes,
            using: session
        )
    }

    /// Session injection is internal so tests can deterministically exercise streaming boundaries
    /// with a URLProtocol instead of binding a real loopback port.
    static func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
        using session: URLSession
    ) async throws -> (Data, URLResponse) {
        guard let requestURL = request.url else { throw Violation.missingURL }
        try validated(requestURL)
        guard maximumResponseBytes > 0 else { throw Violation.invalidResponseLimit }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let responseURL = response.url else {
                bytes.task.cancel()
                throw Violation.invalidResponseURL
            }
            do {
                try validated(responseURL)
            } catch {
                bytes.task.cancel()
                throw error
            }

            // A declared size can reject immediately, but it is never trusted as the enforcement
            // mechanism: Content-Length may be absent or dishonest.
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                bytes.task.cancel()
                throw Violation.responseTooLarge
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
                    throw Violation.responseTooLarge
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response)
        } catch {
            // URLSession may surface cancellation as URLError.cancelled. Keep structured
            // cancellation observable to the voice coordinator instead of rewriting it.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        // A nil proxy dictionary inherits system proxy/PAC settings. Local-only payloads must
        // connect directly to loopback, even on a Mac whose global proxy does not exempt it.
        configuration.connectionProxyDictionary = [:]
        return configuration
    }

    private static let session: URLSession = {
        return URLSession(
            configuration: makeSessionConfiguration(),
            delegate: LocalEndpointURLSessionDelegate.shared,
            delegateQueue: nil
        )
    }()
}

/// URLSession follows redirects by default. Returning `nil` is the documented refusal path and
/// leaves the caller with the original 3xx response, which every provider already treats as a
/// failure. Internal visibility keeps the policy directly testable via `@testable import`.
final class LocalEndpointURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LocalEndpointURLSessionDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
