import AVFoundation
import XCTest
@testable import ExpanderEngine

final class PermissionsSecurityRegressionTests: XCTestCase {
    private actor CaptureSpy: VoiceCaptureEngine {
        private(set) var startCount = 0

        func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {}
        func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?) {}
        func startCapture(sessionDirectory: URL) throws { startCount += 1 }
        func stopCapture() async throws -> AudioArtifact { VoiceFixtures.audioArtifact() }
        func cancelCapture() {}
    }

    func testPermissionCallbacksRejectStoppedAndSupersededGenerations() {
        let callbacks = PermissionCallbackState()
        let statusCount = LockedPermissionCounter()
        let identityCount = LockedPermissionCounter()
        let status = PermissionCoordinator.Status(
            snapshot: PermissionSnapshot(
                canListenTap: false,
                canUseAX: false,
                canPostEvents: false
            ),
            tapRunning: false,
            recommendsRelaunchForAX: false
        )

        let first = callbacks.start(
            onStatusChanged: { _ in statusCount.increment() },
            onTapStartFailed: nil,
            onIdentityResolved: { _ in identityCount.increment() }
        )
        callbacks.deliverStatus(status)
        callbacks.deliverIdentity("first", generation: first)
        callbacks.stop()
        callbacks.deliverStatus(status)
        callbacks.deliverIdentity("stale", generation: first)

        let second = callbacks.start(
            onStatusChanged: { _ in statusCount.increment() },
            onTapStartFailed: nil,
            onIdentityResolved: { _ in identityCount.increment() }
        )
        callbacks.deliverIdentity("still-stale", generation: first)
        callbacks.deliverIdentity("second", generation: second)

        XCTAssertEqual(statusCount.value, 1)
        XCTAssertEqual(identityCount.value, 2)
        XCTAssertNotEqual(first, second)
    }

    func testPermissionStopWaitsForEnteredCallbackAndPreventsLaterDelivery() {
        let callbacks = PermissionCallbackState()
        let callbackCount = LockedPermissionCounter()
        let entered = expectation(description: "callback entered")
        let release = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let status = PermissionCoordinator.Status(
            snapshot: PermissionSnapshot(
                canListenTap: false,
                canUseAX: false,
                canPostEvents: false
            ),
            tapRunning: false,
            recommendsRelaunchForAX: false
        )
        _ = callbacks.start(
            onStatusChanged: { _ in
                callbackCount.increment()
                entered.fulfill()
                release.wait()
            },
            onTapStartFailed: nil,
            onIdentityResolved: nil
        )

        DispatchQueue.global().async { callbacks.deliverStatus(status) }
        wait(for: [entered], timeout: 1)
        DispatchQueue.global().async {
            callbacks.stop()
            stopReturned.signal()
        }

        XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)
        callbacks.deliverStatus(status)
        XCTAssertEqual(callbackCount.value, 1)
    }

    func testTapStartFailureCallbackEmitsOncePerFailureEpisode() {
        let callbacks = PermissionCallbackState()
        let failureCount = LockedPermissionCounter()
        _ = callbacks.start(
            onStatusChanged: { _ in },
            onTapStartFailed: { failureCount.increment() },
            onIdentityResolved: nil
        )

        callbacks.deliverTapStartFailure()
        callbacks.deliverTapStartFailure()
        XCTAssertEqual(
            failureCount.value,
            1,
            "Repeated refreshes for one persistent tap failure must not stack modal alerts."
        )

        callbacks.resetTapStartFailureEpisode()
        callbacks.deliverTapStartFailure()
        XCTAssertEqual(failureCount.value, 2)

        callbacks.stop()
        callbacks.resetTapStartFailureEpisode()
        callbacks.deliverTapStartFailure()
        XCTAssertEqual(failureCount.value, 2)
    }

    func testProviderSpecificSpeechPermissionPolicy() {
        XCTAssertEqual(
            VoicePermissionPolicy.decision(
                engine: .appleSpeech,
                liveRecognitionRequested: false,
                speechStatus: .notDetermined
            ),
            .requestAuthorization
        )
        XCTAssertEqual(
            VoicePermissionPolicy.decision(
                engine: .localLLM,
                liveRecognitionRequested: false,
                speechStatus: .denied
            ),
            .blocked
        )
        XCTAssertEqual(
            VoicePermissionPolicy.decision(
                engine: .gemini,
                liveRecognitionRequested: false,
                speechStatus: .denied
            ),
            .proceed(enableLiveRecognition: false)
        )
        XCTAssertEqual(
            VoicePermissionPolicy.decision(
                engine: .whisperLocal,
                liveRecognitionRequested: true,
                speechStatus: .notDetermined
            ),
            .requestAuthorization
        )
        XCTAssertEqual(
            VoicePermissionPolicy.decision(
                engine: .whisperLocal,
                liveRecognitionRequested: true,
                speechStatus: .restricted
            ),
            .proceed(enableLiveRecognition: false)
        )
        XCTAssertEqual(
            VoicePermissionPolicy.decision(
                engine: .gemini,
                liveRecognitionRequested: true,
                speechStatus: .authorized
            ),
            .proceed(enableLiveRecognition: true)
        )
    }

    func testCloudAudioConsentDefaultsOffAndPersists() {
        VoicePreferences.resetAllForTesting()
        defer { VoicePreferences.resetAllForTesting() }

        XCTAssertFalse(VoicePreferences.hasCloudAudioConsent)
        XCTAssertFalse(
            VoicePermissionPolicy.mayStartCloudAudio(
                privacyRoute: .cloudPermitted,
                consentGranted: VoicePreferences.hasCloudAudioConsent
            )
        )
        VoicePreferences.hasCloudAudioConsent = true
        XCTAssertTrue(VoicePreferences.hasCloudAudioConsent)
        XCTAssertTrue(
            VoicePermissionPolicy.mayStartCloudAudio(
                privacyRoute: .cloudPermitted,
                consentGranted: VoicePreferences.hasCloudAudioConsent
            )
        )
        XCTAssertTrue(
            VoicePermissionPolicy.mayStartCloudAudio(
                privacyRoute: .onDeviceOnly,
                consentGranted: false
            )
        )
    }

    func testCoordinatorRefusesCloudSessionBeforeStartingCaptureWithoutConsent() async {
        VoicePreferences.resetAllForTesting()
        defer { VoicePreferences.resetAllForTesting() }

        let capture = CaptureSpy()
        let coordinator = VoiceSessionCoordinator(capture: capture)
        let snapshot = VoiceFixtures.snapshot(privacyRoute: .cloudPermitted)

        do {
            try await coordinator.startSession(snapshot: snapshot)
            XCTFail("A cloud-capable session must not reach capture before explicit consent.")
        } catch is CloudAudioConsentRequiredError {
            // Expected typed refusal.
        } catch {
            XCTFail("Expected CloudAudioConsentRequiredError, got \(error)")
        }
        let startCount = await capture.startCount
        XCTAssertEqual(startCount, 0)
    }

    func testInputMonitoringRelaunchNudgeClearsWhenItsGrantArrives() {
        let state = PermissionRelaunchState()
        let denied = PermissionSnapshot(canListenTap: false, canUseAX: true, canPostEvents: true)
        let granted = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)

        state.noteRequestResult(for: .inputMonitoring, preflightGranted: false)
        XCTAssertTrue(state.recommendsRelaunch(for: denied))

        state.observe(granted)
        XCTAssertFalse(state.recommendsRelaunch(for: granted))
    }

    func testRelaunchNudgesClearIndependentlyPerCapability() {
        let state = PermissionRelaunchState()
        state.noteRequestResult(for: .accessibility, preflightGranted: false)
        state.noteRequestResult(for: .inputMonitoring, preflightGranted: false)

        let inputOnly = PermissionSnapshot(
            canListenTap: true,
            canUseAX: false,
            canPostEvents: true
        )
        state.observe(inputOnly)
        XCTAssertTrue(
            state.recommendsRelaunch(for: inputOnly),
            "The Accessibility nudge must survive an unrelated Input Monitoring grant."
        )

        let allGranted = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: true
        )
        state.observe(allGranted)
        XCTAssertFalse(state.recommendsRelaunch(for: allGranted))
    }

    func testRelaunchStateSurvivesConcurrentRequestsObservationsAndReads() {
        let state = PermissionRelaunchState()
        let accessibilityDenied = PermissionSnapshot(
            canListenTap: true,
            canUseAX: false,
            canPostEvents: true
        )
        let inputMonitoringDenied = PermissionSnapshot(
            canListenTap: false,
            canUseAX: true,
            canPostEvents: true
        )
        let allGranted = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: true
        )

        // Both request callbacks and observer/status reads can arrive on different queues.
        // The first wave must finish with both independent latches set regardless of order.
        DispatchQueue.concurrentPerform(iterations: 1_000) { iteration in
            if iteration.isMultiple(of: 2) {
                state.noteRequestResult(for: .accessibility, preflightGranted: false)
                _ = state.recommendsRelaunch(for: accessibilityDenied)
            } else {
                state.noteRequestResult(for: .inputMonitoring, preflightGranted: false)
                _ = state.recommendsRelaunch(for: inputMonitoringDenied)
            }
        }
        XCTAssertTrue(state.recommendsRelaunch(for: accessibilityDenied))
        XCTAssertTrue(state.recommendsRelaunch(for: inputMonitoringDenied))

        // A granted snapshot clears both latches in one observation. Hammer concurrent reads
        // while doing so; Thread Sanitizer turns an unguarded implementation into a failure,
        // while these terminal assertions catch lost or torn state in ordinary test runs.
        DispatchQueue.concurrentPerform(iterations: 1_000) { iteration in
            if iteration.isMultiple(of: 3) {
                state.observe(allGranted)
            } else {
                _ = state.recommendsRelaunch(
                    for: iteration.isMultiple(of: 2) ? accessibilityDenied : inputMonitoringDenied
                )
            }
        }
        state.observe(allGranted)
        XCTAssertFalse(state.recommendsRelaunch(for: allGranted))

        // The state remains usable after contention and the two capabilities still clear
        // independently; synchronization must not collapse them into one global latch.
        state.noteRequestResult(for: .accessibility, preflightGranted: false)
        XCTAssertTrue(state.recommendsRelaunch(for: accessibilityDenied))
        XCTAssertFalse(state.recommendsRelaunch(for: inputMonitoringDenied))
        state.noteRequestResult(for: .accessibility, preflightGranted: true)
        XCTAssertFalse(state.recommendsRelaunch(for: accessibilityDenied))
    }

    func testPermissionPrivacyAndPackagingSourceContracts() throws {
        let info = try source("Resources/Info.plist")
        let copy = try source("Sources/ExpanderEngine/Permissions/PermissionCopy.swift")
        let localization = try source("Sources/ExpanderEngine/Localization/LocalizationManager.swift")
        let entitlements = try source("Resources/DevType.entitlements")
        let reset = try source("Scripts/reset-tcc.sh")
        let preferences = try source("Sources/DevTypeAppCore/PreferencesWindowController.swift")
        let delegate = try source("Sources/DevTypeAppCore/AppDelegate.swift")

        XCTAssertFalse(info.contains("on-device Smart Speech-to-Text"))
        XCTAssertFalse(copy.contains("Audio stays strictly local on your Mac"))
        XCTAssertFalse(localization.contains("All audio is processed locally on-device"))
        XCTAssertFalse(entitlements.contains("com.apple.security.automation.apple-events"))
        XCTAssertTrue(reset.contains("Microphone"))
        XCTAssertTrue(reset.contains("SpeechRecognition"))
        XCTAssertFalse(
            reset.contains("tccutil reset \"${svc}\" \"${BUNDLE_ID}\" || true"),
            "The reset helper must not print a successful completion after tccutil failed."
        )
        XCTAssertTrue(reset.contains("FAILED_SERVICES"))
        XCTAssertFalse(preferences.contains("try? GeminiAPIKeyStore.save"))
        XCTAssertFalse(preferences.contains("try? GeminiAPIKeyStore.delete"))
        XCTAssertFalse(preferences.contains("mic.badge.shield"))
        XCTAssertTrue(delegate.contains("PreferencesWindowController.shared.refreshPermissionState()"))
    }

    func testPackagedPermissionPromptsShipForEveryAdvertisedLanguage() throws {
        let usageKeys = [
            "NSAccessibilityUsageDescription",
            "NSInputMonitoringUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
        ]

        for language in ["en", "ko", "ja"] {
            let strings = try source("Resources/\(language).lproj/InfoPlist.strings")
            for key in usageKeys {
                XCTAssertTrue(
                    strings.contains("\"\(key)\" ="),
                    "\(language) is missing the system-visible permission reason for \(key)."
                )
            }
        }

        let packaging = try source("Scripts/package-app.sh")
        XCTAssertTrue(
            packaging.contains("InfoPlist.strings"),
            "A permission-copy-only change must invalidate the packaged resource seal instead of being skipped as cosmetic."
        )
        XCTAssertTrue(packaging.contains("lproj"))
    }

    func testPackagedLocalEndpointsUseOnlyTheNarrowATSLocalNetworkingScope() throws {
        let info = try source("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(info.utf8),
            options: [],
            format: nil
        )
        let root = try XCTUnwrap(plist as? [String: Any])
        let ats = try XCTUnwrap(root["NSAppTransportSecurity"] as? [String: Any])

        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertEqual(
            Set(ats.keys),
            ["NSAllowsLocalNetworking"],
            "Loopback HTTP support must not widen ATS beyond Apple's local-network exception."
        )

        let packaging = try source("Scripts/package-app.sh")
        XCTAssertTrue(packaging.contains("verify_narrow_local_network_ats \"${PLIST_SRC}\""))
        XCTAssertTrue(packaging.contains("verify_narrow_local_network_ats \"${CONTENTS}/Info.plist\""))
        XCTAssertTrue(packaging.contains("NSAllowsArbitraryLoads"))
    }

    func testLaunchRecoverySurfacesOpaqueReferencesWithoutPersistingTranscriptText() throws {
        let controller = try source("Sources/DevTypeAppCore/VoiceDictationController.swift")
        let activitySignal = try source("Sources/ExpanderEngine/Models/ActivitySignal.swift")

        XCTAssertFalse(
            controller.contains("pending.prefix(ActivityHistoryStore.maxEvents)"),
            "Silently truncating before pruning leaves retained recovery sessions unreachable."
        )
        XCTAssertTrue(controller.contains("recordBatch"))
        XCTAssertTrue(controller.contains("RecoveredVoiceActivityMetadata"))
        XCTAssertTrue(controller.contains("signal: .voiceRecovery("))
        XCTAssertTrue(controller.contains("sessionID: metadata.sessionID"))
        XCTAssertTrue(controller.contains("characterCount: metadata.characterCount"))
        XCTAssertTrue(controller.contains("recordedAt: metadata.timestamp"))
        XCTAssertTrue(activitySignal.contains("case .voiceRecovery"))
        XCTAssertTrue(activitySignal.contains("action: .reviewRecoveredVoice"))
        XCTAssertTrue(activitySignal.contains("referenceID: sessionID.description"))
        XCTAssertTrue(activitySignal.contains("deduplicationKey: \"voice-recovery-\\(sessionID.description)\""))
        XCTAssertFalse(controller.contains("details: text"))
        XCTAssertFalse(controller.contains("service.discard(session)"))
    }

    func testLocalWhisperRefusesANonLoopbackEndpointAtTheEgressBoundary() async {
        let adapter = WhisperCppServerAdapter(
            endpointURL: URL(string: "https://example.invalid/inference")!
        )
        let snapshot = VoiceFixtures.snapshot(
            speechProviderID: adapter.descriptor.id,
            privacyRoute: .localNetworkOnly
        )
        let request = SpeechRequest(
            sessionID: snapshot.sessionID,
            generation: snapshot.generation,
            audio: VoiceFixtures.audioArtifact(),
            locale: Locale(identifier: "en_US"),
            vocabulary: snapshot.vocabularySnapshot,
            deadline: Date().addingTimeInterval(1),
            privacyRoute: .localNetworkOnly
        )

        do {
            for try await _ in adapter.transcribe(request) {}
            XCTFail("A local-only provider must never send audio to a non-loopback host.")
        } catch let failure as VoiceFailure {
            XCTAssertEqual(failure.code, .endpointUnreachable)
            XCTAssertTrue(failure.redactedDetail?.contains("non-loopback") == true)
        } catch {
            XCTFail("Expected a structured privacy refusal, got \(error)")
        }
    }

    func testVoiceTracePreferencesUseOrderedTypedRecorderOperations() throws {
        let preferences = try source("Sources/DevTypeAppCore/PreferencesWindowController.swift")
        let toggle = try objcMethod(named: "voiceTracingChanged", in: preferences)

        XCTAssertTrue(toggle.contains("disableAndDelete()"), "Turning tracing off must drain writes and delete atomically.")
        XCTAssertTrue(toggle.contains("deleteTrace()"), "Turning tracing on must first establish a fresh trace.")
        let deletion = try XCTUnwrap(toggle.range(of: "deleteTrace()"))
        let enabling = try XCTUnwrap(toggle.range(of: "recorder.isEnabled = true"))
        XCTAssertLessThan(deletion.lowerBound, enabling.lowerBound)
        XCTAssertTrue(toggle.contains("case .failed(let failure)"), "Typed deletion failure must be presented, not ignored.")

        let delete = try objcMethod(named: "deleteVoiceTrace", in: preferences)
        XCTAssertTrue(delete.contains("deleteTrace()"), "Preferences needs an explicit trace deletion action.")

        let reveal = try objcMethod(named: "revealVoiceTrace", in: preferences)
        let read = try XCTUnwrap(reveal.range(of: "recorder.read()"))
        let health = try XCTUnwrap(reveal.range(of: "recorder.ioHealth"))
        let workspace = try XCTUnwrap(reveal.range(of: "NSWorkspace.shared.activateFileViewerSelecting"))
        XCTAssertLessThan(read.lowerBound, health.lowerBound, "read() must flush queued writes before health is inspected.")
        XCTAssertLessThan(health.lowerBound, workspace.lowerBound, "Reveal must not race the recorder queue.")
        XCTAssertTrue(reveal.contains("case .failed(let failure)"), "Read/write failure must use typed I/O health.")
    }

    private func objcMethod(named name: String, in source: String) throws -> String {
        let declaration = try XCTUnwrap(source.range(of: "@objc private func \(name)"))
        let nextSearchStart = declaration.upperBound
        let nextDeclaration = source.range(
            of: "\n    @objc private func ",
            range: nextSearchStart..<source.endIndex
        )
        return String(source[declaration.lowerBound..<(nextDeclaration?.lowerBound ?? source.endIndex)])
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private final class LockedPermissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
