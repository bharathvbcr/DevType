import Foundation

/// In-memory record of recent on-device AI transform outcomes, for `DiagnosticReport`.
///
/// Why this exists: an AI failure used to leave no trace in the one artifact people actually
/// paste when something breaks. The stable failure class is retained because a diagnostic report
/// captures only a short OSLog window and a support request often arrives later. Provider error
/// prose is reduced to length plus a process-salted fingerprint: frameworks may echo input,
/// prompt fragments, endpoint bodies, and local paths in their descriptions.
///
/// Deliberately in-memory and process-scoped: this is a debugging aid, not telemetry. It is
/// never written to disk and never leaves the machine.
///
/// **Privacy:** stores only whitelisted transform/failure labels and content-free shape metadata.
/// The user's selected text, generated output, and provider descriptions are never retained.
public final class AIDiagnosticsStore {
    public static let shared = AIDiagnosticsStore(activitySink: ActivityHistoryStore.publish)

    /// Most recent failures retained; older entries are dropped.
    public static let capacity = 20

    public struct Failure: Equatable, Sendable {
        public let at: Date
        /// `AITransformKind.rawValue`.
        public let kind: String
        /// Short case label (`guardrailViolation`, `rateLimited`, …).
        public let error: String
        /// Content-free shape of provider detail (`detailChars`, `detailUTF8`, salted hash), or
        /// empty. Never the provider string itself.
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
        /// `SelectionReader.ReadVia.rawValue` — which AX attribute answered.
        ///
        /// Tells an app that answers the plain attribute apart from one that is marker-only,
        /// which is the difference between "works everywhere" and "works in AppKit apps".
        public let via: String
        /// Wall-clock cost of the read. A read that fails *and* took a second is a stalled app,
        /// not a missing selection.
        public let elapsedMilliseconds: Int

        public init(
            at: Date,
            outcome: String,
            bundleID: String?,
            candidateCount: Int,
            characters: Int,
            probeSummary: String = "",
            via: String = "",
            elapsedMilliseconds: Int = 0
        ) {
            self.at = at
            self.outcome = outcome
            self.bundleID = bundleID
            self.candidateCount = candidateCount
            self.characters = characters
            self.probeSummary = probeSummary
            self.via = via
            self.elapsedMilliseconds = elapsedMilliseconds
        }
    }

    private let lock = UnfairLock()
    private var failures: [Failure] = []
    private var failureObservedCount = 0
    private var successCount = 0
    private var lastSuccessAt: Date?
    private var lastSuccessKind: String?
    private var selectionReads: [SelectionRead] = []
    private var selectionReadObservedCount = 0
    private let activitySink: ((ActivitySignal) -> Void)?

    private static let allowedKinds: Set<String> = Set(AITransformKind.allCases.map(\.rawValue))
        .union(["injection-boundary"])
    private static let allowedErrors: Set<String> = [
        "assetsUnavailable",
        "concurrentRequests",
        "decodingFailure",
        "emptyOutput",
        "exceededContextWindowSize",
        "guardrailViolation",
        "languageDrift",
        "promptEcho",
        "rateLimited",
        "refusal",
        "refusalProse",
        "unexpectedRewrite",
        "unknown",
        "unsupportedGuide",
        "unsupportedLanguageOrLocale",
    ]
    private static let detailHashCharacterLimit = 4_096

    public init() {
        activitySink = nil
    }

    init(activitySink: @escaping (ActivitySignal) -> Void) {
        self.activitySink = activitySink
    }

    // MARK: - Recording

    public func recordFailure(
        kind: String,
        error: String,
        detail: String,
        at date: Date = Date()
    ) {
        let safeKind = Self.allowedKinds.contains(kind) ? kind : "unknown"
        let safeError = Self.allowedErrors.contains(error) ? error : "unknown"
        let safeDetail = Self.contentFreeDetailSummary(detail)
        lock.lock()
        failureObservedCount = Self.saturatingAdd(failureObservedCount, 1)
        failures.append(Failure(at: date, kind: safeKind, error: safeError, detail: safeDetail))
        if failures.count > Self.capacity {
            failures.removeFirst(failures.count - Self.capacity)
        }
        lock.unlock()
        activitySink?(.aiFailed)
    }

    public func recordSuccess(kind: String, at date: Date = Date()) {
        lock.lock()
        successCount += 1
        lastSuccessAt = date
        lastSuccessKind = Self.allowedKinds.contains(kind) ? kind : "unknown"
        lock.unlock()
    }

    private static func contentFreeDetailSummary(_ detail: String) -> String {
        guard !detail.isEmpty else { return "" }
        let sample = String(detail.prefix(detailHashCharacterLimit))
        return "detailChars=\(detail.count) detailUTF8=\(detail.utf8.count)"
            + " detailHash=\(DiagnosticPrivacy.fingerprint(sample, domain: "ai-failure-detail"))"
            + " detailSampled=\(detail.count > detailHashCharacterLimit)"
    }

    public func recordSelectionRead(
        outcome: String,
        bundleID: String?,
        candidateCount: Int,
        characters: Int,
        probeSummary: String = "",
        via: String = "",
        elapsedMilliseconds: Int = 0,
        at date: Date = Date()
    ) {
        let safeOutcome = DiagnosticPrivacy.boundedIdentifier(
            outcome,
            label: "selectionOutcome",
            domain: "ai-selection-outcome"
        )
        let safeBundleID = bundleID.map {
            DiagnosticPrivacy.boundedIdentifier(
                $0,
                label: "selectionBundleID",
                domain: "ai-selection-bundle-id"
            )
        }
        let safeProbeSummary = DiagnosticPrivacy.boundedIdentifier(
            probeSummary,
            label: "selectionProbes",
            domain: "ai-selection-probes"
        )
        let safeVia = DiagnosticPrivacy.boundedIdentifier(
            via,
            label: "selectionVia",
            domain: "ai-selection-via"
        )
        lock.lock()
        selectionReadObservedCount = Self.saturatingAdd(selectionReadObservedCount, 1)
        selectionReads.append(
            SelectionRead(
                at: date,
                outcome: safeOutcome,
                bundleID: safeBundleID,
                candidateCount: candidateCount,
                characters: characters,
                probeSummary: safeProbeSummary,
                via: safeVia,
                elapsedMilliseconds: elapsedMilliseconds
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
        failureObservedCount = 0
        successCount = 0
        lastSuccessAt = nil
        lastSuccessKind = nil
        selectionReads.removeAll()
        selectionReadObservedCount = 0
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
        let observedFailures = failureObservedCount
        let successes = successCount
        let successAt = lastSuccessAt
        let successKind = lastSuccessKind
        let reads = selectionReads
        let observedReads = selectionReadObservedCount
        lock.unlock()

        var lines = [
            "Enabled: \(enabled)",
            "Availability: \(availability)"
        ]
        if let localeNote {
            lines.append("Locale: \(localeNote)")
        }
        lines.append(
            "Transforms this session: \(successes) succeeded, \(observedFailures) failed"
                + (observedFailures > snapshot.count
                    ? " (retained \(snapshot.count)/\(Self.capacity); dropped \(observedFailures - snapshot.count))"
                    : "")
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
            lines.append(contentsOf: Self.selectionReadLines(
                reads,
                observedCount: observedReads,
                iso: iso
            ))
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
        lines.append(contentsOf: Self.selectionReadLines(
            reads,
            observedCount: observedReads,
            iso: iso
        ))
        return lines
    }

    /// `-- On-device AI --` tail describing how selection reads resolved.
    ///
    /// The last read is spelled out because it is almost always *the* read the user is
    /// complaining about; the histogram below it separates "one unlucky read" from "this app
    /// never reports a selection".
    static func selectionReadLines(
        _ reads: [SelectionRead],
        observedCount: Int? = nil,
        iso: ISO8601DateFormatter
    ) -> [String] {
        guard let last = reads.last else {
            return ["Selection reads: (none this session)"]
        }
        let observed = max(reads.count, max(0, observedCount ?? reads.count))
        var lines = [
            "Selection reads: \(observed)"
                + (observed > reads.count
                    ? " (retained \(reads.count)/\(capacity); dropped \(observed - reads.count))"
                    : "")
        ]
        lines.append(
            "Last selection read: \(iso.string(from: last.at)) outcome=\(last.outcome) "
                + "app=\(last.bundleID ?? "(unknown)") axCandidates=\(last.candidateCount) "
                + "chars=\(last.characters)"
                + (last.via.isEmpty ? "" : " via=\(last.via)")
                + (last.elapsedMilliseconds > 0 ? " elapsedMs=\(last.elapsedMilliseconds)" : "")
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

        // Which attribute answers, per app. This is the line that says "this app is marker-only"
        // or "this app never answers anything", which no amount of outcome counting can.
        let viaCounts = reads
            .filter { !$0.via.isEmpty && $0.via != "unknown" }
            .reduce(into: [String: Int]()) { $0[$1.via, default: 0] += 1 }
        if !viaCounts.isEmpty {
            let viaSummary = viaCounts
                .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            lines.append("Selection read attributes: \(viaSummary)")
        }
        return lines
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
