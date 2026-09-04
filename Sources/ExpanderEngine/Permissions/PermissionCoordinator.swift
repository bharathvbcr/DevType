import AppKit
import Foundation

/// Capability-specific relaunch nudges. A successful live preflight clears only the capability
/// that caused the nudge, so an Input Monitoring refusal cannot get stuck behind AX state.
/// Lock-owned relaunch latch shared by permission request completions, observer callbacks, and
/// status rendering. Those paths deliberately run on different queues; keeping synchronization
/// beside the state makes every caller safe without exposing the coordinator's broader outcome
/// lock or requiring a fragile external lock-taking convention.
final class PermissionRelaunchState: @unchecked Sendable {
    private let lock = UnfairLock()
    private var accessibilityRequestStillDenied = false
    private var inputMonitoringRequestStillDenied = false

    func noteRequestResult(for kind: PermissionKind, preflightGranted: Bool) {
        lock.withLock {
            switch kind {
            case .accessibility:
                accessibilityRequestStillDenied = !preflightGranted
            case .inputMonitoring:
                inputMonitoringRequestStillDenied = !preflightGranted
            case .postEvent, .microphone, .speechRecognition:
                break
            }
        }
    }

    func observe(_ snapshot: PermissionSnapshot) {
        lock.withLock {
            if snapshot.canUseAX { accessibilityRequestStillDenied = false }
            if snapshot.canListenTap { inputMonitoringRequestStillDenied = false }
        }
    }

    func recommendsRelaunch(for snapshot: PermissionSnapshot) -> Bool {
        lock.withLock {
            (accessibilityRequestStillDenied && !snapshot.canUseAX)
                || (inputMonitoringRequestStillDenied && !snapshot.canListenTap)
        }
    }
}

/// Owns the coordinator callback lifecycle. Status can be emitted from the main, inject, and
/// processing queues, while `stop()` runs during app termination. Keeping admission, generation,
/// deduplication, and invocation under one recursive lock prevents a copied callback from starting
/// after `stop()` returns without forbidding a callback from re-entering coordinator lifecycle APIs.
final class PermissionCallbackState: @unchecked Sendable {
    typealias StatusCallback = (PermissionCoordinator.Status) -> Void
    typealias IdentityCallback = (String?) -> Void

    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var onStatus: StatusCallback?
    private var onTapStartFailed: (() -> Void)?
    private var onIdentityResolved: IdentityCallback?
    private var lastStatus: PermissionCoordinator.Status?
    private var tapStartFailureDelivered = false

    @discardableResult
    func start(
        onStatusChanged: @escaping StatusCallback,
        onTapStartFailed: (() -> Void)?,
        onIdentityResolved: IdentityCallback?
    ) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        if generation == 0 { generation = 1 }
        activeGeneration = generation
        onStatus = onStatusChanged
        self.onTapStartFailed = onTapStartFailed
        self.onIdentityResolved = onIdentityResolved
        lastStatus = nil
        tapStartFailureDelivered = false
        return generation
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        if generation == 0 { generation = 1 }
        activeGeneration = nil
        onStatus = nil
        onTapStartFailed = nil
        onIdentityResolved = nil
        lastStatus = nil
        tapStartFailureDelivered = false
    }

    var lastEmittedStatus: PermissionCoordinator.Status? {
        lock.lock()
        defer { lock.unlock() }
        return lastStatus
    }

    /// Returns whether this active lifecycle observed a changed status. The callback still runs for
    /// duplicate statuses, preserving the coordinator's existing synchronous refresh contract.
    @discardableResult
    func deliverStatus(_ status: PermissionCoordinator.Status) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration != nil, let onStatus else { return false }
        let changed = status != lastStatus
        lastStatus = status
        onStatus(status)
        return changed
    }

    func deliverTapStartFailure() {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration != nil, !tapStartFailureDelivered else { return }
        tapStartFailureDelivered = true
        onTapStartFailed?()
    }

    func resetTapStartFailureEpisode() {
        lock.lock()
        defer { lock.unlock() }
        tapStartFailureDelivered = false
    }

    func deliverIdentity(_ hash: String?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation else { return }
        onIdentityResolved?(hash)
    }
}

/// Coordinates tap lifecycle (Listen + Accessibility for `.defaultTap`), inject degradation, and status emission.
public final class PermissionCoordinator {
    public static let shared = PermissionCoordinator()

    public struct Status: Equatable {
        public let snapshot: PermissionSnapshot
        public let tapRunning: Bool
        public let recommendsRelaunchForAX: Bool
        public let lastInjectOutcome: InjectOutcome?

        public init(
            snapshot: PermissionSnapshot,
            tapRunning: Bool,
            recommendsRelaunchForAX: Bool,
            lastInjectOutcome: InjectOutcome? = nil
        ) {
            self.snapshot = snapshot
            self.tapRunning = tapRunning
            self.recommendsRelaunchForAX = recommendsRelaunchForAX
            self.lastInjectOutcome = lastInjectOutcome
        }
    }

    public enum InjectOutcome: Equatable, Sendable {
        case succeeded
        case postedUnverified
        case refused(String)
        case degradedAXOnly
        case failedSilent

        /// Whether delivery was actually confirmed strongly enough for callers to treat the
        /// expansion as a success. A posted-but-unverified paste is deliberately excluded: it
        /// may have landed, but usage/recent-history side effects must not claim certainty the
        /// pipeline does not have.
        public var isConfirmedSuccess: Bool {
            switch self {
            case .succeeded, .degradedAXOnly:
                return true
            case .postedUnverified, .refused, .failedSilent:
                return false
            }
        }
    }

    /// Provenance captured at refuse time for diagnostics (distinct from a later live gate probe).
    public struct InjectRefuseProvenance: Equatable {
        public var refusedAt: Date
        public var reason: String
        public var gateSnapshot: DiagnosticReport.ExpandGateSnapshot?
        public var frontmostAppName: String?
        public var frontmostBundleID: String?
        public var frontmostPID: pid_t?
        public var axErrorRawValue: Int32?

        public init(
            refusedAt: Date = Date(),
            reason: String,
            gateSnapshot: DiagnosticReport.ExpandGateSnapshot? = nil,
            frontmostAppName: String? = nil,
            frontmostBundleID: String? = nil,
            frontmostPID: pid_t? = nil,
            axErrorRawValue: Int32? = nil
        ) {
            self.refusedAt = refusedAt
            self.reason = reason
            self.gateSnapshot = gateSnapshot
            self.frontmostAppName = frontmostAppName
            self.frontmostBundleID = frontmostBundleID
            self.frontmostPID = frontmostPID
            self.axErrorRawValue = axErrorRawValue
        }

        /// Capture frontmost + optional gate/focus error. Prefer calling on the main thread.
        public static func capture(
            reason: String,
            decision: AXContextChecker.ExpandGateDecision? = nil,
            refusedAt: Date = Date()
        ) -> InjectRefuseProvenance {
            let front = NSWorkspace.shared.frontmostApplication
            var axRaw: Int32?
            if let decision, case .axFailure(let error) = decision.focus {
                axRaw = error.rawValue
            }
            return InjectRefuseProvenance(
                refusedAt: refusedAt,
                reason: reason,
                gateSnapshot: decision?.snapshot,
                frontmostAppName: front?.localizedName,
                frontmostBundleID: front?.bundleIdentifier,
                frontmostPID: front?.processIdentifier,
                axErrorRawValue: axRaw
            )
        }
    }

    private let probe = PermissionProbe()
    private let observer = PermissionObserver.shared
    private let identity = ProcessIdentity.shared

    private let callbackState = PermissionCallbackState()
    private let relaunchState = PermissionRelaunchState()

    /// §1.11: `lastInjectOutcome` / `lastInjectRefuseProvenance` are written from `injectQueue`,
    /// `processingQueue` **and** main while `_cachedSnapshot` right beside them was carefully
    /// guarded. `InjectOutcome.refused(String)` carries a `String`, so a torn write is an
    /// over-release risk, not just a stale read. Both live behind `outcomeLock`; callback and
    /// last-emitted-status lifecycle lives atomically in `callbackState`.
    ///
    /// §2.4: `os_unfair_lock` (not `NSLock`) so the userInteractive tap callback reading
    /// `cachedSnapshot` cannot be blocked behind a utility-QoS writer without priority donation.
    private let outcomeLock = UnfairLock()
    private var _lastInjectOutcome: InjectOutcome?
    private var _lastInjectRefuseProvenance: InjectRefuseProvenance?

    private var axWasFalse = true

    /// Cached snapshot for the event-tap hot path (updated on observer ticks / refresh — never probe inside the CG callback).
    private let snapshotLock = UnfairLock()
    private var _cachedSnapshot: PermissionSnapshot?

    /// §3.2: bounded per-attempt inject telemetry. `lastInjectOutcome` is a single slot; this is
    /// the history that answers "does expansion work in Slack?".
    public let injectTelemetry = InjectTelemetryLog.shared

    public init() {}

    public var currentSnapshot: PermissionSnapshot {
        probe.snapshot()
    }

    /// Last observed snapshot for cheap tap-side reads. Falls back to a live probe if never cached.
    public var cachedSnapshot: PermissionSnapshot {
        snapshotLock.lock()
        let cached = _cachedSnapshot
        snapshotLock.unlock()
        return cached ?? probe.snapshot()
    }

    private func storeCachedSnapshot(_ snapshot: PermissionSnapshot) {
        snapshotLock.lock()
        _cachedSnapshot = snapshot
        snapshotLock.unlock()
    }

    public var lastRecordedInjectOutcome: InjectOutcome? {
        outcomeLock.withLock { _lastInjectOutcome }
    }

    /// Clears the last-outcome slot — the user acknowledged a failure by restarting the engine,
    /// and the status item must stop showing the urgent state for an attempt that is no longer
    /// pending anyone's attention. The refuse *provenance* is deliberately kept (it documents
    /// what happened for the diagnostic report), as is the telemetry ring.
    public func clearLastInjectOutcome() {
        outcomeLock.withLock { _lastInjectOutcome = nil }
    }

    /// Gate / frontmost / timestamp captured at the most recent refuse (not cleared on later success).
    public var lastRecordedInjectRefuseProvenance: InjectRefuseProvenance? {
        outcomeLock.withLock { _lastInjectRefuseProvenance }
    }

    private var lastEmittedStatus: Status? {
        callbackState.lastEmittedStatus
    }

    /// True when UI should prominently offer Relaunch (Settings flip may not apply until restart).
    public var recommendsRelaunch: Bool {
        let snapshot = lastEmittedStatus?.snapshot ?? cachedSnapshot
        return relaunchState.recommendsRelaunch(for: snapshot)
    }

    /// True when the last inject definitively failed — menu/Recovery should not stay quiet Active.
    /// `postedUnverified` is excluded: Cmd+V was sent and AX cannot confirm delivery (normal for
    /// Chrome/Electron/apps that hide AX values). It is informational only, not an urgent failure.
    public var hasUrgentInjectFailure: Bool {
        switch lastRecordedInjectOutcome {
        case .failedSilent:
            return true
        case .succeeded, .refused, .postedUnverified, .degradedAXOnly, .none:
            return false
        }
    }

    /// Threading contract: `onStatusChanged` fires synchronously on **whatever thread** drove the
    /// refresh — main, `injectQueue`, or `processingQueue` (inject outcomes record status from
    /// the injection path). Consumers must marshal to main themselves; the app delegate's
    /// handler funnels through `refreshStatusItemUI`, which already does. Emission is
    /// synchronous so status reads never lag a state transition they observed.
    public func start(
        onStatusChanged: @escaping (Status) -> Void,
        onTapStartFailed: (() -> Void)? = nil,
        onIdentityResolved: ((String?) -> Void)? = nil
    ) {
        let lifecycleGeneration = callbackState.start(
            onStatusChanged: onStatusChanged,
            onTapStartFailed: onTapStartFailed,
            onIdentityResolved: onIdentityResolved
        )
        identity.refreshCDHashAsync { [weak self] hash in
            DevTypeLog.identity.info(
                "[Identity] CDHash resolved=\(hash ?? "nil", privacy: .public) \(DevTypeLog.publicPathMetadata(ProcessIdentity.shared.bundlePath), privacy: .public)"
            )
            self?.callbackState.deliverIdentity(hash, generation: lifecycleGeneration)
        }

        DevTypeLog.permission.info(
            "[Permission] coordinator start identity bundleID=\(DevTypeLog.boundedPublicIdentifier(self.identity.bundleIdentifier, label: "bundleID"), privacy: .public) packaged=\(self.identity.isPackaged, privacy: .public) \(DevTypeLog.publicPathMetadata(self.identity.bundlePath), privacy: .public)"
        )
        if let unpackaged = ProcessIdentity.unpackagedBinaryWarning(bundlePath: identity.bundlePath) {
            _ = unpackaged
            DevTypeLog.identity.notice(
                "[Identity] unpackaged binary detected \(DevTypeLog.publicPathMetadata(self.identity.bundlePath), privacy: .public)"
            )
        }
        let siblings = identity.siblingPaths()
        if let dup = ProcessIdentity.duplicateProcessWarning(siblingPaths: siblings) {
            _ = dup
            DevTypeLog.identity.notice(
                "[Identity] other DevType processes detected count=\(siblings.count, privacy: .public)"
            )
        }

        // Prime tap BEFORE starting the observer so the first status emission cannot
        // race a Tap Failed flash (Listen+AX granted, tap not yet installed).
        let initial = probe.snapshot()
        storeCachedSnapshot(initial)
        DevTypeLog.permission.info(
            "[Permission] initial check \(DevTypeLog.snapshotSummary(initial), privacy: .public)"
        )
        applyTapLifecycle(for: initial, presentFailureAlert: true)

        observer.start { [weak self] snapshot in
            self?.handleSnapshotChange(snapshot)
        }
        emitStatus(snapshot: initial)
    }

    public func stop() {
        DevTypeLog.permission.info("[Permission] coordinator stop")
        // Revoke callback admission first. A callback already inside its synchronous invocation
        // finishes before this returns; observer/inject emissions arriving later see no lifecycle.
        callbackState.stop()
        observer.stop()
        SettingsDeepLinker.shared.cancelPendingOpen()
        snapshotLock.lock()
        _cachedSnapshot = nil
        snapshotLock.unlock()
    }

    public func cancelPendingWork() {
        SettingsDeepLinker.shared.cancelPendingOpen()
    }

    /// Re-evaluate tap + emit (e.g. after Request / Open / relaunch UI).
    public func refresh(presentTapFailureAlert: Bool = false) {
        observer.refreshNow()
        let snapshot = probe.snapshot()
        let tapBefore = EventTapEngine.shared.isTapRunning
        applyTapLifecycle(for: snapshot, presentFailureAlert: presentTapFailureAlert)
        let tapAfter = EventTapEngine.shared.isTapRunning
        let changed = lastEmittedStatus.map {
            $0.snapshot != snapshot || $0.tapRunning != tapAfter
        } ?? true
        if changed || presentTapFailureAlert || tapBefore != tapAfter {
            DevTypeLog.permission.info(
                "[Permission] refresh check \(DevTypeLog.snapshotSummary(snapshot), privacy: .public) presentTapFailureAlert=\(presentTapFailureAlert, privacy: .public)"
            )
        } else {
            DevTypeLog.permission.debug(
                "[Permission] refresh check unchanged \(DevTypeLog.snapshotSummary(snapshot), privacy: .public)"
            )
        }
        emitStatus(snapshot: snapshot)
    }

    /// Immediate probe + tap start after Request or when returning from System Settings.
    public func handleApplicationDidBecomeActive() {
        DevTypeLog.permission.info(
            "[Permission] applicationDidBecomeActive — immediate refresh + tap start attempt"
        )
        refresh(presentTapFailureAlert: true)
    }

    public func recordInjectOutcome(
        _ outcome: InjectOutcome,
        refuseContext: InjectRefuseProvenance? = nil
    ) {
        recordInjectOutcome(outcome, refuseContext: refuseContext, path: nil)
    }

    /// §3.2: same as `recordInjectOutcome(_:refuseContext:)` plus the inject path taken
    /// ("ax", "axPlusHID", "clipboard", "hid", …) for the telemetry ring. Added as an overload
    /// rather than a defaulted parameter so existing call sites are untouched.
    public func recordInjectOutcome(
        _ outcome: InjectOutcome,
        refuseContext: InjectRefuseProvenance?,
        path: String?
    ) {
        var reason: String? = nil
        var provenance: InjectRefuseProvenance? = nil
        let recordedOutcome: InjectOutcome

        switch outcome {
        case .succeeded:
            recordedOutcome = .succeeded
            DevTypeLog.inject.info("[Inject] outcome=succeeded")
        case .postedUnverified:
            recordedOutcome = .postedUnverified
            DevTypeLog.inject.notice("[Inject] outcome=postedUnverified")
        case .refused(let refuseReason):
            let safeReason = Self.sanitizedRefusalReason(refuseReason, path: path)
            reason = safeReason
            var safeProvenance = refuseContext
                ?? InjectRefuseProvenance.capture(reason: safeReason)
            safeProvenance.reason = safeReason
            provenance = safeProvenance
            recordedOutcome = .refused(safeReason)
            DevTypeLog.inject.notice("[Inject] outcome=refused reason=\(safeReason, privacy: .public)")
        case .degradedAXOnly:
            recordedOutcome = .degradedAXOnly
            DevTypeLog.inject.info("[Inject] outcome=degradedAXOnly (Post Events missing)")
        case .failedSilent:
            recordedOutcome = .failedSilent
            DevTypeLog.inject.error("[Inject] outcome=failedSilent")
        }

        outcomeLock.lock()
        _lastInjectOutcome = recordedOutcome
        if let provenance {
            _lastInjectRefuseProvenance = provenance
        }
        outcomeLock.unlock()

        // §3.2: prefer the bundle captured at refuse time; a later frontmost read can race the
        // app switch that caused the refuse in the first place.
        // §2.3: read the engine's cached frontmost bundle ID rather than touching NSWorkspace —
        // this can be called from `injectQueue` / `processingQueue`, not just main.
        var bundleID: String? = EventTapEngine.shared.cachedFrontmostBundleID
        if let captured = provenance?.frontmostBundleID {
            bundleID = captured
        } else if let captured = refuseContext?.frontmostBundleID {
            bundleID = captured
        }
        injectTelemetry.record(
            outcome: recordedOutcome,
            bundleID: bundleID,
            path: path,
            reason: reason
        )

        emitStatus(snapshot: probe.snapshot())
    }

    /// Reduces free-form refusal prose to a finite, actionable vocabulary before it reaches
    /// public OSLog, the telemetry ring, status UI, or a copied diagnostic report. `path` is the
    /// pipeline's internal branch identifier; raw details can contain attachment paths or text
    /// mismatch evidence and therefore must never survive this boundary.
    static func sanitizedRefusalReason(_ reason: String, path: String?) -> String {
        switch path {
        case "imagePaste":
            return reason.contains("missing or unreadable")
                ? "Image attachment missing or unreadable"
                : "Image paste unavailable"
        case "fillInRequired":
            return "Fill-in values are required before insertion"
        case "shellNoPostEvents":
            return "Post Events permission is required for multi-line shell insertion"
        case "eraseContextChanged":
            return "Input or target application changed before insertion"
        case "erasePrecondition", "guardedErase":
            return "Erase precondition failed — the target text changed"
        case "axOnlyRange":
            return "AX insertion failed — Post Events permission is required for fallback"
        case "secureClipboardPaste":
            return reason.contains("image")
                ? "Secure clipboard insertion does not support images"
                : "Secure clipboard insertion unavailable"
        case "undo", "undoAXRange", "undoAXDirect", "undoPaste":
            return "Undo refused — the target text changed"
        default:
            break
        }

        if reason.localizedCaseInsensitiveContains("secure input") {
            return "Secure Input is active — expansion blocked"
        }
        if reason.localizedCaseInsensitiveContains("ime") {
            return "Active IME marked text — expansion blocked"
        }
        if reason.localizedCaseInsensitiveContains("accessibility")
            || reason.contains("AXIsProcessTrusted") {
            return "Accessibility unavailable — expansion blocked"
        }
        if reason.localizedCaseInsensitiveContains("post events") {
            return "Post Events permission is required for insertion"
        }
        if reason.localizedCaseInsensitiveContains("focused")
            || reason.localizedCaseInsensitiveContains("focus") {
            return "Focused text field unavailable — expansion blocked"
        }
        if reason.localizedCaseInsensitiveContains("erase precondition") {
            return "Erase precondition failed — the target text changed"
        }
        if reason.localizedCaseInsensitiveContains("target application changed")
            || reason.localizedCaseInsensitiveContains("input or target") {
            return "Input or target application changed before insertion"
        }
        return "Injection refused"
    }

    /// §3.2 / §2.10: diagnostic block for `DiagnosticReport` — per-app delivery ratios, refuse
    /// reason histogram, and the event-tap disable counters (`tapDisabledByTimeout` means our
    /// callback was too slow and is the actionable one).
    public func injectTelemetrySummaryLines() -> [String] {
        var lines = injectTelemetry.summaryLines()
        lines.append("")
        lines.append(EventTapEngine.shared.tapDisableCounters.summaryLine)
        return lines
    }

    /// Bounded counterpart used by production report capture. Carries the telemetry store's full
    /// observed-line count through composition with the tap-health footer.
    func injectTelemetryDiagnosticProjection(
        itemLimit: Int = DiagnosticReport.headerProjectionItemLimit,
        byteLimit: Int = DiagnosticReport.headerProjectionByteLimit
    ) -> DiagnosticReport.HeaderProjection {
        let source = injectTelemetry.diagnosticSummaryProjection(
            itemLimit: itemLimit,
            byteLimit: byteLimit
        )
        var builder = DiagnosticReport.HeaderProjectionBuilder(
            itemLimit: itemLimit,
            byteLimit: byteLimit
        )
        for line in source.retainedLines { builder.observe(line) }
        builder.observe("")
        builder.observe(EventTapEngine.shared.tapDisableCounters.summaryLine)
        let composedObserved = source.observedCount > Int.max - 2
            ? Int.max
            : source.observedCount + 2
        return builder.finish(totalObservedCount: composedObserved)
    }

    private func handleSnapshotChange(_ snapshot: PermissionSnapshot) {
        relaunchState.observe(snapshot)
        if snapshot.canUseAX {
            ProcessIdentity.rememberAccessibilityGranted(
                true,
                cdHash: identity.cachedCodeDirectoryHash
                    ?? UserDefaults.standard.string(forKey: ProcessIdentity.lastKnownCDHashDefaultsKey)
            )
            if axWasFalse {
                // Newly trusted — clear relaunch nudge once AX preflight is true.
                DevTypeLog.permission.info("[Permission] Accessibility became granted")
            }
            axWasFalse = false
        } else {
            if !axWasFalse {
                DevTypeLog.permission.notice("[Permission] Accessibility became denied/reset")
            }
            axWasFalse = true
        }

        applyTapLifecycle(for: snapshot, presentFailureAlert: false)
        emitStatus(snapshot: snapshot)
    }

    /// Tap start/stop follows Listen **and** Accessibility (both required for `.defaultTap`).
    /// Missing Post alone never stops the tap. Tap Failed alerts only fire when both are
    /// granted but `tapCreate` still returns nil (identity / duplicate-process class).
    private func applyTapLifecycle(for snapshot: PermissionSnapshot, presentFailureAlert: Bool) {
        let engine = EventTapEngine.shared
        if snapshot.blocksDefaultEventTap {
            callbackState.resetTapStartFailureEpisode()
            if engine.isTapRunning {
                DevTypeLog.permission.notice(
                    "[Permission] Listen or Accessibility denied — stopping event tap (\(DevTypeLog.snapshotSummary(snapshot), privacy: .public))"
                )
                engine.stop()
            }
            return
        }

        if engine.isTapRunning {
            callbackState.resetTapStartFailureEpisode()
            return
        }

        if engine.isEnabled {
            DevTypeLog.permission.info(
                "[Permission] Listen+AX granted — attempting event tap start"
            )
            let started = engine.start()
            if !started {
                DevTypeLog.permission.error(
                    "[Permission] event tap start failed despite listen+ax granted — check duplicate processes / binary identity"
                )
                if presentFailureAlert {
                    callbackState.deliverTapStartFailure()
                }
            } else {
                callbackState.resetTapStartFailureEpisode()
            }
        }
    }

    private func emitStatus(snapshot: PermissionSnapshot) {
        storeCachedSnapshot(snapshot)
        relaunchState.observe(snapshot)
        let recommendsRelaunch = relaunchState.recommendsRelaunch(for: snapshot)
        let status = Status(
            snapshot: snapshot,
            tapRunning: EventTapEngine.shared.isTapRunning,
            recommendsRelaunchForAX: recommendsRelaunch,
            lastInjectOutcome: lastRecordedInjectOutcome
        )
        let changed = callbackState.deliverStatus(status)
        if changed {
            DevTypeLog.permission.info(
                "[Permission] status tapRunning=\(status.tapRunning, privacy: .public) relaunch=\(recommendsRelaunch, privacy: .public) \(DevTypeLog.snapshotSummary(snapshot), privacy: .public)"
            )
        }
    }

    /// Call after Request Accessibility when preflight is still false (user may need relaunch).
    public func noteAccessibilityRequestResult(preflightGranted: Bool) {
        if !preflightGranted {
            DevTypeLog.permission.notice(
                "[Permission] Accessibility request returned; preflight still denied — relaunch may be required after enabling in Settings"
            )
            relaunchState.noteRequestResult(for: .accessibility, preflightGranted: false)
        } else {
            DevTypeLog.permission.info(
                "[Permission] Accessibility request returned; preflight granted"
            )
            relaunchState.noteRequestResult(for: .accessibility, preflightGranted: true)
        }
        refresh(presentTapFailureAlert: false)
    }

    /// Call after Request Input Monitoring when preflight is still false (often needs Settings + relaunch).
    public func noteListenRequestResult(preflightGranted: Bool) {
        if !preflightGranted {
            DevTypeLog.permission.notice(
                "[Permission] Input Monitoring request returned; preflight still denied — enable in Settings for THIS path, then Relaunch if needed"
            )
            relaunchState.noteRequestResult(for: .inputMonitoring, preflightGranted: false)
        } else {
            DevTypeLog.permission.info(
                "[Permission] Input Monitoring request returned; preflight granted"
            )
            relaunchState.noteRequestResult(for: .inputMonitoring, preflightGranted: true)
        }
        refresh(presentTapFailureAlert: true)
    }
}
