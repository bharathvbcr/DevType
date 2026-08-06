import Cocoa
import Foundation

/// Single permission observation stream: app activation + become-active + ~2s poll.
public final class PermissionObserver {
    public static let shared = PermissionObserver()

    public static let pollInterval: TimeInterval = 2.0

    private let probe = PermissionProbe()
    private var workspaceObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?
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

        // Accessory apps often miss workspace activation when returning from Settings.
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DevTypeLog.permission.info("[Permission] NSApp didBecomeActive — forcing preflight refresh")
            self?.emitIfChanged(force: true)
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
        if let observer = appActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            appActiveObserver = nil
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

    private func emitIfChanged(force: Bool = false) {
        let snapshot = probe.snapshot()
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
