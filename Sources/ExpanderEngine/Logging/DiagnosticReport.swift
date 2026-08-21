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
        /// §2.10: `EventTapEngine.TapDisableCounters.summaryLine` — `byTimeout` means our
        /// callback blew the system budget and is the most likely silent field failure.
        public var tapDisableSummary: String?
        /// §3.2: `PermissionCoordinator.injectTelemetrySummaryLines()` — per-bundle inject
        /// success ratios plus the refuse-reason histogram.
        public var injectTelemetryLines: [String]
        /// §3.9: triggers longer than the match buffer, which can never fire.
        public var overlongTriggerLines: [String]
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
            tapDisableSummary: String? = nil,
            injectTelemetryLines: [String] = [],
            overlongTriggerLines: [String] = [],
            aiLines: [String] = [],
            secretLines: [String] = [],
            prefixDebounceSummary: String? = nil,
            matchingSuspensionLines: [String] = [],
            matchDropLines: [String] = [],
            unreachableSnippetLines: [String] = [],
            logMirrorLines: [String] = []
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
            self.tapDisableSummary = tapDisableSummary
            self.injectTelemetryLines = injectTelemetryLines
            self.overlongTriggerLines = overlongTriggerLines
            self.aiLines = aiLines
            self.secretLines = secretLines
            self.prefixDebounceSummary = prefixDebounceSummary
            self.matchingSuspensionLines = matchingSuspensionLines
            self.matchDropLines = matchDropLines
            self.unreachableSnippetLines = unreachableSnippetLines
            self.logMirrorLines = logMirrorLines
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

        return Context(
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
            mutedApps: mutedApps ?? AppMuteStore.shared.allMuted(),
            expandGate: AXContextChecker.shared.expandGateSnapshot(
                canUseAX: resolvedSnapshot.canUseAX,
                canPostEvents: resolvedSnapshot.canPostEvents
            ),
            expandGateAtLastRefuse: PermissionCoordinator.shared.lastRecordedInjectRefuseProvenance,
            siblingPaths: identity.siblingPaths(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion,
            // §2.10 / §3.2 / §3.9: three diagnostics the engine already maintains and
            // that nothing used to print. Every one of them answers a question a bug
            // report cannot otherwise answer.
            tapDisableSummary: EventTapEngine.shared.tapDisableCounters.summaryLine,
            injectTelemetryLines: PermissionCoordinator.shared.injectTelemetrySummaryLines(),
            overlongTriggerLines: EventTapEngine.shared.overlongTriggerDiagnostics(),
            aiLines: captureAILines(),
            secretLines: captureSecretLines(
                pendingMigrationCount: { SecretStore.shared.snippetIDsPendingMigration().count },
                keychainLocked: { SecretStore.shared.isKeychainLocked() },
                storageDescription: { SecretStore.shared.storageDescription() }
            ),
            prefixDebounceSummary: EventTapEngine.shared.prefixDebounceDiagnostics(),
            // The three that answer "I typed my trigger and nothing happened" — the one question
            // the report could not previously answer at all. Each covers a distinct way an
            // expansion dies before it becomes an inject, and therefore before any counter above
            // this line can see it.
            matchingSuspensionLines: EventTapEngine.shared.matchingSuspensionDiagnostics(),
            matchDropLines: EventTapEngine.shared.matchDropDiagnostics(),
            unreachableSnippetLines: EventTapEngine.shared.silentNoExpandDiagnostics(),
            logMirrorLines: Self.mirrorReportLines()
        )
    }

    /// Newest mirrored lines for the report, with a truncation notice when the ring holds more
    /// than the report carries. The count/read pair is not atomic; a line landing between the
    /// two only skews the notice by one, which is fine for diagnostics.
    static func mirrorReportLines(
        limit: Int = defaultMirrorLineLimit,
        mirror: DevLogMirror = .shared
    ) -> [String] {
        let total = mirror.count
        guard total > 0 else { return [] }
        var lines = mirror.recentLines(limit: limit)
        if total > lines.count {
            lines.insert(
                "(oldest \(total - lines.count) mirrored line(s) truncated — full ring lives in process memory)",
                at: 0
            )
        }
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
        keychainLocked: (() -> Bool)? = nil,
        storageDescription: (() -> String)? = nil
    ) -> [String] {
        let all = snippets ?? SnippetStore.shared.loadSnippets()
        let resolved = availability ?? BiometricGate.shared.availability()
        let gateOn = SecretPreferences.requireBiometry(defaults: defaults, availability: resolved)

        let capability: String
        switch resolved {
        case .biometry(let name): capability = "available (\(name))"
        case .passwordOnly: capability = "password only — no enrolled biometrics on this Mac"
        case .unavailable: capability = "unavailable — no login password or biometrics set"
        }

        return [
            "Secret snippets: \(all.filter { $0.isSecret }.count)",
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
            // A locked keychain fails every decrypt while metadata still answers — without
            // this line those reports read exactly like "the secret vanished".
            "Keychain: \((keychainLocked ?? { false })() ? "LOCKED" : "unlocked")",
            // §8.11: where the values actually live, and whether the master key is intact.
            "Storage: \((storageDescription ?? { "in-memory" })())",
        ]
        // The step trail: every fetch/heal/migrate with its OSStatus, accounts aliased to
        // "item A/B/…" — the exact sequence that produced whatever the user just saw.
        + accessDiagnostics.trail().suffix(16).map { "  trail: \($0)" }
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

    public static func formatHeader(_ context: Context) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = [
            "=== DevType Diagnostic Report ===",
            "Generated: \(iso.string(from: context.generatedAt))",
            "macOS: \(context.macOSVersion)",
            "App version: \(context.appVersion ?? "unknown")",
            "",
            "-- Identity --",
            "Bundle ID: \(context.bundleID)",
            "App path: \(context.appPath)",
            "Executable: \(context.executablePath)",
            "CDHash: \(context.cdHash ?? "(unknown)")",
            "Requirement: \(context.designatedRequirement ?? "(unknown)")",
            "",
            "-- Capabilities --",
            "LIVE: \(PermissionCopy.livePreflightSummary(snapshot: context.snapshot))",
            "Tap running: \(context.tapRunning)",
            "Engine enabled: \(context.engineEnabled)",
            "Secure Input active: \(context.secureInputActive)",
            "Display status: \(context.displayStatus)",
            "Last inject: \(context.lastInjectOutcome ?? "(none)")",
            "",
            "-- Expand gate (live) --",
        ]
        lines.append(contentsOf: formatExpandGateLines(context.expandGate))
        lines.append("")
        lines.append("-- Expand gate at last refuse --")
        if let refuse = context.expandGateAtLastRefuse {
            lines.append("Refused at: \(iso.string(from: refuse.refusedAt))")
            lines.append("Refuse reason: \(refuse.reason)")
            lines.append("Frontmost name: \(refuse.frontmostAppName ?? "(none)")")
            lines.append("Frontmost bundle ID: \(refuse.frontmostBundleID ?? "(none)")")
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
            "Name: \(context.frontmostAppName ?? "(none)")",
            "Bundle ID: \(context.frontmostBundleID ?? "(none)")",
            "PID: \(context.frontmostPID.map(String.init) ?? "(none)")",
            "",
            "-- Muted apps --",
            context.mutedApps.isEmpty ? "(none)" : context.mutedApps.sorted().joined(separator: "\n"),
            "",
            "-- Sibling DevType paths --",
            context.siblingPaths.isEmpty ? "(none)" : context.siblingPaths.joined(separator: "\n"),
        ])

        // §2.10: tap-disable-by-timeout is the most likely silent field failure and used
        // to produce one indistinguishable `notice` line with no counter.
        lines.append("")
        lines.append("-- Event tap health --")
        lines.append(context.tapDisableSummary ?? "(not captured)")

        // §3.2: five outcomes and a dozen refuse reasons used to collapse into one
        // overwritten variable.
        lines.append("")
        lines.append("-- Inject telemetry --")
        if context.injectTelemetryLines.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: context.injectTelemetryLines)
        }

        // An AI guardrail refusal used to leave no trace here at all, so the one artifact
        // people paste when the model refuses said nothing about the model.
        lines.append("")
        lines.append("-- On-device AI --")
        if context.aiLines.isEmpty {
            lines.append("(not captured)")
        } else {
            lines.append(contentsOf: context.aiLines)
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
            lines.append(contentsOf: context.secretLines)
        }

        lines.append("")
        lines.append("-- Prefix debounce --")
        lines.append(context.prefixDebounceSummary ?? "(not captured)")

        // The expansion-outage section. Everything above describes expansions that *happened*;
        // these three describe the ways one never starts. A report where every counter looks
        // healthy and the user is still typing triggers into the void is answered here or nowhere.
        lines.append("")
        lines.append("-- Matching state --")
        if context.matchingSuspensionLines.isEmpty {
            lines.append("(not captured)")
        } else {
            lines.append(contentsOf: context.matchingSuspensionLines)
        }

        lines.append("")
        lines.append("-- Matched but not expanded --")
        if context.matchDropLines.isEmpty {
            lines.append("(not captured)")
        } else {
            lines.append(contentsOf: context.matchDropLines)
        }

        lines.append("")
        lines.append("-- Snippets that never expand by typing --")
        if context.unreachableSnippetLines.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: context.unreachableSnippetLines)
        }

        // §3.9: triggers past the 64-character match buffer can never fire and nothing said so.
        lines.append("")
        lines.append("-- Overlong triggers --")
        if context.overlongTriggerLines.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: context.overlongTriggerLines)
        }

        // §9.1: the mirror's own section. OSLog's direct fetch above is bounded by what logd
        // still holds; these lines were captured into process memory precisely so a report
        // generated after that window still shows what happened, in which app, at which level.
        lines.append("")
        lines.append("-- In-process log mirror (retained beyond OSLog) --")
        if context.logMirrorLines.isEmpty {
            lines.append("(mirror empty — not started or nothing logged yet)")
        } else {
            lines.append(contentsOf: context.logMirrorLines)
        }

        return lines.joined(separator: "\n")
    }

    private static func formatExpandGateLines(_ gate: ExpandGateSnapshot) -> [String] {
        [
            "canUseAX: \(gate.canUseAX)",
            "AX trusted: \(gate.axTrusted)",
            "Focused element: \(gate.focusedAvailable ? "available" : "missing")",
            "Secure field: \(optionalBool(gate.isSecureField))",
            "IME marked text: \(optionalBool(gate.hasIMEMarkedText))",
            "Should block expand: \(gate.shouldBlockExpand)",
            "Block reason: \(gate.blockReason)",
        ]
    }

    public static func formatFullReport(context: Context, logLines: [String]) -> String {
        var parts = [formatHeader(context), "", "-- Recent OSLog (subsystem \(DevTypeLog.subsystem)) --"]
        if logLines.isEmpty {
            parts.append("(no recent entries — OSLogStore empty or unavailable)")
        } else {
            parts.append(contentsOf: logLines)
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
    /// Scope: the system-wide store is tried first so persisted entries from *previous*
    /// launches of the app are included — "it broke this morning" must not be answerable
    /// only while the process that saw it is still alive. Some hosts refuse that scope;
    /// the current-process store is the fallback. Entries are filtered to the DevType
    /// subsystem either way, so nothing from other processes' logs is ever rendered.
    public static func fetchRecentLogLines(
        lookback: TimeInterval = defaultLogLookback,
        limit: Int = defaultLogLineLimit
    ) -> [String] {
        let store: OSLogStore
        do {
            store = try makeLogStore(preferSystemScope: true)
        } catch {
            return ["(OSLogStore error: \(error.localizedDescription))"]
        }
        do {
            let startDate = Date().addingTimeInterval(-lookback)
            let position = store.position(date: startDate)
            let predicate = NSPredicate(format: "subsystem == %@", DevTypeLog.subsystem)
            let entries = try store.getEntries(at: position, matching: predicate)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var lines: [String] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                let level = levelLabel(log.level)
                lines.append(
                    "\(formatter.string(from: log.date)) [\(log.category)] \(level) \(log.composedMessage)"
                )
            }
            return keepingMostRecent(lines, limit: limit)
        } catch {
            return ["(OSLogStore error: \(error.localizedDescription))"]
        }
    }

    /// Store construction with fallback. Internal so tests can pin the ordering.
    static func makeLogStore(preferSystemScope: Bool) throws -> OSLogStore {
        if preferSystemScope {
            do {
                return try OSLogStore(scope: .system)
            } catch {
                DevTypeLog.app.notice(
                    "[Diagnostics] system-wide OSLogStore unavailable (\(error.localizedDescription, privacy: .public)) — falling back to current-process scope"
                )
            }
        }
        return try OSLogStore(scope: .currentProcessIdentifier)
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func optionalBool(_ value: Bool?) -> String {
        guard let value else { return "(n/a — no focus)" }
        return value ? "yes" : "no"
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
