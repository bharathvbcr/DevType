import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Tool routing for natural-language palette queries.
///
/// Prefer tools (`resolveDate`, `runMacro`, `findSnippet`) over a `@Generable`
/// classifier so the model cannot invent IDs. Guarded by `AIPreferences.isSemanticRoutingEnabled`,
/// ~250 ms debounce, and a single-flight latch so typing never starves transforms.
///
/// Everything except the model call itself runs through `route(query:engine:)` with an
/// injected engine, so the gates, the latch, the staleness guard and the trust boundary are
/// all reachable in tests without a model — the same split `SnippetTagSuggester` uses.
public enum PaletteToolRouter {
    public static let debounceMilliseconds: Int = 250

    /// Longest a routing round trip may take before the row is abandoned.
    ///
    /// Without a bound, a model that never answers holds the single-flight latch for the rest
    /// of the session: every later keystroke finds the latch busy, and routing is dead with no
    /// error surfaced anywhere. The timeout relies on the engine honouring cancellation, which
    /// `LanguageModelSession.respond` does.
    public static let timeoutSeconds: Double = 8

    /// Longest text a routed row will carry. The palette shows one line; anything longer is
    /// the model having written prose instead of calling a tool, which is not a result.
    public static let maximumResultCharacters = 400

    /// A resolved answer, tagged with the query it was computed for.
    ///
    /// The query travels with the result because routing is asynchronous and debounced: by
    /// the time an answer lands the user has usually typed more, and a row answering an
    /// older query is worse than no row at all.
    public struct Routed: Equatable, Sendable {
        public let query: String
        public let text: String

        public init(query: String, text: String) {
            self.query = query
            self.text = text
        }
    }

    public typealias RoutingEngine = @Sendable (String) async throws -> String

    /// Whether this query is worth a model round trip.
    public static func shouldAttemptRouting(query: String) -> Bool {
        guard AIPreferences.isEnabled, AIPreferences.isSemanticRoutingEnabled else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        // Past the ranking cap it is a paste, not a question. Refusing here also keeps the
        // routed row's staleness check honest: `buildRows` compares against a clamped query,
        // so a routed answer to an unclamped one could never match it anyway.
        guard trimmed.count <= CommandPaletteCatalog.maximumQueryCharacters else { return false }
        // Typed prefixes already have deterministic handlers.
        if trimmed.hasPrefix("=") || trimmed.hasPrefix(">") { return false }
        return true
    }

    /// Serializes routing so a fast typist cannot stack model calls, and so routing never
    /// competes with an AI transform the user explicitly asked for.
    actor Latch {
        static let shared = Latch()
        private var busy = false
        func acquire() -> Bool {
            if busy { return false }
            busy = true
            return true
        }
        func release() { busy = false }
    }

    /// Runs `work`, returning `nil` when it has not finished within `seconds`.
    ///
    /// The loser is cancelled rather than left running, so a timed-out round trip does not go
    /// on consuming the model behind a palette the user has already closed.
    static func withTimeout(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> String
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// Nothing the model returns is trusted as a row.
    ///
    /// The tools resolve through `DateFormatLibrary` / `PaletteTextOps` / `SnippetSearch`, so
    /// a *tool result* is always real. This guards the other path: a model that answered in
    /// prose instead of calling a tool. Multi-line or overlong output is that, not an answer.
    static func sanitize(_ raw: String) -> String? {
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2028}", with: "\n")
        guard !collapsed.isEmpty else { return nil }
        guard !collapsed.contains("\n") else { return nil }
        guard collapsed.count <= maximumResultCharacters else { return nil }
        return collapsed
    }

    /// Best-effort. Returns `nil` for every failure — gates closed, latch busy, model refusal,
    /// prose instead of a tool call — because the palette's offline ranking is the primary
    /// answer and routing is only ever an addition to it.
    ///
    /// A `nil` engine means "no model available here" and is the normal state below macOS 26.
    public static func route(
        query: String,
        engine: RoutingEngine?,
        timeout: Double = timeoutSeconds
    ) async -> Routed? {
        guard let engine, shouldAttemptRouting(query: query) else { return nil }
        let trimmed = CommandPaletteCatalog.boundedQuery(query)
        guard await Latch.shared.acquire() else { return nil }

        // Released explicitly on both paths rather than in a `defer`: a deferred release is
        // ordered after the caller resumes, so the next keystroke's call would find the latch
        // still held and be dropped as if the model were busy.
        let routed: Routed?
        do {
            // Cancelled between acquiring the latch and starting work — the palette closed, so
            // there is nothing left to answer. Checked inside the do/catch so the latch below
            // is still released.
            try Task.checkCancellation()
            let raw = try await withTimeout(seconds: timeout) { try await engine(trimmed) }
            routed = raw.flatMap(sanitize).map { Routed(query: trimmed, text: $0) }
        } catch {
            DevTypeLog.store.debug(
                "[AI] palette routing declined: \(error.localizedDescription, privacy: .public)"
            )
            routed = nil
        }
        await Latch.shared.release()
        return routed
    }

    #if canImport(FoundationModels)
    /// Tool definitions the session may call. Implementations resolve through
    /// `DateFormatLibrary` / `CommandPaletteCatalog` / `SnippetSearch` — never guess IDs.
    @available(macOS 26.0, *)
    public struct ResolveDateTool: Tool {
        public let name = "resolveDate"
        public let description = "Resolve a relative or named date phrase into a formatted date string."

        @Generable
        public struct Arguments {
            @Guide(description: "Natural-language date phrase, e.g. 'next friday' or '+3w'.")
            public var phrase: String
            @Guide(description: "Optional format preset: medium, full, iso, time, datetime.")
            public var format: String?
        }

        public init() {}

        public func call(arguments: Arguments) async throws -> String {
            let phrase = arguments.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let format = (arguments.format?.isEmpty == false ? arguments.format! : "medium")
            if let typed = CommandPaletteCatalog.parseTypedQuery(phrase) {
                switch typed {
                case .relativeDays(let days, let fmt, _):
                    return CommandPaletteCatalog.resolveDate(.offsetDays(days, format: fmt))
                case .relativeOffset(let offset, let fmt, _):
                    return CommandPaletteCatalog.resolveDate(.offset(offset, format: fmt))
                default:
                    break
                }
            }
            if let relative = CommandPaletteCatalog.parseRelativeDayQuery(phrase) {
                return CommandPaletteCatalog.resolveDate(
                    .offsetDays(relative.days, format: relative.format)
                )
            }
            return CommandPaletteCatalog.resolveDate(.offsetDays(0, format: format))
        }
    }

    @available(macOS 26.0, *)
    public struct RunMacroTool: Tool {
        public let name = "runMacro"
        public let description = "Run a built-in palette text operation on the supplied text."

        @Generable
        public struct Arguments {
            @Guide(description: "Operation id such as upper, lower, sortLines, base64Encode.")
            public var operation: String
            @Guide(description: "Input text to transform.")
            public var text: String
        }

        public init() {}

        public func call(arguments: Arguments) async throws -> String {
            let key = arguments.operation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let op = PaletteTextOp(rawValue: key)
                    ?? PaletteTextOp(rawValue: key.lowercased()) else {
                return arguments.text
            }
            return PaletteTextOps.apply(op, to: arguments.text)
        }
    }

    @available(macOS 26.0, *)
    public struct FindSnippetTool: Tool {
        public let name = "findSnippet"
        public let description = "Find the best matching snippet trigger for a search phrase."

        @Generable
        public struct Arguments {
            @Guide(description: "Search phrase for the snippet library.")
            public var query: String
        }

        public let groupsProvider: @Sendable () -> [SnippetGroup]

        public init(groupsProvider: @escaping @Sendable () -> [SnippetGroup] = { SnippetStore.shared.loadGroups() }) {
            self.groupsProvider = groupsProvider
        }

        public func call(arguments: Arguments) async throws -> String {
            let hits = SnippetSearch.run(
                query: arguments.query,
                in: groupsProvider(),
                includeDisabled: false,
                limit: 1
            )
            guard let hit = hits.first else { return "" }
            return hit.snippet.triggerKeyword
        }
    }

    /// Builds the tool list for a routing session. Callers must still debounce and
    /// respect the AI transform single-flight latch before creating a session.
    @available(macOS 26.0, *)
    public static func makeTools(
        groupsProvider: @escaping @Sendable () -> [SnippetGroup] = { SnippetStore.shared.loadGroups() }
    ) -> [any Tool] {
        [ResolveDateTool(), RunMacroTool(), FindSnippetTool(groupsProvider: groupsProvider)]
    }

    /// The production engine, or `nil` when this Mac cannot serve one.
    ///
    /// Availability and locale are checked here rather than inside the returned closure so an
    /// unusable model reads as "no engine" — the same state as running below macOS 26 — and
    /// takes the identical path through `route`.
    @available(macOS 26.0, *)
    public static func foundationModelsEngine(
        groupsProvider: @escaping @Sendable () -> [SnippetGroup] = { SnippetStore.shared.loadGroups() }
    ) -> RoutingEngine? {
        let probe = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        guard probe.isAvailable else { return nil }
        guard probe.supportsLocale(.current) else { return nil }

        return { query in
            let model = SystemLanguageModel(
                useCase: .general,
                guardrails: .permissiveContentTransformations
            )
            let session = LanguageModelSession(
                model: model,
                tools: makeTools(groupsProvider: groupsProvider),
                instructions: routingInstructions
            )
            // Greedy: routing is classification, so the same query must route the same way
            // twice. A palette row that changes between keystrokes reads as a bug.
            let response = try await session.respond(
                to: query,
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content
        }
    }
    #endif

    /// Deliberately narrow. The tools resolve through real code and cannot invent an id, so
    /// the only way this can produce a wrong row is by answering from the model's own head —
    /// which is what the "call a tool or say nothing" rule and `sanitize` between them close.
    static let routingInstructions = """
        You turn a short phrase typed into a text-expander palette into a concrete result.
        Call exactly one of the provided tools and reply with only that tool's result.
        Reply with an empty string if no tool fits the phrase.
        Never explain, never add punctuation of your own, never answer from your own knowledge.
        """
}
