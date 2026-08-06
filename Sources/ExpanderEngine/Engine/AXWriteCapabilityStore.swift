import Foundation

/// Tracks, per frontmost app, whether `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)`
/// can be trusted.
///
/// A hardcoded bundle-ID allowlist cannot keep up: every Electron shell, every Chromium wrapper and
/// every new web-view app has the same broken behaviour (AX reports `.success`, the field never
/// changes). The static list is therefore only a *seed*; the real verdict is learned at runtime the
/// first time an app false-succeeds, and every later expand in that app skips the AX write.
public final class AXWriteCapabilityStore {
    public static let shared = AXWriteCapabilityStore()

    public enum Verdict: Equatable {
        /// Never observed — try AX, verify the result.
        case unknown
        /// AX selected-text writes verified as actually mutating the field.
        case trusted
        /// AX reported success without mutating — never attempt the AX write again.
        case falseSuccess
    }

    private let lock = NSLock()
    private var learned: [String: Verdict] = [:]
    /// Consecutive verified AX writes needed to clear a `falseSuccess` verdict. AX writes are not
    /// attempted once an app is condemned, so in practice this only matters if a seed is overridden.
    private var trustedStreak: [String: Int] = [:]

    public init() {}

    /// Known-bad seeds. Chromium/Electron shells and Messages report success without mutating.
    /// Kept deliberately small — it only saves the *first* wasted attempt; learning covers the rest.
    public static func seedVerdict(bundleID: String) -> Verdict {
        switch bundleID {
        case "com.apple.MobileSMS", "com.apple.iChat",
             "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
             "com.google.Chrome.dev", "com.brave.Browser", "com.microsoft.edgemac",
             "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
             "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.facebook.archon",
             "com.microsoft.teams2", "com.microsoft.teams", "com.apple.Safari",
             "com.github.githubapp", "com.github.GitHubClient":
            return .falseSuccess
        default:
            // Electron / Chromium shells (Cursor, VS Code, Slack variants, Notion, Linear, …).
            if bundleID.hasPrefix("com.todesktop.") { return .falseSuccess }
            if bundleID.hasPrefix("com.microsoft.VSCode") { return .falseSuccess }
            if bundleID.hasPrefix("com.visualstudio.code") { return .falseSuccess }
            if bundleID.hasPrefix("com.electron.") { return .falseSuccess }
            return .unknown
        }
    }

    public func verdict(for bundleID: String) -> Verdict {
        guard !bundleID.isEmpty else { return .unknown }
        lock.lock()
        let learnedVerdict = learned[bundleID]
        lock.unlock()
        if let learnedVerdict { return learnedVerdict }
        return Self.seedVerdict(bundleID: bundleID)
    }

    /// True when the AX selected-text write should be skipped entirely for this app.
    public func shouldSkipAXSelectedText(bundleID: String) -> Bool {
        verdict(for: bundleID) == .falseSuccess
    }

    /// Record that AX claimed success but the field did not change. Sticky for the session.
    public func recordFalseSuccess(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        lock.lock()
        let previous = learned[bundleID]
        learned[bundleID] = .falseSuccess
        trustedStreak[bundleID] = 0
        lock.unlock()
        if previous != .falseSuccess {
            DevTypeLog.inject.notice(
                "[Inject] AX selected-text write condemned for \(bundleID, privacy: .public) — HID paste from now on"
            )
        }
    }

    /// Record a verified AX write. Does not resurrect a condemned app on a single observation.
    public func recordTrusted(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if learned[bundleID] == .falseSuccess {
            let streak = (trustedStreak[bundleID] ?? 0) + 1
            trustedStreak[bundleID] = streak
            if streak >= Self.trustedStreakToRehabilitate {
                learned[bundleID] = .trusted
                trustedStreak[bundleID] = 0
            }
            return
        }
        learned[bundleID] = .trusted
        trustedStreak[bundleID] = 0
    }

    public static let trustedStreakToRehabilitate = 3

    /// Test / recovery hook.
    public func reset() {
        lock.lock()
        learned.removeAll()
        trustedStreak.removeAll()
        lock.unlock()
    }
}
