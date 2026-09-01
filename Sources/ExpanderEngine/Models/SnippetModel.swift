import Foundation

public struct SnippetModel: Codable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    /// Optional display label (TextExpander import). Falls back to `title` when empty.
    public var label: String
    public var triggerKeyword: String
    public var replacementText: String
    public var isCaseSensitive: Bool
    public var requireWordBoundary: Bool
    public var isPlainText: Bool
    public var enabled: Bool
    /// File name of an attached image inside `ImageAttachmentStore` (empty = text snippet).
    public var imagePath: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Legacy in-library usage counter. Live counts now live in `UsageStatsStore`
    /// (§1.5); this field is retained so existing JSON keeps decoding and so the
    /// sidecar can be seeded from it on first load.
    public var usageCount: Int
    /// §4.4: Free-form tags for organization / filtering. Backward-compatible (defaults to empty).
    public var tags: [String]
    /// §4.4: Bundle IDs this snippet is limited to. Empty = available everywhere.
    public var includeApps: [String]
    /// §4.4: Bundle IDs this snippet is suppressed in. Takes precedence over `includeApps`.
    public var excludeApps: [String]
    /// On-device AI transform kind id (empty = plain snippet). Backward-compatible via `decodeIfPresent`.
    public var aiTransform: String

    /// The replacement text lives in the keychain (`SecretStore`), not in this struct.
    ///
    /// `replacementText` is empty for a secret both on disk and in memory: it is fetched at the
    /// moment of use and dropped. That is what keeps a password out of the library JSON, out of
    /// every export, out of the editor's text view, and out of the diagnostic report — none of
    /// which had to learn a new rule, because there is nothing there to leak.
    public var isSecret: Bool

    /// True when this snippet pastes an image instead of text.
    public var isImageSnippet: Bool { !isSecret && !imagePath.isEmpty }

    /// May this snippet expand from a *typed* trigger?
    ///
    /// Never, for a secret. Two independent reasons, either sufficient:
    ///
    /// 1. It cannot work where it is wanted. macOS Secure Event Input withholds keystrokes from
    ///    every event tap while a password field has focus (TN2150), so the trigger is never seen.
    /// 2. It is dangerous everywhere else. A trigger that fires on typing fires in the chat window
    ///    and the shared document too — the one place a password must never appear is wherever the
    ///    user did not deliberately ask for it. An explicit gesture (menu, palette) cannot misfire.
    public var isTypedTriggerExpandable: Bool { !isSecret }

    /// What the UI may show in place of the value. Never the value itself.
    public var maskedReplacement: String { String(repeating: "•", count: 12) }

    /// §4.4: App-scope test for the matcher / injection layers.
    /// `nil` or empty `bundleID` means "unknown frontmost app" — such a context only
    /// satisfies snippets that are not restricted to a specific app list.
    public func appliesTo(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return includeApps.isEmpty }
        if excludeApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return false
        }
        if includeApps.isEmpty { return true }
        return includeApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
    }

    public init(
        id: UUID = UUID(),
        title: String,
        label: String = "",
        triggerKeyword: String,
        replacementText: String,
        isCaseSensitive: Bool = false,
        requireWordBoundary: Bool = true,
        isPlainText: Bool = true,
        enabled: Bool = true,
        imagePath: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        usageCount: Int = 0,
        tags: [String] = [],
        includeApps: [String] = [],
        excludeApps: [String] = [],
        aiTransform: String = "",
        isSecret: Bool = false
    ) {
        self.id = id
        self.title = title
        self.label = label
        self.triggerKeyword = triggerKeyword
        self.replacementText = replacementText
        self.isCaseSensitive = isCaseSensitive
        self.requireWordBoundary = requireWordBoundary
        self.isPlainText = isPlainText
        self.enabled = enabled
        self.imagePath = imagePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usageCount = usageCount
        self.tags = tags
        self.includeApps = includeApps
        self.excludeApps = excludeApps
        self.aiTransform = aiTransform
        self.isSecret = isSecret
        // A secret's value never lives in the struct, not even transiently: an initialiser that
        // accepted one would put it in every copy, every listener callback, and every `Recent`
        // entry. Callers hand the value to `SecretStore` and the trigger to this.
        if isSecret {
            self.replacementText = ""
            self.imagePath = ""
            // No AI transform either. Nothing routes a secret to the model today, but the field
            // existing on a secret is an invitation for some future path to read it and send a
            // password off to be rewritten. Unrepresentable beats guarded-everywhere.
            self.aiTransform = ""
        }
    }

    /// Display title for lists: label if present, else title, else trigger.
    public var displayTitle: String {
        if !label.isEmpty { return label }
        if !title.isEmpty { return title }
        return triggerKeyword
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, label, triggerKeyword, replacementText
        case isCaseSensitive, requireWordBoundary, isPlainText, enabled
        case imagePath, createdAt, updatedAt, usageCount
        // §4.4: added in schema v2.1 — always decoded with `decodeIfPresent`.
        case tags, includeApps, excludeApps
        // On-device AI — absent in every pre-existing library file.
        case aiTransform
        // Keychain-backed secrets — absent in every library written before them.
        case isSecret
    }

    /// Encoding is where the guarantee is enforced, not at the call sites.
    ///
    /// Every path that writes a library — `saveSnippets`, `exportLibraryData`, the JSON/CSV/YAML
    /// exporters, the conflict snapshots — runs through this one method. Redacting here means a
    /// future writer cannot forget to, and `replacementText` for a secret is written as the empty
    /// string rather than omitted so a downgraded build still reads a well-formed snippet.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(label, forKey: .label)
        try c.encode(triggerKeyword, forKey: .triggerKeyword)
        try c.encode(isSecret ? "" : replacementText, forKey: .replacementText)
        try c.encode(isCaseSensitive, forKey: .isCaseSensitive)
        try c.encode(requireWordBoundary, forKey: .requireWordBoundary)
        try c.encode(isPlainText, forKey: .isPlainText)
        try c.encode(enabled, forKey: .enabled)
        // Same reasoning as `replacementText`: a snippet that is both a secret and an image is
        // an ambiguous state every consumer would resolve differently — the copy path reads the
        // keychain, `isImageSnippet` says to paste a file. Make it unrepresentable on disk.
        try c.encode(isSecret ? "" : imagePath, forKey: .imagePath)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(usageCount, forKey: .usageCount)
        try c.encode(tags, forKey: .tags)
        try c.encode(includeApps, forKey: .includeApps)
        try c.encode(excludeApps, forKey: .excludeApps)
        try c.encode(isSecret ? "" : aiTransform, forKey: .aiTransform)
        try c.encode(isSecret, forKey: .isSecret)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        triggerKeyword = try c.decode(String.self, forKey: .triggerKeyword)
        replacementText = try c.decode(String.self, forKey: .replacementText)
        isCaseSensitive = try c.decodeIfPresent(Bool.self, forKey: .isCaseSensitive) ?? false
        requireWordBoundary = try c.decodeIfPresent(Bool.self, forKey: .requireWordBoundary) ?? true
        isPlainText = try c.decodeIfPresent(Bool.self, forKey: .isPlainText) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
        // §4.4: absent in every pre-existing library file — default, never fail.
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        includeApps = try c.decodeIfPresent([String].self, forKey: .includeApps) ?? []
        excludeApps = try c.decodeIfPresent([String].self, forKey: .excludeApps) ?? []
        aiTransform = try c.decodeIfPresent(String.self, forKey: .aiTransform) ?? ""
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        // Belt and braces against a library written by a build that did not redact, or edited by
        // hand: a snippet that says it is secret never carries a value in memory either.
        if isSecret {
            replacementText = ""
            imagePath = ""
            aiTransform = ""
        }
    }
}

public struct SnippetMatch: Equatable {
    public enum Source: Equatable {
        case composed
        case physical
    }

    public let snippet: SnippetModel
    /// Trigger keyword character count (without terminator).
    public let triggerLength: Int
    /// Terminator character(s) when bare-word match required one; empty for punct-instant.
    public let terminator: String
    public let source: Source
    /// Screen units to erase. Composed: UTF-16 of trigger (± terminator rules applied by caller).
    /// Physical Hangul: visible grapheme count from LayoutAwareMatcher.
    public let eraseCount: Int
    /// Trigger text as it stands in the target field, when the match path can reconstruct it.
    /// `nil` for physical-Hangul matches. Used by the injection pipeline to verify — before
    /// deleting anything — that the field really holds the trigger.
    public let fieldText: String?

    public init(
        snippet: SnippetModel,
        triggerLength: Int,
        terminator: String = "",
        source: Source = .composed,
        eraseCount: Int? = nil,
        fieldText: String? = nil
    ) {
        self.snippet = snippet
        self.triggerLength = triggerLength
        self.terminator = terminator
        self.source = source
        self.eraseCount = eraseCount ?? triggerLength
        self.fieldText = fieldText
    }
}

// MARK: - SnippetGroup

public struct SnippetGroup: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// SF Symbol used in the sidebar (default "folder.fill").
    public var symbol: String
    /// Hex color tag (e.g. "#F24A3D"). Empty = default accent.
    public var colorHex: String
    /// Bundle IDs every snippet in this group is limited to. Empty = no group-level limit.
    ///
    /// Composes with each snippet's own `includeApps` by intersection: both must allow the app.
    /// Two lists that do not overlap mean the snippet can never fire anywhere, and
    /// `SnippetStore.expandableSnippets` reports that by disabling it rather than by producing
    /// an empty list — an empty `includeApps` means "everywhere", so collapsing to one would
    /// invert the rule.
    public var includeApps: [String]
    /// Bundle IDs every snippet in this group is suppressed in. Unions with each snippet's own
    /// `excludeApps`; blocking is subtractive, so a union needs no tie-break.
    public var excludeApps: [String]
    public var snippets: [SnippetModel]

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        symbol: String = "folder.fill",
        colorHex: String = "",
        includeApps: [String] = [],
        excludeApps: [String] = [],
        snippets: [SnippetModel] = []
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.symbol = symbol
        self.colorHex = colorHex
        self.includeApps = includeApps
        self.excludeApps = excludeApps
        self.snippets = snippets
    }

    /// §4.4 at group level — same rule as `SnippetModel.appliesTo(bundleID:)`, so the two
    /// compose predictably and neither has to explain the other's behaviour.
    public func appliesTo(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return includeApps.isEmpty }
        if excludeApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return false
        }
        if includeApps.isEmpty { return true }
        return includeApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, symbol, colorHex, includeApps, excludeApps, snippets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "folder.fill"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
        includeApps = try c.decodeIfPresent([String].self, forKey: .includeApps) ?? []
        excludeApps = try c.decodeIfPresent([String].self, forKey: .excludeApps) ?? []
        snippets = try c.decodeIfPresent([SnippetModel].self, forKey: .snippets) ?? []
    }
}
