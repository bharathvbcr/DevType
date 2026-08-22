// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Builds TextExpander fill-in macro strings from typed parameters.
public enum FillInBuilder {

    /// Failure thrown by builders whose input cannot be represented without
    /// corrupting the emitted macro.
    public enum BuilderError: Error, Equatable {
        /// The content carries a sequence that `MacroParser` reads as macro
        /// structure; see `contentIsRepresentable(_:)`.
        case contentNotRepresentable
    }

    /// Sequences `MacroParser` resolves as structure when they appear in spliced
    /// content: `%fillpartend%` and `%caseend%` would close blocks early,
    /// `%fillpart:` opens a nested section that breaks bracket matching, and a
    /// valid `%case:<transform>%` silently re-cases everything after it.
    ///
    /// Why these cannot be escaped instead of rejected: §3.6's `%%` → `%`
    /// escaping is honored by `MacroParser.scanBody` only *inside* a
    /// `%keyword:…%` body. At statement level — where fill-part content lives —
    /// there is no escape mechanism: known sequences parse as structure and
    /// unknown ones stay literal, so doubling `%` cannot neutralize them. A lone
    /// `%` (and even a literal `%%`) is therefore perfectly safe and preserved;
    /// only the structural markers above are refused.
    private static let reservedContentSequences: Set<String> = [
        "%fillpartend%", "%fillpart:", "%case:", "%caseend%",
    ]

    private static func sanitizeToken(_ token: String) -> String {
        token.filter { $0 != ":" && $0 != "%" }
    }

    private static func sanitizeDefault(_ value: String) -> String {
        value.filter { $0 != "%" }
    }

    /// True when `value` can be embedded as a default clause.
    public static func defaultValueIsRepresentable(_ value: String) -> Bool {
        !value.contains("%")
    }

    /// True when `token` can be embedded as a name or option clause.
    public static func nameOrOptionIsRepresentable(_ token: String) -> Bool {
        !token.contains(":") && !token.contains("%")
    }

    /// True when `content` can be spliced verbatim into a `%fillpart` section
    /// without being reinterpreted as macro structure. Ordinary percent signs
    /// (`"50% off"`) are representable; structural markers are not.
    ///
    /// Check this before calling `fillPart(name:includeByDefault:content:)` when
    /// the content comes from user typing and you want to show an inline warning
    /// instead of catching the error.
    public static func contentIsRepresentable(_ content: String) -> Bool {
        reservedContentSequences.allSatisfy { !content.contains($0) }
    }

    public static func fillText(name: String, defaultValue: String) -> String {
        let n = sanitizeToken(name)
        let d = sanitizeDefault(defaultValue)
        return d.isEmpty ? "%filltext:name=\(n)%" : "%filltext:name=\(n):default=\(d)%"
    }

    public static func fillArea(name: String, defaultValue: String) -> String {
        let n = sanitizeToken(name)
        let d = sanitizeDefault(defaultValue)
        return d.isEmpty ? "%fillarea:name=\(n)%" : "%fillarea:name=\(n):default=\(d)%"
    }

    public static func fillPopup(name: String, options: [String], defaultValue: String) -> String {
        let n = sanitizeToken(name)
        let opts = options.map(sanitizeToken).filter { !$0.isEmpty }
        let d = sanitizeDefault(defaultValue)
        var body = "name=\(n)"
        for o in opts { body += ":\(o)" }
        if !d.isEmpty { body += ":default=\(d)" }
        return "%fillpopup:\(body)%"
    }

    /// Wraps `content` in a toggleable `%fillpart` section.
    ///
    /// - Throws: `BuilderError.contentNotRepresentable` when `content` contains a
    ///   structural marker (`%fillpartend%`, `%fillpart:`, `%case:`,
    ///   `%caseend%`). Splicing such content used to emit a macro that parses
    ///   with extra/shifted section boundaries or an open case block; since
    ///   statement-level text has no `%%` escape (see
    ///   `reservedContentSequences`), rejection is the only safe contract.
    public static func fillPart(
        name: String,
        includeByDefault: Bool,
        content: String
    ) throws -> String {
        guard contentIsRepresentable(content) else {
            throw BuilderError.contentNotRepresentable
        }
        let n = sanitizeToken(name)
        let flag = includeByDefault ? "yes" : "no"
        return "%fillpart:name=\(n):default=\(flag)%\(content)%fillpartend%"
    }
}
