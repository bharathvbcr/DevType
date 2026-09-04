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
    /// Timer ownership, generation and the edge gate share one lock. Cancellation
    /// alone does not revoke a timer handler or a delivery already queued on main.
    private let stateLock = UnfairLock()
    private var generation: UUID?
    private var lastReportedLocked: Bool?
    private let statusProvider: (() -> LockStatus)?

    public init() {
        statusProvider = nil
    }

    /// Deterministic state source for lifecycle tests; production always uses the OS probe.
    init(statusProvider: @escaping () -> LockStatus) {
        self.statusProvider = statusProvider
    }

    deinit {
        stopMonitoring()
    }

    static func pollingInterval(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 0.35 }
        return min(5, max(0.05, interval))
    }

    private func shouldReport(_ isLocked: Bool, generation expected: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == expected else { return false }
        guard lastReportedLocked == nil || lastReportedLocked != isLocked else { return false }
        lastReportedLocked = isLocked
        return true
    }

    private func isCurrent(_ expected: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == expected
    }

    public func startMonitoring(interval: TimeInterval = 0.35, onChange: @escaping (LockStatus) -> Void) {
        let interval = Self.pollingInterval(interval)
        let currentGeneration = UUID()
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isCurrent(currentGeneration) else { return }
            let status = self.statusProvider?() ?? self.checkLockStatus()
            guard self.shouldReport(status.isLocked, generation: currentGeneration) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(currentGeneration) else { return }
                let app = DevTypeLog.boundedPublicIdentifier(
                    status.holdingAppName,
                    label: "appName"
                )
                let pid = status.holdingPID.map { String($0) } ?? "nil"
                DevTypeLog.secureInput.info(
                    "[SecureInput] lock \(status.isLocked ? "enabled" : "released", privacy: .public) frontmost=\(app, privacy: .public) pid=\(pid, privacy: .public)"
                )
                onChange(status)
            }
        }

        stateLock.lock()
        monitorTimer?.cancel()
        generation = currentGeneration
        lastReportedLocked = nil
        monitorTimer = timer
        // Resume while ownership is locked: stop/start from another thread cannot
        // cancel an unresumed source and deallocate it in the suspended state.
        timer.resume()
        stateLock.unlock()
        DevTypeLog.secureInput.info("[SecureInput] monitor started interval=\(interval, privacy: .public)s")
    }

    public func stopMonitoring() {
        stateLock.lock()
        let wasMonitoring = monitorTimer != nil
        generation = nil
        monitorTimer?.cancel()
        monitorTimer = nil
        lastReportedLocked = nil
        stateLock.unlock()
        if wasMonitoring {
            DevTypeLog.secureInput.debug("[SecureInput] monitor stopped")
        }
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
