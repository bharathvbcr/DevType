import Foundation

public struct ReportHeader: Sendable {
    public var mode: RunMode
    public var started: Date
    public var finished: Date
    public var preflight: [PreflightRow]
    public var seed: UInt64
    public var trigger: String
    public var pageReadMode: String
    public var libraryOutcome: String
    public var libraryBackup: String
    public var clipboardFinal: String
    public var abort: AbortReason?
    public var notes: [String]

    public init(mode: RunMode, started: Date, finished: Date, preflight: [PreflightRow], seed: UInt64, trigger: String,
                pageReadMode: String, libraryOutcome: String, libraryBackup: String, clipboardFinal: String,
                abort: AbortReason?, notes: [String]) {
        self.mode = mode
        self.started = started
        self.finished = finished
        self.preflight = preflight
        self.seed = seed
        self.trigger = trigger
        self.pageReadMode = pageReadMode
        self.libraryOutcome = libraryOutcome
        self.libraryBackup = libraryBackup
        self.clipboardFinal = clipboardFinal
        self.abort = abort
        self.notes = notes
    }
}

/// Log lines the harness collected, already split per case.
public struct CollectedLogs: Sendable {
    public var perCase: [String: (kept: [String], dropped: Int)]
    public var unitsLine: String?
    public var unitsVerdict: TimestampUnitsVerdict
    public var outcomes: [String: [InjectOutcome]]
    public var queryNote: String

    public init(perCase: [String: (kept: [String], dropped: Int)], unitsLine: String?, unitsVerdict: TimestampUnitsVerdict,
                outcomes: [String: [InjectOutcome]], queryNote: String) {
        self.perCase = perCase
        self.unitsLine = unitsLine
        self.unitsVerdict = unitsVerdict
        self.outcomes = outcomes
        self.queryNote = queryNote
    }

    public static let none = CollectedLogs(perCase: [:], unitsLine: nil,
                                           unitsVerdict: .notFound("logs were not collected"), outcomes: [:],
                                           queryNote: "logs were not collected")
}

public enum ReportRenderer {
    public static func summaryCounts(_ results: [CaseResult]) -> [CaseStatus: Int] {
        results.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    /// 0 only when every case that ran passed and nothing was skipped silently. A skip, an error
    /// or an abort is never a pass.
    public static func exitCode(_ results: [CaseResult], mode: RunMode, abort: AbortReason?) -> Int32 {
        if abort != nil { return 3 }
        if mode == .dryRun { return 0 }
        let counts = summaryCounts(results)
        if counts[.fail, default: 0] > 0 || counts[.error, default: 0] > 0 { return 1 }
        if counts[.notRun, default: 0] > 0 || counts[.aborted, default: 0] > 0 { return 3 }
        return 0
    }

    public static func render(header: ReportHeader, results: [CaseResult], logs: CollectedLogs) -> String {
        var out: [String] = []
        let iso = ISO8601DateFormatter()
        out.append("DevType Safari live harness - \(header.mode == .dryRun ? "DRY RUN (no key was posted)" : "LIVE RUN")")
        out.append("started \(iso.string(from: header.started))  finished \(iso.string(from: header.finished))  seed \(header.seed)  trigger \(header.trigger)")
        out.append("page read: \(header.pageReadMode)")
        out.append("")
        out.append("PREFLIGHT")
        for row in header.preflight {
            out.append("  [\(row.ok ? "ok" : "NO")] \(row.name): \(row.detail)")
            if !row.ok, let remedy = row.remedy { out.append("       -> \(remedy)") }
        }
        out.append("")
        if let abort = header.abort { out.append("RUN STOPPED EARLY: \(abort)\n") }

        out.append("RESULTS")
        let idWidth = max(results.map(\.id.count).max() ?? 2, 2)
        out.append("  \("case".padding(toLength: idWidth, withPad: " ", startingAt: 0))  status   clipboard  detail")
        for r in results {
            let clip: String
            switch r.clipboard {
            case .restored: clip = "restored "
            case .modified: clip = "MODIFIED "
            case .unchecked: clip = "unchecked"
            }
            out.append("  \(r.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  \(r.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(clip)  \(r.summary)")
        }
        let counts = summaryCounts(results)
        let order: [CaseStatus] = [.pass, .fail, .error, .skip, .aborted, .notRun, .dryRun]
        out.append("  totals: " + order.compactMap { status in counts[status].map { "\(status.rawValue)=\($0)" } }.joined(separator: " "))
        out.append("")

        out.append("TIMESTAMP UNITS  \(logs.unitsVerdict.summary)")
        if let line = logs.unitsLine { out.append("  \(line)") }
        out.append("")

        out.append("PER-CASE EVIDENCE")
        for r in results {
            out.append("--- \(r.id): \(r.title) [\(r.status.rawValue)]")
            out.append("  window \(iso.string(from: r.started)) .. \(iso.string(from: r.ended)); \(r.plannedEvents) key events \(header.mode == .dryRun ? "built, none posted" : "posted")")
            for f in r.fields { out.append("  field  \(f)") }
            out.append("  clipboard: \(r.clipboard.summary)")
            for n in r.notes { out.append("  note   \(n)") }
            for c in r.chords { out.append("  chord  \(c)") }
            if let outcomes = logs.outcomes[r.id], !outcomes.isEmpty {
                out.append("  inject outcomes in the log: " + outcomes.map(\.description).joined(separator: ", "))
            }
            if !r.pageEvents.isEmpty {
                out.append("  page event log (what the field held after each input event):")
                for e in r.pageEvents { out.append("    \(e)") }
            }
            if let entry = logs.perCase[r.id] {
                out.append("  DevType log (\(entry.kept.count) lines\(entry.dropped > 0 ? ", \(entry.dropped) more dropped by the per-case cap" : "")):")
                for l in entry.kept { out.append("    \(l)") }
            }
            out.append("")
        }

        out.append("LOG QUERY  \(logs.queryNote)")
        out.append("")
        out.append("EXIT STATE")
        out.append("  library:   \(header.libraryOutcome)")
        out.append("  backup:    \(header.libraryBackup)")
        out.append("  clipboard: \(header.clipboardFinal)")
        for n in header.notes { out.append("  note: \(n)") }
        return out.joined(separator: "\n") + "\n"
    }
}
