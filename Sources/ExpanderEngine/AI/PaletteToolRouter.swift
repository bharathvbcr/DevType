import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// C4 Stage 2 scaffold: on-device Tool routing for natural-language palette queries.
///
/// Prefer tools (`resolveDate`, `runMacro`, `findSnippet`) over a `@Generable`
/// classifier so the model cannot invent IDs. Guarded by `AIPreferences.isSemanticRoutingEnabled`,
/// ~250 ms debounce, and the transform single-flight latch so typing never starves transforms.
public enum PaletteToolRouter {
    public static let debounceMilliseconds: Int = 250

    /// Offline-only stub used when FoundationModels is unavailable or Stage 2 is disabled.
    public static func shouldAttemptRouting(query: String) -> Bool {
        guard AIPreferences.isEnabled, AIPreferences.isSemanticRoutingEnabled else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        // Typed prefixes already have deterministic handlers.
        if trimmed.hasPrefix("=") || trimmed.hasPrefix(">") { return false }
        return true
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
    #endif
}
