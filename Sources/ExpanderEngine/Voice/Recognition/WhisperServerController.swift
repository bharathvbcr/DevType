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
        /// No `whisper-server` binary found.
        case notInstalled
        /// The model file is missing at the resolved path.
        case modelMissing(path: String)
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

    private init() {}

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
        if isManagedByApp {
            return .success(())   // already ours and running
        }

        // Something else is already serving this endpoint — the user's own server, or a
        // leftover. Use it rather than fighting over the port.
        if await WhisperServerSetup.isReachable(endpoint: endpoint, timeout: 1.0) {
            return .failure(.portBusy)
        }

        guard let binary = WhisperServerSetup.installedBinaryPath() else {
            return .failure(.notInstalled)
        }

        let modelPath = (WhisperServerSetup.suggestedModelDirectory as NSString)
            .expandingTildeInPath
            .appending("/\(WhisperServerSetup.modelFilename(model))")

        guard FileManager.default.fileExists(atPath: modelPath) else {
            return .failure(.modelMissing(path: modelPath))
        }

        let port = endpoint.port ?? 8080
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--host", "127.0.0.1", "--port", "\(port)", "-m", modelPath]

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

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        lock.withLock {
            self.process = process
            self.outputLog = ""
        }

        DevTypeLog.voice.info("[Voice] whisper-server started pid=\(process.processIdentifier) port=\(port)")

        // Poll rather than sleeping a fixed interval: model load time varies by an order of
        // magnitude between base and large.
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            if !process.isRunning {
                let log = recentLog
                clearProcess()
                return .failure(.neverBecameReady(log: log))
            }
            if await WhisperServerSetup.isReachable(endpoint: endpoint, timeout: 1.0) {
                DevTypeLog.voice.info("[Voice] whisper-server ready")
                return .success(())
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        let log = recentLog
        stop()
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

        DevTypeLog.voice.info("[Voice] stopping whisper-server pid=\(running.processIdentifier)")
        running.terminate()

        // Escalate if it ignores SIGTERM, so quitting DevType cannot leave a server behind.
        let deadline = Date().addingTimeInterval(Self.terminationGrace)
        while running.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if running.isRunning {
            kill(running.processIdentifier, SIGKILL)
        }

        clearProcess()
        return true
    }

    /// Called when DevType quits. A server we spawned must not outlive the app that
    /// spawned it.
    public func stopIfManaged() {
        if isManagedByApp { stop() }
    }

    // MARK: - Internals

    private func clearProcess() {
        lock.withLock {
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
        case .notInstalled:
            return "whisper.cpp is not installed. Run: brew install whisper-cpp"
        case .modelMissing(let path):
            return "No model at \(path). Download one from Voice preferences first."
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
        case network(String)
        case badResponse(Int)
        case couldNotWrite(String)

        public var userMessage: String {
            switch self {
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
        let destinationDirectory = URL(
            fileURLWithPath: (WhisperServerSetup.suggestedModelDirectory as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let destination = destinationDirectory
            .appendingPathComponent(WhisperServerSetup.modelFilename(model))

        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory, withIntermediateDirectories: true
            )
        } catch {
            return .failure(.couldNotWrite(error.localizedDescription))
        }

        let source = WhisperServerSetup.modelDownloadURL(model)
        DevTypeLog.voice.info("[Voice] downloading whisper model \(model)")

        let observer = DownloadProgressObserver(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: observer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (temporaryURL, response) = try await session.download(from: source)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.badResponse(http.statusCode))
            }

            // Replace atomically; a half-written model is worse than none.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)

            DevTypeLog.voice.info("[Voice] whisper model saved to \(destination.path)")
            return .success(destination)
        } catch let error as DownloadFailure {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

/// Reports download progress. A few hundred megabytes with no feedback reads as a hang.
private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async `download(from:)` API takes ownership of the file; nothing to do here.
    }
}
