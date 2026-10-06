import Foundation

/// The one request DevType sends: `devtype.route`, exactly as contract §4 pins it.
///
/// Task, question and slot names are rendered into the model's prompt, so a renamed one serves a
/// prompt the model never saw. The shape is **proposed for v6**; no release trains it yet, so
/// every request is refused with `task_not_trained` today
/// (`GAP-CALLER-REQUEST-SHAPES-PROPOSED-NOT-TRAINED-2026-10-06`).
public enum LappiRouteRequest {
    public static let task = "devtype.route"
    public static let decisionPoint = "devtype.route"
    public static let question = "Which DevType tool should answer this palette query?"
    public static let slotName = "route"
    public static let options = ["resolveDate", "runMacro", "findSnippet", "none"]

    /// `<app>:<decision_point>:<record_id>` (contract §4).
    public static func exampleID(recordID: String) -> String {
        "devtype:\(decisionPoint):\(recordID)"
    }

    /// The request object. `context` is the query's **bytes**: it crosses as base64 of those
    /// bytes plus their count, never through a re-encoded `String` (schema-api.md, "Request").
    public static func object(context: Data, recordID: String) -> [String: Any] {
        [
            "schema_version": LappiWire.schemaVersion,
            "task": task,
            "context_b64": context.base64EncodedString(),
            "context_len": context.count,
            "question": question,
            "slots": [
                ["name": slotName, "type": "choice", "options": options] as [String: Any]
            ],
            "route": "generic",
            "example_id": exampleID(recordID: recordID),
            "metadata": [String: Any](),
        ]
    }

    /// One request line, without its newline. Sorted keys make the bytes deterministic.
    public static func line(context: Data, recordID: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object(context: context, recordID: recordID),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

/// `devtype.lappi.*` preferences. Both default **off** (`UserDefaults.bool` reads unset as false).
public enum LappiPreferences {
    public static let askEnabledKey = "devtype.lappi.askEnabled"
    public static let recordEnabledKey = "devtype.lappi.recordEnabled"

    /// Whether palette routing also asks the local Lappi agent. Only consulted while AI routing
    /// already runs (`PaletteToolRouter.shouldAttemptRouting`).
    public static var isAskEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: askEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: askEnabledKey) }
    }

    /// Whether DevType keeps local caller records (contract §5). Independent of asking.
    public static var isRecordEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: recordEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordEnabledKey) }
    }

    /// `LAPPI_COLLECT=0` forces recording off regardless of the setting (contract §5).
    public static func isCollectionAllowed(
        recordEnabled: Bool = isRecordEnabled,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        recordEnabled && environment["LAPPI_COLLECT"] != "0"
    }
}
