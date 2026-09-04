import Foundation
import AVFoundation

enum LiveRecognitionFailureDisposition: Equatable, Sendable {
    case disableOptionalPreview
    case failSession
}

public actor VoiceSessionCoordinator {
    public static let shared = VoiceSessionCoordinator()
    /// A forgotten hands-free session must not consume disk forever. Reaching this finite budget
    /// follows the ordinary stop/finalize path so the captured audio is preserved.
    public static let defaultMaximumCaptureSeconds: Double = 30 * 60

    private var activeState: VoiceSessionState?

    /// Whether a phase notification carries new information.
    ///
    /// A notification that does not change the phase says nothing, and the recognizer emits one
    /// per revision: a 32-second session announced `recognizing` eighty times inside 0.7 s, each
    /// one a disk append to the trace and a HUD redraw, burying the transitions that do matter in
    /// the one file a report is diagnosed from.
    ///
    /// Generation is part of the identity so a new session always announces its own first phase,
    /// even when it matches where the previous session left off.
    ///
    /// Expressed as a static so the rule is table-testable rather than reachable only by booting a
    /// session against a real microphone.
    static func shouldAnnouncePhase(
        _ phase: SessionPhase,
        generation: SessionGeneration,
        lastAnnounced: (generation: SessionGeneration, phase: SessionPhase)?
    ) -> Bool {
        guard let last = lastAnnounced else { return true }
        return last.generation != generation || last.phase != phase
    }

    /// The last phase actually announced, and the generation it belonged to.
    ///
    /// Scoped by generation so a new session always announces its own first phase, even when
    /// that phase happens to match where the previous session left off.
    private var lastNotifiedPhase: (generation: SessionGeneration, phase: SessionPhase)?
    /// `internal` rather than `private` only so `VoiceCaptureRaceTests` can retire a generation
    /// mid-flight, which is the whole shape of the race being guarded.
    var taskBag: SessionTaskBag?
    private let capture: any VoiceCaptureEngine
    private let store: VoiceSessionStore
    private let speechRegistry: SpeechProviderRegistry
    private let correctionRegistry: CorrectionProviderRegistry
    private let diagnosticsRecorder: VoiceDiagnosticsRecorder
    private let maximumCaptureSeconds: Double
    private let postCaptureWatchdogArmPreparation: (@Sendable () async -> Void)?
    private let captureWatchdogArmPreparation: (@Sendable () async -> Void)?
    private let startStatePreparation: (@Sendable (SessionGeneration) async -> Void)?
    /// The latest caller admitted to the pre-state portion of `startSession`. The actor is
    /// reentrant at cleanup and MainActor hops, so a task bag alone is not installed early enough
    /// to prevent an older caller from resuming and publishing stale state.
    private var startAdmissionID: UUID?

    public var onPhaseChange: (@Sendable (SessionPhase) -> Void)?
    /// Generation-aware phase observation for lifecycle owners that must reject a terminal update
    /// queued by an older session after a newer attempt has begun.
    public var onPhaseChangeWithGeneration: (@Sendable (SessionPhase, SessionGeneration) -> Void)?

    /// Emitted for each live segment while audio is still being captured, so the delivery
    /// layer can type progressively. `.volatile` segments are still being revised;
    /// `.final` marks an endpoint and seals a commit barrier.
    public var onLiveSegment: (@Sendable (SpeechSegment) -> Void)?

    /// Live microphone level, forwarded for HUD metering.
    public var onAudioLevel: (@Sendable (Float) -> Void)?

    /// Gives the app a chance to claim the transcript as a spoken command before it is
    /// typed. Returning `true` means the app handled it and nothing should be inserted.
    public var onDeliveryIntercept: (@Sendable (String) async -> Bool)?

    /// One content-free event for any failure, cancellation, or supersession. AppKit uses the
    /// same object that was persisted by `VoiceDiagnosticsRecorder`, so Activity and the support
    /// report cannot drift into two different explanations of the same terminal edge.
    public var onTerminalDiagnostic: (@Sendable (VoiceTerminalDiagnostic) -> Void)?

    private var liveStream: LiveSpeechStream?
    /// The reducer starts capture in a child task. Stop must join that setup task before it asks
    /// the capture actor to finalize; otherwise the actor may process stop first and a delayed
    /// start second, turning the microphone on after the user pressed Stop.
    private var captureStartTask: Task<Void, Never>?
    /// Terminal reducer commands are synchronous, while capture teardown is actor-isolated. Keep
    /// the scheduled teardown so the next generation can join it before opening the microphone.
    private var captureCleanupTask: Task<Void, Never>?
    /// Identifies the cleanup represented by `captureCleanupTask`. `startSession` is reentrant while
    /// it awaits teardown, so another terminal event can replace the retained task in that window;
    /// the identity makes the barrier loop until the latest cleanup has completed.
    private var captureCleanupID: UUID?
    private let captureCleanupPreparation: (@Sendable () async -> Void)?

    /// Bounds every phase after capture ends. See `SessionWatchdog`.
    private let watchdog = SessionWatchdog()
    /// Retained so tests can join the deliberately delayed arm, and so its lifecycle is explicit
    /// rather than fire-and-forget coordinator work.
    private var postCaptureWatchdogArmTask: Task<Void, Never>?
    /// A separate instance bounds active capture, avoiding arm/disarm ordering between the
    /// recording timer and the post-capture provider timer.
    private let captureWatchdog = SessionWatchdog()
    /// Prevents a failed persistence report from recursively trying to persist its own failed
    /// manifest forever. The actor makes this a serialized state bit, not a racy global flag.
    private var handlingPersistenceFailure = false

    private init() {
        capture = DurableVoiceCapture.shared
        store = .shared
        speechRegistry = .shared
        correctionRegistry = .shared
        diagnosticsRecorder = .shared
        maximumCaptureSeconds = Self.defaultMaximumCaptureSeconds
        postCaptureWatchdogArmPreparation = nil
        captureWatchdogArmPreparation = nil
        startStatePreparation = nil
        captureCleanupPreparation = nil
    }

    /// Test seam. Production always goes through `shared`; this exists so the capture-start and
    /// capture-finalize races can be driven against a double instead of a live microphone.
    init(
        capture: any VoiceCaptureEngine,
        store: VoiceSessionStore = .shared,
        speechRegistry: SpeechProviderRegistry = .shared,
        correctionRegistry: CorrectionProviderRegistry = .shared,
        diagnosticsRecorder: VoiceDiagnosticsRecorder = .shared,
        maximumCaptureSeconds: Double = VoiceSessionCoordinator.defaultMaximumCaptureSeconds,
        postCaptureWatchdogArmPreparation: (@Sendable () async -> Void)? = nil,
        captureWatchdogArmPreparation: (@Sendable () async -> Void)? = nil,
        startStatePreparation: (@Sendable (SessionGeneration) async -> Void)? = nil,
        captureCleanupPreparation: (@Sendable () async -> Void)? = nil
    ) {
        self.capture = capture
        self.store = store
        self.speechRegistry = speechRegistry
        self.correctionRegistry = correctionRegistry
        self.diagnosticsRecorder = diagnosticsRecorder
        self.maximumCaptureSeconds = maximumCaptureSeconds
        self.postCaptureWatchdogArmPreparation = postCaptureWatchdogArmPreparation
        self.captureWatchdogArmPreparation = captureWatchdogArmPreparation
        self.startStatePreparation = startStatePreparation
        self.captureCleanupPreparation = captureCleanupPreparation
    }

    /// Test seam: install a bag so `performStartAudioCapture` has a generation to compare against.
    func installTaskBagForTesting(_ bag: SessionTaskBag?) {
        taskBag = bag
    }

    // Actor-isolated setters — callbacks are stored state and cannot be assigned
    // from outside the actor.
    public func setOnPhaseChange(_ handler: (@Sendable (SessionPhase) -> Void)?) {
        onPhaseChange = handler
    }

    public func setOnPhaseChangeWithGeneration(
        _ handler: (@Sendable (SessionPhase, SessionGeneration) -> Void)?
    ) {
        onPhaseChangeWithGeneration = handler
    }

    public func setOnLiveSegment(_ handler: (@Sendable (SpeechSegment) -> Void)?) {
        onLiveSegment = handler
    }

    public func setOnAudioLevel(_ handler: (@Sendable (Float) -> Void)?) {
        onAudioLevel = handler
    }

    public func setOnDeliveryIntercept(_ handler: (@Sendable (String) async -> Bool)?) {
        onDeliveryIntercept = handler
    }

    public func setOnTerminalDiagnostic(
        _ handler: (@Sendable (VoiceTerminalDiagnostic) -> Void)?
    ) {
        onTerminalDiagnostic = handler
    }

    /// The raw and corrected transcripts of the requested generation, once recognition has run.
    /// A caller can cross an actor hop while a newer session replaces `activeState`; requiring the
    /// generation here prevents an older UI task from reading that newer session's transcript.
    public func transcripts(
        for generation: SessionGeneration
    ) -> (raw: String, final: String)? {
        guard let state = activeState,
              state.snapshot.generation == generation,
              let raw = state.rawTranscript,
              let final = state.finalTranscript else { return nil }
        return (raw.text, final.text)
    }

    public func startSession(
        snapshot: VoiceSessionSnapshot,
        mode: DictationMode = .hold,
        enableLiveRecognition: Bool = VoicePreferences.isRealTimeTypingEnabled
    ) async throws {
        try Task.checkCancellation()
        guard VoicePermissionPolicy.mayStartCloudAudio(
            privacyRoute: snapshot.privacyRoute,
            consentGranted: VoicePreferences.hasCloudAudioConsent
        ) else {
            DevTypeLog.voice.error(
                "[Voice] cloud-capable session refused because explicit audio consent is absent"
            )
            let failure = VoiceFailure(
                stage: .recognition,
                code: .cloudAudioConsentRequired,
                providerID: snapshot.speechProvider.id,
                retryClass: .afterUserAction
            )
            emitTerminal(VoiceTerminalDiagnostic(failure: failure, snapshot: snapshot))
            // Keep the public preflight contract used by non-AppKit callers. The persisted
            // diagnostic carries the richer failure taxonomy; changing the thrown type would
            // make consent indistinguishable from an ordinary provider/capture failure to them.
            throw CloudAudioConsentRequiredError()
        }

        let admissionID = UUID()
        startAdmissionID = admissionID

        // A terminal command from the prior generation may have scheduled capture teardown just
        // before retiring its task bag. Join it before any new setup can reach the capture actor.
        // The barrier rechecks its identity so concurrent starts cannot lose a replacement cleanup
        // while one of them is suspended here.
        await awaitCaptureCleanupBarrier()
        try requireStartAdmission(admissionID)

        // Supersession is a terminal result for the old generation. Reduce cancellation before
        // retiring its bag so cleanup and observers cannot be skipped as stale.
        if let existingState = activeState, taskBag != nil {
            emitTerminal(.superseded(
                snapshot: existingState.snapshot,
                stage: Self.stage(for: existingState.phase)
            ))
            _ = processEvent(
                .cancel,
                generation: existingState.snapshot.generation,
                enableLiveRecognition: enableLiveRecognition
            )
            disarmWatchdogs(for: existingState.snapshot.generation)
            liveStream?.cancel()
            liveStream = nil
            await capture.cancelCapture()
            try requireStartAdmission(admissionID)
            // `processEvent(.cancel)` schedules a new cleanup for the session being superseded.
            // Waiting only for the task that existed on entry lets that newly-created cancel land
            // after the replacement session opens its microphone.
            await awaitCaptureCleanupBarrier()
            try requireStartAdmission(admissionID)
            captureStartTask = nil
            activeState = nil
            taskBag = nil
        }
        try requireStartAdmission(admissionID)

        let generation = snapshot.generation
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: generation)
        self.taskBag = bag

        await MainActor.run {
            VoiceInsertionService.shared.beginSession(targetLease: snapshot.targetLease)
        }
        try await requireStartOwnership(admissionID, bag: bag, insertionLeaseStarted: true)
        await startStatePreparation?(generation)
        try await requireStartOwnership(admissionID, bag: bag, insertionLeaseStarted: true)

        let state = VoiceSessionState(snapshot: snapshot, phase: .preparing)
        self.activeState = state
        if startAdmissionID == admissionID {
            startAdmissionID = nil
        }

        // Create session directory & manifest before capture starts. If this gate fails, do not
        // leave the insertion service armed or a half-live session behind for a later toggle.
        do {
            _ = try store.createSession(snapshot: snapshot)
        } catch {
            activeState = nil
            taskBag = nil
            _ = await MainActor.run { VoiceInsertionService.shared.rollback() }
            let failure = VoiceFailure(
                stage: .persistence,
                code: .manifestWriteFailed,
                retryClass: .afterUserAction,
                artifactState: .absent,
                userAction: .freeDiskSpace
            )
            emitTerminal(VoiceTerminalDiagnostic(failure: failure, snapshot: snapshot))
            throw failure
        }

        // Reduce start event
        _ = processEvent(
            .startCapture(mode: mode),
            generation: generation,
            enableLiveRecognition: enableLiveRecognition
        )
        let pendingCaptureStart = captureStartTask
        await pendingCaptureStart?.value
        if let state = activeState,
           state.snapshot.generation == generation,
           case .failed(let failure) = state.phase {
            throw failure
        }
        guard taskBag === bag,
              activeState?.snapshot.generation == generation else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
        } catch {
            _ = await cancelSession()
            throw error
        }
    }

    /// Rejects a pre-state continuation that was cancelled or superseded while its actor method
    /// was suspended. Only the still-current owner may clear the admission token.
    private func requireStartAdmission(_ admissionID: UUID) throws {
        do {
            try Task.checkCancellation()
        } catch {
            if startAdmissionID == admissionID {
                startAdmissionID = nil
            }
            throw error
        }
        guard startAdmissionID == admissionID else { throw CancellationError() }
    }

    /// Extends admission validation once the task bag and app insertion lease exist. A stale caller
    /// must not roll back a lease already replaced by a newer bag; if it still owns the bag, its
    /// rollback is enqueued before any later start can enqueue `beginSession` on MainActor.
    private func requireStartOwnership(
        _ admissionID: UUID,
        bag: SessionTaskBag,
        insertionLeaseStarted: Bool
    ) async throws {
        do {
            try requireStartAdmission(admissionID)
            guard taskBag === bag else { throw CancellationError() }
        } catch {
            let stillOwnsBag = taskBag === bag
            if startAdmissionID == admissionID {
                startAdmissionID = nil
            }
            if stillOwnsBag {
                taskBag = nil
                if insertionLeaseStarted {
                    _ = await MainActor.run { VoiceInsertionService.shared.rollback() }
                }
            }
            throw error
        }
    }

    @discardableResult
    public func stopSession() async -> Bool {
        let pendingCaptureStart = captureStartTask
        await pendingCaptureStart?.value
        guard let state = activeState, taskBag != nil else { return false }
        let generation = state.snapshot.generation
        return processEvent(.stopCapture, generation: generation)
    }

    @discardableResult
    public func cancelSession() async -> Bool {
        guard let state = activeState, taskBag != nil else { return false }
        // Reduce cancellation while the session generation is still current. Advancing the bag
        // first makes the reducer reject its own `.cancel` event as stale, which skips the
        // terminal HUD/manifest transition and leaves cancellation invisible to observers.
        let generation = state.snapshot.generation
        emitTerminal(.cancelled(
            snapshot: state.snapshot,
            stage: Self.stage(for: state.phase)
        ))
        disarmWatchdogs(for: generation)
        liveStream?.cancel()
        liveStream = nil
        _ = await MainActor.run { VoiceInsertionService.shared.rollback() }
        let accepted = processEvent(.cancel, generation: generation)
        await capture.cancelCapture()
        captureStartTask = nil
        self.activeState = nil
        self.taskBag = nil
        return accepted
    }

    private func processEvent(
        _ event: VoiceSessionEvent,
        generation: SessionGeneration,
        enableLiveRecognition: Bool = true
    ) -> Bool {
        guard var state = activeState, let bag = taskBag else { return false }
        guard bag.isCurrentGeneration(generation) else { return false }

        let result = VoiceSessionReducer.reduce(state: &state, event: event, eventGeneration: generation)
        switch result {
        case .success(let commands):
            self.activeState = state
            executeCommands(
                commands,
                for: state.snapshot,
                generation: generation,
                enableLiveRecognition: enableLiveRecognition
            )
            return true
        case .failure(let error):
            _ = error
            let fail = VoiceFailure(
                stage: .protocolViolation,
                code: .speechProtocolViolation
            )
            state.phase = .failed(fail)
            state.failure = fail
            self.activeState = state
            // A protocol violation is terminal too. Route it through the same command path as
            // provider and persistence failures so an invalid event cannot strand the microphone,
            // live recognizer, watchdog, or insertion lease.
            executeCommands(
                [
                    .notifyHUD(phase: .failed(fail)),
                    .persistManifest(phase: .failed(fail)),
                    .cleanupResources
                ],
                for: state.snapshot,
                generation: generation
            )
            return false
        }
    }

    // MARK: - Watchdog

    private func armWatchdog(seconds: Double, generation: SessionGeneration) {
        let budget = SessionWatchdog.normalizedSeconds(seconds)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPostCaptureWatchdogArm(
                seconds: budget,
                generation: generation
            )
        }
        postCaptureWatchdogArmTask = task
    }

    private func performPostCaptureWatchdogArm(
        seconds: Double,
        generation: SessionGeneration
    ) async {
        guard ownsActiveGeneration(generation) else { return }
        await postCaptureWatchdogArmPreparation?()
        guard ownsActiveGeneration(generation) else { return }

        let didArm = await watchdog.arm(seconds: seconds, generation: generation) { [weak self] expired in
            await self?.failOnTimeout(generation: expired, after: seconds)
        }
        guard didArm else { return }

        // The coordinator actor is reentrant across the watchdog actor hop. If terminal cleanup
        // retired this generation while `arm` was pending, undo only this generation's deadline;
        // a newer session's arm must survive.
        guard ownsActiveGeneration(generation) else {
            await watchdog.disarm(ifArmedFor: generation)
            return
        }
    }

    private func ownsActiveGeneration(_ generation: SessionGeneration) -> Bool {
        guard taskBag?.isCurrentGeneration(generation) == true,
              let state = activeState,
              state.snapshot.generation == generation else { return false }
        switch state.phase {
        case .completed, .failed, .cancelled:
            return false
        default:
            return true
        }
    }

    /// Commits the provider selected by readiness resolution without replacing the requested
    /// plan. The generation checks make a late probe from an older session unable to rewrite the
    /// active session's manifest, and persisting before provider entry leaves recovery with the
    /// exact component that was about to handle the durable audio artifact.
    private func recordResolvedSpeechProvider(
        _ descriptor: SpeechProviderDescriptor,
        generation: SessionGeneration
    ) -> Bool {
        guard taskBag?.isCurrentGeneration(generation) == true,
              var state = activeState,
              state.snapshot.generation == generation else { return false }

        if state.snapshot.resolvedSpeechProvider == descriptor { return true }
        state.snapshot = state.snapshot.resolvingSpeechProvider(descriptor)
        activeState = state

        do {
            _ = try store.createSession(snapshot: state.snapshot)
            return taskBag?.isCurrentGeneration(generation) == true
        } catch {
            handlePersistenceFailure(error, generation: generation, artifactState: .partial)
            return false
        }
    }

    /// Correction resolution follows the same durable, generation-scoped provenance contract as
    /// recognition. A corrector may itself return a candidate attributed to a registered fallback;
    /// callers can record that descriptor again before the reducer advances to delivery.
    private func recordResolvedCorrectionProvider(
        _ descriptor: CorrectionProviderDescriptor,
        generation: SessionGeneration
    ) -> Bool {
        guard taskBag?.isCurrentGeneration(generation) == true,
              var state = activeState,
              state.snapshot.generation == generation else { return false }

        if state.snapshot.resolvedCorrectionProvider == descriptor { return true }
        state.snapshot = state.snapshot.resolvingCorrectionProvider(descriptor)
        activeState = state

        do {
            _ = try store.createSession(snapshot: state.snapshot)
            return taskBag?.isCurrentGeneration(generation) == true
        } catch {
            handlePersistenceFailure(error, generation: generation, artifactState: .partial)
            return false
        }
    }

    /// Joins the retained test-delayed arm before exposing the watchdog state.
    func postCaptureWatchdogIsArmedAfterPendingArmForTesting() async -> Bool {
        let pendingArm = postCaptureWatchdogArmTask
        await pendingArm?.value
        return await watchdog.isArmed
    }

    private func disarmWatchdogs(for generation: SessionGeneration) {
        Task { [watchdog, captureWatchdog] in
            await watchdog.disarm(ifArmedFor: generation)
            await captureWatchdog.disarm(ifArmedFor: generation)
        }
    }

    private func disarmCaptureWatchdog(for generation: SessionGeneration) {
        Task { [captureWatchdog] in
            await captureWatchdog.disarm(ifArmedFor: generation)
        }
    }

    private func armCaptureWatchdog(generation: SessionGeneration) async {
        guard ownsCapturingGeneration(generation) else { return }
        await captureWatchdogArmPreparation?()
        guard ownsCapturingGeneration(generation) else { return }

        let didArm = await captureWatchdog.arm(
            seconds: maximumCaptureSeconds,
            generation: generation
        ) { [weak self] expired in
            await self?.stopCaptureAtLimit(generation: expired)
        }
        guard didArm else { return }

        guard ownsCapturingGeneration(generation) else {
            await captureWatchdog.disarm(ifArmedFor: generation)
            return
        }
    }

    private func ownsCapturingGeneration(_ generation: SessionGeneration) -> Bool {
        guard ownsActiveGeneration(generation),
              let state = activeState,
              case .capturing = state.phase else { return false }
        return true
    }

    func captureWatchdogIsArmedForTesting() async -> Bool {
        await captureWatchdog.isArmed
    }

    private func stopCaptureAtLimit(generation: SessionGeneration) {
        guard taskBag?.isCurrentGeneration(generation) == true,
              let state = activeState,
              state.snapshot.generation == generation,
              case .capturing = state.phase else {
            return
        }
        diagnosticsRecorder.record(
            "capture.limit",
            note: "automaticStop seconds=\(Int(SessionWatchdog.normalizedSeconds(maximumCaptureSeconds)))"
        )
        _ = processEvent(.stopCapture, generation: generation)
    }

    private func failOnTimeout(generation: SessionGeneration, after seconds: Double) {
        guard taskBag?.isCurrentGeneration(generation) == true,
              let state = activeState,
              state.snapshot.generation == generation else { return }
        switch state.phase {
        case .completed, .failed, .cancelled:
            return   // finished in time
        default:
            break
        }

        liveStream?.cancel()
        liveStream = nil

        let failure = VoiceFailure(
            stage: Self.stage(for: state.phase),
            code: .requestTimeout,
            retryClass: .afterUserAction,
            redactedDetail: "Session exceeded \(Int(seconds))s in phase \(state.phase)"
        )
        _ = processEvent(.failureOccurred(failure), generation: generation)
    }

    /// Attributes a timeout to the stage that was actually running, so the diagnostic
    /// names the component that stalled rather than reporting a generic failure.
    static func stage(for phase: SessionPhase) -> FailureStage {
        switch phase {
        case .preparing, .capturing: return .audioCapture
        case .finalizingAudio: return .audioFinalization
        case .recognizing: return .recognition
        case .validatingRaw: return .rawValidation
        case .correcting: return .correction
        case .validatingCorrection: return .correctionValidation
        case .readyForDelivery, .delivering: return .delivery
        case .completed, .failed, .cancelled, .recoverable: return .protocolViolation
        }
    }

    private func startLiveRecognition(
        snapshot: VoiceSessionSnapshot,
        generation: SessionGeneration,
        enabled: Bool
    ) async {
        liveStream?.cancel()
        liveStream = nil

        guard enabled else {
            await capture.setOnPCMBuffer(nil)
            await capture.setOnAudioLevelUpdate { [weak self] level in
                guard let self else { return }
                Task { await self.emitAudioLevel(level) }
            }
            DevTypeLog.voice.info("[Voice] Apple live recognition disabled for this session")
            return
        }

        let stream = LiveSpeechStream(
            locale: Locale(identifier: snapshot.localeIdentifier),
            contextualStrings: snapshot.vocabularySnapshot.terms,
            onSegment: { [weak self] segment in
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.ingestLiveSegment(segment, generation: generation)
                }
            },
            onFailure: { [weak self] failure in
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.ingestLiveFailure(
                        failure,
                        snapshot: snapshot,
                        generation: generation
                    )
                }
            }
        )
        liveStream = stream

        await capture.setOnPCMBuffer { [weak stream] buffer in
            stream?.append(buffer)
        }
        await capture.setOnAudioLevelUpdate { [weak self] level in
            guard let self else { return }
            Task { await self.emitAudioLevel(level) }
        }
    }

    private func finishLiveRecognition() async {
        await capture.setOnPCMBuffer(nil)
        liveStream?.finish()
    }

    private func emitAudioLevel(_ level: Float) {
        onAudioLevel?(level)
    }

    private func ingestLiveSegment(_ segment: SpeechSegment, generation: SessionGeneration) -> Bool {
        processEvent(.liveSegmentReceived(segment), generation: generation)
    }

    static func liveRecognitionFailureDisposition(
        finalSpeechProviderID: String
    ) -> LiveRecognitionFailureDisposition {
        switch finalSpeechProviderID {
        case VoiceSessionSnapshotFactory.ProviderID.gemini,
             VoiceSessionSnapshotFactory.ProviderID.whisperServer,
             VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer:
            return .disableOptionalPreview
        default:
            // Legacy Apple Speech is also the final recognizer for its sessions. SpeechAnalyzer,
            // Gemini, and Whisper consume the durable capture independently of live preview.
            // Unknown future relationships fail closed until their independence is explicit.
            return .failSession
        }
    }

    private func ingestLiveFailure(
        _ failure: VoiceFailure,
        snapshot: VoiceSessionSnapshot,
        generation: SessionGeneration
    ) async -> Bool {
        guard taskBag?.isCurrentGeneration(generation) == true else { return false }
        switch Self.liveRecognitionFailureDisposition(
            finalSpeechProviderID: snapshot.speechProvider.id
        ) {
        case .disableOptionalPreview:
            liveStream?.cancel()
            liveStream = nil
            await capture.setOnPCMBuffer(nil)
            diagnosticsRecorder.record(
                "stream.unavailable",
                note: "optionalPreviewDisabled code=\(failure.code.rawValue)"
            )
            DevTypeLog.voice.info(
                "[Voice] optional live preview disabled; final provider remains active provider=\(snapshot.speechProvider.id, privacy: .public) code=\(failure.code.rawValue, privacy: .public)"
            )
            return true
        case .failSession:
            return processEvent(.failureOccurred(failure), generation: generation)
        }
    }

    // MARK: - Capture task bodies
    //
    // Lifted out of `executeCommands` so the ordering rules below can be driven directly by
    // `VoiceCaptureRaceTests`. Inside a `Task { }` in a switch case they were reachable only by
    // booting a whole session against a real microphone, which is why the guarantees they carry
    // were previously asserted by grepping this file.

    /// Opens the microphone for `generation`, or tears it back down if that generation retired
    /// while it was being opened.
    ///
    /// Two awaits sit between entry and a live microphone, and a session can be superseded or
    /// stopped across either. Checking only on the way in is what allowed a cancelled session to
    /// still open the mic and leave it open — which the user sees as a recording indicator that
    /// never goes away.
    func performStartAudioCapture(
        sessionDir: URL,
        snapshot: VoiceSessionSnapshot,
        generation: SessionGeneration,
        enableLiveRecognition: Bool = true
    ) async {
        do {
            guard taskBag?.isCurrentGeneration(generation) == true else { return }
            try Task.checkCancellation()
            await startLiveRecognition(
                snapshot: snapshot,
                generation: generation,
                enabled: enableLiveRecognition
            )
            try Task.checkCancellation()
            try await capture.startCapture(sessionDirectory: sessionDir)
            // Setup finished, but this task may have lost the race while it ran.
            guard taskBag?.isCurrentGeneration(generation) == true else {
                await capture.cancelCapture()
                return
            }
            await armCaptureWatchdog(generation: generation)
        } catch is CancellationError {
            // A cooperative stop, not a device problem. This used to fall into the catch below
            // and surface as `.noMicrophone`, so every superseded session accused the user's
            // microphone of being broken.
            await capture.cancelCapture()
            cancelCurrentSessionIfNeeded(generation: generation)
        } catch {
            let fail = (error as? VoiceFailure) ?? VoiceFailure(
                stage: .audioCapture,
                code: .noMicrophone
            )
            _ = processEvent(.failureOccurred(fail), generation: generation)
        }
    }

    /// Closes the microphone and hands the artifact to the reducer, unless this generation
    /// retired first — in which case the artifact belongs to a session nobody is waiting on.
    func performFinalizeAudioCapture(generation: SessionGeneration) async {
        do {
            try Task.checkCancellation()
            await finishLiveRecognition()
            try Task.checkCancellation()
            let artifact = try await capture.stopCapture()
            _ = processEvent(.audioFinalized(artifact), generation: generation)
        } catch is CancellationError {
            // Reporting `.zeroFramesCaptured` here turned an ordinary stop into a failure
            // banner for a session the user had already moved on from.
            cancelCurrentSessionIfNeeded(generation: generation)
        } catch {
            let fail = (error as? VoiceFailure) ?? VoiceFailure(
                stage: .audioFinalization,
                code: .zeroFramesCaptured
            )
            _ = processEvent(.failureOccurred(fail), generation: generation)
        }
    }

    private func executeCommands(
        _ commands: [VoiceSessionCommand],
        for snapshot: VoiceSessionSnapshot,
        generation: SessionGeneration,
        enableLiveRecognition: Bool = true
    ) {
        for command in commands {
            // A command can synchronously expose a persistence failure, which transitions the
            // reducer to a terminal state and cancels/removes the task bag. Do not continue the
            // stale command list afterward (for example, do not publish a completed HUD state or
            // attempt the remaining manifest write after a receipt write already failed).
            guard taskBag?.isCurrentGeneration(generation) == true else { return }
            switch command {
            case .notifyHUD(let phase):
                // A notification that does not change the phase carries no information, and
                // the recognizer emits one per revision: a 32-second session logged
                // `recognizing` eighty times inside 0.7 s, each one a disk append to the
                // trace and a HUD redraw. Worse, it buries the transitions that do matter in
                // the one file a report is diagnosed from. Deduplicate here rather than at
                // each of the nineteen emitters, so no future one can reintroduce it.
                guard Self.shouldAnnouncePhase(
                    phase, generation: generation, lastAnnounced: lastNotifiedPhase
                ) else { break }
                lastNotifiedPhase = (generation, phase)

                diagnosticsRecorder.record(
                    "session.phase", note: Self.traceLabel(for: phase)
                )
                if let diagnostic = Self.terminalDiagnostic(for: phase, snapshot: snapshot) {
                    emitTerminal(diagnostic)
                }
                onPhaseChange?(phase)
                onPhaseChangeWithGeneration?(phase, generation)

            case .startAudioCapture:
                let sessionDir = store.sessionDirectory(for: snapshot.sessionID)
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    await self.performStartAudioCapture(
                        sessionDir: sessionDir,
                        snapshot: snapshot,
                        generation: generation,
                        enableLiveRecognition: enableLiveRecognition
                    )
                }
                captureStartTask = task
                _ = taskBag?.add(task)

            case .finalizeAudioCapture:
                disarmCaptureWatchdog(for: generation)
                armWatchdog(seconds: snapshot.timeoutSeconds, generation: generation)
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    await self.performFinalizeAudioCapture(generation: generation)
                }
                _ = taskBag?.add(task)

            case .transcribeAudio(let audio):
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    let resolution = await self.speechRegistry.resolveActiveRecognizer(
                        preferredID: snapshot.speechProvider.id,
                        privacyRoute: snapshot.privacyRoute
                    )
                    guard await self.taskBag?.isCurrentGeneration(generation) == true else {
                        return
                    }
                    guard let recognizer = resolution.recognizer else {
                        let failure = resolution.failure ?? VoiceFailure(
                            stage: .recognition,
                            code: .noReadyProvider,
                            retryClass: .afterUserAction,
                            artifactState: .durable,
                            userAction: .retryWithOtherProvider
                        )
                        _ = await self.processEvent(.failureOccurred(failure), generation: generation)
                        return
                    }
                    guard await self.recordResolvedSpeechProvider(
                        recognizer.descriptor,
                        generation: generation
                    ) else { return }

                    let speechRequest = SpeechRequest(
                        sessionID: snapshot.sessionID,
                        generation: generation,
                        audio: audio,
                        locale: Locale(identifier: snapshot.localeIdentifier),
                        vocabulary: snapshot.vocabularySnapshot,
                        deadline: Date().addingTimeInterval(snapshot.timeoutSeconds),
                        privacyRoute: snapshot.privacyRoute
                    )

                    do {
                        let stream = recognizer.transcribe(speechRequest)
                        for try await event in stream {
                            guard await self.taskBag?.isCurrentGeneration(generation) == true else { break }
                            switch event {
                            case .segment(let seg):
                                _ = await self.processEvent(.speechSegmentReceived(seg), generation: generation)
                            case .metrics:
                                break
                            case .completed(let comp):
                                _ = await self.processEvent(.speechCompleted(comp), generation: generation)
                            }
                        }
                    } catch is CancellationError {
                        await self.cancelCurrentSessionIfNeeded(generation: generation)
                    } catch {
                        let fail: VoiceFailure
                        if let providerFailure = error as? VoiceFailure {
                            // The coordinator owns provider resolution. An adapter error may have
                            // no provider id, or may retain the preferred id from before fallback;
                            // neither can override the recognizer that this task actually invoked.
                            fail = VoiceFailure(
                                stage: providerFailure.stage,
                                code: providerFailure.code,
                                providerID: recognizer.descriptor.id,
                                retryClass: providerFailure.retryClass,
                                artifactState: providerFailure.artifactState,
                                userAction: providerFailure.userAction,
                                diagnosticID: providerFailure.diagnosticID,
                                redactedDetail: providerFailure.redactedDetail
                            )
                        } else {
                            fail = VoiceFailure(
                                stage: .recognition,
                                code: .endpointUnreachable,
                                providerID: recognizer.descriptor.id,
                                retryClass: .jitteredBackoff
                            )
                        }
                        _ = await self.processEvent(.failureOccurred(fail), generation: generation)
                    }
                }
                _ = taskBag?.add(task)

            case .validateRawTranscript(let raw):
                _ = processEvent(.rawValidationPassed(raw), generation: generation)

            case .correctTranscript(let raw):
                let task = Task { [weak self] in
                    guard let self = self else { return }

                    // Resolution enforces the session's privacy route and probes the
                    // provider, so an endpoint that is down falls back immediately instead
                    // of stalling the dictation for the whole timeout.
                    let corrector = await self.correctionRegistry.resolveActiveCorrector(
                        preferredID: snapshot.correctionProvider.id,
                        fallbackIDs: snapshot.correctionFallbackProviderIDs,
                        privacyRoute: snapshot.privacyRoute
                    )

                    guard let corrector else {
                        // No provider can be used — deliver exactly what was recognized. The
                        // reducer is still in `.correcting` here, so use the explicit terminal
                        // correction event rather than pretending validation already happened in
                        // the `.validatingCorrection` phase.
                        _ = await self.processEvent(
                            .correctionValidationPassed(FinalTranscript(
                                text: raw.text,
                                rawTranscript: raw,
                                correctionCandidate: nil,
                                validationOutcome: .notApplicable
                            )),
                            generation: generation
                        )
                        return
                    }
                    guard await self.recordResolvedCorrectionProvider(
                        corrector.descriptor,
                        generation: generation
                    ) else { return }

                    let final = await CorrectionPipeline.execute(
                        rawTranscript: raw,
                        corrector: corrector,
                        policy: snapshot.correctionPolicy,
                        vocabulary: snapshot.vocabularySnapshot,
                        deadline: Date().addingTimeInterval(snapshot.timeoutSeconds),
                        privacyRoute: snapshot.privacyRoute,
                        sessionID: snapshot.sessionID,
                        generation: generation
                    )

                    // Some adapters have an internal, registered fallback. The candidate is the
                    // strongest evidence of which implementation produced the final proposal, so
                    // persist that descriptor when it differs from the outer adapter selected by
                    // the registry (for example Apple transform -> deterministic rules).
                    if let candidateID = final.correctionCandidate?.providerID,
                       candidateID != corrector.descriptor.id,
                       let candidateCorrector = await self.correctionRegistry.corrector(
                           for: candidateID
                       ) {
                        guard await self.recordResolvedCorrectionProvider(
                            candidateCorrector.descriptor,
                            generation: generation
                        ) else { return }
                    }

                    // A successful candidate must cross the reducer's candidate-received edge
                    // before validation can complete. The old code emitted only
                    // `correctionValidationPassed` while still in `.correcting`, which turned
                    // every normal voice correction into a protocol failure and made delivery
                    // unreachable. A thrown/empty-provider fallback has no candidate and uses the
                    // reducer's direct raw-result edge above.
                    if let candidate = final.correctionCandidate {
                        guard await self.processEvent(
                            .correctionCandidateReceived(candidate),
                            generation: generation
                        ) else { return }
                    }
                    _ = await self.processEvent(
                        .correctionValidationPassed(final),
                        generation: generation
                    )
                }
                _ = taskBag?.add(task)

            case .applyLiveSegment(let segment):
                // `DispatchQueue.main.async`, not `Task { @MainActor }`.
                //
                // Unstructured tasks carry no ordering guarantee: several are in flight at
                // once at speaking speed, and if a later segment is applied before an
                // earlier one, a new segment id lands out of order and the transcript is
                // assembled in the wrong sequence — which the reconciler then corrects by
                // erasing. The main queue is FIFO, so segments arrive in the order the
                // recognizer produced them.
                DispatchQueue.main.async {
                    VoiceInsertionService.shared.applyLiveSegment(segment)
                }
                onLiveSegment?(segment)

            case .validateCorrectionCandidate:
                break

            case .cleanupResources:
                disarmWatchdogs(for: generation)
                liveStream?.cancel()
                liveStream = nil
                scheduleCaptureCleanup()
                if let phase = activeState?.phase {
                    switch phase {
                    case .completed, .failed, .cancelled:
                        _ = taskBag?.advanceGenerationAndCancelAll()
                        taskBag = nil
                        captureStartTask = nil
                    default:
                        break
                    }
                }

            case .deliverTranscript(let finalTranscript, let lease):
                let task = Task { [weak self] in
                    guard let self = self else { return }

                    if let intercept = await self.onDeliveryIntercept,
                       await intercept(finalTranscript.text) {
                        _ = await self.processEvent(
                            .deliveryIntercepted(command: finalTranscript.text),
                            generation: generation
                        )
                        return
                    }

                    let receipt = await VoiceInsertionService.shared.deliver(
                        text: finalTranscript.text,
                        targetLease: lease,
                        sessionID: snapshot.sessionID,
                        generation: generation,
                        // A proofread or rewrite pass supersedes the live text rather than
                        // refining it, so it is allowed past the commit barrier.
                        replacingOwnedText: Self.shouldReplaceOwnedText(
                            finalTranscript: finalTranscript,
                            snapshot: snapshot
                        ),
                        // The replacement is bounded by the same deletion ceiling this
                        // session's correction policy declares, so a transcript that lost
                        // most of the dictation cannot delete the rest from the document.
                        maxDeletionRatio: snapshot.correctionPolicy.maxDeletionRatio
                    )
                    if receipt.evidenceQuality == .targetMismatch {
                        _ = await self.processEvent(.targetLeaseInvalidated(reason: "Target application PID changed before delivery"), generation: generation)
                    } else {
                        _ = await self.processEvent(.deliveryCompleted(receipt), generation: generation)
                    }
                }
                _ = taskBag?.add(task)

            case .persistManifest:
                do {
                    _ = try store.createSession(snapshot: snapshot)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }

            case .persistAudio(let artifact):
                do {
                    try store.saveAudioArtifact(artifact, for: snapshot.sessionID)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }

            case .persistRaw(let raw):
                do {
                    try store.saveRawTranscript(raw, for: snapshot.sessionID)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }

            case .persistFinal(let final):
                do {
                    try store.saveFinalTranscript(final, for: snapshot.sessionID)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }

            case .persistReceipt(let receipt):
                do {
                    try store.saveDeliveryReceipt(receipt, for: snapshot.sessionID)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }
            }
        }
    }

    /// A final transcript may cross the live-typing commit barrier only when an accepted
    /// rewriting provider actually produced its candidate. The requested preference is not
    /// evidence: readiness resolution may have selected deterministic rules instead.
    static func shouldReplaceOwnedText(
        finalTranscript: FinalTranscript,
        snapshot: VoiceSessionSnapshot
    ) -> Bool {
        guard case .accepted = finalTranscript.validationOutcome else { return false }
        let actualProviderID = finalTranscript.correctionCandidate?.providerID
            ?? snapshot.resolvedCorrectionProvider?.id
        guard let actualProviderID else { return false }
        return AITransformCorrector.isTransformProvider(actualProviderID)
    }

    private func handlePersistenceFailure(
        _ error: Error,
        generation: SessionGeneration,
        artifactState: ArtifactState
    ) {
        guard !handlingPersistenceFailure else {
            let failureKind = String(reflecting: type(of: error))
            DevTypeLog.store.error(
                "[Voice] secondary persistence failure while recording the primary failure type=\(failureKind, privacy: .public)"
            )
            return
        }

        handlingPersistenceFailure = true
        defer { handlingPersistenceFailure = false }

        let failure = VoiceFailure(
            stage: .persistence,
            code: .manifestWriteFailed,
            retryClass: .afterUserAction,
            artifactState: artifactState,
            userAction: .freeDiskSpace
        )
        if let state = activeState {
            switch state.phase {
            case .completed, .failed, .cancelled:
                // Receipt/terminal-manifest persistence can fail after the reducer has already
                // committed a terminal state. Preserve that state and report the storage failure
                // directly instead of converting it into a protocol violation.
                emitTerminal(VoiceTerminalDiagnostic(failure: failure, snapshot: state.snapshot))
                cleanUpAfterUntransitionablePersistenceFailure(generation: generation)
                return
            default:
                break
            }
        }
        guard processEvent(.failureOccurred(failure), generation: generation) else {
            // A receipt failure can happen after the reducer has already reached `.completed`.
            // Preserve that truthful delivery state, but still tear down capture/watchdog/task
            // resources and leave a structured OSLog record instead of silently leaking them.
            DevTypeLog.store.error(
                "[Voice] could not transition after persistence failure because the session was terminal"
            )
            cleanUpAfterUntransitionablePersistenceFailure(generation: generation)
            return
        }
    }

    private func cleanUpAfterUntransitionablePersistenceFailure(generation: SessionGeneration) {
        disarmWatchdogs(for: generation)
        liveStream?.cancel()
        liveStream = nil
        scheduleCaptureCleanup()
        _ = taskBag?.advanceGenerationAndCancelAll()
        taskBag = nil
        captureStartTask = nil
    }

    private func scheduleCaptureCleanup() {
        let preparation = captureCleanupPreparation
        // One retained task must represent every teardown still in flight. If terminal paths race,
        // chain them rather than replacing an older task that a new generation would then miss.
        let precedingCleanup = captureCleanupTask
        let task = Task { [capture] in
            await precedingCleanup?.value
            await preparation?()
            await capture.cancelCapture()
        }
        captureCleanupID = UUID()
        captureCleanupTask = task
    }

    /// Waits until the latest scheduled capture teardown has completed. Actor reentrancy means a
    /// new cleanup can be installed while this method awaits an older one, so a single snapshot is
    /// not a sufficient barrier.
    private func awaitCaptureCleanupBarrier() async {
        while let pendingCleanup = captureCleanupTask,
              let pendingID = captureCleanupID {
            await pendingCleanup.value
            guard captureCleanupID == pendingID else { continue }
            captureCleanupTask = nil
            captureCleanupID = nil
            return
        }
    }

    /// Handles a dependency-originated `CancellationError` only while that generation is still
    /// the active session. User cancellation and supersession retire the bag first and already
    /// emitted their own summary, so late task unwind cannot duplicate it.
    private func cancelCurrentSessionIfNeeded(generation: SessionGeneration) {
        guard let state = activeState,
              taskBag?.isCurrentGeneration(generation) == true else { return }
        switch state.phase {
        case .completed, .failed, .cancelled:
            return
        default:
            break
        }
        emitTerminal(.cancelled(
            snapshot: state.snapshot,
            stage: Self.stage(for: state.phase)
        ))
        _ = processEvent(.cancel, generation: generation)
    }

    private func emitTerminal(_ diagnostic: VoiceTerminalDiagnostic) {
        _ = diagnosticsRecorder.recordTerminal(diagnostic)
        onTerminalDiagnostic?(diagnostic)
    }

    private static func terminalDiagnostic(
        for phase: SessionPhase,
        snapshot: VoiceSessionSnapshot
    ) -> VoiceTerminalDiagnostic? {
        switch phase {
        case .failed(let failure):
            return VoiceTerminalDiagnostic(failure: failure, snapshot: snapshot)
        case .completed(.savedButNotInserted):
            return .deliveryFailure(
                code: .targetLeaseExpired,
                recoverability: .userActionRequired
            )
        case .completed(.inserted(let receipt)) where receipt.deliveredTextLength == 0:
            return .deliveryFailure(
                code: .speechNoSpeech,
                recoverability: .retryImmediately
            )
        default:
            return nil
        }
    }

    /// The opt-in trace may contain transcript-bearing segment records, but a phase marker never
    /// needs the associated failure description, delivery reason, or spoken command.
    private static func traceLabel(for phase: SessionPhase) -> String {
        switch phase {
        case .preparing: return "preparing"
        case .capturing(let mode): return "capturing.\(mode.rawValue)"
        case .finalizingAudio: return "finalizingAudio"
        case .recognizing: return "recognizing"
        case .validatingRaw: return "validatingRaw"
        case .correcting: return "correcting"
        case .validatingCorrection: return "validatingCorrection"
        case .readyForDelivery: return "readyForDelivery"
        case .delivering: return "delivering"
        case .completed(.inserted): return "completed.inserted"
        case .completed(.savedButNotInserted): return "completed.savedButNotInserted"
        case .completed(.copiedToClipboard): return "completed.copiedToClipboard"
        case .completed(.voiceCommandExecuted): return "completed.voiceCommandExecuted"
        case .failed(let failure):
            return "failed.\(failure.stage.rawValue).\(failure.code.rawValue)"
        case .cancelled: return "cancelled"
        case .recoverable: return "recoverable"
        }
    }
}
