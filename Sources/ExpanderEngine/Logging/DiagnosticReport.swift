import AppKit
import Foundation
import OSLog

/// Builds a pasteboard-friendly diagnostic dump for Permission Recovery support.
public enum DiagnosticReport {
    public static let defaultLogLookback: TimeInterval = 30 * 60
    public static let defaultLogLineLimit = 200

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
            prefixDebounceSummary: String? = nil
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
            secretLines: captureSecretLines(),
            prefixDebounceSummary: EventTapEngine.shared.prefixDebounceDiagnostics()
        )
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
        accessDiagnostics: SecretAccessDiagnostics = .shared
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
        ]
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

        // §3.9: triggers past the 64-character match buffer can never fire and nothing said so.
        lines.append("")
        lines.append("-- Overlong triggers --")
        if context.overlongTriggerLines.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: context.overlongTriggerLines)
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
    public static func fetchRecentLogLines(
        lookback: TimeInterval = defaultLogLookback,
        limit: Int = defaultLogLineLimit
    ) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
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
                if lines.count >= limit { break }
            }
            // Prefer newest-last for reading; OSLogStore usually returns oldest-first.
            return lines
        } catch {
            return ["(OSLogStore error: \(error.localizedDescription))"]
        }
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
