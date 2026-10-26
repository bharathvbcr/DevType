import CoreGraphics
import Foundation
import SafariHarnessCore

/// A listen-only session tap that keeps only the events DevType itself posts (the ones carrying its
/// synthetic marker in `eventSourceUserData`). It exists to answer one question for the held-modifier
/// cases: what flags did DevType's own paste chord carry? Every other event, including the user's
/// keystrokes, is discarded in the callback without being stored.
///
/// Needs Input Monitoring for the responsible app. Without it the harness says so and the cases run
/// without the chord record; it never requests the permission itself.
final class ChordObserver: ChordObserverPort {
    private let lock = NSLock()
    private var records: [ChordRecord] = []
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private(set) var unavailableReason: String?

    init() {
        guard SystemFacts.listenEventAccess() else {
            unavailableReason = "Input Monitoring is not granted to \(SystemFacts.responsibleAppName()); grant it in System Settings > Privacy & Security > Input Monitoring to record the chord DevType posts"
            return
        }
        let thread = Thread { [weak self] in self?.runTap() }
        thread.name = "SafariHarness.ChordObserver"
        thread.start()
        if ready.wait(timeout: .now() + 2) == .timedOut { unavailableReason = "the event tap thread did not start" }
    }

    private func runTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let observer = Unmanaged<ChordObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.consider(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            unavailableReason = "the system refused a listen-only event tap (Input Monitoring)"
            ready.signal()
            return
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        ready.signal()
        CFRunLoopRun()
    }

    fileprivate func consider(type: CGEventType, event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUserData) == HarnessConstants.devTypeSyntheticMarker else { return }
        let record = ChordRecord(
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            down: type != .keyUp,
            flags: ModifierMask(rawValue: event.flags.rawValue).intersection([.shift, .control, .option, .command]),
            at: Date()
        )
        lock.lock(); records.append(record); lock.unlock()
    }

    func drain() -> [ChordRecord] {
        lock.lock(); defer { lock.unlock() }
        defer { records.removeAll() }
        return records
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

/// Collects DevType's unified-log lines with `/usr/bin/log show`. In zsh `log` is a builtin, so the
/// absolute path matters.
enum LogCollector {
    /// The subsystem is shared with DevType's test bundles (`xctest` logs under it too), so the
    /// installed app's own process id narrows it: a line from another process is not evidence about
    /// the app under test.
    static func predicate(devTypePID: Int32?) -> String {
        let base = "subsystem == \"\(HarnessConstants.logSubsystem)\""
        guard let devTypePID else { return base + " AND process == \"DevType\"" }
        return base + " AND processID == \(devTypePID)"
    }

    struct Collected {
        var main: [LogLine]
        var units: [LogLine]
        var note: String
    }

    /// `since` bounds the main query; `launchedAt` bounds the once-per-launch units query.
    static func collect(since: Date, launchedAt: Date?, devTypePID: Int32?) -> Collected {
        let query = predicate(devTypePID: devTypePID)
        let mainSeconds = max(30, Int(Date().timeIntervalSince(since)) + 30)
        let main = SystemFacts.run("/usr/bin/log", [
            "show", "--predicate", query, "--info", "--debug", "--last", "\(mainSeconds)s"
        ], timeout: 90)

        // DevType logs the timestamp-units line once per launch, at its first key event, so it
        // can be far older than the run. Look back to the launch, capped at a day.
        let sinceLaunch = launchedAt.map { Int(Date().timeIntervalSince($0)) + 60 } ?? 3600
        let unitsSeconds = min(max(sinceLaunch, mainSeconds), 86_400)
        let units = SystemFacts.run("/usr/bin/log", [
            "show", "--predicate", query + " AND eventMessage CONTAINS \"event timestamp units\"",
            "--info", "--debug", "--last", "\(unitsSeconds)s"
        ], timeout: 120)

        var note = "/usr/bin/log show --predicate '\(query)' --info --debug --last \(mainSeconds)s -> exit \(main.status)"
        if main.timedOut { note += " (timed out, lines may be missing)" }
        if main.status != 0 { note += " stderr: \(main.stderr.prefix(160))" }
        note += "; units query --last \(unitsSeconds)s -> exit \(units.status)"
        if sinceLaunch > 86_400 { note += " (capped at 24 h; DevType has been up longer)" }
        if units.timedOut { note += " (timed out)" }
        return Collected(main: LogParser.parse(main.stdout), units: LogParser.parse(units.stdout), note: note)
    }
}
