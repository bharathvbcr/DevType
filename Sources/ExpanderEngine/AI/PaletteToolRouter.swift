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
    /// The caller returns by the deadline plus a short cancellation grace. An engine that
    /// ignores cancellation retains admission until it exits, keeping resource use bounded.
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
        /// Set only by `LappiRouteAdmission`, and only from a `model_answered` reading. It
        /// annotates the row's subtitle; it never changes `text` and never creates a row.
        public let lappiNote: LappiNote?

        public init(query: String, text: String, lappiNote: LappiNote? = nil) {
            self.query = query
            self.text = text
            self.lappiNote = lappiNote
        }
    }

    /// Whether Lappi's answered route matches the tool routing actually ran.
    public enum LappiNote: String, Equatable, Sendable {
        case agrees
        case differs
    }

    /// Reports a tool's name when the routing session calls it.
    public typealias ToolCallObserver = @Sendable (String) -> Void

    public typealias RoutingEngine = @Sendable (String) async throws -> String

    /// A tool recognized the call but will not invent a result. `route` drops the throw.
    public enum Refusal: Error, Equatable, Sendable {
        case unrecognizedDate
        case unknownOperation
    }

    /// Formatted date when `parseTypedQuery` or `parseRelativeDayQuery` accepts `phrase`.
    ///
    /// `format` is the tool's optional preset and is not applied: a hit keeps the format the
    /// parser already chose, and a miss is nil rather than today in that preset.
    public static func resolveDatePhrase(phrase: String, format _: String?) -> String? {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return nil
    }

    /// The text operation `operation` names, applied to `text`. An unknown id is nil —
    /// never `text` echoed back.
    public static func runMacro(operation: String, text: String) -> String? {
        guard let op = PaletteTextOp.resolved(from: operation) else { return nil }
        return PaletteTextOps.apply(op, to: text)
    }

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
    /// competes with an AI transform the user explicitly asked for. Its own instance: tag
    /// suggestion has a separate one and the two must not block each other.
    static let latch = SingleFlightLatch()

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
        do {
            let raw: String? = try await latch.run(timeout: timeout) { try await engine(trimmed) }
            try Task.checkCancellation()
            return raw.flatMap(sanitize).map { Routed(query: trimmed, text: $0) }
        } catch {
            DevTypeLog.store.debug(
                "[AI] palette routing declined \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return nil
        }
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

        public let onCall: ToolCallObserver?

        public init(onCall: ToolCallObserver? = nil) {
            self.onCall = onCall
        }

        public func call(arguments: Arguments) async throws -> String {
            onCall?(name)
            guard let resolved = PaletteToolRouter.resolveDatePhrase(
                phrase: arguments.phrase,
                format: arguments.format
            ) else {
                throw PaletteToolRouter.Refusal.unrecognizedDate
            }
            return resolved
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

        public let onCall: ToolCallObserver?

        public init(onCall: ToolCallObserver? = nil) {
            self.onCall = onCall
        }

        public func call(arguments: Arguments) async throws -> String {
            onCall?(name)
            guard let transformed = PaletteToolRouter.runMacro(
                operation: arguments.operation,
                text: arguments.text
            ) else {
                throw PaletteToolRouter.Refusal.unknownOperation
            }
            return transformed
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
        /// Library revision matching whatever `groupsProvider` returns, so the search index
        /// cache can identify it without hashing every snippet. `nil` means "unknown", which
        /// falls back to the content fingerprint.
        public let revisionProvider: @Sendable () -> UInt64?
        /// Identity of the library `revisionProvider` counts in. A revision means nothing
        /// without it, so `nil` still falls back to the content fingerprint.
        public let libraryIDProvider: @Sendable () -> UUID?
        public let onCall: ToolCallObserver?

        public init(
            groupsProvider: @escaping @Sendable () -> [SnippetGroup] = { SnippetStore.shared.loadGroups() },
            revisionProvider: @escaping @Sendable () -> UInt64? = { nil },
            libraryIDProvider: @escaping @Sendable () -> UUID? = { nil },
            onCall: ToolCallObserver? = nil
        ) {
            self.groupsProvider = groupsProvider
            self.revisionProvider = revisionProvider
            self.libraryIDProvider = libraryIDProvider
            self.onCall = onCall
        }

        public func call(arguments: Arguments) async throws -> String {
            onCall?(name)
            let hits = SnippetSearch.run(
                query: arguments.query,
                in: SnippetDocument(groups: groupsProvider()).groups,
                includeDisabled: false,
                limit: 1,
                revision: revisionProvider(),
                libraryID: libraryIDProvider()
            )
            guard let hit = hits.first else { return "" }
            return hit.snippet.triggerKeyword
        }
    }

    /// Builds the tool list for a routing session. Callers must still debounce and
    /// respect the AI transform single-flight latch before creating a session.
    @available(macOS 26.0, *)
    public static func makeTools(
        groupsProvider: @escaping @Sendable () -> [SnippetGroup] = { SnippetStore.shared.loadGroups() },
        onToolCalled: ToolCallObserver? = nil
    ) -> [any Tool] {
        [
            ResolveDateTool(onCall: onToolCalled),
            RunMacroTool(onCall: onToolCalled),
            FindSnippetTool(groupsProvider: groupsProvider, onCall: onToolCalled),
        ]
    }

    /// The production engine, or `nil` when this Mac cannot serve one.
    ///
    /// Availability and locale are checked here rather than inside the returned closure so an
    /// unusable model reads as "no engine" — the same state as running below macOS 26 — and
    /// takes the identical path through `route`.
    @available(macOS 26.0, *)
    public static func foundationModelsEngine(
        groupsProvider: @escaping @Sendable () -> [SnippetGroup] = { SnippetStore.shared.loadGroups() },
        onToolCalled: ToolCallObserver? = nil
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
                tools: makeTools(groupsProvider: groupsProvider, onToolCalled: onToolCalled),
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
