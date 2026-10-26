import AppKit
import ApplicationServices
import Carbon
import Darwin
import Foundation
import SafariHarnessCore

/// Read-only facts about the machine. Nothing here posts an event or writes a file.
enum SystemFacts {
    struct ProcessResult {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    /// Runs a child process we start, kills only that child on timeout, and gives up early if the
    /// harness was interrupted.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let lock = NSLock()
        var outData = Data(), errData = Data()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); outData.append(chunk); lock.unlock()
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); errData.append(chunk); lock.unlock()
        }
        do { try process.run() } catch {
            return ProcessResult(status: -1, stdout: "", stderr: "could not start \(path): \(error)", timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline || SignalState.flag {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        outData.append(out.fileHandleForReading.availableData)
        errData.append(err.fileHandleForReading.availableData)
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut
        )
    }

    static func gitCommitCount(root: URL) -> Int? {
        let result = run("/usr/bin/git", ["-C", root.path, "rev-list", "--count", "HEAD"], timeout: 15)
        guard result.status == 0 else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The CFBundleVersion inside the installed bundle.
    static func installedBuild() -> String? {
        Bundle(path: HarnessConstants.installedAppPath)?.infoDictionary?["CFBundleVersion"] as? String
    }

    static func devTypeInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: HarnessConstants.devTypeBundleID)
    }

    static func safariURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: HarnessConstants.safariBundleID)
    }

    static func safariApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: HarnessConstants.safariBundleID).first
    }

    static func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    static func postEventAccess() -> Bool { CGPreflightPostEventAccess() }

    static func listenEventAccess() -> Bool { CGPreflightListenEventAccess() }

    /// The GUI app macOS attributes this process's privacy permissions to: the nearest ancestor that
    /// is a regular app (Terminal, iTerm2, a Claude Code host, an IDE).
    static func responsibleAppName() -> String {
        var pid = getpid()
        for _ in 0..<12 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let parent = pid_t(info.pbi_ppid)
            guard parent > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular, let name = app.localizedName {
                return name
            }
            pid = parent
        }
        return "the app you launched this from (Terminal, iTerm2, ...)"
    }

    /// The active keyboard layout id, read from HIToolbox's preference rather than the Text Input
    /// Source API: those calls trap off the main queue on macOS 27 and DevType's source contract
    /// (`SourceContractTests`) keeps them in `KeyboardLayoutState` alone.
    static func keyboardLayoutID() -> String? {
        CFPreferencesCopyAppValue("AppleCurrentKeyboardLayoutInputSourceID" as CFString, "com.apple.HIToolbox" as CFString) as? String
    }

    /// DevType's preferences, read through CFPreferences so the domain is DevType's, not this tool's.
    static func devTypePref(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyAppValue(key as CFString, HarnessConstants.devTypeDefaultsDomain as CFString)
    }

    static func devTypePrefBool(_ key: String) -> Bool? { (devTypePref(key) as? NSNumber)?.boolValue }

    static func escapeIsDown() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(KeyPlan.escapeKey))
    }

    static func secureInputEnabled() -> Bool { IsSecureEventInputEnabled() }
}

/// Set from the SIGINT handler and polled by every wait loop, so Ctrl-C always reaches cleanup.
enum SignalState {
    nonisolated(unsafe) static var flag = false

    static func install() {
        signal(SIGINT) { _ in SignalState.flag = true }
        signal(SIGTERM) { _ in SignalState.flag = true }
    }
}
