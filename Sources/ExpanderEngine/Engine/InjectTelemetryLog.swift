import Foundation

/// §3.2: Bounded inject outcomes and per-app delivery aggregates.
///
/// Inject telemetry used to be a single overwritten variable
/// (`PermissionCoordinator.lastInjectOutcome`), so five outcomes and a dozen refuse reasons all
/// collapsed into one slot. You could not answer "does expansion work in Slack?", "which refuse
/// reason dominates?", or "how often does the paste hold time out?".
///
/// This keeps the last `capacity` outcomes with the fields `debugLogInject` already computes but
/// only wrote under the opt-in `DebugTrace` default.
public final class InjectTelemetryLog {
    public static let shared = InjectTelemetryLog()

    public static let defaultCapacity = 256

    public struct Entry: Equatable {
        public let timestamp: Date
        /// Frontmost bundle ID at inject time (nil when unknown).
        public let bundleID: String?
        /// Inject path taken: "ax", "axPlusHID", "clipboard", "hid", … (nil when not recorded).
        public let path: String?
        public let outcome: PermissionCoordinator.InjectOutcome
        /// Refuse reason, when the outcome carries one.
        public let reason: String?

        public init(
            timestamp: Date = Date(),
            bundleID: String?,
            path: String?,
            outcome: PermissionCoordinator.InjectOutcome,
            reason: String?
        ) {
            self.timestamp = timestamp
            self.bundleID = bundleID
            self.path = path
            self.outcome = outcome
            self.reason = reason
        }

        /// Text reached the field and AX confirmed it.
        public var isVerifiedSuccess: Bool {
            outcome == .succeeded
        }

        /// Text was delivered but could not be verified (normal for Chrome / Electron).
        public var isUnverifiedDelivery: Bool {
            switch outcome {
            case .postedUnverified, .degradedAXOnly:
                return true
            case .succeeded, .refused, .failedSilent:
                return false
            }
        }
    }

    /// Per-bundle rollup returned by `statsByBundle()`.
    public struct BundleStats: Equatable {
        public var total: Int = 0
        public var succeeded: Int = 0
        public var deliveredUnverified: Int = 0
        public var refused: Int = 0
        public var failed: Int = 0

        public init() {}

        /// Fraction of attempts that put text in the field (verified or not).
        public var successRatio: Double {
            guard total > 0 else { return 0 }
            return Double(succeeded + deliveredUnverified) / Double(total)
        }
    }

    /// §8.1: the three events that can put text in the field *twice*, counted per app.
    ///
    /// Deliberately not inject outcomes — one expansion that duplicates text is still exactly one
    /// `Entry`, which is why the outcome histogram said `succeeded=14 failedSilent=1` while the
    /// user was looking at doubled text. These count the actions instead: a second ⌘V posted for a
    /// single expansion, and a trigger written back after a paste we could not see. A healthy app
    /// reports zero of both; a non-zero `pasteRetries` is the duplicate-expansion signature.
    public struct DuplicateRiskCounters: Equatable {
        /// Second (or later) ⌘V posted inside one expansion, on a confirmed-missing verdict.
        public var pasteRetries: Int = 0
        /// Trigger text written back after a paste was judged failed.
        public var triggerRestores: Int = 0
        /// `.failed` verdicts ignored because this app's AX cannot testify about delivery. These
        /// are the ones that *would* have re-pasted before the fix — useful for confirming the
        /// guard is doing work rather than sitting idle.
        public var suppressedMissVerdicts: Int = 0
        /// §8.3: keystrokes held during a delivery and replayed after it. Each one is a character
        /// that would previously have landed *in front of* the expansion — the `aScholarLM` bug.
        /// Non-zero here is the fix working, not a problem.
        public var typeAheadReplays: Int = 0
        public var typeAheadCharacters: Int = 0

        public init() {}

        public var isEmpty: Bool {
            pasteRetries == 0 && triggerRestores == 0 && suppressedMissVerdicts == 0
                && typeAheadReplays == 0
        }
    }

    /// §8.12: how long our payload actually stayed on the pasteboard when nothing proved the host
    /// read it.
    ///
    /// The wrong-text-pasted bug was invisible in every existing counter: the expansion recorded
    /// `postedUnverified` (a normal-looking outcome) while the user watched their old clipboard
    /// appear. These numbers make the *residency* itself reportable, so a recurrence can be read
    /// off a diagnostic report instead of reconstructed from timestamps.
    public struct ClipboardHoldCounters: Equatable {
        /// Pastes released with no evidence the host ever read the board.
        public var unverifiedHolds: Int = 0
        /// Of those, how many were extended because the app had stopped answering AX.
        public var stallExtensions: Int = 0
        /// Longest observed residency, milliseconds.
        public var maxHeldMillis: Int = 0

        public init() {}

        public var isEmpty: Bool { unverifiedHolds == 0 && stallExtensions == 0 }
    }

    public let capacity: Int
    private let lock = UnfairLock()
    private var entries: [Entry] = []
    private var duplicateRisk: [String: DuplicateRiskCounters] = [:]
    private var clipboardHolds: [String: ClipboardHoldCounters] = [:]
    /// Shared LRU across both aggregate families. Sharing the key budget prevents two independent
    /// maps from retaining twice as many hostile/one-off application identities.
    private var aggregateRecency: [String] = []
    /// Number of admissions into the bounded aggregate set. A key that returns after eviction is
    /// a new admission; exact lifetime uniqueness would itself require an unbounded seen-key set.
    private var aggregateObservedCount = 0
    private var aggregateDroppedCount = 0

    public init(capacity: Int = InjectTelemetryLog.defaultCapacity) {
        self.capacity = max(1, capacity)
        entries.reserveCapacity(self.capacity)
        aggregateRecency.reserveCapacity(self.capacity)
    }

    public func record(_ entry: Entry) {
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    public func record(
        outcome: PermissionCoordinator.InjectOutcome,
        bundleID: String?,
        path: String? = nil,
        reason: String? = nil,
        at timestamp: Date = Date()
    ) {
        record(
            Entry(
                timestamp: timestamp,
                bundleID: bundleID,
                path: path,
                outcome: outcome,
                reason: reason
            )
        )
    }

    /// Newest-last. `limit` keeps the most recent N.
    public func recentEntries(limit: Int? = nil) -> [Entry] {
        lock.lock()
        let all = entries
        lock.unlock()
        guard let limit, limit < all.count else { return all }
        return Array(all.suffix(max(0, limit)))
    }

    public func statsByBundle() -> [String: BundleStats] {
        var result: [String: BundleStats] = [:]
        for entry in recentEntries() {
            let key = entry.bundleID ?? "(unknown)"
            var stats = result[key] ?? BundleStats()
            stats.total += 1
            switch entry.outcome {
            case .succeeded:
                stats.succeeded += 1
            case .postedUnverified, .degradedAXOnly:
                stats.deliveredUnverified += 1
            case .refused:
                stats.refused += 1
            case .failedSilent:
                stats.failed += 1
            }
            result[key] = stats
        }
        return result
    }

    // MARK: - Duplicate risk

    public func recordPasteRetry(bundleID: String?) {
        mutateDuplicateRisk(bundleID: bundleID) {
            $0.pasteRetries = Self.incrementClamped($0.pasteRetries)
        }
    }

    public func recordTriggerRestore(bundleID: String?) {
        mutateDuplicateRisk(bundleID: bundleID) {
            $0.triggerRestores = Self.incrementClamped($0.triggerRestores)
        }
    }

    public func recordSuppressedMissVerdict(bundleID: String?) {
        mutateDuplicateRisk(bundleID: bundleID) {
            $0.suppressedMissVerdicts = Self.incrementClamped($0.suppressedMissVerdicts)
        }
    }

    public func recordTypeAheadReplay(bundleID: String?, characters: Int) {
        mutateDuplicateRisk(bundleID: bundleID) {
            $0.typeAheadReplays = Self.incrementClamped($0.typeAheadReplays)
            $0.typeAheadCharacters = Self.addingClamped(
                $0.typeAheadCharacters,
                max(0, characters)
            )
        }
    }

    public func duplicateRiskByBundle() -> [String: DuplicateRiskCounters] {
        lock.lock()
        defer { lock.unlock() }
        return duplicateRisk
    }

    // MARK: - Clipboard residency (§8.12)

    public func recordUnverifiedClipboardHold(bundleID: String?, heldFor seconds: TimeInterval) {
        let millis = Self.boundedMilliseconds(seconds)
        mutateClipboardHold(bundleID: bundleID) {
            $0.unverifiedHolds = Self.incrementClamped($0.unverifiedHolds)
            $0.maxHeldMillis = max($0.maxHeldMillis, millis)
        }
    }

    public func recordClipboardHoldExtension(bundleID: String?) {
        mutateClipboardHold(bundleID: bundleID) {
            $0.stallExtensions = Self.incrementClamped($0.stallExtensions)
        }
    }

    public func clipboardHoldsByBundle() -> [String: ClipboardHoldCounters] {
        lock.lock()
        defer { lock.unlock() }
        return clipboardHolds
    }

    private func mutateClipboardHold(bundleID: String?, _ body: (inout ClipboardHoldCounters) -> Void) {
        let key = Self.aggregateKey(bundleID)
        lock.lock()
        admitAggregateKeyLocked(key)
        var counters = clipboardHolds[key] ?? ClipboardHoldCounters()
        body(&counters)
        clipboardHolds[key] = counters
        lock.unlock()
    }

    private func mutateDuplicateRisk(bundleID: String?, _ body: (inout DuplicateRiskCounters) -> Void) {
        let key = Self.aggregateKey(bundleID)
        lock.lock()
        admitAggregateKeyLocked(key)
        var counters = duplicateRisk[key] ?? DuplicateRiskCounters()
        body(&counters)
        duplicateRisk[key] = counters
        lock.unlock()
    }

    private static func aggregateKey(_ bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "(unknown)" }
        return DiagnosticPrivacy.boundedIdentifier(
            bundleID,
            label: "injectBundleID",
            domain: "inject-telemetry-bundle-id"
        )
    }

    /// Must be called with `lock` held. Existing keys become most-recently used; a new key evicts
    /// the least-recently used identity from both counter families so the union stays bounded.
    private func admitAggregateKeyLocked(_ key: String) {
        if let existingIndex = aggregateRecency.firstIndex(of: key) {
            aggregateRecency.remove(at: existingIndex)
            aggregateRecency.append(key)
            return
        }

        aggregateObservedCount = Self.incrementClamped(aggregateObservedCount)
        if aggregateRecency.count >= capacity {
            let evicted = aggregateRecency.removeFirst()
            duplicateRisk.removeValue(forKey: evicted)
            clipboardHolds.removeValue(forKey: evicted)
            aggregateDroppedCount = Self.incrementClamped(aggregateDroppedCount)
        }
        aggregateRecency.append(key)
    }

    private static func incrementClamped(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }

    private static func addingClamped(_ value: Int, _ nonnegativeDelta: Int) -> Int {
        guard nonnegativeDelta > 0 else { return value }
        return value > Int.max - nonnegativeDelta ? Int.max : value + nonnegativeDelta
    }

    /// A diagnostic duration can arrive from a stalled clock or injected test seam. Converting
    /// NaN/infinity, or a finite value that rounds above `Int.max`, traps in Swift; represent those
    /// boundaries as zero (invalid/non-positive) or a truthful saturated maximum instead.
    private static func boundedMilliseconds(_ seconds: TimeInterval) -> Int {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        let scaled = seconds * 1_000
        guard scaled.isFinite, scaled < Double(Int.max) else { return Int.max }
        return Int(scaled.rounded())
    }

    public func refuseReasonHistogram() -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in recentEntries() {
            guard case .refused(let reason) = entry.outcome else { continue }
            result[reason, default: 0] += 1
        }
        return result
    }

    public func outcomeHistogram() -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in recentEntries() {
            result[Self.label(for: entry.outcome), default: 0] += 1
        }
        return result
    }

    /// Stable short label for an outcome (no associated value).
    public static func label(for outcome: PermissionCoordinator.InjectOutcome) -> String {
        switch outcome {
        case .succeeded: return "succeeded"
        case .postedUnverified: return "postedUnverified"
        case .refused: return "refused"
        case .degradedAXOnly: return "degradedAXOnly"
        case .failedSilent: return "failedSilent"
        }
    }

    /// Human-readable block for `DiagnosticReport`.
    public func summaryLines(topRefuseReasons: Int = 8) -> [String] {
        let projection = diagnosticSummaryProjection(topRefuseReasons: topRefuseReasons)
        var lines = [projection.summaryLine(label: "inject-telemetry")]
        lines.append(contentsOf: projection.retainedLines)
        return lines
    }

    /// Canonical bounded view for both the production report and Preferences. Storage eviction and
    /// projection truncation are reported separately: the retention line covers aggregate keys
    /// already evicted, while `HeaderProjection` covers report lines omitted by item/byte ceilings.
    func diagnosticSummaryProjection(
        topRefuseReasons: Int = 8,
        itemLimit: Int = DiagnosticReport.headerProjectionItemLimit,
        byteLimit: Int = DiagnosticReport.headerProjectionByteLimit
    ) -> DiagnosticReport.HeaderProjection {
        var builder = DiagnosticReport.HeaderProjectionBuilder(
            itemLimit: itemLimit,
            byteLimit: byteLimit
        )
        var independentlyOmittedLineCount = 0

        lock.lock()
        let all = entries
        var byBundle: [String: BundleStats] = [:]
        var outcomes: [String: Int] = [:]
        var refusals: [String: Int] = [:]
        for entry in all {
            let bundle = entry.bundleID?.isEmpty == false ? entry.bundleID! : "(unknown)"
            var stats = byBundle[bundle] ?? BundleStats()
            stats.total += 1
            switch entry.outcome {
            case .succeeded: stats.succeeded += 1
            case .postedUnverified, .degradedAXOnly: stats.deliveredUnverified += 1
            case .refused(let reason):
                stats.refused += 1
                refusals[reason, default: 0] += 1
            case .failedSilent: stats.failed += 1
            }
            byBundle[bundle] = stats
            outcomes[Self.label(for: entry.outcome), default: 0] += 1
        }

        if all.isEmpty {
            builder.observe("(no inject attempts recorded)")
        } else {
            builder.observe("Recorded inject attempts: \(all.count) (ring capacity \(capacity))")
            let outcomeLine = outcomes.sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            builder.observe("Outcomes: \(outcomeLine)")
        }

        builder.observe(
            "Per-app aggregate retention: observed=\(aggregateObservedCount); "
                + "retained=\(aggregateRecency.count)/\(capacity); "
                + "dropped=\(aggregateDroppedCount)"
        )

        let riskyCount = duplicateRisk.values.lazy.filter { !$0.isEmpty }.count
        if riskyCount > 0 {
            builder.observe(
                "Duplicate risk (text written twice for one expansion; apps=\(riskyCount)):"
            )
            let rankedRisk = duplicateRisk.lazy
                .filter { !$0.value.isEmpty }
                .sorted { lhs, rhs in
                    lhs.value.pasteRetries == rhs.value.pasteRetries
                        ? lhs.key < rhs.key
                        : lhs.value.pasteRetries > rhs.value.pasteRetries
                }
            for (bundle, counters) in rankedRisk {
                let safeBundle = DiagnosticPrivacy.boundedIdentifier(
                    bundle,
                    label: "injectBundleID",
                    domain: "inject-telemetry-bundle-id"
                )
                builder.observe(
                    "  \(safeBundle): re-pastes=\(counters.pasteRetries) "
                        + "trigger-restores=\(counters.triggerRestores) "
                        + "suppressed-AX-misses=\(counters.suppressedMissVerdicts) "
                        + "type-ahead-replays=\(counters.typeAheadReplays)"
                        + "(\(counters.typeAheadCharacters) chars)"
                )
            }
        }

        let holdCount = clipboardHolds.values.lazy.filter { !$0.isEmpty }.count
        if holdCount > 0 {
            builder.observe(
                "Clipboard residency (payload held with no proof the app read it; apps=\(holdCount)):"
            )
            let rankedHolds = clipboardHolds.lazy
                .filter { !$0.value.isEmpty }
                .sorted { lhs, rhs in
                    lhs.value.maxHeldMillis == rhs.value.maxHeldMillis
                        ? lhs.key < rhs.key
                        : lhs.value.maxHeldMillis > rhs.value.maxHeldMillis
                }
            for (bundle, counters) in rankedHolds {
                let safeBundle = DiagnosticPrivacy.boundedIdentifier(
                    bundle,
                    label: "injectBundleID",
                    domain: "inject-telemetry-bundle-id"
                )
                builder.observe(
                    "  \(safeBundle): unverified-holds=\(counters.unverifiedHolds) "
                        + "stall-extensions=\(counters.stallExtensions) "
                        + "longest=\(counters.maxHeldMillis)ms"
                )
            }
        }

        if !byBundle.isEmpty {
            builder.observe("Per-app delivery:")
            // At most the bounded outcome-ring capacity (256) distinct entries; sorting this map
            // cannot grow with the lifetime aggregate maps above.
            for (bundle, stats) in byBundle.sorted(by: {
                $0.value.total == $1.value.total ? $0.key < $1.key : $0.value.total > $1.value.total
            }) {
                let safeBundle = DiagnosticPrivacy.boundedIdentifier(
                    bundle,
                    label: "injectBundleID",
                    domain: "inject-telemetry-bundle-id"
                )
                let percent = Int((stats.successRatio * 100).rounded())
                builder.observe(
                    "  \(safeBundle): \(percent)% delivered "
                        + "(ok=\(stats.succeeded) unverified=\(stats.deliveredUnverified) "
                        + "refused=\(stats.refused) failed=\(stats.failed) of \(stats.total))"
                )
            }
        }

        if !refusals.isEmpty {
            builder.observe("Refuse reasons:")
            let rankedRefusals = refusals.sorted(by: {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            })
            let visibleRefusals = rankedRefusals.prefix(max(0, topRefuseReasons))
            independentlyOmittedLineCount = rankedRefusals.count - visibleRefusals.count
            for (reason, count) in visibleRefusals {
                let safeReason = DiagnosticPrivacy.boundedIdentifier(
                    reason,
                    label: "refuseReason",
                    domain: "inject-refuse-reason"
                )
                builder.observe("  \(count)× \(safeReason)")
            }
        }
        lock.unlock()
        let visibleProjection = builder.finish()
        let completeObservedCount = visibleProjection.observedCount
            > Int.max - independentlyOmittedLineCount
            ? Int.max
            : visibleProjection.observedCount + independentlyOmittedLineCount
        return builder.finish(totalObservedCount: completeObservedCount)
    }

    /// Test / recovery hook.
    public func reset() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        duplicateRisk.removeAll(keepingCapacity: true)
        clipboardHolds.removeAll(keepingCapacity: true)
        aggregateRecency.removeAll(keepingCapacity: true)
        aggregateObservedCount = 0
        aggregateDroppedCount = 0
        lock.unlock()
    }
}
