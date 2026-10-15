import Cocoa
import Foundation

/// Single permission observation stream: workspace app activation + ~2s poll.
///
/// Our own `NSApplication.didBecomeActiveNotification` is deliberately **not** observed here.
/// `PermissionCoordinator.handleApplicationDidBecomeActive` already answers that exact
/// notification by way of the app delegate, and answers it with strictly more than a probe —
/// it also attempts a tap start and may raise the tap-failure alert. Observing it in both
/// places meant every activation paid three full TCC round trips (`CGPreflightListenEventAccess`
/// + `AXIsProcessTrustedWithOptions` + `CGPreflightPostEventAccess`, each) on the main thread
/// for one event, and printed the answer to the Console twice.
public final class PermissionObserver {
    public static let shared = PermissionObserver()

    public static let pollInterval: TimeInterval = 2.0
    /// While every capability is already granted, a 2s TCC preflight is wasted main-thread work.
    /// The event-tap health timer stays separate and keeps its own 2s cadence: a fully capable
    /// process can still lose the tap.
    public static let capablePollInterval: TimeInterval = 30
    public static let pollLeeway: DispatchTimeInterval = .milliseconds(500)

    private let probe = PermissionProbe()
    private var workspaceObserver: NSObjectProtocol?
    private var permissionPollTimer: DispatchSourceTimer?
    private var lastObservedSnapshot: PermissionSnapshot?
    private var onChanged: ((PermissionSnapshot) -> Void)?
    private var pollingWhileCapable = false
    /// Interval the live poll timer was scheduled with. Tests read this after `refreshNow(with:)`.
    public private(set) var currentPollInterval: TimeInterval = PermissionObserver.pollInterval

    public init() {}

    public var currentSnapshot: PermissionSnapshot {
        probe.snapshot()
    }

    public func start(onStatusChanged: @escaping (PermissionSnapshot) -> Void) {
        stop()
        onChanged = onStatusChanged
        let initial = probe.snapshot()
        lastObservedSnapshot = initial
        DevTypeLog.permission.info(
            "[Permission] observer started; poll=\(Self.pollInterval, privacy: .public)s initial \(DevTypeLog.snapshotSummary(initial), privacy: .public)"
        )

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.emitIfChanged()
        }

        // `stop()` cleared the cadence flag. Seed it to the opposite of the initial snapshot
        // so the first schedule always installs a timer.
        pollingWhileCapable = !initial.isFullyCapable
        adoptPollCadence(fullyCapable: initial.isFullyCapable)
    }

    public func stop() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        permissionPollTimer?.cancel()
        permissionPollTimer = nil
        lastObservedSnapshot = nil
        onChanged = nil
        pollingWhileCapable = false
        currentPollInterval = Self.pollInterval
        DevTypeLog.permission.debug("[Permission] observer stopped")
    }

    public func refreshNow() {
        emitIfChanged(force: true)
    }

    /// Publish a snapshot the caller has *already* taken, instead of taking another one.
    ///
    /// `PermissionCoordinator.refresh` needs a snapshot of its own for the tap lifecycle, and
    /// used to call `refreshNow()` immediately before taking it — two full TCC probes, one line
    /// apart, describing the same instant. Handing the probe it already has to the observer
    /// keeps both sides in sync for the cost of one.
    public func refreshNow(with snapshot: PermissionSnapshot) {
        emitIfChanged(force: true, snapshot: snapshot)
    }

    /// Reschedules only when the fully-capable bit changes, or when no timer is installed.
    /// Cancelling a timer from its own handler is safe: the handler returns, then the source
    /// is cancelled, and the replacement is a different source.
    private func adoptPollCadence(fullyCapable: Bool) {
        guard fullyCapable != pollingWhileCapable || permissionPollTimer == nil else { return }
        pollingWhileCapable = fullyCapable
        let interval = fullyCapable ? Self.capablePollInterval : Self.pollInterval
        currentPollInterval = interval
        permissionPollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: Self.pollLeeway)
        timer.setEventHandler { [weak self] in
            self?.emitIfChanged()
        }
        timer.resume()
        permissionPollTimer = timer
    }

    private func emitIfChanged(force: Bool = false, snapshot probed: PermissionSnapshot? = nil) {
        let snapshot = probed ?? probe.snapshot()
        adoptPollCadence(fullyCapable: snapshot.isFullyCapable)
        // While any capability is denied, log full preflight each poll so Console matches Settings confusion.
        if !snapshot.isFullyCapable {
            DevTypeLog.permission.debug(
                "[Permission] tick \(DevTypeLog.snapshotSummary(snapshot), privacy: .public) force=\(force, privacy: .public)"
            )
        }
        if force || snapshot != lastObservedSnapshot {
            if let previous = lastObservedSnapshot, previous != snapshot {
                DevTypeLog.permission.info(
                    "[Permission] snapshot changed \(DevTypeLog.snapshotSummary(snapshot), privacy: .public) (was \(DevTypeLog.snapshotSummary(previous), privacy: .public))"
                )
            } else if force {
                DevTypeLog.permission.info(
                    "[Permission] check forced \(DevTypeLog.snapshotSummary(snapshot), privacy: .public)"
                )
            }
            lastObservedSnapshot = snapshot
            onChanged?(snapshot)
        }
    }
}
