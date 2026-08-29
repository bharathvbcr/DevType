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

    /// A missing model is the common case after `brew install` and before downloading one.
    /// It must be named, not reported as a generic launch failure.
    func testMissingModelIsReportedWithItsPath() async throws {
        guard WhisperServerSetup.installedBinaryPath() != nil else {
            throw XCTSkip("whisper.cpp not installed on this machine")
        }
        guard !WhisperServerSetup.hasModel("nonexistent-model-xyz") else {
            return XCTFail("Test model unexpectedly present")
        }

        let result = await WhisperServerController.shared.start(
            model: "nonexistent-model-xyz",
            endpoint: URL(string: "http://127.0.0.1:8099/inference")!
        )

        guard case .failure(let failure) = result else {
            return XCTFail("Started with a missing model")
        }
        guard case .modelMissing(let path) = failure else {
            return XCTFail("Wrong failure: \(failure)")
        }
        XCTAssertTrue(path.contains("ggml-nonexistent-model-xyz.bin"))
        XCTAssertTrue(failure.userMessage.contains(path))
    }

    /// Every failure has to tell the user what to do next; a bare error is not actionable.
    func testEveryFailureHasAnActionableMessage() {
        let failures: [WhisperServerController.StartFailure] = [
            .notInstalled,
            .modelMissing(path: "/tmp/ggml-base.en.bin"),
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
