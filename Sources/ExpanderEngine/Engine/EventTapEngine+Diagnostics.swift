import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Matched-then-dropped telemetry and diagnostics projections.
extension EventTapEngine {
    // MARK: - Matched-then-dropped telemetry

    /// Expansions that were **matched and then discarded**, by reason.
    ///
    /// This is the counter the field reports were missing. Every other number in the diagnostic
    /// report describes an expansion that reached the inject pipeline; a trigger that matched and
    /// was dropped before that point produced nothing at all — no outcome, no refuse provenance,
    /// no log line — which is indistinguishable, from the user's chair, from a snippet that does
    /// not exist. "It didn't expand" has to be answerable from the report.
    public struct MatchDropCounters: Equatable {
        /// `InjectionPlanner` refused on the cached permission snapshot (AX unavailable).
        public var plannerRefused = 0
        /// The live Secure Input check blocked the swallow after the polled flag said otherwise.
        public var secureInputLive = 0
        /// A held expansion was already in flight, so this match stood down.
        public var expansionInFlight = 0
        /// Suspensions force-cleared by `recoverOrphanedSuspensions`.
        public var orphanedSuspensionsRecovered = 0
        public var lastReason: String?
        /// Content-free length/hash metadata. Never the matched trigger itself.
        public var lastTriggerMetadata: String?
        public var lastBundleID: String?
        public var lastAt: Date?

        public init() {}

        public var total: Int { plannerRefused + secureInputLive + expansionInFlight }

        public var isEmpty: Bool { total == 0 && orphanedSuspensionsRecovered == 0 }
    }


    public var matchDropCounters: MatchDropCounters {
        matchDropLock.withLock { _matchDrops }
    }

    /// Records a match that will not become an expansion. Never silent: a dropped match gets a
    /// counter *and* a log line, because the counter alone cannot say when it happened.
    func recordMatchDrop(reason: String, trigger: String?, bundleID: String?) {
        let safeReason: String
        switch reason {
        case "plannerRefused", "secureInputLive", "expansionInFlight": safeReason = reason
        default: safeReason = "unknown"
        }
        let triggerMetadata = trigger.map {
            DiagnosticPrivacy.textShape($0, label: "trigger", domain: "match-drop-trigger")
        }
        let safeBundleID = bundleID.map {
            DiagnosticPrivacy.boundedIdentifier(
                $0,
                label: "bundleID",
                domain: "match-drop-bundle-id",
                maxUTF8Bytes: 256
            )
        }
        matchDropLock.lock()
        switch safeReason {
        case "plannerRefused": _matchDrops.plannerRefused += 1
        case "secureInputLive": _matchDrops.secureInputLive += 1
        case "expansionInFlight": _matchDrops.expansionInFlight += 1
        default: break
        }
        _matchDrops.lastReason = safeReason
        _matchDrops.lastTriggerMetadata = triggerMetadata
        _matchDrops.lastBundleID = safeBundleID
        _matchDrops.lastAt = Date()
        matchDropLock.unlock()
        DevTypeLog.eventTap.notice(
            """
            [EventTap] matched trigger dropped before expanding reason=\(safeReason, privacy: .public) \
            app=\(safeBundleID ?? "(unknown)", privacy: .public)
            """
        )
    }

    /// Report lines for matches that never became expansions.
    public func matchDropDiagnostics() -> [String] {
        let drops = matchDropCounters
        guard !drops.isEmpty else { return ["Matched-then-dropped: none"] }
        var lines = [
            "Matched-then-dropped: \(drops.total)"
                + " (planner-refused=\(drops.plannerRefused)"
                + " secure-input=\(drops.secureInputLive)"
                + " already-expanding=\(drops.expansionInFlight))"
        ]
        if drops.orphanedSuspensionsRecovered > 0 {
            lines.append(
                "  orphaned matching suspensions recovered: \(drops.orphanedSuspensionsRecovered)"
                    + " — matching was silently off before each recovery"
            )
        }
        if let reason = drops.lastReason, let at = drops.lastAt {
            lines.append(
                "  last: \(reason) \(drops.lastTriggerMetadata ?? "trigger=unknown")"
                    + " app=\(drops.lastBundleID ?? "(unknown)")"
                    + " at \(ISO8601DateFormatter().string(from: at))"
            )
        }
        return lines
    }

    /// Set when macOS Secure Event Input is active; matching is suppressed independently of user pause.
    public var isSecureInputActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSecureInputActive
        }
        set {
            lock.lock()
            let changed = _isSecureInputActive != newValue
            _isSecureInputActive = newValue
            if newValue && changed {
                ringBuffer.removeAll()
                layoutBuffer.clear()
                lastEventUTF16Count = 1
            }
            lock.unlock()
            if newValue && changed {
                // Secure Input can engage without a single keystroke reaching the tap (a
                // password sheet stealing focus). A hold armed just before that must not fire
                // on its timer — the deferred gate would refuse anyway where AX is readable,
                // but in an AX-opaque app the cancel here is the actual protection.
                heldCoordinator.cancelAll(reason: .unobservedInput)
            }
        }
    }
    /// Prefix-debounce lifecycle counters for the manager UI / `DiagnosticReport`.
    public func prefixDebounceDiagnostics() -> String {
        heldCoordinator.telemetry.summaryLine
    }

    // MARK: - §3.9 trigger-length diagnostics

    /// §3.9: triggers longer than `maxBufferCapacity`. They can never fire — the ring buffer and
    /// `LayoutBuffer` both cap at that length — and previously nothing said so.
    public func overlongTriggers() -> [String] {
        matchSnapshot.matcher.overlongTriggers
    }

    /// Human-readable form for the manager UI / `DiagnosticReport`. Empty when nothing is broken.
    public func overlongTriggerDiagnostics() -> [String] {
        overlongTriggerDiagnosticProjection(
            itemLimit: Int.max,
            byteLimit: Int.max
        ).retainedLines
    }

    /// Report path: count every overlong trigger while retaining only a bounded projection.
    /// Unlike `overlongTriggerDiagnostics()`, this never constructs an all-details array.
    func overlongTriggerDiagnosticProjection(
        itemLimit: Int = DiagnosticReport.headerProjectionItemLimit,
        byteLimit: Int = DiagnosticReport.headerProjectionByteLimit
    ) -> DiagnosticReport.HeaderProjection {
        let triggers = overlongTriggers()
        var builder = DiagnosticReport.HeaderProjectionBuilder(
            itemLimit: itemLimit,
            byteLimit: byteLimit
        )
        if !triggers.isEmpty {
            builder.observe(
                "\(triggers.count) trigger(s) exceed the \(EventTapEngine.maxBufferCapacity)-character match buffer and can never fire:"
            )
            for trigger in triggers {
                builder.observe(
                    "  triggerHash=\(DiagnosticPrivacy.fingerprint(trigger, domain: "typed-trigger"))"
                        + " triggerChars=\(trigger.count) triggerUTF16=\(trigger.utf16.count)"
                        + " reason=exceeds-match-buffer"
                )
            }
        }
        return builder.finish()
    }

    /// Every snippet in the library that can **never** respond to typing, and why.
    ///
    /// Three distinct causes, one user experience: the snippet sits in the list looking perfectly
    /// healthy, its trigger is spelled right, and typing it does nothing. Only one of the three
    /// was reported before, so the other two were indistinguishable from a broken engine.
    ///
    /// Takes the full library — including the secrets `snippets` filters out of the matcher — so
    /// it can account for what the matcher deliberately cannot see without exposing user text.
    public func silentNoExpandDiagnostics(library: [SnippetModel]? = nil) -> [String] {
        silentNoExpandDiagnosticProjection(
            library: library,
            itemLimit: Int.max,
            byteLimit: Int.max
        ).retainedLines
    }

    /// Report path for snippets that cannot fire. Counts every would-be line and emits only a
    /// bounded prefix, so a large imported library cannot allocate a second report-sized copy.
    func silentNoExpandDiagnosticProjection(
        library: [SnippetModel]? = nil,
        itemLimit: Int = DiagnosticReport.headerProjectionItemLimit,
        byteLimit: Int = DiagnosticReport.headerProjectionByteLimit
    ) -> DiagnosticReport.HeaderProjection {
        let all = library ?? libraryLock.withLock { _fullLibrary }
        var builder = DiagnosticReport.HeaderProjectionBuilder(
            itemLimit: itemLimit,
            byteLimit: byteLimit
        )

        // 1. Secrets. Deliberate (a keychain-backed snippet must never fire from typing), but
        //    invisible: nothing in the UI or the old report said "this trigger is typing-proof".
        let secretCount = all.lazy.filter {
            $0.enabled && $0.isSecret && !$0.triggerKeyword.isEmpty
        }.count
        if secretCount > 0 {
            builder.observe(
                "\(secretCount) secret snippet(s) never expand from a typed trigger by design —"
                    + " use the inline search panel instead:"
            )
            for snippet in all
            where snippet.enabled && snippet.isSecret && !snippet.triggerKeyword.isEmpty {
                builder.observe(
                    "  snippetHash=\(DiagnosticPrivacy.fingerprint(snippet.id.uuidString, domain: "snippet-id"))"
                        + " triggerHash=\(DiagnosticPrivacy.fingerprint(snippet.triggerKeyword, domain: "typed-trigger"))"
                        + " triggerChars=\(snippet.triggerKeyword.count)"
                        + " triggerUTF16=\(snippet.triggerKeyword.utf16.count)"
                        + " reason=secret-requires-explicit-action"
                )
            }
        }

        // 2. Overlong. Already reported separately; folded in here so one call answers the whole
        //    question rather than the caller having to know there are two lists.
        let overlong = overlongTriggers()
        if !overlong.isEmpty {
            builder.observe(
                "\(overlong.count) trigger(s) exceed the \(EventTapEngine.maxBufferCapacity)-character match buffer and can never fire:"
            )
            for trigger in overlong {
                builder.observe(
                    "  triggerHash=\(DiagnosticPrivacy.fingerprint(trigger, domain: "typed-trigger"))"
                        + " triggerChars=\(trigger.count) triggerUTF16=\(trigger.utf16.count)"
                        + " reason=exceeds-match-buffer"
                )
            }
        }

        // 3. Duplicates. Exact and case-insensitive tables are distinct, and app-scoped variants
        //    sharing one trigger can each be reachable in a different app. Only call a later row
        //    unreachable when the earlier variants cover every app context in which it applies.
        //    This is the same predicate language as `SnippetModel.appliesTo`: nil, every named
        //    bundle ID, and one fresh identifier represent the complete finite decision space.
        struct CollisionKey: Hashable {
            let trigger: String
            let caseSensitive: Bool
        }
        var precedingByKey: [CollisionKey: [SnippetModel]] = [:]
        var shadowedCount = 0
        for snippet in all where snippet.enabled && !snippet.isSecret && !snippet.triggerKeyword.isEmpty {
            let key = CollisionKey(
                trigger: snippet.isCaseSensitive
                    ? snippet.triggerKeyword
                    : snippet.triggerKeyword.lowercased(),
                caseSensitive: snippet.isCaseSensitive
            )
            let predecessors = precedingByKey[key] ?? []
            if let firstWinnerID = Self.firstWinnerCoveringEveryScope(
                of: snippet,
                predecessors: predecessors
            ) {
                _ = firstWinnerID
                if shadowedCount < Int.max { shadowedCount += 1 }
            }
            precedingByKey[key, default: []].append(snippet)
        }
        if shadowedCount > 0 {
            builder.observe(
                "\(shadowedCount) snippet(s) share a trigger with an earlier one and can never fire:"
            )
            precedingByKey.removeAll(keepingCapacity: true)
            for snippet in all
            where snippet.enabled && !snippet.isSecret && !snippet.triggerKeyword.isEmpty {
                let key = snippet.isCaseSensitive
                    ? CollisionKey(trigger: snippet.triggerKeyword, caseSensitive: true)
                    : CollisionKey(trigger: snippet.triggerKeyword.lowercased(), caseSensitive: false)
                let predecessors = precedingByKey[key] ?? []
                if let firstWinnerID = Self.firstWinnerCoveringEveryScope(
                    of: snippet,
                    predecessors: predecessors
                ) {
                    let comparison = snippet.isCaseSensitive ? "exact" : "case-folded"
                    builder.observe(
                        "  snippetHash=\(DiagnosticPrivacy.fingerprint(snippet.id.uuidString, domain: "snippet-id"))"
                            + " winnerHash=\(DiagnosticPrivacy.fingerprint(firstWinnerID.uuidString, domain: "snippet-id"))"
                            + " winnerScope=first-applicable"
                            + " coveringVariants=\(predecessors.count)"
                            + " triggerHash=\(DiagnosticPrivacy.fingerprint(key.trigger, domain: "typed-trigger"))"
                            + " triggerChars=\(snippet.triggerKeyword.count)"
                            + " triggerUTF16=\(snippet.triggerKeyword.utf16.count)"
                            + " comparison=\(comparison) reason=shadowed-by-earlier-snippets"
                    )
                }
                precedingByKey[key, default: []].append(snippet)
            }
        }

        return builder.finish()
    }

    /// Returns the first predecessor that wins in any applicable context only when the union of
    /// all predecessors covers every possible context for `snippet`. `nil` means at least one app
    /// context reaches the later variant, so calling it "unreachable" would be false.
    private static func firstWinnerCoveringEveryScope(
        of snippet: SnippetModel,
        predecessors: [SnippetModel]
    ) -> UUID? {
        guard !predecessors.isEmpty else { return nil }
        if let universalWinner = predecessors.first(where: {
            $0.includeApps.isEmpty && $0.excludeApps.isEmpty
        }) {
            return universalWinner.id
        }
        var namedBundleIDs = Set<String>()
        for candidate in predecessors {
            for bundleID in candidate.includeApps where !bundleID.isEmpty {
                namedBundleIDs.insert(bundleID.lowercased())
            }
            for bundleID in candidate.excludeApps where !bundleID.isEmpty {
                namedBundleIDs.insert(bundleID.lowercased())
            }
        }
        for bundleID in snippet.includeApps where !bundleID.isEmpty {
            namedBundleIDs.insert(bundleID.lowercased())
        }
        for bundleID in snippet.excludeApps where !bundleID.isEmpty {
            namedBundleIDs.insert(bundleID.lowercased())
        }
        var freshBundleID = "devtype.diagnostic.scope-probe"
        while namedBundleIDs.contains(freshBundleID.lowercased()) {
            freshBundleID += ".next"
        }
        var firstWinnerID: UUID?
        var foundApplicableContext = false
        func check(_ context: String?) -> Bool {
            guard snippet.appliesTo(bundleID: context) else { return true }
            foundApplicableContext = true
            guard let winner = predecessors.first(where: { $0.appliesTo(bundleID: context) }) else {
                return false
            }
            if firstWinnerID == nil { firstWinnerID = winner.id }
            return true
        }
        guard check(nil), check(freshBundleID) else { return nil }
        for bundleID in namedBundleIDs {
            guard check(bundleID) else { return nil }
        }
        return foundApplicableContext ? firstWinnerID : nil
    }

    func logOverlongTriggers(in snapshot: SnippetMatchSnapshot) {
        let triggers = snapshot.matcher.overlongTriggers
        guard !triggers.isEmpty else { return }
        DevTypeLog.eventTap.notice(
            "[EventTap] \(triggers.count, privacy: .public) trigger(s) longer than \(EventTapEngine.maxBufferCapacity, privacy: .public) characters can never fire — see overlongTriggerDiagnostics()"
        )
    }
}
