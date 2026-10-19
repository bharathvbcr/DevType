import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// The narrowings the snippet list can actually be in.
///
/// There is deliberately no `secrets` member. A secret filter was unreachable — both chip entry
/// points route `.secrets` to the Secrets manager — and a branch that cannot run is a branch that
/// cannot be tested or trusted. Removing the case makes the state unrepresentable instead of
/// guarded, so the filter switch stays exhaustive without pretending to handle it.
enum SnippetListFilter: Equatable, CaseIterable {
    case all
    case enabled
    case disabled
    case images
    case macros
    case conflicts
    case unused
    case tagged

    /// Every filter is rendered by exactly one chip: titles and highlighting come from here.
    var chip: SnippetFilterChip {
        switch self {
        case .all: return .all
        case .enabled: return .enabled
        case .disabled: return .disabled
        case .images: return .images
        case .macros: return .macros
        case .conflicts: return .conflicts
        case .unused: return .unused
        case .tagged: return .tagged
        }
    }

    var localizationKey: String { chip.localizationKey }
}
