import Foundation

/// What Lappi's answer may do to the palette: **annotate the routed row, nothing else**
/// (contract §3). It never inserts a row the app did not produce, never changes the text a row
/// would insert, and never runs anything. Only a `model_answered` reading with a valid option
/// in the `route` slot annotates; every other reading leaves the row exactly as it was.
public enum LappiRouteAdmission {
    public static func admit(
        _ routed: PaletteToolRouter.Routed?,
        reading: LappiReading,
        routedTool: String?
    ) -> PaletteToolRouter.Routed? {
        guard let routed else { return nil }
        guard case .modelAnswered(_, let slots) = reading,
              let slot = slots[LappiRouteRequest.slotName], !slot.noul, !slot.degraded,
              case .label(let route)? = slot.value,
              LappiRouteRequest.options.contains(route) else {
            return routed
        }
        let note: PaletteToolRouter.LappiNote = route == (routedTool ?? "none") ? .agrees : .differs
        return PaletteToolRouter.Routed(query: routed.query, text: routed.text, lappiNote: note)
    }
}

/// Collects which palette tool a routing session called, for the decision record.
///
/// One per routing attempt. The engine's tools report into it as they run; `firstTool` is the
/// tool whose result routing used, or nil when the model called none.
public final class PaletteToolCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?

    public init() {}

    public func note(_ toolName: String) {
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = toolName }
    }

    public var firstTool: String? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }
}

/// One palette's Lappi caller: asks (when enabled), writes the decision record (when
/// enabled), and pairs the outcome at pick or cancel.
///
/// Asking and recording are independent (contract §5): either can be on without the other.
/// Every gate is read live at the moment it matters — preferences and `LAPPI_COLLECT` when a
/// record is written, secure input both before asking and again at write time.
public final class LappiPaletteRouting: @unchecked Sendable {
    public struct Environment: Sendable {
        public var client: @Sendable () -> LappiClient?
        public var writer: LappiRecordWriter?
        public var askEnabled: @Sendable () -> Bool
        public var collectionAllowed: @Sendable () -> Bool
        /// True while Secure Event Input is on or the focused element is a secure field.
        public var isSecureContext: @Sendable () -> Bool
        public var now: @Sendable () -> Date
        public var appVersion: String

        public init(
            client: @escaping @Sendable () -> LappiClient?,
            writer: LappiRecordWriter?,
            askEnabled: @escaping @Sendable () -> Bool,
            collectionAllowed: @escaping @Sendable () -> Bool,
            isSecureContext: @escaping @Sendable () -> Bool,
            now: @escaping @Sendable () -> Date = { Date() },
            appVersion: String = LappiCallerRecord.appVersion()
        ) {
            self.client = client
            self.writer = writer
            self.askEnabled = askEnabled
            self.collectionAllowed = collectionAllowed
            self.isSecureContext = isSecureContext
            self.now = now
            self.appVersion = appVersion
        }

        /// The production gates. Secure context fails closed: `isFocusedElementSecure` reports
        /// true when AX is untrusted or nothing is focused.
        public static func live() -> Environment {
            Environment(
                client: { LappiClient.live() },
                writer: LappiRecordWriter.shared,
                askEnabled: { LappiPreferences.isAskEnabled },
                collectionAllowed: { LappiPreferences.isCollectionAllowed() },
                isSecureContext: {
                    AXContextChecker.isSecureEventInputEnabledLive()
                        || AXContextChecker.shared.isFocusedElementSecure()
                }
            )
        }
    }

    /// One routing attempt's identity: the record id that also names the request's
    /// `example_id`, and the bounded query it was for.
    public struct Ticket: Equatable, Sendable {
        public let recordID: String
        public let query: String
    }

    private let environment: Environment
    /// Serial, so a decision is always written before the outcome that pairs with it.
    private let queue = DispatchQueue(label: "com.devtype.lappi.records", qos: .utility)
    /// The one decision awaiting an outcome. Touched only on `queue`; bounded to one, because
    /// only the latest attempt's row can be the one the user picks.
    private var pending: Ticket?

    public init(environment: Environment) {
        self.environment = environment
    }

    /// Asks Lappi about `query` (already `CommandPaletteCatalog.boundedQuery`-ed) when asking
    /// is enabled. Returns nil only when the system RNG cannot name a record.
    public func ask(query: String) async -> (ticket: Ticket, exchange: LappiExchange)? {
        guard let recordID = LappiCallerRecord.newRecordID() else { return nil }
        let ticket = Ticket(recordID: recordID, query: query)
        guard environment.askEnabled() else {
            return (ticket, LappiExchange(reading: .notAsked(.askingDisabled), latencyMs: nil))
        }
        let secure = await onQueue(environment.isSecureContext)
        guard !secure else {
            return (ticket, LappiExchange(reading: .notAsked(.secureInput), latencyMs: nil))
        }
        guard let client = environment.client() else {
            return (ticket, LappiExchange(reading: .unavailable(.socketNotFound), latencyMs: 0))
        }
        let line: Data
        do {
            line = try LappiRouteRequest.line(context: Data(query.utf8), recordID: recordID)
        } catch {
            DevTypeLog.lappi.error("[Lappi] request not encodable \(DevTypeLog.errorMetadata(error), privacy: .public)")
            return (ticket, LappiExchange(reading: .notAsked(.overBound), latencyMs: nil))
        }
        return (ticket, await client.ask(line))
    }

    /// Writes the decision record for one finished routing attempt and holds it as pending.
    public func recordDecision(ticket: Ticket, tool: String, engine: String, exchange: LappiExchange) {
        queue.async { [self] in
            guard let writer = environment.writer, mayRecord() else { return }
            let createdAt = environment.now()
            let object = LappiCallerRecord.decision(
                recordID: ticket.recordID,
                createdAt: createdAt,
                appVersion: environment.appVersion,
                query: ticket.query,
                tool: tool,
                engine: engine,
                exchange: exchange
            )
            pending = nil
            guard write(object, createdAt: createdAt, writer: writer) else { return }
            pending = ticket
        }
    }

    /// Writes the outcome paired with the pending decision, when that decision was for the
    /// query on screen at pick time. Consumes the pending decision either way.
    public func recordOutcome(_ picked: LappiCallerRecord.Picked, query: String) {
        queue.async { [self] in
            guard let ticket = pending else { return }
            pending = nil
            guard ticket.query == query, let writer = environment.writer, mayRecord() else { return }
            let createdAt = environment.now()
            let object = LappiCallerRecord.outcome(
                recordID: ticket.recordID,
                createdAt: createdAt,
                appVersion: environment.appVersion,
                picked: picked
            )
            _ = write(object, createdAt: createdAt, writer: writer)
        }
    }

    /// Blocks until every queued record write has finished. For tests and shutdown.
    public func waitUntilIdle() {
        queue.sync {}
    }

    /// Off by default, `LAPPI_COLLECT=0` wins, and never while secure input is active.
    private func mayRecord() -> Bool {
        environment.collectionAllowed() && !environment.isSecureContext()
    }

    private func write(_ object: [String: Any], createdAt: Date, writer: LappiRecordWriter) -> Bool {
        do {
            return writer.append(try LappiCallerRecord.encode(object), createdAt: createdAt) == .written
        } catch {
            DevTypeLog.lappi.error("[Lappi] caller record not encodable \(DevTypeLog.errorMetadata(error), privacy: .public)")
            return false
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: body()) }
        }
    }
}
