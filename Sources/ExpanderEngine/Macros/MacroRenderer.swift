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

    public init(
        text: String,
        cursorOffset: Int?,
        trailingKeys: [String],
        fillFields: [FillField],
        needsFillIn: Bool
    ) {
        self.text = text
        self.cursorOffset = cursorOffset
        self.trailingKeys = trailingKeys
        self.fillFields = fillFields
        self.needsFillIn = needsFillIn
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
        templateEngine: DynamicTemplateEngine = .shared
    ) -> MacroExpansionResult {
        expand(
            content: content,
            fillValues: fillValues,
            lookup: lookup,
            clipboardText: clipboardText,
            now: now,
            templateEngine: templateEngine,
            environment: .default
        )
    }

    /// §3.5: expansion with injectable locale / counter / random collaborators.
    ///
    /// One user-visible expansion runs this pipeline more than once — `EventTapEngine` renders a
    /// preview to pick an injection strategy, then `TextInjectionPipeline` renders the real
    /// payload. `memoSalt` is derived from `content` so both passes agree on the value of any
    /// `%random%` / `%counter%` token instead of planning against one string and injecting
    /// another (see `MacroVolatileStore`).
  public static func expand(
        content: String,
        fillValues: [Int: String] = [:],
        lookup: @escaping (String) -> String? = { _ in nil },
        clipboardText: String? = nil,
        now: Date = Date(),
        templateEngine: DynamicTemplateEngine = .shared,
        environment: MacroEnvironment
    ) -> MacroExpansionResult {
        let clipboardSnapshot = clipboardText ?? (NSPasteboard.general.string(forType: .string) ?? "")

        var environment = environment
        if environment.memoSalt.isEmpty {
            environment.memoSalt = "te:\(content.hashValue)"
        }

        let teNested = MacroParser.resolveNested(content, lookup: lookup)
        let fullyNested = resolveMustacheNested(teNested, lookup: lookup)
        let tokens = MacroParser.parse(fullyNested)
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

        // §1.12: `MacroParser.render` routes `%clipboard` through
        // `DynamicTemplateEngine.sanitizeClipboardText` before the mustache pass below sees it,
        // so a clipboard containing `{{calc:…}}` / `{{cursor}}` can no longer inject templates.
        let teResult = MacroParser.render(
            tokens: tokens,
            fillValues: fillValues,
            clipboard: clipboardSnapshot,
            now: now,
            environment: environment
        )

        let mustacheResult = templateEngine.resolve(
            teResult.text,
            currentDate: now,
            clipboardText: clipboardSnapshot,
            environment: environment
        )

        let cursorOffset = mergeCursorOffsets(
            teText: teResult.text,
            teOffsetFromEnd: teResult.cursorOffsetFromEnd,
            mustacheOffset: mustacheResult.cursorOffset
        )

        return MacroExpansionResult(
            text: mustacheResult.text,
            cursorOffset: cursorOffset,
            trailingKeys: teResult.trailingKeys,
            fillFields: fields,
            needsFillIn: needsFillIn
        )
    }

    /// Resolves `{{snippet:trigger}}` mustache nested snippets (depth < 10).
    public static func resolveMustacheNested(
        _ content: String,
        lookup: (String) -> String?,
        depth: Int = 0
    ) -> String {
        guard depth < 10, content.contains("{{snippet:"), let regex = mustacheSnippetRegex else {
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
            if let nested = lookup(trigger) {
                let resolved = MacroParser.resolveNested(nested, lookup: lookup, depth: depth + 1)
                replacement = resolveMustacheNested(resolved, lookup: lookup, depth: depth + 1)
            } else {
                replacement = "{{snippet:\(trigger)}}"
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    /// Prefer mustache `{{cursor}}` when present; otherwise convert TE `%|%` grapheme offset to UTF-16.
    private static func mergeCursorOffsets(
        teText: String,
        teOffsetFromEnd: Int,
        mustacheOffset: Int?
    ) -> Int? {
        if let mustacheOffset {
            return mustacheOffset
        }
        guard teOffsetFromEnd > 0 else { return nil }
        let graphemeCount = teText.count
        let graphemeIndex = graphemeCount - teOffsetFromEnd
        guard graphemeIndex >= 0, graphemeIndex <= graphemeCount else { return nil }
        let prefix = String(teText.prefix(graphemeIndex))
        return prefix.utf16.count
    }
}
