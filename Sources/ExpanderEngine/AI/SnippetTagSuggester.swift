import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device tag / group suggestion for a snippet, via the SDK's `contentTagging` use case.
///
/// `SystemLanguageModel(useCase: .contentTagging)` is a purpose-built adapter — it is not
/// `.general` with a tagging prompt bolted on, and it is the one use case whose output is
/// *supposed* to be a short controlled vocabulary rather than prose. That makes it the right
/// tool for `SnippetModel.tags`, which until now nothing in the app ever produced: tags were
/// decodable, mergeable and exportable, but only ever arrived from an Espanso import.
///
/// **Nothing the model returns is trusted.** The model proposes; `normalizedTags` and
/// `resolvedGroupName` dispose. Two boundary rules in particular are load-bearing:
///
/// 1. `SnippetExporter` joins tags with `";"` for CSV. A tag containing a semicolon would
///    survive export and come back as *two* tags on re-import, so semicolons (and every other
///    separator that round-trips ambiguously) are rejected rather than escaped.
/// 2. A group name is only ever *selected* from the groups that already exist, matched
///    case-insensitively and returned in the library's own spelling. The model cannot create a
///    group, rename one, or misspell one into existence.
public enum SnippetTagSuggester {

    // MARK: - Preference

    public static let enabledKey = "devtype.ai.tagSuggestionsEnabled"

    /// Off by default. This spends model time on every new snippet, and the master
    /// `AIPreferences.isEnabled` switch still gates it — both must be on.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Both gates, in one place, so no caller can check only the feature flag.
    public static var isActive: Bool {
        AIPreferences.isEnabled && isEnabled
    }

    // MARK: - Limits

    /// Tags are a filter vocabulary, not a description. Past a handful they stop narrowing
    /// anything, and the row that displays them has finite width.
    public static let maximumTags = 5

    /// Long enough for `"meeting-notes"`, short enough that a leaked sentence is refused.
    public static let maximumTagLength = 24

    /// Below this a body carries no topic to tag — a `":brb"` → `"be right back"` snippet
    /// would get tags invented out of nothing.
    public static let minimumBodyCharacters = 24

    /// Characters that cannot appear in a tag because some format DevType already writes
    /// would read them back as structure: `;` is `SnippetExporter`'s CSV sub-delimiter and
    /// `,` / `"` are CSV's own.
    ///
    /// Deliberately *not* including newlines or tabs. They are equally unwelcome in a CSV row,
    /// but `normalizedTags` collapses all whitespace before it looks here, so by this point
    /// they cannot be present — listing them would read as a rule doing work it never does.
    /// Collapsing is also the better answer for them: a model that returns `"meeting\nnotes"`
    /// meant two words, whereas one that returns `"billing;urgent"` meant something this
    /// format cannot represent.
    static let forbiddenTagCharacters = CharacterSet(charactersIn: ";,\"")

    // MARK: - Result

    public struct Suggestion: Equatable, Sendable {
        /// Already normalized and capped — safe to assign straight to `SnippetModel.tags`.
        public let tags: [String]
        /// The *existing* group the snippet appears to belong to, in the library's own
        /// spelling, or `nil` for "no opinion". Never a new group.
        public let groupName: String?

        public static let none = Suggestion(tags: [], groupName: nil)

        public var isEmpty: Bool { tags.isEmpty && groupName == nil }

        public init(tags: [String], groupName: String?) {
            self.tags = tags
            self.groupName = groupName
        }
    }

    // MARK: - Eligibility

    /// Whether a snippet is worth asking about at all.
    ///
    /// A secret is refused outright and not merely skipped for lack of a body: the guard has to
    /// hold even if a caller passes the plaintext it just read out of the keychain, because the
    /// whole point of `isSecret` is that the value never reaches anything but the injection path.
    public static func shouldSuggest(body: String, isSecret: Bool) -> Bool {
        guard !isSecret else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimumBodyCharacters
    }

    // MARK: - Normalization (the trust boundary)

    /// Turns whatever the model returned into tags that are safe to store, or drops them.
    ///
    /// Lowercased because `SnippetStore`'s merge dedupes with a case-sensitive `contains`:
    /// `"Email"` and `"email"` would both survive a sync and show as two filters for one idea.
    /// Order is the model's, minus rejects — it ranks by relevance, and truncation should drop
    /// the least relevant rather than an arbitrary set-iteration order.
    public static func normalizedTags(_ raw: [String], existing: [String] = []) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var result: [String] = []
        for candidate in raw {
            guard result.count < maximumTags else { break }
            let collapsed = candidate
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#-_"))
                .lowercased()
            guard !collapsed.isEmpty, collapsed.count <= maximumTagLength else { continue }
            guard collapsed.rangeOfCharacter(from: forbiddenTagCharacters) == nil else { continue }
            // A "tag" that is a sentence is the model ignoring the format, not a long tag.
            guard collapsed.components(separatedBy: " ").count <= 3 else { continue }
            guard !seen.contains(collapsed) else { continue }
            seen.insert(collapsed)
            result.append(collapsed)
        }
        return result
    }

    /// Snaps a proposed group name onto one that exists, or returns `nil`.
    ///
    /// Returns the *library's* spelling, never the model's echo of it, so a suggestion can never
    /// be the vehicle for a silent rename.
    public static func resolvedGroupName(_ proposed: String?, in groupNames: [String]) -> String? {
        guard let proposed else { return nil }
        let needle = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return groupNames.first { $0.caseInsensitiveCompare(needle) == .orderedSame }
    }

    // MARK: - Prompt

    /// Built here rather than inline so the tests can assert what leaves the process.
    ///
    /// The body is truncated: tagging reads a topic off the opening lines, and sending a 40 KB
    /// snippet costs prefill on every keystroke-idle for no better answer.
    static func prompt(title: String, body: String, groupNames: [String]) -> String {
        let excerpt = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        var lines = ["Snippet title: \(title.isEmpty ? "(none)" : title)"]
        if !groupNames.isEmpty {
            lines.append("Existing groups: \(groupNames.joined(separator: ", "))")
            lines.append("Choose the single best-fitting existing group, or leave it blank.")
        }
        lines.append("Snippet text:")
        lines.append(excerpt)
        return lines.joined(separator: "\n")
    }

    // MARK: - Model path

    #if canImport(FoundationModels)

    @available(macOS 26.0, *)
    @Generable
    struct Tagging {
        @Guide(
            description: "One to five short lowercase topic tags, at most two words each.",
            .count(1...5)
        )
        var tags: [String]

        @Guide(description: "Best-fitting group name copied exactly from the supplied list, or empty.")
        var group: String
    }

    /// Serializes suggestions so two editors open at once cannot contend for the model.
    @available(macOS 26.0, *)
    private actor Latch {
        static let shared = Latch()
        private var busy = false
        func acquire() -> Bool {
            if busy { return false }
            busy = true
            return true
        }
        func release() { busy = false }
    }

    /// Best-effort. Returns `.none` for every failure — an unavailable model, an unsupported
    /// UI language, a refusal, a busy latch — because a snippet saving without tags is the
    /// normal case, not an error worth showing anyone.
    @available(macOS 26.0, *)
    public static func suggest(
        title: String,
        body: String,
        isSecret: Bool = false,
        existingTags: [String] = [],
        groupNames: [String] = []
    ) async -> Suggestion {
        guard isActive, shouldSuggest(body: body, isSecret: isSecret) else { return .none }

        let model = SystemLanguageModel(
            useCase: .contentTagging,
            guardrails: .permissiveContentTransformations
        )
        guard model.isAvailable else { return .none }
        // B′3: the locale check is free; letting an unsupported language fail inside
        // `respond` costs a full prefill first.
        guard model.supportsLocale(.current) else { return .none }

        guard await Latch.shared.acquire() else { return .none }
        defer { Task { await Latch.shared.release() } }

        do {
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(
                to: prompt(title: title, body: body, groupNames: groupNames),
                generating: Tagging.self,
                // Tagging is classification, not composition. Greedy also makes a second
                // pass over an unchanged snippet return the same tags.
                options: GenerationOptions(sampling: .greedy)
            )
            let content = response.content
            return Suggestion(
                tags: normalizedTags(content.tags, existing: existingTags),
                groupName: resolvedGroupName(content.group, in: groupNames)
            )
        } catch {
            DevTypeLog.store.debug(
                "[AI] tag suggestion declined: \(error.localizedDescription, privacy: .public)"
            )
            return .none
        }
    }

    #endif
}
