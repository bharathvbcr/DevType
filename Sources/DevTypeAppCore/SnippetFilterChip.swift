import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// The chips rendered in the manager's filter row.
///
/// `.secrets` is a **navigation** chip, not a filter: secrets are an independent collection and
/// `loadSnippetGroups()` never yields one, so narrowing this list by `isSecret` could only ever
/// produce an empty table. Tapping it opens the Secrets manager instead. `listFilter` is the one
/// place that distinction is written down, and it is what keeps the impossible state out of
/// `SnippetListFilter`.
enum SnippetFilterChip: Int, CaseIterable {
    case all = 0
    case enabled = 1
    case disabled = 2
    case secrets = 3
    case images = 4
    case macros = 5
    case conflicts = 6
    case unused = 7
    case tagged = 8

    var localizationKey: String {
        switch self {
        case .all: return "manager.filter.all"
        case .enabled: return "manager.filter.enabled"
        case .disabled: return "manager.filter.disabled"
        case .secrets: return "manager.filter.secrets"
        case .images: return "manager.filter.images"
        case .macros: return "manager.filter.macros"
        case .conflicts: return "manager.filter.conflicts"
        case .unused: return "manager.filter.unused"
        case .tagged: return "manager.filter.tagged"
        }
    }

    /// The narrowing this chip applies, or `nil` when the chip navigates somewhere else.
    var listFilter: SnippetListFilter? {
        switch self {
        case .all: return .all
        case .enabled: return .enabled
        case .disabled: return .disabled
        case .secrets: return nil
        case .images: return .images
        case .macros: return .macros
        case .conflicts: return .conflicts
        case .unused: return .unused
        case .tagged: return .tagged
        }
    }
}
