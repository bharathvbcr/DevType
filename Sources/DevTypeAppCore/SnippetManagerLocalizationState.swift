import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Transient, user-authored manager state carried across a runtime language rebuild. None of it is
/// library data: the replacement controller reloads the canonical store, then restores navigation,
/// filtering, selection, density, sort, and scroll positions around that current library.
struct SnippetManagerLocalizationState: Equatable {
    let selectedGroupID: UUID?
    let selectedSnippetIDs: Set<UUID>
    let filterText: String
    let filter: SnippetListFilter
    let isCompactDensity: Bool
    let sortMode: SnippetSortMode
    let groupScrollOrigin: NSPoint
    let snippetScrollOrigin: NSPoint
}
