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

    #if DEBUG
    public static var sessionOverride: URLSession?
    #endif

    /// The only URLSession entry point local-only providers should use. The body is streamed and
    /// abandoned as soon as it crosses the caller's operation-specific response budget.
    public static func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        #if DEBUG
        if let sessionOverride {
            return try await data(
                for: request,
                maximumResponseBytes: maximumResponseBytes,
                using: sessionOverride
            )
        }
        #endif
        return try await data(
            for: request,
            maximumResponseBytes: maximumResponseBytes,
            using: session
        )
    }

    /// Session injection is internal so tests can deterministically exercise streaming boundaries
    /// with a URLProtocol instead of binding a real loopback port.
    ///
    /// `URLSession.AsyncBytes` yields only `UInt8` on the macOS 14 / Swift 5.10 deployment, so a
    /// byte loop suspends once per byte. Buffers come from `URLSessionDataDelegate` instead.
    /// `data(for:)` is not used: it retains the whole body before a missing or dishonest
    /// Content-Length can be cancelled.
    static func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
        using session: URLSession
    ) async throws -> (Data, URLResponse) {
        guard let requestURL = request.url else { throw Violation.missingURL }
        try validated(requestURL)
        guard maximumResponseBytes > 0 else { throw Violation.invalidResponseLimit }

        let transport = openTransport(for: session)
        defer { transport.close() }

        let task = transport.session.dataTask(with: request)
        let reader = LocalEndpointChunkReader(limit: maximumResponseBytes)
        transport.delegate.attach(reader, to: task)
        defer { transport.delegate.detach(task) }

        return try await withTaskCancellationHandler {
            task.resume()
            do {
                let response = try await reader.response()
                var data = Data()
                data.reserveCapacity(min(maximumResponseBytes, 16 * 1024))
                while let chunk = try await reader.nextChunk() {
                    if Task.isCancelled {
                        task.cancel()
                        throw CancellationError()
                    }
                    // The reader already stops at the cap. This check refuses a chunk that
                    // would still cross it if a buffer were delivered whole.
                    let room = maximumResponseBytes - data.count
                    guard chunk.count <= room else {
                        task.cancel()
                        throw Violation.responseTooLarge
                    }
                    data.append(chunk)
                }
                try Task.checkCancellation()
                return (data, response)
            } catch {
                task.cancel()
                // URLSession may surface cancellation as URLError.cancelled. Keep structured
                // cancellation observable to the voice coordinator instead of rewriting it.
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// A session's delegate is fixed at init. Delegate-less injected sessions cannot grow a
    /// collector, so they are replayed on a copy that keeps the configuration (including
    /// protocol classes) and the redirect refusal. The production session already has that
    /// delegate and is used as itself.
    private static func openTransport(for session: URLSession) -> LocalEndpointTransport {
        if let delegate = session.delegate as? LocalEndpointURLSessionDelegate {
            return LocalEndpointTransport(session: session, delegate: delegate, ownsSession: false)
        }
        let delegate = LocalEndpointURLSessionDelegate.shared
        let owned = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        return LocalEndpointTransport(session: owned, delegate: delegate, ownsSession: true)
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

/// One in-flight body, keyed by task identity so concurrent reads on the shared delegate do not
/// mix buffers. The cap is applied as each URLSession buffer arrives, not after the body is whole.
private final class LocalEndpointChunkReader: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var response: URLResponse?
    private var responseWaiter: CheckedContinuation<URLResponse, Error>?
    private var pending: [Data] = []
    private var pendingIndex = 0
    private var chunkWaiter: CheckedContinuation<Data?, Error>?
    private var received = 0
    private var finished = false
    private var failure: Error?

    init(limit: Int) {
        self.limit = limit
    }

    func decide(_ response: URLResponse) -> Error? {
        guard let responseURL = response.url else {
            return LocalEndpointSecurity.Violation.invalidResponseURL
        }
        do {
            try LocalEndpointSecurity.validated(responseURL)
        } catch {
            return error
        }
        // A declared size can reject immediately, but it is never trusted as the enforcement
        // mechanism: Content-Length may be absent or dishonest.
        if response.expectedContentLength > Int64(limit) {
            return LocalEndpointSecurity.Violation.responseTooLarge
        }
        return nil
    }

    func accept(_ response: URLResponse) {
        lock.lock()
        self.response = response
        let waiter = responseWaiter
        responseWaiter = nil
        lock.unlock()
        waiter?.resume(returning: response)
    }

    /// `false` means the task must be cancelled. The oversized buffer is not kept.
    func append(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        let room = limit - received
        if data.count > room {
            let error = LocalEndpointSecurity.Violation.responseTooLarge
            let waiters = takeFailureLocked(error)
            lock.unlock()
            resume(error, to: waiters)
            return false
        }
        received += data.count
        if let waiter = chunkWaiter {
            chunkWaiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return true
        }
        pending.append(data)
        lock.unlock()
        return true
    }

    func fail(_ error: Error) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        let waiters = takeFailureLocked(error)
        lock.unlock()
        resume(error, to: waiters)
    }

    func complete(_ error: Error?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if let error {
            let waiters = takeFailureLocked(error)
            lock.unlock()
            resume(error, to: waiters)
            return
        }
        finished = true
        let responseWaiter = self.responseWaiter
        let chunkWaiter = self.chunkWaiter
        self.responseWaiter = nil
        self.chunkWaiter = nil
        let response = self.response
        lock.unlock()
        if let response {
            responseWaiter?.resume(returning: response)
        } else {
            responseWaiter?.resume(throwing: LocalEndpointSecurity.Violation.invalidResponseURL)
        }
        chunkWaiter?.resume(returning: nil)
    }

    func response() async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            if let response {
                lock.unlock()
                continuation.resume(returning: response)
                return
            }
            responseWaiter = continuation
            lock.unlock()
        }
    }

    func nextChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let chunk = dequeueLocked() {
                lock.unlock()
                continuation.resume(returning: chunk)
                return
            }
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            if finished {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            chunkWaiter = continuation
            lock.unlock()
        }
    }

    private func dequeueLocked() -> Data? {
        guard pendingIndex < pending.count else { return nil }
        let chunk = pending[pendingIndex]
        pendingIndex += 1
        if pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingIndex = 0
        }
        return chunk
    }

    private func takeFailureLocked(_ error: Error) -> (
        response: CheckedContinuation<URLResponse, Error>?,
        chunk: CheckedContinuation<Data?, Error>?
    ) {
        finished = true
        failure = error
        pending.removeAll(keepingCapacity: false)
        pendingIndex = 0
        let responseWaiter = self.responseWaiter
        let chunkWaiter = self.chunkWaiter
        self.responseWaiter = nil
        self.chunkWaiter = nil
        return (responseWaiter, chunkWaiter)
    }

    private func resume(
        _ error: Error,
        to waiters: (
            response: CheckedContinuation<URLResponse, Error>?,
            chunk: CheckedContinuation<Data?, Error>?
        )
    ) {
        waiters.response?.resume(throwing: error)
        waiters.chunk?.resume(throwing: error)
    }
}

private struct LocalEndpointTransport {
    let session: URLSession
    let delegate: LocalEndpointURLSessionDelegate
    let ownsSession: Bool

    func close() {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }
}

/// URLSession follows redirects by default. Returning `nil` is the documented refusal path and
/// leaves the caller with the original 3xx response, which every provider already treats as a
/// failure. Internal visibility keeps the policy directly testable via `@testable import`.
/// The same object is the data delegate: URLSession delivers each body buffer here, and state is
/// keyed by task so concurrent calls do not mix.
final class LocalEndpointURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = LocalEndpointURLSessionDelegate()

    private let lock = NSLock()
    private var readers: [ObjectIdentifier: LocalEndpointChunkReader] = [:]

    fileprivate func attach(_ reader: LocalEndpointChunkReader, to task: URLSessionTask) {
        lock.lock()
        readers[ObjectIdentifier(task)] = reader
        lock.unlock()
    }

    fileprivate func detach(_ task: URLSessionTask) {
        lock.lock()
        readers.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
    }

    private func reader(for task: URLSessionTask) -> LocalEndpointChunkReader? {
        lock.lock()
        defer { lock.unlock() }
        return readers[ObjectIdentifier(task)]
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let reader = reader(for: dataTask) else {
            // Not our task (for example an async-bytes read on this session). Do not cancel it.
            completionHandler(.allow)
            return
        }
        if let error = reader.decide(response) {
            reader.fail(error)
            completionHandler(.cancel)
            return
        }
        reader.accept(response)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let reader = reader(for: dataTask) else { return }
        if !reader.append(data) {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let reader = reader(for: task) else { return }
        reader.complete(error)
    }
}
