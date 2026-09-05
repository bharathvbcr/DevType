import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Injectable boundary around the macOS 26 Speech framework.
///
/// The adapter owns policy, deadlines, event ordering, and bounded accumulation. This value owns
/// only the moving framework surface, so tests can exercise the shipping contract without asking
/// the machine for Speech permission or downloading a model.
struct AppleSpeechAnalyzerRuntime: Sendable {
    enum AssetState: Sendable, Equatable {
        /// SpeechTranscriber exists, but the service is not presently available.
        case unavailable
        /// The OS or requested locale cannot run SpeechTranscriber.
        case unsupported
        /// Apple has an asset for the locale, but it is not installed.
        case downloadable
        /// An explicit installation request is already in progress.
        case downloading(progress: Double?)
        /// The locale-specific asset is installed and can run offline.
        case installed
    }

    enum RuntimeError: Error, Sendable, Equatable {
        case unavailable
        case unsupported
        case assetsNotInstalled
        case audioUnreadable
        case installationUnavailable
    }

    struct Result: Sendable, Equatable {
        let startSeconds: Double
        let durationSeconds: Double
        let text: String
        let alternatives: [SpeechAlternative]
        let confidence: Double?
        let isFinal: Bool

        init(
            startSeconds: Double,
            durationSeconds: Double,
            text: String,
            alternatives: [SpeechAlternative] = [],
            confidence: Double? = nil,
            isFinal: Bool
        ) {
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
            self.text = text
            self.alternatives = alternatives
            self.confidence = confidence
            self.isFinal = isFinal
        }
    }

    let isPlatformSupported: @Sendable () -> Bool
    let assetState: @Sendable (Locale) async -> AssetState
    let transcribe: @Sendable (
        SpeechRequest,
        @escaping @Sendable (Result) -> Void
    ) async throws -> Void
    let installAssets: @Sendable (Locale) async throws -> Void

    /// Apple documents a maximum of 100 contextual strings for transcription. Keep this pure so
    /// the bound is testable without allocating a system SpeechTranscriber or touching assets.
    static func contextualTerms(from terms: [String]) -> [String] {
        Array(terms.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(100))
    }

    static func system() -> AppleSpeechAnalyzerRuntime {
        #if compiler(>=6.0)
        return AppleSpeechAnalyzerRuntime(
            isPlatformSupported: {
                if #available(macOS 26.0, *) { return true }
                return false
            },
            assetState: { locale in
                guard #available(macOS 26.0, *) else { return .unsupported }
                return await SystemAppleSpeechAnalyzerRuntime.assetState(for: locale)
            },
            transcribe: { request, emit in
                guard #available(macOS 26.0, *) else { throw RuntimeError.unsupported }
                try await SystemAppleSpeechAnalyzerRuntime.transcribe(request, emit: emit)
            },
            installAssets: { locale in
                guard #available(macOS 26.0, *) else { throw RuntimeError.unsupported }
                try await SystemAppleSpeechAnalyzerRuntime.installAssets(for: locale)
            }
        )
        #else
        return AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { false },
            assetState: { _ in .unsupported },
            transcribe: { _, _ in throw RuntimeError.unsupported },
            installAssets: { _ in throw RuntimeError.unsupported }
        )
        #endif
    }
}

#if compiler(>=6.0)
@available(macOS 26.0, *)
private enum SystemAppleSpeechAnalyzerRuntime {
    static func assetState(for locale: Locale) async -> AppleSpeechAnalyzerRuntime.AssetState {
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupported
        }

        let transcriber = makeTranscriber(locale: supportedLocale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported: return .unsupported
        case .supported: return .downloadable
        case .downloading: return .downloading(progress: nil)
        case .installed: return .installed
        @unknown default: return .unavailable
        }
    }

    static func transcribe(
        _ request: SpeechRequest,
        emit: @escaping @Sendable (AppleSpeechAnalyzerRuntime.Result) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechAnalyzerRuntime.RuntimeError.unavailable
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: request.locale
        ) else {
            throw AppleSpeechAnalyzerRuntime.RuntimeError.unsupported
        }

        let transcriber = makeTranscriber(locale: supportedLocale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw AppleSpeechAnalyzerRuntime.RuntimeError.assetsNotInstalled
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: request.audio.fileURL)
        } catch {
            throw AppleSpeechAnalyzerRuntime.RuntimeError.audioUnreadable
        }

        let context = AnalysisContext()
        context.contextualStrings[.general] = AppleSpeechAnalyzerRuntime.contextualTerms(
            from: request.vocabulary.terms
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        let resultTask = Task {
            for try await result in transcriber.results {
                try Task.checkCancellation()
                emit(normalize(result))
            }
        }

        do {
            try await withTaskCancellationHandler {
                let lastInputTime = try await analyzer.analyzeSequence(from: audioFile)
                try Task.checkCancellation()
                if let lastInputTime {
                    try await analyzer.finalizeAndFinish(through: lastInputTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                try await resultTask.value
                try Task.checkCancellation()
            } onCancel: {
                resultTask.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            if error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    static func installAssets(for locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechAnalyzerRuntime.RuntimeError.unavailable
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechAnalyzerRuntime.RuntimeError.unsupported
        }

        let transcriber = makeTranscriber(locale: supportedLocale)
        let modules: [any SpeechModule] = [transcriber]
        let before = await AssetInventory.status(forModules: modules)
        if before == .installed { return }
        guard before != .unsupported else {
            throw AppleSpeechAnalyzerRuntime.RuntimeError.unsupported
        }
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: modules
        ) else {
            if await AssetInventory.status(forModules: modules) == .installed { return }
            throw AppleSpeechAnalyzerRuntime.RuntimeError.installationUnavailable
        }

        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
            try Task.checkCancellation()
        } onCancel: {
            request.progress.cancel()
        }

        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw AppleSpeechAnalyzerRuntime.RuntimeError.installationUnavailable
        }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private static func normalize(
        _ result: SpeechTranscriber.Result
    ) -> AppleSpeechAnalyzerRuntime.Result {
        AppleSpeechAnalyzerRuntime.Result(
            startSeconds: finiteNonnegative(CMTimeGetSeconds(result.range.start)),
            durationSeconds: finiteNonnegative(CMTimeGetSeconds(result.range.duration)),
            text: String(result.text.characters),
            alternatives: result.alternatives.prefix(16).map {
                SpeechAlternative(text: String($0.characters))
            },
            // Word-level confidence lives on AttributedString runs. The provider contract permits
            // an absent aggregate instead of inventing one from incomparable per-token values.
            confidence: nil,
            isFinal: result.isFinal
        )
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
#endif

/// On-device, locale-aware batch transcription through macOS 26 SpeechAnalyzer.
///
/// Readiness is observational. A `.downloadable` result never starts a download; callers must
/// explicitly invoke `installAssets(for:deadline:)` from a user-initiated setup action.
public final class AppleSpeechAnalyzerAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor

    private let locale: Locale
    private let authorizationStatus: @Sendable () -> SpeechAuthorization.Status
    private let runtime: AppleSpeechAnalyzerRuntime
    private let sessions = AppleSpeechAnalyzerSessions()

    public convenience init(locale: Locale = Locale.current) {
        self.init(
            locale: locale,
            authorizationStatus: { SpeechAuthorization.status() },
            runtime: .system()
        )
    }

    init(
        locale: Locale,
        authorizationStatus: @escaping @Sendable () -> SpeechAuthorization.Status,
        runtime: AppleSpeechAnalyzerRuntime
    ) {
        self.locale = locale
        self.authorizationStatus = authorizationStatus
        self.runtime = runtime
        self.descriptor = SpeechProviderDescriptor(
            id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer,
            displayName: "Apple SpeechAnalyzer (On-Device)",
            modelVersion: "system",
            privacyRoute: .onDeviceOnly,
            supportsStreaming: false,
            supportsContextualStrings: true
        )
    }

    /// False only when this binary was compiled on a toolchain without `SpeechAnalyzer`;
    /// it says nothing about the machine the binary is running on.
    static let isBuiltWithSpeechAnalyzer: Bool = {
        #if compiler(>=6.0)
        return true
        #else
        return false
        #endif
    }()

    /// Why the platform came back unsupported, drawn on the right axis.
    ///
    /// `isPlatformSupported()` is false for two unrelated reasons and the user needs
    /// them told apart: on a Mac below macOS 26 the OS is the blocker whatever the
    /// build, and only a Mac that could run the analyzer, running a binary compiled
    /// without it, should be pointed at a newer download. Same rule as
    /// `AITextTransformSupport.unavailableReason`, and pure for the same reason —
    /// one of the two build states is always compiled out.
    static func platformUnsupportedReason(
        builtWithSpeechAnalyzer: Bool,
        isCompatibleOS: Bool
    ) -> FailureCode {
        guard isCompatibleOS else { return .modelNotFound }
        return builtWithSpeechAnalyzer ? .modelNotFound : .buildLacksSpeechAnalyzer
    }

    /// Observes platform, TCC, locale, and asset readiness without prompting or downloading.
    public func probe() async -> ProviderReadiness {
        guard runtime.isPlatformSupported() else {
            return .unsupported(reason: Self.platformUnsupportedReason(
                builtWithSpeechAnalyzer: Self.isBuiltWithSpeechAnalyzer,
                isCompatibleOS: AITextTransformSupport.isRunningOnCompatibleOS
            ))
        }
        guard authorizationStatus() == .authorized else {
            return .requiresPermission(.speechRecognition)
        }
        return readiness(for: await runtime.assetState(locale))
    }

    /// Explicit, cancellable model installation for a user-initiated setup action.
    ///
    /// This method is intentionally outside `SpeechRecognizer`: provider resolution remains a
    /// side-effect-free observation and cannot silently start a model download.
    @discardableResult
    public func installAssets(
        for locale: Locale = Locale.current,
        deadline: Date
    ) async throws -> ProviderReadiness {
        guard runtime.isPlatformSupported() else {
            throw failure(code: .modelNotFound, userAction: .retryWithOtherProvider)
        }
        guard deadline.timeIntervalSinceNow > 0 else {
            throw failure(code: .requestTimeout, retryClass: .afterUserAction)
        }

        let timeout = failure(code: .requestTimeout, retryClass: .afterUserAction)
        let finalState: AppleSpeechAnalyzerRuntime.AssetState
        do {
            finalState = try await runBounded(
                deadline: deadline,
                timeoutError: timeout
            ) { [runtime] in
                let before = await runtime.assetState(locale)
                switch before {
                case .installed:
                    return before
                case .unsupported:
                    throw AppleSpeechAnalyzerRuntime.RuntimeError.unsupported
                case .unavailable:
                    throw AppleSpeechAnalyzerRuntime.RuntimeError.unavailable
                case .downloadable, .downloading:
                    try await runtime.installAssets(locale)
                    try Task.checkCancellation()
                    return await runtime.assetState(locale)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw map(error)
        }
        try Task.checkCancellation()
        return readiness(for: finalState)
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            guard request.audio.frameCount > 0,
                  request.audio.byteCount > 0,
                  request.audio.durationSeconds.isFinite,
                  request.audio.durationSeconds > 0 else {
                continuation.finish(throwing: failure(
                    code: .speechNoSpeech,
                    artifactState: .durable
                ))
                return
            }

            let token = UUID()
            let accumulator = AppleSpeechAnalyzerAccumulator(
                idPrefix: "\(request.sessionID.description)-\(request.generation.rawValue)",
                locale: request.locale
            )
            let handle = AppleSpeechAnalyzerSessionHandle(
                token: token,
                continuation: continuation,
                onTerminal: { [weak sessions] in
                    sessions?.remove(sessionID: request.sessionID, token: token)
                }
            )
            sessions.replace(sessionID: request.sessionID, with: handle)

            continuation.onTermination = { @Sendable [weak sessions] termination in
                guard case .cancelled = termination else { return }
                sessions?.cancel(sessionID: request.sessionID, token: token)
            }

            let remaining = request.deadline.timeIntervalSinceNow
            guard remaining.isFinite, remaining > 0 else {
                handle.fail(failure(code: .requestTimeout, retryClass: .afterUserAction))
                return
            }

            // Retain the adapter and handle until a terminal signal. Weak capture here can strand
            // the continuation if a short-lived registry is released during recognition.
            let producer = Task { [self, runtime, authorizationStatus] in
                do {
                    try Task.checkCancellation()
                    guard runtime.isPlatformSupported() else {
                        throw runtimeFailure(.unsupported)
                    }
                    guard authorizationStatus() == .authorized else {
                        throw self.failure(
                            code: .speechRecognitionPermissionDenied,
                            retryClass: .afterUserAction,
                            artifactState: .durable
                        )
                    }

                    let currentAssets = await runtime.assetState(request.locale)
                    try Task.checkCancellation()
                    guard currentAssets == .installed else {
                        throw self.failure(for: currentAssets)
                    }

                    // Probe is only a hint. Re-check TCC immediately before the runtime can open
                    // the audio artifact, because permission may have changed across the asset await.
                    guard authorizationStatus() == .authorized else {
                        throw self.failure(
                            code: .speechRecognitionPermissionDenied,
                            retryClass: .afterUserAction,
                            artifactState: .durable
                        )
                    }

                    try await runtime.transcribe(request) { result in
                        if let segment = accumulator.ingest(result) {
                            handle.yield(.segment(segment))
                        }
                    }
                    try Task.checkCancellation()

                    if let overflow = accumulator.overflowFailure(providerID: self.descriptor.id) {
                        throw overflow
                    }
                    try self.finishRecognizedEvidence(
                        request: request,
                        accumulator: accumulator,
                        handle: handle,
                        startedAt: handle.startedAt
                    )
                } catch is CancellationError {
                    handle.cancel()
                } catch {
                    if accumulator.hasRecognizedText,
                       accumulator.overflowFailure(providerID: self.descriptor.id) == nil {
                        DevTypeLog.voice.error(
                            "[Voice] SpeechAnalyzer ended after producing text; delivering recognized evidence provider=\(self.descriptor.id, privacy: .public) chars=\(accumulator.characterCount, privacy: .public)"
                        )
                        VoiceDiagnosticsRecorder.shared.record(
                            "recognition.partialAfterError",
                            note: "provider=\(self.descriptor.id) chars=\(accumulator.characterCount) runtime=SpeechAnalyzer"
                        )
                        do {
                            try self.finishRecognizedEvidence(
                                request: request,
                                accumulator: accumulator,
                                handle: handle,
                                startedAt: handle.startedAt
                            )
                        } catch {
                            handle.fail(self.map(error))
                        }
                    } else {
                        handle.fail(self.map(error))
                    }
                }
            }
            handle.attachProducer(producer)

            let boundedRemaining = min(remaining, 86_400)
            let timeoutTask = Task { [self, handle] in
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64((boundedRemaining * 1_000_000_000).rounded(.up))
                    )
                } catch {
                    return
                }
                handle.fail(self.failure(code: .requestTimeout, retryClass: .afterUserAction))
            }
            handle.attachTimeout(timeoutTask)
        }
    }

    public func cancel(sessionID: VoiceSessionID) async {
        sessions.cancel(sessionID: sessionID, token: nil)
    }

    private func readiness(for state: AppleSpeechAnalyzerRuntime.AssetState) -> ProviderReadiness {
        switch state {
        case .unavailable:
            return .temporarilyUnavailable(retryAfterSeconds: 2, reason: .endpointUnreachable)
        case .unsupported:
            return .unsupported(reason: .modelNotFound)
        case .downloadable:
            return .requiresConfiguration(.missingModelDownload)
        case .downloading(let progress):
            let normalized = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            return .downloading(progress: normalized)
        case .installed:
            return .ready(ProviderEvidence(
                providerID: descriptor.id,
                modelVersion: descriptor.modelVersion,
                probeTimestamp: Date(),
                capabilities: [
                    "speechAnalyzer",
                    "volatileRevisions",
                    "contextualStrings",
                    "installedAssets",
                    "offline"
                ],
                contextLimits: 100
            ))
        }
    }

    private func failure(for state: AppleSpeechAnalyzerRuntime.AssetState) -> VoiceFailure {
        switch state {
        case .installed:
            return failure(code: .speechProtocolViolation)
        case .downloadable, .downloading:
            return failure(
                code: .modelNotFound,
                retryClass: .afterUserAction,
                artifactState: .durable,
                userAction: .downloadModel
            )
        case .unsupported:
            return failure(
                code: .modelNotFound,
                artifactState: .durable,
                userAction: .retryWithOtherProvider
            )
        case .unavailable:
            return failure(
                code: .endpointUnreachable,
                retryClass: .jitteredBackoff,
                artifactState: .durable,
                userAction: .retryWithOtherProvider
            )
        }
    }

    private func runtimeFailure(_ error: AppleSpeechAnalyzerRuntime.RuntimeError) -> VoiceFailure {
        map(error)
    }

    private func map(_ error: Error) -> VoiceFailure {
        if let failure = error as? VoiceFailure { return failure }
        guard let runtimeError = error as? AppleSpeechAnalyzerRuntime.RuntimeError else {
            return failure(
                code: .modelLoadFailed,
                retryClass: .immediateSameRoute,
                artifactState: .durable,
                userAction: .retryWithOtherProvider,
                redactedDetail: "SpeechAnalyzer could not complete recognition"
            )
        }
        switch runtimeError {
        case .audioUnreadable:
            return failure(
                code: .audioEncodingFailed,
                artifactState: .durable,
                userAction: .reviewInHistory,
                redactedDetail: "The saved audio could not be opened for recognition"
            )
        case .assetsNotInstalled:
            return failure(
                code: .modelNotFound,
                retryClass: .afterUserAction,
                artifactState: .durable,
                userAction: .downloadModel,
                redactedDetail: "SpeechAnalyzer assets are not installed for the requested language"
            )
        case .unsupported:
            return failure(
                code: .modelNotFound,
                artifactState: .durable,
                userAction: .retryWithOtherProvider,
                redactedDetail: "SpeechAnalyzer does not support the requested language"
            )
        case .unavailable:
            return failure(
                code: .endpointUnreachable,
                retryClass: .jitteredBackoff,
                artifactState: .durable,
                userAction: .retryWithOtherProvider,
                redactedDetail: "SpeechAnalyzer is temporarily unavailable"
            )
        case .installationUnavailable:
            return failure(
                code: .modelLoadFailed,
                retryClass: .afterUserAction,
                artifactState: .durable,
                userAction: .downloadModel,
                redactedDetail: "SpeechAnalyzer assets could not be installed"
            )
        }
    }

    private func failure(
        code: FailureCode,
        retryClass: RetryClass = .none,
        artifactState: ArtifactState = .absent,
        userAction: UserAction? = nil,
        redactedDetail: String? = nil
    ) -> VoiceFailure {
        VoiceFailure(
            stage: .recognition,
            code: code,
            providerID: descriptor.id,
            retryClass: retryClass,
            artifactState: artifactState,
            userAction: userAction,
            redactedDetail: redactedDetail
        )
    }

    private func finishRecognizedEvidence(
        request: SpeechRequest,
        accumulator: AppleSpeechAnalyzerAccumulator,
        handle: AppleSpeechAnalyzerSessionHandle,
        startedAt: Date
    ) throws {
        let completion = try accumulator.complete()
        guard !completion.text.isEmpty else {
            throw failure(code: .speechNoSpeech, artifactState: .durable)
        }
        for promoted in completion.promotedSegments {
            handle.yield(.segment(promoted))
        }

        let raw = RawTranscript(
            text: completion.text,
            localeIdentifier: request.locale.identifier,
            confidence: completion.confidence,
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            latencyMs: max(0, Date().timeIntervalSince(startedAt) * 1_000),
            audioSHA256: request.audio.sha256Hex,
            isFinal: true
        )
        handle.yield(.completed(SpeechCompletion(
            rawTranscript: raw,
            finalSegmentCount: completion.finalSegmentCount,
            totalDurationSeconds: request.audio.durationSeconds
        )))
        handle.finish()
    }
}

private final class AppleSpeechAnalyzerAccumulator: @unchecked Sendable {
    struct Completion {
        let text: String
        let confidence: Double?
        let finalSegmentCount: Int
        let promotedSegments: [SpeechSegment]
    }

    private struct Entry {
        let id: String
        var revision: UInt64
        var start: Double
        var duration: Double
        var text: String
        var alternatives: [SpeechAlternative]
        var confidence: Double?
        var isFinal: Bool
        var storageBytes: Int
    }

    private static let maximumSegments = 4_096
    private static let maximumTranscriptBytes = 1_048_576
    private static let maximumResultBytes = 131_072
    private static let maximumAlternatives = 32
    /// `SpeechTranscriber` defines an empty result as revoking earlier volatile output for the
    /// same audio range. Preserve range identity narrowly here: overlap is useful for recognizing
    /// a growing revision, but is not authority to erase a neighboring phrase.
    private static let revocationRangeToleranceSeconds = 0.000_001

    private let lock = NSLock()
    private let idPrefix: String
    private let locale: Locale
    private var entries: [Entry] = []
    private var nextID: UInt64 = 1
    private var storedResultBytes = 0
    private var overflowed = false

    init(idPrefix: String, locale: Locale) {
        self.idPrefix = idPrefix
        self.locale = locale
    }

    var hasRecognizedText: Bool {
        lock.withLock { entries.contains { Self.containsRecognizedText($0.text) } }
    }

    var characterCount: Int {
        lock.withLock { entries.reduce(0) { $0 + $1.text.count } }
    }

    func ingest(_ result: AppleSpeechAnalyzerRuntime.Result) -> SpeechSegment? {
        let rawTextBytes = result.text.utf8.count
        guard rawTextBytes <= Self.maximumResultBytes,
              result.alternatives.count <= Self.maximumAlternatives else {
            lock.withLock { overflowed = true }
            return nil
        }
        let text = result.text
        let start = finiteNonnegative(result.startSeconds)
        let duration = finiteNonnegative(result.durationSeconds)
        guard Self.containsRecognizedText(text) else {
            return lock.withLock {
                guard !overflowed,
                      let matchIndex = entries.indices.reversed().first(where: { index in
                          !entries[index].isFinal
                              && sameRevocationRange(entries[index], start: start, duration: duration)
                      }) else {
                    // Repeated revocations and revocations for already-finalized or unknown ranges
                    // are idempotent. Without a volatile owner there is nothing safe to retract.
                    return nil
                }

                var revoked = entries.remove(at: matchIndex)
                storedResultBytes -= revoked.storageBytes
                revoked.revision &+= 1
                if revoked.revision == 0 { revoked.revision = UInt64.max }
                revoked.start = start
                revoked.duration = duration
                revoked.text = ""
                revoked.alternatives = []
                revoked.confidence = nil
                revoked.isFinal = result.isFinal
                revoked.storageBytes = 0
                // The entry leaves bounded accumulator state, but the same-id revision must still
                // reach live consumers so they remove text that was already rendered.
                return segment(from: revoked)
            }
        }

        var resultBytes = rawTextBytes
        var alternatives: [SpeechAlternative] = []
        alternatives.reserveCapacity(result.alternatives.count)
        for alternative in result.alternatives {
            let alternativeBytes = alternative.text.utf8.count
            guard alternativeBytes <= Self.maximumResultBytes - resultBytes else {
                lock.withLock { overflowed = true }
                return nil
            }
            resultBytes += alternativeBytes
            let alternativeText = alternative.text
            guard Self.containsRecognizedText(alternativeText) else { continue }
            alternatives.append(SpeechAlternative(
                text: alternativeText,
                confidence: normalizedConfidence(alternative.confidence)
            ))
        }
        let storageBytes = text.utf8.count + alternatives.reduce(0) { partial, alternative in
            partial + alternative.text.utf8.count
        }
        guard storageBytes <= Self.maximumResultBytes else {
            lock.withLock { overflowed = true }
            return nil
        }

        return lock.withLock {
            guard !overflowed else { return nil }
            let matchIndex = entries.indices.reversed().first { index in
                !entries[index].isFinal && sameSegment(entries[index], start: start, duration: duration)
            }

            if let matchIndex {
                let projected = storedResultBytes - entries[matchIndex].storageBytes + storageBytes
                guard projected <= Self.maximumTranscriptBytes else {
                    overflowed = true
                    return nil
                }
                entries[matchIndex].revision &+= 1
                if entries[matchIndex].revision == 0 { entries[matchIndex].revision = UInt64.max }
                entries[matchIndex].start = start
                entries[matchIndex].duration = duration
                entries[matchIndex].text = text
                entries[matchIndex].alternatives = alternatives
                entries[matchIndex].confidence = normalizedConfidence(result.confidence)
                entries[matchIndex].isFinal = result.isFinal
                entries[matchIndex].storageBytes = storageBytes
                storedResultBytes = projected
                return segment(from: entries[matchIndex])
            }

            guard entries.count < Self.maximumSegments,
                  storageBytes <= Self.maximumTranscriptBytes - storedResultBytes else {
                overflowed = true
                return nil
            }
            let entry = Entry(
                id: "\(idPrefix)-\(nextID)",
                revision: 1,
                start: start,
                duration: duration,
                text: text,
                alternatives: alternatives,
                confidence: normalizedConfidence(result.confidence),
                isFinal: result.isFinal,
                storageBytes: storageBytes
            )
            nextID &+= 1
            entries.append(entry)
            storedResultBytes += storageBytes
            return segment(from: entry)
        }
    }

    func overflowFailure(providerID: String) -> VoiceFailure? {
        lock.withLock {
            guard overflowed else { return nil }
            return VoiceFailure(
                stage: .recognition,
                code: .speechProtocolViolation,
                providerID: providerID,
                retryClass: .none,
                artifactState: .durable,
                userAction: .reviewInHistory,
                redactedDetail: "SpeechAnalyzer output exceeded the bounded transcript contract"
            )
        }
    }

    func complete() throws -> Completion {
        lock.lock()
        defer { lock.unlock() }
        if overflowed {
            throw VoiceFailure(
                stage: .recognition,
                code: .speechProtocolViolation,
                artifactState: .durable,
                userAction: .reviewInHistory,
                redactedDetail: "SpeechAnalyzer output exceeded the bounded transcript contract"
            )
        }

        var promoted: [SpeechSegment] = []
        for index in entries.indices where !entries[index].isFinal {
            entries[index].revision &+= 1
            if entries[index].revision == 0 { entries[index].revision = UInt64.max }
            entries[index].isFinal = true
            promoted.append(segment(from: entries[index]))
        }
        let ordered = entries.sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return $0.start < $1.start
        }
        let text = try assembledTranscript(from: ordered.map(\.text))
        let confidences = ordered.compactMap(\.confidence)
        let confidence = confidences.isEmpty
            ? nil
            : confidences.reduce(0, +) / Double(confidences.count)
        return Completion(
            text: text,
            confidence: confidence,
            finalSegmentCount: ordered.count,
            promotedSegments: promoted
        )
    }

    private func sameSegment(_ entry: Entry, start: Double, duration: Double) -> Bool {
        let tolerance = max(0.25, min(entry.duration, duration) * 0.20)
        if abs(entry.start - start) <= tolerance { return true }
        let entryEnd = entry.start + entry.duration
        let candidateEnd = start + duration
        let overlap = min(entryEnd, candidateEnd) - max(entry.start, start)
        return overlap > 0 && overlap >= min(entry.duration, duration) * 0.60
    }

    private func sameRevocationRange(_ entry: Entry, start: Double, duration: Double) -> Bool {
        abs(entry.start - start) <= Self.revocationRangeToleranceSeconds
            && abs(entry.duration - duration) <= Self.revocationRangeToleranceSeconds
    }

    /// SpeechTranscriber chunks may already carry their exact leading or trailing boundary.
    /// Concatenate those bytes unchanged and synthesize a separator only for boundary-free chunks.
    private func assembledTranscript(from chunks: [String]) throws -> String {
        var assembled = ""
        var assembledBytes = 0
        for chunk in chunks where !chunk.isEmpty {
            let separator = assembled.isEmpty ? "" : fallbackSeparator(from: assembled, to: chunk)
            let separatorBytes = separator.utf8.count
            guard separatorBytes <= Self.maximumTranscriptBytes - assembledBytes else {
                overflowed = true
                throw boundedTranscriptFailure()
            }
            assembledBytes += separatorBytes

            let chunkBytes = chunk.utf8.count
            guard chunkBytes <= Self.maximumTranscriptBytes - assembledBytes else {
                overflowed = true
                throw boundedTranscriptFailure()
            }
            assembledBytes += chunkBytes
            assembled.append(separator)
            assembled.append(chunk)
        }
        return assembled
    }

    private func fallbackSeparator(from left: String, to right: String) -> String {
        guard let leftScalar = left.unicodeScalars.last,
              let rightScalar = right.unicodeScalars.first else { return "" }
        guard !Self.isWhitespace(leftScalar), !Self.isWhitespace(rightScalar) else { return "" }
        guard !Self.attachesToPrevious(rightScalar), !Self.attachesToNext(leftScalar) else { return "" }
        guard !localeOmitsWordSpaces,
              !Self.isHanOrJapanese(leftScalar),
              !Self.isHanOrJapanese(rightScalar) else { return "" }
        return " "
    }

    private var localeOmitsWordSpaces: Bool {
        guard let languageCode = locale.language.languageCode?.identifier.lowercased() else {
            return false
        }
        return languageCode == "ja" || languageCode == "zh"
    }

    private static func containsRecognizedText(_ text: String) -> Bool {
        text.unicodeScalars.contains { !isWhitespace($0) }
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func attachesToPrevious(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .closePunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return scalar == "%"
        }
    }

    private static func attachesToNext(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .openPunctuation, .initialPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isHanOrJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana and Katakana
             0x31F0...0x31FF, // Katakana phonetic extensions
             0x3400...0x4DBF, // CJK unified ideographs extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF65...0xFF9F, // Halfwidth Katakana
             0x20000...0x2FA1F: // Supplementary CJK ideographs
            return true
        default:
            return false
        }
    }

    private func boundedTranscriptFailure() -> VoiceFailure {
        VoiceFailure(
            stage: .recognition,
            code: .speechProtocolViolation,
            artifactState: .durable,
            userAction: .reviewInHistory,
            redactedDetail: "SpeechAnalyzer output exceeded the bounded transcript contract"
        )
    }

    private func segment(from entry: Entry) -> SpeechSegment {
        SpeechSegment(
            segmentID: entry.id,
            revision: entry.revision,
            startSeconds: entry.start,
            durationSeconds: entry.duration,
            text: entry.text,
            alternatives: entry.alternatives,
            confidence: entry.confidence,
            finality: entry.isFinal ? .final : .volatile
        )
    }

    private func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private func normalizedConfidence(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}

private final class AppleSpeechAnalyzerSessionHandle: @unchecked Sendable {
    let token: UUID
    let startedAt = Date()

    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    private let onTerminal: @Sendable () -> Void
    private var producer: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var terminal = false

    init(
        token: UUID,
        continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation,
        onTerminal: @escaping @Sendable () -> Void
    ) {
        self.token = token
        self.continuation = continuation
        self.onTerminal = onTerminal
    }

    func attachProducer(_ task: Task<Void, Never>) {
        attach(task, keyPath: \AppleSpeechAnalyzerSessionHandle.producer)
    }

    func attachTimeout(_ task: Task<Void, Never>) {
        attach(task, keyPath: \AppleSpeechAnalyzerSessionHandle.timeout)
    }

    func yield(_ event: SpeechEvent) {
        guard lock.withLock({ !terminal }) else { return }
        _ = continuation.yield(event)
    }

    func finish() {
        terminate(error: nil)
    }

    func fail(_ error: Error) {
        terminate(error: error)
    }

    func cancel() {
        terminate(error: CancellationError())
    }

    private func attach(
        _ task: Task<Void, Never>,
        keyPath: ReferenceWritableKeyPath<AppleSpeechAnalyzerSessionHandle, Task<Void, Never>?>
    ) {
        let shouldCancel = lock.withLock {
            guard !terminal else { return true }
            self[keyPath: keyPath] = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    private func terminate(error: Error?) {
        let tasks: (Task<Void, Never>?, Task<Void, Never>?)? = lock.withLock {
            guard !terminal else { return nil }
            terminal = true
            let captured = (producer, timeout)
            producer = nil
            timeout = nil
            return captured
        }
        guard let tasks else { return }
        tasks.0?.cancel()
        tasks.1?.cancel()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        onTerminal()
    }
}

private final class AppleSpeechAnalyzerSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [VoiceSessionID: AppleSpeechAnalyzerSessionHandle] = [:]

    func replace(sessionID: VoiceSessionID, with handle: AppleSpeechAnalyzerSessionHandle) {
        let previous = lock.withLock { active.updateValue(handle, forKey: sessionID) }
        previous?.cancel()
    }

    func remove(sessionID: VoiceSessionID, token: UUID) {
        lock.withLock {
            guard active[sessionID]?.token == token else { return }
            active.removeValue(forKey: sessionID)
        }
    }

    func cancel(sessionID: VoiceSessionID, token: UUID?) {
        let handle: AppleSpeechAnalyzerSessionHandle? = lock.withLock {
            guard let current = active[sessionID], token == nil || current.token == token else {
                return nil
            }
            active.removeValue(forKey: sessionID)
            return current
        }
        handle?.cancel()
    }
}

private final class BoundedOperationRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var resolved = false
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?

    func installContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        let pending: Result<Value, Error>? = lock.withLock {
            if let pending = self.pending {
                self.pending = nil
                return pending
            }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func attach(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            self.operation = operation
            self.timeout = timeout
            return resolved
        }
        if shouldCancel {
            operation.cancel()
            timeout.cancel()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        let state: (
            CheckedContinuation<Value, Error>?,
            Task<Void, Never>?,
            Task<Void, Never>?
        )? = lock.withLock {
            guard !resolved else { return nil }
            resolved = true
            if continuation == nil {
                pending = result
            }
            let state = (continuation, operation, timeout)
            continuation = nil
            operation = nil
            timeout = nil
            return state
        }
        guard let state else { return }
        state.1?.cancel()
        state.2?.cancel()
        state.0?.resume(with: result)
    }
}

private func runBounded<Value: Sendable>(
    deadline: Date,
    timeoutError: Error,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining.isFinite, remaining > 0 else { throw timeoutError }
    let race = BoundedOperationRace<Value>()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.installContinuation(continuation)
            let operationTask = Task {
                do { race.resolve(.success(try await operation())) }
                catch { race.resolve(.failure(error)) }
            }
            let boundedRemaining = min(remaining, 86_400)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64((boundedRemaining * 1_000_000_000).rounded(.up))
                    )
                } catch {
                    return
                }
                race.resolve(.failure(timeoutError))
            }
            race.attach(operation: operationTask, timeout: timeoutTask)
        }
    } onCancel: {
        race.resolve(.failure(CancellationError()))
    }
}
