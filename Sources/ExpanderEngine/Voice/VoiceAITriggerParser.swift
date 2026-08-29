import Foundation

/// What a spoken AI command should act on.
public enum VoiceCommandTarget: Equatable, Sendable {
    /// Text spoken as part of the command: "dev rewrite make this shorter".
    case spoken(String)
    /// Whatever is selected in the frontmost app: "dev rewrite this".
    case selection
    /// The text this dictation session just inserted: "proofread final insertion".
    ///
    /// Distinct from `.selection` because the useful thing to fix immediately after
    /// speaking is what was just typed, and it is generally *not* selected — asking the
    /// user to select it first would defeat the point of asking by voice.
    case lastInsertion
}

/// A parsed voice AI action command extracted from live speech.
public struct VoiceAICommand: Equatable, Sendable {
    public let kind: AITransformKind
    public let triggerPhrase: String
    public let target: VoiceCommandTarget

    public init(kind: AITransformKind, triggerPhrase: String, target: VoiceCommandTarget) {
        self.kind = kind
        self.triggerPhrase = triggerPhrase
        self.target = target
    }

    /// Text spoken inline with the command, if any.
    public var payloadText: String {
        if case .spoken(let text) = target { return text }
        return ""
    }

    /// Whether the command needs text from somewhere other than the utterance itself.
    public var requiresSelectionFallback: Bool {
        target != .spoken(payloadText) || payloadText.isEmpty
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
    /// Phrases that name the text just inserted rather than a selection.
    ///
    /// Ordered longest first so "final insertion" is matched before "final".
    static let lastInsertionPhrases = [
        "final insertion",
        "last insertion",
        "the last insertion",
        "final dictation",
        "last dictation",
        "the final one",
        "the last one",
    ]

    public static func parse(
        transcript: String,
        customTriggers: [String: String] = VoicePreferences.customVoiceTriggers,
        wakeWords: [String] = VoicePreferences.voiceCommandWakeWords
    ) -> VoiceAICommand? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()

        // Wake words are stripped first so every pattern below sees a bare command.
        // "dev rewrite this" and "rewrite this" then follow identical paths, which is what
        // keeps a new wake word from needing a new branch in each pattern.
        let (body, bodyLower, hadWakeWord) = strippingWakeWord(
            trimmed: trimmed, lower: lower, wakeWords: wakeWords
        )

        // 1. Check custom triggers first (longest phrase match first to avoid prefix shadowing)
        let sortedTriggers = customTriggers.sorted { $0.key.count > $1.key.count }

        for (phrase, actionKey) in sortedTriggers {
            let lowerPhrase = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lowerPhrase.isEmpty, let kind = AITransformKind.named(actionKey) else { continue }

            // Pattern A: "phrase: payload" or "ai phrase: payload" or "phrase - payload"
            // A separator makes the intent explicit, so it stands on its own. A bare
            // "<trigger> <free text>" does not: "expand the search to include archived
            // items" is a sentence someone dictates, not a request to expand anything. That
            // form is only a command when a wake word preceded it.
            var prefixes = [
                lowerPhrase + ":",
                lowerPhrase + " -",
                lowerPhrase + ",",
            ]
            if hadWakeWord {
                prefixes.append(lowerPhrase + " ")
            }

            for prefix in prefixes {
                if bodyLower.hasPrefix(prefix) {
                    let rawPayload = String(body.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return VoiceAICommand(
                        kind: kind,
                        triggerPhrase: phrase,
                        target: target(forPayload: rawPayload)
                    )
                }
            }

            // Pattern B: Exact match (e.g. "explain code", "rephrase", "prompt enhance") -> transforms current selection
            if bodyLower == lowerPhrase || bodyLower == lowerPhrase + " this" {
                return VoiceAICommand(kind: kind, triggerPhrase: phrase, target: .selection)
            }

            // "proofread final insertion" — act on what was just typed.
            for suffix in lastInsertionPhrases where bodyLower == lowerPhrase + " " + suffix {
                return VoiceAICommand(kind: kind, triggerPhrase: phrase, target: .lastInsertion)
            }
        }

        // 2. Built-in trigger fallbacks
        for kind in AITransformKind.allCases where kind != .custom {
            let name = kind.rawValue.lowercased()
            var builtInPrefixes = [name + ":"]
            if hadWakeWord { builtInPrefixes.append(name + " ") }

            for prefix in builtInPrefixes {
                if bodyLower.hasPrefix(prefix) {
                    let payload = String(body.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return VoiceAICommand(
                        kind: kind,
                        triggerPhrase: name,
                        target: target(forPayload: payload)
                    )
                }
            }

            if bodyLower == name {
                return VoiceAICommand(kind: kind, triggerPhrase: name, target: .selection)
            }
        }

        return nil
    }

    // MARK: - Wake words

    /// Removes a leading wake word, so "dev rewrite this" is matched by the same code that
    /// matches "rewrite this".
    ///
    /// A wake word only counts at the very start and must be followed by more words — a
    /// dictation that merely *contains* "dev" is ordinary text, and one that is only the
    /// wake word is not a command.
    static func strippingWakeWord(
        trimmed: String,
        lower: String,
        wakeWords: [String]
    ) -> (body: String, lower: String, hadWakeWord: Bool) {
        for wake in wakeWords.sorted(by: { $0.count > $1.count }) {
            let prefix = wake.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + " "
            guard !prefix.isEmpty, lower.hasPrefix(prefix) else { continue }

            let body = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            return (body, body.lowercased(), true)
        }
        return (trimmed, lower, false)
    }

    /// A payload that names the last insertion targets that text rather than being it.
    static func target(forPayload payload: String) -> VoiceCommandTarget {
        let lower = payload.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return .selection }
        if lastInsertionPhrases.contains(lower) { return .lastInsertion }
        if lower == "this" || lower == "that" { return .selection }
        return .spoken(payload)
    }
}
