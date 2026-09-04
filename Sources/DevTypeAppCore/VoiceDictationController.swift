import AppKit
import ExpanderEngine

private struct RecoveredVoiceActivityMetadata: Sendable {
    let sessionID: VoiceSessionID
    let timestamp: Date
    let characterCount: Int
}

/// Lock-owned state machine for the app-side start gesture. Permission prompts and coordinator
/// setup both suspend; treating those intervals as idle lets repeated hotkeys create overlapping
/// sessions and lets a late permission continuation resurrect an attempt the user stopped.
struct VoiceDictationLifecycle {
    typealias Attempt = UInt64

    enum Phase: Equatable {
        case idle
        case preparing(attempt: Attempt)
        case starting(attempt: Attempt)
        case active(attempt: Attempt)
        case finishing(attempt: Attempt)

        var attempt: Attempt? {
            switch self {
            case .idle: return nil
            case .preparing(let attempt), .starting(let attempt),
                 .active(let attempt), .finishing(let attempt):
                return attempt
            }
        }
    }

    enum ToggleDecision: Equatable {
        case begin(attempt: Attempt)
        case cancelPreparation(attempt: Attempt)
        case stop(attempt: Attempt)
        case ignore
    }

    enum FinishDecision: Equatable {
        case none
        case cancelPreparation(attempt: Attempt)
        case stop(attempt: Attempt)
        case alreadyFinishing(attempt: Attempt)
    }

    private(set) var phase: Phase = .idle
    private var latestAttempt: Attempt = 0

    mutating func toggle() -> ToggleDecision {
        switch phase {
        case .idle:
            latestAttempt &+= 1
            if latestAttempt == 0 { latestAttempt = 1 }
            phase = .preparing(attempt: latestAttempt)
            return .begin(attempt: latestAttempt)
        case .preparing(let attempt):
            phase = .idle
            return .cancelPreparation(attempt: attempt)
        case .starting(let attempt), .active(let attempt):
            phase = .finishing(attempt: attempt)
            return .stop(attempt: attempt)
        case .finishing:
            return .ignore
        }
    }

    mutating func requestStop() -> FinishDecision {
        switch phase {
        case .idle:
            return .none
        case .preparing(let attempt):
            phase = .idle
            return .cancelPreparation(attempt: attempt)
        case .starting(let attempt), .active(let attempt):
            phase = .finishing(attempt: attempt)
            return .stop(attempt: attempt)
        case .finishing(let attempt):
            return .alreadyFinishing(attempt: attempt)
        }
    }

    /// Cancel may escalate a Stop already waiting for capture setup, so `.finishing` remains an
    /// actionable result here rather than being ignored like another toggle.
    mutating func requestCancel() -> FinishDecision {
        switch requestStop() {
        case .alreadyFinishing(let attempt): return .stop(attempt: attempt)
        case let decision: return decision
        }
    }

    func isPreparing(attempt: Attempt) -> Bool {
        phase == .preparing(attempt: attempt)
    }

    func isLatestAttempt(_ attempt: Attempt) -> Bool {
        latestAttempt == attempt
    }

    mutating func beginCoordinatorStart(attempt: Attempt) -> SessionGeneration? {
        guard phase == .preparing(attempt: attempt) else { return nil }
        phase = .starting(attempt: attempt)
        return SessionGeneration(rawValue: attempt)
    }

    func mayEnterCoordinator(attempt: Attempt) -> Bool {
        phase == .starting(attempt: attempt)
    }

    @discardableResult
    mutating func coordinatorDidStart(attempt: Attempt) -> Bool {
        guard phase == .starting(attempt: attempt) else { return false }
        phase = .active(attempt: attempt)
        return true
    }

    /// Ends only the matching attempt. A late permission result or start failure from an older
    /// generation cannot clear a newer session.
    @discardableResult
    mutating func finish(attempt: Attempt) -> Phase? {
        guard phase.attempt == attempt else { return nil }
        let previous = phase
        phase = .idle
        return previous
    }

    mutating func finishCurrentSession() {
        phase = .idle
    }
}

/// Single-consumption identity for the asynchronous spoken-command transform that outlives its
/// voice session. A completed `.voiceCommandExecuted` session releases the ordinary dictation
/// lifecycle before the model answers, so that lifecycle cannot by itself reject a late result.
struct VoiceAITransformLifecycle {
    typealias Operation = UInt64

    private var nextOperation: Operation = 0
    private(set) var activeOperation: Operation?

    mutating func begin() -> Operation {
        nextOperation &+= 1
        if nextOperation == 0 { nextOperation = 1 }
        activeOperation = nextOperation
        return nextOperation
    }

    @discardableResult
    mutating func invalidate() -> Operation? {
        let invalidated = activeOperation
        activeOperation = nil
        return invalidated
    }

    mutating func claimCompletion(_ operation: Operation) -> Bool {
        guard activeOperation == operation else { return false }
        activeOperation = nil
        return true
    }

    func isActive(_ operation: Operation) -> Bool {
        activeOperation == operation
    }
}

/// Immutable identity and payload for the asynchronous correction-diff refinement. The terminal
/// callback has already released the active phase by the time this request runs, so freshness is
/// defined by the monotonically increasing attempt rather than by `phase` being non-idle.
struct VoiceCorrectionDiffRequest: Sendable {
    let attempt: VoiceDictationLifecycle.Attempt
    let finalText: String

    var generation: SessionGeneration { SessionGeneration(rawValue: attempt) }

    /// Resolves only this request's generation and rejects it again after the actor hop. The caller
    /// performs one final lock-owned check at the exact HUD mutation boundary, covering a newer
    /// attempt that begins after this method returns.
    func prepare(
        transcriptLookup: @escaping @Sendable (
            SessionGeneration
        ) async -> (raw: String, final: String)?,
        isLatestAttempt: @escaping @Sendable (VoiceDictationLifecycle.Attempt) -> Bool
    ) async -> [TranscriptDiffEngine.Segment]? {
        guard !Task.isCancelled, isLatestAttempt(attempt) else { return nil }
        guard let transcripts = await transcriptLookup(generation) else { return nil }
        guard !Task.isCancelled, isLatestAttempt(attempt) else { return nil }

        let raw = transcripts.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != finalText else { return nil }

        let segments = TranscriptDiffEngine.segments(verbatim: raw, cleaned: finalText)
        guard segments.contains(where: { $0.isCut }) else { return nil }
        return segments
    }
}

/// App-layer glue for voice dictation.
///
/// All session logic lives in `VoiceSessionCoordinator` (engine side): the reducer owns
/// state, `LiveSpeechStream` produces live segments, `VoiceInsertionService` owns what has
/// been typed. This type does only what needs AppKit — resolve the target application,
/// check microphone permission, drive the hotkey, and map session phases onto the HUD.
public final class VoiceDictationController: @unchecked Sendable {
    public static let shared = VoiceDictationController()

    private let lock = UnfairLock()
    private var lastToggleTime: DispatchTime?
    private var lifecycle = VoiceDictationLifecycle()
    private var currentModelName: String = ""
    private var coordinatorStartTask: (attempt: UInt64, task: Task<Void, Never>)?
    private var callbackWiringTask: Task<Void, Never>?
    private var aiTransformLifecycle = VoiceAITransformLifecycle()
    private var aiTransformHandle: (
        operation: VoiceAITransformLifecycle.Operation,
        handle: AITransformDiscardHandle
    )?

    private init() {}

    // MARK: - Launch

    /// Housekeeping for the on-disk session store, run once at launch off the main thread.
    ///
    /// Two jobs. **Prune**: every dictation writes a directory containing its audio, so
    /// without a retention policy the store grows without bound. **Recover**: a session that
    /// produced text but never delivered it (the app was killed, or the target app quit
    /// mid-insert) is the only copy of something the user said — activity history gets only
    /// an opaque reference to the retained session so the text is revealed on explicit review.
    public func performLaunchRecovery() {
        DispatchQueue.global(qos: .utility).async {
            let service = VoiceRecoveryService.shared
            // Activity history can expose at most this many actionable rows. Prune first using the
            // same cap, then surface every retained undelivered session; keeping 50 artifacts but
            // only 25 references made the older half permanently unreachable.
            let removed = service.prune(keepingAtMost: ActivityHistoryStore.maxEvents)
            let pending = service.recoverableUndelivered().map { session in
                RecoveredVoiceActivityMetadata(
                    sessionID: session.id,
                    timestamp: session.snapshot.createdAt,
                    characterCount: VoiceRecoveryService.recoveredText(session).count
                )
            }

            // LocalizationManager owns mutable language state and UI observers expect activity
            // notifications on main. Build the content-free rows there, then persist them in one
            // batch so launch never performs 25 atomic JSON rewrites on the UI thread.
            DispatchQueue.main.async {
                let events = pending.map { metadata in
                    return ActivityHistoryStore.ActivityEvent(
                        timestamp: metadata.timestamp,
                        signal: .voiceRecovery(
                            sessionID: metadata.sessionID,
                            characterCount: metadata.characterCount,
                            recordedAt: metadata.timestamp
                        )
                    )
                }
                let result = ActivityHistoryStore.shared.recordBatch(events)
                let surfaced = result == .persisted ? events.count : 0
                let unsurfaced = events.count - surfaced
                if removed > 0 || surfaced > 0 || unsurfaced > 0 {
                    DevTypeLog.app.info(
                        "[Voice] launch recovery: surfaced=\(surfaced) unsurfaced=\(unsurfaced) pruned=\(removed)"
                    )
                }
            }
        }
    }

    // MARK: - Entry points

    /// Starts dictation, or stops it if a session is already running.
    public func toggleDictation(sourceApp: NSRunningApplication? = nil) {
        let decision: VoiceDictationLifecycle.ToggleDecision = lock.withLock {
            let now = DispatchTime.now()
            if let lastToggleTime,
               now.uptimeNanoseconds - lastToggleTime.uptimeNanoseconds < 150_000_000 {
                return .ignore // 150ms debounce against hotkey chatter
            }
            lastToggleTime = now
            return lifecycle.toggle()
        }

        switch decision {
        case .begin(let attempt):
            discardActiveAITransform()
            let app = sourceApp ?? NSWorkspace.shared.frontmostApplication
            startDictation(
                attempt: attempt,
                app: app,
                engine: VoicePreferences.effectiveEngine,
                liveRecognitionRequested: VoicePreferences.liveDeliveryMode.usesLiveRecognition
            )
        case .cancelPreparation:
            break
        case .stop(let attempt):
            finishCoordinatorSession(attempt: attempt, cancel: false)
        case .ignore:
            break
        }
    }

    /// Ends capture and lets recognition, correction and delivery run.
    public func stopDictation() {
        let decision = lock.withLock { lifecycle.requestStop() }
        switch decision {
        case .stop(let attempt):
            finishCoordinatorSession(attempt: attempt, cancel: false)
        case .none, .cancelPreparation, .alreadyFinishing:
            break
        }
    }

    /// Abandons the session and erases anything progressive typing already inserted.
    public func cancelDictation() {
        let decision = lock.withLock { lifecycle.requestCancel() }
        switch decision {
        case .stop(let attempt):
            finishCoordinatorSession(attempt: attempt, cancel: true)
        case .cancelPreparation, .none:
            discardActiveAITransform()
            Task { @MainActor in VoiceHUDPanel.shared.hide() }
        case .alreadyFinishing:
            break
        }
    }

    // MARK: - Start

    private func startDictation(
        attempt: UInt64,
        app: NSRunningApplication?,
        engine: TranscriptionEngine,
        liveRecognitionRequested: Bool
    ) {
        guard lock.withLock({ lifecycle.isPreparing(attempt: attempt) }) else { return }

        if engine.uploadsRecordedAudio && !VoicePreferences.hasCloudAudioConsent {
            DevTypeLog.permission.notice(
                "[Permission] voice start paused — Gemini cloud audio consent not granted"
            )
            DevTypeAlert.confirm(
                title: LocalizationManager.shared.s("voice.cloudConsent.title"),
                message: LocalizationManager.shared.s("voice.cloudConsent.message"),
                confirmTitle: LocalizationManager.shared.s("voice.cloudConsent.allow"),
                style: .informational,
                onCancel: { [weak self] in
                    guard let self,
                          self.lock.withLock({ self.lifecycle.finish(attempt: attempt) }) != nil else {
                        return
                    }
                    self.recordPreflightTerminal(VoiceTerminalDiagnostic(
                        outcome: .cancelled,
                        code: .cancelled,
                        stage: .recognition,
                        provider: .gemini,
                        locality: .cloud,
                        recoverability: .notApplicable
                    ))
                },
                onConfirm: { [weak self] in
                    guard let self,
                          self.lock.withLock({ self.lifecycle.isPreparing(attempt: attempt) }) else {
                        return
                    }
                    VoicePreferences.hasCloudAudioConsent = true
                    PreferencesWindowController.shared.refreshPermissionState()
                    self.startDictation(
                        attempt: attempt,
                        app: app,
                        engine: engine,
                        liveRecognitionRequested: liveRecognitionRequested
                    )
                }
            )
            return
        }

        // Fail before recording rather than after, so the user is not left speaking into
        // a session that cannot possibly produce a transcript.
        if engine == .gemini {
            switch GeminiAPIKeyStore.readState() {
            case .available(let key) where !key.isEmpty:
                break
            case .unavailable:
                guard lock.withLock({ lifecycle.finish(attempt: attempt) }) != nil else { return }
                recordPreflightTerminal(.preflightFailure(
                    code: .credentialUnavailable,
                    stage: .recognition,
                    provider: .gemini,
                    locality: .cloud
                ))
                showError(
                    LocalizationManager.shared.s("voice.error.keychainUnavailable"),
                    attempt: attempt
                )
                return
            case .available, .missing:
                guard lock.withLock({ lifecycle.finish(attempt: attempt) }) != nil else { return }
                recordPreflightTerminal(.preflightFailure(
                    code: .missingAPIKey,
                    stage: .recognition,
                    provider: .gemini,
                    locality: .cloud
                ))
                showError(
                    LocalizationManager.shared.s("voice.error.geminiKeyMissing"),
                    attempt: attempt
                )
                return
            }
        }

        guard DurableVoiceCapture.checkMicrophonePermission() else {
            Task {
                let granted = await DurableVoiceCapture.requestMicrophonePermission()
                guard self.lock.withLock({ self.lifecycle.isPreparing(attempt: attempt) }) else {
                    return
                }
                if granted {
                    self.startDictation(
                        attempt: attempt,
                        app: app,
                        engine: engine,
                        liveRecognitionRequested: liveRecognitionRequested
                    )
                } else {
                    guard self.lock.withLock({ self.lifecycle.finish(attempt: attempt) }) != nil else {
                        return
                    }
                    self.recordPreflightTerminal(.preflightFailure(
                        code: .microphonePermissionDenied,
                        stage: .audioCapture,
                        provider: .audioCapture,
                        locality: .onDevice
                    ))
                    self.showError(
                        LocalizationManager.shared.s("voice.error.microphoneDenied"),
                        attempt: attempt
                    )
                }
            }
            return
        }

        // Speech recognition is separate from microphone capture. Apple-backed final providers
        // require it; Gemini and Local Whisper need it only for the optional live preview. A
        // denied preview therefore degrades instead of blocking a final provider that can work.
        let speechStatus = SpeechAuthorization.status()
        let permissionDecision = VoicePermissionPolicy.decision(
            engine: engine,
            liveRecognitionRequested: liveRecognitionRequested,
            speechStatus: speechStatus
        )
        let enableLiveRecognition: Bool
        switch permissionDecision {
        case .proceed(let enabled):
            enableLiveRecognition = enabled
            if liveRecognitionRequested && !enabled {
                DevTypeLog.permission.notice(
                    "[Permission] voice proceeding without Apple live recognition engine=\(engine.rawValue, privacy: .public) speech=\(speechStatus.diagnosticLabel, privacy: .public)"
                )
            }
        case .requestAuthorization:
            Task {
                let requestedStatus = await SpeechAuthorization.request()
                guard self.lock.withLock({ self.lifecycle.isPreparing(attempt: attempt) }) else {
                    return
                }
                if requestedStatus == .authorized {
                    self.beginSession(
                        attempt: attempt,
                        app: app,
                        engine: engine,
                        enableLiveRecognition: liveRecognitionRequested
                    )
                } else if !engine.usesAppleSpeechForFinalTranscript {
                    // Some managed systems can remain not-determined after a request. Do not
                    // reprompt in a loop: only the optional Apple preview is unavailable.
                    self.beginSession(
                        attempt: attempt,
                        app: app,
                        engine: engine,
                        enableLiveRecognition: false
                    )
                } else {
                    guard self.lock.withLock({ self.lifecycle.finish(attempt: attempt) }) != nil else {
                        return
                    }
                    self.recordPreflightTerminal(.preflightFailure(
                        code: .speechRecognitionPermissionDenied,
                        stage: .recognition,
                        provider: .appleSpeech,
                        locality: .onDevice
                    ))
                    self.showError(
                        LocalizationManager.shared.s("voice.error.speechRecognitionDenied"),
                        attempt: attempt
                    )
                }
            }
            return
        case .blocked:
            guard lock.withLock({ lifecycle.finish(attempt: attempt) }) != nil else { return }
            recordPreflightTerminal(.preflightFailure(
                code: .speechRecognitionPermissionDenied,
                stage: .recognition,
                provider: .appleSpeech,
                locality: .onDevice
            ))
            showError(
                LocalizationManager.shared.s("voice.error.speechRecognitionDenied"),
                attempt: attempt
            )
            return
        }

        beginSession(
            attempt: attempt,
            app: app,
            engine: engine,
            enableLiveRecognition: enableLiveRecognition
        )
    }

    private func beginSession(
        attempt: UInt64,
        app: NSRunningApplication?,
        engine: TranscriptionEngine,
        enableLiveRecognition: Bool
    ) {
        let localizedModelName = LocalizationManager.shared.s(engine.localizationKey)
        guard let generation = lock.withLock({ () -> SessionGeneration? in
            guard let generation = lifecycle.beginCoordinatorStart(attempt: attempt) else {
                return nil
            }
            currentModelName = localizedModelName
            return generation
        }) else { return }

        let snapshot = VoiceSessionSnapshotFactory.make(
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier ?? 0,
            generation: generation,
            engine: engine
        )

        // Create and publish the task while holding the same lock Stop uses to retrieve it. The
        // task's first gate also takes this lock, so Stop can never observe "starting" with no
        // task and race a no-op stop ahead of the eventual coordinator start.
        lock.withLock {
            guard lifecycle.mayEnterCoordinator(attempt: attempt) else { return }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runCoordinatorStart(
                    attempt: attempt,
                    snapshot: snapshot,
                    enableLiveRecognition: enableLiveRecognition
                )
            }
            coordinatorStartTask = (attempt, task)
        }
    }

    // MARK: - Session callbacks

    /// Runs the start after the callback barrier and rejects a stop/cancelled attempt immediately
    /// before entering the actor. If Stop wins after that gate, it waits for this task before
    /// asking the coordinator to finalize, preserving start-before-stop ordering.
    private func runCoordinatorStart(
        attempt: UInt64,
        snapshot: VoiceSessionSnapshot,
        enableLiveRecognition: Bool
    ) async {
        let wiring = callbackWiringOperation()
        await wiring.value
        guard lock.withLock({ lifecycle.mayEnterCoordinator(attempt: attempt) }) else {
            clearCoordinatorStartTask(attempt: attempt)
            return
        }

        do {
            // Every entry point (hotkey, menu, palette) is a toggle: press to start,
            // press again to stop. `HotkeyManager` has no key-up path, so there is no
            // hold-to-talk gesture to record.
            try await VoiceSessionCoordinator.shared.startSession(
                snapshot: snapshot,
                mode: .handsFree,
                enableLiveRecognition: enableLiveRecognition
            )
            let becameActive = lock.withLock {
                lifecycle.coordinatorDidStart(attempt: attempt)
            }
            if becameActive && VoicePreferences.isSoundFeedbackEnabled {
                await MainActor.run { NSSound.beep() }
            }
        } catch is CancellationError {
            clearCoordinatorStartTask(attempt: attempt)
        } catch is CloudAudioConsentRequiredError {
            let previous = finishAttempt(attempt)
            guard previous != nil, previous != .finishing(attempt: attempt) else { return }
            // The coordinator already persisted/published the typed consent diagnostic.
            showError(
                LocalizationManager.shared.s("voice.cloudConsent.message"),
                attempt: attempt
            )
        } catch let failure as VoiceFailure {
            let previous = finishAttempt(attempt)
            guard previous != nil, previous != .finishing(attempt: attempt) else { return }
            // `VoiceSessionCoordinator` already persisted and published this exact diagnostic
            // before throwing. Keep the HUD actionable without duplicating it.
            showError(Self.message(for: failure), attempt: attempt)
        } catch {
            let previous = finishAttempt(attempt)
            guard previous != nil, previous != .finishing(attempt: attempt) else { return }
            let failure = VoiceFailure(stage: .audioCapture, code: .noMicrophone)
            recordPreflightTerminal(VoiceTerminalDiagnostic(failure: failure, snapshot: snapshot))
            showError(Self.message(for: failure), attempt: attempt)
        }
    }

    private func finishCoordinatorSession(attempt: UInt64, cancel: Bool) {
        let pendingStart = lock.withLock {
            coordinatorStartTask?.attempt == attempt ? coordinatorStartTask?.task : nil
        }
        if cancel {
            pendingStart?.cancel()
        }
        Task {
            if cancel {
                let accepted = await VoiceSessionCoordinator.shared.cancelSession()
                if !accepted {
                    _ = self.finishAttempt(attempt)
                    await MainActor.run { VoiceHUDPanel.shared.hide() }
                }
            } else {
                await pendingStart?.value
                let accepted = await VoiceSessionCoordinator.shared.stopSession()
                // A pre-coordinator cancellation has no terminal phase callback to release the
                // finishing state. A real Stop stays single-flight until its terminal phase.
                if !accepted { _ = self.finishAttempt(attempt) }
            }
        }
    }

    @discardableResult
    private func finishAttempt(_ attempt: UInt64) -> VoiceDictationLifecycle.Phase? {
        lock.withLock {
            let previous = lifecycle.finish(attempt: attempt)
            if coordinatorStartTask?.attempt == attempt {
                coordinatorStartTask = nil
            }
            return previous
        }
    }

    private func clearCoordinatorStartTask(attempt: UInt64) {
        lock.withLock {
            if coordinatorStartTask?.attempt == attempt {
                coordinatorStartTask = nil
            }
        }
    }

    /// Installs the phase, terminal, segment and audio-level handlers exactly once. Retaining the
    /// installation task makes concurrent callers await the whole sequence instead of treating a
    /// Boolean set before the first actor hop as proof that every callback is ready.
    private func callbackWiringOperation() -> Task<Void, Never> {
        lock.withLock {
            if let callbackWiringTask { return callbackWiringTask }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.installCallbacks()
            }
            callbackWiringTask = task
            return task
        }
    }

    private func installCallbacks() async {
        await VoiceSessionCoordinator.shared.setOnPhaseChangeWithGeneration {
            [weak self] phase, generation in
            self?.handlePhase(phase, attempt: generation.rawValue)
        }
        await VoiceSessionCoordinator.shared.setOnTerminalDiagnostic { diagnostic in
            ActivityHistoryStore.publish(.voiceTerminal(diagnostic))
        }
        await VoiceSessionCoordinator.shared.setOnAudioLevel { level in
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateAudioLevel(level)
            }
        }
        await VoiceSessionCoordinator.shared.setOnDeliveryIntercept { transcript in
            await VoiceDictationController.shared.interceptVoiceCommand(transcript)
        }
        await VoiceSessionCoordinator.shared.setOnLiveSegment { segment in
            // What the recognizer heard, not what was typed. In `previewInHUD` nothing is
            // typed at all, and a HUD reading the typed text would stay blank all session.
            DispatchQueue.main.async {
                let transcript = VoiceInsertionService.shared.recognizedText
                if !transcript.isEmpty {
                    VoiceHUDPanel.shared.updateStreamingTranscript(transcript)
                }
                _ = segment
            }
        }
    }

    private func handlePhase(_ phase: SessionPhase, attempt: UInt64) {
        let modelName: String? = lock.withLock {
            guard lifecycle.phase.attempt == attempt else { return nil }
            switch phase {
            case .completed, .failed, .cancelled, .recoverable:
                _ = lifecycle.finish(attempt: attempt)
                if coordinatorStartTask?.attempt == attempt {
                    coordinatorStartTask = nil
                }
            default:
                break
            }
            return currentModelName
        }
        guard let modelName else { return }

        DispatchQueue.main.async {
            guard self.lock.withLock({ self.lifecycle.isLatestAttempt(attempt) }) else { return }
            switch phase {
            case .preparing, .capturing:
                VoiceHUDPanel.shared.updateState(.listening(modelName: modelName))

            case .finalizingAudio, .recognizing, .validatingRaw, .correcting, .validatingCorrection:
                VoiceHUDPanel.shared.updateState(.transcribing(modelName: modelName))

            case .readyForDelivery, .delivering:
                break

            case .completed(let outcome):
                switch outcome {
                case .inserted:
                    let text = VoiceInsertionService.shared.ownedText
                    if text.isEmpty {
                        VoiceHUDPanel.shared.updateState(
                            .error(message: LocalizationManager.shared.s("voice.error.noSpeech"))
                        )
                    } else {
                        VoiceHUDPanel.shared.updateState(.success(text: text))
                        self.showCorrectionDiff(for: text, attempt: attempt)
                    }
                case .savedButNotInserted:
                    VoiceHUDPanel.shared.updateState(
                        .error(message: LocalizationManager.shared.s("voice.error.targetChanged"))
                    )
                case .copiedToClipboard(let count):
                    VoiceHUDPanel.shared.updateState(.success(
                        text: LocalizationManager.shared.s("voice.result.copiedCharacters", count)
                    ))
                case .voiceCommandExecuted:
                    // The intercept owns its in-progress/result HUD. Replacing it with the raw
                    // spoken command briefly exposed user content and hid the AI progress state.
                    break
                }

            case .failed(let failure):
                VoiceHUDPanel.shared.updateState(.error(message: Self.message(for: failure)))

            case .cancelled:
                VoiceHUDPanel.shared.hide()

            case .recoverable:
                break
            }
        }
    }

    /// Shows which words cleanup removed, so a bad correction is visible rather than
    /// silent. Fetched after the success state is already on screen: the diff is a
    /// refinement, and waiting on the actor for it would delay the result the user cares
    /// about.
    private func showCorrectionDiff(for finalText: String, attempt: UInt64) {
        let request = VoiceCorrectionDiffRequest(attempt: attempt, finalText: finalText)
        Task { [weak self] in
            guard let self,
                  let segments = await request.prepare(
                    transcriptLookup: { generation in
                        await VoiceSessionCoordinator.shared.transcripts(for: generation)
                    },
                    isLatestAttempt: { [weak self] candidate in
                        guard let self else { return false }
                        return self.lock.withLock {
                            self.lifecycle.isLatestAttempt(candidate)
                        }
                    }
                  ) else { return }
            await MainActor.run {
                // Keep the final freshness check and HUD write under the same lock. Toggle handling
                // may arrive off-main, so checking and then releasing the lock before the write
                // would leave one last interleaving window for a newer attempt.
                self.lock.withLock {
                    guard self.lifecycle.isLatestAttempt(request.attempt) else { return }
                    VoiceHUDPanel.shared.updateState(
                        .success(text: request.finalText, diffSegments: segments)
                    )
                }
            }
        }
    }

    // MARK: - Spoken AI commands

    /// Claims the transcript when it opens with an AI trigger phrase ("rewrite this",
    /// "summarise this", …). Returns `true` when the command was handled, so the session
    /// completes without typing the transcript verbatim.
    fileprivate func interceptVoiceCommand(_ transcript: String) async -> Bool {
        guard let command = VoiceAITriggerParser.parse(transcript: transcript) else {
            return false
        }

        return await MainActor.run {
            // Whatever progressive typing put on screen was the spoken command, not content
            // the user wants kept — except when the command acts on it, which is captured
            // before the rollback.
            //
            // Two different values, which coincided only while typing as you speak. What the
            // command operates on is what the session *recognized*; what a failed transform
            // must put back is only what rollback actually *removed from the document*. In
            // the modes that do not type while speaking the second is empty, and restoring
            // the first would insert text the user never had on screen.
            let spokenText = VoiceInsertionService.shared.recognizedText
            let erasedFromDocument = VoiceInsertionService.shared.ownedText
            VoiceInsertionService.shared.rollback()

            guard AITextTransformSupport.isRunningOnCompatibleOS else {
                VoiceHUDPanel.shared.updateState(
                    .error(message: LocalizationManager.shared.s("ai.availability.unsupportedOS"))
                )
                return true
            }

            let input: String
            switch command.target {
            case .spoken(let text):
                input = text

            case .lastInsertion:
                // "proofread final insertion" — the text this session just typed. It is not
                // selected, and asking the user to select it first would defeat the point of
                // asking by voice.
                input = spokenText

            case .selection:
                switch SelectionReader.readSelectionForExplicitAIAction() {
                case .selection(let resolved):
                    input = resolved.text
                case .failure(let failure):
                    VoiceHUDPanel.shared.updateState(.error(message: failure.message(loc: .shared)))
                    return true
                }
            }

            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                VoiceHUDPanel.shared.updateState(
                    .error(message: self.emptyTargetMessage(for: command))
                )
                return true
            }

            // For `.lastInsertion` the user's dictated text has already been rolled back
            // off screen, so a failed transform would destroy it. Hand it over as the thing
            // to put back — an AI that declines must cost the user nothing.
            self.runAITransform(
                command,
                input: input,
                restoringOnFailure: command.target == .lastInsertion && !erasedFromDocument.isEmpty
                    ? erasedFromDocument
                    : nil
            )
            return true
        }
    }

    /// Names what was missing, so "nothing happened" is never the whole story.
    private func emptyTargetMessage(for command: VoiceAICommand) -> String {
        let action = LocalizationManager.shared.s(command.kind.localizationKey)
        switch command.target {
        case .lastInsertion:
            return LocalizationManager.shared.s("voice.ai.empty.lastInsertion", action)
        case .selection:
            return LocalizationManager.shared.s("voice.ai.empty.selection", action)
        case .spoken:
            return LocalizationManager.shared.s("voice.ai.empty.spoken", action)
        }
    }

    @MainActor
    private func runAITransform(
        _ command: VoiceAICommand,
        input: String,
        restoringOnFailure fallback: String? = nil
    ) {
        let action = LocalizationManager.shared.s(command.kind.localizationKey)
        VoiceHUDPanel.shared.updateState(.transcribing(
            modelName: LocalizationManager.shared.s("voice.ai.working", action)
        ))

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let operation = beginAITransform()
            let handle = AITextTransformer.shared.transform(
                kind: command.kind,
                input: input,
                completionQueue: .main
            ) { result in
                DispatchQueue.main.async {
                    guard self.claimAITransformCompletion(operation) else { return }
                    switch result {
                    case .success(let output) where !output.isEmpty:
                        VoiceHUDPanel.shared.updateState(.success(text: output))
                        let snippet = SnippetModel(
                            title: "Voice AI",
                            triggerKeyword: "",
                            replacementText: output
                        )
                        TextInjectionPipeline.shared.inject(
                            snippet: snippet,
                            triggerLength: 0,
                            swallowedFinalKey: false,
                            eraseCountOverride: 0,
                            preResolvedText: output,
                            secureClipboardPaste: false
                        )
                    case .success:
                        VoiceHUDPanel.shared.updateState(.error(
                            message: LocalizationManager.shared.s("voice.ai.emptyOutput")
                        ))
                        self.restore(fallback)
                    case .failure:
                        VoiceHUDPanel.shared.updateState(
                            .error(message: LocalizationManager.shared.s("voice.ai.failed"))
                        )
                        self.restore(fallback)
                    }
                }
            }
            retainAITransformHandle(handle, operation: operation)
            return
        }
        #endif

        VoiceHUDPanel.shared.updateState(
            .error(message: LocalizationManager.shared.s("ai.availability.unsupportedOS"))
        )
        restore(fallback)
    }

    /// Starts a new spoken-command transform and invalidates any older result before its provider
    /// can reach the HUD or injection pipeline. Discard fires a `.discarded` completion, but that
    /// completion carries the old operation identity and therefore fails the claim below.
    private func beginAITransform() -> VoiceAITransformLifecycle.Operation {
        let state = lock.withLock { () -> (
            operation: VoiceAITransformLifecycle.Operation,
            previous: AITransformDiscardHandle?
        ) in
            let previous = aiTransformHandle?.handle
            aiTransformHandle = nil
            _ = aiTransformLifecycle.invalidate()
            return (aiTransformLifecycle.begin(), previous)
        }
        state.previous?.discard()
        return state.operation
    }

    private func retainAITransformHandle(
        _ handle: AITransformDiscardHandle,
        operation: VoiceAITransformLifecycle.Operation
    ) {
        let retained = lock.withLock { () -> Bool in
            guard aiTransformLifecycle.isActive(operation) else { return false }
            aiTransformHandle = (operation, handle)
            return true
        }
        if !retained { handle.discard() }
    }

    private func claimAITransformCompletion(
        _ operation: VoiceAITransformLifecycle.Operation
    ) -> Bool {
        lock.withLock {
            guard aiTransformLifecycle.claimCompletion(operation) else { return false }
            if aiTransformHandle?.operation == operation {
                aiTransformHandle = nil
            }
            return true
        }
    }

    private func discardActiveAITransform() {
        let handle = lock.withLock { () -> AITransformDiscardHandle? in
            _ = aiTransformLifecycle.invalidate()
            let handle = aiTransformHandle?.handle
            aiTransformHandle = nil
            return handle
        }
        handle?.discard()
    }

    /// Puts back text that was rolled back for a transform that then failed.
    @MainActor
    private func restore(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        let snippet = SnippetModel(title: "Voice AI", triggerKeyword: "", replacementText: text)
        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: 0,
            swallowedFinalKey: false,
            eraseCountOverride: 0,
            preResolvedText: text,
            secureClipboardPaste: false
        )
    }

    // MARK: - Messaging

    private func recordPreflightTerminal(_ diagnostic: VoiceTerminalDiagnostic) {
        _ = VoiceDiagnosticsRecorder.shared.recordTerminal(diagnostic)
        ActivityHistoryStore.publish(.voiceTerminal(diagnostic))
    }

    private func showError(_ message: String, attempt: UInt64) {
        DispatchQueue.main.async {
            guard self.lock.withLock({ self.lifecycle.isLatestAttempt(attempt) }) else { return }
            VoiceHUDPanel.shared.updateState(.error(message: message))
        }
    }

    /// Maps a structured failure to something the user can act on. The failure already
    /// carries a `userAction`, so the message names the fix rather than the fault.
    static func message(
        for failure: VoiceFailure,
        localization: LocalizationManager = .shared
    ) -> String {
        switch failure.code {
        case .noMicrophone: return localization.s("voice.error.noMicrophone")
        case .microphonePermissionDenied: return localization.s("voice.error.microphoneDenied")
        case .accessibilityPermissionDenied: return localization.s("voice.error.accessibilityDenied")
        case .zeroFramesCaptured, .speechNoSpeech: return localization.s("voice.error.noSpeech")
        case .captureBackpressure, .deviceChangeInterrupted:
            return localization.s("voice.error.audioInterrupted")
        case .diskFull: return localization.s("voice.error.diskFull")
        case .audioEncodingFailed: return localization.s("voice.error.audioEncoding")
        case .missingAPIKey: return localization.s("voice.error.geminiKeyMissing")
        case .credentialUnavailable: return localization.s("voice.error.keychainUnavailable")
        case .cloudAudioConsentRequired: return localization.s("voice.cloudConsent.message")
        case .speechRecognitionPermissionDenied:
            return localization.s("voice.error.speechRecognitionDenied")
        case .authFailed: return localization.s("voice.error.invalidAPIKey")
        case .endpointUnreachable: return localization.s("voice.error.endpointUnreachable")
        case .noReadyProvider: return localization.s("voice.error.noReadyProvider")
        case .modelNotFound, .modelLoadFailed: return localization.s("voice.error.modelUnavailable")
        case .modelDigestMismatch: return localization.s("voice.error.modelIntegrity")
        case .rateLimited: return localization.s("voice.error.rateLimited")
        case .quotaExhausted: return localization.s("voice.error.quotaExhausted")
        case .requestTimeout, .correctionTimeout: return localization.s("voice.error.timeout")
        case .speechCoverageGap, .speechRepeatedLoop, .speechProtocolViolation:
            return localization.s("voice.error.transcriptValidation")
        case .correctionRefusal, .correctionHallucination,
             .correctionProtectedSpanAltered, .correctionUnsupportedEdit:
            return localization.s("voice.error.correctionRejected")
        case .targetLeaseExpired, .targetAppTerminated:
            return localization.s("voice.error.targetChanged")
        case .secureInputActive: return localization.s("voice.error.secureInput")
        case .manifestWriteFailed: return localization.s("voice.error.sessionSave")
        case .staleGeneration: return localization.s("voice.error.superseded")
        }
    }
}
