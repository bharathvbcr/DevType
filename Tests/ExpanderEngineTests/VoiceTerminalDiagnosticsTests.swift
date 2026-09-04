import AVFoundation
import XCTest
@testable import ExpanderEngine

final class VoiceTerminalDiagnosticsTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-terminal-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeRecorder(in directory: URL) -> VoiceDiagnosticsRecorder {
        VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("voice-trace.jsonl"),
            terminalManifestURL: directory.appendingPathComponent("voice-terminal-manifest.json")
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        return value.intValue & 0o777
    }

    private func makeSnapshot(
        generation: UInt64 = 1,
        speechProviderID: String = VoiceSessionSnapshotFactory.ProviderID.whisperServer,
        route: PrivacyRoute = .localNetworkOnly
    ) -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            generation: SessionGeneration(rawValue: generation),
            speechProvider: SpeechProviderDescriptor(
                id: speechProviderID,
                displayName: "Private provider display name",
                modelVersion: "private-model-path",
                privacyRoute: route
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: VoiceSessionSnapshotFactory.ProviderID.deterministicCorrector,
                displayName: "Built-in",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            privacyRoute: route,
            targetLease: TargetLease(bundleIdentifier: "com.example.private-target", processIdentifier: 4242)
        )
    }

    func testFailureSummaryWhitelistsProviderAndDropsEveryFreeFormPayload() throws {
        let directory = try makeDirectory()
        let recorder = makeRecorder(in: directory)
        let secret = "private transcript /Users/person/recordings/voice.caf bearer-token"
        let snapshot = makeSnapshot(speechProviderID: secret, route: .cloudPermitted)
        let failure = VoiceFailure(
            stage: .recognition,
            code: .endpointUnreachable,
            providerID: secret,
            retryClass: .jitteredBackoff,
            redactedDetail: secret
        )
        let diagnostic = VoiceTerminalDiagnostic(failure: failure, snapshot: snapshot)

        XCTAssertEqual(diagnostic.code, .failure(.endpointUnreachable))
        XCTAssertEqual(diagnostic.stage, .recognition)
        XCTAssertEqual(diagnostic.provider, .unknown)
        XCTAssertEqual(diagnostic.locality, .cloud)
        XCTAssertEqual(diagnostic.recoverability, .retryAfterDelay)
        XCTAssertEqual(recorder.recordTerminal(diagnostic), .persisted)

        let encoded = try String(
            contentsOf: directory.appendingPathComponent("voice-terminal-manifest.json"),
            encoding: .utf8
        )
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(recorder.terminalReportLines().joined(separator: "\n").contains(secret))
    }

    func testKnownProviderUsesItsCanonicalLocalityInsteadOfTheRequestedRoute() {
        let snapshot = makeSnapshot(
            speechProviderID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
            route: .cloudPermitted
        )
        let failure = VoiceFailure(
            stage: .recognition,
            code: .speechNoSpeech,
            providerID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy
        )

        let diagnostic = VoiceTerminalDiagnostic(failure: failure, snapshot: snapshot)

        XCTAssertEqual(diagnostic.provider, .appleSpeech)
        XCTAssertEqual(
            diagnostic.locality,
            .onDevice,
            "A registry fallback must describe the provider that actually ran, not the preferred route."
        )
    }

    func testTerminalManifestIsBoundedAndCarriesObservedAndRetainedCounts() throws {
        let directory = try makeDirectory()
        let recorder = makeRecorder(in: directory)
        let snapshot = makeSnapshot()

        for offset in 0..<(VoiceDiagnosticsRecorder.maxTerminalEntries + 19) {
            let failure = VoiceFailure(
                stage: .recognition,
                code: .endpointUnreachable,
                retryClass: .jitteredBackoff,
                diagnosticID: UUID()
            )
            let diagnostic = VoiceTerminalDiagnostic(
                failure: failure,
                snapshot: snapshot,
                recordedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
            XCTAssertEqual(recorder.recordTerminal(diagnostic), .persisted)
        }

        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let byteCount = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber
        ).intValue
        let recent = recorder.recentTerminalDiagnostics(limit: Int.max)
        let report = recorder.terminalReportLines(limit: Int.max).joined(separator: "\n")

        XCTAssertEqual(recent.count, VoiceDiagnosticsRecorder.maxTerminalEntries)
        XCTAssertLessThanOrEqual(byteCount, VoiceDiagnosticsRecorder.maxTerminalBytes)
        XCTAssertTrue(report.contains("observed=\(VoiceDiagnosticsRecorder.maxTerminalEntries + 19)"), report)
        XCTAssertTrue(report.contains("retained=\(VoiceDiagnosticsRecorder.maxTerminalEntries)"), report)
    }

    func testTerminalWriteTightensPreexistingDirectoryAndAtomicFilePermissions() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        let recorder = makeRecorder(in: directory)
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )

        XCTAssertEqual(recorder.recordTerminal(diagnostic), .persisted)

        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: manifestURL), 0o600)
        XCTAssertEqual(recorder.ioHealth.terminalWrite, .succeeded)
    }

    func testTerminalPermissionFailureRemainsVolatileAndNeverReportsPersisted() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("voice-trace.jsonl"),
            terminalManifestURL: manifestURL,
            permissionSetter: { candidate, mode in
                if mode == 0o600 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: candidate.path
                )
            }
        )
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .failed,
            code: .failure(.manifestWriteFailed),
            stage: .persistence,
            provider: .sessionStore,
            locality: .onDevice,
            recoverability: .userActionRequired
        )

        XCTAssertEqual(
            recorder.recordTerminal(diagnostic),
            .retainedInMemory(.filePermissions)
        )
        XCTAssertEqual(recorder.ioHealth.terminalWrite, .failed(.filePermissions))
        XCTAssertEqual(recorder.recentTerminalDiagnostics(), [diagnostic])
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testTerminalReloadTightensPreexistingDirectoryAndManifestPermissions() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let seed = makeRecorder(in: directory)
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )
        XCTAssertEqual(seed.recordTerminal(diagnostic), .persisted)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: manifestURL.path)

        let reloaded = makeRecorder(in: directory)

        XCTAssertEqual(reloaded.recentTerminalDiagnostics(), [diagnostic])
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: manifestURL), 0o600)
        XCTAssertEqual(reloaded.ioHealth.terminalRead, .succeeded)
    }

    func testTerminalReloadPermissionFailureIsTypedAndReturnsNoUncheckedEntries() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let seed = makeRecorder(in: directory)
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )
        XCTAssertEqual(seed.recordTerminal(diagnostic), .persisted)
        let reloaded = VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("unused-trace.jsonl"),
            terminalManifestURL: manifestURL,
            permissionSetter: { candidate, mode in
                if mode == 0o600 { throw CocoaError(.fileReadNoPermission) }
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: candidate.path
                )
            }
        )

        XCTAssertEqual(reloaded.recentTerminalDiagnostics(), [])
        XCTAssertEqual(reloaded.ioHealth.terminalRead, .failed(.filePermissions))
        XCTAssertTrue(reloaded.ioHealth.hasFailure)
    }

    func testTransientInitialManifestReadFailureRetriesBeforeTheNextRecord() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let seed = makeRecorder(in: directory)
        let retained = VoiceTerminalDiagnostic(
            recordedAt: Date(timeIntervalSince1970: 1),
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )
        XCTAssertEqual(seed.recordTerminal(retained), .persisted)

        var failFirstManifestPermissionCheck = true
        let reloaded = VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("unused-trace.jsonl"),
            terminalManifestURL: manifestURL,
            permissionSetter: { candidate, mode in
                if mode == 0o600, failFirstManifestPermissionCheck {
                    failFirstManifestPermissionCheck = false
                    throw CocoaError(.fileReadNoPermission)
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: candidate.path
                )
            }
        )

        XCTAssertEqual(reloaded.recentTerminalDiagnostics(), [])
        XCTAssertEqual(reloaded.ioHealth.terminalRead, .failed(.filePermissions))

        let newest = VoiceTerminalDiagnostic(
            recordedAt: Date(timeIntervalSince1970: 2),
            outcome: .failed,
            code: .failure(.manifestWriteFailed),
            stage: .persistence,
            provider: .sessionStore,
            locality: .onDevice,
            recoverability: .userActionRequired
        )
        XCTAssertEqual(reloaded.recordTerminal(newest), .persisted)

        let verified = makeRecorder(in: directory)
        XCTAssertEqual(
            verified.recentTerminalDiagnostics(limit: Int.max),
            [retained, newest],
            "A transient first read must not let a later record replace retained diagnostics from an empty projection."
        )
    }

    func testTerminalManifestGrowthAfterSizeCheckIsRejectedByTheBoundedReader() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let seed = makeRecorder(in: directory)
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )
        XCTAssertEqual(seed.recordTerminal(diagnostic), .persisted)

        let reloaded = VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("unused-trace.jsonl"),
            terminalManifestURL: manifestURL,
            afterTerminalManifestSizeCheckForTesting: {
                guard let handle = try? FileHandle(forWritingTo: manifestURL) else { return }
                try? handle.truncate(
                    atOffset: UInt64(VoiceDiagnosticsRecorder.maxTerminalBytes + 1)
                )
                try? handle.close()
            }
        )

        XCTAssertEqual(reloaded.recentTerminalDiagnostics(), [])
        XCTAssertEqual(reloaded.ioHealth.terminalRead, .failed(.manifestExceedsLimit))
    }

    func testRawTraceFailureCannotHideOrContaminateTerminalManifest() throws {
        let directory = try makeDirectory()
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: blocker.appendingPathComponent("voice-trace.jsonl"),
            terminalManifestURL: manifestURL
        )
        let privateText = "do not copy this dictated sentence"
        let previousTracingSetting = UserDefaults.standard.object(
            forKey: VoicePreferences.voiceTracingKey
        )
        VoicePreferences.isVoiceTracingEnabled = true
        defer {
            if let previousTracingSetting {
                UserDefaults.standard.set(
                    previousTracingSetting,
                    forKey: VoicePreferences.voiceTracingKey
                )
            } else {
                UserDefaults.standard.removeObject(forKey: VoicePreferences.voiceTracingKey)
            }
        }

        XCTAssertEqual(recorder.record("trace-write", note: privateText), .accepted)
        XCTAssertEqual(recorder.ioHealth.write, .failed(.directoryCreation))

        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .failed,
            code: .failure(.endpointUnreachable),
            stage: .recognition,
            provider: .whisperCpp,
            locality: .localNetwork,
            recoverability: .retryAfterDelay
        )
        XCTAssertEqual(recorder.recordTerminal(diagnostic), .persisted)
        XCTAssertEqual(recorder.ioHealth.terminalWrite, .succeeded)

        let reloaded = VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("unused-trace.jsonl"),
            terminalManifestURL: manifestURL
        )
        XCTAssertEqual(reloaded.recentTerminalDiagnostics(), [diagnostic])
        XCTAssertFalse(try String(contentsOf: manifestURL, encoding: .utf8).contains(privateText))
    }

    func testTerminalWriteFailureRemainsVisibleWithVolatileBoundedEntry() throws {
        let directory = try makeDirectory()
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("voice-trace.jsonl"),
            terminalManifestURL: blocker.appendingPathComponent("voice-terminal-manifest.json")
        )
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .failed,
            code: .failure(.manifestWriteFailed),
            stage: .persistence,
            provider: .sessionStore,
            locality: .onDevice,
            recoverability: .userActionRequired
        )

        XCTAssertEqual(
            recorder.recordTerminal(diagnostic),
            .retainedInMemory(.directoryCreation)
        )
        XCTAssertEqual(recorder.recentTerminalDiagnostics(), [diagnostic])
        XCTAssertEqual(recorder.ioHealth.terminalWrite, .failed(.directoryCreation))
        XCTAssertTrue(
            recorder.terminalReportLines().contains { $0.contains("terminal-write=failed(directoryCreation)") }
        )
    }

    func testVolatileCountNamesOnlyEntriesNotYetPersistedAndClearsAfterRecovery() throws {
        let directory = try makeDirectory()
        let manifestDirectory = directory.appendingPathComponent("manifest", isDirectory: true)
        let manifestURL = manifestDirectory.appendingPathComponent("voice-terminal-manifest.json")
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("voice-trace.jsonl"),
            terminalManifestURL: manifestURL
        )
        let persisted = VoiceTerminalDiagnostic(
            outcome: .failed,
            code: .failure(.endpointUnreachable),
            stage: .recognition,
            provider: .whisperCpp,
            locality: .localNetwork,
            recoverability: .retryAfterDelay
        )
        XCTAssertEqual(recorder.recordTerminal(persisted), .persisted)

        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.removeItem(at: manifestDirectory)
        try Data("blocker".utf8).write(to: manifestDirectory)

        let volatile = VoiceTerminalDiagnostic(
            outcome: .failed,
            code: .failure(.manifestWriteFailed),
            stage: .persistence,
            provider: .sessionStore,
            locality: .onDevice,
            recoverability: .userActionRequired
        )
        XCTAssertEqual(
            recorder.recordTerminal(volatile),
            .retainedInMemory(.directoryCreation)
        )
        XCTAssertTrue(recorder.terminalReportLines().first?.contains("retained=2/") == true)
        XCTAssertTrue(
            recorder.terminalReportLines().first?.contains("volatile=1") == true,
            "A previously persisted entry must not be relabeled as volatile after a later write fails."
        )

        try FileManager.default.removeItem(at: manifestDirectory)
        let recovered = VoiceTerminalDiagnostic(
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )
        XCTAssertEqual(recorder.recordTerminal(recovered), .persisted)
        XCTAssertTrue(recorder.terminalReportLines().first?.contains("volatile=0") == true)
    }

    func testCloudConsentRefusalPersistsTypedDiagnosticAndPreservesPublicErrorContract() async throws {
        let directory = try makeDirectory()
        let recorder = makeRecorder(in: directory)
        let coordinator = VoiceSessionCoordinator(
            capture: CaptureStub(),
            store: VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions")),
            diagnosticsRecorder: recorder
        )
        let previousConsent = VoicePreferences.hasCloudAudioConsent
        VoicePreferences.hasCloudAudioConsent = false
        defer { VoicePreferences.hasCloudAudioConsent = previousConsent }

        let observed = expectation(description: "terminal observer")
        await coordinator.setOnTerminalDiagnostic { diagnostic in
            if diagnostic.code == .failure(.cloudAudioConsentRequired) { observed.fulfill() }
        }

        do {
            try await coordinator.startSession(
                snapshot: makeSnapshot(
                    speechProviderID: VoiceSessionSnapshotFactory.ProviderID.gemini,
                    route: .cloudPermitted
                ),
                enableLiveRecognition: false
            )
            XCTFail("A cloud-capable session must be refused before capture without consent.")
        } catch is CloudAudioConsentRequiredError {
            // Expected compatibility contract.
        } catch {
            XCTFail("Expected CloudAudioConsentRequiredError, got \(error)")
        }

        await fulfillment(of: [observed], timeout: 1)
        let diagnostic = try XCTUnwrap(recorder.recentTerminalDiagnostics().last)
        XCTAssertEqual(diagnostic.code, .failure(.cloudAudioConsentRequired))
        XCTAssertEqual(diagnostic.provider, .gemini)
        XCTAssertEqual(diagnostic.locality, .cloud)
        XCTAssertEqual(diagnostic.recoverability, .userActionRequired)
    }

    func testDependencyDownReachesRecorderAndObserverEndToEnd() async throws {
        let directory = try makeDirectory()
        let recorder = makeRecorder(in: directory)
        let capture = CaptureStub()
        let failure = VoiceFailure(
            stage: .recognition,
            code: .endpointUnreachable,
            providerID: VoiceSessionSnapshotFactory.ProviderID.whisperServer,
            retryClass: .jitteredBackoff,
            redactedDetail: "private endpoint response body"
        )
        let recognizer = StubSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.whisperServer,
            privacyRoute: .localNetworkOnly,
            behavior: .failure(failure)
        )
        let coordinator = VoiceSessionCoordinator(
            capture: capture,
            store: VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions")),
            speechRegistry: SpeechProviderRegistry(providers: [recognizer]),
            correctionRegistry: CorrectionProviderRegistry(providers: [DeterministicCorrector()]),
            diagnosticsRecorder: recorder
        )
        let observed = expectation(description: "terminal observer")
        await coordinator.setOnTerminalDiagnostic { diagnostic in
            if diagnostic.code == .failure(.endpointUnreachable) { observed.fulfill() }
        }
        let snapshot = makeSnapshot()

        try await coordinator.startSession(snapshot: snapshot, enableLiveRecognition: false)
        await capture.waitUntilStarted()
        await coordinator.stopSession()
        await fulfillment(of: [observed], timeout: 2)

        let diagnostic = try XCTUnwrap(recorder.recentTerminalDiagnostics().last)
        XCTAssertEqual(diagnostic.code, .failure(.endpointUnreachable))
        XCTAssertEqual(diagnostic.stage, .recognition)
        XCTAssertEqual(diagnostic.provider, .whisperCpp)
        XCTAssertEqual(diagnostic.locality, .localNetwork)
        XCTAssertEqual(diagnostic.recoverability, .retryAfterDelay)
        let persisted = try String(
            contentsOf: directory.appendingPathComponent("voice-terminal-manifest.json"),
            encoding: .utf8
        )
        XCTAssertFalse(persisted.contains("private endpoint response body"))
    }

    func testCancellationAndSupersessionHaveDistinctStableCodes() async throws {
        let directory = try makeDirectory()
        let recorder = makeRecorder(in: directory)
        let capture = CaptureStub()
        let coordinator = VoiceSessionCoordinator(
            capture: capture,
            store: VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions")),
            diagnosticsRecorder: recorder
        )

        let first = makeSnapshot(generation: 1)
        try await coordinator.startSession(snapshot: first, enableLiveRecognition: false)
        await capture.waitUntilStarted()
        let second = makeSnapshot(generation: 2)
        try await coordinator.startSession(snapshot: second, enableLiveRecognition: false)
        await coordinator.cancelSession()

        let diagnostics = recorder.recentTerminalDiagnostics(limit: Int.max)
        XCTAssertEqual(diagnostics.map(\.outcome), [.superseded, .cancelled])
        XCTAssertEqual(diagnostics.map(\.code), [.superseded, .cancelled])
        XCTAssertTrue(diagnostics.allSatisfy { $0.stage == .audioCapture })
    }
}

private actor CaptureStub: VoiceCaptureEngine {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {}
    func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?) {}

    func startCapture(sessionDirectory: URL) throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func stopCapture() async throws -> AudioArtifact {
        AudioArtifact(
            fileURL: URL(fileURLWithPath: "/dev/null"),
            frameCount: 16_000,
            durationSeconds: 1
        )
    }

    func cancelCapture() {}
}
