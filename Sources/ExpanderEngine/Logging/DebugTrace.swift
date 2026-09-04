import Foundation

/// Opt-in JSONL trace for diagnosing inject / focus behaviour in the field.
///
/// This replaces the hand-rolled writers that appended to a hardcoded absolute path on every
/// keystroke-triggered focus probe and every inject. Those did synchronous file I/O on the main
/// thread in the hot path, grew without bound, and shipped in release builds.
///
/// Off by default. To capture a trace:
/// ```
/// defaults write com.devtype.app DevTypeDebugTrace -bool YES
/// defaults write com.devtype.app DevTypeDebugTracePath -string ~/devtype-trace.jsonl
/// ```
/// Both defaults are read once at first use, so toggling them requires an app restart — that keeps
/// the disabled path down to a single cached `Bool` check.
public enum DebugTrace {
    public static let enabledDefaultsKey = "DevTypeDebugTrace"
    public static let pathDefaultsKey = "DevTypeDebugTracePath"

    /// Trace file size cap. Past this the file is truncated rather than allowed to fill the disk.
    public static let maxBytes = 4 * 1024 * 1024

    private static let resolvedPath: String? = {
        guard UserDefaults.standard.bool(forKey: enabledDefaultsKey) else { return nil }
        guard let raw = UserDefaults.standard.string(forKey: pathDefaultsKey), !raw.isEmpty else {
            return nil
        }
        return (raw as NSString).expandingTildeInPath
    }()

    /// Submission says whether a record entered the serial writer. I/O finishes asynchronously;
    /// `health` waits for accepted work and exposes the final typed result.
    public enum Submission: Equatable, Sendable {
        case accepted
        case disabled
        case rejected(WriteFailure)
    }

    /// Finite, content-free failure vocabulary. It is safe to include in copied diagnostics;
    /// paths, payloads, and localized error descriptions must never enter this type.
    public enum WriteFailure: String, Equatable, Sendable {
        case encoding
        case recordExceedsLimit = "record-exceeds-limit"
        case fileCreation = "file-creation"
        case notRegularFile = "not-regular-file"
        case filePermissions = "file-permissions"
        case open
        case seek
        case truncate
        case write
        case close
        case postconditionExceeded = "postcondition-exceeded"
    }

    public enum WriteStatus: Equatable, Sendable {
        case notAttempted
        case succeeded
        case failed(WriteFailure)

        fileprivate var diagnosticLabel: String {
            switch self {
            case .notAttempted:
                return "not-attempted"
            case .succeeded:
                return "succeeded"
            case .failed(let failure):
                return "failed(\(failure.rawValue))"
            }
        }
    }

    public struct Health: Equatable, Sendable {
        public let enabled: Bool
        public let write: WriteStatus

        public init(enabled: Bool, write: WriteStatus) {
            self.enabled = enabled
            self.write = write
        }

        /// Content-free by construction: only a boolean and finite enum cases are rendered.
        public var diagnosticLine: String {
            "Debug trace: \(enabled ? "enabled" : "disabled"); "
                + "write=\(write.diagnosticLabel)"
        }
    }

    private static let writer: Writer? = {
        guard let resolvedPath else { return nil }
        return Writer(fileURL: URL(fileURLWithPath: resolvedPath), maxBytes: maxBytes)
    }()

    public static var isEnabled: Bool { writer != nil }

    /// Waits for every accepted write ahead of this read. An enabled-but-unattempted trace is
    /// deliberately distinguishable from a successful trace.
    public static var health: Health {
        guard let writer else {
            return Health(enabled: false, write: .notAttempted)
        }
        return Health(enabled: true, write: writer.writeStatus)
    }

    @discardableResult
    public static func write(
        location: String,
        hypothesisId: String,
        message: String,
        data: [String: Any]
    ) -> Submission {
        guard let writer else { return .disabled }
        let payload: [String: Any] = [
            "location": location,
            "hypothesisId": hypothesisId,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "data": data
        ]
        // Validate before serialization: some Objective-C JSONSerialization failures are not
        // representable as ordinary Swift errors. An invalid diagnostic payload must be a typed
        // rejection, never a crash or a silent no-op.
        guard JSONSerialization.isValidJSONObject(payload) else {
            writer.recordFailure(.encoding)
            return .rejected(.encoding)
        }
        do {
            let json = try JSONSerialization.data(withJSONObject: payload)
            writer.enqueue(recordData: json)
            return .accepted
        } catch {
            writer.recordFailure(.encoding)
            return .rejected(.encoding)
        }
    }

    /// Isolated file seam for deterministic retention, permission, and I/O-health tests.
    final class Writer: @unchecked Sendable {
        typealias PermissionSetter = (_ url: URL, _ mode: Int) throws -> Void

        private let fileURL: URL
        private let maxBytes: Int
        private let queue: DispatchQueue
        private let permissionSetter: PermissionSetter
        private var status: WriteStatus = .notAttempted

        init(
            fileURL: URL,
            maxBytes: Int = DebugTrace.maxBytes,
            permissionSetter: PermissionSetter? = nil
        ) {
            self.fileURL = fileURL
            self.maxBytes = max(0, maxBytes)
            self.queue = DispatchQueue(label: "com.devtype.debugtrace", qos: .utility)
            self.permissionSetter = permissionSetter ?? Self.setPOSIXPermissions
        }

        /// `recordData` is one complete JSON value without its line terminator.
        func enqueue(recordData: Data) {
            queue.async { [self] in
                var bytes = recordData
                bytes.append(0x0A)
                append(bytes)
            }
        }

        func recordFailure(_ failure: WriteFailure) {
            queue.async { [self] in setFailure(failure) }
        }

        var writeStatus: WriteStatus {
            queue.sync { status }
        }

        private func append(_ bytes: Data) {
            // A JSONL record is indivisible. A partial line would corrupt downstream readers, so
            // reject it without touching an existing trace.
            guard bytes.count <= maxBytes else {
                setFailure(.recordExceedsLimit)
                return
            }

            let fileManager = FileManager.default
            let existed = fileManager.fileExists(atPath: fileURL.path)
            if !existed {
                let created = fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
                guard created else {
                    setFailure(.fileCreation)
                    return
                }
            }

            guard isRegularFile() else {
                if !existed { try? fileManager.removeItem(at: fileURL) }
                setFailure(.notRegularFile)
                return
            }

            // Tighten a permissive pre-existing file before appending any trace content. Creation
            // also gets an explicit read-back verification rather than trusting requested attrs.
            guard enforcePermissions(mode: 0o600) else {
                if !existed { try? fileManager.removeItem(at: fileURL) }
                setFailure(.filePermissions)
                return
            }

            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: fileURL)
            } catch {
                setFailure(.open)
                return
            }

            var operation: WriteFailure = .seek
            do {
                let currentBytes = try handle.seekToEnd()

                // Decide from projected size, including integer overflow and equality at the old
                // cap. Every successful append therefore ends at or below the configured limit.
                if Self.requiresRotation(
                    currentBytes: currentBytes,
                    recordBytes: UInt64(bytes.count),
                    maximumBytes: UInt64(maxBytes)
                ) {
                    operation = .truncate
                    try handle.truncate(atOffset: 0)
                    operation = .seek
                    try handle.seek(toOffset: 0)
                }

                operation = .write
                try handle.write(contentsOf: bytes)

                operation = .seek
                let finalBytes = try handle.seekToEnd()
                if finalBytes > UInt64(maxBytes) {
                    operation = .truncate
                    try handle.truncate(atOffset: 0)
                    operation = .close
                    try handle.close()
                    setFailure(.postconditionExceeded)
                    return
                }

                operation = .close
                try handle.close()
                guard enforcePermissions(mode: 0o600) else {
                    // Do not retain content at a path whose owner-only mode could not be verified.
                    try? fileManager.removeItem(at: fileURL)
                    setFailure(.filePermissions)
                    return
                }
                status = .succeeded
            } catch {
                try? handle.close()
                setFailure(operation)
            }
        }

        private static func setPOSIXPermissions(_ url: URL, _ mode: Int) throws {
            try FileManager.default.setAttributes(
                [.posixPermissions: mode],
                ofItemAtPath: url.path
            )
        }

        static func requiresRotation(
            currentBytes: UInt64,
            recordBytes: UInt64,
            maximumBytes: UInt64
        ) -> Bool {
            let projected = currentBytes.addingReportingOverflow(recordBytes)
            return projected.overflow || projected.partialValue > maximumBytes
        }

        private func enforcePermissions(mode: Int) -> Bool {
            do {
                try permissionSetter(fileURL, mode)
                guard let permissions = try FileManager.default
                    .attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber else {
                    return false
                }
                return (permissions.intValue & 0o777) == mode
            } catch {
                return false
            }
        }

        private func isRegularFile() -> Bool {
            do {
                return try FileManager.default.attributesOfItem(atPath: fileURL.path)[.type]
                    as? FileAttributeType == .typeRegular
            } catch {
                return false
            }
        }

        private func setFailure(_ failure: WriteFailure) {
            status = .failed(failure)
            DevTypeLog.app.error(
                "[DebugTrace] write unavailable reason=\(failure.rawValue, privacy: .public)"
            )
        }
    }
}
