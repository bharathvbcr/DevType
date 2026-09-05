import AppKit
import Foundation
import OSLog

/// Builds a pasteboard-friendly diagnostic dump for Permission Recovery support.
public enum DiagnosticReport {
    public static let defaultLogLookback: TimeInterval = 30 * 60
    /// Raised from 200: a single busy minute of typing produces more lines than the old cap, so
    /// the report regularly opened mid-history even before `DevLogMirror` extended retention.
    /// The mirror is the long-horizon answer; this keeps the direct fetch useful on its own.
    public static let defaultLogLineLimit = 500
    /// §9.1: newest mirrored lines included in a report. The ring holds thousands; a report is
    /// pasted into chat windows and issue trackers, so it carries the recent tail plus a notice
    /// rather than the whole buffer.
    public static let defaultMirrorLineLimit = 400
    /// Independent of the line cap: a single unexpectedly large OSLog message must not make a
    /// support report (or its construction) effectively unbounded.
    /// The report contains both an OSLog tail and an independent in-process mirror tail. Capping
    /// each at 256 KiB leaves enough room for every 16 KiB state section while keeping the full
    /// pasteboard artifact below 800 KiB even when every source is at its ceiling.
    public static let defaultLogByteLimit = 256 * 1_024
    /// Per-section ceiling for dynamic header collections. These collections are derived from
    /// user libraries and learned app state, so neither their item count nor one hostile entry may
    /// make a pasteboard report grow without bound.
    static let headerProjectionItemLimit = 64
    static let headerProjectionByteLimit = 16 * 1_024
    static let diagnosticLineByteLimit = 4 * 1_024

    struct HeaderProjection: Equatable {
        let retainedLines: [String]
        let observedCount: Int
        let retainedUTF8Bytes: Int
        let droppedCount: Int
        let itemLimit: Int
        let byteLimit: Int

        func summaryLine(label: String) -> String {
            "(\(label) projection — observed=\(observedCount); "
                + "retained=\(retainedLines.count)/\(itemLimit); "
                + "bytes=\(retainedUTF8Bytes)/\(byteLimit); dropped=\(droppedCount))"
        }
    }

    /// Streaming builder for dynamic diagnostic sections. It counts every source row while
    /// retaining only rows that fit both caps, so callers never have to allocate an unbounded
    /// intermediate `[String]` merely to truncate it later.
    struct HeaderProjectionBuilder {
        private let itemLimit: Int
        private let byteLimit: Int
        private var retainedLines: [String] = []
        private var retainedUTF8Bytes = 0
        private var observedCount = 0

        init(itemLimit: Int, byteLimit: Int) {
            self.itemLimit = max(0, itemLimit)
            self.byteLimit = max(0, byteLimit)
            retainedLines.reserveCapacity(min(self.itemLimit, 64))
        }

        mutating func observe(_ line: String) {
            if observedCount < Int.max { observedCount += 1 }
            guard retainedLines.count < itemLimit else { return }
            let separatorBytes = retainedLines.isEmpty ? 0 : 1
            let remaining = byteLimit - retainedUTF8Bytes
            guard separatorBytes <= remaining else { return }
            let lineBytes = line.utf8.count
            // A single externally-derived message must not consume an entire section or echo an
            // attacker-sized payload into a copied report. It remains represented by the
            // observed/dropped counters, so a capped sample is never presented as complete.
            guard lineBytes <= DiagnosticReport.diagnosticLineByteLimit else { return }
            guard lineBytes <= remaining - separatorBytes else { return }
            retainedLines.append(line)
            retainedUTF8Bytes += separatorBytes + lineBytes
        }

        /// `totalObservedCount` carries an upstream count when that boundary already selected a
        /// bounded subset (for example the AX verdict store). It may only increase the count this
        /// builder observed; retained/dropped therefore remain truthful under composition.
        func finish(totalObservedCount: Int? = nil) -> HeaderProjection {
            let total = max(observedCount, max(0, totalObservedCount ?? observedCount))
            return HeaderProjection(
                retainedLines: retainedLines,
                observedCount: total,
                retainedUTF8Bytes: retainedUTF8Bytes,
                droppedCount: total - retainedLines.count,
                itemLimit: itemLimit,
                byteLimit: byteLimit
            )
        }
    }

    /// Keeps the earliest fitting lines in source order. An oversized line is dropped rather than
    /// truncated mid-grapheme, and later small evidence can still be retained. `retainedUTF8Bytes`
    /// exactly matches the UTF-8 size of `retainedLines.joined(separator: "\n")`.
    static func boundedHeaderProjection(
        _ sourceLines: [String],
        itemLimit: Int = headerProjectionItemLimit,
        byteLimit: Int = headerProjectionByteLimit
    ) -> HeaderProjection {
        var builder = HeaderProjectionBuilder(itemLimit: itemLimit, byteLimit: byteLimit)
        for line in sourceLines {
            builder.observe(line)
        }
        return builder.finish()
    }

    enum LogCollectionScope: Equatable {
        case systemFilteredToCurrentProcess
        case currentProcess

        var diagnosticLabel: String {
            switch self {
            case .systemFilteredToCurrentProcess:
                return "system/current-process-filtered"
            case .currentProcess:
                return "current-process"
            }
        }
    }

    /// Content-bearing fields stay internal to the bounded collector and are never included in
    /// its metadata line. This seam lets tests model system-store entries from parallel launches.
    struct LogRecord: Equatable {
        let date: Date
        let category: String
        let level: String
        let message: String
        let processIdentifier: pid_t
        let process: String
    }

    struct LogCollection: Equatable {
        let lines: [String]
        let scope: LogCollectionScope
        let observedEntryCount: Int
        let retainedEntryCount: Int
        let retainedUTF8Bytes: Int
        let entryLimit: Int
        let byteLimit: Int
        let excludedForeignProcessCount: Int
        let oversizedEntryCount: Int
        let evictedEntryCount: Int
    }

    /// Voice permission/configuration evidence. It contains no audio, transcript, API key, or
    /// provider response — only the state needed to explain why dictation could not start.
    public struct VoicePermissionContext: Equatable {
        public enum GeminiCredentialState: String, Equatable {
            case configured
            case missing
            case unavailable
        }

        public var microphone: DurableVoiceCapture.MicrophonePermissionStatus
        public var speechRecognition: SpeechAuthorization.Status
        public var selectedEngine: TranscriptionEngine
        public var effectiveEngine: TranscriptionEngine
        public var realTimeTypingEnabled: Bool
        public var cloudAudioConsentGranted: Bool
        public var geminiCredentialState: GeminiCredentialState

        public init(
            microphone: DurableVoiceCapture.MicrophonePermissionStatus,
            speechRecognition: SpeechAuthorization.Status,
            selectedEngine: TranscriptionEngine,
            effectiveEngine: TranscriptionEngine,
            realTimeTypingEnabled: Bool,
            cloudAudioConsentGranted: Bool,
            geminiCredentialState: GeminiCredentialState
        ) {
            self.microphone = microphone
            self.speechRecognition = speechRecognition
            self.selectedEngine = selectedEngine
            self.effectiveEngine = effectiveEngine
            self.realTimeTypingEnabled = realTimeTypingEnabled
            self.cloudAudioConsentGranted = cloudAudioConsentGranted
            self.geminiCredentialState = geminiCredentialState
        }
    }

    /// Static / live state captured for the dump header (no OSLog I/O).
    public struct Context: Equatable {
        public var generatedAt: Date
        public var bundleID: String
        public var appPath: String
        public var executablePath: String
        public var cdHash: String?
        public var designatedRequirement: String?
        public var snapshot: PermissionSnapshot
        public var tapRunning: Bool
        public var engineEnabled: Bool
        public var secureInputActive: Bool
        public var displayStatus: String
        public var lastInjectOutcome: String?
        public var frontmostAppName: String?
        public var frontmostBundleID: String?
        public var frontmostPID: pid_t?
        public var mutedApps: [String]
        public var expandGate: ExpandGateSnapshot
        /// Gate / frontmost captured when the last refuse was recorded (may differ from live gate).
        public var expandGateAtLastRefuse: PermissionCoordinator.InjectRefuseProvenance?
        public var siblingPaths: [String]
        public var macOSVersion: String
        /// Read live from `CFBundleShortVersionString` / `CFBundleVersion`, which
        /// `Scripts/package-app.sh` now stamps from `git describe` (§7.6).
        public var appVersion: String?
        /// Stamped build toolchain info from DTXcode, DTSDKName, etc.
        public var buildToolchain: String?
        /// §2.10: `EventTapEngine.TapDisableCounters.summaryLine` — `byTimeout` means our
        /// callback blew the system budget and is the most likely silent field failure.
        public var tapDisableSummary: String?
        /// §3.2: `PermissionCoordinator.injectTelemetrySummaryLines()` — per-bundle inject
        /// success ratios plus the refuse-reason histogram.
        public var injectTelemetryLines: [String]
        /// §3.9: triggers longer than the match buffer, which can never fire.
        public var overlongTriggerLines: [String]
        /// Per-app AX-write verdicts learned by `AXWriteCapabilityStore`. Answers "why does
        /// expansion behave differently in this one app?": a `falseSuccess` app is one where
        /// AX reported a write it did not perform, so DevType permanently pastes there instead.
        /// Bundle IDs only — never a snippet, never typed text.
        public var axWriteVerdictLines: [String]
        /// Prefix-debounce hold lifecycle counters (`EventTapEngine.prefixDebounceDiagnostics()`).
        /// `races-absorbed` counts debounce timers that lost to a keystroke at the deadline —
        /// each one used to be a possible double expansion.
        public var prefixDebounceSummary: String?
        /// On-device AI state + recent transform outcomes. An AI failure was previously
        /// invisible here, so a guardrail refusal left no trace in the artifact people
        /// actually paste. Contains no user text — see `AIDiagnosticsStore`.
        public var aiLines: [String]
        /// Secret/Touch ID state. Counts and capabilities only — never a value, never a title.
        public var secretLines: [String]
        /// Whether abbreviation matching is suspended, and by whom.
        ///
        /// A suspension leaked by a panel stops **every** typed expansion while leaving the tap
        /// running, the engine enabled and all permissions granted — the exact report that
        /// motivated this field, in which nothing looked wrong and nothing expanded.
        public var matchingSuspensionLines: [String]
        /// Triggers that matched and were then discarded before reaching the inject pipeline.
        /// Invisible in every per-app delivery counter, because no inject was ever attempted.
        public var matchDropLines: [String]
        /// Snippets that can never respond to typing at all (secret, overlong, shadowed).
        public var unreachableSnippetLines: [String]
        /// §9.1: `DevLogMirror` — engine log lines retained in-process past what OSLog still
        /// holds. This is the section that answers "it broke yesterday in Slack" at all.
        public var logMirrorLines: [String]
        /// Always-on finite-vocabulary voice outcomes. Unlike the opt-in trace, these lines can
        /// never contain transcript/audio/provider error payloads.
        public var voiceTerminalLines: [String]
        public var voicePermissions: VoicePermissionContext?
        /// Bounded health of the persisted Recent Activity envelope. This distinguishes a truly
        /// empty history from one that could not be read or written.
        public var activityHistoryLine: String?
        /// Opt-in debug-trace state and its latest typed write result. The type can represent only
        /// finite status values, so a configured path or trace payload cannot enter the report.
        public var debugTraceHealth: DebugTrace.Health?

        /// Production capture fills these at the subsystem boundary. Public/test callers keep the
        /// array initializer and are projected during formatting for source compatibility.
        var mutedAppsProjection: HeaderProjection?
        var siblingPathsProjection: HeaderProjection?
        var injectTelemetryProjection: HeaderProjection?
        var matchingSuspensionProjection: HeaderProjection?
        var overlongTriggerProjection: HeaderProjection?
        var axWriteVerdictProjection: HeaderProjection?
        var unreachableSnippetProjection: HeaderProjection?

        public init(
            generatedAt: Date = Date(),
            bundleID: String,
            appPath: String,
            executablePath: String,
            cdHash: String?,
            designatedRequirement: String?,
            snapshot: PermissionSnapshot,
            tapRunning: Bool,
            engineEnabled: Bool,
            secureInputActive: Bool,
            displayStatus: String,
            lastInjectOutcome: String?,
            frontmostAppName: String?,
            frontmostBundleID: String?,
            frontmostPID: pid_t?,
            mutedApps: [String],
            expandGate: ExpandGateSnapshot,
            expandGateAtLastRefuse: PermissionCoordinator.InjectRefuseProvenance? = nil,
            siblingPaths: [String],
            macOSVersion: String,
            appVersion: String?,
            buildToolchain: String? = nil,
            tapDisableSummary: String? = nil,
            injectTelemetryLines: [String] = [],
            overlongTriggerLines: [String] = [],
            axWriteVerdictLines: [String] = [],
            aiLines: [String] = [],
            secretLines: [String] = [],
            prefixDebounceSummary: String? = nil,
            matchingSuspensionLines: [String] = [],
            matchDropLines: [String] = [],
            unreachableSnippetLines: [String] = [],
            logMirrorLines: [String] = [],
            voiceTerminalLines: [String] = [],
            voicePermissions: VoicePermissionContext? = nil,
            activityHistoryLine: String? = nil,
            debugTraceHealth: DebugTrace.Health? = nil
        ) {
            self.generatedAt = generatedAt
            self.bundleID = bundleID
            self.appPath = appPath
            self.executablePath = executablePath
            self.cdHash = cdHash
            self.designatedRequirement = designatedRequirement
            self.snapshot = snapshot
            self.tapRunning = tapRunning
            self.engineEnabled = engineEnabled
            self.secureInputActive = secureInputActive
            self.displayStatus = displayStatus
            self.lastInjectOutcome = lastInjectOutcome
            self.frontmostAppName = frontmostAppName
            self.frontmostBundleID = frontmostBundleID
            self.frontmostPID = frontmostPID
            self.mutedApps = mutedApps
            self.expandGate = expandGate
            self.expandGateAtLastRefuse = expandGateAtLastRefuse
            self.siblingPaths = siblingPaths
            self.macOSVersion = macOSVersion
            self.appVersion = appVersion
            self.buildToolchain = buildToolchain
            self.tapDisableSummary = tapDisableSummary
            self.injectTelemetryLines = injectTelemetryLines
            self.overlongTriggerLines = overlongTriggerLines
            self.axWriteVerdictLines = axWriteVerdictLines
            self.aiLines = aiLines
            self.secretLines = secretLines
            self.prefixDebounceSummary = prefixDebounceSummary
            self.matchingSuspensionLines = matchingSuspensionLines
            self.matchDropLines = matchDropLines
            self.unreachableSnippetLines = unreachableSnippetLines
            self.logMirrorLines = logMirrorLines
            self.voiceTerminalLines = voiceTerminalLines
            self.voicePermissions = voicePermissions
            self.activityHistoryLine = activityHistoryLine
            self.debugTraceHealth = debugTraceHealth
            self.mutedAppsProjection = nil
            self.siblingPathsProjection = nil
            self.injectTelemetryProjection = nil
            self.matchingSuspensionProjection = nil
            self.overlongTriggerProjection = nil
            self.axWriteVerdictProjection = nil
            self.unreachableSnippetProjection = nil
        }
    }

    /// Observability for the expand gate (does not use fail-closed defaults for diagnostics).
    public struct ExpandGateSnapshot: Equatable {
        public var canUseAX: Bool
        public var axTrusted: Bool
        public var focusedAvailable: Bool
        public var isSecureField: Bool?
        public var hasIMEMarkedText: Bool?
        public var shouldBlockExpand: Bool
        public var blockReason: String

        public init(
            canUseAX: Bool,
            axTrusted: Bool,
            focusedAvailable: Bool,
            isSecureField: Bool?,
            hasIMEMarkedText: Bool?,
            shouldBlockExpand: Bool,
            blockReason: String
        ) {
            self.canUseAX = canUseAX
            self.axTrusted = axTrusted
            self.focusedAvailable = focusedAvailable
            self.isSecureField = isSecureField
            self.hasIMEMarkedText = hasIMEMarkedText
            self.shouldBlockExpand = shouldBlockExpand
            self.blockReason = blockReason
        }
    }

    /// Capture live app/engine state for the dump header.
    public static func captureContext(
        identity: ProcessIdentity = .shared,
        cdHash: String? = nil,
        snapshot: PermissionSnapshot? = nil,
        mutedApps: [String]? = nil
    ) -> Context {
        let resolvedSnapshot = snapshot ?? PermissionProbe().snapshot()
        let tapRunning = EventTapEngine.shared.isTapRunning
        let secure = EventTapEngine.shared.isSecureInputActive
        let enabled = EventTapEngine.shared.isEnabled
        let display = EngineDisplayStatus.resolve(
            snapshot: resolvedSnapshot,
            isTapRunning: tapRunning,
            isEnabled: enabled,
            isSecureInputActive: secure
        )
        let front = NSWorkspace.shared.frontmostApplication
        let outcome: String?
        if let recorded = PermissionCoordinator.shared.lastRecordedInjectOutcome {
            switch recorded {
            case .succeeded: outcome = "succeeded"
            case .postedUnverified: outcome = "postedUnverified"
            case .refused(let reason): outcome = "refused — \(reason)"
            case .degradedAXOnly: outcome = "degradedAXOnly"
            case .failedSilent: outcome = "failedSilent"
            }
        } else {
            outcome = nil
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let appVersion: String?
        if let version, let build {
            appVersion = "\(version) (\(build))"
        } else {
            appVersion = version ?? build
        }
        let dtXcode = Bundle.main.infoDictionary?["DTXcode"] as? String
        let dtSDKName = Bundle.main.infoDictionary?["DTSDKName"] as? String
        let buildToolchain = formatToolchain(xcode: dtXcode, sdk: dtSDKName)
        // One Keychain read feeds both fields. Two independent reads could report a provider
        // fallback and a credential state that never coexisted if Keychain availability changed
        // between calls, and would needlessly double a security-service operation.
        let selectedVoiceEngine = VoicePreferences.transcriptionEngine
        let geminiReadState = GeminiAPIKeyStore.readState()
        let effectiveVoiceEngine = VoicePreferences.effectiveEngine(
            preferred: selectedVoiceEngine,
            keyState: geminiReadState
        )
        let overlongTriggerProjection = EventTapEngine.shared.overlongTriggerDiagnosticProjection()
        let axWriteVerdictProjection = captureAXWriteVerdictProjection()
        let unreachableSnippetProjection = EventTapEngine.shared.silentNoExpandDiagnosticProjection()
        let mutedAppsProjection: HeaderProjection
        let capturedMutedApps: [String]
        if let mutedApps {
            var builder = HeaderProjectionBuilder(
                itemLimit: headerProjectionItemLimit,
                byteLimit: headerProjectionByteLimit
            )
            for identifier in mutedApps {
                builder.observe(
                    DiagnosticPrivacy.boundedIdentifier(
                        identifier,
                        label: "mutedApp",
                        domain: "muted-app"
                    )
                )
            }
            mutedAppsProjection = builder.finish()
            capturedMutedApps = mutedAppsProjection.retainedLines
        } else {
            mutedAppsProjection = captureMutedAppProjection()
            capturedMutedApps = mutedAppsProjection.retainedLines
        }
        let siblingPathsProjection = captureSiblingPathProjection(identity: identity)
        let injectTelemetryProjection = PermissionCoordinator.shared
            .injectTelemetryDiagnosticProjection()
        let matchingSuspensionProjection = EventTapEngine.shared
            .matchingSuspensionDiagnosticProjection()
        let activityStore = ActivityHistoryStore.shared
        let activityHistoryLine = activityHistoryDiagnosticLine(
            health: activityStore.persistenceHealth,
            retainedEventCount: activityStore.recentEvents(limit: ActivityHistoryStore.maxEvents).count
        )

        var context = Context(
            bundleID: identity.bundleIdentifier,
            appPath: identity.bundlePath,
            executablePath: identity.executablePath,
            cdHash: cdHash ?? identity.cachedCodeDirectoryHash,
            designatedRequirement: identity.cachedDesignatedRequirementString,
            snapshot: resolvedSnapshot,
            tapRunning: tapRunning,
            engineEnabled: enabled,
            secureInputActive: secure,
            displayStatus: display.menuTitle,
            lastInjectOutcome: outcome,
            frontmostAppName: front?.localizedName,
            frontmostBundleID: front?.bundleIdentifier,
            frontmostPID: front?.processIdentifier,
            mutedApps: capturedMutedApps,
            expandGate: AXContextChecker.shared.expandGateSnapshot(
                canUseAX: resolvedSnapshot.canUseAX,
                canPostEvents: resolvedSnapshot.canPostEvents
            ),
            expandGateAtLastRefuse: PermissionCoordinator.shared.lastRecordedInjectRefuseProvenance,
            siblingPaths: siblingPathsProjection.retainedLines,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion,
            buildToolchain: buildToolchain,
            // §2.10 / §3.2 / §3.9: three diagnostics the engine already maintains and
            // that nothing used to print. Every one of them answers a question a bug
            // report cannot otherwise answer.
            tapDisableSummary: EventTapEngine.shared.tapDisableCounters.summaryLine,
            injectTelemetryLines: injectTelemetryProjection.retainedLines,
            overlongTriggerLines: overlongTriggerProjection.retainedLines,
            axWriteVerdictLines: axWriteVerdictProjection.retainedLines,
            aiLines: captureAILines(),
            secretLines: captureSecretLines(
                pendingMigrationCount: { SecretStore.shared.snippetIDsPendingMigration().count },
                pendingCleanupCount: { SnippetStore.shared.pendingSecretCleanupCount },
                keychainLocked: { SecretStore.shared.isKeychainLocked() },
                storageDescription: { SecretStore.shared.storageDescription() }
            ),
            prefixDebounceSummary: EventTapEngine.shared.prefixDebounceDiagnostics(),
            // The three that answer "I typed my trigger and nothing happened" — the one question
            // the report could not previously answer at all. Each covers a distinct way an
            // expansion dies before it becomes an inject, and therefore before any counter above
            // this line can see it.
            matchingSuspensionLines: matchingSuspensionProjection.retainedLines,
            matchDropLines: EventTapEngine.shared.matchDropDiagnostics(),
            unreachableSnippetLines: unreachableSnippetProjection.retainedLines,
            logMirrorLines: Self.mirrorReportLines(),
            voiceTerminalLines: VoiceDiagnosticsRecorder.shared.terminalReportLines(),
            voicePermissions: VoicePermissionContext(
                microphone: DurableVoiceCapture.microphonePermissionStatus(),
                speechRecognition: SpeechAuthorization.status(),
                selectedEngine: selectedVoiceEngine,
                effectiveEngine: effectiveVoiceEngine,
                realTimeTypingEnabled: VoicePreferences.isRealTimeTypingEnabled,
                cloudAudioConsentGranted: VoicePreferences.hasCloudAudioConsent,
                geminiCredentialState: geminiCredentialState(for: geminiReadState)
            ),
            activityHistoryLine: activityHistoryLine,
            debugTraceHealth: DebugTrace.health
        )
        context.mutedAppsProjection = mutedAppsProjection
        context.siblingPathsProjection = siblingPathsProjection
        context.injectTelemetryProjection = injectTelemetryProjection
        context.matchingSuspensionProjection = matchingSuspensionProjection
        context.overlongTriggerProjection = overlongTriggerProjection
        context.axWriteVerdictProjection = axWriteVerdictProjection
        context.unreachableSnippetProjection = unreachableSnippetProjection
        return context
    }

    static func geminiCredentialState(
        for readState: GeminiAPIKeyStore.ReadState
    ) -> VoicePermissionContext.GeminiCredentialState {
        switch readState {
        case .available: return .configured
        case .missing: return .missing
        case .unavailable: return .unavailable
        }
    }

    /// Newest mirrored lines for the report, with a truncation notice when the ring holds more
    /// than the report carries. Lines and retention counters come from one atomic snapshot.
    static func mirrorReportLines(
        limit: Int = defaultMirrorLineLimit,
        mirror: DevLogMirror = .shared
    ) -> [String] {
        let snapshot = mirror.snapshot(limit: limit)
        let health = snapshot.health
        let total = health.retainedEntryCount
        let healthLine: String? = if health.consecutiveFailures > 0 {
            "(mirror unavailable — OSLog fetch failed \(health.consecutiveFailures) time(s)"
                + (health.lastFailureKind.map { " (\($0))" } ?? "")
                + "; cursor retained for retry)"
        } else if health.hasSuccessfulPoll {
            "(mirror healthy — last fetch succeeded; no matching entries)"
        } else {
            "(mirror pending — no successful OSLog fetch yet)"
        }
        let retentionLine = "(mirror retention — observed=\(health.observedEntryCount); "
            + "retained=\(health.retainedEntryCount)/\(health.entryCapacity); "
            + "bytes=\(health.retainedUTF8Bytes)/\(health.byteCapacity); "
            + "oversized=\(health.oversizedEntryCount); evicted=\(health.evictedEntryCount))"
        guard total > 0 else { return [healthLine!, retentionLine] }
        var lines = snapshot.lines
        if total > lines.count {
            lines.insert(
                "(oldest \(total - lines.count) mirrored line(s) truncated — full ring lives in process memory)",
                at: 0
            )
        }
        if health.consecutiveFailures > 0, let healthLine {
            lines.insert(healthLine, at: 0)
        }
        lines.insert(retentionLine, at: health.consecutiveFailures > 0 ? 1 : 0)
        return lines
    }

    /// On-device AI state for the report. Keeps every FoundationModels detail behind
    /// `AITextTransformSupport` / `AILocaleSupport`, which already compile on macOS 14.
    ///
    /// Never includes the user's selected text or any model output — only the transform
    /// kind and Apple's own diagnostic string.
    /// Secret / Touch ID state for the report.
    ///
    /// Counts and capabilities only. Not a title, not a trigger, and obviously not a value — the
    /// report is pasted into chat windows and issue trackers, and a list of what someone keeps
    /// passwords for is itself worth protecting.
    static func captureSecretLines(
        snippets: [SnippetModel]? = nil,
        availability: BiometricGate.Availability? = nil,
        defaults: UserDefaults = .standard,
        accessDiagnostics: SecretAccessDiagnostics = .shared,
        pendingMigrationCount: (() -> Int)? = nil,
        pendingCleanupCount: (() -> Int)? = nil,
        keychainLocked: (() -> Bool)? = nil,
        storageDescription: (() -> String)? = nil
    ) -> [String] {
        let all = snippets ?? SnippetStore.shared.loadSnippets()
        let resolved = availability ?? BiometricGate.shared.availability()
        let gateOn = SecretPreferences.requireBiometry(defaults: defaults, availability: resolved)

        let capability: String
        switch resolved {
        case .biometry(let name):
            let safeName = DiagnosticPrivacy.boundedIdentifier(
                name,
                label: "biometryName",
                domain: "biometry-display-name"
            )
            capability = "available (\(safeName))"
        case .passwordOnly: capability = "password only — no enrolled biometrics on this Mac"
        case .unavailable: capability = "unavailable — no login password or biometrics set"
        }

        let safeStorageDescription = DiagnosticPrivacy.boundedIdentifier(
            (storageDescription ?? { "in-memory" })(),
            label: "secretStorage",
            domain: "secret-storage-description"
        )
        let trailLines = accessDiagnostics.trail().suffix(16).map {
            let safeTrail = DiagnosticPrivacy.boundedIdentifier(
                $0,
                label: "secretTrail",
                domain: "secret-access-trail"
            )
            return "  trail: \(safeTrail)"
        }

        return [
            "Secret snippets: \(all.lazy.filter { $0.isSecret }.count)",
            "Biometry: \(capability)",
            "Require authentication: \(gateOn ? "on" : "off")",
            "Reuse window: \(Int(BiometricGate.reuseWindow))s",
            "Clipboard auto-clear: \(Int(SecretClipboard.defaultClearAfter))s",
            // §8.10: tells "keychain asked for the login password" apart from every other
            // prompt in a report. "healed partition" here means the self-signed-cert rebuild
            // problem fired and was absorbed silently, exactly as designed.
            "Keychain last read: \(accessDiagnostics.lastRead().label)",
            // Hermetic by default (tests must never touch the live keychain); the production
            // capture site below injects the real closures.
            "Secrets pending migration: \((pendingMigrationCount ?? { 0 })())",
            // A failed destructive sweep remains retryable; count only, never item identity.
            "Secret cleanup pending: \((pendingCleanupCount ?? { 0 })())",
            // A locked keychain fails every decrypt while metadata still answers — without
            // this line those reports read exactly like "the secret vanished".
            "Keychain: \((keychainLocked ?? { false })() ? "LOCKED" : "unlocked")",
            // §8.11: where the values actually live, and whether the master key is intact.
            "Storage: \(safeStorageDescription)",
        ]
        // The step trail: every fetch/heal/migrate with its OSStatus, accounts aliased to
        // "item A/B/…" — the exact sequence that produced whatever the user just saw.
        + trailLines
    }

    /// Production report path: the store counts all learned entries while selecting only the
    /// bounded lexicographic prefix. Formatting then applies the independent byte cap and carries
    /// the store's complete observed count into the rendered projection metadata.
    static func captureAXWriteVerdictProjection(
        store: AXWriteCapabilityStore = .shared,
        itemLimit: Int = headerProjectionItemLimit,
        byteLimit: Int = headerProjectionByteLimit
    ) -> HeaderProjection {
        let source = store.learnedVerdictProjection(limit: max(0, itemLimit))
        var builder = HeaderProjectionBuilder(itemLimit: itemLimit, byteLimit: byteLimit)
        for entry in source.entries {
            builder.observe(axWriteVerdictLine(entry))
        }
        return builder.finish(totalObservedCount: source.observedCount)
    }

    /// Production report path for the persisted per-app mute set. The store selects a bounded,
    /// stable prefix under its lock and supplies the complete observed count; report formatting
    /// applies the independent byte limit without ever copying or sorting the full set.
    static func captureMutedAppProjection(
        store: AppMuteStore = .shared,
        itemLimit: Int = headerProjectionItemLimit,
        byteLimit: Int = headerProjectionByteLimit
    ) -> HeaderProjection {
        let source = store.mutedIdentifierProjection(limit: max(0, itemLimit))
        var builder = HeaderProjectionBuilder(itemLimit: itemLimit, byteLimit: byteLimit)
        for identifier in source.identifiers {
            builder.observe(
                DiagnosticPrivacy.boundedIdentifier(
                    identifier,
                    label: "mutedApp",
                    domain: "muted-app"
                )
            )
        }
        return builder.finish(totalObservedCount: source.observedCount)
    }

    /// Running applications are an OS-owned finite snapshot, but their paths are still external
    /// strings. Bound the diagnostic projection before it enters `Context`, retaining ordinary
    /// paths verbatim and converting only oversized outliers to content-free shape metadata.
    static func captureSiblingPathProjection(
        identity: ProcessIdentity,
        itemLimit: Int = headerProjectionItemLimit,
        byteLimit: Int = headerProjectionByteLimit
    ) -> HeaderProjection {
        identity.siblingPathDiagnosticProjection(
            itemLimit: itemLimit,
            byteLimit: byteLimit
        )
    }

    private static func axWriteVerdictLine(
        _ entry: (key: String, verdict: AXWriteCapabilityStore.Verdict)
    ) -> String {
        let label: String
        switch entry.verdict {
        case .trusted: label = "trusted (AX writes verified)"
        case .falseSuccess: label = "falseSuccess (AX lied — pasting instead)"
        case .unknown: label = "unknown"
        }
        let key = DiagnosticPrivacy.boundedIdentifier(
            entry.key,
            label: "axKey",
            domain: "ax-write-key"
        )
        return "\(key): \(label)"
    }

    static func captureAILines(
        store: AIDiagnosticsStore = .shared,
        enabled: Bool = AIPreferences.isEnabled
    ) -> [String] {
        let availability: String
        switch AITextTransformSupport.availability {
        case .available:
            availability = "available"
        case .unavailable(let reason):
            switch reason {
            case .unsupportedOS:
                availability = "unavailable — unsupportedOS (needs macOS 26+ with FoundationModels)"
            case .buildLacksFoundationModels:
                availability = "unavailable — buildLacksFoundationModels (app compiled without FoundationModels)"
            case .deviceNotEligible:
                availability = "unavailable — deviceNotEligible"
            case .appleIntelligenceNotEnabled:
                availability = "unavailable — appleIntelligenceNotEnabled"
            case .modelNotReady:
                availability = "unavailable — modelNotReady (assets still downloading)"
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // `disabledReason` returns a localized string when the current locale is unsupported.
        let localeNote = AILocaleSupport.disabledReason().map { "unsupported — \($0)" }
            ?? "supported (\(Locale.current.identifier))"
        return store.diagnosticLines(
            enabled: enabled,
            availability: availability,
            localeNote: localeNote,
            iso: iso
        )
    }

    /// Finite persistence health for Recent Activity. `PersistenceHealth` intentionally exposes a
    /// string for source compatibility, so normalize it back through the closed failure enum before
    /// rendering; a malformed file path or NSError payload can never escape via this line.
    static func activityHistoryDiagnosticLine(
        health: ActivityHistoryStore.PersistenceHealth,
        retainedEventCount: Int
    ) -> String {
        let retained = min(ActivityHistoryStore.maxEvents, max(0, retainedEventCount))
        guard let rawFailure = health.lastFailureKind else {
            return "Activity history: healthy retained=\(retained)/\(ActivityHistoryStore.maxEvents)"
        }
        let failure = ActivityHistoryStore.PersistenceFailureKind(rawValue: rawFailure)?.rawValue
            ?? "unknown"
        return "Activity history: unavailable failure=\(failure) "
            + "retained=\(retained)/\(ActivityHistoryStore.maxEvents)"
    }

    public static func formatToolchain(xcode: String?, sdk: String?) -> String {
        let xcodeStr: String
        if let xcode, !xcode.isEmpty {
            if xcode.count == 4, let num = Int(xcode) {
                let major = num / 100
                let minor = (num % 100) / 10
                let patch = num % 10
                if patch > 0 {
                    xcodeStr = "\(major).\(minor).\(patch)"
                } else {
                    xcodeStr = "\(major).\(minor)"
                }
            } else {
                xcodeStr = xcode
            }
        } else {
            xcodeStr = "unknown"
        }
        let sdkStr = (sdk?.isEmpty == false) ? sdk! : "unknown"
        return "Built with Xcode \(xcodeStr) · SDK \(sdkStr)"
    }

    public static func formatHeader(_ context: Context) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = [
            "=== DevType Diagnostic Report ===",
            "Generated: \(iso.string(from: context.generatedAt))",
            "macOS: \(boundedScalar(context.macOSVersion, label: "macOS", domain: "macos-version"))",
            "App version: \(boundedOptionalScalar(context.appVersion, label: "appVersion", domain: "app-version", nilValue: "unknown"))",
            context.buildToolchain ?? formatToolchain(xcode: nil, sdk: nil),
            "",
            "-- Identity --",
            "Bundle ID: \(boundedScalar(context.bundleID, label: "bundleID", domain: "process-bundle-id"))",
            "App path: \(boundedScalar(context.appPath, label: "appPath", domain: "process-app-path"))",
            "Executable: \(boundedScalar(context.executablePath, label: "executable", domain: "process-executable-path"))",
            "CDHash: \(boundedOptionalScalar(context.cdHash, label: "cdHash", domain: "process-cdhash", nilValue: "(unknown)"))",
            "Requirement: \(boundedOptionalScalar(context.designatedRequirement, label: "requirement", domain: "process-requirement", nilValue: "(unknown)"))",
            "",
            "-- Capabilities --",
            "LIVE: \(PermissionCopy.livePreflightSummary(snapshot: context.snapshot))",
            "Tap running: \(context.tapRunning)",
            "Engine enabled: \(context.engineEnabled)",
            "Secure Input active: \(context.secureInputActive)",
            "Display status: \(boundedScalar(context.displayStatus, label: "displayStatus", domain: "display-status"))",
            "Last inject: \(boundedOptionalScalar(context.lastInjectOutcome, label: "injectOutcome", domain: "inject-outcome", nilValue: "(none)"))",
        ]
        lines.append("")
        lines.append("-- Voice permissions --")
        if let voice = context.voicePermissions {
            lines.append("Microphone: \(voice.microphone.rawValue)")
            lines.append("Speech Recognition: \(voice.speechRecognition.diagnosticLabel)")
            lines.append("Selected engine: \(voice.selectedEngine.rawValue)")
            lines.append("Effective engine: \(voice.effectiveEngine.rawValue)")
            lines.append("Real-time typing: \(voice.realTimeTypingEnabled ? "on" : "off")")
            lines.append("Cloud audio consent: \(voice.cloudAudioConsentGranted ? "granted" : "not granted")")
            lines.append("Gemini credential: \(voice.geminiCredentialState.rawValue)")
        } else {
            lines.append("(not captured)")
        }
        lines.append("")
        lines.append("-- Voice terminal diagnostics (content-free) --")
        if context.voiceTerminalLines.isEmpty {
            lines.append("(not captured)")
        } else {
            appendBoundedHeaderProjection(
                boundedHeaderProjection(context.voiceTerminalLines),
                label: "voice-terminal-lines",
                emptyLine: "(not captured)",
                to: &lines
            )
        }
        lines.append("")
        lines.append("-- Activity history persistence --")
        lines.append(boundedOptionalScalar(
            context.activityHistoryLine,
            label: "activityHistory",
            domain: "activity-history-health",
            nilValue: "(not captured)"
        ))
        lines.append("")
        lines.append("-- Opt-in debug trace --")
        lines.append(context.debugTraceHealth?.diagnosticLine ?? "(not captured)")
        lines.append("")
        lines.append("-- Expand gate (live) --")
        lines.append(contentsOf: formatExpandGateLines(context.expandGate))
        lines.append("")
        lines.append("-- Expand gate at last refuse --")
        if let refuse = context.expandGateAtLastRefuse {
            lines.append("Refused at: \(iso.string(from: refuse.refusedAt))")
            lines.append("Refuse reason: \(boundedScalar(refuse.reason, label: "refuseReason", domain: "inject-refuse-reason"))")
            lines.append("Frontmost name: \(boundedOptionalScalar(refuse.frontmostAppName, label: "frontmostName", domain: "frontmost-name", nilValue: "(none)"))")
            lines.append("Frontmost bundle ID: \(boundedOptionalScalar(refuse.frontmostBundleID, label: "frontmostBundleID", domain: "frontmost-bundle-id", nilValue: "(none)"))")
            lines.append("Frontmost PID: \(refuse.frontmostPID.map(String.init) ?? "(none)")")
            lines.append("AX error: \(refuse.axErrorRawValue.map(String.init) ?? "(none)")")
            if let gate = refuse.gateSnapshot {
                lines.append(contentsOf: formatExpandGateLines(gate))
            } else {
                lines.append("(gate snapshot not recorded)")
            }
        } else {
            lines.append("(none)")
        }
        lines.append(contentsOf: [
            "",
            "-- Frontmost --",
            "Name: \(boundedOptionalScalar(context.frontmostAppName, label: "frontmostName", domain: "frontmost-name", nilValue: "(none)"))",
            "Bundle ID: \(boundedOptionalScalar(context.frontmostBundleID, label: "frontmostBundleID", domain: "frontmost-bundle-id", nilValue: "(none)"))",
            "PID: \(context.frontmostPID.map(String.init) ?? "(none)")",
            "",
            "-- Muted apps --",
        ])
        appendBoundedHeaderProjection(
            context.mutedAppsProjection
                ?? boundedHeaderProjection(context.mutedApps),
            label: "muted-apps",
            emptyLine: "(none)",
            to: &lines
        )
        lines.append("")
        lines.append("-- Sibling DevType paths --")
        appendBoundedHeaderProjection(
            context.siblingPathsProjection
                ?? boundedHeaderProjection(context.siblingPaths),
            label: "sibling-paths",
            emptyLine: "(none)",
            to: &lines
        )

        // §2.10: tap-disable-by-timeout is the most likely silent field failure and used
        // to produce one indistinguishable `notice` line with no counter.
        lines.append("")
        lines.append("-- Event tap health --")
        lines.append(boundedOptionalScalar(
            context.tapDisableSummary,
            label: "tapHealth",
            domain: "tap-health",
            nilValue: "(not captured)"
        ))

        // §3.2: five outcomes and a dozen refuse reasons used to collapse into one
        // overwritten variable.
        lines.append("")
        lines.append("-- Inject telemetry --")
        if context.injectTelemetryLines.isEmpty {
            lines.append("(none)")
        } else {
            appendBoundedHeaderProjection(
                context.injectTelemetryProjection
                    ?? boundedHeaderProjection(context.injectTelemetryLines),
                label: "inject-telemetry",
                emptyLine: "(none)",
                to: &lines
            )
        }

        // An AI guardrail refusal used to leave no trace here at all, so the one artifact
        // people paste when the model refuses said nothing about the model.
        lines.append("")
        lines.append("-- On-device AI --")
        if context.aiLines.isEmpty {
            lines.append("(not captured)")
        } else {
            appendBoundedHeaderProjection(
                boundedHeaderProjection(context.aiLines),
                label: "ai-diagnostics",
                emptyLine: "(not captured)",
                to: &lines
            )
        }

        // Prefix-debounce lifecycle. "races-absorbed" is the line to read when a report claims
        // a double expansion: each count is a timer/keystroke collision the coordinator resolved.
        // "It asks for my password instead of Touch ID" is not diagnosable from anything else in
        // this report: whether the gate is on, and whether this Mac can do biometry at all, are
        // the two facts that separate a policy bug from a Mac with no enrolled finger.
        lines.append("")
        lines.append("-- Secrets --")
        if context.secretLines.isEmpty {
            lines.append("(not captured)")
        } else {
            appendBoundedHeaderProjection(
                boundedHeaderProjection(context.secretLines),
                label: "secret-diagnostics",
                emptyLine: "(not captured)",
                to: &lines
            )
        }

        lines.append("")
        lines.append("-- Prefix debounce --")
        lines.append(boundedOptionalScalar(
            context.prefixDebounceSummary,
            label: "prefixDebounce",
            domain: "prefix-debounce",
            nilValue: "(not captured)"
        ))

        // The expansion-outage section. Everything above describes expansions that *happened*;
        // these three describe the ways one never starts. A report where every counter looks
        // healthy and the user is still typing triggers into the void is answered here or nowhere.
        lines.append("")
        lines.append("-- Matching state --")
        if context.matchingSuspensionLines.isEmpty {
            lines.append("(not captured)")
        } else {
            appendBoundedHeaderProjection(
                context.matchingSuspensionProjection
                    ?? boundedHeaderProjection(context.matchingSuspensionLines),
                label: "matching-suspensions",
                emptyLine: "(not captured)",
                to: &lines
            )
        }

        lines.append("")
        lines.append("-- Matched but not expanded --")
        if context.matchDropLines.isEmpty {
            lines.append("(not captured)")
        } else {
            appendBoundedHeaderProjection(
                boundedHeaderProjection(context.matchDropLines),
                label: "match-drops",
                emptyLine: "(not captured)",
                to: &lines
            )
        }

        lines.append("")
        lines.append("-- Snippets that never expand by typing --")
        appendBoundedHeaderProjection(
            context.unreachableSnippetProjection
                ?? boundedHeaderProjection(context.unreachableSnippetLines),
            label: "silent-no-expand",
            emptyLine: "(none)",
            to: &lines
        )

        // §3.9: triggers past the 64-character match buffer can never fire and nothing said so.
        lines.append("")
        lines.append("-- Overlong triggers --")
        appendBoundedHeaderProjection(
            context.overlongTriggerProjection
                ?? boundedHeaderProjection(context.overlongTriggerLines),
            label: "overlong-triggers",
            emptyLine: "(none)",
            to: &lines
        )

        lines.append("")
        lines.append("-- Learned AX write verdicts (per app) --")
        appendBoundedHeaderProjection(
            context.axWriteVerdictProjection
                ?? boundedHeaderProjection(context.axWriteVerdictLines),
            label: "ax-write-verdicts",
            emptyLine: "(none learned yet)",
            to: &lines
        )

        // §9.1: the mirror's own section. OSLog's direct fetch above is bounded by what logd
        // still holds; these lines were captured into process memory precisely so a report
        // generated after that window still shows what happened, in which app, at which level.
        lines.append("")
        lines.append("-- In-process log mirror (retained beyond OSLog) --")
        if context.logMirrorLines.isEmpty {
            lines.append("(mirror empty — not started or nothing logged yet)")
        } else {
            appendBoundedHeaderProjection(
                boundedHeaderProjection(
                    context.logMirrorLines,
                    itemLimit: defaultMirrorLineLimit + 4,
                    byteLimit: defaultLogByteLimit
                ),
                label: "log-mirror-lines",
                emptyLine: "(mirror empty — not started or nothing logged yet)",
                to: &lines
            )
        }

        return lines.joined(separator: "\n")
    }

    private static func appendBoundedHeaderProjection(
        _ projection: HeaderProjection,
        label: String,
        emptyLine: String,
        to reportLines: inout [String]
    ) {
        reportLines.append(projection.summaryLine(label: label))
        if projection.retainedLines.isEmpty {
            reportLines.append(emptyLine)
        } else {
            reportLines.append(contentsOf: projection.retainedLines)
        }
    }

    private static func formatExpandGateLines(_ gate: ExpandGateSnapshot) -> [String] {
        [
            "canUseAX: \(gate.canUseAX)",
            "AX trusted: \(gate.axTrusted)",
            "Focused element: \(gate.focusedAvailable ? "available" : "missing")",
            "Secure field: \(optionalBool(gate.isSecureField))",
            "IME marked text: \(optionalBool(gate.hasIMEMarkedText))",
            "Should block expand: \(gate.shouldBlockExpand)",
            "Block reason: \(boundedScalar(gate.blockReason, label: "blockReason", domain: "expand-gate-reason"))",
        ]
    }

    public static func formatFullReport(context: Context, logLines: [String]) -> String {
        var parts = [formatHeader(context), "", "-- Recent OSLog (subsystem \(DevTypeLog.subsystem)) --"]
        if logLines.isEmpty {
            parts.append("(no recent entries — OSLogStore empty or unavailable)")
        } else {
            let projection = boundedHeaderProjection(
                logLines,
                itemLimit: defaultLogLineLimit + 1,
                byteLimit: defaultLogByteLimit
            )
            parts.append(projection.summaryLine(label: "recent-oslog-lines"))
            parts.append(contentsOf: projection.retainedLines)
        }
        parts.append("")
        parts.append("=== End DevType Diagnostic Report ===")
        return parts.joined(separator: "\n")
    }

    /// Fetch recent unified-log lines for this process / DevType subsystem.
    ///
    /// The window keeps the *most recent* `limit` lines, not the first `limit` the store happens
    /// to enumerate: OSLogStore iterates oldest-first, so an early `break` at the limit kept the
    /// quiet minutes from half an hour ago and cut exactly the seconds around the incident the
    /// report exists to explain.
    ///
    /// Scope: the system-wide store is tried first, but subsystem equality is not process
    /// identity. Every enumerated log is therefore required to match both this executable's
    /// process name and PID before it can enter the bounded tail. Some hosts refuse system scope;
    /// that fallback is explicitly reported as current-process scope. We intentionally do not
    /// claim prior-launch coverage: parallel launches and PID reuse cannot be attributed safely.
    public static func fetchRecentLogLines(
        lookback: TimeInterval = defaultLogLookback,
        limit: Int = defaultLogLineLimit,
        byteLimit: Int = defaultLogByteLimit
    ) -> [String] {
        let selection: LogStoreSelection
        do {
            selection = try makeLogStoreSelection(preferSystemScope: true)
        } catch {
            return [osLogFailureLine(error)]
        }
        do {
            let startDate = Date().addingTimeInterval(-lookback)
            let position = selection.store.position(date: startDate)
            let predicate = NSPredicate(format: "subsystem == %@", DevTypeLog.subsystem)
            let entries = try selection.store.getEntries(at: position, matching: predicate)
            var accumulator = LogCollectionAccumulator(
                limit: limit,
                byteLimit: byteLimit,
                scope: selection.scope,
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                currentProcessNames: currentProcessNames()
            )
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                accumulator.observe(
                    LogRecord(
                        date: log.date,
                        category: log.category,
                        level: levelLabel(log.level),
                        message: log.composedMessage,
                        processIdentifier: log.processIdentifier,
                        process: log.process
                    )
                )
            }
            return reportLines(for: accumulator.result)
        } catch {
            return [osLogFailureLine(error)]
        }
    }

    private struct LogStoreSelection {
        let store: OSLogStore
        let scope: LogCollectionScope
    }

    /// Store construction with fallback. The selection used by report generation carries the
    /// actual scope so a fallback can never silently masquerade as a system-store read.
    private static func makeLogStoreSelection(preferSystemScope: Bool) throws -> LogStoreSelection {
        if preferSystemScope {
            do {
                return LogStoreSelection(
                    store: try OSLogStore(scope: .system),
                    scope: .systemFilteredToCurrentProcess
                )
            } catch {
                let failureKind = String(reflecting: type(of: error))
                DevTypeLog.app.notice(
                    "[Diagnostics] system-wide OSLogStore unavailable (\(failureKind, privacy: .public)) — falling back to current-process scope"
                )
            }
        }
        return LogStoreSelection(
            store: try OSLogStore(scope: .currentProcessIdentifier),
            scope: .currentProcess
        )
    }

    /// Compatibility/test seam for callers that only need a store. Report generation uses the
    /// selection above so it retains scope truthfulness.
    static func makeLogStore(preferSystemScope: Bool) throws -> OSLogStore {
        try makeLogStoreSelection(preferSystemScope: preferSystemScope).store
    }

    static func collectRecentLogLines<S: Sequence>(
        _ records: S,
        limit: Int,
        byteLimit: Int,
        scope: LogCollectionScope,
        currentProcessIdentifier: pid_t,
        currentProcessNames: Set<String>
    ) -> LogCollection where S.Element == LogRecord {
        var accumulator = LogCollectionAccumulator(
            limit: limit,
            byteLimit: byteLimit,
            scope: scope,
            currentProcessIdentifier: currentProcessIdentifier,
            currentProcessNames: currentProcessNames
        )
        for record in records {
            accumulator.observe(record)
        }
        return accumulator.result
    }

    static func reportLines(for collection: LogCollection) -> [String] {
        let metadata = "(OSLog retention — scope=\(collection.scope.diagnosticLabel); "
            + "observed=\(collection.observedEntryCount); "
            + "retained=\(collection.retainedEntryCount)/\(collection.entryLimit); "
            + "bytes=\(collection.retainedUTF8Bytes)/\(collection.byteLimit); "
            + "excluded-foreign=\(collection.excludedForeignProcessCount); "
            + "oversized=\(collection.oversizedEntryCount); "
            + "evicted=\(collection.evictedEntryCount))"
        return [metadata] + collection.lines
    }

    private struct LogCollectionAccumulator {
        private let scope: LogCollectionScope
        private let currentProcessIdentifier: pid_t
        private let currentProcessNames: Set<String>
        private var tail: BoundedUTF8Tail<String>
        private var observedEntryCount = 0
        private var excludedForeignProcessCount = 0

        init(
            limit: Int,
            byteLimit: Int,
            scope: LogCollectionScope,
            currentProcessIdentifier: pid_t,
            currentProcessNames: Set<String>
        ) {
            self.scope = scope
            self.currentProcessIdentifier = currentProcessIdentifier
            self.currentProcessNames = currentProcessNames
            self.tail = BoundedUTF8Tail(
                countLimit: limit,
                byteLimit: byteLimit
            )
        }

        mutating func observe(_ record: LogRecord) {
            observedEntryCount = Saturating.adding(observedEntryCount, 1)
            let nameMatches = currentProcessNames.contains(record.process)
            guard record.processIdentifier == currentProcessIdentifier, nameMatches else {
                excludedForeignProcessCount = Saturating.adding(excludedForeignProcessCount, 1)
                return
            }

            let line = "\(Self.timestampFormatter.string(from: record.date)) "
                + "[\(record.category)] \(record.level) \(record.message)"
            _ = tail.append(line, utf8ByteCount: line.utf8.count + 1)
        }

        var result: LogCollection {
            let statistics = tail.statistics
            return LogCollection(
                lines: tail.values,
                scope: scope,
                observedEntryCount: observedEntryCount,
                retainedEntryCount: statistics.retainedCount,
                retainedUTF8Bytes: statistics.retainedUTF8Bytes,
                entryLimit: tail.countLimit,
                byteLimit: tail.byteLimit,
                excludedForeignProcessCount: excludedForeignProcessCount,
                oversizedEntryCount: statistics.oversizedCount,
                evictedEntryCount: statistics.evictedCount
            )
        }

        private static let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }

    private static func currentProcessNames() -> Set<String> {
        Set(
            [
                ProcessInfo.processInfo.processName,
                Bundle.main.executableURL?.lastPathComponent,
            ].compactMap { name in
                guard let name, !name.isEmpty else { return nil }
                return name
            }
        )
    }

    static func osLogFailureLine(_ error: Error) -> String {
        "(OSLogStore unavailable — \(String(reflecting: type(of: error))))"
    }

    /// Newest-last window over an oldest-first enumeration: keep the tail when the session
    /// produced more than `limit` lines. Pure for tests.
    public static func keepingMostRecent(_ lines: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        guard lines.count > limit else { return lines }
        return Array(lines.suffix(limit))
    }

    /// Build the full report on a background queue, then deliver on the main queue.
    public static func buildAsync(
        cdHash: String? = nil,
        lookback: TimeInterval = defaultLogLookback,
        limit: Int = defaultLogLineLimit,
        completion: @escaping (String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let context = captureContext(cdHash: cdHash)
            let logs = fetchRecentLogLines(lookback: lookback, limit: limit)
            let report = formatFullReport(context: context, logLines: logs)
            DispatchQueue.main.async {
                completion(report)
            }
        }
    }

    /// Copy text to the general pasteboard as a plain string.
    @discardableResult
    public static func copyToPasteboard(_ text: String) -> Bool {
        PasteboardBroker.shared.writeUserClipboardString(text)
    }

    private static func optionalBool(_ value: Bool?) -> String {
        guard let value else { return "(n/a — no focus)" }
        return value ? "yes" : "no"
    }

    private static func boundedScalar(
        _ value: String,
        label: String,
        domain: String
    ) -> String {
        DiagnosticPrivacy.boundedIdentifier(value, label: label, domain: domain)
    }

    private static func boundedOptionalScalar(
        _ value: String?,
        label: String,
        domain: String,
        nilValue: String
    ) -> String {
        guard let value else { return nilValue }
        return boundedScalar(value, label: label, domain: domain)
    }

    private static func levelLabel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "undef"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "level"
        }
    }
}
