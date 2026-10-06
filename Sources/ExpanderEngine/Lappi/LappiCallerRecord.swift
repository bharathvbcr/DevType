import Foundation
import Security

/// Builders for `lappi.caller_record` version 1 lines (contract §5).
///
/// `crates/qd-runtime/src/caller_record.rs::validate_line` is the checker these lines must pass.
/// What goes in is **structure, not content**: the query's length and shape, never its text.
/// Records are not training or eval data (the human's "Synthetic only", 2026-10-06), and
/// `admission` has one legal value.
public enum LappiCallerRecord {
    public static let record = "lappi.caller_record"
    public static let recordVersion = 1
    public static let admission = "not_admitted"
    public static let app = "devtype"
    public static let redactionPolicy = "devtype.diagnostic-privacy"
    public static let engineFoundationModels = "foundation-models"

    /// Which palette row the user ended on (contract §5, DevType's outcome).
    public enum Picked: String, Sendable, CaseIterable {
        case routed, command, snippet, cancel
    }

    /// 32 lowercase hex characters from `SecRandomCopyBytes`, or nil when the system RNG fails.
    public static func newRecordID() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            DevTypeLog.lappi.error("[Lappi] SecRandomCopyBytes failed status=\(status, privacy: .public)")
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 3339 UTC with milliseconds and a `Z`, e.g. `2026-10-06T15:06:00.250Z`.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `CFBundleShortVersionString`, bounded to the checker's 64 characters. A process with no
    /// bundle version (the test runner) says so rather than inventing a number.
    public static func appVersion(bundle: Bundle = .main) -> String {
        let raw = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = raw.isEmpty ? "unbundled" : raw
        return String(version.prefix(64))
    }

    /// The decision line written when routing produced a result or was attempted.
    ///
    /// `query` is used only to compute its shape and to scrub any echo of it from strings the
    /// agent sent back; the text itself is never placed in the record.
    public static func decision(
        recordID: String,
        createdAt: Date,
        appVersion: String,
        query: String,
        tool: String,
        engine: String,
        exchange: LappiExchange
    ) -> [String: Any] {
        var scrub = Scrubber(query: query)
        let lappi = lappiBlock(exchange, scrub: &scrub)
        return [
            "record": record,
            "record_version": recordVersion,
            "kind": "decision",
            "record_id": recordID,
            "app": app,
            "app_version": appVersion,
            "decision_point": LappiRouteRequest.decisionPoint,
            "created_at": timestamp(createdAt),
            "admission": admission,
            "facts": [
                "query_chars": query.count,
                "query_shape": DiagnosticPrivacy.textShape(query, label: "query", domain: "lappi.devtype.route"),
            ] as [String: Any],
            "app_choice": ["tool": tool, "engine": engine],
            "lappi": lappi,
            // The query itself is the one field always redacted (replaced by its shape).
            "redaction": ["policy": redactionPolicy, "fields_redacted": 1 + scrub.changed] as [String: Any],
        ]
    }

    /// The outcome line written at pick or cancel, sharing the decision's `record_id`.
    public static func outcome(
        recordID: String,
        createdAt: Date,
        appVersion: String,
        picked: Picked
    ) -> [String: Any] {
        [
            "record": record,
            "record_version": recordVersion,
            "kind": "outcome",
            "record_id": recordID,
            "app": app,
            "app_version": appVersion,
            "decision_point": LappiRouteRequest.decisionPoint,
            "created_at": timestamp(createdAt),
            "admission": admission,
            "observed": ["picked": picked.rawValue],
            "redaction": ["policy": redactionPolicy, "fields_redacted": 0] as [String: Any],
        ]
    }

    /// One line, without its newline.
    public static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - The lappi block

    /// `asked` is false exactly when the reading is `not_asked`; a refusal, error or
    /// unavailability names its `kind`; only an answer carries `slots` and `backend`.
    static func lappiBlock(_ exchange: LappiExchange, scrub: inout Scrubber) -> [String: Any] {
        let reading = exchange.reading
        var kind: Any = NSNull()
        var backend: Any = NSNull()
        var slots: Any = NSNull()
        switch reading {
        case .modelAnswered(let name, let answers), .modelAbstained(let name, let answers):
            backend = scrub.clean(name)
            slots = slotsObject(answers, scrub: &scrub)
        case .requestRefused(let refusal):
            kind = scrub.clean(refusal)
        case .backendFailed(let error):
            kind = scrub.clean(error)
        case .unavailable(let reason):
            kind = reason.rawValue
        case .notAsked:
            break
        }
        var latency: Any = NSNull()
        var task: Any = NSNull()
        if reading.asked {
            latency = max(0, exchange.latencyMs ?? 0)
            task = LappiRouteRequest.task
        }
        return [
            "asked": reading.asked,
            "task": task,
            "reading": reading.name,
            "kind": kind,
            "backend": backend,
            "slots": slots,
            "latency_ms": latency,
        ]
    }

    private static func slotsObject(_ answers: [String: LappiSlotAnswer], scrub: inout Scrubber) -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, answer) in answers {
            let value: Any
            switch answer.value {
            case .none: value = NSNull()
            case .label(let label)?: value = scrub.clean(label)
            case .span(let start, let end)?: value = ["start_line": start, "end_line": end]
            }
            var conformal: Any = NSNull()
            if let set = answer.conformalSet {
                var cleaned: [String] = []
                for label in set { cleaned.append(scrub.clean(label)) }
                conformal = cleaned
            }
            out[scrub.clean(name)] = [
                "value": value,
                "conformal_set": conformal,
                "score": answer.score,
                "noul": answer.noul,
                "degraded": answer.degraded,
            ] as [String: Any]
        }
        return out
    }

    /// DevType's redactor for strings the agent sent back: any echo of the query is replaced
    /// (`AIPromptLeakGuard.redact`), and a credential-shaped string is replaced whole — the same
    /// shapes `caller_record.rs` refuses a line for, so a record DevType writes is never one the
    /// checker rejects for a secret.
    struct Scrubber {
        let query: String
        private(set) var changed = 0

        init(query: String) { self.query = query }

        mutating func clean(_ value: String) -> String {
            var out = AIPromptLeakGuard.redact(value, sources: [query])
            if LappiSecretShape.containsCredential(out) { out = AIPromptLeakGuard.redactionMarker }
            if out != value { changed += 1 }
            return out
        }
    }
}

/// The credential prefixes `crates/qd-runtime/src/caller_record.rs` refuses a line for.
enum LappiSecretShape {
    static let prefixes = [
        "sk-ant-", "sk-proj-", "ghp_", "gho_", "ghs_", "github_pat_", "glpat-",
        "xoxb-", "xoxp-", "AKIA", "AIza", "-----BEGIN",
    ]

    static func containsCredential(_ value: String) -> Bool {
        for prefix in prefixes {
            var search = value.startIndex..<value.endIndex
            while let found = value.range(of: prefix, range: search) {
                let atBoundary = found.lowerBound == value.startIndex
                    || !isASCIIAlphanumeric(value[value.index(before: found.lowerBound)])
                let body = value[found.upperBound...].prefix { isASCIIAlphanumeric($0) || $0 == "_" || $0 == "-" }
                if atBoundary && (prefix.hasPrefix("-----") || body.count >= 12) { return true }
                search = found.upperBound..<value.endIndex
            }
        }
        return false
    }

    private static func isASCIIAlphanumeric(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }
}
