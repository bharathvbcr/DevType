import Foundation
import Darwin

/// Bounded diagnostic subprocess capture. Drains nonblocking pipes on the calling thread so
/// descendants holding an inherited pipe cannot strand a background reader after return.
public enum BoundedProcess {
    public static let defaultTimeout: TimeInterval = 5
    public static let terminationGrace: TimeInterval = 1
    public static let maximumOutputBytes = 1_048_576

    public struct Result: Equatable {
        public let output: String
        public let exitCode: Int32
        public let timedOut: Bool
        public let outputTruncated: Bool
        public let outputComplete: Bool

        /// Identity probes must not interpret failed or partial output as a verified identity.
        public var succeeded: Bool {
            exitCode == 0 && !timedOut && outputComplete && !outputTruncated
        }

        public init(
            output: String, exitCode: Int32, timedOut: Bool,
            outputTruncated: Bool = false, outputComplete: Bool = true
        ) {
            self.output = output
            self.exitCode = exitCode
            self.timedOut = timedOut
            self.outputTruncated = outputTruncated
            self.outputComplete = outputComplete
        }
    }

    static func normalizedTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value >= 0 else { return defaultTimeout }
        return min(max(value, 0.01), 60)
    }

    /// Captures at most `outputLimit` bytes (clamped to 0...16 MiB), while continuing to drain
    /// excess bytes to avoid blocking the child. Escalates SIGTERM to SIGKILL after a grace
    /// period; pipe EOF and process exit each have bounded waits.
    public static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        mergeStandardError: Bool = false,
        outputLimit: Int = maximumOutputBytes
    ) -> Result? {
        let timeout = normalizedTimeout(timeout)
        let outputLimit = min(max(outputLimit, 0), 16 * maximumOutputBytes)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStandardError ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        defer {
            for handle in [pipe.fileHandleForWriting, pipe.fileHandleForReading] {
                do { try handle.close() }
                catch {
                    DevTypeLog.identity.error(
                        "[Identity] pipe close failed \(DevTypeLog.errorMetadata(error), privacy: .public)"
                    )
                }
            }
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            DevTypeLog.identity.error("[Identity] nonblocking pipe setup failed errno=\(errno)")
            return nil
        }
        do {
            try process.run()
        } catch {
            DevTypeLog.identity.error(
                "[Identity] spawn failed tool=\(executable, privacy: .public) \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return nil
        }
        do { try pipe.fileHandleForWriting.close() }
        catch {
            // Continue through the bounded lifecycle even if closing the parent's copy fails.
            DevTypeLog.identity.error(
                "[Identity] writer close failed \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var reachedEOF = false
        var readFailed = false
        var truncated = false
        var timedOut = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var terminatedAt: TimeInterval?
        var killedAt: TimeInterval?
        var exitObservedAt: TimeInterval?
        while true {
            if !reachedEOF && !readFailed {
                // Limit each drain batch so a continuously writing child cannot starve deadlines.
                for _ in 0..<16 {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        let retained = min(count, outputLimit - data.count)
                        data.append(contentsOf: buffer.prefix(retained))
                        truncated = truncated || retained < count
                    } else if count == 0 {
                        reachedEOF = true
                        break
                    } else {
                        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                            readFailed = true
                            DevTypeLog.identity.error("[Identity] pipe read failed errno=\(errno)")
                        }
                        break
                    }
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            if !process.isRunning {
                if reachedEOF || readFailed { break }
                if exitObservedAt == nil { exitObservedAt = now }
                if let exitObservedAt, now - exitObservedAt >= terminationGrace { break }
            } else if let killedAt {
                if now - killedAt >= terminationGrace { break }
            } else if let terminatedAt {
                if now - terminatedAt >= terminationGrace {
                    if kill(process.processIdentifier, SIGKILL) != 0 && errno != ESRCH {
                        DevTypeLog.identity.error("[Identity] SIGKILL failed errno=\(errno)")
                    }
                    killedAt = now
                }
            } else if now >= deadline {
                timedOut = true
                terminatedAt = now
                process.terminate()
            }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let output = String(data: data, encoding: .utf8)
        return Result(
            output: output ?? "",
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            timedOut: timedOut,
            outputTruncated: truncated,
            outputComplete: reachedEOF && !readFailed && !truncated && output != nil
        )
    }
}
