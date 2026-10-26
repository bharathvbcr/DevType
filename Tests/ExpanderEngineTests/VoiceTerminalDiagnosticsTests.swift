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
        let recorder = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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

    /// A failure that names something the user can do must never also report that nothing can
    /// be done. `retryClass` and `userAction` defaulted independently, so `noMicrophone` reached
    /// a real diagnostic report as `recoverability=notRecoverable` while carrying
    /// `userAction: .grantMicrophonePermission`.
    func testARemedyIsNeverReportedAsUnrecoverable() {
        let snapshot = makeSnapshot(speechProviderID: "apple_speech", route: .onDeviceOnly)
        let failure = VoiceFailure(
            stage: .audioCapture,
            code: .noMicrophone,
            userAction: .grantMicrophonePermission,
            redactedDetail: "Hardware input format unavailable or invalid"
        )

        XCTAssertEqual(failure.retryClass, .none, "The stored input is left exactly as written…")
        XCTAssertEqual(failure.effectiveRetryClass, .afterUserAction, "…and reconciled on read.")
        XCTAssertEqual(
            VoiceTerminalDiagnostic(failure: failure, snapshot: snapshot).recoverability,
            .userActionRequired
        )
    }

    /// Every remedy, not just the microphone one — the four other construction sites that got
    /// this wrong named four different actions.
    func testEveryRemedyActionReconcilesTheDefaultRetryClass() {
        for action in [
            UserAction.grantMicrophonePermission, .grantAccessibilityPermission, .enterAPIKey,
            .configureEndpoint, .downloadModel, .freeDiskSpace, .retryWithOtherProvider,
        ] {
            let failure = VoiceFailure(stage: .recognition, code: .authFailed, userAction: action)
            XCTAssertEqual(failure.effectiveRetryClass, .afterUserAction, "\(action)")
        }
    }

    /// `reviewInHistory` is not a remedy: it says the audio survived and where it is, not how to
    /// make the operation succeed. Reconciliation must not turn that into a promise of a retry.
    func testReviewInHistoryStaysUnrecoverable() {
        let failure = VoiceFailure(
            stage: .recognition,
            code: .speechProtocolViolation,
            userAction: .reviewInHistory
        )
        XCTAssertEqual(failure.effectiveRetryClass, .none)
        XCTAssertFalse(UserAction.reviewInHistory.isRemedy)
    }

    /// An explicit retry class is the caller's, and reconciliation leaves it alone.
    func testAnExplicitRetryClassIsNeverOverridden() {
        let failure = VoiceFailure(
            stage: .recognition,
            code: .endpointUnreachable,
            retryClass: .jitteredBackoff,
            userAction: .configureEndpoint
        )
        XCTAssertEqual(failure.effectiveRetryClass, .jitteredBackoff)
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
        let recorder = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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
        let recorder = VoiceDiagnosticsFixture.makeRecorder(in: directory)
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )

        XCTAssertEqual(recorder.recordTerminal(diagnostic), .persisted)

        XCTAssertEqual(try VoiceDiagnosticsFixture.posixPermissions(at: directory), 0o700)
        XCTAssertEqual(try VoiceDiagnosticsFixture.posixPermissions(at: manifestURL), 0o600)
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
        let seed = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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

        let reloaded = VoiceDiagnosticsFixture.makeRecorder(in: directory)

        XCTAssertEqual(reloaded.recentTerminalDiagnostics(), [diagnostic])
        XCTAssertEqual(try VoiceDiagnosticsFixture.posixPermissions(at: directory), 0o700)
        XCTAssertEqual(try VoiceDiagnosticsFixture.posixPermissions(at: manifestURL), 0o600)
        XCTAssertEqual(reloaded.ioHealth.terminalRead, .succeeded)
    }

    func testTerminalReloadPermissionFailureIsTypedAndReturnsNoUncheckedEntries() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let seed = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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
        let seed = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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

        let verified = VoiceDiagnosticsFixture.makeRecorder(in: directory)
        XCTAssertEqual(
            verified.recentTerminalDiagnostics(limit: Int.max),
            [retained, newest],
            "A transient first read must not let a later record replace retained diagnostics from an empty projection."
        )
    }

    func testTerminalManifestGrowthAfterSizeCheckIsRejectedByTheBoundedReader() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let seed = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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

    /// A manifest written by a newer build can carry a failure code this build does not know.
    /// Decoding must keep every other entry, map the unknown one to the payload-free
    /// `unrecognized` code, and leave the next record able to persist.
    func testManifestEntryWithFutureCodeLoadsAsUnrecognizedAndLaterRecordsPersist() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let seed = VoiceDiagnosticsFixture.makeRecorder(in: directory)
        let kept = VoiceTerminalDiagnostic(
            recordedAt: Date(timeIntervalSince1970: 1),
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )
        let future = VoiceTerminalDiagnostic(
            recordedAt: Date(timeIntervalSince1970: 2),
            outcome: .failed,
            code: .failure(.endpointUnreachable),
            stage: .recognition,
            provider: .whisperCpp,
            locality: .localNetwork,
            recoverability: .retryAfterDelay
        )
        XCTAssertEqual(seed.recordTerminal(kept), .persisted)
        XCTAssertEqual(seed.recordTerminal(future), .persisted)

        let original = try String(contentsOf: manifestURL, encoding: .utf8)
        let rewritten = original.replacingOccurrences(
            of: "\"code\":\"endpointUnreachable\"",
            with: "\"code\":\"someFutureCode\""
        )
        XCTAssertNotEqual(original, rewritten, "The fixture must actually carry the unknown code.")
        try rewritten.write(to: manifestURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

        let reloaded = VoiceDiagnosticsFixture.makeRecorder(in: directory)
        let loaded = reloaded.recentTerminalDiagnostics(limit: Int.max)

        XCTAssertEqual(reloaded.ioHealth.terminalRead, .succeeded)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first, kept)
        XCTAssertEqual(loaded.last?.id, future.id)
        XCTAssertEqual(loaded.last?.code.rawValue, "unrecognized")

        let newest = VoiceTerminalDiagnostic(
            recordedAt: Date(timeIntervalSince1970: 3),
            outcome: .superseded,
            code: .superseded,
            stage: .recognition,
            provider: .whisperCpp,
            locality: .localNetwork,
            recoverability: .retryImmediately
        )
        XCTAssertEqual(
            reloaded.recordTerminal(newest),
            .persisted,
            "A tolerated unknown code must not park the recorder on the load-failure path."
        )
        XCTAssertEqual(reloaded.ioHealth.terminalWrite, .succeeded)

        let afterWrite = VoiceDiagnosticsFixture.makeRecorder(in: directory)
            .recentTerminalDiagnostics(limit: Int.max)
        XCTAssertEqual(afterWrite.map(\.id), [kept.id, future.id, newest.id])
        XCTAssertEqual(afterWrite.map(\.code.rawValue), ["cancelled", "unrecognized", "sessionSuperseded"])
    }

    /// An entry that cannot be decoded at all (not merely an unknown code) is skipped, counted
    /// and surfaced; it never discards its neighbours.
    func testManifestEntryThatCannotDecodeIsSkippedCountedAndReported() throws {
        let directory = try makeDirectory()
        let manifestURL = directory.appendingPathComponent("voice-terminal-manifest.json")
        let seed = VoiceDiagnosticsFixture.makeRecorder(in: directory)
        let kept = VoiceTerminalDiagnostic(
            recordedAt: Date(timeIntervalSince1970: 1),
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )
        let damaged = VoiceTerminalDiagnostic(
            recordedAt: Date(timeIntervalSince1970: 2),
            outcome: .failed,
            code: .failure(.endpointUnreachable),
            stage: .recognition,
            provider: .whisperCpp,
            locality: .localNetwork,
            recoverability: .retryAfterDelay
        )
        XCTAssertEqual(seed.recordTerminal(kept), .persisted)
        XCTAssertEqual(seed.recordTerminal(damaged), .persisted)
        XCTAssertEqual(seed.ioHealth.terminalSkippedEntries, 0)

        let original = try String(contentsOf: manifestURL, encoding: .utf8)
        let rewritten = original.replacingOccurrences(
            of: "\"stage\":\"recognition\"",
            with: "\"stage\":\"someFutureStage\""
        )
        XCTAssertNotEqual(original, rewritten)
        try rewritten.write(to: manifestURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

        let reloaded = VoiceDiagnosticsFixture.makeRecorder(in: directory)

        XCTAssertEqual(reloaded.recentTerminalDiagnostics(limit: Int.max), [kept])
        XCTAssertEqual(reloaded.ioHealth.terminalRead, .succeeded)
        XCTAssertEqual(reloaded.ioHealth.terminalSkippedEntries, 1)
        XCTAssertTrue(
            reloaded.terminalReportLines().first?.contains("skipped=1") == true,
            "A skipped entry must be visible in the report, never silent."
        )
    }

    /// The wire value `unrecognized` is itself a valid code, so a manifest this build wrote after
    /// tolerating an unknown value reads back unchanged.
    func testUnrecognizedCodeRoundTripsAndStaysPayloadFree() throws {
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .failed,
            code: .unrecognized,
            stage: .protocolViolation,
            provider: .sessionCoordinator,
            locality: .onDevice,
            recoverability: .notRecoverable
        )
        let data = try JSONEncoder().encode(diagnostic)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"code\":\"unrecognized\""))
        XCTAssertEqual(try JSONDecoder().decode(VoiceTerminalDiagnostic.self, from: data), diagnostic)

        let hostile = String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: "\"code\":\"unrecognized\"",
            with: "\"code\":\"/Users/person/secret transcript\""
        )
        let decoded = try JSONDecoder().decode(VoiceTerminalDiagnostic.self, from: Data(hostile.utf8))
        XCTAssertEqual(decoded.code, .unrecognized)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("secret"))
    }

    /// `LenientlyDecoded` is only correct if a failed element still advances the unkeyed
    /// container; otherwise a bad element would be retried forever or abort the array.
    func testLenientlyDecodedAdvancesTheContainerPastAFailedElement() throws {
        struct Strict: Decodable, Equatable {
            let n: Int
        }
        let json = Data(#"[{"n":1},{"n":"bad"},{"x":0},{"n":4},7,{"n":5}]"#.utf8)
        let decoded = try JSONDecoder().decode([LenientlyDecoded<Strict>].self, from: json)

        XCTAssertEqual(decoded.count, 6)
        XCTAssertEqual(decoded.map(\.value), [Strict(n: 1), nil, nil, Strict(n: 4), nil, Strict(n: 5)])
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
        let recorder = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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
        let recorder = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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

    /// A non-`VoiceFailure` error out of `stopCapture` used to be fabricated into
    /// `.zeroFramesCaptured`, which the UI renders as "no speech detected".
    func testUntypedStopFailureIsACaptureProtocolViolationNotNoSpeech() async throws {
        let directory = try makeDirectory()
        let recorder = VoiceDiagnosticsFixture.makeRecorder(in: directory)
        let capture = UntypedStopFailureCapture()
        let coordinator = VoiceSessionCoordinator(
            capture: capture,
            store: VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions")),
            diagnosticsRecorder: recorder
        )
        let observed = expectation(description: "terminal observer")
        observed.assertForOverFulfill = false
        let observations = ObservedCodes()
        await coordinator.setOnTerminalDiagnostic { diagnostic in
            observations.append(diagnostic.code.rawValue)
            if diagnostic.outcome == .failed { observed.fulfill() }
        }

        try await coordinator.startSession(snapshot: makeSnapshot(), enableLiveRecognition: false)
        await capture.waitUntilStarted()
        await coordinator.stopSession()
        await fulfillment(of: [observed], timeout: 2)

        let diagnostic = try XCTUnwrap(recorder.recentTerminalDiagnostics().last)
        XCTAssertEqual(diagnostic.code, .failure(.captureProtocolViolation))
        XCTAssertEqual(diagnostic.stage, .protocolViolation)
        XCTAssertNotEqual(diagnostic.code, .failure(.zeroFramesCaptured))
        XCTAssertEqual(observations.all, ["captureProtocolViolation"])
    }

    func testCancellationAndSupersessionHaveDistinctStableCodes() async throws {
        let directory = try makeDirectory()
        let recorder = VoiceDiagnosticsFixture.makeRecorder(in: directory)
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
    func setOnInterruption(_ handler: (@Sendable (CaptureInterruption) -> Void)?) {}

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
            durationSeconds: 1,
            // A real artifact always has bytes; the reducer now rejects one that does not.
            byteCount: 64_000
        )
    }

    func cancelCapture() {}
}

private final class ObservedCodes: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String] = []

    func append(_ code: String) {
        lock.lock()
        codes.append(code)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return codes
    }
}

/// A capture engine whose `stopCapture` throws something that is not a `VoiceFailure`, the shape
/// of a broken capture/coordinator contract rather than a typed device failure.
private actor UntypedStopFailureCapture: VoiceCaptureEngine {
    struct ContractBroken: Error {}
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {}
    func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?) {}
    func setOnInterruption(_ handler: (@Sendable (CaptureInterruption) -> Void)?) {}

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

    func stopCapture() async throws -> AudioArtifact { throw ContractBroken() }

    func cancelCapture() {}
}
