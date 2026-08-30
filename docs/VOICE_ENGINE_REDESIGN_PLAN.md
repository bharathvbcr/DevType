# DevType Speech Engine and Correction System Redesign

> **Historical record — superseded by the shipping implementation.**
>
> This document is the audit and plan that led to the current voice pipeline. It is kept
> because it is the only record of *why* the Voxtral and Fun-ASR engine selections were
> removed: they never executed those models, both delegating to Apple Speech behind a
> file-size readiness check (see §2, "Verified current-state baseline").
>
> The engine work described here has landed. DevType now ships four engines — Apple Speech,
> Local AI (on-device), Local Whisper (whisper.cpp), and opt-in cloud Gemini — with a
> per-session immutable snapshot, enforced privacy routes, durable CAF capture, and
> recognition separated from correction. Every "current state" description below refers to
> the pre-redesign baseline `4e3e488`, **not** to the code as it stands; individual line
> references and file paths in it are stale.
>
> For how dictation actually behaves today, read [VOICE_DICTATION.md](VOICE_DICTATION.md)
> and the Smart Dictation section of [ARCHITECTURE.md](ARCHITECTURE.md). Do not use this
> plan as a description of current behavior.

Status: second-pass audited implementation plan (historical)

Prepared: 2026-08-28

DevType baseline: `4e3e48897a8ce9fc2ccf2c2de3534de2250fea4e` (`main`)

Reference baseline: [`google-gemini/jot-gemini-transcribe-macOS`](https://github.com/google-gemini/jot-gemini-transcribe-macOS) at `8f2d7a44d533dedc432351caa41227e65b0a4cec`

## 1. Outcome

Redesign voice dictation as a local-first, provider-neutral pipeline with these properties:

- Audio is durably captured from the first frame and remains recoverable after a crash.
- Speech recognition and transcript correction are separate capabilities. A provider may implement either or both, but the product never assumes that it does.
- Local ASR is preferred, Apple on-device recognition is a supported fallback, and Gemini is an explicit opt-in cloud adapter.
- Local correction can use Apple Foundation Models, Ollama, llama.cpp server, or another capability-compatible runtime; deterministic rules remain the no-model fallback.
- Partial transcripts are display-only by default. Only a finalized, validated transcript is persisted and inserted.
- Every session records the actual provider, model, timing, fallback, validation, and insertion outcome.
- Existing DevType permission, secure-input, delivery verification, and text-injection behavior remains under its current canonical owner.

The redesign is intentionally not “replace Gemini with one local model.” It creates stable contracts around audio, ASR, correction, validation, persistence, and delivery so local runtimes can evolve without rewriting the coordinator.

## 2. Verified current-state baseline

### Audit evidence status

- **Verified:** source call sites and packaging scripts in DevType commit `4e3e488`; source/tests in Jot commit `8f2d7a4`; DevType's prescribed `./Scripts/test.sh` passed 1,342 tests with 7 skips and no failures; Jot's `./scripts/test.sh` passed 206 tests with 8 skips and no failures.
- **Verified:** both configured Hugging Face GGUF download URLs returned HTTP 401 `Authentication required` on 2026-08-28. The current downloader supplies no Hub credential and its ready/install path does not enforce the descriptor digest.
- **Inferred design decision:** an external-server-first route followed by a supervised helper is the lowest-risk path given the current single-executable SwiftPM packaging, crash-isolation requirement, and prohibition on adding dependencies without approval. This remains subject to benchmark and packaging evidence.
- **Unverified release gates:** live microphone/device-change behavior, real target-app insertion, secure-input behavior, current-provider credential flows, model quality, strict no-egress capture, helper signing/notarization, and power-loss durability. No passing unit suite is presented as proof of those behaviors.

### DevType today

The current flow is concentrated in `VoiceDictationCoordinator` and directly constructs the recorder, transcriber, and Gemini client. The selected engine branches among Gemini, local LLM, and Apple Speech, but those labels do not represent equivalent speech engines:

- Gemini performs cloud audio transcription.
- “Local LLM” first obtains text from Apple Speech and then cleans it with Apple Foundation Models, a local HTTP endpoint, or deterministic rules.
- The Voxtral and Fun-ASR paths currently resolve a model file and then call Apple Speech; no GGUF speech inference runtime is wired.
- Streaming Apple Speech runs during capture for all engine choices and can inject partial text into the target application.
- Audio capture uses a raw PCM journal, but stopping removes the tap immediately, reads the recording into memory, wraps it as WAV, and deletes the journal. Recovery discovery exists but is not wired into a durable session workflow.
- Model “ready” state is primarily a file-size check. It does not prove digest validity, runtime loadability, or successful inference.
- The state machine silently ignores invalid transitions, and the coordinator does not preserve a complete immutable session configuration or timing record.
- Local HTTP correction mixes OpenAI-compatible and Ollama response shapes behind one endpoint assumption.
- DevType already has a stronger canonical insertion owner in `TextInjectionPipeline`: permission checks, secure-field and IME guards, serialization, bounded delivery, pasteboard handling, and verification. That path should be adapted, not duplicated.

Evidence anchors in the inspected baseline:

- Engine routing is a direct coordinator switch at `Sources/DevTypeApp/VoiceDictationCoordinator.swift:190`.
- Voxtral and Fun-ASR delegate to Apple Speech at `Sources/ExpanderEngine/Voice/VoiceTranscriber.swift:117` and `Sources/ExpanderEngine/Voice/VoiceTranscriber.swift:134`.
- Model readiness is a greater-than-10-MB file check at `Sources/ExpanderEngine/Voice/VoiceModelManager.swift:84`.
- Recorder stop removes the tap, loads the journal with `Data(contentsOf:)`, writes WAV, and removes the journal at `Sources/ExpanderEngine/Voice/VoiceAudioRecorder.swift:203`.
- Invalid state transitions return the unchanged state at `Sources/ExpanderEngine/Voice/DictationStateMachine.swift:53`.
- The local correction transport builds one chat payload and decodes both OpenAI-style `choices` and Ollama’s older direct `response` shape at `Sources/ExpanderEngine/Voice/LocalLLMCleanupClient.swift:107`.
- The existing delivery pipeline declares `PasteboardBroker`, `AXTextWriter`, `DeliveryVerifier`, and `EraseExecutor` as its collaborators at `Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift:56`.
- Empty transcript and voice-command early returns occur after the state has entered insertion at `Sources/DevTypeApp/VoiceDictationCoordinator.swift:394-409`; the normal branch reports `.inserted` before delivery completion at `Sources/DevTypeApp/VoiceDictationCoordinator.swift:428-435`.
- Cancellation clears capture/session references but does not invalidate outstanding recognition or correction work at `Sources/DevTypeApp/VoiceDictationCoordinator.swift:504-524`; final delivery also reactivates the captured app at `Sources/DevTypeApp/VoiceDictationCoordinator.swift:580-600`.
- The canonical injection completion is deliberately invoked after either normal settlement or the watchdog, so it is not a success receipt: `Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift:389-443`.
- Current local cleanup unconditionally tries Foundation Models before HTTP at `Sources/ExpanderEngine/Voice/LocalLLMCleanupClient.swift:41-53`, derives output allowance from character count at line 133, and decodes `choices` or a top-level `response` at lines 153-166 rather than native Ollama chat's `message.content`.
- The audio tap converts, allocates, locks, and writes at `Sources/ExpanderEngine/Voice/VoiceAudioRecorder.swift:145-183`; stop removes the tap, loads the entire journal, and deletes it at lines 203-244, while launch cleanup deletes all active journals at lines 71-75.
- Model descriptors contain empty-input and one-byte-known SHA-256 values at `Sources/ExpanderEngine/Voice/VoiceModelType.swift:17-48`; readiness is only size-based at `Sources/ExpanderEngine/Voice/VoiceModelManager.swift:84-105`, and direct install announces ready without digest verification at lines 196-207.
- Live target mutation defaults on at `Sources/ExpanderEngine/Voice/VoicePreferences.swift:94-103`; the arbitrary endpoint is stored in `UserDefaults` with no adapter or authority policy at lines 214-225.

### Structural lessons from Jot

Jot’s useful contribution is its system shape, not its dependence on Gemini:

- A headless `JotCore` package separates hotkeys, audio, transcription, formatting, insertion, history, settings, and session coordination from the app shell.
- A pure state machine makes warming, recording, finalizing, transcribing, inserting, cancellation, and terminal failures explicit.
- Live transcription is a distinct optional capability from batch transcription. Partials are display-only, and final acceptance reconciles streamed bytes with captured frames.
- Audio is written to a crash-safe session artifact from the first frame, with asynchronous finalization and tail draining.
- Session UUID guards prevent stale asynchronous completions from affecting a newer session.
- The raw transcript is persisted before insertion. Recovery and retry never auto-insert into an unknown or changed target.
- Insertion returns typed outcomes and rechecks target safety throughout delivery.
- Correction is bounded by a deadline and semantic validation; repeated validation failures automatically degrade to safer behavior.

Jot-to-DevType structural mapping:

| JotCore area | Functional role | DevType treatment |
|---|---|---|
| `HotkeyEngine` | Produces press/release/lock/cancel intent without owning transcription. | Keep DevType's hotkey owner; send typed intents to the session actor. Do not fork another event tap. |
| `AudioEngine` (`AudioCaptureEngine`, `CAFWriter`) | Capture, conversion, levels, device events, durable audio. | Adapt the durable CAF/tail concepts, but replace callback-buffer handoff and unbounded backlog with owned bounded buffers. |
| `SessionCoordinator` | Orchestrates state, batch/live paths, cancellation, and target/session identity. | Split global orchestration into a session registry plus per-session reducer and task bag. |
| `TranscriptionClient` | Gemini transport, FLAC encoding, live protocol, timeout policy. | Generalize into provider adapters; keep conversion provider-neutral; Gemini becomes one opt-in implementation. |
| `FormattingPipeline` | Prompt, replacement, diff, validation. | Fold into one provider-neutral correction pipeline with stronger protected-span validation and deterministic fallback. |
| `HistoryStore` | Session metadata, recovery scan, retry, retention. | Use atomic per-session directories first; persistence failures are typed and never swallowed. |
| `InsertionEngine` | AX/paste delivery and target rechecks. | Do not port it. Extend DevType's existing `TextInjectionPipeline` to return a target-aware receipt. |
| `Settings` / `Support` | Policy, dictionary, migrations, Keychain, layout, reachability. | Snapshot immutable per-session policy; credentials stay Keychain-backed; route and schema migrations are explicit. |

Jot’s current tests pass, but its Swift 6 concurrency warnings around `UserDefaults` sendability and locking from async contexts are reasons to adapt its design rather than copy its implementation.

Reference implementation anchors:

- [service contracts](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/SessionCoordinator/Services.swift)
- [pure dictation state machine](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/SessionCoordinator/DictationStateMachine.swift)
- [session coordinator](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/SessionCoordinator/DictationCoordinator.swift)
- [live/batch separation and byte reconciliation](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/SessionCoordinator/LiveTranscribing.swift)
- [crash-safe audio capture](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/AudioEngine/AudioCaptureEngine.swift)
- [recovery scanner](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/HistoryStore/RecoveryScanner.swift) and [retry queue](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/8f2d7a44d533dedc432351caa41227e65b0a4cec/JotCore/Sources/HistoryStore/RetryQueue.swift)

### Second-pass adversarial findings

The deeper audit changes the implementation order. Several current behaviors are release-blocking correctness defects, not merely architectural debt:

| Priority | Verified finding | Required disposition |
|---|---|---|
| P0 | Cancellation stops capture/streaming but does not cancel or invalidate every in-flight recognition/correction task. A late completion can still reach insertion. | Add session-ID guards and structured task cancellation before changing providers. Prove `cancel -> late result -> no persist/no insert` with a pre-fix failing test. |
| P0 | An empty final transcript can leave the coordinator in `inserting`; the voice-command branch can also exit without a terminal state or clearing the active session. | Make every branch emit exactly one terminal event and release session ownership. Add empty-result and command-success/failure regression tests. |
| P0 | Voice marks `.inserted` immediately after scheduling `TextInjectionPipeline`; that pipeline's completion is a liveness callback, not a verified delivery result. | Extend the canonical pipeline with a typed asynchronous delivery receipt. Do not infer success from callback execution or a posted paste event. |
| P0 | Voxtral/Fun-ASR selections do not execute those models; both delegate to Apple Speech. Their stored hashes are placeholder-like, readiness is file-size based, downloads are not verified in the install path, and the configured Hugging Face URLs returned HTTP 401 during this audit. | Immediately hide/disable download and ready claims while preserving user files. Reintroduce only through an authenticated artifact manifest, digest verification, runtime load, and inference probe. |
| P0 | Local correction always tries Apple Foundation Models first on supported systems, even when an endpoint/model was selected. The default URL resembles OpenAI compatibility while the decoder does not handle native Ollama `message.content`. | Make provider choice explicit and split Apple, Ollama native, and OpenAI-compatible adapters. No hidden priority or multi-protocol probing. |
| P0 | The audio tap performs conversion, allocation, RMS work, locking, and file writes from the real-time callback. Stop removes the tap without a proven tail drain; cleanup deletes journals that a recovery API purports to recover. | Introduce a bounded preallocated handoff, durable CAF writer, tail barrier, gap accounting, and recovery ownership before deleting the old journal path. |
| P1 | The state reducer silently accepts invalid transitions as no-ops, while tests encode that behavior and even accept an empty success payload. | Characterize first, then replace silent no-ops with typed transition errors and explicit diagnostics. Do not weaken the existing tests; supersede them with intentional state contracts. |
| P1 | Session vocabulary/tone/timestamps are not fully snapshotted or updated. Duration can fall back to a fabricated value, so provenance is not trustworthy. | Persist an immutable start policy plus monotonic stage timestamps; never synthesize measured duration without marking it estimated. |
| P1 | Current Gemini transport uses a provider-specific SSE path, tolerates malformed lines, does not require a terminal event, conflates status codes, and labels the same returned text as both raw and cleaned. | Move Gemini behind the current documented Interactions API contract, require a terminal response, type errors correctly, and represent only outputs the provider actually returns. |
| P1 | Endpoint settings accept arbitrary URLs and discovery probes multiple protocol families. `localhost` is treated as equivalent to a cryptographically trusted local process. | Validate a selected adapter and normalized authority first. Default to numeric loopback; require an explicit LAN/remote profile, HTTPS, redirect policy, and optional Keychain credential for anything broader. |
| P1 | Correction validation uses coarse set/length heuristics that can miss multiplicity, order, protected-token changes, or locale-specific drift. | Replace it with typed protected spans, token/grapheme alignment, edit budgets, locale modules, and shadow-calibrated thresholds. Structured JSON proves syntax, not semantic safety. |
| P1 | Recovery policy is not bound to the original egress decision. A recovered local-only session must not be sent to cloud merely because current preferences changed. | Persist the privacy/provider snapshot and resume only within it; require a new explicit user decision to broaden the route. |
| P2 | Current audio/model/correction tests are mostly shape and no-crash checks. The so-called recorder stress loop is serial and catches failures rather than asserting concurrency invariants. | Add deterministic transports, fault injection, real concurrent pressure, and physical-device gates. Do not describe the current suite as coverage of crash recovery, delivery, or model execution. |

These findings were derived from current source and call sites, not README claims. The existing 1,342-test DevType suite passed on the audited commit, which means these are largely specification and coverage gaps rather than currently failing assertions. Jot's 206-test suite also passed, but it has no dedicated physical insertion proof and emits Swift concurrency warnings; its passing suite is not evidence that its patterns can be copied unchanged.

### What to adapt from Jot—and what not to copy

Adopt the service boundaries, durable-session concept, batch/live separation, stale-session guard, display-only partials, typed terminal outcomes, and recovery-without-auto-insert policy. Independently re-derive these details:

- Jot's coordinator still serializes work around one global active state; DevType needs a session registry if capture N+1 may overlap processing N.
- Jot's metadata writer can suppress persistence errors. DevType must fail loudly: an unpersisted transcript is a distinct unsafe state and cannot be reported as durably complete.
- Jot can enqueue a callback-owned `AVAudioPCMBuffer` to another queue and its writer backlog is not intrinsically bounded. DevType must copy into owned preallocated storage or prove buffer lifetime, and must make overload observable.
- Jot's streamed-byte equality is format-specific and proves local enqueue coverage, not necessarily server decode/commit. DevType needs format-aware frame/sequence accounting and provider acknowledgement where available.
- Jot's paste tier can report success after posting Command-V. DevType must keep its stronger delivery machinery and add a real receipt rather than copying this semantic.
- Jot's automatic recovery transcription is not sufficient for DevType's route policy. Recovery inherits the captured session's egress permissions.
- Jot's placeholder/stub services and third-party packages are reference scaffolding, not approved DevType dependencies.

## 3. Design principles and invariants

1. **Audio is the durable source of truth.** Once capture begins, the session owns a recoverable audio artifact until retention policy permits deletion.
2. **Raw ASR is never overwritten.** Correction produces a separate candidate and provenance record.
3. **Unvalidated model output is never inserted.** Timeout, malformed output, refusal, content expansion, or semantic drift falls back to the raw transcript plus deterministic normalization.
4. **A skipped or unavailable check cannot report “passed.”** Readiness and validation use typed results: passed, failed, unavailable, timed out, or not applicable.
5. **Partials do not become document state by default.** The HUD may show them; insertion waits for a final transcript.
6. **Target identity is a lease, not a guess.** Capture the intended process and accessibility context, revalidate before delivery, and never recover by inserting into whatever is frontmost later.
7. **Local means local by construction.** Loopback endpoints are the default. Cloud transmission requires a named route and explicit user opt-in.
8. **Capabilities drive UI and routing.** A model name or downloaded file is not proof that a provider can transcribe, stream, correct, or use structured output.
9. **One canonical owner per behavior.** Provider adapters do transport; the pipeline owns routing; the validator owns acceptance; `TextInjectionPipeline` owns delivery.
10. **All work is bounded.** Audio length, request bytes, output bytes, retries, concurrent inference, correction duration, and model residency have explicit limits.

## 4. Target architecture

```text
Hotkey / menu / command intent
             |
             v
      VoiceSessionCoordinator  <---- immutable VoiceSessionPolicy snapshot
      (session registry + activeCaptureID, not one global job state)
             |
       +-----+---------------------------------------------------+
       |                                                         |
       v                                                         v
DurableAudioCapture                                      TargetLease
(CAF from frame 0, metadata,                         (PID + AX identity +
 tail drain, device events)                           security state)
       |
       +--> optional StreamingSpeechRecognizer --> HUD partials only
       |
       v
      SpeechRecognizer selected by ProviderRegistry + RoutingPolicy
       |
       v
 RawTranscript ----------> deterministic normalization
       |                              |
       |                              v
       +---------------------> TranscriptCorrector (optional/local-first)
                                      |
                                      v
                              CorrectionValidator
                              /                 \
                     accepted candidate      safe fallback
                              \                 /
                               v               v
                         deterministic dictionary
                                      |
                                      v
                         persist finalized transcript
                                      |
                                      v
                    VoiceInsertionService typed adapter
                                      |
                                      v
                 extended canonical TextInjectionPipeline
                    (TargetLease + InjectionReceipt)
```

### Proposed package/module boundaries

Retain the existing Swift package and introduce boundaries within `ExpanderEngine` before considering a new package target:

```text
Sources/ExpanderEngine/Voice/
  Session/
    VoiceSessionCoordinator.swift
    VoiceSessionStateMachine.swift
    VoiceSessionModels.swift
    VoiceSessionPolicy.swift
  Audio/
    DurableAudioCapture.swift
    AudioCaptureModels.swift
    AudioRecoveryScanner.swift
  Recognition/
    SpeechRecognizer.swift
    StreamingSpeechRecognizer.swift
    AppleSpeechAdapter.swift
    GeminiSpeechAdapter.swift
    OpenAICompatibleAudioAdapter.swift
    WhisperCppServerAdapter.swift        # native /inference server protocol
    WhisperCppWorkerAdapter.swift        # only after helper dependency approval
  Correction/
    TranscriptCorrector.swift
    CorrectionPipeline.swift
    CorrectionValidator.swift
    AppleFoundationCorrectionAdapter.swift
    OllamaCorrectionAdapter.swift
    OpenAICompatibleCorrectionAdapter.swift
    DeterministicCorrectionAdapter.swift
  Providers/
    VoiceProviderRegistry.swift
    VoiceProviderCapabilities.swift
    VoiceRoutingPolicy.swift
    VoiceRuntimeHealth.swift
  Persistence/
    VoiceSessionStore.swift
    VoiceRetryQueue.swift
    VoiceRetentionPolicy.swift
  Delivery/
    VoiceInsertionService.swift          # delegates to typed TextInjectionPipeline API
```

`DevTypeApp` should retain only UI composition: hotkey intent, HUD rendering, preferences, history views, and dependency assembly. It must not encode provider-specific routing.

## 5. Core contracts

The following shapes are illustrative Swift contracts. Exact names may change during implementation, but the separation must remain.

```swift
protocol SpeechRecognizer: Sendable {
    var descriptor: VoiceProviderDescriptor { get }
    func readiness() async -> ProviderReadiness
    func transcribe(
        audio: CapturedAudio,
        request: RecognitionRequest
    ) async throws -> RawTranscript
}

protocol StreamingSpeechRecognizer: Sendable {
    func start(request: StreamingRecognitionRequest) async throws -> StreamingSession
    func enqueue(_ frame: AudioFrame) -> EnqueueOutcome   // nonblocking
    func finish(expectedFrames: Int64, deadline: ContinuousClock.Instant)
        async throws -> RawTranscript
    func cancel() async
}

protocol TranscriptCorrector: Sendable {
    var descriptor: VoiceProviderDescriptor { get }
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate
}

protocol VoiceSessionStoring: Sendable {
    func create(_ metadata: SessionMetadata) async throws -> SessionHandle
    func record(_ event: PersistedSessionEvent, for session: SessionID) async throws
    func finalize(_ result: PersistedSessionResult, for session: SessionID) async throws
    func interruptedSessions() async throws -> [RecoverableSession]
}
```

Required typed results include:

- `ProviderReadiness`: ready, loading, unavailable, misconfigured, unhealthy, unsupported, probe timed out.
- `RawTranscript`: text, locale, confidence if supplied, model ID, provider ID, audio digest, request duration, response duration.
- `CorrectionCandidate`: text, optional operations, model/adapter/runtime metadata, artifact digest, prompt and validator versions, structured-output status, input/output token counts when available, termination reason, truncation state, and latency.
- `ValidationOutcome`: accepted, rejected with reason codes, unavailable, timed out.
- `InsertionOutcome`: delivered and verified, delivered but unverified, target changed, secure input, permission denied, clipboard fallback, timeout, cancelled, failed.

No Boolean named `ready`, `validated`, or `inserted` should be set by assignment alone.

## 6. Session state and concurrency model

Use an `actor VoiceSessionCoordinator` with injected services. UI projection stays on `@MainActor`; audio callbacks must never acquire a coordinator lock or perform file conversion. The actor owns `sessionsByID`, bounded work queues, and a separate `activeCaptureID`. A session reducer owns one session's state; a global enum must not conflate capture N+1 with recognition/correction for N.

```text
idle
  -> warming
  -> recording
  -> finalizingAudio
  -> recognizing
  -> normalizing
  -> correcting?
  -> validating?
  -> persisting
  -> inserting
  -> completed

Any active state -> cancelling -> cancelled
Any active state -> failed(reason, stage, recoverability)
```

Rules:

- Invalid transitions return an explicit error and diagnostic event; they are never silent no-ops.
- Each asynchronous completion carries a session UUID. Results for an inactive UUID are discarded and logged as stale.
- Every spawned task is held in a per-session task bag. Cancellation first invalidates the session generation, then propagates to capture, recognition, correction, persistence, and delivery; late callbacks are incapable of committing or inserting.
- Capture may overlap processing of an earlier session, but concurrency is bounded by policy. Default: one capture, one recognition job per resident model, one correction job per resident model.
- Cancellation propagates to audio, provider requests, correction, persistence, and delivery.
- A session snapshots provider selection, vocabulary, tone, locale, limits, target lease, and privacy route at start. Preference changes affect the next session only.
- Every accepted start has exactly one terminal disposition: completed, cancelled, failed, or saved-but-not-inserted. Empty/silent audio and voice-command handling are explicit paths, not early returns.
- The source application is never automatically reactivated at completion. The target lease is revalidated against current focus; a changed target produces saved-but-not-inserted state.
- Hotkey-to-HUD and hotkey-to-capture paths cannot wait for model loading. Prewarming is opportunistic; an unready preferred provider triggers the declared fallback policy.

## 7. Durable audio subsystem

Replace the raw-journal-to-in-memory-WAV lifecycle with a session-owned capture artifact:

1. Create `Application Support/DevType/VoiceSessions/<UUID>/` atomically.
2. Write `meta.json` with state `capturing`, device identity, format, policy snapshot hash, and target PID before installing the tap.
3. Write linear PCM to a recoverable CAF from the first accepted frame. CAF avoids requiring a final header rewrite and is suitable for interrupted recordings.
4. The audio callback copies into an owned preallocated buffer pool and performs only bounded, nonblocking accounting. It must not retain callback-owned buffers across queues without a proven lifetime, allocate unbounded `Data`, take a contended coordinator/file lock, convert formats, or perform filesystem I/O.
5. On stop, stop accepting new buffers, drain the configured tail window, finalize the file, reconcile expected and written frames, then transition to recognition.
6. Record `AudioCoverage`: accepted/written frame and byte counts, bytes per frame, sample rate, channels, monotonic sequence range, gaps, overruns, and digest. Do not hard-code mono/stereo byte arithmetic.
7. Convert to a provider format such as FLAC only after durable capture is complete, and stream conversion rather than loading the entire utterance into memory.
8. Bound the writer queue and disk budget. If the pool or write-lag budget is exhausted, record an exact gap and finalize/fail loudly according to policy; never silently drop audio while claiming complete capture.
9. Device/format changes rebuild the converter and writer segment explicitly. Voice-activity detection begins in shadow mode and cannot delete or omit source audio until soft-speech/noisy-room false-negative rates are established.

Recovery policy:

- On launch, scan session metadata and audio artifacts.
- Interrupted recordings are offered for recovery. Automatic transcription is allowed only under the original session's provider/egress policy; local/manual recovery is the default.
- Recovery may generate and persist a transcript but must never auto-insert.
- Corrupt metadata, missing audio, partial conversion, and zero-frame sessions get distinct states.
- Retention may delete audio only after a durable transcript or an explicit silent/cancelled disposition. Never delete the only recoverable artifact.
- Define the promise precisely: CAF plus atomic metadata is process-crash recovery. If power-loss durability is promised, add bounded off-audio-thread flush/sync points and test sudden host interruption; page-cache writes alone do not prove it.

## 8. Provider registry and local-first routing

### Capability model

Each provider registers a descriptor rather than occupying a fixed enum case:

```swift
struct VoiceProviderCapabilities: OptionSet, Sendable {
    static let batchASR
    static let streamingASR
    static let correction
    static let structuredCorrection
    static let vocabularyHints
    static let languageDetection
    static let timestamps
    static let onDevice
    static let cloud
}
```

Readiness requires all of the following, as applicable:

- configuration parses;
- artifact digest matches a signed or pinned manifest;
- runtime can load the model;
- a bounded health/inference probe succeeds;
- the requested capability is advertised and exercised;
- memory and hardware requirements fit the configured budget.

A file larger than 10 MB is not ready. Remove current placeholder digest behavior and do not present Voxtral or Fun-ASR as usable until a real runtime probe passes.

### Default routing policy

Recognition:

1. configured healthy local ASR provider;
2. Apple on-device Speech when available for the requested locale;
3. optional configured cloud ASR, only when the user enabled cloud fallback;
4. retain the session for retry and return a typed unavailable result.

Correction:

1. configured healthy on-device correction provider;
2. another configured loopback correction provider;
3. deterministic cleanup and dictionary replacement;
4. optional cloud correction only when separately enabled.

Never silently send audio or text to a cloud service because a local process failed.

### Initial adapters

| Adapter | Capability | Transport and constraints |
|---|---|---|
| `AppleSpeechAdapter` | batch and optional partial ASR | Prefer [`SpeechAnalyzer`](https://developer.apple.com/documentation/speech/speechanalyzer) / `SpeechTranscriber` on supported systems, including `AssetInventory` readiness and the one-input-sequence-per-analyzer rule. Retain legacy `SFSpeechRecognizer` as the older-OS adapter. Report `onDevice` only when the active backend proves it for the locale. If another provider owns final ASR, Apple partials are HUD previews only. |
| `GeminiSpeechAdapter` | optional cloud batch/live ASR | Move to the current documented [Gemini audio transcription](https://ai.google.dev/gemini-api/docs/transcribe) / Interactions contract. Require a terminal event, reject malformed partial responses, bound encoded payload size, probe model-specific access, and distinguish bad request, authentication, permission, model-not-found, quota, and transient failure. Gemini is never the coordinator. |
| `AppleFoundationCorrectionAdapter` | local correction | Plain-string generation with permissive content transformations where appropriate; output still passes the common validator. Readiness includes system-model availability, locale support, model variant, context budget, and provider token counting where available. Refusal prose remains possible and must be rejected. |
| `OllamaCorrectionAdapter` | local correction and model discovery | Use native [`POST /api/chat`](https://docs.ollama.com/api/chat) and [`GET /api/tags`](https://docs.ollama.com/api/tags); set non-streaming mode for final correction and use bounded `keep_alive`. |
| `OpenAICompatibleCorrectionAdapter` | local correction and model discovery | Use `/v1/chat/completions` and `/v1/models`; capability-probe optional `/health`. llama.cpp’s [server](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) is the first target, without assuming exact parity with hosted OpenAI behavior. |
| `DeterministicCorrectionAdapter` | no-model correction | Existing rules and dictionary behavior, made deterministic and independently testable. |
| `OpenAICompatibleAudioAdapter` | optional local/remote ASR | Enable only after a successful `/v1/audio/transcriptions` probe. Do not infer this capability from chat support. |
| `WhisperCppServerAdapter` | external local batch ASR | Use whisper.cpp server's native multipart [`POST /inference`](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/README.md), not an invented OpenAI audio route. The upstream server is user-managed and must not be exposed as an unauthenticated LAN service. |
| `WhisperCppWorkerAdapter` | embedded local batch ASR | Second-stage integration using [whisper.cpp](https://github.com/ggml-org/whisper.cpp); requires explicit dependency, helper packaging, artifact/license, signing, security, and memory approval. |

External local servers are the first local-ASR integration path because they avoid adding a runtime dependency to the initial refactor. The first milestone is reliable batch ASR; streaming is a later capability after cold/warm latency and final-quality evidence. Embedded whisper.cpp follows only after the provider seam, artifact verification, and resource manager exist.

## 9. Local runtime manager

Introduce a runtime layer separate from provider protocol adapters. The packaging audit found one application executable in `Package.swift:9-47`; `Scripts/package-app.sh:297-384` assembles and signs that executable without a separately managed helper lifecycle, and `Resources/DevType.entitlements:23-28` deliberately omits unsigned-executable-memory and disable-library-validation exceptions. There is no existing helper/XPC target or nested-code signing path. Therefore the runtime decision is staged, not open-ended:

1. **Initial production route:** user-managed external loopback servers, including native whisper.cpp `/inference`, with explicit adapter selection and health/inference probes. This adds no binary dependency.
2. **Integrated route after approval:** add a second SwiftPM executable target, `DevTypeASRWorker`, embed it under `Contents/Helpers`, and supervise it through versioned framed stdin/stdout pipes. Do not open a general TCP listener.
3. **XPC alternative:** use XPC only if the project deliberately adds an Xcode/launchd service lifecycle and accepts that packaging change; it is not a casual drop-in for the present build.
4. **Rejected production route:** in-process native ASR. Model crashes, allocator failure, or corrupt artifacts must not take down the menu-bar app or its session recovery owner.

Runtime requirements:

- Load models during idle time, never in the hotkey callback.
- Maintain one bounded inference queue per model and expose loading, ready, busy, unhealthy, evicted, and crashed states.
- Set configurable RAM limits, model residency duration, and maximum parallel jobs. Observe memory pressure and thermal state; evict correction before the active ASR model.
- Cache model manifests separately from model files. A manifest includes provider kind, model ID, version, byte size, SHA-256, supported languages, capabilities, minimum app/runtime version, and source URL.
- Treat model files as untrusted data. Validate paths against the managed model root, reject symlink escapes, verify digests before load, and never execute scripts supplied with a model.
- Define a helper handshake and message contract: protocol version, request/session ID, model load/unload, transcribe, progress, cancellation, heartbeat, maximum frame size, and exactly one structured terminal result. Pass canonical managed paths or framed bytes; never construct a shell command from a model path.
- Bound startup, heartbeat, cancellation, and forced-termination deadlines. A helper crash yields a typed recoverable stage failure and cannot corrupt the durable capture artifact.
- Sign nested helpers and dylibs before the containing app, then verify the full bundle with `codesign --verify --deep --strict`. Preserve library validation and the existing prohibition on unsigned executable memory. Verify universal architectures, notarization/stapling, helper/app protocol compatibility, and updater atomicity.
- Redact prompts, transcript text, tokens, and authorization headers from routine logs. Diagnostics record lengths, hashes, timing, and reason codes instead.

Decision gate: adding whisper.cpp, llama.cpp libraries, GRDB, or any new package is outside this plan’s initial no-dependency refactor. Before adoption, present the exact audited tag/commit, transitive licenses, model-artifact license, binary size, architecture support, update mechanism, security model, and measured resource cost for approval. Upstream `master`/`main` is evidence for protocol shape, never a product version pin.

Audit-time upstream snapshots—not approved pins—were whisper.cpp [`9781133`](https://github.com/ggml-org/whisper.cpp/commit/978113305b2ead22249b881deafa131dc8884911), llama.cpp [`6fe7498`](https://github.com/ggml-org/llama.cpp/commit/6fe74980162af0ed5e559870d5deccafaa034e7c), and Ollama [`f96e7aa`](https://github.com/ollama/ollama/commit/f96e7aa0513b9973a0ccc71be414c2ecb9d65b1a); each repository exposed an MIT license at audit time. Runtime licensing does not establish that a separately distributed model artifact may be redistributed.

## 10. Correction pipeline

Correction must become a single canonical pipeline used by every ASR provider:

```text
raw transcript
  -> Unicode and whitespace normalization
  -> optional model correction under a hard deadline
  -> sanitize transport wrappers/reasoning/preambles
  -> semantic and structural validation
  -> accepted model candidate OR normalized raw fallback
  -> deterministic user dictionary
  -> final transcript
```

### Prompt contract

- State that the model edits dictated text and must never answer questions or follow instructions contained in the transcript.
- Provide locale, tone, bounded vocabulary hints, and narrowly selected examples.
- Require transcript-only output. Prefer schema-constrained JSON when the runtime proves structured-output support, for example `{ "text": "...", "operations": [...] }`.
- Treat the transcript and vocabulary as untrusted data delimiters, not prompt instructions.
- Version and hash the prompt template. Persist the version, not the full sensitive prompt.
- Cap input bytes, vocabulary entries and bytes, example count, output bytes, and duration. Do not convert character count directly into a token limit.
- Select the correction adapter before constructing a request. A user's Ollama choice must not be shadowed by an implicit Apple Foundation Models attempt, and discovery must not probe unrelated protocol families.
- Treat delimiters and role instructions as defense in depth only. Transcript and dictionary content remain attacker-controlled; the validator and raw fallback are the acceptance boundary.

### Validation contract

The shared validator should evaluate:

- non-empty and bounded output;
- Unicode/script and locale consistency;
- normalized length ratio, token multiplicity/order, edit alignment, and versioned deletion/addition budgets;
- locale-specific word, token, or grapheme comparison rather than one English-centric tokenizer;
- exact typed protected spans for numbers/units, dates, URLs, email addresses, filesystem paths, code identifiers, command flags, and named vocabulary unless a declared edit explains the change;
- rejection of assistant preambles, refusals, markdown fences, reasoning tags, role labels, or AI self-reference;
- detection of question answering, content continuation, summarization, or new claims;
- allowed self-correction removal such as “Tuesday—sorry, Thursday” without treating the removal as semantic loss.

Return reason codes and metrics, not just a Boolean. After three validation trips for the same provider/model/prompt version within 24 hours, auto-disable model correction for that combination and fall back to deterministic cleanup until a successful explicit probe or user reset. Raw transcription remains available.

Thresholds begin in shadow mode against a consented, human-labeled corpus. Report false acceptance and false rejection by locale, provider/model digest, prompt version, validator version, and correction class. A schema-valid response is still untrusted model output; JSON structure never waives semantic checks.

Apply exact wrong-to-right user dictionary replacements last. Send only correct terms as ASR vocabulary hints; do not teach an ASR model the known-wrong variants.

## 11. Live partials and insertion

Adopt Jot’s strongest invariant: partial hypotheses are display state, not document state.

- Show partial text in the HUD with a clear “listening” status.
- Persist only the final raw and final corrected transcripts.
- Migrate current live target-field mutation to disabled by default. Existing users are shown the changed safety default and may explicitly re-enable the experiment; silently preserving the current `true` default is not acceptable.
- If experimental live insertion survives, require an edit lease containing target PID, AX element identity, initial selection/range, inserted-range checksum, and monotonic revision. Abort on user edits, caret movement, focus change, secure input, or unverifiable rollback.

`TextInjectionPipeline` is the canonical delivery owner, but its current callback signals that the attempt settled, not whether text was delivered. Extend that seam first; only then create `VoiceInsertionService` as a thin voice-specific adapter:

1. Capture target PID and accessibility identity when the session starts.
2. Recheck secure input and frontmost PID before delivery.
3. Add an `async` target-aware entry point returning `InjectionReceipt`; keep legacy snippet APIs as delegating compatibility adapters. Do not copy AX writing, HID posting, pasteboard restoration, or delivery verification into voice code.
4. Recheck target identity after direct AX failure and before any paste fallback.
5. Do not automatically reactivate the source app. If focus changed, persist saved-but-not-inserted and let the user explicitly copy/retry; do not overwrite the clipboard as an implicit recovery action.
6. Persist the typed insertion outcome only after the canonical pipeline produces its receipt. A transcript may be complete even when insertion is blocked.

## 12. Persistence, history, retry, and retention

Start without a new database dependency. Use atomic per-session directories and an append-safe metadata/event format; add an index only after measuring the need.

```text
VoiceSessions/<session UUID>/
  session.json              # authoritative atomic snapshot, schemaVersion + revision
  events.jsonl              # diagnostic journal; tolerate a truncated final record
  capture.caf               # durable source audio
  provider-input.flac       # optional derived artifact
  raw-transcript.json
  correction.json
  final-transcript.json
  insertion.json
```

The directory is canonical. Any later SQLite/index layer is a rebuildable projection, not a second authority. Each transcript/result write uses temp file -> bounded flush/sync according to the durability policy -> atomic rename -> digest -> `session.json` revision update. Persistence errors are never swallowed: a transcript that could not be committed enters `unpersistedResult`, blocks automatic insertion, and remains actionable.

Persist:

- timestamps and stage durations;
- audio digest, frame counts, gaps, format, device identity;
- configured and actual provider/model IDs and capabilities;
- every fallback decision and its reason;
- raw, candidate, and final text as separate values;
- validator version/outcome and prompt version hash;
- target application bundle ID/PID where policy permits, never sensitive AX content;
- insertion outcome and whether delivery was verified.

Retry policy:

- Retry only retryable recognition/correction failures, one session at a time, with exponential backoff and a hard attempt cap. Resume at the failed stage: if raw ASR is durable, retry correction without rerunning ASR.
- Network restoration may wake cloud work; local runtime health restoration may wake local work.
- Authentication, billing/quota, incompatible model, invalid request, and corrupt audio are blockers, not blind retries.
- Retried/recovered sessions never auto-insert.
- Retry jobs persist provider/privacy snapshot, current stage, attempt count, next eligible time, and blocker code. Current preferences cannot silently broaden an old job's route.

Create session directories with mode `0700` and sensitive files with mode `0600`. Authoritative sessions belong in Application Support; only reproducible derived artifacts belong in Caches. Retention should expose separate durations for audio, transcripts, and diagnostics. Deletion is atomic, auditable, and never removes an artifact still needed to recover a transcript-less session.

## 13. Preferences and UX

Replace the flat engine picker with policy-oriented settings:

- **Speech recognition:** preferred provider, model, locale, local-only toggle, cloud fallback toggle.
- **Correction:** off, deterministic only, local preferred, or named provider/model; independent cloud correction consent.
- **Local runtimes:** explicit endpoint entries with adapter kind, health, capabilities, and last probe time. Discovery is user-initiated.
- **Resources:** maximum resident memory, model idle timeout, maximum recording length, retained history/audio duration.
- **Privacy:** plain-language route summary showing where audio and text can go.
- **Advanced:** display-only partials, experimental live insertion, diagnostics export.

The HUD should distinguish listening, finalizing audio, recognizing locally, recognizing in cloud, correcting locally, falling back, inserting, and saved-but-not-inserted. It must not report generic “processing” when an actionable state is known.

Provider/model selection is capability-filtered. An unavailable model remains visible with a precise reason and recovery action; it is not silently relabeled as Apple Speech.

## 14. Security and privacy impact

This redesign narrows default access:

- strict-local endpoints default to numeric loopback `127.0.0.1` or `[::1]`; `localhost` is convenient but is not itself an authenticated process identity;
- normalize the URL and reject userinfo, fragments, unexpected base paths, cross-authority redirects, and disallowed schemes before any request;
- the selected adapter exclusively owns allowlisted paths. Do not probe Ollama, OpenAI, and whisper.cpp routes against the same arbitrary authority to guess its type;
- non-loopback/LAN endpoints require a distinct approved profile, HTTPS unless an explicit development exception is active, and clear audio/text disclosure;
- cloud audio and cloud correction are separately opt-in;
- endpoint probes use allowlisted paths for the selected adapter, reject redirects to a different authority by default, and enforce short timeouts and payload caps;
- loopback does not authenticate a user-managed service. Support an optional bearer credential stored in Keychain and show the probed provider/model identity before enabling it;
- credentials never enter `UserDefaults`, model manifests, session metadata, or logs;
- captured audio never leaves the declared route, including during fallback.

Allowing arbitrary LAN/remote endpoints, adding model execution libraries, or changing authentication/authorization is a security-impacting expansion and requires a separate review before implementation.

## 15. Migration plan

### Phase 0 — freeze behavior and establish evidence

- Reconcile current in-progress preferences/local-model work before touching overlapping files.
- Immediately hide/disable misleading Voxtral/Fun-ASR download, readiness, and execution claims while preserving any user-downloaded files for an explicit migration decision.
- Change the live-document-mutation default to off with a visible one-time migration notice.
- Add pre-fix failing characterization tests for: cancel then late result, empty-result terminal state, voice-command terminal state, callback falsely reported as insertion success, recovery cleanup deleting source audio, invalid model artifact marked ready, native Ollama response ignored, arbitrary endpoint probing, unbounded prompt/dictionary input, and recorder backpressure/tail loss.
- Capture baseline latency, memory, CPU, transcript quality, and failure behavior on named hardware and macOS versions.
- Build a small consented evaluation corpus with clean/noisy audio, accents, supported languages, jargon, numbers, punctuation, commands, code, questions that must not be answered, and spoken self-corrections.

Exit: current behavior is reproducible, known deficiencies have failing tests, and no benchmark is described as broader than its corpus or hardware.

### Phase 1 — contracts and coordinator

- Add the provider, session, persistence, and typed-outcome protocols.
- Replace the mutable singleton flow with an injected actor coordinator and pure state reducer.
- Snapshot preferences at session start, add a session registry/active-capture split, and add generation-based stale-completion guards plus owned task cancellation.
- Wrap existing Apple Speech, Gemini, local cleaner, and deterministic rules behind adapters without changing user-visible routing yet.

Exit: existing behavior runs through the new contracts; invalid transitions, cancellation, stale completions, and timeouts are tested.

### Phase 2 — durable audio

- Introduce per-session folders, crash-safe CAF capture, asynchronous tail drain, frame reconciliation, streaming conversion, and device/disk events.
- Replace callback conversion/writes with an owned bounded buffer pool and observable overload policy.
- Wire launch recovery and remove the current delete-only journal cleanup once migration tests prove older artifacts are handled.

Exit: kill-and-relaunch recovers usable audio; the last spoken phonemes survive stop; no full recording is loaded into memory merely to package it.

### Phase 3 — persistence and recovery

- Persist raw transcript before correction/insertion.
- Add recovery UI, retry queue, typed blockers, and retention.
- Add privacy-safe diagnostics export.

Exit: every terminal session has an explainable durable result; retry cannot insert into an unintended target.

### Phase 4 — provider registry and local routes

- Split Apple Foundation Models, native Ollama, OpenAI-compatible, and Gemini transports; selection is explicit and transports are dependency-injected in tests.
- Add normalized numeric-loopback validation, adapter-specific health/capability probes, model discovery, request/response fixture tests, credential handling, and explicit routing policy.
- Add native whisper.cpp `/inference` as the first external local ASR contract; add `/v1/audio/transcriptions` only for servers that prove it.
- Migrate Gemini to its documented Interactions/audio-transcription contract if retained.
- Retire fake Voxtral/Fun-ASR readiness and UI claims.

Exit: a local speech provider and local corrector can be selected independently, server loss has deterministic fallback behavior, and no cloud call occurs in local-only mode.

### Phase 5 — correction hardening

- Consolidate prompt construction, sanitization, validation, fallback, and dictionary application.
- Add structured output where proved, validation reason codes, auto-degradation, and adversarial corpus evaluation.
- Move Gemini cleanup through the same contract if retained.

Exit: every provider passes the same semantic-preservation suite; rejected correction always preserves a usable raw transcript.

### Phase 6 — guarded delivery

- Extend `TextInjectionPipeline` with target leases and typed receipts, then add `VoiceInsertionService` over that canonical seam.
- Disable live document mutation by default and gate experimental live insertion behind edit-lease checks.

Exit: focus theft, secure input, clipboard races, permission loss, and user edits cannot cause silent delivery to the wrong target.

### Phase 7 — embedded local ASR worker decision

- Benchmark external local ASR first.
- Present a dependency proposal for whisper.cpp or another runtime, including pinned source revision, runtime and model licenses, universal-binary size, model distribution, update/signing, helper protocol, RAM/thermal cost, and representative WER/latency.
- If approved, add the signed `DevTypeASRWorker` helper and framed-pipe protocol behind the existing adapter/resource manager; no coordinator changes should be needed. XPC remains an explicit packaging alternative, not the default assumption.

Exit: packaged local inference passes digest, load, crash-isolation, cancellation, memory-pressure, and offline end-to-end tests on supported Macs.

### Phase 8 — cutover and removal

- Move UI to capability-based settings and truthful HUD states.
- Run full automated, live-provider, and physical UI gates.
- Remove the old coordinator branches, duplicate correction transport, inert model paths, and obsolete audio journal behavior in the same cutover.
- Update privacy documentation and migration handling for existing preferences/model files.

Exit: there is one production path per behavior, old code is deleted with two independent usage signals, and rollback is a release-level decision rather than a hidden parallel implementation.

## 16. Verification strategy

### Unit and contract tests

- Every valid and invalid state/event pair, including cancellation at each stage.
- Stale async completion after cancellation or a newer session starts, proving no durable commit or insertion occurs.
- Provider capability, readiness, fallback, and local-only routing matrices.
- Injected Apple/Ollama/OpenAI/Gemini/whisper.cpp request-response fixtures, including native Ollama `message.content`, malformed JSON/SSE, missing terminal events, empty choices, reasoning fields, streaming unexpectedly enabled, oversized responses, redirects, authentication/permission/model errors, and timeouts. Unit tests must never depend on ambient localhost or the machine's system model.
- Audio frame accounting, tail drain, zero frames, maximum duration, format changes, and gaps.
- Correction attacks: empty, huge, duplicated, multilingual, emoji/graphemes, code, prompt injection in transcript, refusal, answer generation, summarization, altered numbers, fabricated names, and valid self-correction deletion.
- Dictionary boundaries, Unicode normalization, overlapping replacements, and locale-sensitive cases.
- Persistence interruption at every write boundary and retention safety.
- Target lease invalidation and all typed insertion outcomes.
- Model install/download tests that reject bad digest, wrong size, HTML/auth response, symlink escape, incompatible architecture/runtime, and a model that cannot complete a bounded inference probe.

Every defect fix must include a test that fails against the pre-fix implementation.

### Integration and chaos tests

- Kill the app during recording, conversion, recognition, correction, persistence, and insertion.
- Unplug/change microphone; revoke microphone or accessibility permission; enable secure input.
- Fill the session volume, make it read-only, corrupt metadata, remove derived audio, and retain the source CAF.
- Stop/restart the local server; return 429/500, hang, close mid-response, advertise a model that cannot load, and crash the worker.
- Trigger memory pressure and thermal pressure while recording.
- Stall the audio writer until its bounded queue fills and prove exact gap/failure reporting; change input format mid-session; verify stop-tail preservation.
- Steal focus between start/finalize/insert; change selection; mutate clipboard concurrently; begin rapid back-to-back sessions.
- Disconnect the network in local-only mode and prove behavior is unchanged except for explicitly configured cloud routes.
- Run strict local-only mode with an outbound deny rule or packet capture and prove zero egress, including discovery, telemetry, recovery, and fallback paths.

### Quality evaluation

Report by provider/model/version, language, noise band, utterance length, and hardware:

- WER and CER for raw ASR;
- semantic preservation and accepted-edit precision for correction;
- number/date/URL/code-token preservation;
- dictionary exact-match rate;
- validation trip, timeout, fallback, and hallucination rates;
- silent/too-short false-positive and false-negative rates.

Never use model-written pseudo-labels as sole truth. Keep human references and ambiguous-item adjudication separate.

### Performance budgets

Budgets must be calibrated on supported hardware tiers before becoming release gates. Initial engineering targets:

- hotkey to visible HUD: p50 under 16 ms, p95 under 33 ms;
- hotkey to first durable built-in-mic frame: p95 under 80 ms; Bluetooth reported separately;
- zero unexplained final-buffer loss, with captured/streamed byte reconciliation;
- model correction: p50 under 750 ms, hard deadline 1.5 s, then safe fallback;
- idle CPU below 0.5% with no active model work;
- no main-actor stall over one frame budget caused by audio, encoding, network, model load, or persistence;
- resident model memory remains within the user-configured budget and releases under memory pressure.

Measure cold and warm model-load time, real-time factor by utterance band, p50/p95 end-to-end latency, resident and peak memory, CPU/GPU/Metal use, energy impact, thermal state, and battery/AC separately for each supported Mac tier. The scheduler priority is durable capture/write first, ASR second, correction third; correction is cancelled/evicted first under pressure. Enforce a recording cap, disk-reserve floor, and session quota before capture begins.

The 750 ms / 1.5 s correction numbers are provisional hypotheses, not measured guarantees. ASR targets should be expressed as real-time factor plus end-to-end p50/p95 for short, medium, and capped utterances on each supported Mac tier, not as one universal number. Do not inherit performance assertions from Jot comments without independent measurement.

### Release gates

- Project-prescribed local build, tests, lint/static analysis, and package verification.
- Live Apple Speech, Apple Foundation Models, each supported local HTTP adapter, and Gemini only when credentials are supplied.
- Offline local-only test with network denied.
- Physical hotkey, microphone, HUD, cancellation, recovery, and insertion testing across representative target apps.
- Signed application and nested-helper verification if an embedded runtime is adopted, including architectures, hardened-runtime entitlements, notarization/stapling, worker/app protocol compatibility, and updater behavior.
- Privacy route review proving every audio/text egress is declared and consented.

A green unit suite is not proof of live model quality, microphone behavior, accessibility delivery, or packaged runtime signing; report those gates separately.

## 17. Adapt, reuse, and reject

| Decision | Treatment |
|---|---|
| Jot’s headless core boundaries and injected coordinator | Adapt into `ExpanderEngine`; keep `DevTypeApp` thin. |
| Jot’s pure state machine, durable sessions, stale-result guard, recovery/retry, and typed outcomes | Adapt as core invariants. |
| Jot’s separate live and batch transcription paths | Adapt; local providers may implement one or both, but replace format-specific byte equality with sequence/frame coverage plus provider acknowledgement when available. |
| Jot’s display-only partials | Adopt as the safe default. |
| DevType’s `TextInjectionPipeline` and its permission/security/delivery machinery | Reuse as the canonical owner, after adding target-aware typed receipts; the current completion callback is not proof of success. |
| DevType’s existing correction safeguards and Foundation Models permissive text generation behavior | Reuse behind the common correction and validation contracts. |
| Gemini as the central speech abstraction | Reject; retain only as an optional provider. |
| One generic “local endpoint” decoder for Ollama and OpenAI-compatible servers | Reject; use typed adapters and probes. |
| Downloaded file size as model readiness | Reject; require digest, load, capability, and inference proof. |
| A second insertion engine copied from Jot | Reject; it would duplicate and drift from DevType’s stronger existing path. |
| Jot's callback-buffer handoff, unbounded writer backlog, swallowed metadata errors, or auto-recovery route | Reject as written; re-derive bounded ownership, loud persistence, and policy-preserving recovery. |
| In-process native ASR in the menu-bar executable | Reject for production; use external loopback first and a supervised signed helper only after approval. |
| GRDB/SQLite, whisper.cpp, or another runtime added during structural refactoring | Defer to explicit dependency decision gates. |
| Permanent side-by-side old and new voice pipelines | Reject; adapters provide staged migration, then old owners are removed. |

## 18. Open decisions requiring evidence

1. Which Mac hardware and macOS versions define the supported local-inference tiers?
2. Which external local ASR servers besides native whisper.cpp `/inference` are release targets, and which actually prove `/v1/audio/transcriptions` compatibility?
3. Which languages and accents are release-critical, and what evaluation corpus can be used with consent?
4. What audio/transcript retention defaults match the product’s privacy promise?
5. Should cloud fallback be offered at all in local-only profiles, or must enabling it change the profile explicitly?
6. Is experimental live insertion worth preserving after physical usability testing, given its target/focus risks?
7. Which provider/model artifacts may DevType redistribute, and which must users download themselves?
8. Does the product promise process-crash recovery or power-loss durability, and what bounded sync cost is acceptable if it promises the latter?

These decisions should tune adapters and policy, not change the architecture.

## 19. Definition of done

The redesign is complete only when:

- the app records recoverable audio from the first frame and drains the tail;
- local ASR and local correction are independently selectable and capability-probed;
- local-only mode has proven zero network egress;
- Gemini is optional and removable without changing session coordination;
- raw, corrected, final, and insertion results are durably distinguishable;
- correction cannot answer, invent, or silently replace a transcript without validator acceptance;
- recovery and retry cannot insert into an unintended application;
- `TextInjectionPipeline` remains the sole delivery implementation;
- fake model readiness and inert speech-engine labels are gone;
- old parallel paths are removed after migration;
- automated, live-provider, physical UI, privacy, resource, and signing gates are reported independently with their actual results.
