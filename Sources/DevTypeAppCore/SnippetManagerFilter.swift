import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// The manager's free-text filter predicate.
///
/// Extracted from `applyFilterAndReloadTable` so the field's behaviour can be asserted without
/// standing up a view controller — and so it stays honest about tags. `SnippetSearch` gained
/// tag matching when tags became something a user could see and edit; this field searched the
/// same library by different rules, which meant typing a tag here found nothing while typing it
/// in the palette found the snippet.
enum SnippetManagerFilter {
    /// Names the manager's secret-free view of the library. It is not the store's own
    /// `searchCacheIdentity`: the same revision there labels the unfiltered list, and the
    /// search index cache is process-wide.
    static let searchIdentity = UUID()

    /// One indexed pass over the complete groups preserves field-filter parity with the
    /// palette. The manager then intersects these IDs with its selected group and chip.
    ///
    /// `revision` (a `SnippetStore.libraryRevision` read together with `groups`) lets the search
    /// index be identified by a counter. Without it `SnippetSearch` falls back to
    /// `fingerprint(of:)`, which hashes every field of every snippet — replacement text included —
    /// on each keystroke.
    static func matchingIDs(in groups: [SnippetGroup], query: String, revision: UInt64? = nil) -> Set<UUID> {
        guard SnippetSearch.queryIssue(for: query) == nil else { return [] }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Set(groups.flatMap(\.snippets).map(\.id))
        }
        return Set(SnippetSearch.run(
            query: query, in: groups,
            revision: revision, libraryID: revision == nil ? nil : searchIdentity
        ).map(\.id))
    }
}
