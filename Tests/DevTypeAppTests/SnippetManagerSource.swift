import Foundation
import SourceTreeTestSupport

/// Everything `SnippetManagerViewController.swift` held before it was split: the view controller's
/// own family (`SnippetManagerViewController+*.swift`) plus the top-level types that moved into files
/// of their own. Source-contract tests read this rather than the family alone, so a "must not
/// contain" check still covers the filter, sort, preview and mutation types it covered before.
enum SnippetManagerSource {
    static let movedTypes = [
        "SnippetSortMode", "SnippetOneLinePreview", "SnippetManagerFilter", "SnippetFilterChip",
        "SnippetListFilter", "SnippetDuplicationPlanner", "SnippetManagerMutationCommitter",
        "SnippetReorderEligibility", "SnippetManagerLocalizationState", "SnippetManagerUndoTarget",
    ].map { "Sources/DevTypeAppCore/\($0).swift" }

    static func read() throws -> String {
        try SourceTree.text(
            "Sources/DevTypeAppCore/SnippetManagerViewController.swift", including: movedTypes)
    }
}
