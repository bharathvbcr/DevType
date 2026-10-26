import AppKit
import Foundation
import SafariHarnessCore

/// Everything learned before any page is opened or key posted.
struct PreflightResult {
    var rows: [PreflightRow] = []
    var devType: NSRunningApplication?
    var safariURL: URL?
    var libraryURL: URL
    var libraryData: Data?
    var libraryReport: LibraryReport?
    var ai: AIAvailability = .unavailable("not checked")
    var hotkey: AIHotkey = .default

    var allOK: Bool { rows.allSatisfy(\.ok) }
}

enum PreflightRunner {
    static func run(options: Options, repoRoot: URL, fixtureURL: URL, spec: HarnessSnippetSpec, mode: RunMode) -> PreflightResult {
        let who = SystemFacts.responsibleAppName()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let storePath = (SystemFacts.devTypePref(HarnessConstants.storeLocationKey) as? String)
        var result = PreflightResult(libraryURL: LibraryLocation.resolve(storeFilePath: storePath, home: home))

        // 1. DevType is running, and it is the installed copy.
        let installed = URL(fileURLWithPath: HarnessConstants.installedAppPath).resolvingSymlinksInPath().path
        let instances = SystemFacts.devTypeInstances()
        let paths = instances.map { $0.bundleURL?.resolvingSymlinksInPath().path ?? "unknown" }
        if instances.isEmpty {
            result.rows.append(PreflightRow(name: "DevType running", ok: false, detail: "no process with bundle id \(HarnessConstants.devTypeBundleID)",
                                            remedy: "Launch /Applications/DevType.app and wait for the menu bar icon."))
        } else if let match = zip(instances, paths).first(where: { $0.1 == installed })?.0, paths.allSatisfy({ $0 == installed }) {
            result.devType = match
            result.rows.append(PreflightRow(name: "DevType running", ok: true, detail: "pid \(match.processIdentifier) from \(installed)"))
        } else {
            result.rows.append(PreflightRow(name: "DevType running", ok: false,
                                            detail: "running from \(paths.joined(separator: ", ")), not only \(installed)",
                                            remedy: "Quit every other DevType (a stale .build copy would pass a bundle-id check) and launch the installed app."))
        }

        // 2. Installed build equals the checkout's commit count.
        let check = VersionCheck.compare(installed: SystemFacts.installedBuild(), expected: SystemFacts.gitCommitCount(root: repoRoot))
        result.rows.append(PreflightRow(name: "Installed build matches checkout", ok: check.isMatch, detail: check.summary,
                                        remedy: check.isMatch ? nil : "Scripts/install-app.sh release from this checkout, relaunch DevType, rerun."))

        // 2b. The running process started after the installed binary was written.
        if let running = result.devType {
            let binary = URL(fileURLWithPath: installed).appendingPathComponent("Contents/MacOS/DevType").path
            let modified = (try? FileManager.default.attributesOfItem(atPath: binary))?[.modificationDate] as? Date
            switch StaleProcessCheck.isStale(launchDate: running.launchDate, binaryModified: modified) {
            case .some(true):
                result.rows.append(PreflightRow(name: "Running process is the installed binary", ok: false,
                                                detail: "pid \(running.processIdentifier) launched \(running.launchDate.map { "\($0)" } ?? "?"), before the installed binary was written (\(modified.map { "\($0)" } ?? "?"))",
                                                remedy: "Quit DevType and launch it again, so the process runs the build that was installed."))
            case .some(false):
                result.rows.append(PreflightRow(name: "Running process is the installed binary", ok: true,
                                                detail: "launched after the binary was written"))
            case nil:
                result.rows.append(PreflightRow(name: "Running process is the installed binary", ok: false,
                                                detail: "launch time or binary time unreadable, so staleness cannot be ruled out",
                                                remedy: "Quit and relaunch DevType, then rerun."))
            }
        }

        // 3. Safari.
        result.safariURL = SystemFacts.safariURL()
        result.rows.append(PreflightRow(name: "Safari installed", ok: result.safariURL != nil,
                                        detail: result.safariURL?.path ?? "no application with bundle id \(HarnessConstants.safariBundleID)"))

        // 4/5. Permissions, attributed to the responsible app, not to this binary.
        let trusted = SystemFacts.accessibilityTrusted()
        result.rows.append(PreflightRow(name: "Accessibility permission", ok: trusted,
                                        detail: trusted ? "granted to \(who)" : "AXIsProcessTrusted is false for \(who)",
                                        remedy: "System Settings > Privacy & Security > Accessibility: switch on \(who) (the app you launched this from, not \"SafariHarness\"), then rerun."))
        let post = SystemFacts.postEventAccess()
        result.rows.append(PreflightRow(name: "Posting key events", ok: post,
                                        detail: post ? "allowed for \(who)" : "CGPreflightPostEventAccess is false for \(who)",
                                        remedy: "Grant \(who) in Privacy & Security > Accessibility; if macOS also lists it under Input Monitoring, enable that too."))

        // 6. Layout.
        let layout = SystemFacts.keyboardLayoutID()
        result.rows.append(PreflightRow(name: "US keyboard layout", ok: LayoutPolicy.isSupported(sourceID: layout),
                                        detail: layout ?? "current layout unreadable",
                                        remedy: "Switch the input source to U.S. or ABC. The harness posts US key codes and compares the characters Safari renders."))

        // 7. Fixture.
        let fixtureOK = FileManager.default.isReadableFile(atPath: fixtureURL.path)
        result.rows.append(PreflightRow(name: "Fixture page", ok: fixtureOK, detail: fixtureURL.path,
                                        remedy: "Run from a full checkout; \(HarnessConstants.fixtureRelativePath) is missing."))

        // 8. Snippet spec and library.
        let specProblems = spec.problems
        result.rows.append(PreflightRow(name: "Snippet spec", ok: specProblems.isEmpty,
                                        detail: specProblems.isEmpty ? "trigger \(spec.trigger) -> \(spec.expansion)" : specProblems.joined(separator: "; ")))
        do {
            let data = try Data(contentsOf: result.libraryURL)
            result.libraryData = data
            let report = LibraryProbe.evaluate(data: data, spec: spec)
            result.libraryReport = report
            var detail = "\(result.libraryURL.path): \(report.snippetCount) snippets, sha256 \(report.sha256.prefix(16)), read-only"
            if report.ok { detail += "; harness snippet present and valid" }
            else { detail += "; " + report.problems.joined(separator: "; ") }
            if !report.warnings.isEmpty { detail += " [warning: " + report.warnings.joined(separator: "; ") + "]" }
            let remedy = report.ok ? nil : """
                DevType has no supported way to add a snippet from outside (devtype://new only opens the editor, and \
                the library is watched live, so the harness never writes it). Run `Scripts/safari-harness.sh --add-snippet`, \
                press Save in the editor that opens, then rerun. By hand: trigger \(spec.trigger), text \(spec.expansion), plain text, \
                enabled, not a secret, no app restrictions.
                """
            result.rows.append(PreflightRow(name: "Library has the harness snippet", ok: report.ok, detail: detail, remedy: remedy))
        } catch {
            result.rows.append(PreflightRow(name: "Library has the harness snippet", ok: false,
                                            detail: "could not read \(result.libraryURL.path): \(error.localizedDescription)",
                                            remedy: "Open DevType once so it creates its library, then `--add-snippet`."))
        }

        // 9. AI palette (a distinct skip, never a pass).
        result.hotkey = AIHotkey.decode(SystemFacts.devTypePref(HarnessConstants.aiPaletteHotkeyKey) as? Data)
        if options.noAI {
            result.ai = .unavailable("--no-ai was given")
        } else if SystemFacts.devTypePrefBool(HarnessConstants.hotkeysDisabledKey) == true {
            result.ai = .unavailable("DevType's keyboard shortcuts are disabled (devtype.hotkeys.disabled)")
        } else if SystemFacts.devTypePrefBool(HarnessConstants.aiEnabledKey) != true {
            result.ai = .unavailable("AI is off in DevType (Preferences > AI, devtype.ai.enabled)")
        } else {
            result.ai = .available
        }
        let aiDetail: String
        switch result.ai {
        case .available: aiDetail = "enabled; palette hotkey \(result.hotkey.label)\(result.hotkey.isDefault ? " (default)" : "")"
        case .unavailable(let why): aiDetail = "proofread case will be SKIPPED: \(why)"
        }
        result.rows.append(PreflightRow(name: "AI proofread", ok: true, detail: aiDetail))
        return result
    }
}
