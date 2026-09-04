import CryptoKit
import Darwin
import Foundation

/// Starts and stops a local `whisper.cpp` server on the user's behalf.
///
/// Distinct from `BoundedProcess`, which runs a short tool to completion under a deadline.
/// This supervises a long-lived child: it stays up across dictations, its output is drained
/// continuously so it cannot block on a full pipe, and it is terminated when DevType quits
/// so a stray server is never left listening.
///
/// **It only ever manages a server it started itself.** A server the user is running in
/// their own terminal is theirs — the app will use it, report it as running, and refuse to
/// stop it. Killing a process the app did not create is not the app's decision to make.
///
/// The binary comes from `WhisperServerSetup.installedBinaryPath()` and the host is pinned
/// to loopback, so neither is user-supplied text that could redirect what gets executed or
/// where audio goes.
public final class WhisperServerController: @unchecked Sendable {
    private enum StartAdmission {
        case admitted
        case alreadyRunning
        case inProgress
    }

    public static let shared = WhisperServerController()

    /// How long to wait for the server to answer after spawning. Model load dominates:
    /// base.en is a second or two on Apple Silicon, larger models longer.
    public static let readinessTimeout: TimeInterval = 30.0

    /// Grace between SIGTERM and SIGKILL.
    public static let terminationGrace: TimeInterval = 2.0

    /// Cap on retained server output. Enough to see a model-load failure, bounded so a
    /// chatty server cannot grow memory for the life of the app.
    public static let maxLogCharacters = 32_768

    public enum StartFailure: Error, Equatable, Sendable {
        /// The configured address is not an exact HTTP(S) loopback endpoint.
        case invalidEndpoint
        /// No `whisper-server` binary found.
        case notInstalled
        /// The requested model is not in the immutable download manifest.
        case unsupportedModel(model: String)
        /// The model file is missing at the resolved path.
        case modelMissing(path: String)
        /// The model exists but cannot be inspected as a regular readable file.
        case modelUnreadable(path: String)
        /// The model bytes do not have the exact audited length.
        case modelWrongSize(path: String, expected: Int, actual: UInt64)
        /// The model length matches, but its SHA-256 does not.
        case modelDigestMismatch(path: String)
        /// The file path or inode changed after verification and before launch.
        case modelChanged(path: String)
        /// Another caller is already starting the managed server.
        case startInProgress
        /// The caller cancelled startup; any child created by this attempt was stopped.
        case cancelled
        /// Spawning failed.
        case launchFailed(String)
        /// It started but never answered within the timeout — usually a bad model file.
        case neverBecameReady(log: String)
        /// Something is already listening on the endpoint.
        case portBusy
    }

    private let lock = UnfairLock()
    private var process: Process?
    private var outputLog = ""
    private var isStarting = false
    private var isDownloadingModel = false
    private let binaryPathProvider: @Sendable () -> String?
    private let modelDirectory: URL
    private let artifactProvider: @Sendable (String) -> WhisperModelDownloadPolicy.Artifact?
    private let readinessProbe: @Sendable (URL, TimeInterval) async -> Bool
    private let beforeModelIdentityRecheckForTesting: (@Sendable (URL) -> Void)?
    private let beforeDownloadForTesting: (@Sendable () async -> Void)?

    private init() {
        binaryPathProvider = { WhisperServerSetup.installedBinaryPath() }
        modelDirectory = WhisperServerSetup.suggestedModelDirectoryURL
        artifactProvider = { WhisperModelDownloadPolicy.artifact(for: $0) }
        readinessProbe = { endpoint, timeout in
            await WhisperServerSetup.isReachable(endpoint: endpoint, timeout: timeout)
        }
        beforeModelIdentityRecheckForTesting = nil
        beforeDownloadForTesting = nil
    }

    /// Isolated dependency seam for model-integrity and process-policy tests. Production always
    /// uses `shared`, the immutable artifact manifest, and the standard private model directory.
    init(
        binaryPathProvider: @escaping @Sendable () -> String?,
        modelDirectory: URL,
        artifactProvider: @escaping @Sendable (String) -> WhisperModelDownloadPolicy.Artifact?,
        readinessProbe: @escaping @Sendable (URL, TimeInterval) async -> Bool,
        beforeModelIdentityRecheckForTesting: (@Sendable (URL) -> Void)? = nil,
        beforeDownloadForTesting: (@Sendable () async -> Void)? = nil
    ) {
        self.binaryPathProvider = binaryPathProvider
        self.modelDirectory = modelDirectory
        self.artifactProvider = artifactProvider
        self.readinessProbe = readinessProbe
        self.beforeModelIdentityRecheckForTesting = beforeModelIdentityRecheckForTesting
        self.beforeDownloadForTesting = beforeDownloadForTesting
    }

    // MARK: - State

    /// Whether DevType started the server that is currently running.
    public var isManagedByApp: Bool {
        lock.withLock { process?.isRunning == true }
    }

    /// Recent server output, for diagnosing a model that will not load.
    public var recentLog: String {
        lock.withLock { outputLog }
    }

    // MARK: - Start

    /// Launches the server and waits until it answers, or fails with a reason the user can
    /// act on.
    public func start(
        model: String = WhisperServerSetup.defaultModel,
        endpoint: URL = VoicePreferences.whisperEndpoint
    ) async -> Result<Void, StartFailure> {
        guard LocalEndpointSecurity.isValid(endpoint) else {
            return .failure(.invalidEndpoint)
        }
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }

        let admission = lock.withLock { () -> StartAdmission in
            if isStarting {
                return .inProgress
            }
            // Qualified: `start` declares its own `let process = Process()` further down,
            // which shadows the property for the whole function body.
            if self.process?.isRunning == true {
                return .alreadyRunning
            }
            if let pipe = self.process?.standardOutput as? Pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
            }
            self.process = nil
            outputLog = ""
            isStarting = true
            return .admitted
        }
        switch admission {
        case .alreadyRunning:
            return .success(())
        case .inProgress:
            return .failure(.startInProgress)
        case .admitted:
            break
        }
        defer { lock.withLock { isStarting = false } }

        // Something else is already serving this endpoint — the user's own server, or a
        // leftover. Use it rather than fighting over the port.
        let endpointWasReady = await readinessProbe(endpoint, 1.0)
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }
        if endpointWasReady {
            return .failure(.portBusy)
        }

        guard let artifact = artifactProvider(model) else {
            return .failure(.unsupportedModel(model: model))
        }
        guard let binary = binaryPathProvider() else {
            return .failure(.notInstalled)
        }

        let modelURL = modelDirectory.appendingPathComponent(WhisperServerSetup.modelFilename(model))
        let modelPath = modelURL.path
        let modelStatus: WhisperModelStatus
        do {
            modelStatus = try await Self.inspectModel(fileAt: modelURL, artifact: artifact)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.modelUnreadable(path: modelPath))
        }
        let verifiedModel: WhisperVerifiedModel
        switch modelStatus {
        case .unsupportedModel:
            return .failure(.unsupportedModel(model: model))
        case .missing:
            return .failure(.modelMissing(path: modelPath))
        case .unreadable:
            return .failure(.modelUnreadable(path: modelPath))
        case .wrongSize(let expected, let actual):
            return .failure(.modelWrongSize(path: modelPath, expected: expected, actual: actual))
        case .digestMismatch:
            return .failure(.modelDigestMismatch(path: modelPath))
        case .changedDuringVerification:
            return .failure(.modelChanged(path: modelPath))
        case .verified(let verified):
            verifiedModel = verified
        }

        let port = endpoint.port ?? 8080
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--host", "127.0.0.1", "--port", "\(port)", "-m", verifiedModel.fileURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        // Drain continuously. A server whose pipe fills blocks on write and stops serving,
        // which would look exactly like a hang.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text)
        }

        beforeModelIdentityRecheckForTesting?(verifiedModel.fileURL)
        guard WhisperModelDownloadPolicy.isStillCurrent(verifiedModel) else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.modelChanged(path: modelPath))
        }
        guard !Task.isCancelled else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.cancelled)
        }

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        lock.withLock {
            self.process = process
        }
        guard !Task.isCancelled else {
            stopManagedProcess(process)
            return .failure(.cancelled)
        }

        DevTypeLog.voice.info("[Voice] whisper-server started pid=\(process.processIdentifier) port=\(port)")

        // Poll rather than sleeping a fixed interval: model load time varies by an order of
        // magnitude between base and large.
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            guard !Task.isCancelled else {
                stopManagedProcess(process)
                return .failure(.cancelled)
            }
            if !process.isRunning {
                let log = recentLog
                clearProcess(ifMatching: process)
                return .failure(.neverBecameReady(log: log))
            }
            let isReady = await readinessProbe(endpoint, 1.0)
            guard !Task.isCancelled else {
                stopManagedProcess(process)
                return .failure(.cancelled)
            }
            if isReady {
                DevTypeLog.voice.info("[Voice] whisper-server ready")
                return .success(())
            }
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch is CancellationError {
                stopManagedProcess(process)
                return .failure(.cancelled)
            } catch {
                stopManagedProcess(process)
                return .failure(.cancelled)
            }
        }

        let log = recentLog
        stopManagedProcess(process)
        return .failure(.neverBecameReady(log: log))
    }

    // MARK: - Stop

    /// Terminates the server, but only if DevType started it.
    ///
    /// Returns `false` when there is nothing of ours to stop — including when a server is
    /// running that someone else started, which is deliberately left alone.
    @discardableResult
    public func stop() -> Bool {
        let running: Process? = lock.withLock {
            guard let process, process.isRunning else { return nil }
            return process
        }
        guard let running else {
            clearProcess()
            return false
        }
        return stopManagedProcess(running)
    }

    /// Called when DevType quits. A server we spawned must not outlive the app that
    /// spawned it.
    public func stopIfManaged() {
        if isManagedByApp { stop() }
    }

    // MARK: - Internals

    private static func inspectModel(
        fileAt url: URL,
        artifact: WhisperModelDownloadPolicy.Artifact
    ) async throws -> WhisperModelStatus {
        let inspection = Task.detached(priority: .utility) {
            try WhisperModelDownloadPolicy.modelStatus(
                fileAt: url,
                artifact: artifact,
                cancellationCheck: {
                    try Task<Never, Never>.checkCancellation()
                }
            )
        }
        return try await withTaskCancellationHandler {
            try await inspection.value
        } onCancel: {
            inspection.cancel()
        }
    }

    @discardableResult
    private func stopManagedProcess(_ expected: Process) -> Bool {
        let isOurs = lock.withLock { process === expected }
        guard isOurs else { return false }

        if expected.isRunning {
            DevTypeLog.voice.info(
                "[Voice] stopping whisper-server pid=\(expected.processIdentifier)"
            )
            expected.terminate()

            // Escalate if it ignores SIGTERM, so quitting DevType cannot leave a server behind.
            let deadline = Date().addingTimeInterval(Self.terminationGrace)
            while expected.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if expected.isRunning {
                kill(expected.processIdentifier, SIGKILL)
            }
        }

        clearProcess(ifMatching: expected)
        return true
    }

    private func clearProcess(ifMatching expected: Process? = nil) {
        lock.withLock {
            if let expected, process !== expected {
                return
            }
            if let pipe = process?.standardOutput as? Pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
            }
            process = nil
        }
    }

    private func appendLog(_ text: String) {
        lock.withLock {
            outputLog += text
            if outputLog.count > Self.maxLogCharacters {
                outputLog = String(outputLog.suffix(Self.maxLogCharacters))
            }
        }
    }
}

// MARK: - Messaging

public extension WhisperServerController.StartFailure {
    /// What the user should do about it.
    var userMessage: String {
        switch self {
        case .invalidEndpoint:
            return "Use a loopback endpoint: localhost, 127.0.0.1, or [::1]."
        case .notInstalled:
            return "whisper.cpp is not installed. Run: brew install whisper-cpp"
        case .unsupportedModel(let model):
            return "The \(model) model has no verified manifest. Choose the verified base.en model."
        case .modelMissing(let path):
            return "No model at \(path). Download one from Voice preferences first."
        case .modelUnreadable(let path):
            return "The model at \(path) is not a readable regular file. Download a fresh verified copy."
        case .modelWrongSize(let path, let expected, let actual):
            return "The model at \(path) has \(actual) bytes; expected \(expected). Download it again."
        case .modelDigestMismatch(let path):
            return "The model at \(path) failed its SHA-256 integrity check. Download it again."
        case .modelChanged(let path):
            return "The model at \(path) changed while it was being verified. Retry after file activity stops."
        case .startInProgress:
            return "The local Whisper server is already starting. Wait for that attempt to finish."
        case .cancelled:
            return "Starting the local Whisper server was cancelled."
        case .launchFailed(let detail):
            return "Could not start the server: \(detail)"
        case .neverBecameReady(let log):
            let tail = log.split(separator: "\n").suffix(3).joined(separator: " ")
            return tail.isEmpty
                ? "The server started but never answered."
                : "The server started but never answered: \(tail)"
        case .portBusy:
            return "A server is already running on that port. DevType will use it."
        }
    }
}

// MARK: - Model acquisition

public extension WhisperServerController {

    enum DownloadFailure: Error, Equatable, Sendable {
        case unsupportedModel
        case responseTooLarge
        case integrityCheckFailed
        case untrustedRedirect
        case downloadInProgress
        case cancelled
        case network(String)
        case badResponse(Int)
        case couldNotWrite(String)

        public var userMessage: String {
            switch self {
            case .unsupportedModel:       return "This model has no verified download manifest."
            case .responseTooLarge:       return "The model download exceeded its verified size."
            case .integrityCheckFailed:   return "The downloaded model failed its integrity check."
            case .untrustedRedirect:      return "The model host redirected to an untrusted destination."
            case .downloadInProgress:     return "A Whisper model download is already in progress."
            case .cancelled:              return "The model download was cancelled."
            case .network(let detail):    return "Download failed: \(detail)"
            case .badResponse(let code):  return "The model host returned HTTP \(code)."
            case .couldNotWrite(let detail): return "Could not save the model: \(detail)"
            }
        }
    }

    /// Downloads a ggml model into the location the Start button looks in.
    ///
    /// Explicitly user-initiated: this is a few hundred megabytes, so it happens when
    /// someone presses a button, never as a side effect of opening Preferences or of a
    /// failed dictation.
    ///
    /// Writes to a temporary file and moves it into place only on success, so an
    /// interrupted download cannot leave a truncated file that the server would later fail
    /// to load with a confusing error.
    func downloadModel(
        _ model: String = WhisperServerSetup.defaultModel,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> Result<URL, DownloadFailure> {
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }
        guard let artifact = artifactProvider(model) else {
            return .failure(.unsupportedModel)
        }
        let admitted = lock.withLock { () -> Bool in
            guard !isDownloadingModel else { return false }
            isDownloadingModel = true
            return true
        }
        guard admitted else {
            return .failure(.downloadInProgress)
        }
        defer { lock.withLock { isDownloadingModel = false } }
        await beforeDownloadForTesting?()
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }

        let destinationDirectory = modelDirectory
        let destination = destinationDirectory
            .appendingPathComponent(WhisperServerSetup.modelFilename(model))

        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Creation attributes do not affect an existing cache directory. Tighten it too so
            // another local account cannot replace a verified model.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: destinationDirectory.path
            )
        } catch {
            return .failure(.couldNotWrite(error.localizedDescription))
        }

        let source = artifact.sourceURL
        DevTypeLog.voice.info("[Voice] downloading whisper model \(model)")

        let observer = DownloadProgressObserver(
            maximumBytes: Int64(artifact.byteCount),
            onProgress: progress
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1_800
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let download: (URL, URLResponse)
        do {
            download = try await session.download(from: source)
        } catch {
            if observer.rejectedRedirect {
                return .failure(.untrustedRedirect)
            }
            if observer.exceededBudget {
                return .failure(.responseTooLarge)
            }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return .failure(.cancelled)
            }
            return .failure(.network("The connection could not complete."))
        }

        let (temporaryURL, response) = download
        if observer.rejectedRedirect {
            return .failure(.untrustedRedirect)
        }
        if observer.exceededBudget {
            return .failure(.responseTooLarge)
        }
        if Task.isCancelled {
            return .failure(.cancelled)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return .failure(.badResponse(http.statusCode))
        }

        do {
            try await Self.verifyDownloadedModel(fileAt: temporaryURL, artifact: artifact)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.integrityCheckFailed)
        }

        // Move the verified bytes beside the destination before replacement. This retains a
        // previously working model if the cross-directory move or final replacement fails.
        let staged = destinationDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).download-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: staged)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: staged.path
            )
            // Reverify after the cross-directory move. A filesystem that implemented the move as
            // copy-and-delete must not get a free pass based on the temporary inode's digest.
            try await Self.verifyDownloadedModel(fileAt: staged, artifact: artifact)
            try Task<Never, Never>.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch is WhisperModelDownloadPolicy.VerificationError {
            return .failure(.integrityCheckFailed)
        } catch {
            return .failure(.couldNotWrite(
                "Check that ~/.cache/whisper.cpp is writable and has free space, then retry."
            ))
        }

        DevTypeLog.voice.info("[Voice] whisper model saved to \(destination.path)")
        return .success(destination)
    }

    private static func verifyDownloadedModel(
        fileAt url: URL,
        artifact: WhisperModelDownloadPolicy.Artifact
    ) async throws {
        let verification = Task.detached(priority: .utility) {
            try WhisperModelDownloadPolicy.verify(
                fileAt: url,
                expectedByteCount: artifact.byteCount,
                expectedSHA256: artifact.sha256
            )
        }
        try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: {
            verification.cancel()
        }
    }
}

/// A successful inspection carries the exact inode metadata that was hashed. Launch reopens the
/// path and compares this token immediately before `Process.run()`, refusing any replacement it
/// observes at the launch boundary without retaining 148 MB in memory.
public struct WhisperVerifiedModel: Equatable, Sendable {
    public let fileURL: URL
    public let byteCount: Int
    public let sha256: String
    fileprivate let identity: WhisperModelFileIdentity
}

/// Canonical model trust state shared by setup/readiness, download verification, and launch.
public enum WhisperModelStatus: Equatable, Sendable {
    case unsupportedModel
    case missing
    case unreadable
    case wrongSize(expected: Int, actual: UInt64)
    case digestMismatch
    case changedDuringVerification
    case verified(WhisperVerifiedModel)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

fileprivate struct WhisperModelFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

/// Immutable supply-chain and resource policy for model acquisition and consumption. Only
/// artifacts with an audited byte count and SHA-256 digest can be reported ready or launched.
enum WhisperModelDownloadPolicy {
    struct Artifact: Equatable, Sendable {
        let sourceURL: URL
        let byteCount: Int
        let sha256: String
    }

    enum VerificationError: Error, Equatable {
        case wrongSize
        case wrongDigest
        case unreadable
        case changedDuringVerification
    }

    private static let artifacts: [String: Artifact] = [
        WhisperServerSetup.defaultModel: Artifact(
            sourceURL: WhisperServerSetup.modelDownloadURL(WhisperServerSetup.defaultModel),
            byteCount: 147_964_211,
            sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        ),
    ]

    static func artifact(for model: String) -> Artifact? {
        guard isSafeModelIdentifier(model),
              let artifact = artifacts[model],
              allowsRedirect(to: artifact.sourceURL) else {
            return nil
        }
        return artifact
    }

    static func allowsRedirect(to url: URL) -> Bool {
        guard url.baseURL == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased() else {
            return false
        }
        return host == "huggingface.co" || host.hasSuffix(".hf.co")
    }

    private static func isSafeModelIdentifier(_ model: String) -> Bool {
        guard !model.isEmpty else { return false }
        return model.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    static func isWithinBudget(
        totalBytesWritten: Int64,
        expectedBytes: Int64,
        maximumBytes: Int64
    ) -> Bool {
        guard maximumBytes > 0,
              totalBytesWritten >= 0,
              totalBytesWritten <= maximumBytes else {
            return false
        }
        return expectedBytes < 0 || expectedBytes <= maximumBytes
    }

    static func verify(
        fileAt url: URL,
        expectedByteCount: Int,
        expectedSHA256: String,
        cancellationCheck: () throws -> Void = {
            try Task<Never, Never>.checkCancellation()
        }
    ) throws {
        let artifact = Artifact(
            sourceURL: url,
            byteCount: expectedByteCount,
            sha256: expectedSHA256
        )
        switch try inspectedModelStatus(
            fileAt: url,
            artifact: artifact,
            cancellationCheck: cancellationCheck
        ) {
        case .verified:
            return
        case .wrongSize, .missing:
            throw VerificationError.wrongSize
        case .digestMismatch:
            throw VerificationError.wrongDigest
        case .changedDuringVerification:
            throw VerificationError.changedDuringVerification
        case .unsupportedModel, .unreadable:
            throw VerificationError.unreadable
        }
    }

    /// Opens one descriptor, hashes at most the exact expected extent plus one byte, and confirms
    /// both the descriptor and path still identify the same regular file after hashing.
    static func modelStatus(fileAt url: URL, artifact: Artifact) -> WhisperModelStatus {
        // This compatibility/readiness path is synchronous and cannot be cancelled. Downloads use
        // the throwing verifier, whose detached task checks cancellation between bounded chunks.
        do {
            return try inspectedModelStatus(
                fileAt: url,
                artifact: artifact,
                cancellationCheck: {}
            )
        } catch {
            return .unreadable
        }
    }

    static func modelStatus(
        fileAt url: URL,
        artifact: Artifact,
        cancellationCheck: () throws -> Void
    ) throws -> WhisperModelStatus {
        try inspectedModelStatus(
            fileAt: url,
            artifact: artifact,
            cancellationCheck: cancellationCheck
        )
    }

    private static func inspectedModelStatus(
        fileAt url: URL,
        artifact: Artifact,
        cancellationCheck: () throws -> Void
    ) throws -> WhisperModelStatus {
        try cancellationCheck()
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard artifact.byteCount >= 0, artifact.byteCount < Int.max else { return .unreadable }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .unreadable
        }
        defer { try? handle.close() }

        guard let before = identity(for: handle) else { return .unreadable }
        guard before.byteCount == UInt64(artifact.byteCount) else {
            return .wrongSize(expected: artifact.byteCount, actual: before.byteCount)
        }

        var hasher = SHA256()
        var observedBytes = 0
        do {
            while observedBytes <= artifact.byteCount {
                try cancellationCheck()
                let remaining = artifact.byteCount + 1 - observedBytes
                let chunk = try handle.read(upToCount: min(remaining, 1024 * 1024)) ?? Data()
                guard !chunk.isEmpty else { break }
                observedBytes += chunk.count
                hasher.update(data: chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }

        try cancellationCheck()
        guard let after = identity(for: handle), before == after else {
            return .changedDuringVerification
        }
        guard observedBytes == artifact.byteCount else {
            return observedBytes > artifact.byteCount
                ? .changedDuringVerification
                : .wrongSize(expected: artifact.byteCount, actual: UInt64(observedBytes))
        }
        guard identity(at: url) == after else {
            return .changedDuringVerification
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256.lowercased() else {
            return .digestMismatch
        }
        return .verified(WhisperVerifiedModel(
            fileURL: url,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256.lowercased(),
            identity: after
        ))
    }

    /// Reopens the launch path so replacement, truncation, or ordinary same-inode mutation after
    /// hashing invalidates the token. ctime is included because users can restore mtime explicitly.
    static func isStillCurrent(_ verified: WhisperVerifiedModel) -> Bool {
        identity(at: verified.fileURL) == verified.identity
    }

    private static func identity(at url: URL) -> WhisperModelFileIdentity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return identity(for: handle)
    }

    private static func identity(for handle: FileHandle) -> WhisperModelFileIdentity? {
        var metadata = stat()
        guard fstat(handle.fileDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            return nil
        }
        return WhisperModelFileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: UInt64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }
}

/// Reports download progress. A few hundred megabytes with no feedback reads as a hang.
private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int64
    private let onProgress: @Sendable (Double) -> Void
    private var didExceedBudget = false
    private var didRejectRedirect = false

    var exceededBudget: Bool { lock.withLock { didExceedBudget } }
    var rejectedRedirect: Bool { lock.withLock { didRejectRedirect } }

    init(maximumBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.maximumBytes = maximumBytes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, WhisperModelDownloadPolicy.allowsRedirect(to: target) else {
            lock.withLock { didRejectRedirect = true }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard WhisperModelDownloadPolicy.isWithinBudget(
            totalBytesWritten: totalBytesWritten,
            expectedBytes: totalBytesExpectedToWrite,
            maximumBytes: maximumBytes
        ) else {
            lock.withLock { didExceedBudget = true }
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async `download(from:)` API takes ownership of the file; nothing to do here.
    }
}
