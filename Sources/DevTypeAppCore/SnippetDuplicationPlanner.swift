import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Canonical construction for both single-item and bulk duplication.
///
/// A duplicate preserves authored behavior and metadata, while identity metadata starts fresh.
/// Triggers are reserved as copies are planned so two items duplicated in the same batch cannot
/// collide with one another. Secret values deliberately cannot cross the UUID/keychain boundary:
/// a secret becomes a disabled plain draft for the user to fill explicitly.
struct SnippetDuplicationPlanner {
    struct Target: Equatable {
        let groupIndex: Int
        let snippet: SnippetModel
    }

    private var occupiedTriggers: Set<String>

    init(existing: [SnippetModel]) {
        occupiedTriggers = Set(existing.map { $0.triggerKeyword.lowercased() })
    }

    /// Resolves the rendered selection against the latest library without guessing across a
    /// malformed duplicate UUID. Group UUIDs are intentionally irrelevant: an array index is the
    /// only unambiguous destination when two imported groups carry the same identity.
    static func validatedTargets(
        for selected: [SnippetModel],
        in groups: [SnippetGroup]
    ) -> [Target]? {
        guard !selected.isEmpty,
              Set(selected.map(\.id)).count == selected.count else { return nil }

        var targets: [Target] = []
        targets.reserveCapacity(selected.count)
        for expected in selected {
            let matches = groups.enumerated().flatMap { groupIndex, group in
                group.snippets
                    .filter { $0.id == expected.id }
                    .map { Target(groupIndex: groupIndex, snippet: $0) }
            }
            guard matches.count == 1, matches[0].snippet == expected else { return nil }
            targets.append(matches[0])
        }
        return targets
    }

    mutating func duplicate(
        _ source: SnippetModel,
        id: UUID = UUID(),
        timestamp: Date = Date(),
        duplicateImage: (String) throws -> String
    ) throws -> SnippetModel {
        let trigger = nextTrigger(basedOn: source.triggerKeyword)
        let isSecretDraft = source.isSecret
        let imagePath: String
        if source.isImageSnippet {
            imagePath = try duplicateImage(source.imagePath)
            guard !imagePath.isEmpty else {
                throw ImageAttachmentStore.StoreError.saveFailed(source.imagePath)
            }
        } else {
            imagePath = ""
        }

        occupiedTriggers.insert(trigger.lowercased())
        return SnippetModel(
            id: id,
            title: source.title,
            label: source.label,
            triggerKeyword: trigger,
            replacementText: isSecretDraft ? "" : source.replacementText,
            isCaseSensitive: source.isCaseSensitive,
            propagateCase: source.propagateCase,
            requireWordBoundary: source.requireWordBoundary,
            isPlainText: source.isPlainText,
            enabled: isSecretDraft ? false : source.enabled,
            imagePath: imagePath,
            createdAt: timestamp,
            updatedAt: timestamp,
            usageCount: 0,
            tags: source.tags,
            includeApps: source.includeApps,
            excludeApps: source.excludeApps,
            aiTransform: isSecretDraft ? "" : source.aiTransform,
            isSecret: false
        )
    }

    private func nextTrigger(basedOn base: String) -> String {
        let limit = AbbreviationMatcher.matchableTriggerLimit
        let stem = base.isEmpty ? "copy" : base
        var attempt = 1
        var candidate = boundedCandidate(stem: stem, sourceWasEmpty: base.isEmpty, attempt: attempt, limit: limit)
        while occupiedTriggers.contains(candidate.lowercased()) {
            attempt += 1
            candidate = boundedCandidate(stem: stem, sourceWasEmpty: base.isEmpty, attempt: attempt, limit: limit)
        }
        return candidate
    }

    private func boundedCandidate(stem: String, sourceWasEmpty: Bool, attempt: Int, limit: Int) -> String {
        let suffix: String
        if sourceWasEmpty {
            suffix = attempt == 1 ? "" : String(attempt)
        } else {
            suffix = attempt == 1 ? "-copy" : "-copy\(attempt)"
        }
        return String(stem.prefix(max(0, limit - suffix.count))) + suffix
    }
}
