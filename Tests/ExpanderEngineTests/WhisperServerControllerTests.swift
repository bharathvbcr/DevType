import XCTest
@testable import ExpanderEngine

/// The controller spawns and kills a real process, so the properties that matter most are
/// the ones about restraint: what it refuses to launch, and what it refuses to kill.
///
/// The happy path needs whisper.cpp installed and is exercised by the integration case at
/// the end, which skips when it is not present rather than failing on a machine that never
/// installed it.
final class WhisperServerControllerTests: XCTestCase {

    override func tearDown() {
        WhisperServerController.shared.stopIfManaged()
        super.tearDown()
    }

    // MARK: - Refusing to launch

    /// An unmanifested model must fail as unsupported, independent of whether the binary or a
    /// similarly named file happens to exist on this machine.
    func testUnsupportedModelIsRejectedBeforeBinaryOrFilesystemLookup() async {
        let controller = WhisperServerController(
            binaryPathProvider: { nil },
            modelDirectory: FileManager.default.temporaryDirectory,
            artifactProvider: { _ in nil },
            readinessProbe: { _, _ in false }
        )
        let result = await controller.start(
            model: "nonexistent-model-xyz",
            endpoint: URL(string: "http://127.0.0.1:8099/inference")!
        )
        assertStartFailure(
            result,
            equals: .unsupportedModel(model: "nonexistent-model-xyz")
        )
    }

    /// Every failure has to tell the user what to do next; a bare error is not actionable.
    func testEveryFailureHasAnActionableMessage() {
        let failures: [WhisperServerController.StartFailure] = [
            .invalidEndpoint,
            .notInstalled,
            .unsupportedModel(model: "unverified"),
            .modelMissing(path: "/tmp/ggml-base.en.bin"),
            .modelUnreadable(path: "/tmp/ggml-base.en.bin"),
            .modelWrongSize(path: "/tmp/ggml-base.en.bin", expected: 3, actual: 2),
            .modelDigestMismatch(path: "/tmp/ggml-base.en.bin"),
            .modelChanged(path: "/tmp/ggml-base.en.bin"),
            .startInProgress,
            .cancelled,
            .launchFailed("permission denied"),
            .neverBecameReady(log: "error: failed to load model"),
            .portBusy,
        ]

        for failure in failures {
            let message = failure.userMessage
            XCTAssertFalse(message.isEmpty, "\(failure) has no message")
            XCTAssertGreaterThan(message.count, 20, "\(failure) message is too terse: \(message)")
        }

        XCTAssertTrue(
            WhisperServerController.StartFailure.notInstalled.userMessage.contains("brew install whisper-cpp"),
            "The not-installed message must carry the command that fixes it"
        )
        XCTAssertTrue(
            WhisperServerController.StartFailure
                .neverBecameReady(log: "error: failed to load model")
                .userMessage.contains("failed to load model"),
            "Server output is what explains a model that will not load"
        )
    }

    func testModelDownloadPolicyPinsTheArtifactAndRejectsUnsafeRedirects() throws {
        let artifact = try XCTUnwrap(WhisperModelDownloadPolicy.artifact(for: "base.en"))
        XCTAssertEqual(artifact.byteCount, 147_964_211)
        XCTAssertEqual(
            artifact.sha256,
            "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        )
        XCTAssertTrue(artifact.sourceURL.path.contains(WhisperServerSetup.verifiedModelRevision))
        XCTAssertFalse(artifact.sourceURL.path.contains("/resolve/main/"))
        XCTAssertNil(WhisperModelDownloadPolicy.artifact(for: "../../untrusted"))

        XCTAssertTrue(
            WhisperModelDownloadPolicy.allowsRedirect(
                to: URL(string: "https://us.aws.cdn.hf.co/xet/model")!
            )
        )
        XCTAssertFalse(
            WhisperModelDownloadPolicy.allowsRedirect(
                to: URL(string: "http://us.aws.cdn.hf.co/xet/model")!
            )
        )
        XCTAssertFalse(
            WhisperModelDownloadPolicy.allowsRedirect(
                to: URL(string: "https://hf.co.attacker.invalid/model")!
            )
        )
        XCTAssertFalse(
            WhisperModelDownloadPolicy.allowsRedirect(
                to: URL(string: "https://huggingface.co.attacker.invalid/model")!
            )
        )
    }

    func testModelDownloadBudgetAndDigestAreExact() throws {
        XCTAssertTrue(
            WhisperModelDownloadPolicy.isWithinBudget(
                totalBytesWritten: 10,
                expectedBytes: 10,
                maximumBytes: 10
            )
        )
        XCTAssertFalse(
            WhisperModelDownloadPolicy.isWithinBudget(
                totalBytesWritten: 11,
                expectedBytes: -1,
                maximumBytes: 10
            )
        )
        XCTAssertFalse(
            WhisperModelDownloadPolicy.isWithinBudget(
                totalBytesWritten: 1,
                expectedBytes: 11,
                maximumBytes: 10
            )
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.bin")
        try Data("abc".utf8).write(to: file)

        XCTAssertNoThrow(
            try WhisperModelDownloadPolicy.verify(
                fileAt: file,
                expectedByteCount: 3,
                expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        )
        XCTAssertThrowsError(
            try WhisperModelDownloadPolicy.verify(
                fileAt: file,
                expectedByteCount: 2,
                expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        )
        XCTAssertThrowsError(
            try WhisperModelDownloadPolicy.verify(
                fileAt: file,
                expectedByteCount: 3,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        )
    }

    func testModelVerificationPropagatesCancellation() {
        XCTAssertThrowsError(
            try WhisperModelDownloadPolicy.verify(
                fileAt: URL(fileURLWithPath: "/definitely-not-read"),
                expectedByteCount: 3,
                expectedSHA256: String(repeating: "0", count: 64),
                cancellationCheck: { throw CancellationError() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Cancellation became \(error)")
        }
        XCTAssertFalse(WhisperServerController.DownloadFailure.cancelled.userMessage.isEmpty)
    }

    func testCanonicalModelStatusDistinguishesMissingSizeDigestAndVerifiedBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ggml-fixture.bin")
        let artifact = WhisperModelDownloadPolicy.Artifact(
            sourceURL: URL(string: "https://huggingface.co/example/model.bin")!,
            byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        XCTAssertEqual(
            WhisperModelDownloadPolicy.modelStatus(fileAt: directory, artifact: artifact),
            .unreadable,
            "A directory must not be accepted as a regular model file"
        )

        XCTAssertEqual(
            WhisperModelDownloadPolicy.modelStatus(fileAt: file, artifact: artifact),
            .missing
        )

        try Data("ab".utf8).write(to: file)
        XCTAssertEqual(
            WhisperModelDownloadPolicy.modelStatus(fileAt: file, artifact: artifact),
            .wrongSize(expected: 3, actual: 2)
        )

        try Data("abd".utf8).write(to: file)
        XCTAssertEqual(
            WhisperModelDownloadPolicy.modelStatus(fileAt: file, artifact: artifact),
            .digestMismatch
        )

        try Data("abc".utf8).write(to: file)
        guard case .verified(let verified) = WhisperModelDownloadPolicy.modelStatus(
            fileAt: file,
            artifact: artifact
        ) else {
            return XCTFail("Exact fixture was not accepted")
        }
        XCTAssertTrue(WhisperModelDownloadPolicy.isStillCurrent(verified))

        try Data("abd".utf8).write(to: file, options: .atomic)
        XCTAssertFalse(
            WhisperModelDownloadPolicy.isStillCurrent(verified),
            "Replacing the path after verification must invalidate the launch token."
        )
    }

    func testStartRejectsMissingWrongSizeAndSameSizeWrongDigestModels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-start-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = WhisperModelDownloadPolicy.Artifact(
            sourceURL: URL(string: "https://huggingface.co/example/model.bin")!,
            byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let controller = WhisperServerController(
            binaryPathProvider: { "/usr/bin/false" },
            modelDirectory: directory,
            artifactProvider: { $0 == "fixture" ? artifact : nil },
            readinessProbe: { _, _ in false }
        )
        let endpoint = URL(string: "http://127.0.0.1:8096/inference")!
        let path = directory.appendingPathComponent("ggml-fixture.bin").path

        let missingResult = await controller.start(model: "fixture", endpoint: endpoint)
        assertStartFailure(missingResult, equals: .modelMissing(path: path))

        try Data("ab".utf8).write(to: URL(fileURLWithPath: path))
        let wrongSizeResult = await controller.start(model: "fixture", endpoint: endpoint)
        assertStartFailure(
            wrongSizeResult,
            equals: .modelWrongSize(path: path, expected: 3, actual: 2)
        )

        try Data("abd".utf8).write(to: URL(fileURLWithPath: path))
        let wrongDigestResult = await controller.start(model: "fixture", endpoint: endpoint)
        assertStartFailure(wrongDigestResult, equals: .modelDigestMismatch(path: path))
    }

    func testStartRejectsAPathReplacedBetweenVerificationAndLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-start-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ggml-fixture.bin")
        try Data("abc".utf8).write(to: file)
        let artifact = WhisperModelDownloadPolicy.Artifact(
            sourceURL: URL(string: "https://huggingface.co/example/model.bin")!,
            byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let mutationError = ErrorDescriptionRecorder()
        let controller = WhisperServerController(
            binaryPathProvider: { "/usr/bin/false" },
            modelDirectory: directory,
            artifactProvider: { $0 == "fixture" ? artifact : nil },
            readinessProbe: { _, _ in false },
            beforeModelIdentityRecheckForTesting: { url in
                do {
                    try Data("abd".utf8).write(to: url, options: .atomic)
                } catch {
                    mutationError.record(error)
                }
            }
        )

        let result = await controller.start(
            model: "fixture",
            endpoint: URL(string: "http://127.0.0.1:8096/inference")!
        )
        XCTAssertNil(mutationError.value, mutationError.value ?? "")
        assertStartFailure(result, equals: .modelChanged(path: file.path))
    }

    func testCancellationImmediatelyBeforeLaunchDoesNotSpawnAChild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-prelaunch-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("abc".utf8).write(
            to: directory.appendingPathComponent("ggml-fixture.bin")
        )
        let artifact = WhisperModelDownloadPolicy.Artifact(
            sourceURL: URL(string: "https://huggingface.co/example/model.bin")!,
            byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let controller = WhisperServerController(
            binaryPathProvider: { "/usr/bin/yes" },
            modelDirectory: directory,
            artifactProvider: { $0 == "fixture" ? artifact : nil },
            readinessProbe: { _, _ in false },
            beforeModelIdentityRecheckForTesting: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )
        defer { controller.stopIfManaged() }

        let attempt = Task {
            await controller.start(
                model: "fixture",
                endpoint: URL(string: "http://127.0.0.1:8096/inference")!
            )
        }
        let result = await attempt.value

        assertStartFailure(result, equals: .cancelled)
        XCTAssertFalse(controller.isManagedByApp)
    }

    func testStartUsesInjectedReadinessProbeBeforeAndAfterLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ggml-fixture.bin")
        try Data("abc".utf8).write(to: file)
        let artifact = WhisperModelDownloadPolicy.Artifact(
            sourceURL: URL(string: "https://huggingface.co/example/model.bin")!,
            byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let probeCalls = LockedIntegerCounter()
        let controller = WhisperServerController(
            binaryPathProvider: { "/usr/bin/yes" },
            modelDirectory: directory,
            artifactProvider: { $0 == "fixture" ? artifact : nil },
            readinessProbe: { _, _ in
                probeCalls.increment()
                return probeCalls.value > 1
            }
        )
        defer { controller.stopIfManaged() }

        let result = await controller.start(
            model: "fixture",
            endpoint: URL(string: "http://127.0.0.1:8096/inference")!
        )

        guard case .success = result else {
            return XCTFail("Injected post-launch readiness was bypassed: \(result)")
        }
        XCTAssertGreaterThanOrEqual(probeCalls.value, 2)
        XCTAssertTrue(controller.isManagedByApp)
    }

    func testConcurrentStartsAreSingleFlightAndCancellationStopsTheOwnedChild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-start-flight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("abc".utf8).write(
            to: directory.appendingPathComponent("ggml-fixture.bin")
        )
        let artifact = WhisperModelDownloadPolicy.Artifact(
            sourceURL: URL(string: "https://huggingface.co/example/model.bin")!,
            byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let readiness = PostLaunchReadinessGate()
        let controller = WhisperServerController(
            binaryPathProvider: { "/usr/bin/yes" },
            modelDirectory: directory,
            artifactProvider: { $0 == "fixture" ? artifact : nil },
            readinessProbe: { _, _ in await readiness.probe() }
        )
        defer { controller.stopIfManaged() }
        let endpoint = URL(string: "http://127.0.0.1:8096/inference")!

        let first = Task {
            await controller.start(model: "fixture", endpoint: endpoint)
        }
        await readiness.waitUntilPostLaunchProbe()

        let overlap = await controller.start(model: "fixture", endpoint: endpoint)
        assertStartFailure(overlap, equals: .startInProgress)

        first.cancel()
        await readiness.release()
        let cancelled = await first.value
        assertStartFailure(cancelled, equals: .cancelled)
        XCTAssertFalse(controller.isManagedByApp, "Cancelled startup left its child running")
    }

    func testConcurrentDownloadsAreSingleFlightAndCancellationIsTyped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-download-flight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = WhisperModelDownloadPolicy.Artifact(
            sourceURL: URL(string: "https://huggingface.co/example/model.bin")!,
            byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let gate = AsyncSuspensionGate()
        let controller = WhisperServerController(
            binaryPathProvider: { nil },
            modelDirectory: directory,
            artifactProvider: { $0 == "fixture" ? artifact : nil },
            readinessProbe: { _, _ in false },
            beforeDownloadForTesting: { await gate.wait() }
        )

        let first = Task {
            await controller.downloadModel("fixture")
        }
        await gate.waitUntilEntered()

        let overlap = await controller.downloadModel("fixture")
        assertDownloadFailure(overlap, equals: .downloadInProgress)

        first.cancel()
        await gate.release()
        let cancelled = await first.value
        assertDownloadFailure(cancelled, equals: .cancelled)
    }

    // MARK: - Refusing to kill

    /// A server the user started in their own terminal is theirs. The app may use it and
    /// must not stop it.
    func testStopDoesNothingWhenTheServerIsNotOurs() {
        XCTAssertFalse(WhisperServerController.shared.isManagedByApp)
        XCTAssertFalse(
            WhisperServerController.shared.stop(),
            "stop() claimed to have stopped a server it did not start"
        )
    }

    func testStopIsIdempotent() {
        WhisperServerController.shared.stop()
        WhisperServerController.shared.stop()
        XCTAssertFalse(WhisperServerController.shared.isManagedByApp)
    }

    func testStopIfManagedIsSafeWhenNothingIsRunning() {
        WhisperServerController.shared.stopIfManaged()
        XCTAssertFalse(WhisperServerController.shared.isManagedByApp)
    }

    /// An endpoint already answering means someone else is serving it. Starting a second
    /// server on the same port would fail confusingly; the app defers instead.
    func testAlreadyServedEndpointIsDeferredToRatherThanContested() async throws {
        let server = try? StubHTTPServer()
        guard let server else { throw XCTSkip("Could not bind a local port for the test") }
        defer { server.stop() }

        let result = await WhisperServerController.shared.start(
            endpoint: URL(string: "http://127.0.0.1:\(server.port)/inference")!
        )

        guard case .failure(.portBusy) = result else {
            return XCTFail("Expected portBusy, got \(result)")
        }
        XCTAssertFalse(
            WhisperServerController.shared.isManagedByApp,
            "The app took ownership of a server it did not start"
        )
    }

    // MARK: - Integration

    /// The real thing, when the machine has it. Start, confirm it answers, stop, confirm it
    /// stops — and confirm the app cleans up after itself.
    func testStartAndStopRoundTrip() async throws {
        guard WhisperServerSetup.installedBinaryPath() != nil,
              WhisperServerSetup.hasModel() else {
            throw XCTSkip("whisper.cpp or its model is not installed on this machine")
        }

        let endpoint = URL(string: "http://127.0.0.1:8097/inference")!
        let result = await WhisperServerController.shared.start(endpoint: endpoint)

        guard case .success = result else {
            return XCTFail("Start failed: \(result)")
        }
        XCTAssertTrue(WhisperServerController.shared.isManagedByApp)

        let reachable = await WhisperServerSetup.isReachable(endpoint: endpoint, timeout: 2.0)
        XCTAssertTrue(reachable, "Reported ready but the endpoint does not answer")

        XCTAssertTrue(WhisperServerController.shared.stop())
        XCTAssertFalse(WhisperServerController.shared.isManagedByApp)

        let stillUp = await WhisperServerSetup.isReachable(endpoint: endpoint, timeout: 1.0)
        XCTAssertFalse(stillUp, "Server survived stop()")
    }

    private func assertStartFailure(
        _ result: Result<Void, WhisperServerController.StartFailure>,
        equals expected: WhisperServerController.StartFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let actual) = result else {
            return XCTFail("Expected start failure \(expected), got success", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertDownloadFailure(
        _ result: Result<URL, WhisperServerController.DownloadFailure>,
        equals expected: WhisperServerController.DownloadFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let actual) = result else {
            return XCTFail("Expected download failure \(expected), got success", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private final class ErrorDescriptionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        lock.withLock { storage }
    }

    func record(_ error: Error) {
        lock.withLock { storage = error.localizedDescription }
    }
}

private final class LockedIntegerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private actor AsyncSuspensionGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}

private actor PostLaunchReadinessGate {
    private var probeCount = 0
    private let suspension = AsyncSuspensionGate()

    func probe() async -> Bool {
        probeCount += 1
        if probeCount == 1 {
            return false
        }
        await suspension.wait()
        return false
    }

    func waitUntilPostLaunchProbe() async {
        await suspension.waitUntilEntered()
    }

    func release() async {
        await suspension.release()
    }
}

/// Minimal listener used to occupy a port, so "someone else is already serving this" can be
/// tested without whisper.cpp installed.
private final class StubHTTPServer {
    let port: UInt16
    private let socketFD: Int32
    private var isStopped = false

    init() throws {
        // Work on locals; the stored properties are assigned once everything succeeded, so
        // no closure captures `self` mid-initialisation.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "stub", code: 1) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0   // let the kernel choose
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: "stub", code: 2)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }

        socketFD = fd
        port = actual.sin_port.byteSwapped

        // Answer requests with 200 so the readiness probe succeeds.
        DispatchQueue.global(qos: .utility).async {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
                _ = response.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        close(socketFD)
    }
}
