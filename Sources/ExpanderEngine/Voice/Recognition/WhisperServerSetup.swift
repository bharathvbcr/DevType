import Foundation

/// Detects how far along a local `whisper.cpp` setup is, and produces the exact commands to
/// finish it.
///
/// The Local Whisper engine needs a server the user runs themselves. Rather than leave that
/// as "configure an endpoint" and let it fail silently, this reports which of the three
/// steps is missing — install, model, run — and hands over commands that can be pasted
/// as-is.
///
/// Nothing here installs or launches anything. Running a build, downloading a multi-hundred
/// megabyte model, and starting a long-lived server are all decisions the user makes; the
/// app's job is to make them obvious and correct, not to make them silently.
public enum WhisperServerSetup {

    /// How far the setup has got.
    public enum State: Sendable, Equatable {
        /// The server answered — everything is ready.
        case running
        /// `whisper-server` is on disk but nothing is listening on the endpoint.
        case installedNotRunning(binaryPath: String)
        /// No `whisper-server` binary found in the usual places.
        case notInstalled
    }

    /// A single step, with a command the user can paste.
    public struct Step: Sendable, Equatable {
        public let title: String
        public let detail: String
        public let command: String
        /// Whether this step still needs doing given the detected state.
        public let isPending: Bool
    }

    /// Places Homebrew and a source build put the binary. Checked in order.
    static let searchPaths = [
        "/opt/homebrew/bin/whisper-server",      // Homebrew, Apple Silicon
        "/usr/local/bin/whisper-server",         // Homebrew, Intel
        "/opt/homebrew/bin/whisper-cpp-server",
        "/usr/local/bin/whisper-cpp-server",
    ]

    /// Default model. `base.en` is the usual starting point: ~148 MB, comfortably real-time
    /// on Apple Silicon, and noticeably better than Apple Speech on technical vocabulary.
    public static let defaultModel = "base.en"

    /// Where the model is suggested to live. Kept out of the app container so it survives
    /// reinstalling DevType and can be shared with other whisper.cpp tools.
    public static var suggestedModelDirectory: String {
        "~/.cache/whisper.cpp"
    }

    public static func modelFilename(_ model: String = defaultModel) -> String {
        "ggml-\(model).bin"
    }

    /// Hugging Face path for a ggml model. This is the same repository
    /// `download-ggml-model.sh` pulls from, used directly because a Homebrew install does
    /// not ship that script.
    public static func modelDownloadURL(_ model: String = defaultModel) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelFilename(model))")!
    }

    // MARK: - Detection

    /// First `whisper-server` binary found on disk, if any.
    public static func installedBinaryPath() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether a model file is already present in the suggested location.
    public static func hasModel(_ model: String = defaultModel) -> Bool {
        let path = (suggestedModelDirectory as NSString).expandingTildeInPath
        return FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent(modelFilename(model))
        )
    }

    /// Probes the configured endpoint, then falls back to inspecting the filesystem.
    ///
    /// A reachable server is the only answer that matters; the binary check exists to tell
    /// "not installed" apart from "installed but not started", because those need different
    /// instructions.
    public static func detect(
        endpoint: URL = VoicePreferences.whisperEndpoint,
        timeout: TimeInterval = 1.5
    ) async -> State {
        if await isReachable(endpoint: endpoint, timeout: timeout) {
            return .running
        }
        if let path = installedBinaryPath() {
            return .installedNotRunning(binaryPath: path)
        }
        return .notInstalled
    }

    /// The stock server exposes a GET page at its request-path root; it does not provide a
    /// `/health` route. For the default `/inference` endpoint this is `/`, while a custom
    /// endpoint such as `/api/inference` is probed at `/api/`.
    static func readinessProbeURL(for endpoint: URL) -> URL {
        endpoint.deletingLastPathComponent()
    }

    /// Whether the configured whisper.cpp server is answering at its request-path root.
    public static func isReachable(
        endpoint: URL = VoicePreferences.whisperEndpoint,
        timeout: TimeInterval = 1.5
    ) async -> Bool {
        var request = URLRequest(url: readinessProbeURL(for: endpoint))
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout

        guard let (_, response) = try? await URLSession(configuration: configuration).data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200...299).contains(http.statusCode)
    }

    // MARK: - Instructions

    /// The three steps, with the ones already done marked as such.
    public static func steps(
        for state: State,
        model: String = defaultModel,
        endpoint: URL = VoicePreferences.whisperEndpoint
    ) -> [Step] {
        let modelDirectory = suggestedModelDirectory
        let modelPath = "\(modelDirectory)/\(modelFilename(model))"
        let port = endpoint.port ?? 8080

        let isInstalled: Bool
        let serverExecutable: String
        switch state {
        case .notInstalled:
            isInstalled = false
            serverExecutable = "whisper-server"
        case .installedNotRunning(let binaryPath):
            isInstalled = true
            serverExecutable = binaryPath
        case .running:
            isInstalled = true
            serverExecutable = "whisper-server"
        }

        return [
            Step(
                title: "Install whisper.cpp",
                detail: "Homebrew provides the server binary. Takes about a minute.",
                command: "brew install whisper-cpp",
                isPending: !isInstalled
            ),
            Step(
                title: "Download a model",
                detail: "\(model) is ~148 MB and runs comfortably in real time on Apple Silicon.",
                command: """
                mkdir -p \(modelDirectory) && \\
                  curl -L -o \(modelPath) \\
                  \(modelDownloadURL(model).absoluteString)
                """,
                isPending: !hasModel(model)
            ),
            Step(
                title: "Start the server",
                detail: "Leave this running while you dictate. DevType talks to it on \(endpoint.absoluteString).",
                command: "\(serverExecutable) --host 127.0.0.1 --port \(port) -m \(modelPath)",
                isPending: state != .running
            ),
        ]
    }

    /// Every pending step's command, ready to paste into a terminal as one block.
    public static func pendingCommands(
        for state: State,
        model: String = defaultModel,
        endpoint: URL = VoicePreferences.whisperEndpoint
    ) -> String {
        steps(for: state, model: model, endpoint: endpoint)
            .filter(\.isPending)
            .map(\.command)
            .joined(separator: "\n\n")
    }

    /// One line describing where the setup stands.
    public static func summary(for state: State) -> String {
        switch state {
        case .running:
            return "Server is running"
        case .installedNotRunning:
            return "Installed — start the server to use this engine"
        case .notInstalled:
            return "Not installed"
        }
    }
}
