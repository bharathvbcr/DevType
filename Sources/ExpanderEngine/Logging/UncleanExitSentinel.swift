import Darwin
import Foundation

/// Records whether the previous process exited without reaching a normal termination.
///
/// `NSSetUncaughtExceptionHandler` only observes uncaught Objective-C exceptions. A Mach
/// exception such as `EXC_BREAKPOINT` / `SIGTRAP` (for example `dispatch_assert_queue`)
/// kills the process without entering that handler and without running
/// `applicationWillTerminate`. The sentinel file is the evidence those exits leave behind.
/// This type does not install a signal handler.
public enum UncleanExitSentinel {
    static let sentinelFileName = "unclean-exit.sentinel"
    /// One mebibyte is enough for a DevType `.ips`. Anything larger is not read.
    static let maximumCrashReportBytes = 1 << 20

    struct LaunchResult: Equatable {
        let previousRunUnclean: Bool
        let sentinelWritten: Bool
        let attachment: CrashFacts?
    }

    struct CrashFacts: Equatable {
        let basename: String
        let appVersion: String?
        let exceptionType: String?
        let faultingQueue: String?
    }

    private static let stateLock = NSLock()
    private static var storedLines: [String] = []

    /// Production launch. The file URL goes through `SupportDirectory.file`.
    /// A failed write is logged and does not fail launch.
    public static func noteLaunch() {
        let result = noteLaunch(
            sentinelFileURL: SupportDirectory.file(sentinelFileName),
            diagnosticReportsDirectory: defaultDiagnosticReportsDirectory
        )
        let lines = diagnosticLines(for: result)
        stateLock.lock()
        storedLines = lines
        stateLock.unlock()
    }

    /// Production termination. Called at the end of `applicationWillTerminate`, so a crash
    /// during cleanup still leaves the sentinel in place. A failed delete is logged.
    public static func noteCleanTermination() {
        _ = clearSentinel(at: SupportDirectory.file(sentinelFileName))
    }

    static func lastDiagnosticLines() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLines
    }

    static func noteLaunch(
        supportDirectory: URL,
        diagnosticReportsDirectory: URL
    ) -> LaunchResult {
        noteLaunch(
            sentinelFileURL: supportDirectory.appendingPathComponent(sentinelFileName, isDirectory: false),
            diagnosticReportsDirectory: diagnosticReportsDirectory
        )
    }

    @discardableResult
    static func noteCleanTermination(supportDirectory: URL) -> Bool {
        clearSentinel(
            at: supportDirectory.appendingPathComponent(sentinelFileName, isDirectory: false)
        )
    }

    static func diagnosticLines(for result: LaunchResult) -> [String] {
        guard result.previousRunUnclean else { return [] }
        var lines = ["unclean: yes"]
        guard let attachment = result.attachment else { return lines }
        lines.append("ips: \(attachment.basename)")
        if let appVersion = attachment.appVersion {
            lines.append("version: \(appVersion)")
        }
        if let exceptionType = attachment.exceptionType {
            lines.append("exception: \(exceptionType)")
        }
        if let faultingQueue = attachment.faultingQueue {
            lines.append("queue: \(faultingQueue)")
        }
        return lines
    }

    private static var defaultDiagnosticReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DiagnosticReports", isDirectory: true)
    }

    private static func noteLaunch(
        sentinelFileURL: URL,
        diagnosticReportsDirectory: URL
    ) -> LaunchResult {
        let previousRunUnclean = regularFileExists(at: sentinelFileURL)
        let attachment = previousRunUnclean
            ? newestMatchingCrashReport(in: diagnosticReportsDirectory)
            : nil
        if previousRunUnclean {
            logUnclean(attachment)
        }
        let sentinelWritten = writeSentinel(at: sentinelFileURL)
        if sentinelWritten {
            DevTypeLog.app.info("[Diagnostics] unclean-exit sentinel armed")
        }
        return LaunchResult(
            previousRunUnclean: previousRunUnclean,
            sentinelWritten: sentinelWritten,
            attachment: attachment
        )
    }

    private static func writeSentinel(at url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory)
        if parentExists && !isDirectory.boolValue {
            logIOFailure("write", POSIXError(.ENOTDIR))
            return false
        }
        do {
            if !parentExists {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try FilePermissions.atomicWrite(Data("devtype-unclean-exit\n".utf8), to: url)
            return true
        } catch {
            logIOFailure("write", error)
            return false
        }
    }

    private static func clearSentinel(at url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return true }
            logIOFailure("clear", posixError())
            return false
        }
        // `unlink` removes a symlink itself and refuses a directory. It does not follow.
        if unlink(url.path) != 0 {
            logIOFailure("clear", posixError())
            return false
        }
        return true
    }

    private static func regularFileExists(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func newestMatchingCrashReport(in directory: URL) -> CrashFacts? {
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR
        else { return nil }

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return nil
        }

        var best: (rank: Rank, facts: CrashFacts)?
        for name in names {
            guard isCandidateName(name) else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let parsed = readMatch(at: url, basename: name) else { continue }
            if best == nil || best!.rank < parsed.rank {
                best = parsed
            }
        }
        return best?.facts
    }

    private struct Rank: Comparable {
        var birthSec: Int64
        var birthNsec: Int64
        var modifySec: Int64
        var modifyNsec: Int64
        var name: String

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.birthSec != rhs.birthSec { return lhs.birthSec < rhs.birthSec }
            if lhs.birthNsec != rhs.birthNsec { return lhs.birthNsec < rhs.birthNsec }
            if lhs.modifySec != rhs.modifySec { return lhs.modifySec < rhs.modifySec }
            if lhs.modifyNsec != rhs.modifyNsec { return lhs.modifyNsec < rhs.modifyNsec }
            return lhs.name < rhs.name
        }
    }

    private static func readMatch(at url: URL, basename: String) -> (rank: Rank, facts: CrashFacts)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard info.st_size >= 0, info.st_size <= off_t(maximumCrashReportBytes) else { return nil }

        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var confirmed = stat()
        guard fstat(fd, &confirmed) == 0, (confirmed.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard confirmed.st_size >= 0, confirmed.st_size <= off_t(maximumCrashReportBytes) else { return nil }
        guard let data = readEntirely(fd: fd, byteCount: Int(confirmed.st_size)) else { return nil }
        guard let facts = parseCrashReport(data, basename: basename) else { return nil }

        let rank = Rank(
            birthSec: Int64(info.st_birthtimespec.tv_sec),
            birthNsec: Int64(info.st_birthtimespec.tv_nsec),
            modifySec: Int64(info.st_mtimespec.tv_sec),
            modifyNsec: Int64(info.st_mtimespec.tv_nsec),
            name: basename
        )
        return (rank, facts)
    }

    private static func readEntirely(fd: Int32, byteCount: Int) -> Data? {
        guard byteCount > 0 else { return Data() }
        var data = Data(count: byteCount)
        var offset = 0
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            while offset < byteCount {
                let readCount = Darwin.read(fd, base.advanced(by: offset), byteCount - offset)
                if readCount == 0 { return false }
                if readCount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += readCount
            }
            return true
        }
        return complete ? data : nil
    }

    private static func parseCrashReport(_ data: Data, basename: String) -> CrashFacts? {
        guard let objects = decodeJSONObjects(data), isDevType(objects) else { return nil }
        guard let safeBasename = sanitizedFact(basename, allowingPunctuation: false) else { return nil }
        var merged: [String: Any] = [:]
        for object in objects {
            for (key, value) in object {
                merged[key] = value
            }
        }
        let bundleInfo = merged["bundleInfo"] as? [String: Any]
        let version = sanitizedFact(string(merged["app_version"]))
            ?? sanitizedFact(string(bundleInfo?["CFBundleShortVersionString"]))
        let exception = sanitizedFact(string((merged["exception"] as? [String: Any])?["type"]))
        let queue = sanitizedFact(faultingQueue(in: merged))
        return CrashFacts(
            basename: safeBasename,
            appVersion: version,
            exceptionType: exception,
            faultingQueue: queue
        )
    }

    private static func isDevType(_ objects: [[String: Any]]) -> Bool {
        for object in objects {
            if string(object["procName"]) == "DevType" { return true }
            if string(object["app_name"]) == "DevType" { return true }
            if string(object["bundleID"]) == "com.devtype.app" { return true }
            if let info = object["bundleInfo"] as? [String: Any],
               string(info["CFBundleIdentifier"]) == "com.devtype.app" {
                return true
            }
        }
        return false
    }

    private static func faultingQueue(in report: [String: Any]) -> String? {
        let threads = report["threads"] as? [[String: Any]] ?? []
        if let index = int(report["faultingThread"]), threads.indices.contains(index) {
            if let queue = string(threads[index]["queue"]) { return queue }
        }
        if let triggered = threads.first(where: { $0["triggered"] as? Bool == true }),
           let queue = string(triggered["queue"]) {
            return queue
        }
        let legacy = report["legacyInfo"] as? [String: Any]
        let triggered = legacy?["threadTriggered"] as? [String: Any]
        return string(triggered?["queue"])
    }

    private static func decodeJSONObjects(_ data: Data) -> [[String: Any]]? {
        guard let slices = topLevelJSONObjects(in: data) else { return nil }
        var objects: [[String: Any]] = []
        objects.reserveCapacity(slices.count)
        for slice in slices {
            do {
                guard let object = try JSONSerialization.jsonObject(with: slice) as? [String: Any] else {
                    return nil
                }
                objects.append(object)
            } catch {
                return nil
            }
        }
        return objects
    }

    /// Splits a one- or two-object `.ips` document. macOS writes a one-line header object
    /// followed by a pretty-printed body. Brace counting stays in strings so a `}` inside a
    /// value cannot truncate the object. At most two objects are returned.
    private static func topLevelJSONObjects(in data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        var index = 0
        var objects: [Data] = []
        while index < bytes.count && objects.count < 2 {
            while index < bytes.count && isJSONWhitespace(bytes[index]) {
                index += 1
            }
            if index >= bytes.count { break }
            guard bytes[index] == UInt8(ascii: "{") else { return nil }
            let start = index
            var depth = 0
            var inString = false
            var escaped = false
            var closed = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        inString = false
                    }
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    inString = true
                } else if byte == UInt8(ascii: "{") {
                    depth += 1
                } else if byte == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 {
                        objects.append(Data(bytes[start..<index]))
                        closed = true
                        break
                    }
                }
            }
            if !closed || inString || depth != 0 { return nil }
        }
        return objects.isEmpty ? nil : objects
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isCandidateName(_ name: String) -> Bool {
        guard name.hasPrefix("DevType-"), name.hasSuffix(".ips") else { return false }
        let middle = name.dropFirst("DevType-".count).dropLast(".ips".count)
        guard !middle.isEmpty else { return false }
        return middle.unicodeScalars.allSatisfy(isFilenameScalar)
    }

    private static func isFilenameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "A"..."Z", "a"..."z", ".", "_", "-":
            return true
        default:
            return false
        }
    }

    /// Report facts are a closed token alphabet. A slash, tilde, or other path character
    /// drops the field instead of being copied into the diagnostic report.
    private static func sanitizedFact(_ raw: String?, allowingPunctuation: Bool = true) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
            switch scalar {
            case "0"..."9", "A"..."Z", "a"..."z", ".", "_", "-":
                continue
            case " ", "(", ")", "+":
                if allowingPunctuation { continue }
                return nil
            default:
                return nil
            }
        }
        return value
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func int(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func logUnclean(_ facts: CrashFacts?) {
        guard let facts else {
            DevTypeLog.app.error("[Diagnostics] previous exit unclean (no matching crash report)")
            return
        }
        let version = facts.appVersion ?? "unknown"
        let exception = facts.exceptionType ?? "unknown"
        let queue = facts.faultingQueue ?? "unknown"
        DevTypeLog.app.error(
            "[Diagnostics] previous exit unclean version=\(version, privacy: .public) exception=\(exception, privacy: .public) queue=\(queue, privacy: .public) ips=\(facts.basename, privacy: .public)"
        )
    }

    private static func logIOFailure(_ action: String, _ error: Error) {
        DevTypeLog.app.error(
            "[Diagnostics] unclean-exit sentinel \(action, privacy: .public) failed \(DevTypeLog.errorMetadata(error), privacy: .public)"
        )
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
