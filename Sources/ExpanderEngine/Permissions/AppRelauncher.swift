import AppKit
import Foundation

/// Quit-then-reopen relaunch for the running app bundle.
///
/// Why this is not `NSWorkspace.openApplication`: opening a bundle URL that is *already running*
/// asks LaunchServices to activate the existing instance, not to spawn a second one. Both
/// permission surfaces used that call and then terminated the app from its completion handler, so
/// "Relaunch DevType" reliably did nothing but quit — on the exact screen whose whole purpose is
/// telling the user that a relaunch is how they apply a freshly flipped Privacy toggle.
///
/// `NSWorkspace.OpenConfiguration.createsNewApplicationInstance` would launch a second copy, but
/// that briefly puts two DevType processes under the same TCC identity, which is precisely the
/// state the identity diagnostics warn about (and which can break event-tap creation). Instead a
/// detached `/bin/sh` waits for *this* PID to exit and only then reopens the bundle, so at no
/// point do two instances compete for the tap.
public enum AppRelauncher {

    /// Seconds the helper waits between liveness polls of the parent PID.
    public static let pollInterval = "0.2"

    /// Extra settle after the parent exits, so LaunchServices does not observe the dying process
    /// and short-circuit the reopen into an activate of a process that is already gone.
    public static let settleDelay = "0.4"

    /// Ceiling on the wait loop. Without it, a parent that never exits (terminate vetoed by a
    /// modal sheet, say) leaves an `sh` polling forever.
    public static let maxWaitSeconds = 30

    /// Shell program for the detached waiter.
    ///
    /// Values arrive as positional parameters rather than interpolated text, so a bundle path
    /// containing spaces, quotes, or `$` cannot alter the command. `kill -0` tests liveness
    /// without signalling.
    public static let waiterScript = """
    pid="$1"; app="$2"; poll="$3"; settle="$4"; limit="$5"; waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep "$poll"
      waited=$((waited + 1))
      if [ "$waited" -ge "$limit" ]; then break; fi
    done
    if kill -0 "$pid" 2>/dev/null; then
      # The ceiling expired with the parent still alive — terminate was vetoed (a modal sheet,
      # say). Opening now would run two instances under one TCC identity, which is exactly what
      # this helper exists to prevent. Do nothing.
      exit 0
    fi
    sleep "$settle"
    exec /usr/bin/open "$app"
    """

    /// Full argument vector for the detached `/bin/sh`, exposed for tests.
    ///
    /// The literal `sh` after `-c` is the conventional `$0` placeholder — without it the first
    /// real value would be consumed as the program name and `$1` would be the bundle path.
    public static func waiterArguments(pid: pid_t, bundlePath: String) -> [String] {
        let iterations = max(1, Int((Double(maxWaitSeconds) / (Double(pollInterval) ?? 0.2)).rounded()))
        return [
            "-c",
            waiterScript,
            "sh",
            String(pid),
            bundlePath,
            pollInterval,
            settleDelay,
            String(iterations)
        ]
    }

    /// Spawns the waiter, then terminates this process.
    ///
    /// - Parameter terminate: injected in tests; defaults to `NSApp.terminate`.
    /// - Returns: whether the waiter was spawned. On `false` the caller stays running rather than
    ///   quitting into nothing — a failed relaunch must not become an unrequested quit.
    @discardableResult
    public static func relaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        terminate: (() -> Void)? = nil
    ) -> Bool {
        let path = bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = waiterArguments(pid: getpid(), bundlePath: path)
        // Detach from our stdio so the helper is not holding descriptors we are about to close.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            DevTypeLog.app.error(
                "[App] relaunch helper failed to spawn — staying alive error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        DevTypeLog.app.info(
            "[App] relaunch helper spawned pid=\(process.processIdentifier, privacy: .public) target=\(path, privacy: .public)"
        )

        PermissionCoordinator.shared.cancelPendingWork()
        if let terminate {
            terminate()
        } else {
            NSApp.terminate(nil)
        }
        return true
    }
}
