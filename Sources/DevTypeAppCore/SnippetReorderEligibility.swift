import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Drag rows only when their indexes are the indexes in persistent storage.
enum SnippetReorderEligibility {
    static func isAllowed(
        sortMode: SnippetSortMode,
        hasConcreteGroup: Bool,
        filterText: String,
        filter: SnippetListFilter
    ) -> Bool {
        sortMode == .manual
            && hasConcreteGroup
            && filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && filter == .all
    }
}
