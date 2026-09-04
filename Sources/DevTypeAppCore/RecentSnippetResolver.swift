import Foundation
import ExpanderEngine

/// Keeps the Recent Expansions menu as references into the live library.
///
/// Holding whole `SnippetModel` values here is unsafe: a later edit, disable, deletion, group
/// disable, or conversion to a secret would leave the menu capable of inserting stale content.
/// IDs are inert; every presentation and click resolves them against a freshly projected library.
struct RecentSnippetResolver {
    static let maximumCount = 6

    static func record(
        _ snippet: SnippetModel,
        in ids: [UUID],
        limit: Int = maximumCount
    ) -> [UUID] {
        guard isEligible(snippet), limit > 0 else { return ids }
        return Array(([snippet.id] + ids.filter { $0 != snippet.id }).prefix(limit))
    }

    static func reconcile(
        _ ids: [UUID],
        with snippets: [SnippetModel],
        limit: Int = maximumCount
    ) -> [UUID] {
        guard limit > 0 else { return [] }
        var eligibleIDs = Set<UUID>()
        for snippet in snippets where isEligible(snippet) {
            eligibleIDs.insert(snippet.id)
        }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in ids where eligibleIDs.contains(id) && seen.insert(id).inserted {
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }

    static func resolve(_ id: UUID, in snippets: [SnippetModel]) -> SnippetModel? {
        snippets.first { $0.id == id && isEligible($0) }
    }

    private static func isEligible(_ snippet: SnippetModel) -> Bool {
        snippet.enabled && !snippet.isSecret
    }
}
