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
    /// §8.4: `(bundle, role)` keys whose AX has *positively proven* it can see a paste land — a
    /// delivery was AX-confirmed inside the operational hold window at least once. This is the
    /// second trust dimension, separate from `learned`: `learned` answers "do AX writes work",
    /// this answers "do AX reads tell the truth fast enough to act on". Persisted alongside
    /// verdicts under a distinct key namespace.
    private var deliveryReadProven: Set<String> = []

    /// The app build string observed when a `(bundle, role)` was condemned.
    ///
    /// Condemnation is otherwise permanent, and its own escape hatch is unreachable:
    /// `trustedStreak` rehabilitates after verified AX writes, but a condemned app is never
    /// given an AX write to verify, so the streak can never start. The result is a one-way
    /// door — 11 of 16 apps in a real field report — and every expansion into those apps then
    /// pastes via the clipboard, which is what produces `postedUnverified` and holds the
    /// payload on the general pasteboard while waiting for evidence that can never arrive.
    ///
    /// An app *update* is the one event that plausibly changes the answer, and the store
    /// already accepts the converse ("an app update can regress a once-truthful mirror").
    /// Re-opening the verdict on a build change costs at most one re-tested expansion per
    /// update — the same cost a never-seen app already pays — and is self-limiting: nothing is
    /// re-probed while the app sits still.
    private var condemnedBuild: [String: String] = [:]

    /// Resolves an app's current build string. Injectable so tests never touch the filesystem;
    /// the default is cached per bundle ID because the inject path consults verdicts often.
    private let currentBuild: (String) -> String?

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

    public init(
        fileURL: URL?,
        currentBuild: @escaping (String) -> String? = AppBuildStamp.shared.build(forBundleID:)
    ) {
        self.fileURL = fileURL
        self.currentBuild = currentBuild
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let loaded = Self.loadFromDisk(fileURL: fileURL)
            learned = loaded.verdicts
            deliveryReadProven = loaded.proven
            condemnedBuild = loaded.condemnedBuild
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
        let lower = bundleID.lowercased()
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
             "com.github.githubapp", "com.github.GitHubClient",
             // Microsoft Office suite (Word, Excel, PowerPoint, Outlook, OneNote, Remote Desktop, To-Do, etc.).
             // Custom document rendering & AX bridge report success on setSelectedText without mutating.
             "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.PowerPoint",
             "com.microsoft.Outlook", "com.microsoft.onenote.mac",
             // Google Antigravity (Electron IDE). Field incident 2026-08-07: AX write
             // false-succeeded, and its AXValue mirror also never showed a landed paste inside
             // the hold window — the stale `.failed` reads drove a re-paste plus a trigger
             // restore, tripling the text. Seeded so no fresh install pays that first attempt.
             "com.google.antigravity":
            return .falseSuccess
        default:
            // Electron / Chromium shells (Cursor, VS Code, Slack variants, Notion, Linear, …).
            if lower.hasPrefix("com.todesktop.") { return .falseSuccess }
            if lower.hasPrefix("com.microsoft.vscode") { return .falseSuccess }
            if lower.hasPrefix("com.visualstudio.code") { return .falseSuccess }
            if lower.hasPrefix("com.electron.") { return .falseSuccess }
            // Microsoft ecosystem (all Office, productivity, remote desktop, and developer tools).
            if lower.hasPrefix("com.microsoft.") { return .falseSuccess }
            // Mozilla / Gecko ecosystem (Firefox, Nightly, Developer Edition, Tor Browser, Thunderbird).
            if lower.hasPrefix("org.mozilla.") || lower.hasPrefix("org.torproject.") { return .falseSuccess }
            // JetBrains & Java IDEs (IntelliJ IDEA, PyCharm, WebStorm, CLion, GoLand, Rider, Android Studio, Fleet, etc.).
            if lower.hasPrefix("com.jetbrains.") || lower == "com.google.android.studio" { return .falseSuccess }
            // Non-native document suites (LibreOffice, OpenOffice, WPS Office).
            if lower.hasPrefix("org.libreoffice.") || lower.hasPrefix("org.openoffice.") || lower.hasPrefix("com.kingsoft.wpsoffice.") {
                return .falseSuccess
            }
            // Productivity, Notes & Task Management (Notion, Obsidian, Logseq, Linear, Evernote, ClickUp, Asana).
            if lower.hasPrefix("notion.") || lower.hasPrefix("com.notion.") || lower == "md.obsidian" || lower.hasPrefix("com.logseq.") {
                return .falseSuccess
            }
            if lower.hasPrefix("com.linear") || lower.hasPrefix("com.evernote.") || lower.hasPrefix("com.clickup.") || lower.hasPrefix("com.asana.") {
                return .falseSuccess
            }
            // Design, Developer & Creative tools (Figma, Canva, Adobe CC, Postman, Insomnia, GitKraken, Zed, Sublime).
            if lower.hasPrefix("com.figma.") || lower.hasPrefix("com.canva.") || lower.hasPrefix("com.adobe.") {
                return .falseSuccess
            }
            if lower.hasPrefix("com.postmanlabs.") || lower.hasPrefix("com.insomnia.") || lower.hasPrefix("com.axosoft.gitkraken") || lower.hasPrefix("com.gitkraken.") {
                return .falseSuccess
            }
            if lower.hasPrefix("dev.zed.zed") || lower.hasPrefix("com.sublimetext.") || lower == "com.sublimemerge" {
                return .falseSuccess
            }
            // Communication & Chat (Signal, Telegram, Zoom, Discord variants).
            if lower.hasPrefix("org.whispersystems.signal") || lower.contains("telegram") || lower.hasPrefix("us.zoom.") {
                return .falseSuccess
            }
            if lower.hasPrefix("com.discord") || lower == "com.hammerandchisel.discord" {
                return .falseSuccess
            }
            // AI Clients & WebKit/Blink Browsers (ChatGPT, Orion, DuckDuckGo).
            if lower.hasPrefix("com.openai.") || lower == "com.kagi.orion" || lower.hasPrefix("com.duckduckgo.") {
                return .falseSuccess
            }
            // Electron, but not under any of the prefixes above. Its AXValue is readable and
            // never contains pasted text, so delivery verification cannot judge it.
            if lower == "com.anthropic.claudefordesktop" { return .falseSuccess }
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
        if let composite {
            if composite == .falseSuccess, retireStaleCondemnation(key: compositeKey, bundleID: canonical) {
                return .unknown
            }
            return composite
        }
        if let bundleOnly {
            if bundleOnly == .falseSuccess, retireStaleCondemnation(key: canonical, bundleID: canonical) {
                return .unknown
            }
            return bundleOnly
        }
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
    /// Clears a condemnation recorded against a build the app has since moved past.
    ///
    /// Returns true when the verdict was retired, so the caller answers `.unknown` and the next
    /// expansion tries AX again and re-verifies it. A condemnation with no stamp (recorded by a
    /// build before stamping existed, or where the build could not be read) is left alone —
    /// absence of evidence is not evidence the app changed. The build lookup happens outside
    /// the lock: it can touch the filesystem, and this is consulted from the inject path.
    private func retireStaleCondemnation(key: String, bundleID: String) -> Bool {
        lock.lock()
        let stamped = condemnedBuild[key]
        lock.unlock()
        guard let stamped, let now = currentBuild(bundleID), now != stamped else { return false }

        lock.lock()
        // Re-check under the lock: another thread may have re-condemned since the read above.
        guard condemnedBuild[key] == stamped, learned[key] == .falseSuccess else {
            lock.unlock()
            return false
        }
        learned.removeValue(forKey: key)
        condemnedBuild.removeValue(forKey: key)
        trustedStreak[key] = 0
        // A new build's AX is unproven in both dimensions; read proof is re-earned too.
        deliveryReadProven.remove(key)
        // Re-open the door, but remember the record behind it. The two-strike ladder exists so
        // that one transient (focus stolen mid-inject) cannot permanently condemn a *never-seen*
        // app; an app with a prior conviction needs no such benefit of the doubt, and each strike
        // costs the user a refused expansion. Seeding one strike makes the re-test single-shot:
        // prove it works, or go straight back to the verdict it already had.
        unverifiableStrikes[key] = max(unverifiableStrikes[key] ?? 0, Self.unverifiableStrikesToCondemn - 1)
        lock.unlock()
        DevTypeLog.inject.notice(
            "[Inject] AX write condemnation retired for \(key, privacy: .public) — build changed \(stamped, privacy: .public) → \(now, privacy: .public); re-testing once"
        )
        scheduleSave()
        return true
    }

    public func canConfirmDelivery(bundleID: String?) -> Bool {
        canConfirmDelivery(bundleID: bundleID, role: nil)
    }

    /// §8.4: role-aware form. The field incident this closes: the false-success verdict for
    /// `com.google.antigravity` was recorded under `(bundle, AXTextArea)`, but the paste hold
    /// queried delivery trust with the bundle alone — missed the condemnation, believed the stale
    /// "text missing" answer, and re-pasted plus restored the trigger over a paste that landed.
    public func canConfirmDelivery(bundleID: String?, role: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return verdict(for: bundleID, role: role) != .falseSuccess
    }

    // MARK: - Delivery-read proof (§8.4)

    /// Has a paste in this `(bundle, role)` ever been AX-confirmed inside the hold window?
    /// Composite key first, then the bundle-level key, mirroring `verdict(for:role:)`.
    public func hasProvenDeliveryReads(bundleID: String, role: String?) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let canonical = Self.canonicalBundleID(bundleID)
        let compositeKey = Self.verdictKey(bundleID: canonical, role: role)
        lock.lock()
        defer { lock.unlock() }
        return deliveryReadProven.contains(compositeKey) || deliveryReadProven.contains(canonical)
    }

    /// Record an in-window AX-confirmed delivery — the only event that earns read trust.
    ///
    /// Deliberately *not* fed by late confirmations (the deferred re-verify): an app whose mirror
    /// catches up only after the hold window would earn proof it cannot honor inside the window,
    /// and the next in-window `.failed` would drive a duplicating re-paste.
    public func recordDeliveryConfirmed(bundleID: String?, role: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        let key = Self.verdictKey(bundleID: Self.canonicalBundleID(bundleID), role: role)
        lock.lock()
        let inserted = deliveryReadProven.insert(key).inserted
        lock.unlock()
        if inserted {
            let safeBundleID = DevTypeLog.boundedPublicIdentifier(bundleID, label: "bundleID")
            let safeRole = role.map {
                DevTypeLog.boundedPublicIdentifier($0, label: "axRole")
            }
            DevTypeLog.inject.info(
                "[Inject] delivery reads proven for \(safeBundleID, privacy: .public)\(safeRole.map { " role=\($0)" } ?? "", privacy: .public) — confirmed-miss corrections enabled"
            )
            scheduleSave()
        }
    }

    /// §8.4: the single gate for every *corrective* write a delivery `.failed` can drive —
    /// re-pasting Cmd+V and restoring the erased trigger. Both add text to the field, so both
    /// require this app's AX to be a **proven truthful witness**, not merely an uncondemned one:
    ///
    ///  1. Not condemned — a false-success app's reads are known to lie (role-aware).
    ///  2. Positively proven — some earlier paste here was AX-confirmed *inside* the hold window.
    ///
    /// An unknown app failing (2) gets exactly one paste and a `postedUnverified` outcome. That is
    /// the deliberate trade: the cost of wrongly *withholding* a correction is one missing
    /// expansion the user retypes; the cost of wrongly *performing* one is doubled text in the
    /// user's document. A readable-and-truthful app converts to proven on its first confirmed
    /// delivery (the overwhelmingly common case in native apps), so the ladder is armed from the
    /// second expansion on. A readable-but-lying app (Electron/Chromium stale mirrors) can never
    /// prove itself in-window, so it is suppressed forever — which is the fix.
    public func mayActOnDeliveryFailure(bundleID: String?, role: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        guard canConfirmDelivery(bundleID: bundleID, role: role) else { return false }
        return hasProvenDeliveryReads(bundleID: bundleID, role: role)
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
        let canonical = Self.canonicalBundleID(bundleID)
        let key = Self.verdictKey(bundleID: canonical, role: role)
        // Read the build before taking the lock — this can hit the filesystem.
        let build = currentBuild(canonical)
        lock.lock()
        let previous = learned[key]
        learned[key] = .falseSuccess
        // Stamp what we condemned, so a later version of this app is re-tested rather than
        // inheriting a verdict earned by different code.
        if let build { condemnedBuild[key] = build } else { condemnedBuild.removeValue(forKey: key) }
        trustedStreak[key] = 0
        // §8.4: fresh evidence that this AX lies revokes any earlier read proof — an app update
        // can regress a once-truthful mirror, and stale proof would re-arm the corrective ladder
        // its own reads can no longer justify. Proof is re-earned by the next confirmed delivery.
        deliveryReadProven.remove(key)
        let changed = previous != .falseSuccess
        lock.unlock()
        if changed {
            let safeBundleID = DevTypeLog.boundedPublicIdentifier(bundleID, label: "bundleID")
            let safeRole = role.map {
                DevTypeLog.boundedPublicIdentifier($0, label: "axRole")
            }
            let roleLabel = (safeRole?.isEmpty == false) ? " role=\(safeRole ?? "")" : ""
            DevTypeLog.inject.notice(
                "[Inject] AX selected-text write condemned for \(safeBundleID, privacy: .public)\(roleLabel, privacy: .public) — HID paste from now on"
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
        // §8.4: an unverifiable-after-write observation is evidence the mirror has gone bad;
        // suspend read proof immediately rather than waiting for the condemning second strike.
        deliveryReadProven.remove(key)
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
                condemnedBuild.removeValue(forKey: key)
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
        deliveryReadProven.removeAll()
        condemnedBuild.removeAll()
        lock.unlock()
        scheduleSave()
    }

    /// Bounded diagnostic view selected while the dictionary is locked. It counts every
    /// non-unknown verdict but keeps only the lexicographically earliest `limit`, so a machine
    /// with thousands of learned apps cannot turn a diagnostic report into an unbounded
    /// dictionary copy plus a full sort.
    func learnedVerdictProjection(
        limit: Int
    ) -> (entries: [(key: String, verdict: Verdict)], observedCount: Int) {
        let resolvedLimit = max(0, limit)
        var retained: [(key: String, verdict: Verdict)] = []
        retained.reserveCapacity(min(resolvedLimit, 64))
        var observedCount = 0

        lock.lock()
        for (key, verdict) in learned where verdict != .unknown {
            if observedCount < Int.max { observedCount += 1 }
            guard resolvedLimit > 0 else { continue }
            if retained.count < resolvedLimit {
                retained.append((key: key, verdict: verdict))
                continue
            }
            guard let greatestIndex = retained.indices.max(by: {
                retained[$0].key < retained[$1].key
            }), key < retained[greatestIndex].key else { continue }
            retained[greatestIndex] = (key: key, verdict: verdict)
        }
        lock.unlock()

        retained.sort { $0.key < $1.key }
        return (retained, observedCount)
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
            let provenSnapshot = self.deliveryReadProven
            let condemnedSnapshot = self.condemnedBuild
            self.lock.unlock()
            Self.saveToDisk(
                snapshot, proven: provenSnapshot, condemnedBuild: condemnedSnapshot, fileURL: fileURL
            )
        }
    }

    private struct PersistedFile: Codable {
        var version: Int
        /// key -> raw verdict string ("trusted" / "falseSuccess"). §8.4 read-proof entries share
        /// this map under a `deliveryRead|` key prefix with the raw value "confirmed"; builds
        /// that predate them skip unrecognised raw values, so the file stays interchangeable.
        var entries: [String: String]
    }

    /// §8.4: key namespace for persisted read-proof entries.
    private static let deliveryReadKeyPrefix = "deliveryRead|"
    private static let deliveryReadRawValue = "confirmed"
    /// Key namespace for the build a condemnation was recorded against. Its raw value is the
    /// build string, which no verdict parser accepts — so older builds skip these entries and
    /// simply keep today's permanent-condemnation behaviour.
    private static let condemnedBuildKeyPrefix = "condemnedBuild|"

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

    private static func loadFromDisk(
        fileURL: URL
    ) -> (verdicts: [String: Verdict], proven: Set<String>, condemnedBuild: [String: String]) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(PersistedFile.self, from: data) else {
            return ([:], [], [:])
        }
        guard file.version <= persistenceSchemaVersion else {
            // Written by a newer build — do not guess at its semantics, just relearn.
            DevTypeLog.inject.notice(
                "[Inject] AX write-capability file schema \(file.version, privacy: .public) is newer than \(persistenceSchemaVersion, privacy: .public) — ignoring"
            )
            return ([:], [], [:])
        }
        var verdicts: [String: Verdict] = [:]
        var proven: Set<String> = []
        var condemnedBuild: [String: String] = [:]
        for (key, raw) in file.entries {
            guard !key.isEmpty else { continue }
            // Same rule as the read-proof namespace above, for the same reason: a *verdict*
            // recorded for a (pathological) bundle ID that begins with this prefix must not be
            // swallowed as a build stamp. A stamp's value is an arbitrary version string, which
            // is never one of the verdict raw values — that asymmetry is what separates them.
            if key.hasPrefix(condemnedBuildKeyPrefix), verdict(fromRaw: raw) == nil {
                let bare = String(key.dropFirst(condemnedBuildKeyPrefix.count))
                if !bare.isEmpty, !raw.isEmpty { condemnedBuild[bare] = raw }
                continue
            }
            // A proof entry is prefix AND marker value together. Matching on the prefix alone
            // would silently drop a *verdict* recorded for a (pathological) bundle ID that
            // happens to begin with the prefix — namespaces must never eat each other's data.
            if key.hasPrefix(deliveryReadKeyPrefix), raw == deliveryReadRawValue {
                let bare = String(key.dropFirst(deliveryReadKeyPrefix.count))
                if !bare.isEmpty { proven.insert(bare) }
                continue
            }
            guard let verdict = verdict(fromRaw: raw) else { continue }
            verdicts[key] = verdict
        }
        // A stamp for a key that is no longer condemned is dead weight; drop it on load.
        condemnedBuild = condemnedBuild.filter { verdicts[$0.key] == .falseSuccess }
        return (verdicts, proven, condemnedBuild)
    }

    private static func saveToDisk(
        _ verdicts: [String: Verdict],
        proven: Set<String>,
        condemnedBuild: [String: String],
        fileURL: URL
    ) {
        var entries: [String: String] = [:]
        for (key, verdict) in verdicts {
            guard let raw = rawValue(for: verdict) else { continue }
            entries[key] = raw
        }
        for key in proven {
            entries[deliveryReadKeyPrefix + key] = deliveryReadRawValue
        }
        for (key, build) in condemnedBuild where verdicts[key] == .falseSuccess && !build.isEmpty {
            // A version string that happens to equal a verdict raw value would read back as a
            // verdict. Dropping it costs one app one re-test opportunity; persisting it would
            // corrupt the verdict namespace. Fail toward the old, safe behaviour.
            guard verdict(fromRaw: build) == nil else { continue }
            entries[condemnedBuildKeyPrefix + key] = build
        }
        let file = PersistedFile(version: persistenceSchemaVersion, entries: entries)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DevTypeLog.inject.error(
                "[Inject] Failed to persist AX write-capability verdicts \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
        }
    }
}
