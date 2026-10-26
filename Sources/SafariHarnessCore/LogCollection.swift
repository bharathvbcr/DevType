import Foundation

extension CollectedLogs {
    /// Splits the run's log lines into per-case excerpts (case window padded by 300 ms before and
    /// 1.5 s after, so a late outcome line is kept) and reads the timestamp-units line from
    /// `unitsLines`, which come from a wider query because DevType logs it once per launch.
    public static func build(
        mainLines: [LogLine],
        unitsLines: [LogLine],
        results: [CaseResult],
        perCaseCap: Int = 80,
        queryNote: String
    ) -> CollectedLogs {
        var perCase: [String: (kept: [String], dropped: Int)] = [:]
        var outcomes: [String: [InjectOutcome]] = [:]
        for result in results where result.status != .notRun && result.status != .skip {
            let from = result.started.addingTimeInterval(-0.3)
            let to = result.ended.addingTimeInterval(1.5)
            let slice = LogParser.excerpt(mainLines, from: from, to: to, cap: perCaseCap)
            perCase[result.id] = (slice.kept.map(\.text), slice.dropped)
            outcomes[result.id] = mainLines
                .filter { $0.timestamp >= from && $0.timestamp <= to }
                .compactMap { LogParser.injectOutcome(in: $0.text) }
        }
        let unitsLine = (unitsLines + mainLines)
            .filter { $0.text.contains("[Debounce] event timestamp units") }
            .max { $0.timestamp < $1.timestamp }
        let ratio = unitsLine.flatMap { LogParser.timestampUnitsRatio(in: $0.text) }
        let converted = unitsLine.flatMap { LogParser.timestampUnitsConvertedRatio(in: $0.text) }
        return CollectedLogs(perCase: perCase, unitsLine: unitsLine?.text,
                             unitsVerdict: TimestampUnitsVerdict.assess(ratio: ratio, converted: converted),
                             outcomes: outcomes, queryNote: queryNote)
    }
}
