import Darwin
import Foundation
import XCTest
@testable import ExpanderEngine

/// Adversarial coverage for managed whisper traffic. Production code is not the place
/// these observations belong; the closures record the URL that would have been requested.
final class WhisperManagedInferenceAttackTests: XCTestCase {
    func testManagedLocalhostAndIPv6HitBoundHostPortAndSavedPath() async throws {
        try await assertAccepted(
            savedRaw: "http://localhost:38421/inference",
            managed: true,
            probe: "http://127.0.0.1:38421/",
            post: "http://127.0.0.1:38421/inference"
        )
        try await assertAccepted(
            savedRaw: "http://[::1]:38422/inference",
            managed: true,
            probe: "http://127.0.0.1:38422/",
            post: "http://127.0.0.1:38422/inference"
        )
    }

    func testManagedPathShapesKeepEncodingTrailingSlashAndEmptyPath() async throws {
        let cases: [(String, String, String)] = [
            (
                "http://localhost:38423/a%20b/inference",
                "http://127.0.0.1:38423/a%20b/",
                "http://127.0.0.1:38423/a%20b/inference"
            ),
            (
                "http://localhost:38424/a%2Fb/inference",
                "http://127.0.0.1:38424/a%2Fb/",
                "http://127.0.0.1:38424/a%2Fb/inference"
            ),
            (
                "http://[::1]:38425/inference/",
                "http://127.0.0.1:38425/",
                "http://127.0.0.1:38425/inference/"
            ),
            (
                "http://localhost:38426",
                "http://127.0.0.1:38426/",
                "http://127.0.0.1:38426"
            ),
            (
                "http://localhost:38427/",
                "http://127.0.0.1:38427/",
                "http://127.0.0.1:38427/"
            ),
            (
                "http://localhost:38428/%E6%8E%A8%E8%AB%96/inference",
                "http://127.0.0.1:38428/%E6%8E%A8%E8%AB%96/",
                "http://127.0.0.1:38428/%E6%8E%A8%E8%AB%96/inference"
            ),
            (
                "http://[::1]:38429/caf%C3%A9/inference/",
                "http://127.0.0.1:38429/caf%C3%A9/",
                "http://127.0.0.1:38429/caf%C3%A9/inference/"
            ),
        ]
        for (saved, probe, post) in cases {
            try await assertAccepted(savedRaw: saved, managed: true, probe: probe, post: post)
        }

        let unicode = try XCTUnwrap(URL(string: "http://localhost:38430/\u{63A8}\u{8AD6}/inference"))
        let bound = WhisperServerSetup.spawnedChildInferenceURL(port: 38_430, savedEndpoint: unicode)
        XCTAssertEqual(bound.host, "127.0.0.1")
        XCTAssertEqual(bound.port, 38_430)
        XCTAssertEqual(percentEncodedPath(bound), percentEncodedPath(unicode))
        try await assertAccepted(
            savedRaw: unicode.absoluteString,
            managed: true,
            probe: "http://127.0.0.1:38430/%E6%8E%A8%E8%AB%96/",
            post: bound.absoluteString
        )
    }

    /// The bound URL is built from the path only. A query or fragment on a valid saved
    /// endpoint is removed for both the readiness probe and the transcription POST.
    func testManagedRewriteDropsQueryAndFragment() async throws {
        let savedRaw = "http://localhost:38431/inference?x=1&y=a%20b#frag"
        let saved = try XCTUnwrap(URL(string: savedRaw))
        XCTAssertEqual(percentEncodedQuery(saved), "x=1&y=a%20b")
        XCTAssertEqual(URLComponents(url: saved, resolvingAgainstBaseURL: false)?.fragment, "frag")
        let observed = try await assertAccepted(
            savedRaw: savedRaw,
            managed: true,
            probe: "http://127.0.0.1:38431/",
            post: "http://127.0.0.1:38431/inference"
        )
        XCTAssertNil(percentEncodedQuery(observed.probe))
        XCTAssertNil(percentEncodedQuery(observed.post))
        XCTAssertNil(fragment(observed.post))

        let bareQuery = "http://[::1]:38432?x=1"
        let bare = try await assertAccepted(
            savedRaw: bareQuery,
            managed: true,
            probe: "http://127.0.0.1:38432/",
            post: "http://127.0.0.1:38432"
        )
        XCTAssertNil(percentEncodedQuery(bare.post))
    }

    func testUnmanagedLocalhostKeepsHostPathAndQuery() async throws {
        let observed = try await assertAccepted(
            savedRaw: "http://localhost:38433/inference?x=1&y=a%20b#frag",
            managed: false,
            probe: "http://localhost:38433/?x=1&y=a%20b#frag",
            post: "http://localhost:38433/inference?x=1&y=a%20b#frag"
        )
        XCTAssertEqual(observed.probe?.host, "localhost")
        XCTAssertNotEqual(observed.post?.host, "127.0.0.1")
        XCTAssertEqual(percentEncodedQuery(observed.post), "x=1&y=a%20b")

        try await assertAccepted(
            savedRaw: "http://[::1]:38434/%E6%8E%A8%E8%AB%96/inference/",
            managed: false,
            probe: "http://[::1]:38434/%E6%8E%A8%E8%AB%96/",
            post: "http://[::1]:38434/%E6%8E%A8%E8%AB%96/inference/"
        )
    }

    func testNonLoopbackIsNotRewrittenEvenWhenLookupWouldReturnLoopback() async throws {
        let loopback = URL(string: "http://127.0.0.1:38435/inference")!
        let rejected = [
            "http://127.0.0.2:38435/inference",
            "http://0.0.0.0:38435/inference",
            "http://example.com:38435/inference",
            "http://[::2]:38435/inference",
            "https://whisper.example/inference",
        ]
        for raw in rejected {
            let saved = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertFalse(LocalEndpointSecurity.isValid(saved), raw)
            let lookups = LockedCount()
            let probed = LockedURLBox()
            let posted = LockedURLBox()
            let adapter = WhisperCppServerAdapter(
                endpointURL: saved,
                transport: { request, _ in
                    posted.set(request.url)
                    throw URLError(.badServerResponse)
                },
                managedInferenceURL: {
                    lookups.increment()
                    return loopback
                },
                reachability: { url in
                    probed.set(url)
                    return true
                }
            )
            let readiness = await adapter.probe()
            guard case .requiresConfiguration(.invalidEndpointFormat) = readiness else {
                return XCTFail("\(raw) probe was \(readiness)")
            }
            XCTAssertEqual(lookups.value, 0, "lookup ran before the saved URL was accepted: \(raw)")
            XCTAssertNil(probed.value, raw)

            let audioURL = try makeAudioFile()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            do {
                for try await _ in adapter.transcribe(makeRequest(audioURL: audioURL)) {}
                XCTFail("non-loopback \(raw) was transcribed")
            } catch let failure as VoiceFailure {
                XCTAssertEqual(failure.code, .endpointUnreachable, raw)
            } catch {
                XCTFail("\(raw) threw \(error)")
            }
            XCTAssertNil(posted.value, raw)
            XCTAssertEqual(lookups.value, 0, raw)
        }
    }

    func testDefaultEndpointIsUnchangedWhenLookupParameterDefaultsToNil() async throws {
        let probed = LockedURLBox()
        let posted = LockedURLBox()
        let adapter = WhisperCppServerAdapter(
            endpointURL: VoicePreferences.defaultWhisperEndpoint,
            transport: { request, _ in
                posted.set(request.url)
                return Self.ok(request.url)
            },
            reachability: { url in
                probed.set(url)
                return true
            }
        )
        let readiness = await adapter.probe()
        XCTAssertTrue(readiness.isReady, "\(readiness)")
        XCTAssertEqual(probed.value?.absoluteString, "http://127.0.0.1:8080/")
        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        for try await _ in adapter.transcribe(makeRequest(audioURL: audioURL)) {}
        XCTAssertEqual(posted.value?.absoluteString, "http://127.0.0.1:8080/inference")
        XCTAssertEqual(posted.value?.host, "127.0.0.1")
        XCTAssertEqual(posted.value?.port, 8080)
        XCTAssertEqual(posted.value?.path, "/inference")

        let unmanaged = try await assertAccepted(
            savedRaw: "http://localhost:38436/inference",
            managed: nil,
            probe: "http://localhost:38436/",
            post: "http://localhost:38436/inference"
        )
        XCTAssertEqual(unmanaged.post?.host, "localhost")
    }

    func testManagedInferenceURLIsNilWhenNoChildIsRunning() async throws {
        let idle = makeController(binary: { "/usr/bin/true" }, probe: { _, _ in true })
        XCTAssertNil(idle.managedInferenceURL)
        XCTAssertFalse(idle.isManagedByApp)
        XCTAssertNil(idle.managedInferenceURL)

        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("no-such-whisper-server").path
        let failed = makeController(
            binary: { missing },
            directory: directory,
            probe: { _, _ in false }
        )
        let launched = await failed.start(model: "fixture", endpoint: URL(string: "http://localhost:38437/inference")!)
        guard case .failure(.launchFailed(_)) = launched else {
            return XCTFail("missing binary was \(launched)")
        }
        XCTAssertNil(failed.managedInferenceURL)
        XCTAssertFalse(failed.isManagedByApp)
        let again = await failed.start(model: "fixture", endpoint: URL(string: "http://localhost:38437/inference")!)
        guard case .failure(.launchFailed(_)) = again else {
            return XCTFail("a failed launch left the controller wedged: \(again)")
        }
        XCTAssertNil(failed.managedInferenceURL)

        let endpoint = URL(string: "http://localhost:38438/inference")!
        let started = try await startSleepingChild(endpoint: endpoint, readyOnBoundPort: true)
        defer { cleanup(started) }
        XCTAssertEqual(started.controller.managedInferenceURL?.host, "127.0.0.1")
        XCTAssertEqual(started.controller.managedInferenceURL?.port, 38_438)
        XCTAssertEqual(started.controller.managedInferenceURL?.path, "/inference")
        let stoppedAt = ContinuousClock.now
        XCTAssertTrue(started.controller.stop())
        XCTAssertLessThan(ContinuousClock.now - stoppedAt, .milliseconds(500))
        XCTAssertNil(started.controller.managedInferenceURL)
        XCTAssertFalse(started.controller.isManagedByApp)
        XCTAssertNil(started.controller.managedInferenceURL)
    }

    func testCancellationAfterLaunchClearsManagedInferenceURL() async throws {
        let endpoint = URL(string: "http://[::1]:38439/custom/inference")!
        let hung = try await startSleepingChild(endpoint: endpoint, readyOnBoundPort: false)
        defer { cleanup(hung) }
        XCTAssertEqual(hung.controller.managedInferenceURL?.absoluteString, "http://127.0.0.1:38439/custom/inference")
        hung.task?.cancel()
        let startedAt = ContinuousClock.now
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline && hung.controller.managedInferenceURL != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertLessThan(ContinuousClock.now - startedAt, .milliseconds(500))
        XCTAssertNil(hung.controller.managedInferenceURL)
        XCTAssertFalse(hung.controller.isManagedByApp)
        hung.release.set(true)
        let result = await hung.task?.value
        guard case .failure(.cancelled)? = result else {
            return XCTFail("cancel after launch was \(String(describing: result))")
        }
        XCTAssertNil(hung.controller.managedInferenceURL)
        XCTAssertFalse(hung.controller.stop())
    }

    func testOutOfRangePortsFailBeforeTheProbePreconditionAndMissingPortUses8080() async throws {
        let outOfRange = [
            "http://127.0.0.1:0/inference",
            "http://localhost:0/inference",
            "http://[::1]:0/inference",
            "http://127.0.0.1:65536/inference",
            "http://localhost:65536/x",
            "http://[::1]:65536/inference",
        ]
        for raw in outOfRange {
            let endpoint = try XCTUnwrap(URL(string: raw), raw)
            let port = try XCTUnwrap(endpoint.port, raw)
            XCTAssertFalse((1 ... 65_535).contains(port), raw)
            XCTAssertFalse(LocalEndpointSecurity.isValid(endpoint), raw)
            let launches = LockedCount()
            let probes = LockedCount()
            let controller = makeController(
                binary: {
                    launches.increment()
                    return "/usr/bin/true"
                },
                probe: { _, _ in
                    probes.increment()
                    return false
                }
            )
            let result = await controller.start(model: "fixture", endpoint: endpoint)
            guard case .failure(.invalidEndpoint) = result else {
                return XCTFail("\(raw) was \(result)")
            }
            XCTAssertEqual(probes.value, 0, raw)
            XCTAssertEqual(launches.value, 0, raw)
            XCTAssertNil(controller.managedInferenceURL, raw)
            XCTAssertFalse(controller.stop())
        }

        for raw in ["http://localhost/inference", "http://[::1]/inference", "http://127.0.0.1/inference"] {
            let endpoint = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertNil(endpoint.port, raw)
            XCTAssertTrue(LocalEndpointSecurity.isValid(endpoint), raw)
            let child = try await startSleepingChild(endpoint: endpoint, readyOnBoundPort: true)
            defer { cleanup(child) }
            let args = try String(contentsOf: child.argsFile, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            XCTAssertEqual(Array(args.prefix(4)), ["--host", "127.0.0.1", "--port", "8080"], raw)
            XCTAssertEqual(child.probes.values.first?.absoluteString, endpoint.absoluteString, raw)
            for url in child.probes.values.dropFirst() {
                XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8080/", raw)
            }
            XCTAssertEqual(
                child.controller.managedInferenceURL?.absoluteString,
                "http://127.0.0.1:8080/inference",
                raw
            )
            let adapterProbe = LockedURLBox()
            let adapterPost = LockedURLBox()
            let adapter = WhisperCppServerAdapter(
                endpointURL: endpoint,
                transport: { request, _ in
                    adapterPost.set(request.url)
                    return Self.ok(request.url)
                },
                managedInferenceURL: { child.controller.managedInferenceURL },
                reachability: { url in
                    adapterProbe.set(url)
                    return true
                }
            )
            let readiness = await adapter.probe()
            XCTAssertTrue(readiness.isReady, "\(raw) \(readiness)")
            XCTAssertEqual(adapterProbe.value?.absoluteString, "http://127.0.0.1:8080/", raw)
            let audioURL = try makeAudioFile()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            for try await _ in adapter.transcribe(makeRequest(audioURL: audioURL)) {}
            XCTAssertEqual(adapterPost.value?.host, "127.0.0.1", raw)
            XCTAssertEqual(adapterPost.value?.port, 8080, raw)
            XCTAssertEqual(adapterPost.value?.path, "/inference", raw)
        }
    }

    func testSpawnedChildAndAdapterUseTheSameBoundURLUntilStop() async throws {
        let endpoint = URL(string: "http://localhost:38441/api/inference?keep=1")!
        let child = try await startSleepingChild(endpoint: endpoint, readyOnBoundPort: true)
        defer { cleanup(child) }
        XCTAssertEqual(child.probes.values.first?.host, "localhost")
        for url in child.probes.values.dropFirst() {
            XCTAssertEqual(url.absoluteString, "http://127.0.0.1:38441/")
        }
        let bound = "http://127.0.0.1:38441/api/inference"
        XCTAssertEqual(child.controller.managedInferenceURL?.absoluteString, bound)
        XCTAssertNil(percentEncodedQuery(child.controller.managedInferenceURL))

        let probed = LockedURLBox()
        let posted = LockedURLBox()
        let adapter = WhisperCppServerAdapter(
            endpointURL: endpoint,
            transport: { request, _ in
                posted.set(request.url)
                return Self.ok(request.url)
            },
            managedInferenceURL: { child.controller.managedInferenceURL },
            reachability: { url in
                probed.set(url)
                return true
            }
        )
        let readiness = await adapter.probe()
        XCTAssertTrue(readiness.isReady, "\(readiness)")
        XCTAssertEqual(probed.value?.absoluteString, "http://127.0.0.1:38441/api/")
        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        for try await _ in adapter.transcribe(makeRequest(audioURL: audioURL)) {}
        XCTAssertEqual(posted.value?.absoluteString, bound)
        XCTAssertNil(percentEncodedQuery(posted.value))

        XCTAssertTrue(child.controller.stop())
        XCTAssertNil(child.controller.managedInferenceURL)
        let afterStop = LockedURLBox()
        let released = WhisperCppServerAdapter(
            endpointURL: endpoint,
            transport: { request, _ in
                afterStop.set(request.url)
                return Self.ok(request.url)
            },
            managedInferenceURL: { child.controller.managedInferenceURL },
            reachability: { _ in true }
        )
        for try await _ in released.transcribe(makeRequest(audioURL: audioURL)) {}
        XCTAssertEqual(afterStop.value?.absoluteString, endpoint.absoluteString)
        XCTAssertEqual(afterStop.value?.host, "localhost")
        XCTAssertEqual(percentEncodedQuery(afterStop.value), "keep=1")
    }

    private struct ObservedURLs {
        var probe: URL?
        var post: URL?
    }

    @discardableResult
    private func assertAccepted(
        savedRaw: String,
        managed: Bool?,
        probe: String,
        post: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ObservedURLs {
        let saved = try XCTUnwrap(URL(string: savedRaw), savedRaw, file: file, line: line)
        XCTAssertTrue(LocalEndpointSecurity.isValid(saved), savedRaw, file: file, line: line)
        let bound: URL?
        if managed == true {
            let port = try XCTUnwrap(saved.port, savedRaw, file: file, line: line)
            bound = WhisperServerSetup.spawnedChildInferenceURL(port: port, savedEndpoint: saved)
            XCTAssertEqual(bound?.absoluteString, post, savedRaw, file: file, line: line)
        } else {
            bound = nil
        }
        let lookups = LockedCount()
        let probed = LockedURLBox()
        let posted = LockedURLBox()
        let adapter = WhisperCppServerAdapter(
            endpointURL: saved,
            transport: { request, _ in
                posted.set(request.url)
                XCTAssertEqual(request.httpMethod, "POST", file: file, line: line)
                return Self.ok(request.url)
            },
            managedInferenceURL: {
                lookups.increment()
                return bound
            },
            reachability: { url in
                probed.set(url)
                return true
            }
        )
        let readiness = await adapter.probe()
        XCTAssertTrue(readiness.isReady, "\(savedRaw) probe \(readiness)", file: file, line: line)
        XCTAssertEqual(probed.value?.absoluteString, probe, savedRaw, file: file, line: line)
        XCTAssertEqual(probed.value?.host, URL(string: probe)?.host, savedRaw, file: file, line: line)
        XCTAssertEqual(probed.value?.port, URL(string: probe)?.port, savedRaw, file: file, line: line)
        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var completed = false
        for try await event in adapter.transcribe(makeRequest(audioURL: audioURL)) {
            if case .completed = event { completed = true }
        }
        XCTAssertTrue(completed, savedRaw, file: file, line: line)
        XCTAssertEqual(posted.value?.absoluteString, post, savedRaw, file: file, line: line)
        XCTAssertEqual(posted.value?.host, URL(string: post)?.host, savedRaw, file: file, line: line)
        XCTAssertEqual(posted.value?.port, URL(string: post)?.port, savedRaw, file: file, line: line)
        XCTAssertEqual(lookups.value, 2, savedRaw, file: file, line: line)
        XCTAssertEqual(adapter.endpointURL.absoluteString, saved.absoluteString, savedRaw, file: file, line: line)
        return ObservedURLs(probe: probed.value, post: posted.value)
    }

    private struct RunningChild {
        let controller: WhisperServerController
        let directory: URL
        let argsFile: URL
        let pidFile: URL
        let probes: LockedURLList
        let release: LockedFlag
        var task: Task<Result<Void, WhisperServerController.StartFailure>, Never>?
        var pid: pid_t?
    }

    private func cleanup(_ child: RunningChild) {
        child.release.set(true)
        child.controller.stopIfManaged()
        if let pid = child.pid { terminateIfSleep(pid) }
        try? FileManager.default.removeItem(at: child.directory)
    }

    private func startSleepingChild(endpoint: URL, readyOnBoundPort: Bool) async throws -> RunningChild {
        let directory = try makeFixtureDirectory()
        let argsFile = directory.appendingPathComponent("args.txt")
        let pidFile = directory.appendingPathComponent("child.pid")
        let script = try writeExecutableScript(
            named: "sleep-child.sh",
            in: directory,
            body: """
            #!/bin/sh
            printf '%s\\n' "$@" > \(shellSingleQuoted(argsFile.path))
            echo $$ > \(shellSingleQuoted(pidFile.path))
            exec sleep 30
            """
        )
        let probes = LockedURLList()
        let entered = LockedCount()
        let release = LockedFlag()
        let controller = makeController(
            binary: { script.path },
            directory: directory,
            probe: { url, _ in
                let index = probes.append(url)
                if index == 1 { return false }
                if readyOnBoundPort { return true }
                entered.increment()
                while !release.value {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return false
            }
        )
        if readyOnBoundPort {
            let result = await controller.start(model: "fixture", endpoint: endpoint)
            guard case .success = result else {
                controller.stopIfManaged()
                try? FileManager.default.removeItem(at: directory)
                XCTFail("child did not become ready: \(result) probes=\(probes.values)")
                throw CocoaError(.userCancelled)
            }
            let pid = try await waitForPID(at: pidFile)
            return RunningChild(
                controller: controller,
                directory: directory,
                argsFile: argsFile,
                pidFile: pidFile,
                probes: probes,
                release: release,
                task: nil,
                pid: pid
            )
        }

        let task = Task { await controller.start(model: "fixture", endpoint: endpoint) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && (entered.value == 0 || controller.managedInferenceURL == nil) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try? await waitForPID(at: pidFile)
        if entered.value == 0 || controller.managedInferenceURL == nil {
            release.set(true)
            _ = await task.value
            controller.stopIfManaged()
            if let pid { terminateIfSleep(pid) }
            try? FileManager.default.removeItem(at: directory)
            XCTFail("hung child never published a bound URL; probes=\(probes.values)")
            throw CocoaError(.userCancelled)
        }
        return RunningChild(
            controller: controller,
            directory: directory,
            argsFile: argsFile,
            pidFile: pidFile,
            probes: probes,
            release: release,
            task: task,
            pid: pid
        )
    }

    private func makeController(
        binary: @escaping @Sendable () -> String?,
        directory: URL? = nil,
        probe: @escaping @Sendable (URL, TimeInterval) async -> Bool
    ) -> WhisperServerController {
        WhisperServerController(
            binaryPathProvider: binary,
            modelDirectory: directory ?? FileManager.default.temporaryDirectory,
            artifactProvider: { $0 == "fixture" ? Self.fixtureArtifact : nil },
            readinessProbe: probe
        )
    }

    private static let fixtureArtifact = WhisperModelDownloadPolicy.Artifact(
        sourceURL: URL(string: "https://huggingface.co/example/model.bin")!,
        byteCount: 3,
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-whisper-attack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: directory.appendingPathComponent("ggml-fixture.bin"))
        return directory
    }

    private func writeExecutableScript(named name: String, in directory: URL, body: String) throws -> URL {
        let script = directory.appendingPathComponent(name)
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitForPID(at url: URL) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("child did not record a pid")
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func terminateIfSleep(_ pid: pid_t) {
        guard kill(pid, 0) == 0 else { return }
        let command = commandLine(of: pid)
        guard command == "sleep 30" || command.hasSuffix("/sleep 30") else { return }
        _ = kill(pid, SIGKILL)
    }

    private func commandLine(of pid: pid_t) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func percentEncodedPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
    }

    private func percentEncodedQuery(_ url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    }

    private func fragment(_ url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
    }

    private static func ok(_ url: URL?) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: url ?? URL(string: "http://127.0.0.1/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data("{\"text\":\"ok\"}".utf8), response)
    }

    private func makeAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-attack-\(UUID().uuidString).wav")
        let pcm = Data(repeating: 0, count: 100 * MemoryLayout<Int16>.size)
        try WhisperAudioPayload.wavContainer(
            pcm: pcm,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        ).write(to: url)
        return url
    }

    private func makeRequest(audioURL: URL) -> SpeechRequest {
        SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: AudioArtifact(
                fileURL: audioURL,
                format: "wav",
                sampleRate: 16000,
                channelCount: 1,
                frameCount: 100,
                durationSeconds: 0.01,
                byteCount: 244,
                sha256Hex: "redacted",
                gapCount: 0
            ),
            deadline: Date().addingTimeInterval(10),
            privacyRoute: .localNetworkOnly
        )
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set(_ value: Bool) { lock.withLock { storage = value } }
}

private final class LockedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?
    var value: URL? { lock.withLock { storage } }
    func set(_ url: URL?) { lock.withLock { storage = url } }
}

private final class LockedURLList: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var values: [URL] { lock.withLock { storage } }
    @discardableResult
    func append(_ url: URL) -> Int {
        lock.withLock {
            storage.append(url)
            return storage.count
        }
    }
}
