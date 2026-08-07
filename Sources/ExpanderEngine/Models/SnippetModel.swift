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

    /// True when this snippet pastes an image instead of text.
    public var isImageSnippet: Bool { !imagePath.isEmpty }

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
        aiTransform: String = ""
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
    public var snippets: [SnippetModel]

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        symbol: String = "folder.fill",
        colorHex: String = "",
        snippets: [SnippetModel] = []
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.symbol = symbol
        self.colorHex = colorHex
        self.snippets = snippets
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, symbol, colorHex, snippets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "folder.fill"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
        snippets = try c.decodeIfPresent([SnippetModel].self, forKey: .snippets) ?? []
    }
}
