import Foundation

/// §3.2: Bounded ring of inject outcomes.
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

    public let capacity: Int
    private let lock = UnfairLock()
    private var entries: [Entry] = []
    private var duplicateRisk: [String: DuplicateRiskCounters] = [:]

    public init(capacity: Int = InjectTelemetryLog.defaultCapacity) {
        self.capacity = max(1, capacity)
        entries.reserveCapacity(self.capacity)
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
        mutateDuplicateRisk(bundleID: bundleID) { $0.pasteRetries += 1 }
    }

    public func recordTriggerRestore(bundleID: String?) {
        mutateDuplicateRisk(bundleID: bundleID) { $0.triggerRestores += 1 }
    }

    public func recordSuppressedMissVerdict(bundleID: String?) {
        mutateDuplicateRisk(bundleID: bundleID) { $0.suppressedMissVerdicts += 1 }
    }

    public func recordTypeAheadReplay(bundleID: String?, characters: Int) {
        mutateDuplicateRisk(bundleID: bundleID) {
            $0.typeAheadReplays += 1
            $0.typeAheadCharacters += max(0, characters)
        }
    }

    public func duplicateRiskByBundle() -> [String: DuplicateRiskCounters] {
        lock.lock()
        defer { lock.unlock() }
        return duplicateRisk
    }

    private func mutateDuplicateRisk(bundleID: String?, _ body: (inout DuplicateRiskCounters) -> Void) {
        let key = bundleID?.isEmpty == false ? bundleID! : "(unknown)"
        lock.lock()
        var counters = duplicateRisk[key] ?? DuplicateRiskCounters()
        body(&counters)
        duplicateRisk[key] = counters
        lock.unlock()
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
        let all = recentEntries()
        guard !all.isEmpty else { return ["(no inject attempts recorded)"] }

        var lines: [String] = ["Recorded inject attempts: \(all.count) (ring capacity \(capacity))"]

        let outcomes = outcomeHistogram().sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        lines.append("Outcomes: " + outcomes.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

        let byBundle = statsByBundle().sorted { lhs, rhs in
            lhs.value.total == rhs.value.total ? lhs.key < rhs.key : lhs.value.total > rhs.value.total
        }
        if !byBundle.isEmpty {
            lines.append("Per-app delivery:")
            for (bundle, stats) in byBundle {
                let percent = Int((stats.successRatio * 100).rounded())
                lines.append(
                    "  \(bundle): \(percent)% delivered "
                        + "(ok=\(stats.succeeded) unverified=\(stats.deliveredUnverified) "
                        + "refused=\(stats.refused) failed=\(stats.failed) of \(stats.total))"
                )
            }
        }

        let risky = duplicateRiskByBundle()
            .filter { !$0.value.isEmpty }
            .sorted { lhs, rhs in
                lhs.value.pasteRetries == rhs.value.pasteRetries
                    ? lhs.key < rhs.key
                    : lhs.value.pasteRetries > rhs.value.pasteRetries
            }
        if !risky.isEmpty {
            lines.append("Duplicate risk (text written twice for one expansion):")
            for (bundle, counters) in risky {
                lines.append(
                    "  \(bundle): re-pastes=\(counters.pasteRetries) "
                        + "trigger-restores=\(counters.triggerRestores) "
                        + "suppressed-AX-misses=\(counters.suppressedMissVerdicts) "
                        + "type-ahead-replays=\(counters.typeAheadReplays)"
                        + "(\(counters.typeAheadCharacters) chars)"
                )
            }
        }

        let refusals = refuseReasonHistogram().sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        if !refusals.isEmpty {
            lines.append("Refuse reasons:")
            for (reason, count) in refusals.prefix(max(0, topRefuseReasons)) {
                lines.append("  \(count)× \(reason)")
            }
        }
        return lines
    }

    /// Test / recovery hook.
    public func reset() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        duplicateRisk.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
