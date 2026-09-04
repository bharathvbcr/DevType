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

    /// Immutable repository revision whose default model bytes match the digest enforced by
    /// `WhisperModelDownloadPolicy`. A moving `main` URL would make a legitimate upstream update
    /// indistinguishable from a corrupted or substituted download.
    static let verifiedModelRevision = "80da2d8bfee42b0e836fc3a9890373e5defc00a6"

    /// Where the model is suggested to live. Kept out of the app container so it survives
    /// reinstalling DevType and can be shared with other whisper.cpp tools.
    public static var suggestedModelDirectory: String {
        "~/.cache/whisper.cpp"
    }

    public static var suggestedModelDirectoryURL: URL {
        URL(
            fileURLWithPath: (suggestedModelDirectory as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    public static func modelFilename(_ model: String = defaultModel) -> String {
        "ggml-\(model).bin"
    }

    /// Hugging Face path for a ggml model. This is the same repository
    /// `download-ggml-model.sh` pulls from, used directly because a Homebrew install does
    /// not ship that script.
    public static func modelDownloadURL(_ model: String = defaultModel) -> URL {
        URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(verifiedModelRevision)/\(modelFilename(model))"
        )!
    }

    // MARK: - Detection

    /// First `whisper-server` binary found on disk, if any.
    public static func installedBinaryPath() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Canonical integrity inspection used by Preferences readiness. Hashing runs on a utility
    /// task because the verified base model is roughly 148 MB.
    public static func inspectModel(
        _ model: String = defaultModel,
        modelDirectory: URL = suggestedModelDirectoryURL
    ) async -> WhisperModelStatus {
        guard let artifact = WhisperModelDownloadPolicy.artifact(for: model) else {
            return .unsupportedModel
        }
        let fileURL = modelDirectory.appendingPathComponent(modelFilename(model))
        return await Task.detached(priority: .utility) {
            WhisperModelDownloadPolicy.modelStatus(fileAt: fileURL, artifact: artifact)
        }.value
    }

    /// Synchronous compatibility query for non-UI callers. This means "verified", not merely
    /// "a path exists"; UI readiness uses `inspectModel` so hashing never blocks AppKit.
    public static func hasModel(_ model: String = defaultModel) -> Bool {
        guard let artifact = WhisperModelDownloadPolicy.artifact(for: model) else { return false }
        let fileURL = suggestedModelDirectoryURL.appendingPathComponent(modelFilename(model))
        return WhisperModelDownloadPolicy.modelStatus(fileAt: fileURL, artifact: artifact).isVerified
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
        guard LocalEndpointSecurity.isValid(endpoint) else { return false }
        let probeURL = readinessProbeURL(for: endpoint)
        guard LocalEndpointSecurity.isValid(probeURL) else { return false }
        var request = URLRequest(url: probeURL)
        request.timeoutInterval = timeout

        guard let (_, response) = try? await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: LocalEndpointSecurity.maximumReadinessResponseBytes
        ),
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
        modelStatus: WhisperModelStatus? = nil,
        endpoint: URL = VoicePreferences.whisperEndpoint
    ) -> [Step] {
        let port = endpoint.port ?? 8080
        let artifact = WhisperModelDownloadPolicy.artifact(for: model)
        let resolvedModelStatus: WhisperModelStatus
        if artifact == nil {
            // A caller-provided status must never turn an unmanifested model into a runnable one.
            resolvedModelStatus = .unsupportedModel
        } else if let modelStatus {
            resolvedModelStatus = modelStatus
        } else if let artifact {
            let fileURL = suggestedModelDirectoryURL.appendingPathComponent(modelFilename(model))
            resolvedModelStatus = WhisperModelDownloadPolicy.modelStatus(
                fileAt: fileURL,
                artifact: artifact
            )
        } else {
            resolvedModelStatus = .unsupportedModel
        }

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

        let downloadDetail = artifact == nil
            ? "This model has no verified download manifest. Choose base.en."
            : "\(model) is ~148 MB and runs comfortably in real time on Apple Silicon."
        let runCommand: String
        if artifact == nil {
            runCommand = unsupportedModelCommand
        } else {
            let modelPathSuffix = "/.cache/whisper.cpp/\(modelFilename(model))"
            runCommand = "\(shellSingleQuoted(serverExecutable)) --host 127.0.0.1 --port \(port) "
                + "-m \"$HOME\"\(shellSingleQuoted(modelPathSuffix))"
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
                detail: downloadDetail,
                command: verifiedDownloadCommand(for: model),
                isPending: !resolvedModelStatus.isVerified
            ),
            Step(
                title: "Start the server",
                detail: "Leave this running while you dictate. DevType talks to it on \(endpoint.absoluteString).",
                command: runCommand,
                isPending: state != .running
            ),
        ]
    }

    /// Every pending step's command, ready to paste into a terminal as one block.
    public static func pendingCommands(
        for state: State,
        model: String = defaultModel,
        modelStatus: WhisperModelStatus? = nil,
        endpoint: URL = VoicePreferences.whisperEndpoint
    ) -> String {
        steps(for: state, model: model, modelStatus: modelStatus, endpoint: endpoint)
            .filter(\.isPending)
            .map(\.command)
            .joined(separator: "\n\n")
    }

    private static let unsupportedModelCommand =
        "echo 'No verified download manifest exists for this model. Choose base.en.' >&2; false"

    /// Shell guidance keeps the same immutable revision, host allowlist, byte budget, and SHA-256
    /// contract as the in-app downloader. The destination is replaced only after every check passes.
    private static func verifiedDownloadCommand(for model: String) -> String {
        guard let artifact = WhisperModelDownloadPolicy.artifact(for: model) else {
            return unsupportedModelCommand
        }
        let filename = modelFilename(model)
        return """
        (
          set -eu
          umask 077
          model_dir="$HOME/.cache/whisper.cpp"
          filename=\(shellSingleQuoted(filename))
          mkdir -p "$model_dir"
          chmod 700 "$model_dir"
          tmp="$(mktemp "$model_dir/.$filename.XXXXXX")"
          trap 'rm -f "$tmp"' EXIT
          trap 'exit 1' HUP INT TERM
          effective_url="$(
            curl --disable --fail --location --max-redirs 5 \
              --max-filesize \(artifact.byteCount) --max-time 1800 \
              --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
              --proto '=https' --proto-redir '=https' \
              --write-out '%{url_effective}' --output "$tmp" \
              \(shellSingleQuoted(artifact.sourceURL.absoluteString))
          )"
          case "$effective_url" in
            https://huggingface.co/*|https://*.hf.co/*) ;;
            *) echo 'The model host redirected to an untrusted destination.' >&2; exit 1 ;;
          esac
          test "$(stat -f%z "$tmp")" -eq \(artifact.byteCount)
          actual_sha="$(shasum -a 256 "$tmp" | awk '{print $1}')"
          test "$actual_sha" = \(shellSingleQuoted(artifact.sha256))
          chmod 600 "$tmp"
          mv -f "$tmp" "$model_dir/$filename"
          trap - EXIT HUP INT TERM
        )
        """
    }

    /// POSIX-shell single quoting. The manifest currently contains only a fixed safe model, but
    /// keeping this boundary correct prevents a future path or URL from becoming executable text.
    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
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
