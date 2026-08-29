import Foundation

/// What a release looks like once parsed out of the GitHub Releases payload.
public struct ReleaseInfo: Equatable, Sendable {
    /// Parsed from the release's `tag_name`.
    public let version: AppVersion
    /// The tag exactly as GitHub reports it (`v1.3.0`).
    public let tagName: String
    /// Human-readable release name, when GitHub has one.
    public let name: String?
    /// Curated release notes body. Truncated to `UpdateChecker.maximumNotesCharacters`.
    public let notes: String
    /// The release page. Always a `github.com` URL on the configured repository — see
    /// `UpdateChecker.sanitizedReleaseURL(from:)`.
    public let releaseURL: URL
    /// Publication timestamp, when parseable.
    public let publishedAt: Date?

    public init(
        version: AppVersion,
        tagName: String,
        name: String?,
        notes: String,
        releaseURL: URL,
        publishedAt: Date?
    ) {
        self.version = version
        self.tagName = tagName
        self.name = name
        self.notes = notes
        self.releaseURL = releaseURL
        self.publishedAt = publishedAt
    }
}

/// The result of one check.
///
/// Failure cases are **distinct from** `.upToDate` on purpose. A check that could not run must
/// never render the same "You're up to date" UI as a check that ran and confirmed it — that is
/// how a silently broken updater comes to mean "no updates exist" and users sit on a version
/// with a known bug for months.
public enum UpdateCheckOutcome: Equatable, Sendable {
    /// A newer release exists and the user has not skipped it.
    case updateAvailable(ReleaseInfo)
    /// The check ran and the running build is current (or ahead of) the latest release.
    case upToDate(current: AppVersion, latest: AppVersion)
    /// A newer release exists but the user chose "Skip This Version".
    case skipped(ReleaseInfo)
    /// The running build's own version could not be determined, so no comparison is meaningful.
    case undeterminedLocalVersion(raw: String?)
    /// The check did not complete.
    case failed(UpdateCheckError)
}

public enum UpdateCheckError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case rateLimited
    case notFound
    case httpError(status: Int)
    case malformedResponse(reason: String)
    case responseTooLarge
    case cancelled

    /// A short, non-technical sentence for the UI. Never contains a URL or raw payload.
    public var userMessage: String {
        switch self {
        case .offline:
            return "No internet connection."
        case .timedOut:
            return "The update check timed out."
        case .rateLimited:
            return "GitHub rate limit reached. Try again later."
        case .notFound:
            return "No published releases were found."
        case .httpError(let status):
            return "GitHub returned an error (HTTP \(status))."
        case .malformedResponse:
            return "The release information could not be read."
        case .responseTooLarge:
            return "The release information was unexpectedly large."
        case .cancelled:
            return "The update check was cancelled."
        }
    }
}

/// Checks GitHub Releases for a newer DevType, and reports what it finds.
///
/// **It never downloads or installs anything.** The outcome is information; acting on it is a
/// button that opens the release page in the user's browser. That is deliberate rather than a
/// missing feature: `.github/workflows/release.yml` publishes with `DEVTYPE_SKIP_NOTARIZE=1`, so
/// CI-built DMGs are signed but not notarized, and a silently auto-installed non-notarized bundle
/// is exactly what Gatekeeper is built to stop. Handing the user the release page keeps the
/// install on the path macOS actually trusts. Swapping in an in-place updater is a separate
/// change that has to enable notarization in CI first.
///
/// Privacy: an ephemeral session with no cookie, cache, or credential storage; a static
/// `User-Agent` carrying no version, machine, or install identifier; no request body; and
/// nothing sent anywhere except the public releases endpoint of the configured repository.
public actor UpdateChecker {

    public static let shared = UpdateChecker()

    /// Owner/repo the checker talks to. Matches the `origin` remote and the release workflow.
    public static let repositoryOwner = "bharathvbcr"
    public static let repositoryName = "DevType"

    /// Release notes are shown in a fixed-size panel; a multi-megabyte body would be a memory
    /// and layout problem, not a feature. Bodies longer than this are truncated for display.
    public static let maximumNotesCharacters = 8_000

    /// Hard ceiling on the response DevType will read. The latest-release payload is a few KB;
    /// this bounds a hostile or malfunctioning endpoint rather than trusting `Content-Length`.
    public static let maximumResponseBytes = 512 * 1024

    private let session: URLSession
    private let endpoint: URL

    public init(
        endpoint: URL? = nil,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint ?? URL(
            string: "https://api.github.com/repos/\(Self.repositoryOwner)/\(Self.repositoryName)/releases/latest"
        )!

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 20
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.httpShouldSetCookies = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// Runs a check and classifies the result.
    ///
    /// `currentVersion` defaults to the running bundle's. On success the last-check timestamp and
    /// last-found version are recorded; on failure neither is touched, so a stale "checked today"
    /// can never be produced by a check that did not complete.
    public func check(
        currentVersion: AppVersion? = AppVersion.current(),
        honorSkip: Bool = true
    ) async -> UpdateCheckOutcome {
        guard let currentVersion else {
            let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            DevTypeLog.updates.error("update check aborted: local version unparseable")
            return .undeterminedLocalVersion(raw: raw)
        }

        let release: ReleaseInfo
        do {
            release = try await fetchLatestRelease()
        } catch let error as UpdateCheckError {
            DevTypeLog.updates.error("update check failed: \(String(describing: error), privacy: .public)")
            return .failed(error)
        } catch {
            return .failed(.malformedResponse(reason: "unexpected error"))
        }

        UpdatePreferences.lastSuccessfulCheck = Date()
        UpdatePreferences.lastFoundVersion = release.version.rawValue

        guard AppVersion.compare(release.version, currentVersion) == .orderedDescending else {
            DevTypeLog.updates.info("up to date (local ahead of or equal to latest release)")
            return .upToDate(current: currentVersion, latest: release.version)
        }

        if honorSkip, UpdatePreferences.isSkipped(release.version) {
            return .skipped(release)
        }
        return .updateAvailable(release)
    }

    /// Runs a check only if the user opted in to automatic checks and the interval has elapsed.
    /// Returns `nil` when no check was attempted, so a caller cannot mistake "did not run" for
    /// an outcome.
    public func checkIfDue(currentVersion: AppVersion? = AppVersion.current()) async -> UpdateCheckOutcome? {
        guard UpdatePreferences.isAutomaticCheckDue() else { return nil }
        return await check(currentVersion: currentVersion)
    }

    // MARK: - Networking

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // Static and version-free: GitHub requires a User-Agent, and this sends the minimum that
        // satisfies it without turning every check into a version/install fingerprint.
        request.setValue("DevType", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await readBounded(request: request)
        } catch let error as UpdateCheckError {
            throw error
        } catch is CancellationError {
            throw UpdateCheckError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw UpdateCheckError.offline
            case .timedOut:
                throw UpdateCheckError.timedOut
            case .cancelled:
                throw UpdateCheckError.cancelled
            default:
                throw UpdateCheckError.malformedResponse(reason: "transport error")
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.malformedResponse(reason: "not an HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 404:
            // The repository has no published (non-draft, non-prerelease) release yet.
            throw UpdateCheckError.notFound
        case 403, 429:
            // GitHub signals anonymous rate limiting with 403 + a zeroed remaining header.
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            if http.statusCode == 429 || remaining == "0" {
                throw UpdateCheckError.rateLimited
            }
            throw UpdateCheckError.httpError(status: http.statusCode)
        default:
            throw UpdateCheckError.httpError(status: http.statusCode)
        }

        return try Self.parseRelease(from: data)
    }

    /// Reads the response while enforcing `maximumResponseBytes`.
    ///
    /// Streams rather than using `data(for:)` so an oversized body is abandoned mid-flight
    /// instead of being fully buffered and only then rejected.
    private func readBounded(request: URLRequest) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)

        // Trust the declared length only to reject early; the streaming cap below is what
        // actually enforces the bound.
        if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
            stream.task.cancel()
            throw UpdateCheckError.responseTooLarge
        }

        var data = Data()
        data.reserveCapacity(16 * 1024)
        for try await byte in stream {
            if Task.isCancelled {
                stream.task.cancel()
                throw UpdateCheckError.cancelled
            }
            data.append(byte)
            if data.count > Self.maximumResponseBytes {
                stream.task.cancel()
                throw UpdateCheckError.responseTooLarge
            }
        }
        return (data, response)
    }

    // MARK: - Parsing

    /// Parses GitHub's latest-release JSON. `internal` so tests can drive it with fixtures
    /// instead of the network.
    static func parseRelease(from data: Data) throws -> ReleaseInfo {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            throw UpdateCheckError.malformedResponse(reason: "not a JSON object")
        }

        guard let tagName = (json["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tagName.isEmpty else {
            throw UpdateCheckError.malformedResponse(reason: "missing tag_name")
        }
        guard let version = AppVersion(tagName) else {
            throw UpdateCheckError.malformedResponse(reason: "unparseable tag_name")
        }

        guard let releaseURL = sanitizedReleaseURL(from: json["html_url"] as? String, tagName: tagName) else {
            throw UpdateCheckError.malformedResponse(reason: "unusable html_url")
        }

        var notes = (json["body"] as? String) ?? ""
        if notes.count > maximumNotesCharacters {
            notes = String(notes.prefix(maximumNotesCharacters)) + "\n\n…"
        }

        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var publishedAt: Date?
        if let published = json["published_at"] as? String {
            let formatter = ISO8601DateFormatter()
            publishedAt = formatter.date(from: published)
        }

        return ReleaseInfo(
            version: version,
            tagName: tagName,
            name: name,
            notes: notes,
            releaseURL: releaseURL,
            publishedAt: publishedAt
        )
    }

    /// Accepts `html_url` only when it is an `https://github.com` URL under the configured
    /// repository; otherwise falls back to the canonical tag URL built locally.
    ///
    /// The value ends up in `NSWorkspace.open`, so it is treated as untrusted input: a payload
    /// that returned a `javascript:` or `file://` URL, or pointed at another host entirely,
    /// must not become something DevType hands to the system to open.
    static func sanitizedReleaseURL(from candidate: String?, tagName: String) -> URL? {
        if let candidate,
           let url = URL(string: candidate),
           url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "github.com",
           url.path.hasPrefix("/\(repositoryOwner)/\(repositoryName)/") {
            return url
        }

        // Fall back to the canonical page for the tag, built from a validated component.
        guard let encodedTag = tagName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://github.com/\(repositoryOwner)/\(repositoryName)/releases/tag/\(encodedTag)")
    }
}
