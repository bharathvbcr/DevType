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

    private static let queue = DispatchQueue(label: "com.devtype.debugtrace", qos: .utility)

    private static let resolvedPath: String? = {
        guard UserDefaults.standard.bool(forKey: enabledDefaultsKey) else { return nil }
        guard let raw = UserDefaults.standard.string(forKey: pathDefaultsKey), !raw.isEmpty else {
            return nil
        }
        return (raw as NSString).expandingTildeInPath
    }()

    public static var isEnabled: Bool { resolvedPath != nil }

    public static func write(
        location: String,
        hypothesisId: String,
        message: String,
        data: [String: Any]
    ) {
        guard let path = resolvedPath else { return }
        let payload: [String: Any] = [
            "location": location,
            "hypothesisId": hypothesisId,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "data": data
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8) else { return }
        queue.async { append(line: line, to: path) }
    }

    private static func append(line: String, to path: String) {
        guard let bytes = (line + "\n").data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? bytes.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > UInt64(maxBytes) {
            try? handle.truncate(atOffset: 0)
            // `truncate` does not move the file offset — without this seek the next write lands at
            // the old end and leaves a multi-megabyte hole of NULs behind it.
            try? handle.seek(toOffset: 0)
        }
        try? handle.write(contentsOf: bytes)
    }
}
