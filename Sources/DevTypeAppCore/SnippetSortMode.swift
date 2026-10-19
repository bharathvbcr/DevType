import AppKit
import Carbon.HIToolbox
import ExpanderEngine

// MARK: - §4.6 — sorting
//
// There was no `sortDescriptor` or `sorted(by` anywhere in `Sources/DevTypeApp/`:
// the list was always in raw storage order with no way to find the snippet you
// use most. `manual` preserves storage order and is the only mode in which
// drag-to-reorder makes sense.
enum SnippetSortMode: Int, CaseIterable {
    case manual
    case title
    case trigger
    case usage
    case recentlyUsed
    case recentlyEdited

    var title: String {
        switch self {
        case .manual: return LocalizationManager.shared.s("manager.sort.manual")
        case .title: return LocalizationManager.shared.s("manager.sort.title")
        case .trigger: return LocalizationManager.shared.s("manager.sort.trigger")
        case .usage: return LocalizationManager.shared.s("manager.sort.usage")
        case .recentlyUsed: return LocalizationManager.shared.s("manager.sort.recent")
        case .recentlyEdited: return LocalizationManager.shared.s("manager.sort.updated")
        }
    }

    /// The equivalent `NSSortDescriptor`, published on the table so anything that
    /// inspects `tableView.sortDescriptors` sees the truth.
    var sortDescriptor: NSSortDescriptor? {
        switch self {
        case .manual: return nil
        case .title: return NSSortDescriptor(key: "title", ascending: true)
        case .trigger: return NSSortDescriptor(key: "triggerKeyword", ascending: true)
        case .usage: return NSSortDescriptor(key: "usageCount", ascending: false)
        case .recentlyUsed: return NSSortDescriptor(key: "lastUsedAt", ascending: false)
        case .recentlyEdited: return NSSortDescriptor(key: "updatedAt", ascending: false)
        }
    }

    static let defaultsKey = "devtype.manager.sortMode"
}

