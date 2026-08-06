import AppKit
import Foundation

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

    public enum InjectOutcome: Equatable {
        case succeeded
        case postedUnverified
        case refused(String)
        case degradedAXOnly
        case failedSilent
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

    private var onStatus: ((Status) -> Void)?
    /// Fired when Listen+AX are granted but `engine.start()` fails and the caller asked for an alert.
    private var onTapStartFailed: (() -> Void)?
    private var onIdentityResolved: ((String?) -> Void)?
    private var sawAXGrantedWhileUntrusted = false

    /// §1.11: `lastInjectOutcome` / `lastInjectRefuseProvenance` / `lastEmittedStatus` are written
    /// from `injectQueue`, `processingQueue` **and** main while `_cachedSnapshot` right beside them
    /// was carefully guarded. `InjectOutcome.refused(String)` carries a `String`, so a torn write
    /// is an over-release risk, not just a stale read. All three now live behind `outcomeLock`.
    ///
    /// §2.4: `os_unfair_lock` (not `NSLock`) so the userInteractive tap callback reading
    /// `cachedSnapshot` cannot be blocked behind a utility-QoS writer without priority donation.
    private let outcomeLock = UnfairLock()
    private var _lastInjectOutcome: InjectOutcome?
    private var _lastInjectRefuseProvenance: InjectRefuseProvenance?
    private var _lastEmittedStatus: Status?

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

    /// Gate / frontmost / timestamp captured at the most recent refuse (not cleared on later success).
    public var lastRecordedInjectRefuseProvenance: InjectRefuseProvenance? {
        outcomeLock.withLock { _lastInjectRefuseProvenance }
    }

    private var lastEmittedStatus: Status? {
        get { outcomeLock.withLock { _lastEmittedStatus } }
        set { outcomeLock.withLock { _lastEmittedStatus = newValue } }
    }

    /// True when UI should prominently offer Relaunch (Settings flip may not apply until restart).
    public var recommendsRelaunch: Bool {
        lastEmittedStatus?.recommendsRelaunchForAX == true || sawAXGrantedWhileUntrusted
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

    public func start(
        onStatusChanged: @escaping (Status) -> Void,
        onTapStartFailed: (() -> Void)? = nil,
        onIdentityResolved: ((String?) -> Void)? = nil
    ) {
        onStatus = onStatusChanged
        self.onTapStartFailed = onTapStartFailed
        self.onIdentityResolved = onIdentityResolved
        identity.refreshCDHashAsync { [weak self] hash in
            DevTypeLog.identity.info(
                "[Identity] CDHash resolved=\(hash ?? "nil", privacy: .public) path=\(ProcessIdentity.shared.bundlePath, privacy: .public)"
            )
            self?.onIdentityResolved?(hash)
        }

        DevTypeLog.permission.info(
            "[Permission] coordinator start identity bundleID=\(self.identity.bundleIdentifier, privacy: .public) packaged=\(self.identity.isPackaged, privacy: .public) path=\(self.identity.bundlePath, privacy: .public)"
        )
        if let unpackaged = ProcessIdentity.unpackagedBinaryWarning(bundlePath: identity.bundlePath) {
            DevTypeLog.identity.notice("[Identity] \(unpackaged, privacy: .public)")
        }
        let siblings = identity.siblingPaths()
        if let dup = ProcessIdentity.duplicateProcessWarning(siblingPaths: siblings) {
            DevTypeLog.identity.notice("[Identity] \(dup, privacy: .public)")
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
        observer.stop()
        SettingsDeepLinker.shared.cancelPendingOpen()
        onStatus = nil
        onTapStartFailed = nil
        onIdentityResolved = nil
        lastEmittedStatus = nil
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

        switch outcome {
        case .succeeded:
            DevTypeLog.inject.info("[Inject] outcome=succeeded")
        case .postedUnverified:
            DevTypeLog.inject.notice("[Inject] outcome=postedUnverified")
        case .refused(let refuseReason):
            reason = refuseReason
            provenance = refuseContext ?? InjectRefuseProvenance.capture(reason: refuseReason)
            DevTypeLog.inject.notice("[Inject] outcome=refused reason=\(refuseReason, privacy: .public)")
        case .degradedAXOnly:
            DevTypeLog.inject.info("[Inject] outcome=degradedAXOnly (Post Events missing)")
        case .failedSilent:
            DevTypeLog.inject.error("[Inject] outcome=failedSilent")
        }

        outcomeLock.lock()
        _lastInjectOutcome = outcome
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
            outcome: outcome,
            bundleID: bundleID,
            path: path,
            reason: reason
        )

        emitStatus(snapshot: probe.snapshot())
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

    public func markAXPossiblyNeedsRelaunch() {
        DevTypeLog.permission.notice(
            "[Permission] Accessibility may need relaunch (granted in Settings but preflight still false)"
        )
        sawAXGrantedWhileUntrusted = true
        emitStatus(snapshot: probe.snapshot())
    }

    private func handleSnapshotChange(_ snapshot: PermissionSnapshot) {
        if snapshot.canUseAX {
            ProcessIdentity.rememberAccessibilityGranted(
                true,
                cdHash: identity.cachedCodeDirectoryHash
                    ?? UserDefaults.standard.string(forKey: ProcessIdentity.lastKnownCDHashDefaultsKey)
            )
            if axWasFalse {
                // Newly trusted — clear relaunch nudge once AX preflight is true.
                DevTypeLog.permission.info("[Permission] Accessibility became granted")
                sawAXGrantedWhileUntrusted = false
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
            if engine.isTapRunning {
                DevTypeLog.permission.notice(
                    "[Permission] Listen or Accessibility denied — stopping event tap (\(DevTypeLog.snapshotSummary(snapshot), privacy: .public))"
                )
                engine.stop()
            }
            return
        }

        if !engine.isTapRunning && engine.isEnabled {
            DevTypeLog.permission.info(
                "[Permission] Listen+AX granted — attempting event tap start"
            )
            let started = engine.start()
            if !started {
                DevTypeLog.permission.error(
                    "[Permission] event tap start failed despite listen+ax granted — check duplicate processes / binary identity"
                )
                if presentFailureAlert {
                    onTapStartFailed?()
                }
            }
        }
    }

    private func emitStatus(snapshot: PermissionSnapshot) {
        storeCachedSnapshot(snapshot)
        let recommendsRelaunch = sawAXGrantedWhileUntrusted && !snapshot.canUseAX
        let status = Status(
            snapshot: snapshot,
            tapRunning: EventTapEngine.shared.isTapRunning,
            recommendsRelaunchForAX: recommendsRelaunch,
            lastInjectOutcome: lastRecordedInjectOutcome
        )
        if status != lastEmittedStatus {
            DevTypeLog.permission.info(
                "[Permission] status tapRunning=\(status.tapRunning, privacy: .public) relaunchAX=\(recommendsRelaunch, privacy: .public) \(DevTypeLog.snapshotSummary(snapshot), privacy: .public)"
            )
            lastEmittedStatus = status
        }
        onStatus?(status)
    }

    /// Call after Request Accessibility when preflight is still false (user may need relaunch).
    public func noteAccessibilityRequestResult(preflightGranted: Bool) {
        if !preflightGranted {
            DevTypeLog.permission.notice(
                "[Permission] Accessibility request returned; preflight still denied — relaunch may be required after enabling in Settings"
            )
            sawAXGrantedWhileUntrusted = true
        } else {
            DevTypeLog.permission.info(
                "[Permission] Accessibility request returned; preflight granted"
            )
            sawAXGrantedWhileUntrusted = false
        }
        refresh(presentTapFailureAlert: false)
    }

    /// Call after Request Input Monitoring when preflight is still false (often needs Settings + relaunch).
    public func noteListenRequestResult(preflightGranted: Bool) {
        if !preflightGranted {
            DevTypeLog.permission.notice(
                "[Permission] Input Monitoring request returned; preflight still denied — enable in Settings for THIS path, then Relaunch if needed"
            )
            // Reuse relaunch nudge; Listen flips also often need process restart.
            sawAXGrantedWhileUntrusted = true
        } else {
            DevTypeLog.permission.info(
                "[Permission] Input Monitoring request returned; preflight granted"
            )
        }
        refresh(presentTapFailureAlert: true)
    }
}
