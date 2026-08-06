import Carbon.HIToolbox
import Cocoa
import Foundation

public final class SecureInputMonitor {
    public static let shared = SecureInputMonitor()

    public struct LockStatus: Equatable {
        public let isLocked: Bool
        public let holdingPID: pid_t?
        public let holdingAppName: String?
        public let holdingExecutablePath: String?

        public init(isLocked: Bool, holdingPID: pid_t?, holdingAppName: String?, holdingExecutablePath: String?) {
            self.isLocked = isLocked
            self.holdingPID = holdingPID
            self.holdingAppName = holdingAppName
            self.holdingExecutablePath = holdingExecutablePath
        }
    }

    private var monitorTimer: DispatchSourceTimer?
    private let monitorQueue = DispatchQueue(label: "com.devtype.secureinputmonitor", qos: .utility)
    /// §1.11: `lastReportedLocked` is written by the timer handler (monitorQueue) and by
    /// `start`/`stopMonitoring` (usually main). It was previously unsynchronized — an
    /// `Optional<Bool>` torn between threads silently drops or duplicates lock transitions,
    /// which is exactly the edge that decides whether DevType is muted in a password field.
    private let stateLock = UnfairLock()
    /// Change-gate: only invoke onChange when lock state actually flips.
    private var lastReportedLocked: Bool?

    public init() {}

    /// Reads-and-updates the change gate atomically. Returns `true` when the caller should notify.
    private func shouldReport(_ isLocked: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        // Edge-triggered: notify only on first sample or when locked state changes.
        guard lastReportedLocked == nil || lastReportedLocked != isLocked else { return false }
        lastReportedLocked = isLocked
        return true
    }

    private func clearReportedState() {
        stateLock.lock()
        lastReportedLocked = nil
        stateLock.unlock()
    }

    public func startMonitoring(interval: TimeInterval = 0.35, onChange: @escaping (LockStatus) -> Void) {
        stopMonitoring()
        clearReportedState()
        DevTypeLog.secureInput.info(
            "[SecureInput] monitor started interval=\(interval, privacy: .public)s"
        )

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let status = self.checkLockStatus()
            guard self.shouldReport(status.isLocked) else { return }
            let app = status.holdingAppName ?? "nil"
            let pid = status.holdingPID.map { String($0) } ?? "nil"
            DevTypeLog.secureInput.info(
                "[SecureInput] lock \(status.isLocked ? "enabled" : "released", privacy: .public) frontmost=\(app, privacy: .public) pid=\(pid, privacy: .public)"
            )
            DispatchQueue.main.async {
                onChange(status)
            }
        }
        timer.resume()
        monitorTimer = timer
    }

    public func stopMonitoring() {
        if monitorTimer != nil {
            DevTypeLog.secureInput.debug("[SecureInput] monitor stopped")
        }
        monitorTimer?.cancel()
        monitorTimer = nil
        clearReportedState()
    }

    public func checkLockStatus() -> LockStatus {
        let isLocked = IsSecureEventInputEnabled()
        guard isLocked else {
            return LockStatus(isLocked: false, holdingPID: nil, holdingAppName: nil, holdingExecutablePath: nil)
        }

        // Best-effort attribution only: the private CGS Secure Event Input PID API is
        // unavailable on macOS 27+, so a background secure field may not match frontmost.
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let pid = frontApp.processIdentifier
            let appName = frontApp.localizedName ?? frontApp.bundleIdentifier ?? "Active Password/Secure Field"
            let execPath = frontApp.bundleURL?.path ?? "Unknown"
            return LockStatus(isLocked: true, holdingPID: pid, holdingAppName: appName, holdingExecutablePath: execPath)
        }

        return LockStatus(isLocked: true, holdingPID: nil, holdingAppName: "Secure Field Application", holdingExecutablePath: nil)
    }
}
