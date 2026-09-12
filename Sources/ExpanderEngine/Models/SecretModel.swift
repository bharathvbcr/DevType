import Foundation

/// Metadata only. A secret has no trigger, replacement body, image, or AI action.
/// Values remain in SecretStore under the same UUID across library migrations.
public struct SecretModel: Codable, Identifiable, Hashable {
    public let id: UUID
    public var title: String
    public var label: String
    public var enabled: Bool
    public var tags: [String]
    public var includeApps: [String]
    public var excludeApps: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var usageCount: Int

    public init(id: UUID = UUID(), title: String, label: String = "", enabled: Bool = true,
                tags: [String] = [], includeApps: [String] = [], excludeApps: [String] = [],
                createdAt: Date = Date(), updatedAt: Date = Date(), usageCount: Int = 0) {
        self.id = id
        self.title = title
        self.label = label
        self.enabled = enabled
        self.tags = tags
        self.includeApps = includeApps
        self.excludeApps = excludeApps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usageCount = usageCount
    }

    public var displayTitle: String { label.isEmpty ? title : label }

    init(migrating snippet: SnippetModel) {
        self.init(id: snippet.id, title: snippet.title.isEmpty ? snippet.displayTitle : snippet.title,
                  label: snippet.label, enabled: snippet.enabled, tags: snippet.tags,
                  includeApps: snippet.includeApps, excludeApps: snippet.excludeApps,
                  createdAt: snippet.createdAt, updatedAt: snippet.updatedAt, usageCount: snippet.usageCount)
    }

    /// Thin compatibility adapter for the existing search, gated copy and resource transaction
    /// owners. This shape is never persisted as a snippet in schema 3.
    public var snippetAdapter: SnippetModel {
        SnippetModel(id: id, title: title, label: label, triggerKeyword: "", replacementText: "",
                     enabled: enabled, createdAt: createdAt, updatedAt: updatedAt,
                     usageCount: usageCount, tags: tags, includeApps: includeApps,
                     excludeApps: excludeApps, isSecret: true)
    }
}

extension SnippetStore {
    /// Independent collection; no caller needs a snippet group or a trigger to manage a secret.
    public func loadSecrets() -> [SecretModel] { SnippetDocument(groups: loadGroups()).secrets }

    /// The snippet manager sees only snippet groups. Whole-library transactions still use
    /// loadGroups/mutateGroups so secret edits share their digest guards, rollback and cleanup.
    public func loadSnippetGroups() -> [SnippetGroup] { SnippetDocument(groups: loadGroups()).groups }
}
