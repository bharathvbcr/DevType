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

    // MARK: - The model call, behind a seam

    /// Raw, untrusted model output — before `normalizedTags` and `resolvedGroupName` have had
    /// their say. Exists so the composition around the model can be driven without one.
    public struct RawTagging: Sendable, Equatable {
        public let tags: [String]
        public let group: String?

        public init(tags: [String], group: String?) {
            self.tags = tags
            self.group = group
        }
    }

    /// The one step that genuinely needs macOS 26 and on-device model assets.
    ///
    /// Everything else in `suggest` — the two preference gates, the secret refusal, the
    /// eligibility floor, the single-flight latch, normalization, group resolution, and the
    /// "every failure is just no suggestion" rule — is ordinary logic that was previously
    /// unreachable from a test purely because it sat in the same function as the model call.
    public typealias TaggingEngine = @Sendable (String) async throws -> RawTagging

    /// Serializes suggestions so two editors open at once cannot contend for the model.
    /// Not availability-gated: the latch is a plain actor, and the rule it enforces is
    /// testable without a model. Its own instance, separate from palette routing's.
    static let latch = SingleFlightLatch()

    /// Best-effort. Returns `.none` for every failure — no engine, an unsupported UI language,
    /// a refusal, a busy latch — because a snippet saving without tags is the normal case, not
    /// an error worth showing anyone.
    ///
    /// A `nil` engine means "no model available here" and is the normal state below macOS 26.
    static func suggest(
        title: String,
        body: String,
        isSecret: Bool,
        existingTags: [String],
        groupNames: [String],
        engine: TaggingEngine?
    ) async -> Suggestion {
        guard isActive, shouldSuggest(body: body, isSecret: isSecret), let engine else {
            return .none
        }
        guard await latch.acquire() else { return .none }

        // Released with `await`, not from a detached `Task` in a `defer`. A deferred release is
        // ordered *after* the caller resumes, so a second call made straight away — which is
        // exactly what `SnippetLibraryTagger` does — found the latch still held and was dropped
        // as if the model were busy. The editor never saw it, because its calls are a debounce
        // apart. `defer` cannot `await`, so the release is spelled out on both paths instead.
        let suggestion: Suggestion
        do {
            let raw = try await engine(prompt(title: title, body: body, groupNames: groupNames))
            suggestion = Suggestion(
                tags: normalizedTags(raw.tags, existing: existingTags),
                groupName: resolvedGroupName(raw.group, in: groupNames)
            )
        } catch {
            DevTypeLog.store.debug(
                "[AI] tag suggestion declined \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            suggestion = .none
        }
        await latch.release()
        return suggestion
    }

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

    /// The production engine, or `nil` when this Mac cannot serve one.
    ///
    /// The availability and locale checks happen here rather than inside the returned closure so
    /// an unusable model reads as "no engine" — the same state as running below macOS 26 — and
    /// takes the identical path through `suggest`.
    @available(macOS 26.0, *)
    public static func foundationModelsEngine() -> TaggingEngine? {
        let probe = SystemLanguageModel(
            useCase: .contentTagging,
            guardrails: .permissiveContentTransformations
        )
        guard probe.isAvailable else { return nil }
        // B'3: the locale check is free; letting an unsupported language fail inside `respond`
        // costs a full prefill first.
        guard probe.supportsLocale(.current) else { return nil }

        return { prompt in
            let model = SystemLanguageModel(
                useCase: .contentTagging,
                guardrails: .permissiveContentTransformations
            )
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(
                to: prompt,
                generating: Tagging.self,
                // Tagging is classification, not composition. Greedy also makes a second pass
                // over an unchanged snippet return the same tags.
                options: GenerationOptions(sampling: .greedy)
            )
            return RawTagging(tags: response.content.tags, group: response.content.group)
        }
    }

    @available(macOS 26.0, *)
    public static func suggest(
        title: String,
        body: String,
        isSecret: Bool = false,
        existingTags: [String] = [],
        groupNames: [String] = []
    ) async -> Suggestion {
        await suggest(
            title: title,
            body: body,
            isSecret: isSecret,
            existingTags: existingTags,
            groupNames: groupNames,
            engine: foundationModelsEngine()
        )
    }

    #endif
}
