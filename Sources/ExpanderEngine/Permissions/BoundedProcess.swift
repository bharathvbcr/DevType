import Foundation

/// Deadline-bounded external tool invocation.
///
/// Why this exists: `ProcessIdentity` shells out to `codesign` and `mdfind` to resolve the TCC
/// identity shown in Setup and Permission Recovery. Both call sites used the
/// `run()` → `waitUntilExit()` → `readDataToEndOfFile()` shape, which has two failure modes that
/// both strand the Setup wizard:
///
///  1. **No deadline.** `codesign` against a bundle on a stalled network mount, or `mdfind` while
///     the Spotlight index is rebuilding, blocks forever. The wizard gates Finish on
///     `cdHashLoadFinished`, so a hung `codesign` leaves Finish permanently disabled with no way
///     out of the wizard except closing it — which never records completion, so it reopens on the
///     next launch. A hang in a diagnostic subprocess must not be able to brick onboarding.
///
///  2. **Read-after-exit deadlocks.** Draining the pipe only *after* `waitUntilExit()` returns
///     deadlocks whenever the child writes more than the ~64KB pipe buffer: the child blocks in
///     `write()` waiting for a reader, the parent blocks in `waitUntilExit()` waiting for the
///     child. `mdfind` on a machine with many DevType copies is exactly that shape.
///
/// This type drains the pipe concurrently and escalates SIGTERM → SIGKILL at the deadline, so the
/// worst case is a bounded wait that returns `nil` and a caller that degrades to "unavailable".
public enum BoundedProcess {

    /// Default ceiling for identity tools. Generous relative to a healthy run (tens of
    /// milliseconds) and short enough that a hung tool cannot outlive a user's patience.
    public static let defaultTimeout: TimeInterval = 5.0

    /// Grace period between SIGTERM and SIGKILL for a tool that ignores termination.
    public static let terminationGrace: TimeInterval = 1.0

    public struct Result: Equatable {
        public let output: String
        public let exitCode: Int32
        public let timedOut: Bool

        public init(output: String, exitCode: Int32, timedOut: Bool) {
            self.output = output
            self.exitCode = exitCode
            self.timedOut = timedOut
        }
    }

    /// Runs `executable` with `arguments`, returning captured output.
    ///
    /// - Parameter mergeStandardError: route stderr into the same pipe as stdout. `codesign`
    ///   writes its `-dvvv` report to stderr and splits `-d -r-` across both depending on the
    ///   version, so both identity probes want this; `mdfind` does not.
    /// - Returns: `nil` when the tool could not be spawned. A timed-out run returns a `Result`
    ///   with `timedOut == true` and whatever was drained before the deadline, so callers can tell
    ///   "did not run" from "ran too slowly".
    public static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        mergeStandardError: Bool = false
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        // Unmerged stderr goes to the null device: a fresh undrained `Pipe()` here blocked any
        // tool writing >64 KB to stderr until it was SIGTERM'd (output lost, full timeout burned)
        // and leaked its file handles on every call.
        process.standardError = mergeStandardError ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // Drain concurrently with the wait — see failure mode 2 above.
        let sink = OutputSink()
        let readFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            sink.append(pipe.fileHandleForReading.readDataToEndOfFile())
            readFinished.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            DevTypeLog.identity.error(
                "[Identity] spawn failed tool=\(executable, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            // The reader is parked on a pipe whose write end never opened; close it so the
            // dispatched block can finish instead of leaking a thread for the process lifetime.
            try? pipe.fileHandleForWriting.close()
            _ = readFinished.wait(timeout: .now() + terminationGrace)
            return nil
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            DevTypeLog.identity.notice(
                "[Identity] tool exceeded \(timeout, privacy: .public)s — terminating tool=\(executable, privacy: .public)"
            )
            process.terminate()
            if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
                DevTypeLog.identity.error(
                    "[Identity] tool ignored SIGTERM — killing tool=\(executable, privacy: .public)"
                )
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminationGrace)
            }
        }

        // Bounded even here: a killed child's pipe should hit EOF immediately, but a grandchild
        // holding the write end open would otherwise park this thread forever.
        _ = readFinished.wait(timeout: .now() + terminationGrace)

        return Result(
            output: sink.string(),
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    /// Lock-guarded box so the draining queue and the waiting caller do not race on the buffer.
    private final class OutputSink {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
