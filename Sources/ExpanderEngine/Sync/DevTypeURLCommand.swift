import Foundation

/// A `devtype://` command. The grammar is `devtype://<action>[/<sub>][?query]`.
///
/// There is no `expand` action. A URL must never inject text into the frontmost
/// app and must never read a secret. Copy and dictation still need an in-app
/// confirmation before they do anything; this type only classifies the URL.
public enum DevTypeURLCommand: Equatable, Sendable {
    /// Open the snippet editor with these fields. Nothing is saved.
    case newSnippet(title: String, trigger: String, text: String)
    case palette
    /// `tab == nil` opens Preferences on its default section, including an unknown tab name.
    case preferences(tab: DevTypePreferencesTab?)
    case toggleDictation
    /// Exact trigger match. Empty is not representable; the parser rejects it.
    case copy(trigger: String)

    /// Editor seed for `new`. Nothing is saved. A blank new snippet is case-sensitive,
    /// and this draft is never a secret: the editor would send a secret to the secret manager.
    public static func editorDraft(title: String, trigger: String, text: String) -> SnippetModel {
        SnippetModel(
            title: title,
            triggerKeyword: trigger,
            replacementText: text,
            isCaseSensitive: true,
            isSecret: false
        )
    }
}

public enum DevTypePreferencesTab: String, Equatable, Sendable, CaseIterable {
    case home
    case general
    case snippets
    case hotkeys
    case voice
    case ai
    case advanced
}

public enum DevTypeURLParseFailure: Equatable, Sendable {
    /// Another scheme, or a host that looks like a domain (`evil.example`).
    case foreignHost
    /// A `devtype://` host that is not on the allowlist.
    case unknownAction
    case malformed
    case oversized
}

public enum DevTypeURLParseResult: Equatable, Sendable {
    case command(DevTypeURLCommand)
    case failure(DevTypeURLParseFailure)
}

public enum DevTypeURLParser {
    /// Longest preferences tab name we will even look at. Longer than this is rejected
    /// before it is compared with the allowlist.
    public static let maxPreferencesTabCharacters = 64

    /// Raw URL cap, applied before any parse. A body at the replacement limit plus a
    /// short scheme and query still fits; anything past that is refused whole.
    public static var maxRawURLCharacters: Int {
        SnippetImporter.SnippetImportLimits.maxReplacementCharacters + 4096
    }

    /// One percent-decode, the one `URLComponents.queryItems` already performed.
    /// Do not call `removingPercentEncoding` on the result: `hello%2520world` must
    /// stay `hello%20world`.
    public static func parse(_ raw: String) -> DevTypeURLParseResult {
        if raw.count > maxRawURLCharacters {
            return .failure(.oversized)
        }
        guard let components = URLComponents(string: raw) else {
            return .failure(.malformed)
        }
        guard components.scheme?.lowercased() == "devtype" else {
            return .failure(.foreignHost)
        }
        if components.user != nil || components.password != nil || components.port != nil {
            return .failure(.malformed)
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            return .failure(.malformed)
        }
        if host.contains(".") {
            return .failure(.foreignHost)
        }

        let items: [URLQueryItem]
        if components.query == nil {
            items = []
        } else if let parsed = components.queryItems {
            items = parsed
        } else {
            return .failure(.malformed)
        }

        switch host {
        case "new":
            guard normalizedPath(components.path).isEmpty else { return .failure(.malformed) }
            let title = first(items, named: "title")
            let trigger = first(items, named: "trigger")
            let text = first(items, named: "text")
            if title.count > SnippetImporter.SnippetImportLimits.maxTriggerCharacters
                || trigger.count > SnippetImporter.SnippetImportLimits.maxTriggerCharacters
                || text.count > SnippetImporter.SnippetImportLimits.maxReplacementCharacters {
                return .failure(.oversized)
            }
            return .command(.newSnippet(title: title, trigger: trigger, text: text))
        case "palette":
            guard normalizedPath(components.path).isEmpty else { return .failure(.malformed) }
            return .command(.palette)
        case "preferences":
            guard normalizedPath(components.path).isEmpty else { return .failure(.malformed) }
            let tabRaw = first(items, named: "tab")
            if tabRaw.count > maxPreferencesTabCharacters {
                return .failure(.oversized)
            }
            let tab = tabRaw.isEmpty ? nil : DevTypePreferencesTab(rawValue: tabRaw.lowercased())
            return .command(.preferences(tab: tab))
        case "dictation":
            guard normalizedPath(components.path) == "/toggle" else { return .failure(.malformed) }
            return .command(.toggleDictation)
        case "copy":
            guard normalizedPath(components.path).isEmpty else { return .failure(.malformed) }
            let trigger = first(items, named: "trigger")
            if trigger.isEmpty { return .failure(.malformed) }
            if trigger.count > SnippetImporter.SnippetImportLimits.maxTriggerCharacters {
                return .failure(.oversized)
            }
            return .command(.copy(trigger: trigger))
        default:
            return .failure(.unknownAction)
        }
    }

    /// First value for `name`. Unknown keys are ignored. The value is the single
    /// decode `URLQueryItem` already applied.
    private static func first(_ items: [URLQueryItem], named name: String) -> String {
        items.first { $0.name == name }?.value ?? ""
    }

    /// `""` and `"/"` are an empty path. A trailing slash does not make `/toggle` a different action.
    private static func normalizedPath(_ path: String) -> String {
        var text = path.lowercased()
        if text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        if text == "/" { return "" }
        return text
    }
}

/// What a `copy` URL may do. A secret match refuses before any store read: the
/// decision only looks at `SnippetModel.isSecret`, which is the library flag,
/// not the keychain value.
public enum DevTypeURLCopyDecision: Equatable {
    case confirm(SnippetModel)
    case refusedSecret
    case notFound
    case ambiguous
}

public enum DevTypeURLCopy {
    /// Exact `triggerKeyword` match.
    ///
    /// Any secret match, including a disabled one, refuses the whole set. An empty
    /// trigger matches nothing, so a snippet whose trigger is empty cannot be copied
    /// by omitting the query. Two or more non-secret matches copy nothing.
    public static func decide(trigger: String, in snippets: [SnippetModel]) -> DevTypeURLCopyDecision {
        guard !trigger.isEmpty else { return .notFound }
        let matches = snippets.filter { $0.triggerKeyword == trigger }
        if matches.contains(where: \.isSecret) {
            return .refusedSecret
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .confirm(matches[0])
        default: return .ambiguous
        }
    }
}

/// Log line for a copy URL. The only inputs are the result tag and the originating
/// bundle id, so a trigger or title cannot appear in the line.
public enum DevTypeURLCopyAudit {
    public enum Result: String, Equatable, Sendable {
        case needsConfirm = "needs-confirm"
        case refusedSecret = "refused-secret"
        case notFound = "not-found"
        case ambiguous = "ambiguous"
    }

    public static func line(result: Result, originBundleIdentifier: String?) -> String {
        let origin = DevTypeLog.boundedPublicIdentifier(originBundleIdentifier, label: "origin")
        return "action=copy result=\(result.rawValue) origin=\(origin)"
    }
}

/// Log line for every other URL outcome. Callers pass a fixed action and result
/// token. This function has no parameter for a query value or a snippet body.
public enum DevTypeURLAudit {
    public static func line(action: String, result: String, originBundleIdentifier: String?) -> String {
        let origin = DevTypeLog.boundedPublicIdentifier(originBundleIdentifier, label: "origin")
        return "action=\(action) result=\(result) origin=\(origin)"
    }
}
