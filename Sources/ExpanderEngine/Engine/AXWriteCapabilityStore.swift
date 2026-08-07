import Foundation

/// Tracks, per frontmost app (and §3.3 per focused AX role), whether
/// `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` can be trusted.
///
/// A hardcoded bundle-ID allowlist cannot keep up: every Electron shell, every Chromium wrapper and
/// every new web-view app has the same broken behaviour (AX reports `.success`, the field never
/// changes). The static list is therefore only a *seed*; the real verdict is learned at runtime the
/// first time an app false-succeeds, and every later expand in that app skips the AX write.
///
/// §3.3 fixes two problems with that learning:
///  1. It was in-memory only, so every relaunch re-paid the first-expansion false-success cost per
///     app — and the false-success path is the one that duplicates or eats the user's text.
///     Verdicts are now persisted as JSON under Application Support.
///  2. It was keyed on bundle ID alone, so a Chromium app's web view (AX lies) and its native
///     `NSTextField` (AX works) shared one verdict — the first web-view false-success condemned
///     native fields forever. Verdicts can now be keyed on `(bundleID, AXRole)`.
public final class AXWriteCapabilityStore {
    public static let shared = AXWriteCapabilityStore(fileURL: AXWriteCapabilityStore.defaultFileURL())

    public enum Verdict: Equatable {
        /// Never observed — try AX, verify the result.
        case unknown
        /// AX selected-text writes verified as actually mutating the field.
        case trusted
        /// AX reported success without mutating — never attempt the AX write again.
        case falseSuccess
    }

    /// §2.4: `os_unfair_lock` rather than `NSLock` — this is consulted from the inject path,
    /// which must not stall behind a lower-QoS holder.
    private let lock = UnfairLock()
    private var learned: [String: Verdict] = [:]
    /// Consecutive verified AX writes needed to clear a `falseSuccess` verdict. AX writes are not
    /// attempted once an app is condemned, so in practice this only matters if a seed is overridden.
    private var trustedStreak: [String: Int] = [:]
    /// Unverifiable-after-write strikes this launch, keyed like `learned`. Deliberately not
    /// persisted — see `recordUnverifiableAfterWrite`.
    private var unverifiableStrikes: [String: Int] = [:]

    /// `nil` disables persistence (used by tests and by the plain `init()`).
    private let fileURL: URL?
    private let ioQueue = DispatchQueue(label: "com.devtype.axwritecapability.io", qos: .utility)
    /// Coalescing flag so a burst of verdict changes results in one write.
    private var savePending = false

    public static let persistenceFileName = "ax-write-capability.json"
    public static let persistenceSchemaVersion = 1

    /// In-memory store. Kept as the no-argument initializer so existing tests stay isolated from
    /// the on-disk file used by `shared`.
    public convenience init() {
        self.init(fileURL: nil)
    }

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            learned = Self.loadFromDisk(fileURL: fileURL)
        }
    }

    /// `~/Library/Application Support/DevType/ax-write-capability.json` (AppMuteStore's pattern).
    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("DevType", isDirectory: true)
        return dir.appendingPathComponent(persistenceFileName)
    }

    // MARK: - Keys

    /// §3.3: `(bundleID, role)` composite. A `nil`/empty role keeps the legacy bundle-only key so
    /// callers that have not adopted roles keep exactly today's behaviour.
    public static func verdictKey(bundleID: String, role: String?) -> String {
        guard let role, !role.isEmpty else { return bundleID }
        return "\(bundleID)|\(role)"
    }

    /// Collapses a Chromium "installed web app" shell to its host browser's identity.
    ///
    /// Chromium browsers give every installed web app (PWA / app shortcut) a **fresh bundle ID**
    /// of the form `<browser-bundle-id>.app.<32-character id>` — e.g. the GitHub app installed
    /// from Chrome is `com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg`. It is the same
    /// renderer with the same broken AX, but under a bundle ID no seed list or learned verdict
    /// has ever seen. The observed failure: a PWA passes every capability check as "unknown",
    /// the AX write is attempted, the field cannot be verified afterwards, and the expansion is
    /// refused — on every attempt, forever, in every newly installed web app.
    ///
    /// The suffix alphabet is Chromium's extension-ID encoding: exactly 32 characters drawn from
    /// `a`–`p` (a hex digest re-mapped past `f`, precisely so it cannot look like anything
    /// else). Requiring the full `.app.` + 32×[a–p] shape means an ordinary reverse-DNS bundle
    /// ID that merely contains ".app." cannot be misclassified.
    ///
    /// Every read and write below canonicalizes first, so one verdict covers the browser and
    /// every web app it installs — past and future — with no per-app relearning.
    public static func canonicalBundleID(_ bundleID: String) -> String {
        // Safari web apps ("Add to Dock", macOS 14+): `com.apple.Safari.WebApp.<UUID>`. Same
        // WebKit view as Safari itself, same seeded verdict — and the UUID requirement keeps
        // any unrelated `…Safari.WebApp.something` from collapsing.
        let safariWebAppPrefix = "com.apple.Safari.WebApp."
        if bundleID.hasPrefix(safariWebAppPrefix),
           UUID(uuidString: String(bundleID.dropFirst(safariWebAppPrefix.count))) != nil {
            return "com.apple.Safari"
        }

        guard let marker = bundleID.range(of: ".app.", options: .backwards),
              marker.lowerBound != bundleID.startIndex else {
            return bundleID
        }
        let suffix = bundleID[marker.upperBound...]
        guard suffix.count == 32, suffix.allSatisfy({ $0 >= "a" && $0 <= "p" }) else {
            return bundleID
        }
        return String(bundleID[..<marker.lowerBound])
    }

    /// Known-bad seeds. Chromium/Electron shells and Messages report success without mutating.
    /// Kept deliberately small — it only saves the *first* wasted attempt; learning covers the rest.
    ///
    /// Canonicalizes first, so callers that hit this statically (`SelectionReader.isWeakAXApp`)
    /// see the same verdict for an installed web app as for its host browser without having to
    /// know canonicalization exists.
    public static func seedVerdict(bundleID rawBundleID: String) -> Verdict {
        let bundleID = canonicalBundleID(rawBundleID)
        switch bundleID {
        case "com.apple.MobileSMS", "com.apple.iChat",
             "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
             "com.google.Chrome.dev", "com.brave.Browser", "com.microsoft.edgemac",
             "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
             "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.facebook.archon",
             // WhatsApp Desktop: Electron AXTextArea reports selected-text write success without
             // mutating. Paying that first expand duplicates/eats text or erases the trigger and
             // then "succeeds" via unverifiable AX direct with nothing pasted.
             "net.whatsapp.WhatsApp", "net.whatsapp.WhatsApp.beta",
             "com.microsoft.teams2", "com.microsoft.teams", "com.apple.Safari",
             "com.github.githubapp", "com.github.GitHubClient":
            return .falseSuccess
        default:
            // Electron / Chromium shells (Cursor, VS Code, Slack variants, Notion, Linear, …).
            if bundleID.hasPrefix("com.todesktop.") { return .falseSuccess }
            if bundleID.hasPrefix("com.microsoft.VSCode") { return .falseSuccess }
            if bundleID.hasPrefix("com.visualstudio.code") { return .falseSuccess }
            if bundleID.hasPrefix("com.electron.") { return .falseSuccess }
            // Electron, but not under any of the prefixes above. Its AXValue is readable and
            // never contains pasted text, so delivery verification cannot judge it.
            if bundleID == "com.anthropic.claudefordesktop" { return .falseSuccess }
            // Installed web apps (Chromium PWAs, Safari "Add to Dock") never reach this branch
            // under their wrapper IDs — `canonicalBundleID` collapsed them to the host browser
            // above, which the exact-match list already covers.
            return .unknown
        }
    }

    // MARK: - Queries

    /// Legacy bundle-only shim. Equivalent to `verdict(for:role:)` with a nil role.
    public func verdict(for bundleID: String) -> Verdict {
        verdict(for: bundleID, role: nil)
    }

    /// §3.3: role-aware verdict. Falls back to the bundle-only verdict, then to the seed list, so
    /// nothing learned before roles were threaded through is lost.
    public func verdict(for bundleID: String, role: String?) -> Verdict {
        guard !bundleID.isEmpty else { return .unknown }
        let canonical = Self.canonicalBundleID(bundleID)
        let compositeKey = Self.verdictKey(bundleID: canonical, role: role)
        // Verdicts learned before canonicalization existed were stored under the raw web-app
        // bundle ID — keep reading those so an existing install loses nothing.
        let rawCompositeKey = Self.verdictKey(bundleID: bundleID, role: role)
        lock.lock()
        let composite = learned[compositeKey] ?? (canonical == bundleID ? nil : learned[rawCompositeKey])
        let bundleOnly = learned[canonical] ?? (canonical == bundleID ? nil : learned[bundleID])
        lock.unlock()
        if let composite { return composite }
        if let bundleOnly { return bundleOnly }
        return Self.seedVerdict(bundleID: canonical)
    }

    /// True when the AX selected-text write should be skipped entirely for this app.
    public func shouldSkipAXSelectedText(bundleID: String) -> Bool {
        shouldSkipAXSelectedText(bundleID: bundleID, role: nil)
    }

    public func shouldSkipAXSelectedText(bundleID: String, role: String?) -> Bool {
        verdict(for: bundleID, role: role) == .falseSuccess
    }

    /// §8.1: may this app's AX be believed when it says the pasted text is *not* in the field?
    ///
    /// A different question from `shouldSkipAXSelectedText`, answered by the same evidence: an app
    /// whose AX reports writes it never performed is an app whose `AXValue` does not reflect the
    /// real field. Its `.failed` delivery verdict is therefore a false negative — permanent, not
    /// transient — and the two actions that verdict drives both put text in the field twice:
    /// re-pasting duplicates the expansion, and restoring the trigger appends it after text that
    /// did land. `nil`/unknown bundles stay trusted, so nothing outside the condemned set changes.
    public func canConfirmDelivery(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return verdict(for: bundleID) != .falseSuccess
    }

    // MARK: - Learning

    /// Record that AX claimed success but the field did not change. Sticky across launches.
    public func recordFalseSuccess(bundleID: String) {
        recordFalseSuccess(bundleID: bundleID, role: nil)
    }

    /// §3.3: condemn only `(bundleID, role)` when a role is known, so a Chromium web view cannot
    /// condemn the same app's native text fields.
    ///
    /// Recorded under the *canonical* bundle ID, so a lesson learned in one Chromium web app
    /// covers the host browser and every sibling web app instead of being relearned per install.
    public func recordFalseSuccess(bundleID: String, role: String?) {
        guard !bundleID.isEmpty else { return }
        let key = Self.verdictKey(bundleID: Self.canonicalBundleID(bundleID), role: role)
        lock.lock()
        let previous = learned[key]
        learned[key] = .falseSuccess
        trustedStreak[key] = 0
        let changed = previous != .falseSuccess
        lock.unlock()
        if changed {
            let roleLabel = (role?.isEmpty == false) ? " role=\(role ?? "")" : ""
            DevTypeLog.inject.notice(
                "[Inject] AX selected-text write condemned for \(bundleID, privacy: .public)\(roleLabel, privacy: .public) — HID paste from now on"
            )
            scheduleSave()
        }
    }

    /// Outcome of one "attempted AX write, field unverifiable afterwards" observation.
    public enum UnverifiableStrikeOutcome: Equatable {
        /// First strike this launch — noted, nothing condemned. A transient (the user switching
        /// focus mid-inject, an AX tree caught mid-teardown) looks identical to a broken shell
        /// on a single observation, and a wrong condemnation is effectively permanent: AX writes
        /// stop being attempted, so the rehabilitation streak can never accumulate.
        case struck(count: Int)
        /// The strike threshold was reached — the app is now condemned (persisted).
        case condemned
        /// Already condemned; nothing to do.
        case alreadyCondemned
    }

    /// Strikes within one launch before an unverifiable-after-write refusal condemns the app.
    /// A genuinely broken shell hits the second strike on the user's very next expansion
    /// attempt (usually seconds later, when they retype the trigger that just refused); a
    /// transient almost never repeats against the same `(bundle, role)`.
    public static let unverifiableStrikesToCondemn = 2

    /// Escalating self-heal for the "AX write attempted, field unverifiable even after the
    /// settle retry" refusal — the signature of a Chromium/Electron shell no seed or learned
    /// verdict has seen (a freshly installed web app hits it on its first-ever expansion).
    ///
    /// Strikes are deliberately in-memory only: persisting suspicion would let two transients
    /// months apart condemn a healthy app. Condemnation itself persists via
    /// `recordFalseSuccess`, so once an app *is* judged broken the fix survives relaunch.
    public func recordUnverifiableAfterWrite(
        bundleID: String,
        role: String?
    ) -> UnverifiableStrikeOutcome {
        guard !bundleID.isEmpty else { return .struck(count: 0) }
        if verdict(for: bundleID, role: role) == .falseSuccess {
            return .alreadyCondemned
        }
        let key = Self.verdictKey(bundleID: Self.canonicalBundleID(bundleID), role: role)
        lock.lock()
        let strikes = (unverifiableStrikes[key] ?? 0) + 1
        unverifiableStrikes[key] = strikes
        lock.unlock()
        guard strikes >= Self.unverifiableStrikesToCondemn else {
            return .struck(count: strikes)
        }
        recordFalseSuccess(bundleID: bundleID, role: role)
        return .condemned
    }

    /// Record a verified AX write. Does not resurrect a condemned app on a single observation.
    public func recordTrusted(bundleID: String) {
        recordTrusted(bundleID: bundleID, role: nil)
    }

    public func recordTrusted(bundleID: String, role: String?) {
        guard !bundleID.isEmpty else { return }
        let key = Self.verdictKey(bundleID: Self.canonicalBundleID(bundleID), role: role)
        lock.lock()
        var changed = false
        if learned[key] == .falseSuccess {
            let streak = (trustedStreak[key] ?? 0) + 1
            trustedStreak[key] = streak
            if streak >= Self.trustedStreakToRehabilitate {
                learned[key] = .trusted
                trustedStreak[key] = 0
                changed = true
            }
        } else {
            changed = learned[key] != .trusted
            learned[key] = .trusted
            trustedStreak[key] = 0
        }
        lock.unlock()
        if changed {
            scheduleSave()
        }
    }

    public static let trustedStreakToRehabilitate = 3

    /// Test / recovery hook. Also clears the persisted file when this store owns one.
    public func reset() {
        lock.lock()
        learned.removeAll()
        trustedStreak.removeAll()
        unverifiableStrikes.removeAll()
        lock.unlock()
        scheduleSave()
    }

    /// Diagnostic dump: `key -> verdict`, sorted.
    public func learnedVerdicts() -> [(key: String, verdict: Verdict)] {
        lock.lock()
        let snapshot = learned
        lock.unlock()
        return snapshot
            .map { (key: $0.key, verdict: $0.value) }
            .sorted { $0.key < $1.key }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard let fileURL else { return }
        lock.lock()
        if savePending {
            lock.unlock()
            return
        }
        savePending = true
        lock.unlock()

        // Coalesce a burst of verdict changes into one write, off the inject path entirely.
        ioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.savePending = false
            let snapshot = self.learned
            self.lock.unlock()
            Self.saveToDisk(snapshot, fileURL: fileURL)
        }
    }

    private struct PersistedFile: Codable {
        var version: Int
        /// key -> raw verdict string ("trusted" / "falseSuccess").
        var entries: [String: String]
    }

    private static func rawValue(for verdict: Verdict) -> String? {
        switch verdict {
        case .unknown: return nil
        case .trusted: return "trusted"
        case .falseSuccess: return "falseSuccess"
        }
    }

    private static func verdict(fromRaw raw: String) -> Verdict? {
        switch raw {
        case "trusted": return .trusted
        case "falseSuccess": return .falseSuccess
        default: return nil
        }
    }

    private static func loadFromDisk(fileURL: URL) -> [String: Verdict] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(PersistedFile.self, from: data) else {
            return [:]
        }
        guard file.version <= persistenceSchemaVersion else {
            // Written by a newer build — do not guess at its semantics, just relearn.
            DevTypeLog.inject.notice(
                "[Inject] AX write-capability file schema \(file.version, privacy: .public) is newer than \(persistenceSchemaVersion, privacy: .public) — ignoring"
            )
            return [:]
        }
        var result: [String: Verdict] = [:]
        for (key, raw) in file.entries {
            guard !key.isEmpty, let verdict = verdict(fromRaw: raw) else { continue }
            result[key] = verdict
        }
        return result
    }

    private static func saveToDisk(_ verdicts: [String: Verdict], fileURL: URL) {
        var entries: [String: String] = [:]
        for (key, verdict) in verdicts {
            guard let raw = rawValue(for: verdict) else { continue }
            entries[key] = raw
        }
        let file = PersistedFile(version: persistenceSchemaVersion, entries: entries)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DevTypeLog.inject.error(
                "[Inject] Failed to persist AX write-capability verdicts: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
