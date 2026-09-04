import AVFoundation
import XCTest
@testable import ExpanderEngine

final class VoiceProviderProvenanceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    func testSnapshotRoundTripsRequestedAndResolvedProvidersWhileLegacyDecodeKeepsRequestedIdentity() throws {
        let requestedSpeech = speechDescriptor(
            id: VoiceSessionSnapshotFactory.ProviderID.whisperServer,
            route: .localNetworkOnly
        )
        let resolvedSpeech = speechDescriptor(
            id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
            route: .onDeviceOnly
        )
        let requestedCorrection = correctionDescriptor(
            id: AITransformCorrector.id(for: .proofread),
            route: .onDeviceOnly
        )
        let resolvedCorrection = correctionDescriptor(
            id: DeterministicCorrector.providerID,
            route: .onDeviceOnly
        )
        let snapshot = makeSnapshot(
            requestedSpeech: requestedSpeech,
            resolvedSpeech: resolvedSpeech,
            requestedCorrection: requestedCorrection,
            resolvedCorrection: resolvedCorrection
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(VoiceSessionSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.speechProvider, requestedSpeech)
        XCTAssertEqual(decoded.correctionProvider, requestedCorrection)
        XCTAssertEqual(decoded.resolvedSpeechProvider, resolvedSpeech)
        XCTAssertEqual(decoded.resolvedCorrectionProvider, resolvedCorrection)
        XCTAssertEqual(decoded.effectiveSpeechProvider, resolvedSpeech)
        XCTAssertEqual(decoded.effectiveCorrectionProvider, resolvedCorrection)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "resolvedSpeechProvider")
        legacyObject.removeValue(forKey: "resolvedCorrectionProvider")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(VoiceSessionSnapshot.self, from: legacyData)

        XCTAssertNil(legacy.resolvedSpeechProvider)
        XCTAssertNil(legacy.resolvedCorrectionProvider)
        XCTAssertEqual(legacy.effectiveSpeechProvider, requestedSpeech)
        XCTAssertEqual(legacy.effectiveCorrectionProvider, requestedCorrection)
    }

    func testTerminalDiagnosticsUseResolvedProviderWhenFailureHasNoProviderID() {
        let snapshot = makeSnapshot(
            requestedSpeech: speechDescriptor(
                id: VoiceSessionSnapshotFactory.ProviderID.whisperServer,
                route: .localNetworkOnly
            ),
            resolvedSpeech: speechDescriptor(
                id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
                route: .onDeviceOnly
            ),
            requestedCorrection: correctionDescriptor(
                id: AITransformCorrector.id(for: .proofread),
                route: .onDeviceOnly
            ),
            resolvedCorrection: correctionDescriptor(
                id: DeterministicCorrector.providerID,
                route: .onDeviceOnly
            )
        )

        let recognition = VoiceTerminalDiagnostic(
            failure: VoiceFailure(stage: .recognition, code: .requestTimeout),
            snapshot: snapshot
        )
        let correction = VoiceTerminalDiagnostic(
            failure: VoiceFailure(stage: .correction, code: .requestTimeout),
            snapshot: snapshot
        )
        let cancellation = VoiceTerminalDiagnostic.cancelled(
            snapshot: snapshot,
            stage: .recognition
        )

        XCTAssertEqual(recognition.provider, .appleSpeech)
        XCTAssertEqual(recognition.locality, .onDevice)
        XCTAssertEqual(correction.provider, .deterministic)
        XCTAssertEqual(correction.locality, .onDevice)
        XCTAssertEqual(cancellation.provider, .appleSpeech)
        XCTAssertEqual(cancellation.locality, .onDevice)
    }

    func testCoordinatorPersistsRequestedAndActualFallbackDescriptors() async throws {
        let directory = try makeDirectory()
        let store = VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions"))
        let capture = ProviderProvenanceCapture()
        let requestedSpeech = StubSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.whisperServer,
            privacyRoute: .localNetworkOnly,
            readiness: .temporarilyUnavailable(
                retryAfterSeconds: 1,
                reason: .endpointUnreachable
            )
        )
        let resolvedSpeech = StubSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
            behavior: .segments([
                SpeechSegment(
                    segmentID: "fallback",
                    text: "hello world",
                    finality: .final
                )
            ])
        )
        let requestedCorrectionID = AITransformCorrector.id(for: .proofread)
        let requestedCorrection = StubCorrector(
            id: requestedCorrectionID,
            readiness: .temporarilyUnavailable(
                retryAfterSeconds: nil,
                reason: .modelNotFound
            )
        )
        let resolvedCorrection = StubCorrector(
            id: "test.correction.fallback",
            behavior: .returns("Hello world.")
        )
        let recorder = makeRecorder(in: directory)
        let coordinator = VoiceSessionCoordinator(
            capture: capture,
            store: store,
            speechRegistry: SpeechProviderRegistry(
                providers: [requestedSpeech, resolvedSpeech]
            ),
            correctionRegistry: CorrectionProviderRegistry(
                providers: [requestedCorrection, resolvedCorrection]
            ),
            diagnosticsRecorder: recorder
        )
        let completed = expectation(description: "fallback session completed")
        await coordinator.setOnDeliveryIntercept { _ in true }
        await coordinator.setOnPhaseChange { phase in
            if case .completed = phase { completed.fulfill() }
        }
        let requestedSpeechDescriptor = requestedSpeech.descriptor
        let requestedCorrectionDescriptor = requestedCorrection.descriptor
        let snapshot = makeSnapshot(
            requestedSpeech: requestedSpeechDescriptor,
            requestedCorrection: requestedCorrectionDescriptor,
            correctionFallbackProviderIDs: [resolvedCorrection.descriptor.id]
        )

        try await coordinator.startSession(snapshot: snapshot, enableLiveRecognition: false)
        await capture.waitUntilStarted()
        let didStop = await coordinator.stopSession()
        XCTAssertTrue(didStop)
        await fulfillment(of: [completed], timeout: 2)

        let manifest = try await eventuallyLoadManifest(
            from: store.sessionDirectory(for: snapshot.sessionID)
                .appendingPathComponent("manifest.json"),
            until: {
                $0.resolvedSpeechProvider?.id == resolvedSpeech.descriptor.id &&
                $0.resolvedCorrectionProvider?.id == resolvedCorrection.descriptor.id
            }
        )
        XCTAssertEqual(manifest.speechProvider, requestedSpeechDescriptor)
        XCTAssertEqual(manifest.correctionProvider, requestedCorrectionDescriptor)
        XCTAssertEqual(manifest.resolvedSpeechProvider, resolvedSpeech.descriptor)
        XCTAssertEqual(manifest.resolvedCorrectionProvider, resolvedCorrection.descriptor)
    }

    func testCancellationAfterSpeechFallbackAttributesActualRecognizerAndPersistsIt() async throws {
        let directory = try makeDirectory()
        let store = VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions"))
        let capture = ProviderProvenanceCapture()
        let latch = AsyncEntryLatch()
        let requestedSpeech = StubSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.whisperServer,
            privacyRoute: .localNetworkOnly,
            readiness: .temporarilyUnavailable(
                retryAfterSeconds: 1,
                reason: .endpointUnreachable
            )
        )
        let resolvedSpeech = HangingSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
            entryLatch: latch
        )
        let recorder = makeRecorder(in: directory)
        let coordinator = VoiceSessionCoordinator(
            capture: capture,
            store: store,
            speechRegistry: SpeechProviderRegistry(
                providers: [requestedSpeech, resolvedSpeech]
            ),
            correctionRegistry: CorrectionProviderRegistry(
                providers: [DeterministicCorrector()]
            ),
            diagnosticsRecorder: recorder
        )
        let snapshot = makeSnapshot(
            requestedSpeech: requestedSpeech.descriptor,
            requestedCorrection: DeterministicCorrector().descriptor
        )

        try await coordinator.startSession(snapshot: snapshot, enableLiveRecognition: false)
        await capture.waitUntilStarted()
        let didStop = await coordinator.stopSession()
        XCTAssertTrue(didStop)
        await latch.waitUntilEntered()
        let didCancel = await coordinator.cancelSession()
        XCTAssertTrue(didCancel)

        let terminal = try XCTUnwrap(recorder.recentTerminalDiagnostics().last)
        XCTAssertEqual(terminal.outcome, .cancelled)
        XCTAssertEqual(terminal.stage, .recognition)
        XCTAssertEqual(terminal.provider, .appleSpeech)
        XCTAssertEqual(terminal.locality, .onDevice)

        let manifestURL = store.sessionDirectory(for: snapshot.sessionID)
            .appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            VoiceSessionSnapshot.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.speechProvider, requestedSpeech.descriptor)
        XCTAssertEqual(manifest.resolvedSpeechProvider, resolvedSpeech.descriptor)
    }

    func testFailureAfterSpeechFallbackOverridesAStaleProviderIDFromTheAdapter() async throws {
        let directory = try makeDirectory()
        let store = VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions"))
        let capture = ProviderProvenanceCapture()
        let requestedID = VoiceSessionSnapshotFactory.ProviderID.whisperServer
        let requestedSpeech = StubSpeechRecognizer(
            id: requestedID,
            privacyRoute: .localNetworkOnly,
            readiness: .temporarilyUnavailable(
                retryAfterSeconds: 1,
                reason: .endpointUnreachable
            )
        )
        let resolvedSpeech = StubSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
            behavior: .failure(VoiceFailure(
                stage: .recognition,
                code: .endpointUnreachable,
                providerID: requestedID,
                retryClass: .jitteredBackoff,
                artifactState: .durable,
                userAction: .retryWithOtherProvider
            ))
        )
        let recorder = makeRecorder(in: directory)
        let coordinator = VoiceSessionCoordinator(
            capture: capture,
            store: store,
            speechRegistry: SpeechProviderRegistry(
                providers: [requestedSpeech, resolvedSpeech]
            ),
            correctionRegistry: CorrectionProviderRegistry(
                providers: [DeterministicCorrector()]
            ),
            diagnosticsRecorder: recorder
        )
        let failed = expectation(description: "fallback recognizer failure")
        await coordinator.setOnTerminalDiagnostic { diagnostic in
            if diagnostic.code == .failure(.endpointUnreachable) { failed.fulfill() }
        }
        let snapshot = makeSnapshot(
            requestedSpeech: requestedSpeech.descriptor,
            requestedCorrection: DeterministicCorrector().descriptor
        )

        try await coordinator.startSession(snapshot: snapshot, enableLiveRecognition: false)
        await capture.waitUntilStarted()
        let didStop = await coordinator.stopSession()
        XCTAssertTrue(didStop)
        await fulfillment(of: [failed], timeout: 2)

        let terminal = try XCTUnwrap(recorder.recentTerminalDiagnostics().last)
        XCTAssertEqual(terminal.stage, .recognition)
        XCTAssertEqual(
            terminal.provider,
            .appleSpeech,
            "The coordinator knows which fallback ran and must not retain a stale preferred id supplied by that adapter."
        )
        XCTAssertEqual(terminal.locality, .onDevice)
    }

    func testLateResolutionFromSupersededGenerationCannotRewriteReplacementManifest() async throws {
        let directory = try makeDirectory()
        let store = VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions"))
        let capture = ProviderProvenanceCapture()
        let probeEntered = AsyncEntryLatch()
        let releaseProbe = AsyncEntryLatch()
        let probeReturned = AsyncEntryLatch()
        let delayed = DelayedProbeSpeechRecognizer(
            id: "test.speech.delayed",
            probeEntered: probeEntered,
            releaseProbe: releaseProbe,
            probeReturned: probeReturned
        )
        let coordinator = VoiceSessionCoordinator(
            capture: capture,
            store: store,
            speechRegistry: SpeechProviderRegistry(providers: [delayed]),
            correctionRegistry: CorrectionProviderRegistry(
                providers: [DeterministicCorrector()]
            ),
            diagnosticsRecorder: makeRecorder(in: directory)
        )
        let correction = DeterministicCorrector().descriptor
        let old = VoiceSessionSnapshot(
            generation: SessionGeneration(rawValue: 1),
            speechProvider: delayed.descriptor,
            correctionProvider: correction,
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        )
        let replacementSpeech = speechDescriptor(
            id: "test.speech.replacement",
            route: .onDeviceOnly
        )
        let replacement = VoiceSessionSnapshot(
            generation: SessionGeneration(rawValue: 2),
            speechProvider: replacementSpeech,
            correctionProvider: correction,
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        )

        try await coordinator.startSession(snapshot: old, enableLiveRecognition: false)
        await capture.waitUntilStarted()
        let didStopOld = await coordinator.stopSession()
        XCTAssertTrue(didStopOld)
        await probeEntered.waitUntilEntered()

        try await coordinator.startSession(snapshot: replacement, enableLiveRecognition: false)
        await releaseProbe.markEntered()
        await probeReturned.waitUntilEntered()
        try await Task.sleep(nanoseconds: 20_000_000)

        let replacementManifestURL = store.sessionDirectory(for: replacement.sessionID)
            .appendingPathComponent("manifest.json")
        let replacementManifest = try JSONDecoder().decode(
            VoiceSessionSnapshot.self,
            from: Data(contentsOf: replacementManifestURL)
        )
        XCTAssertEqual(replacementManifest.generation, replacement.generation)
        XCTAssertEqual(replacementManifest.speechProvider, replacementSpeech)
        XCTAssertNil(
            replacementManifest.resolvedSpeechProvider,
            "A late provider probe from generation 1 must not become generation 2's runtime provenance."
        )

        let oldManifestURL = store.sessionDirectory(for: old.sessionID)
            .appendingPathComponent("manifest.json")
        let oldManifest = try JSONDecoder().decode(
            VoiceSessionSnapshot.self,
            from: Data(contentsOf: oldManifestURL)
        )
        XCTAssertNil(
            oldManifest.resolvedSpeechProvider,
            "Resolution completed only after the session was superseded, so that provider never ran."
        )
        _ = await coordinator.cancelSession()
    }

    func testCancellationDuringResolvedCorrectionFallbackAttributesActualCorrector() async throws {
        let directory = try makeDirectory()
        let store = VoiceSessionStore(baseDirectory: directory.appendingPathComponent("sessions"))
        let capture = ProviderProvenanceCapture()
        let speech = StubSpeechRecognizer(
            id: "test.speech.ready",
            behavior: .segments([
                SpeechSegment(
                    segmentID: "ready",
                    text: "hello world",
                    finality: .final
                )
            ])
        )
        let requestedCorrectionID = AITransformCorrector.id(for: .proofread)
        let requestedCorrection = StubCorrector(
            id: requestedCorrectionID,
            readiness: .temporarilyUnavailable(
                retryAfterSeconds: nil,
                reason: .modelNotFound
            )
        )
        let correctionEntered = AsyncEntryLatch()
        let fallbackCorrection = HangingCorrector(
            id: VoiceSessionSnapshotFactory.ProviderID.ollamaCorrector,
            entryLatch: correctionEntered
        )
        let recorder = makeRecorder(in: directory)
        let coordinator = VoiceSessionCoordinator(
            capture: capture,
            store: store,
            speechRegistry: SpeechProviderRegistry(providers: [speech]),
            correctionRegistry: CorrectionProviderRegistry(
                providers: [requestedCorrection, fallbackCorrection]
            ),
            diagnosticsRecorder: recorder
        )
        let snapshot = makeSnapshot(
            requestedSpeech: speech.descriptor,
            requestedCorrection: requestedCorrection.descriptor,
            correctionFallbackProviderIDs: [fallbackCorrection.descriptor.id]
        )

        try await coordinator.startSession(snapshot: snapshot, enableLiveRecognition: false)
        await capture.waitUntilStarted()
        let didStop = await coordinator.stopSession()
        XCTAssertTrue(didStop)
        await correctionEntered.waitUntilEntered()
        let didCancel = await coordinator.cancelSession()
        XCTAssertTrue(didCancel)

        let terminal = try XCTUnwrap(recorder.recentTerminalDiagnostics().last)
        XCTAssertEqual(terminal.outcome, .cancelled)
        XCTAssertEqual(terminal.stage, .correction)
        XCTAssertEqual(terminal.provider, .ollama)
        XCTAssertEqual(terminal.locality, .localNetwork)

        let manifestURL = store.sessionDirectory(for: snapshot.sessionID)
            .appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            VoiceSessionSnapshot.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.correctionProvider, requestedCorrection.descriptor)
        XCTAssertEqual(manifest.resolvedCorrectionProvider, fallbackCorrection.descriptor)
    }

    func testReplacementPolicyUsesActualFinalCandidateInsteadOfRequestedAppleTransform() {
        let requestedTransform = correctionDescriptor(
            id: AITransformCorrector.id(for: .proofread),
            route: .onDeviceOnly
        )
        let deterministic = correctionDescriptor(
            id: DeterministicCorrector.providerID,
            route: .onDeviceOnly
        )
        let snapshot = makeSnapshot(
            requestedSpeech: speechDescriptor(id: "speech", route: .onDeviceOnly),
            requestedCorrection: requestedTransform,
            resolvedCorrection: deterministic
        )
        let raw = RawTranscript(
            text: "hello world",
            localeIdentifier: "en_US",
            providerID: "speech",
            modelVersion: "1"
        )
        let deterministicFinal = FinalTranscript(
            text: "Hello world.",
            rawTranscript: raw,
            correctionCandidate: CorrectionCandidate(
                text: "Hello world.",
                providerID: DeterministicCorrector.providerID,
                modelVersion: "rules-v1"
            ),
            validationOutcome: .accepted(metrics: [:])
        )
        let transformFinal = FinalTranscript(
            text: "Hello, world.",
            rawTranscript: raw,
            correctionCandidate: CorrectionCandidate(
                text: "Hello, world.",
                providerID: AITransformCorrector.id(for: .proofread),
                modelVersion: "system-language-model"
            ),
            validationOutcome: .accepted(metrics: [:])
        )

        XCTAssertFalse(
            VoiceSessionCoordinator.shouldReplaceOwnedText(
                finalTranscript: deterministicFinal,
                snapshot: snapshot
            )
        )
        let selectedTransformButDeterministicCandidate = makeSnapshot(
            requestedSpeech: speechDescriptor(id: "speech", route: .onDeviceOnly),
            requestedCorrection: requestedTransform,
            resolvedCorrection: requestedTransform
        )
        XCTAssertFalse(
            VoiceSessionCoordinator.shouldReplaceOwnedText(
                finalTranscript: deterministicFinal,
                snapshot: selectedTransformButDeterministicCandidate
            ),
            "A candidate's provider is stronger evidence than an outer adapter that internally fell back."
        )
        XCTAssertTrue(
            VoiceSessionCoordinator.shouldReplaceOwnedText(
                finalTranscript: transformFinal,
                snapshot: snapshot
            )
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-provider-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeRecorder(in directory: URL) -> VoiceDiagnosticsRecorder {
        VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("voice-trace.jsonl"),
            terminalManifestURL: directory.appendingPathComponent("voice-terminal-manifest.json")
        )
    }

    private func makeSnapshot(
        requestedSpeech: SpeechProviderDescriptor,
        resolvedSpeech: SpeechProviderDescriptor? = nil,
        requestedCorrection: CorrectionProviderDescriptor,
        resolvedCorrection: CorrectionProviderDescriptor? = nil,
        correctionFallbackProviderIDs: [String] = []
    ) -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            speechProvider: requestedSpeech,
            resolvedSpeechProvider: resolvedSpeech,
            correctionProvider: requestedCorrection,
            resolvedCorrectionProvider: resolvedCorrection,
            correctionFallbackProviderIDs: correctionFallbackProviderIDs,
            privacyRoute: .localNetworkOnly,
            targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        )
    }

    private func speechDescriptor(
        id: String,
        route: PrivacyRoute
    ) -> SpeechProviderDescriptor {
        SpeechProviderDescriptor(
            id: id,
            displayName: "Requested speech \(id)",
            modelVersion: "requested",
            privacyRoute: route,
            supportsStreaming: true,
            supportsContextualStrings: true
        )
    }

    private func correctionDescriptor(
        id: String,
        route: PrivacyRoute
    ) -> CorrectionProviderDescriptor {
        CorrectionProviderDescriptor(
            id: id,
            displayName: "Requested correction \(id)",
            modelVersion: "requested",
            privacyRoute: route,
            supportsStructuredOutput: false
        )
    }

    private func eventuallyLoadManifest(
        from url: URL,
        until predicate: (VoiceSessionSnapshot) -> Bool
    ) async throws -> VoiceSessionSnapshot {
        let deadline = Date().addingTimeInterval(2)
        var lastSnapshot: VoiceSessionSnapshot?
        repeat {
            if let data = try? Data(contentsOf: url),
               let snapshot = try? JSONDecoder().decode(VoiceSessionSnapshot.self, from: data) {
                lastSnapshot = snapshot
                if predicate(snapshot) { return snapshot }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        return try XCTUnwrap(lastSnapshot)
    }
}

private actor ProviderProvenanceCapture: VoiceCaptureEngine {
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

private actor AsyncEntryLatch {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class HangingSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {
    let descriptor: SpeechProviderDescriptor
    private let entryLatch: AsyncEntryLatch
    private let lock = UnfairLock()
    private var continuations: [VoiceSessionID: AsyncThrowingStream<SpeechEvent, Error>.Continuation] = [:]

    init(id: String, entryLatch: AsyncEntryLatch) {
        descriptor = SpeechProviderDescriptor(
            id: id,
            displayName: "Hanging fallback",
            modelVersion: "test",
            privacyRoute: .onDeviceOnly,
            supportsStreaming: true,
            supportsContextualStrings: true
        )
        self.entryLatch = entryLatch
    }

    func probe() async -> ProviderReadiness {
        .ready(ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            probeTimestamp: Date(),
            capabilities: ["test"]
        ))
    }

    func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                continuations[request.sessionID] = continuation
            }
            Task { await entryLatch.markEntered() }
        }
    }

    func cancel(sessionID: VoiceSessionID) async {
        let continuation = lock.withLock {
            continuations.removeValue(forKey: sessionID)
        }
        continuation?.finish(throwing: CancellationError())
    }
}

private final class DelayedProbeSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {
    let descriptor: SpeechProviderDescriptor
    private let probeEntered: AsyncEntryLatch
    private let releaseProbe: AsyncEntryLatch
    private let probeReturned: AsyncEntryLatch

    init(
        id: String,
        probeEntered: AsyncEntryLatch,
        releaseProbe: AsyncEntryLatch,
        probeReturned: AsyncEntryLatch
    ) {
        descriptor = SpeechProviderDescriptor(
            id: id,
            displayName: "Delayed probe",
            modelVersion: "test",
            privacyRoute: .onDeviceOnly,
            supportsStreaming: true,
            supportsContextualStrings: true
        )
        self.probeEntered = probeEntered
        self.releaseProbe = releaseProbe
        self.probeReturned = probeReturned
    }

    func probe() async -> ProviderReadiness {
        await probeEntered.markEntered()
        await releaseProbe.waitUntilEntered()
        await probeReturned.markEntered()
        return .ready(ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            probeTimestamp: Date(),
            capabilities: ["test"]
        ))
    }

    func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func cancel(sessionID: VoiceSessionID) async {}
}

private final class HangingCorrector: TranscriptCorrector, @unchecked Sendable {
    let descriptor: CorrectionProviderDescriptor
    private let entryLatch: AsyncEntryLatch

    init(id: String, entryLatch: AsyncEntryLatch) {
        descriptor = CorrectionProviderDescriptor(
            id: id,
            displayName: "Hanging corrector",
            modelVersion: "test",
            privacyRoute: .localNetworkOnly,
            supportsStructuredOutput: false
        )
        self.entryLatch = entryLatch
    }

    func probe() async -> ProviderReadiness {
        .ready(ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            probeTimestamp: Date(),
            capabilities: ["test"]
        ))
    }

    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        await entryLatch.markEntered()
        try await Task.sleep(nanoseconds: .max)
        throw CancellationError()
    }

    func cancel(sessionID: VoiceSessionID) async {}
}
