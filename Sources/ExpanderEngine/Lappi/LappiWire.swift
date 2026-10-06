import Foundation

/// The Lappi wire constants DevType must agree with, and the closed reading of one reply.
///
/// The binding spec is `docs/caller-contract.md` in the Lappi repository
/// (`bharathvbcr/Lappi-decision`); the reply shapes are `docs/schema-api.md` ("Answer") and the
/// corpus under `fixtures/wire/`. Nothing here decides anything for DevType: a reading is
/// evidence, and `LappiRouteAdmission` is the only place one may touch the palette.
public enum LappiWire {
    /// Mirrors `MAX_PAYLOAD_BYTES` in `crates/qd-runtime/src/wire.rs:64` (1_572_864 bytes).
    /// A request line over it is not sent, and a reply line over it is `reply_over_cap`.
    public static let maxPayloadBytes = 1_572_864

    /// The only request/reply schema version this client speaks.
    public static let schemaVersion = 1
}

/// Why an exchange produced no reply the app can read (contract §2, `unavailable`).
public enum LappiUnavailableReason: String, Sendable, Equatable, CaseIterable {
    case socketNotFound = "socket_not_found"
    case connectRefused = "connect_refused"
    case deadline
    case closedWithoutReply = "closed_without_reply"
    case replyOverCap = "reply_over_cap"
    case replyUnparseable = "reply_unparseable"
}

/// Why DevType chose not to send (contract §2, `not_asked`).
public enum LappiNotAskedReason: String, Sendable, Equatable, CaseIterable {
    /// `devtype.lappi.askEnabled` is off (the default).
    case askingDisabled = "asking_disabled"
    /// The request line would exceed `LappiWire.maxPayloadBytes`, or is not one line.
    case overBound = "over_bound"
    /// Secure Event Input is on, or the focused element is a secure field.
    case secureInput = "secure_input"
}

/// One slot of an `ok` reply. `value` is nil exactly when `noul` is true; the parser refuses
/// either other combination, as the runtime's own deserializer does.
public struct LappiSlotAnswer: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case label(String)
        case span(startLine: Int, endLine: Int)
    }

    public let value: Value?
    public let conformalSet: [String]?
    public let score: Double
    public let noul: Bool
    public let degraded: Bool

    public init(value: Value?, conformalSet: [String]?, score: Double, noul: Bool, degraded: Bool) {
        self.value = value
        self.conformalSet = conformalSet
        self.score = score
        self.noul = noul
        self.degraded = degraded
    }
}

/// The six outcomes of contract §2. A caller matches all six; there is no seventh.
public enum LappiReading: Equatable, Sendable {
    case modelAnswered(backend: String, slots: [String: LappiSlotAnswer])
    case modelAbstained(backend: String, slots: [String: LappiSlotAnswer])
    case requestRefused(kind: String)
    case backendFailed(kind: String)
    case unavailable(LappiUnavailableReason)
    case notAsked(LappiNotAskedReason)

    /// The spelling a caller record uses (`caller_record::READINGS`).
    public var name: String {
        switch self {
        case .modelAnswered: return "model_answered"
        case .modelAbstained: return "model_abstained"
        case .requestRefused: return "request_refused"
        case .backendFailed: return "backend_failed"
        case .unavailable: return "unavailable"
        case .notAsked: return "not_asked"
        }
    }

    /// Whether a request left the app. False exactly for `notAsked`.
    public var asked: Bool {
        if case .notAsked = self { return false }
        return true
    }
}

/// Reads one reply line into a `LappiReading`. Strict: an envelope this client does not
/// fully understand is `unavailable(.replyUnparseable)`, never a guessed answer.
public enum LappiReply {
    static let maxIdentifierLength = 256

    private static let okKeys: Set<String> = ["status", "schema_version", "backend", "degraded", "slots"]
    private static let refusedKeys: Set<String> = ["status", "schema_version", "refusal", "message"]
    private static let errorKeys: Set<String> = ["status", "schema_version", "error", "message"]
    private static let slotKeys: Set<String> = ["value", "conformal_set", "score", "noul", "degraded"]

    public static func read(_ line: Data) -> LappiReading {
        let unparseable = LappiReading.unavailable(.replyUnparseable)
        guard let object = try? JSONSerialization.jsonObject(with: line, options: []),
              let envelope = object as? [String: Any],
              let status = envelope["status"] as? String,
              isInteger(envelope["schema_version"], equalTo: LappiWire.schemaVersion) else {
            return unparseable
        }
        switch status {
        case "ok":
            return readAnswer(envelope) ?? unparseable
        case "refused":
            guard Set(envelope.keys) == refusedKeys,
                  let kind = kind(of: envelope["refusal"]) else { return unparseable }
            return .requestRefused(kind: kind)
        case "error":
            guard Set(envelope.keys) == errorKeys,
                  let kind = kind(of: envelope["error"]) else { return unparseable }
            return .backendFailed(kind: kind)
        default:
            // A status this client does not know is never read as any of the three it does.
            return unparseable
        }
    }

    private static func readAnswer(_ envelope: [String: Any]) -> LappiReading? {
        guard Set(envelope.keys) == okKeys,
              let backend = envelope["backend"] as? String,
              !backend.isEmpty, backend.count <= maxIdentifierLength,
              let degraded = bool(envelope["degraded"]),
              let rawSlots = envelope["slots"] as? [String: Any],
              !rawSlots.isEmpty else { return nil }
        var slots: [String: LappiSlotAnswer] = [:]
        for (name, raw) in rawSlots {
            guard !name.isEmpty, name.count <= maxIdentifierLength,
                  let slot = readSlot(raw) else { return nil }
            slots[name] = slot
        }
        // `degraded` is one bit mirrored onto every slot; a reference backend's answer is not
        // a model's (contract §2), so either spelling of it reads as an abstention.
        if degraded || slots.values.contains(where: \.degraded) || slots.values.allSatisfy(\.noul) {
            return .modelAbstained(backend: backend, slots: slots)
        }
        return .modelAnswered(backend: backend, slots: slots)
    }

    private static func readSlot(_ raw: Any) -> LappiSlotAnswer? {
        guard let slot = raw as? [String: Any], Set(slot.keys) == slotKeys,
              let noul = bool(slot["noul"]),
              let degraded = bool(slot["degraded"]),
              let score = number(slot["score"]), score.isFinite, (0...1).contains(score) else {
            return nil
        }
        let value: LappiSlotAnswer.Value?
        switch slot["value"] {
        case is NSNull:
            value = nil
        case let label as String:
            guard !label.isEmpty, label.count <= maxIdentifierLength else { return nil }
            value = .label(label)
        case let span as [String: Any]:
            guard Set(span.keys) == ["start_line", "end_line"],
                  let start = integer(span["start_line"]), let end = integer(span["end_line"]),
                  start >= 0, end >= start else { return nil }
            value = .span(startLine: start, endLine: end)
        default:
            return nil
        }
        // `value` is absent if and only if `noul` (schema-api.md, "Answer").
        guard (value == nil) == noul else { return nil }
        let conformal: [String]?
        switch slot["conformal_set"] {
        case is NSNull:
            conformal = nil
        case let items as [Any]:
            var labels: [String] = []
            for item in items {
                guard let label = item as? String, !label.isEmpty,
                      label.count <= maxIdentifierLength else { return nil }
                labels.append(label)
            }
            conformal = labels
        default:
            return nil
        }
        return LappiSlotAnswer(value: value, conformalSet: conformal, score: score, noul: noul, degraded: degraded)
    }

    /// A refusal's or error's `kind`: a lowercase identifier, as `Refusal::kind()` spells it.
    private static func kind(of raw: Any?) -> String? {
        guard let detail = raw as? [String: Any], let kind = detail["kind"] as? String,
              !kind.isEmpty, kind.count <= maxIdentifierLength,
              kind.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else { return nil }
        return kind
    }

    /// JSON `true`/`false` only. `NSNumber(1)` bridges to `Bool` too, which would accept a
    /// number where the wire says a boolean.
    static func bool(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    static func integer(_ raw: Any?) -> Int? {
        guard let value = number(raw), value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    private static func isInteger(_ raw: Any?, equalTo expected: Int) -> Bool {
        integer(raw) == expected
    }
}
