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

    private let probe = PermissionProbe()
    private var workspaceObserver: NSObjectProtocol?
    private var permissionPollTimer: DispatchSourceTimer?
    private var lastObservedSnapshot: PermissionSnapshot?
    private var onChanged: ((PermissionSnapshot) -> Void)?

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

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            self?.emitIfChanged()
        }
        timer.resume()
        permissionPollTimer = timer
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

    private func emitIfChanged(force: Bool = false, snapshot probed: PermissionSnapshot? = nil) {
        let snapshot = probed ?? probe.snapshot()
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
