// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import AppKit
import Foundation

public struct MacroExpansionResult: Equatable {
    public let text: String
    /// UTF-16 offset from start (DevType caret style).
    public let cursorOffset: Int?
    public let trailingKeys: [String]
    public let fillFields: [FillField]
    public let needsFillIn: Bool
    public let failure: MacroRenderFailure?

    public init(
        text: String,
        cursorOffset: Int?,
        trailingKeys: [String],
        fillFields: [FillField],
        needsFillIn: Bool,
        failure: MacroRenderFailure? = nil
    ) {
        self.text = text
        self.cursorOffset = cursorOffset
        self.trailingKeys = trailingKeys
        self.fillFields = fillFields
        self.needsFillIn = needsFillIn
        self.failure = failure
    }
}

/// Explicit lifetime for preparation, including time and clipboard snapshots. Create one per
/// user expansion and retain it while a fill-in panel is open or a preparation is retried.
public final class MacroRenderContext {
    public let operationID: UUID
    public let now: Date
    public let clipboardText: String
    public let environment: MacroEnvironment
    private let compileLock = NSLock()
    private var compiled: (source: String, tokens: Result<[MacroToken], MacroRenderFailure>)?

    public init(clipboardText: String, now: Date = Date(), environment: MacroEnvironment = .default) {
        let id = UUID()
        operationID = id
        self.now = now
        self.clipboardText = clipboardText
        var scoped = environment
        scoped.memoSalt = id.uuidString
        scoped.volatileValues = MacroVolatileStore()
        self.environment = scoped
    }
    func tokens(for source: String, lookup: (String) -> String?) -> Result<[MacroToken], MacroRenderFailure> {
        compileLock.lock()
        defer { compileLock.unlock() }
        if let compiled {
            return compiled.source == source ? compiled.tokens : .failure(.sourceChanged)
        }
        let budget = MacroParser.NestedSnippetBudget()
        let nested = MacroParser.resolveNested(source, lookup: lookup, budget: budget)
        let resolved = MacroRenderer.resolveMustacheNested(nested, lookup: lookup, budget: budget)
        let result: Result<[MacroToken], MacroRenderFailure>
        if resolved.utf16.prefix(MacroDocument.maximumUTF16 + 1).count > MacroDocument.maximumUTF16 {
            result = .failure(.sizeLimit)
        } else {
            let tokens = MacroParser.parse(resolved)
            result = tokens.count <= MacroDocument.maximumOperations ? .success(tokens) : .failure(.workLimit)
        }
        compiled = (source, result)
        return result
    }

}

/// Full expansion pipeline: TE parse → nested → fill-in → mustache → emit.
public enum MacroRenderer {

  private static let mustacheSnippetRegex = try? NSRegularExpression(
        pattern: "\\{\\{snippet:([^}]+)\\}\\}",
        options: []
    )

    /// Expands snippet content through TextExpander macros and DevType mustache templates.
    ///
    /// - Parameters:
    ///   - content: Raw snippet replacement text.
    ///   - fillValues: User-provided fill-in values keyed by `FillField.id`.
    ///   - lookup: Resolves nested snippet triggers to replacement text.
    ///   - clipboardText: Pre-snapshot clipboard; when nil, reads pasteboard once at call time.
    ///   - now: Date used for `%date:` and mustache date tags.
  public static func expand(
        content: String,
        fillValues: [Int: String] = [:],
        lookup: @escaping (String) -> String? = { _ in nil },
        clipboardText: String? = nil,
        now: Date = Date(),
        templateEngine: DynamicTemplateEngine = .shared,
        context: MacroRenderContext? = nil
    ) -> MacroExpansionResult {
        expand(
            content: content,
            fillValues: fillValues,
            lookup: lookup,
            clipboardText: clipboardText,
            now: now,
            templateEngine: templateEngine,
            environment: .default,
            context: context
        )
    }

    /// An omitted context starts a new operation, even when content and timing match another
    /// expansion. Repeated preparation explicitly passes the original context.
  public static func expand(
        content: String,
        fillValues: [Int: String] = [:],
        lookup: @escaping (String) -> String? = { _ in nil },
        clipboardText: String? = nil,
        now: Date = Date(),
        templateEngine: DynamicTemplateEngine = .shared,
        environment: MacroEnvironment,
        context: MacroRenderContext? = nil
    ) -> MacroExpansionResult {
        guard content.utf16.prefix(MacroDocument.maximumUTF16 + 1).count <= MacroDocument.maximumUTF16 else {
            return MacroExpansionResult(text: "", cursorOffset: nil, trailingKeys: [], fillFields: [], needsFillIn: false, failure: .sizeLimit)
        }
        let context = context ?? MacroRenderContext(
            clipboardText: clipboardText ?? (NSPasteboard.general.string(forType: .string) ?? ""),
            now: now, environment: environment
        )
        let clipboardSnapshot = context.clipboardText
        let now = context.now
        let environment = context.environment

        let tokens: [MacroToken]
        switch context.tokens(for: content, lookup: lookup) {
        case .success(let compiled): tokens = compiled
        case .failure(let reason):
            return MacroExpansionResult(text: "", cursorOffset: nil, trailingKeys: [], fillFields: [], needsFillIn: false, failure: reason)
        }
        let fields = MacroParser.fillFields(in: tokens)
        let needsFillIn = MacroParser.hasFillIns(tokens)

        if needsFillIn && fillValues.isEmpty {
            return MacroExpansionResult(
                text: "",
                cursorOffset: nil,
                trailingKeys: [],
                fillFields: fields,
                needsFillIn: true
            )
        }

        let teResult = MacroParser.renderDocument(
            tokens: tokens, fillValues: fillValues, clipboard: clipboardSnapshot, now: now, environment: environment
        )
        let document = templateEngine.render(teResult.document, currentDate: now, clipboardText: clipboardSnapshot,
                                              environment: environment)
        let mustacheResult = templateEngine.result(document)

        return MacroExpansionResult(
            text: mustacheResult.text,
            cursorOffset: mustacheResult.cursorOffset,
            trailingKeys: document.failure == nil ? teResult.trailingKeys : [],
            fillFields: fields,
            needsFillIn: needsFillIn,
            failure: mustacheResult.failure
        )
    }

    /// Resolves `{{snippet:trigger}}` mustache nested snippets (depth < 10).
    ///
    /// The budget bounds total fan-out across this pass *and* every TE resolution
    /// it performs (a branching reference library previously cost Fᴸ expansions —
    /// a hang/memory bomb from one typed trigger). Exhaustion leaves references
    /// literal, matching depth-cap and unresolved-reference behavior.
    public static func resolveMustacheNested(
        _ content: String,
        lookup: (String) -> String?,
        depth: Int = 0,
        budget: MacroParser.NestedSnippetBudget = MacroParser.NestedSnippetBudget()
    ) -> String {
        guard depth < 10, content.contains("{{snippet:"), let regex = mustacheSnippetRegex,
              budget.canResolveMore
        else {
            return content
        }
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        var result = content
        let matches = regex.matches(in: content, options: [], range: range).reversed()
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let trigger = ns.substring(with: match.range(at: 1))
            let replacement: String
            if let nested = lookup(trigger), budget.canResolveMore {
                let resolved = MacroParser.resolveNested(nested, lookup: lookup, depth: depth + 1, budget: budget)
                let fullyResolved = resolveMustacheNested(resolved, lookup: lookup, depth: depth + 1, budget: budget)
                budget.recordResolution(producedUTF16Count: fullyResolved.utf16.count)
                replacement = fullyResolved
            } else {
                // Unresolved or over-budget: keep the reference literal.
                replacement = "{{snippet:\(trigger)}}"
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

}
