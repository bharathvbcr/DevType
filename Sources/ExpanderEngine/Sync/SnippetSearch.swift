// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

public struct SearchHit: Identifiable, Equatable {
    public let snippet: SnippetModel
    public let groupID: UUID
    public let groupName: String
    public let score: Int

    public var id: UUID { snippet.id }

    public init(snippet: SnippetModel, groupID: UUID, groupName: String, score: Int) {
        self.snippet = snippet
        self.groupID = groupID
        self.groupName = groupName
        self.score = score
    }
}

public enum SnippetSearch {

    public static func run(
        query: String,
        in groups: [SnippetGroup],
        includeDisabled: Bool = true,
        limit: Int? = nil
    ) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for group in groups {
            for snippet in group.snippets {
                if !includeDisabled && !(snippet.enabled && group.enabled) { continue }
                guard let score = score(snippet: snippet, needle: needle) else { continue }
                hits.append(SearchHit(
                    snippet: snippet,
                    groupID: group.id,
                    groupName: group.name,
                    score: score
                ))
            }
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.snippet.triggerKeyword.count != b.snippet.triggerKeyword.count {
                return a.snippet.triggerKeyword.count < b.snippet.triggerKeyword.count
            }
            return a.snippet.triggerKeyword.localizedCaseInsensitiveCompare(b.snippet.triggerKeyword) == .orderedAscending
        }

        if let limit, hits.count > limit {
            return Array(hits.prefix(limit))
        }
        return hits
    }

    public static func conflictingTriggers(in groups: [SnippetGroup]) -> Set<String> {
        var seen: [String: Int] = [:]
        for group in groups where group.enabled {
            for snippet in group.snippets where snippet.enabled && !snippet.triggerKeyword.isEmpty {
                let key = snippet.isCaseSensitive
                    ? snippet.triggerKeyword
                    : snippet.triggerKeyword.lowercased()
                seen[key, default: 0] += 1
            }
        }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    private static func score(snippet: SnippetModel, needle: String) -> Int? {
        let abbreviation = snippet.triggerKeyword.lowercased()
        let label = snippet.displayTitle.lowercased()
        let content = snippet.replacementText.lowercased()
        let bareAbbreviation = strippingLeadingSigils(abbreviation)

        if abbreviation == needle || bareAbbreviation == needle { return 100 }
        if abbreviation.hasPrefix(needle) || bareAbbreviation.hasPrefix(needle) { return 90 }
        if abbreviation.contains(needle) { return 70 }
        if label.hasPrefix(needle) { return 60 }
        if label.contains(needle) { return 50 }
        if content.contains(needle) { return 30 }
        return nil
    }

    private static func strippingLeadingSigils(_ abbreviation: String) -> String {
        var rest = Substring(abbreviation)
        while let first = rest.first, !first.isLetter, !first.isNumber {
            rest = rest.dropFirst()
        }
        return String(rest)
    }
}
