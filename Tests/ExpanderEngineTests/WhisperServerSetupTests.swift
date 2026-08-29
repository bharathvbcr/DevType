import XCTest
@testable import ExpanderEngine

/// The setup helper hands the user commands to paste into a terminal, so the commands have
/// to be right — a wrong flag or a stale URL is worse than no guidance at all.
///
/// Every fact asserted here was verified against the current whisper.cpp documentation and
/// a live request to the model host: the Homebrew formula is `whisper-cpp`, the binary is
/// `whisper-server`, the default port is 8080, the inference route is `/inference`, and the
/// ggml models live in `ggerganov/whisper.cpp` on Hugging Face.
final class WhisperServerSetupTests: XCTestCase {

    // MARK: - Commands

    func testInstallStepUsesTheRealHomebrewFormula() {
        let steps = WhisperServerSetup.steps(for: .notInstalled)
        guard let install = steps.first else { return XCTFail("No install step") }

        XCTAssertEqual(install.command, "brew install whisper-cpp")
        XCTAssertTrue(install.isPending)
    }

    func testRunStepUsesTheRealBinaryAndFlags() {
        let endpoint = URL(string: "http://127.0.0.1:9090/inference")!
        let steps = WhisperServerSetup.steps(for: .notInstalled, endpoint: endpoint)
        guard let run = steps.last else { return XCTFail("No run step") }

        XCTAssertTrue(run.command.hasPrefix("whisper-server "), "Wrong binary: \(run.command)")
        XCTAssertTrue(run.command.contains("--host 127.0.0.1"))
        XCTAssertTrue(run.command.contains("--port 9090"), "Port not taken from the endpoint")
        XCTAssertTrue(run.command.contains("-m "), "No model flag")
        XCTAssertTrue(run.command.contains("ggml-base.en.bin"))
    }

    /// The endpoint's port must flow into the run command, or the user starts a server the
    /// app is not talking to.
    func testRunCommandPortTracksTheConfiguredEndpoint() {
        for port in [8080, 8081, 9000] {
            let endpoint = URL(string: "http://127.0.0.1:\(port)/inference")!
            let steps = WhisperServerSetup.steps(for: .notInstalled, endpoint: endpoint)
            XCTAssertTrue(
                steps.last!.command.contains("--port \(port)"),
                "Run command did not use port \(port)"
            )
        }
    }

    func testRunStepUsesTheDetectedBinaryPath() {
        let binary = "/opt/homebrew/bin/whisper-cpp-server"
        let steps = WhisperServerSetup.steps(for: .installedNotRunning(binaryPath: binary))
        XCTAssertTrue(steps.last!.command.hasPrefix("\(binary) "))
    }

    func testModelDownloadUsesTheGgmlRepository() {
        let url = WhisperServerSetup.modelDownloadURL()
        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertTrue(url.path.contains("ggerganov/whisper.cpp"))
        XCTAssertTrue(url.path.hasSuffix("ggml-base.en.bin"))
    }

    func testModelFilenameFollowsTheGgmlConvention() {
        XCTAssertEqual(WhisperServerSetup.modelFilename("base.en"), "ggml-base.en.bin")
        XCTAssertEqual(WhisperServerSetup.modelFilename("large-v3-turbo"), "ggml-large-v3-turbo.bin")
    }

    /// The download command must create the directory it writes into, or it fails on a
    /// clean machine — which is exactly the machine that needs it.
    func testDownloadCommandCreatesItsDirectory() {
        let steps = WhisperServerSetup.steps(for: .notInstalled)
        let download = steps[1]
        XCTAssertTrue(download.command.contains("mkdir -p"), "Download would fail on a clean machine")
        XCTAssertTrue(download.command.contains("curl"))
        XCTAssertTrue(download.command.contains(WhisperServerSetup.modelDownloadURL().absoluteString))
    }

    // MARK: - Step pending state

    func testAllStepsPendingWhenNothingIsInstalled() {
        let steps = WhisperServerSetup.steps(for: .notInstalled)
        XCTAssertEqual(steps.count, 3)
        XCTAssertTrue(steps[0].isPending, "Install should be pending")
        XCTAssertTrue(steps[2].isPending, "Run should be pending")
    }

    func testInstallIsNotPendingOnceTheBinaryExists() {
        let steps = WhisperServerSetup.steps(for: .installedNotRunning(binaryPath: "/opt/homebrew/bin/whisper-server"))
        XCTAssertFalse(steps[0].isPending, "Install step still pending after install")
        XCTAssertTrue(steps[2].isPending, "Run step should still be pending")
    }

    func testNothingIsPendingWhenTheServerIsRunning() {
        let steps = WhisperServerSetup.steps(for: .running)
        XCTAssertFalse(steps[0].isPending)
        XCTAssertFalse(steps[2].isPending)
    }

    func testPendingCommandsOmitCompletedSteps() {
        let running = WhisperServerSetup.pendingCommands(for: .running)
        XCTAssertFalse(running.contains("brew install"))
        XCTAssertFalse(running.contains("whisper-server --host"))

        let fresh = WhisperServerSetup.pendingCommands(for: .notInstalled)
        XCTAssertTrue(fresh.contains("brew install whisper-cpp"))
        XCTAssertTrue(fresh.contains("whisper-server --host"))
    }

    // MARK: - Detection

    /// Stock whisper-server has no `/health` handler. Readiness is its GET page at the
    /// request-path root, as documented by the upstream server implementation.
    func testReadinessProbeUsesTheServerRequestPathRoot() {
        XCTAssertEqual(
            WhisperServerSetup.readinessProbeURL(
                for: URL(string: "http://127.0.0.1:8080/inference")!
            ).absoluteString,
            "http://127.0.0.1:8080/"
        )
        XCTAssertEqual(
            WhisperServerSetup.readinessProbeURL(
                for: URL(string: "http://127.0.0.1:8080/api/inference")!
            ).absoluteString,
            "http://127.0.0.1:8080/api/"
        )
    }

    /// Detection must look where Homebrew actually installs, on both architectures.
    func testSearchPathsCoverBothHomebrewPrefixes() {
        XCTAssertTrue(WhisperServerSetup.searchPaths.contains("/opt/homebrew/bin/whisper-server"),
            "Apple Silicon Homebrew prefix missing")
        XCTAssertTrue(WhisperServerSetup.searchPaths.contains("/usr/local/bin/whisper-server"),
            "Intel Homebrew prefix missing")
    }

    /// An unreachable endpoint must report unreachable rather than hanging — this runs on
    /// every Preferences open.
    func testUnreachableEndpointReturnsQuickly() async {
        let start = Date()
        let reachable = await WhisperServerSetup.isReachable(
            endpoint: URL(string: "http://127.0.0.1:1/inference")!,
            timeout: 1.0
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(reachable)
        XCTAssertLessThan(elapsed, 5.0, "Reachability probe took \(elapsed)s")
    }

    func testDetectFallsBackToFilesystemWhenUnreachable() async {
        let state = await WhisperServerSetup.detect(
            endpoint: URL(string: "http://127.0.0.1:1/inference")!,
            timeout: 0.5
        )
        // Whichever machine this runs on, an unreachable endpoint can never be `.running`.
        XCTAssertNotEqual(state, .running)
    }

    func testSummaryDistinguishesTheThreeStates() {
        let summaries = [
            WhisperServerSetup.summary(for: .running),
            WhisperServerSetup.summary(for: .installedNotRunning(binaryPath: "/x")),
            WhisperServerSetup.summary(for: .notInstalled),
        ]
        XCTAssertEqual(Set(summaries).count, 3, "States must be distinguishable to the user")
    }

    // MARK: - Audio payload

    /// whisper.cpp reads 16 kHz mono 16-bit PCM WAV. The header has to be right or the
    /// server rejects perfectly good audio.
    func testWavHeaderIsCanonical() throws {
        let pcm = Data(repeating: 0, count: 3200)   // 0.1s of 16 kHz mono int16
        let wav = WhisperAudioPayload.wavContainer(
            pcm: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        XCTAssertEqual(wav.count, 44 + pcm.count, "Header must be exactly 44 bytes")
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")

        // Read the fixed-offset header fields directly.
        let sampleRate = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian }
        let channels = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: UInt16.self).littleEndian }
        let bits = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self).littleEndian }
        let dataSize = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian }

        XCTAssertEqual(sampleRate, 16000)
        XCTAssertEqual(channels, 1)
        XCTAssertEqual(bits, 16)
        XCTAssertEqual(Int(dataSize), pcm.count)
    }

    func testWavContainerHandlesEmptyAudio() {
        let wav = WhisperAudioPayload.wavContainer(
            pcm: Data(), sampleRate: 16000, channels: 1, bitsPerSample: 16
        )
        XCTAssertEqual(wav.count, 44)
    }
}
