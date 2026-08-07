import Foundation

/// In-memory record of recent on-device AI transform outcomes, for `DiagnosticReport`.
///
/// Why this exists: an AI failure used to leave no trace in the one artifact people actually
/// paste when something breaks. `AITextTransformer` logs the failure detail to OSLog, but a
/// diagnostic report captures only the last 30 minutes of log and a support request often
/// arrives well after that window — and `GenerationError.Context.debugDescription` is the
/// only explanation the framework ever gives for a guardrail refusal. Losing it means the
/// question "why did the model refuse?" becomes permanently unanswerable.
///
/// Deliberately in-memory and process-scoped: this is a debugging aid, not telemetry. It is
/// never written to disk and never leaves the machine.
///
/// **Privacy:** stores only the transform kind and Apple's own diagnostic string. The user's
/// selected text and the generated output are never recorded here.
public final class AIDiagnosticsStore {
    public static let shared = AIDiagnosticsStore()

    /// Most recent failures retained; older entries are dropped.
    public static let capacity = 20

    public struct Failure: Equatable, Sendable {
        public let at: Date
        /// `AITransformKind.rawValue`.
        public let kind: String
        /// Short case label (`guardrailViolation`, `rateLimited`, …).
        public let error: String
        /// Apple's `GenerationError.Context.debugDescription`, or empty.
        public let detail: String

        public init(at: Date, kind: String, error: String, detail: String) {
            self.at = at
            self.kind = kind
            self.error = error
            self.detail = detail
        }
    }

    /// One resolved selection read, for the report's `-- On-device AI --` section.
    ///
    /// "Prompt Enhance says no text is selected" was previously unfalsifiable from a diagnostic
    /// report: nothing recorded whether the read failed on Accessibility, Secure Input, a mute,
    /// a missing focused element, or a genuinely empty selection.
    ///
    /// **Privacy:** records the outcome label, the app, how many AX probes answered, and the
    /// *length* of what was read. Never the text.
    public struct SelectionRead: Equatable, Sendable {
        public let at: Date
        /// `live` / `cached`, or a `SelectionReader.Failure.diagnosticLabel`.
        public let outcome: String
        public let bundleID: String?
        /// Distinct focused elements the AX probes resolved.
        public let candidateCount: Int
        /// Character count of the resolved selection (0 on failure). Never the content.
        public let characters: Int
        /// Per-probe AX status, e.g. `systemWide:noValue appScoped:err-25212 chain:noValue`.
        ///
        /// `candidateCount: 0` alone cannot distinguish an app whose accessibility tree was
        /// never switched on from one that is timing out — and those need opposite fixes.
        public let probeSummary: String

        public init(
            at: Date,
            outcome: String,
            bundleID: String?,
            candidateCount: Int,
            characters: Int,
            probeSummary: String = ""
        ) {
            self.at = at
            self.outcome = outcome
            self.bundleID = bundleID
            self.candidateCount = candidateCount
            self.characters = characters
            self.probeSummary = probeSummary
        }
    }

    private let lock = UnfairLock()
    private var failures: [Failure] = []
    private var successCount = 0
    private var lastSuccessAt: Date?
    private var lastSuccessKind: String?
    private var selectionReads: [SelectionRead] = []

    public init() {}

    // MARK: - Recording

    public func recordFailure(
        kind: String,
        error: String,
        detail: String,
        at date: Date = Date()
    ) {
        lock.lock()
        failures.append(Failure(at: date, kind: kind, error: error, detail: detail))
        if failures.count > Self.capacity {
            failures.removeFirst(failures.count - Self.capacity)
        }
        lock.unlock()
    }

    public func recordSuccess(kind: String, at date: Date = Date()) {
        lock.lock()
        successCount += 1
        lastSuccessAt = date
        lastSuccessKind = kind
        lock.unlock()
    }

    public func recordSelectionRead(
        outcome: String,
        bundleID: String?,
        candidateCount: Int,
        characters: Int,
        probeSummary: String = "",
        at date: Date = Date()
    ) {
        lock.lock()
        selectionReads.append(
            SelectionRead(
                at: date,
                outcome: outcome,
                bundleID: bundleID,
                candidateCount: candidateCount,
                characters: characters,
                probeSummary: probeSummary
            )
        )
        if selectionReads.count > Self.capacity {
            selectionReads.removeFirst(selectionReads.count - Self.capacity)
        }
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        failures.removeAll()
        successCount = 0
        lastSuccessAt = nil
        lastSuccessKind = nil
        selectionReads.removeAll()
        lock.unlock()
    }

    // MARK: - Reading

    public func recentFailures() -> [Failure] {
        lock.lock()
        let snapshot = failures
        lock.unlock()
        return snapshot
    }

    public func recentSelectionReads() -> [SelectionRead] {
        lock.lock()
        let snapshot = selectionReads
        lock.unlock()
        return snapshot
    }

    public func successes() -> Int {
        lock.lock()
        let count = successCount
        lock.unlock()
        return count
    }

    /// Formatted body for the report's `-- On-device AI --` section.
    ///
    /// `availabilityLine` / `enabled` / `localeNote` are passed in so this type stays free of
    /// any FoundationModels or preferences dependency (and remains testable without a model).
    public func diagnosticLines(
        enabled: Bool,
        availability: String,
        localeNote: String?,
        iso: ISO8601DateFormatter
    ) -> [String] {
        lock.lock()
        let snapshot = failures
        let successes = successCount
        let successAt = lastSuccessAt
        let successKind = lastSuccessKind
        let reads = selectionReads
        lock.unlock()

        var lines = [
            "Enabled: \(enabled)",
            "Availability: \(availability)"
        ]
        if let localeNote {
            lines.append("Locale: \(localeNote)")
        }
        lines.append(
            "Transforms this session: \(successes) succeeded, \(snapshot.count) failed"
                + (snapshot.count >= Self.capacity ? " (failure list capped at \(Self.capacity))" : "")
        )

        if let successAt {
            lines.append(
                "Last success: \(iso.string(from: successAt)) kind=\(successKind ?? "?")"
            )
        } else {
            lines.append("Last success: (none)")
        }

        guard let last = snapshot.last else {
            lines.append("Last failure: (none)")
            lines.append(contentsOf: Self.selectionReadLines(reads, iso: iso))
            return lines
        }
        lines.append(
            "Last failure: \(iso.string(from: last.at)) kind=\(last.kind) error=\(last.error)"
        )
        lines.append("  detail: \(last.detail.isEmpty ? "(none provided)" : last.detail)")

        // A repeated error class is the signal worth surfacing — one guardrail refusal is
        // noise, five on the same kind is a reproducible problem.
        if snapshot.count > 1 {
            var counts: [String: Int] = [:]
            for failure in snapshot {
                counts[failure.error, default: 0] += 1
            }
            let summary = counts
                .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            lines.append("Failure breakdown: \(summary)")
        }
        lines.append(contentsOf: Self.selectionReadLines(reads, iso: iso))
        return lines
    }

    /// `-- On-device AI --` tail describing how selection reads resolved.
    ///
    /// The last read is spelled out because it is almost always *the* read the user is
    /// complaining about; the histogram below it separates "one unlucky read" from "this app
    /// never reports a selection".
    static func selectionReadLines(
        _ reads: [SelectionRead],
        iso: ISO8601DateFormatter
    ) -> [String] {
        guard let last = reads.last else {
            return ["Selection reads: (none this session)"]
        }
        var lines = [
            "Selection reads: \(reads.count)"
                + (reads.count >= capacity ? " (capped at \(capacity))" : "")
        ]
        lines.append(
            "Last selection read: \(iso.string(from: last.at)) outcome=\(last.outcome) "
                + "app=\(last.bundleID ?? "(unknown)") axCandidates=\(last.candidateCount) "
                + "chars=\(last.characters)"
        )
        if !last.probeSummary.isEmpty {
            lines.append("Last selection AX probes: \(last.probeSummary)")
        }
        var counts: [String: Int] = [:]
        for read in reads {
            counts[read.outcome, default: 0] += 1
        }
        let summary = counts
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        lines.append("Selection read breakdown: \(summary)")
        return lines
    }
}
