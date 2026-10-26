import CryptoKit
import ExpanderEngine
import Foundation

public enum VersionCheck: Equatable, Sendable {
    case match(Int)
    case mismatch(installed: String, expected: Int)
    case unreadable(String)

    /// `installed` is the installed bundle's CFBundleVersion; `expected` is `git rev-list --count HEAD`
    /// of the checkout, which is what `Scripts/package-app.sh` stamps.
    public static func compare(installed: String?, expected: Int?) -> VersionCheck {
        guard let expected else { return .unreadable("the checkout's commit count could not be read (git rev-list --count HEAD)") }
        guard let installed, !installed.isEmpty else { return .unreadable("CFBundleVersion could not be read from the installed app") }
        if let build = Int(installed.trimmingCharacters(in: .whitespacesAndNewlines)), build == expected { return .match(build) }
        return .mismatch(installed: installed, expected: expected)
    }

    public var isMatch: Bool { if case .match = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case .match(let n): return "installed build \(n) matches this checkout"
        case .mismatch(let installed, let expected):
            return "installed build \(installed) does not match this checkout (\(expected)); install this checkout (Scripts/install-app.sh) or run the harness from the checkout that was installed"
        case .unreadable(let why): return why
        }
    }
}

/// `CFBundleVersion` is read from the bundle on disk. A DevType launched before the binary was
/// replaced is still the old code, so the version check alone would pass against a stale process.
public enum StaleProcessCheck {
    /// Tolerates clock granularity: the process must not have started before the binary's mtime.
    public static func isStale(launchDate: Date?, binaryModified: Date?) -> Bool? {
        guard let launchDate, let binaryModified else { return nil }
        return launchDate.addingTimeInterval(2) < binaryModified
    }
}

/// One preflight row. `ok == false` stops a live run; a dry run prints it and carries on.
public struct PreflightRow: Equatable, Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String
    /// What the user should do when `ok` is false.
    public let remedy: String?

    public init(name: String, ok: Bool, detail: String, remedy: String? = nil) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.remedy = remedy
    }
}

public enum LibraryLocation {
    /// Mirrors `SnippetStore.resolveLocation` for the installed app: a configured location wins,
    /// otherwise `~/Library/Application Support/DevType/snippets.json`. `DEVTYPE_STORE_DIR` is not
    /// consulted: it is an environment override of a process this harness did not launch.
    public static func resolve(storeFilePath: String?, home: URL) -> URL {
        if let storeFilePath, !storeFilePath.isEmpty { return URL(fileURLWithPath: storeFilePath) }
        return home.appendingPathComponent("Library/Application Support/DevType/snippets.json")
    }
}

public struct HarnessSnippetSpec: Equatable, Sendable {
    public let trigger: String
    public let expansion: String

    public init(trigger: String = HarnessConstants.defaultTrigger, expansion: String = HarnessConstants.defaultExpansion) {
        self.trigger = trigger
        self.expansion = expansion
    }

    /// Problems with the spec itself, independent of any library.
    public var problems: [String] {
        var out: [String] = []
        if trigger.count < 4 { out.append("trigger must be at least 4 characters so no common word or shorter trigger fires on it") }
        if let first = trigger.first, AbbreviationMatcher.isWordCharacter(first) {
            out.append("trigger must start with punctuation: DevType fires those the moment the last character is typed, with no terminator")
        }
        if !KeyPlan.canType(trigger) { out.append("trigger has characters that are not on the US layout") }
        if trigger.contains(" ") { out.append("trigger must not contain a space") }
        if expansion.isEmpty || expansion.contains("\n") { out.append("expansion must be a single non-empty line") }
        if expansion.contains("{") || expansion.contains("%") || expansion.contains("$") {
            out.append("expansion must not contain macro characters ({ % $)")
        }
        if expansion.contains(trigger) { out.append("expansion must not contain the trigger") }
        return out
    }

    /// The `devtype://new` URL that opens DevType's snippet editor with these fields. Nothing is
    /// saved by the URL; the user clicks Save.
    public var editorURL: String {
        var components = URLComponents()
        components.scheme = "devtype"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "title", value: "Safari harness"),
            URLQueryItem(name: "trigger", value: trigger),
            URLQueryItem(name: "text", value: expansion)
        ]
        return components.string ?? "devtype://new"
    }
}

public struct LibraryReport: Equatable, Sendable {
    public var sha256: String
    public var byteCount: Int
    public var snippetCount: Int
    public var found: Bool
    /// Everything that would make the live run meaningless. Non-empty means refuse.
    public var problems: [String]
    /// Things worth knowing that do not invalidate the run.
    public var warnings: [String]

    public var ok: Bool { found && problems.isEmpty }
}

public enum LibraryProbe {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads nothing but the bytes it is handed. Checks that the harness snippet is present, will
    /// fire in Safari, and cannot collide with another trigger.
    public static func evaluate(data: Data, spec: HarnessSnippetSpec) -> LibraryReport {
        var report = LibraryReport(sha256: sha256(data), byteCount: data.count, snippetCount: 0, found: false, problems: spec.problems, warnings: [])

        let decoded: (all: [SnippetModel], expandable: [SnippetModel])
        do {
            let decoder = JSONDecoder()
            if let document = try? decoder.decode(SnippetDocument.self, from: data) {
                decoded = (document.snippets, SnippetStore.expandableSnippets(in: document.groups))
            } else {
                let all = try SnippetStore.decodeSnippets(from: data)
                decoded = (all, all.filter(\.enabled))
                report.warnings.append("library is not a versioned document; group-level restrictions were not checked")
            }
        } catch {
            report.problems.append("the library could not be decoded: \(error.localizedDescription)")
            return report
        }
        report.snippetCount = decoded.all.count

        let mine = decoded.all.filter { $0.triggerKeyword == spec.trigger }
        guard let snippet = mine.first else {
            report.problems.append("no snippet has the trigger \(spec.trigger)")
            return report
        }
        report.found = true
        if mine.count > 1 { report.problems.append("\(mine.count) snippets share the trigger \(spec.trigger)") }
        if snippet.isSecret { report.problems.append("the snippet is a secret; its value is not read from the library") }
        // The scope DevType matches against: the snippet with its group's enable flag and app
        // lists folded in (`SnippetStore.expandableSnippets`), not the raw stored row.
        let effective = decoded.expandable.first { $0.id == snippet.id } ?? snippet
        if !effective.enabled { report.problems.append("the snippet is disabled, or its group is disabled or shares no app with it") }
        if snippet.replacementText != spec.expansion {
            report.problems.append("the snippet's text is not exactly \(spec.expansion)")
        }
        if !snippet.isPlainText { report.problems.append("the snippet is not plain text") }
        if !snippet.aiTransform.isEmpty { report.problems.append("the snippet has an AI transform") }
        if !snippet.imagePath.isEmpty { report.problems.append("the snippet is an image snippet") }
        func listsSafari(_ apps: [String]) -> Bool {
            apps.contains { $0.caseInsensitiveCompare(HarnessConstants.safariBundleID) == .orderedSame }
        }
        if !effective.includeApps.isEmpty, !listsSafari(effective.includeApps) {
            report.problems.append("the snippet (with its group) is limited to apps that do not include Safari")
        }
        if listsSafari(effective.excludeApps) {
            report.problems.append("the snippet (or its group) is excluded in Safari")
        }

        // Other triggers that change when ours fires. Only snippets that can expand count.
        let others = decoded.expandable.filter {
            $0.id != snippet.id && $0.enabled && !$0.isSecret && !$0.triggerKeyword.isEmpty
                && ($0.includeApps.isEmpty || listsSafari($0.includeApps)) && !listsSafari($0.excludeApps)
        }
        for other in others {
            let t = other.triggerKeyword
            // A shorter trigger that is a prefix fires while ours is still being typed, unless it is
            // a bare word that waits for a terminator. A shorter suffix is harmless: the matcher
            // visits the longest candidate first.
            let firesWithoutTerminator = !AbbreviationMatcher.isWordCharacter(t.first ?? "a") || !other.requireWordBoundary
            if t.count < spec.trigger.count, spec.trigger.hasPrefix(t), firesWithoutTerminator {
                report.problems.append("another trigger (\(t.count) characters) is a prefix of \(spec.trigger) and would fire while it is being typed")
            } else if t.count > spec.trigger.count, t.hasPrefix(spec.trigger) {
                report.warnings.append("a longer trigger starts with \(spec.trigger); DevType holds \(spec.trigger) for its prefix-debounce window (500 ms by default) and the fast cases will be slower than a real user's")
            }
        }
        return report
    }
}

/// Exit-path check that the harness left the library alone. It never restores: DevType owns the
/// file while it runs and has a live watcher on it, so writing it back from here would be an
/// unsupported edit.
public enum LibraryGuard {
    public enum Outcome: Equatable, Sendable {
        case unchanged(sha256: String)
        case changed(before: String, after: String)
        case unreadable(String)

        public var summary: String {
            switch self {
            case .unchanged(let sha): return "library unchanged, byte for byte (sha256 \(sha.prefix(16)))"
            case .changed(let before, let after):
                return "LIBRARY CHANGED during the run (sha256 \(before.prefix(16)) -> \(after.prefix(16))); the harness never writes it, so DevType or you did. It was NOT restored: DevType owns the file while it runs"
            case .unreadable(let why): return "library could not be re-read after the run: \(why)"
            }
        }

        public var isClean: Bool { if case .unchanged = self { return true } else { return false } }
    }

    public static func compare(beforeSHA: String, after: Data?) -> Outcome {
        guard let after else { return .unreadable("file missing or unreadable") }
        let afterSHA = LibraryProbe.sha256(after)
        return afterSHA == beforeSHA ? .unchanged(sha256: afterSHA) : .changed(before: beforeSHA, after: afterSHA)
    }
}
