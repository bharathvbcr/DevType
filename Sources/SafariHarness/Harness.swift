import AppKit
import Foundation
import SafariHarnessCore

enum Harness {
    static func main(_ arguments: [String]) -> Int32 {
        let options: Options
        do { options = try Options.parse(arguments) } catch {
            fputs("error: \(error)\n\n\(Options.usage)\n", stderr)
            return 64
        }
        switch options.command {
        case .help:
            print(Options.usage)
            return 0
        case .listCases:
            let spec = HarnessSnippetSpec(trigger: options.trigger, expansion: options.expansion)
            for testCase in CaseTable.select(ids: options.only) {
                let events = Planner.plannedEventCount(testCase, spec: spec, hotkey: .default)
                print("\(Planner.describe(testCase)) [\(events) key events\(testCase.needsAI ? ", needs AI" : "")]")
            }
            return 0
        case .addSnippet:
            return addSnippet(options)
        case .dryRun, .live:
            return execute(options, mode: options.command == .live ? .live : .dryRun)
        }
    }

    // MARK: Repo

    static func findRepoRoot(_ options: Options) -> URL? {
        var dir = URL(fileURLWithPath: options.repo ?? FileManager.default.currentDirectoryPath).standardizedFileURL
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(HarnessConstants.fixtureRelativePath).path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    static func addSnippet(_ options: Options) -> Int32 {
        let spec = HarnessSnippetSpec(trigger: options.trigger, expansion: options.expansion)
        if !spec.problems.isEmpty {
            fputs("the snippet spec is not usable:\n  " + spec.problems.joined(separator: "\n  ") + "\n", stderr)
            return 2
        }
        print("""
        Opening DevType's snippet editor with the harness snippet pre-filled. DevType never saves from a URL.
          trigger  \(spec.trigger)
          text     \(spec.expansion)
        Press Save in DevType, leave it plain text, enabled, not a secret, no app restrictions. Then run
        Scripts/safari-harness.sh --dry-run.
        """)
        guard let url = URL(string: spec.editorURL) else { return 2 }
        NSWorkspace.shared.open(url)
        return 0
    }

    // MARK: Run

    static func execute(_ options: Options, mode: RunMode) -> Int32 {
        SignalState.install()
        guard let root = findRepoRoot(options) else {
            fputs("error: could not find the checkout (looked for \(HarnessConstants.fixtureRelativePath)); pass --repo\n", stderr)
            return 64
        }
        let fixtureURL = root.appendingPathComponent(HarnessConstants.fixtureRelativePath)
        let fixturePath = fixtureURL.resolvingSymlinksInPath().path
        let spec = HarnessSnippetSpec(trigger: options.trigger, expansion: options.expansion)
        let cases = CaseTable.select(ids: options.only)
        let startedAt = Date()
        let seed = options.seed ?? UInt64.random(in: 1...UInt64(UInt32.max))
        let stamp = Self.fileStamp(startedAt)
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)

        print("== preflight (\(mode == .live ? "LIVE" : "dry run"))")
        let pre = PreflightRunner.run(options: options, repoRoot: root, fixtureURL: fixtureURL, spec: spec, mode: mode)
        for row in pre.rows {
            print("  [\(row.ok ? "ok" : "NO")] \(row.name): \(row.detail)")
            if !row.ok, let remedy = row.remedy { print("       -> \(remedy)") }
        }
        if mode == .live, !pre.allOK {
            print("\nrefusing to run live: fix the rows marked NO. Nothing was typed.")
            return 2
        }

        // Library: back up bytes first (live), and re-verify after.
        var backupNote = "not taken (dry run reads and hashes the library only)"
        let librarySHA = pre.libraryReport?.sha256
        if mode == .live, let data = pre.libraryData {
            do {
                let dir = tmp.appendingPathComponent("safari-harness-backup-\(stamp)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let copy = dir.appendingPathComponent("snippets.json")
                try data.write(to: copy, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                let verify = try Data(contentsOf: copy)
                guard verify == data else { throw NSError(domain: "SafariHarness", code: 3, userInfo: [NSLocalizedDescriptionKey: "backup differs from the library"]) }
                backupNote = "\(copy.path) (verified byte-identical, sha256 \(LibraryProbe.sha256(verify).prefix(16)))"
            } catch {
                print("\nrefusing to run live: could not back up the library: \(error.localizedDescription). Nothing was typed.")
                return 2
            }
        }

        // Clipboard stand-ins.
        let clipboard: ClipboardPort = mode == .live ? SystemClipboard() : InMemoryClipboard()
        var initialClipboard: ClipboardSnapshot?
        if mode == .live {
            do { initialClipboard = try clipboard.snapshot() } catch {
                print("\nrefusing to run live: the clipboard cannot be preserved (\(error.localizedDescription)). Nothing was typed.")
                return 2
            }
        }

        let abort = AbortController(
            timeoutSeconds: options.timeoutSeconds,
            escapeDown: { SystemFacts.escapeIsDown() },
            signalled: { SignalState.flag }
        )
        let keyboard: KeyboardPort = mode == .live ? HIDKeyboard() : RecordingKeyboard()
        let js = JSBridge()

        var results: [CaseResult] = []
        var stageFailure: String?
        var pageReadMode = "page not reached"
        var observer: ChordObserver?

        let trusted = SystemFacts.accessibilityTrusted()
        if !trusted {
            stageFailure = "Accessibility is not granted to \(SystemFacts.responsibleAppName()), so Safari's page cannot be reached"
        } else if pre.safariURL == nil {
            stageFailure = "Safari is not installed"
        }

        if stageFailure == nil, mode == .live {
            if !countdown(abort) { stageFailure = "aborted during the countdown: \(abort.tripped.map(\.description) ?? "interrupted")" }
        }

        if stageFailure == nil, let safariURL = pre.safariURL {
            if let page = openPage(safariURL: safariURL, fixtureURL: fixtureURL, fixturePath: fixturePath, triggerLength: spec.trigger.count,
                                   js: js, noJS: options.noJS, allowMouse: mode == .live) {
                pageReadMode = js.available ? "AX (primary) + page JavaScript" : "AX only (page JavaScript unavailable: \(options.noJS ? "--no-js" : js.reason ?? "not probed"))"
                if mode == .live, cases.contains(where: \.observesChords) { observer = ChordObserver() }
                let context = RunContext(mode: mode, spec: spec, fixturePath: fixturePath, devTypePID: pre.devType?.processIdentifier,
                                         ai: pre.ai, hotkey: pre.hotkey, seed: seed)
                let runner = Runner(keyboard: keyboard, page: page, clipboard: clipboard, chords: observer, abort: abort,
                                    clock: .system, context: context)
                print("\n== running \(cases.count) cases (\(mode == .live ? "keys are being posted; Escape aborts" : "dry: no key is posted"))")
                let outcome = runner.run(cases)
                results = outcome.results
                for r in results { print("  \(r.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(r.id): \(r.summary)") }
            } else {
                stageFailure = "the harness page did not appear in Safari's accessibility tree within 25 s"
            }
        }
        if let stageFailure {
            print("\n\(stageFailure)")
            let now = Date()
            results = cases.map { testCase in
                var r = CaseResult(id: testCase.id, title: testCase.title, status: mode == .dryRun ? .dryRun : .notRun,
                                   summary: mode == .dryRun
                                       ? "dry run reached only the offline stage (\(stageFailure)); \(Planner.plannedEventCount(testCase, spec: spec, hotkey: pre.hotkey)) key events would be posted"
                                       : "not run: \(stageFailure)",
                                   started: now, ended: now)
                r.plannedEvents = Planner.plannedEventCount(testCase, spec: spec, hotkey: pre.hotkey)
                r.clipboard = .unchecked("page stage not reached")
                return r
            }
        }

        // MARK: Exit paths. Every route lands here.
        keyboard.releaseHeldModifiers()
        observer?.stop()
        let finished = Date()

        var clipboardFinal = "not touched: a dry run uses an in-memory stand-in; the real pasteboard was neither read nor written"
        if mode == .live, let initialClipboard {
            clipboardFinal = restoreClipboard(clipboard, to: initialClipboard)
        }
        var libraryOutcome = "not applicable (library not read)"
        if let librarySHA {
            let after = try? Data(contentsOf: pre.libraryURL)
            let outcome = LibraryGuard.compare(beforeSHA: librarySHA, after: after)
            libraryOutcome = outcome.summary
        }

        let collected = LogCollector.collect(since: startedAt, launchedAt: pre.devType?.launchDate,
                                           devTypePID: pre.devType?.processIdentifier)
        let logs = CollectedLogs.build(mainLines: collected.main, unitsLines: collected.units, results: results, queryNote: collected.note)

        var notes = [
            "Event source: this harness posts at the HID tap from a .hidSystemState source with userData 0 (untagged, so DevType treats the keys as the user's). DevType's own injections use .privateState (falling back to .hidSystemState) with userData 0x534E4950 (HIDKeyPoster.makeTaggedEventSource); its paste chord sets .maskCommand explicitly. Whether the HID system merges a physically held Shift or Option into that chord is exactly what the held-modifier cases and the chord record test.",
            "Held-modifier cases press the modifier as the last trigger key is released, not before the first: typing the trigger under a held Shift would change its characters and it would not match.",
            "Keys were typed with US key codes; DevType's tap derives the character from the key code through its own US table first (EventTapEngine+TapCallback.swift), which is why a US layout is required."
        ]
        if let reason = observer?.unavailableReason { notes.append("chord observer: \(reason)") }
        if mode == .live, observer == nil, cases.contains(where: \.observesChords) { notes.append("chord observer was not started") }

        let header = ReportHeader(
            mode: mode, started: startedAt, finished: finished, preflight: pre.rows, seed: seed, trigger: spec.trigger,
            pageReadMode: pageReadMode, libraryOutcome: libraryOutcome, libraryBackup: backupNote,
            clipboardFinal: clipboardFinal, abort: abort.tripped, notes: notes)
        let report = ReportRenderer.render(header: header, results: results, logs: logs)

        var path = "(report not written)"
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let file = tmp.appendingPathComponent("safari-harness-\(mode == .live ? "live" : "dry")-\(stamp).txt")
            try report.write(to: file, atomically: true, encoding: .utf8)
            path = file.path
        } catch {
            fputs("could not write the report: \(error)\n", stderr)
        }

        print("")
        print(report.components(separatedBy: "PER-CASE EVIDENCE").first ?? report)
        print("report: \(path)")
        return ReportRenderer.exitCode(results, mode: mode, abort: abort.tripped)
    }

    // MARK: Helpers

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func countdown(_ abort: AbortController) -> Bool {
        print("""

        LIVE RUN. The harness will now type into Safari with real key events for a few minutes.
        Do not touch the keyboard or switch apps. Press or hold Escape (or Ctrl-C) to stop at once.
        """)
        for second in stride(from: 5, through: 1, by: -1) {
            print("  starting in \(second)...")
            let end = Date().addingTimeInterval(1)
            while Date() < end {
                if abort.poll() != nil { return false }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return true
    }

    /// Opens the fixture in Safari and waits for it to show up in the accessibility tree.
    static func openPage(safariURL: URL, fixtureURL: URL, fixturePath: String, triggerLength: Int,
                         js: JSBridge, noJS: Bool, allowMouse: Bool) -> AXPage? {
        var components = URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "triggerLen", value: String(triggerLength))]
        guard let url = components?.url else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([url], withApplicationAt: safariURL, configuration: configuration) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 15)

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, !SignalState.flag {
            if let safari = SystemFacts.safariApp() {
                let page = AXPage(safariPID: safari.processIdentifier, fixturePath: fixturePath, js: js, allowMouse: allowMouse)
                if page.waitForPage(timeout: 2) {
                    if !noJS { js.probe() }
                    return page
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    static func restoreClipboard(_ clipboard: ClipboardPort, to initial: ClipboardSnapshot) -> String {
        do {
            let current = try clipboard.snapshot()
            if current == initial { return "unchanged since the run began (\(initial.summary))" }
            try clipboard.restore(initial)
            let verify = try clipboard.snapshot()
            return verify == initial
                ? "had changed (\(current.summary)); restored to the original (\(initial.summary))"
                : "CHANGED and the restore did not verify: now \(verify.summary), was \(initial.summary)"
        } catch {
            return "could not be checked or restored at exit: \(error.localizedDescription)"
        }
    }
}
