import Foundation
import ExpanderEngine

/// One immutable projection of the library for the conflict resolver.
///
/// Detection, row contents, group labels, winner markings, and counts are all derived from the
/// same `groups` value. Keeping this separate from AppKit prevents the sheet from combining a
/// conflict scan from one disk read with snippet details from another.
struct ConflictResolverSnapshot: Equatable {
    enum EmptyState: Equatable {
        case detectionDisabled
        case noConflicts
    }

    struct Item: Equatable {
        let snippet: SnippetModel
        let groupID: UUID
        let groupName: String
        let target: SnippetStore.TriggerConflictTarget
        let isWinner: Bool
    }

    struct Row: Equatable {
        let conflict: SnippetStore.TriggerConflict
        let items: [Item]

        var affectedSnippetCount: Int { items.count }
    }

    let detectionEnabled: Bool
    let rows: [Row]

    init(groups: [SnippetGroup], detectionEnabled: Bool) {
        self.detectionEnabled = detectionEnabled
        guard detectionEnabled else {
            rows = []
            return
        }

        struct LocatedSnippet {
            let snippet: SnippetModel
            let groupID: UUID
            let groupName: String
            let occurrence: Int
        }

        // Store occurrences rather than a single dictionary value. UUIDs are the canonical
        // identity, but a malformed imported document may duplicate one; the UI must still show
        // the complete detector output instead of silently collapsing a row.
        var locations: [UUID: [LocatedSnippet]] = [:]
        for group in groups {
            var occurrenceByID: [UUID: Int] = [:]
            for snippet in group.snippets {
                let occurrence = occurrenceByID[snippet.id, default: 0]
                occurrenceByID[snippet.id] = occurrence + 1
                locations[snippet.id, default: []].append(
                    LocatedSnippet(
                        snippet: snippet,
                        groupID: group.id,
                        groupName: group.name,
                        occurrence: occurrence
                    )
                )
            }
        }

        rows = SnippetStore.triggerConflicts(in: groups).map { conflict in
            var occurrenceByID: [UUID: Int] = [:]
            let items = conflict.snippetIDs.enumerated().compactMap { position, id -> Item? in
                let occurrence = occurrenceByID[id, default: 0]
                occurrenceByID[id] = occurrence + 1
                guard let candidates = locations[id], candidates.indices.contains(occurrence) else {
                    return nil
                }
                let located = candidates[occurrence]
                return Item(
                    snippet: located.snippet,
                    groupID: located.groupID,
                    groupName: located.groupName,
                    target: SnippetStore.TriggerConflictTarget(
                        groupID: located.groupID,
                        snippet: located.snippet,
                        occurrence: located.occurrence
                    ),
                    isWinner: Self.isWinner(
                        snippet: located.snippet,
                        position: position,
                        conflict: conflict
                    )
                )
            }
            return Row(conflict: conflict, items: items)
        }
    }

    var conflictCount: Int { rows.count }

    /// Counts unique library entries, not row appearances. A snippet can participate in both a
    /// duplicate and case-shadow row, and must not inflate the sheet summary.
    var affectedSnippetCount: Int {
        Set(rows.flatMap { row in
            row.items.map {
                "\($0.target.groupID.uuidString):\($0.target.snippetID.uuidString):\($0.target.occurrence)"
            }
        }).count
    }

    var emptyState: EmptyState? {
        guard rows.isEmpty else { return nil }
        return detectionEnabled ? .noConflicts : .detectionDisabled
    }

    private static func isWinner(
        snippet: SnippetModel,
        position: Int,
        conflict: SnippetStore.TriggerConflict
    ) -> Bool {
        switch conflict.kind {
        case .emptyTrigger:
            return false
        case .duplicateTrigger, .prefixShadow:
            return position == 0
        case .caseShadow:
            // The matcher checks its exact/case-sensitive table before the folded table. Every
            // sensitive spelling therefore wins at its exact spelling; the insensitive entry
            // still handles other casing and is the partially shadowed participant.
            return snippet.isCaseSensitive
        }
    }
}

/// Explicit row geometry shared by the table delegate and row contents. Every additional snippet
/// adds one full summary height plus spacing; the enclosing table scroll view handles large rows.
enum ConflictResolverLayout {
    static let emptyRowHeight: CGFloat = 96
    static let snippetRowHeight: CGFloat = 86
    static let snippetSpacing: CGFloat = 8
    static let headerRowHeight: CGFloat = 24
    /// Card exterior (8) + content top/bottom (18) + header-to-list gap (8) + header (24).
    private static let rowChromeHeight: CGFloat = 58

    static func rowHeight(snippetCount: Int) -> CGFloat {
        guard snippetCount > 0 else { return emptyRowHeight }
        return rowChromeHeight
            + CGFloat(snippetCount) * snippetRowHeight
            + CGFloat(max(0, snippetCount - 1)) * snippetSpacing
    }
}
