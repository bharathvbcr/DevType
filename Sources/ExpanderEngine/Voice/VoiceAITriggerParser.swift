import Foundation

/// A parsed voice AI action command extracted from live speech.
public struct VoiceAICommand: Equatable, Sendable {
    public let kind: AITransformKind
    public let triggerPhrase: String
    public let payloadText: String
    public let requiresSelectionFallback: Bool

    public init(
        kind: AITransformKind,
        triggerPhrase: String,
        payloadText: String,
        requiresSelectionFallback: Bool
    ) {
        self.kind = kind
        self.triggerPhrase = triggerPhrase
        self.payloadText = payloadText
        self.requiresSelectionFallback = requiresSelectionFallback
    }
}

/// Parses voice transcripts to detect custom and built-in AI rewrite / developer voice triggers.
public enum VoiceAITriggerParser {

    /// Inspects speech transcript for custom or built-in AI voice triggers.
    ///
    /// Supports:
    /// 1. Trigger prefix with payload (e.g. `"rewrite: make this concise"`, `"ai explain code: let x = 10"`, `"json: name: foo"`)
    /// 2. Natural voice commands (e.g. `"ai rephrase ..."`, `"expand this: ..."`, `"ai prompt ..."`)
    /// 3. Standalone action on current selection (e.g. `"explain code"`, `"rephrase"`, `"prompt enhance"`, `"fix bugs"`)
    public static func parse(
        transcript: String,
        customTriggers: [String: String] = VoicePreferences.customVoiceTriggers
    ) -> VoiceAICommand? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()

        // 1. Check custom triggers first (longest phrase match first to avoid prefix shadowing)
        let sortedTriggers = customTriggers.sorted { $0.key.count > $1.key.count }

        for (phrase, actionKey) in sortedTriggers {
            let lowerPhrase = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lowerPhrase.isEmpty, let kind = AITransformKind.named(actionKey) else { continue }

            // Pattern A: "phrase: payload" or "ai phrase: payload" or "phrase - payload"
            let prefixes = [
                lowerPhrase + ":",
                lowerPhrase + " -",
                lowerPhrase + ",",
                "ai " + lowerPhrase + ":",
                "ai " + lowerPhrase + " -",
                "ai " + lowerPhrase + ",",
                "ai " + lowerPhrase + " "
            ]

            for prefix in prefixes {
                if lower.hasPrefix(prefix) {
                    let rawPayload = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return VoiceAICommand(
                        kind: kind,
                        triggerPhrase: phrase,
                        payloadText: rawPayload,
                        requiresSelectionFallback: rawPayload.isEmpty
                    )
                }
            }

            // Pattern B: Exact match (e.g. "explain code", "rephrase", "prompt enhance") -> transforms current selection
            if lower == lowerPhrase ||
               lower == "ai " + lowerPhrase ||
               lower == lowerPhrase + " this" ||
               lower == "ai " + lowerPhrase + " this" {
                return VoiceAICommand(
                    kind: kind,
                    triggerPhrase: phrase,
                    payloadText: "",
                    requiresSelectionFallback: true
                )
            }
        }

        // 2. Built-in trigger fallbacks
        for kind in AITransformKind.allCases where kind != .custom {
            let name = kind.rawValue.lowercased()
            let prefixes = [
                name + ":",
                "ai " + name + ":",
                "ai " + name + " "
            ]

            for prefix in prefixes {
                if lower.hasPrefix(prefix) {
                    let payload = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return VoiceAICommand(
                        kind: kind,
                        triggerPhrase: name,
                        payloadText: payload,
                        requiresSelectionFallback: payload.isEmpty
                    )
                }
            }
        }

        return nil
    }
}
