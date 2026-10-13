import AppKit
import ExpanderEngine

// MARK: - §4.1 — a real Preferences window
//
// Configuration used to be scattered across `AppDelegate.buildMenu()`: Open at
// Login (:332), Language (:338-349), Mute Frontmost (:361), Muted Apps (:362) —
// and ⌘, was bound to "Manage Snippets" (:313) rather than settings. This window
// collects them, plus the two features that had *no* UI at all:
//
//   • §4.2 the inline-search shortcut (was hardcoded ⌘/ with no picker)
//   • §4.3 hotkey macros (were readable only by hand-editing UserDefaults)
//
// and the two that were alert-shaped:
//
//   • §4.8 the muted-app list (was one alert button per app, decoded by index
//     arithmetic — broken past ~3 apps)
//   • §4.5 statistics (were collected and never shown)

/// Sections, in sidebar order.
enum PreferencesTab: Int, CaseIterable {
    case home
    case general
    case snippets
    case hotkeys
    case voice
    case ai
    case advanced

    var title: String {
        switch self {
        case .home: return LocalizationManager.shared.s("prefs.tab.home")
        case .general: return LocalizationManager.shared.s("prefs.tab.general")
        case .snippets: return LocalizationManager.shared.s("prefs.tab.snippets")
        case .hotkeys: return LocalizationManager.shared.s("prefs.tab.hotkeys")
        case .voice: return LocalizationManager.shared.s("prefs.tab.voice")
        case .ai: return LocalizationManager.shared.s("prefs.tab.ai")
        case .advanced: return LocalizationManager.shared.s("prefs.tab.advanced")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .general: return "gearshape"
        case .snippets: return "square.stack.3d.up"
        case .hotkeys: return "keyboard"
        case .voice: return "waveform.and.mic"
        case .ai: return "sparkles"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var subtitle: String {
        switch self {
        case .home: return LocalizationManager.shared.s("prefs.tab.home.subtitle")
        case .general: return LocalizationManager.shared.s("prefs.tab.general.subtitle")
        case .snippets: return LocalizationManager.shared.s("prefs.tab.snippets.subtitle")
        case .hotkeys: return LocalizationManager.shared.s("prefs.tab.hotkeys.subtitle")
        case .voice: return LocalizationManager.shared.s("prefs.tab.voice.subtitle")
        case .ai: return LocalizationManager.shared.s("prefs.tab.ai.subtitle")
        case .advanced: return LocalizationManager.shared.s("prefs.tab.advanced.subtitle")
        }
    }

    /// AI requires macOS 26+; hide the tab on older systems.
    static var visibleCases: [PreferencesTab] {
        if #available(macOS 26.0, *) {
            return Array(allCases)
        }
        return allCases.filter { $0 != .ai }
    }
}

// MARK: - Window controller

/// Transient UI state carried across a language-driven controller rebuild.
///
/// Preferences writes switches and popups immediately, but editor rows intentionally keep text
/// unsaved until their Add/Save action is used. Rebuilding without these values silently discarded
/// a partially entered macro, dictionary item, trigger, provider endpoint, or credential.
struct PreferencesLocalizationState: Equatable {
    let selectedTab: PreferencesTab
    let macroArgument: String
    let aiAllowlistBundleID: String
    let voiceDictionarySpoken: String
    let voiceDictionaryReplacement: String
    let voiceTriggerPhrase: String
    let geminiAPIKey: String
    let localLLMEndpoint: String
    let localLLMModel: String
    let scrollOrigins: [PreferencesTab: NSPoint]
}

/// One policy owns whether a language change can replace the current Preferences controller.
/// Sheets own unsaved modal state, while the current controller owns its live async operations.
enum PreferencesLocalizationRefreshDecision: Equatable {
    case upToDate
    case deferRefresh
    case rebuild

    static func resolve(
        needsRefresh: Bool,
        hasAttachedSheet: Bool,
        hasBlockingOperation: Bool
    ) -> Self {
        guard needsRefresh else { return .upToDate }
        return hasAttachedSheet || hasBlockingOperation ? .deferRefresh : .rebuild
    }
}

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private var preferences: PreferencesViewController?
    private weak var hotkeyManager: HotkeyManager?
    private var renderedLanguage: AppLanguage?
    private var localizationRefreshDeferred = false
    private var sheetEndObserver: NSObjectProtocol?

    /// Internal rather than private so tests can open a window of their own instead of sharing the
    /// singleton's state; production code goes through `shared`.
    init() {
        super.init(window: nil)
        sheetEndObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.retryDeferredLocalizationRefresh()
        }
    }

    deinit {
        if let sheetEndObserver {
            NotificationCenter.default.removeObserver(sheetEndObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Opens (or raises) Preferences, optionally jumping to a section.
    ///
    /// `hotkeyManager` is refreshed on *every* call, not only when the window is
    /// first created: the controller outlives individual callers, and pinning the
    /// manager from first show left a window opened via a nil-manager path acting
    /// on nil forever — macro edits then went to defaults instead of the live
    /// registration. Nil-safe: callers without a manager keep today's behaviour.
    func show(tab: PreferencesTab? = nil, hotkeyManager: HotkeyManager?) {
        self.hotkeyManager = hotkeyManager
        if window == nil {
            let controller = makePreferencesController()
            preferences = controller
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 800, height: 680))
            newWindow.minSize = NSSize(width: 720, height: 560)
            DevTypeTheme.styleWindow(newWindow, title: LocalizationManager.shared.s("window.preferences"))
            newWindow.dtRestoreFrame(named: "DevTypePreferencesWindow")
            newWindow.isReleasedWhenClosed = false
            self.window = newWindow
            renderedLanguage = LocalizationManager.shared.language
        } else if renderedLanguage != LocalizationManager.shared.language {
            // `reloadAll()` below is this open's one full pass.
            performLocalizationRefresh(reloadingReplacement: false)
        }
        preferences?.refreshHotkeyManager(hotkeyManager)
        if let tab { preferences?.select(tab) }
        // The single full reload per open. `viewDidLoad`/`viewWillAppear` deliberately do not
        // reload: they ran in addition to this call and tripled the work of opening the window.
        preferences?.reloadAll()
        showWindow(nil)
        WindowOrdering.makeKeyAndOrderFront(window, context: "Preferences")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-read the secrets preference into its switch.
    ///
    /// The same setting is reachable from the Copy Secret menu, and a window showing the opposite
    /// of what is in force is worse than no window — the user would toggle it back and change
    /// nothing, twice.
    func refreshSecretsCard() {
        preferences?.refreshSecretsCard()
    }

    /// Refreshes live TCC and provider readiness after DevType returns from System Settings.
    func refreshPermissionState() {
        preferences?.refreshPermissionState()
    }

    /// Refreshes the maintenance debt after an asynchronous Keychain cleanup pass completes.
    func refreshMaintenanceState() {
        preferences?.refreshMaintenanceState()
    }

    /// Rebuilds the long-lived Preferences controller after the string table changes. AppKit
    /// labels are values, not bindings, so reloading settings alone cannot translate an already
    /// visible window. The rebuild is deferred out of the language popup's action and carries all
    /// transient editor text and scroll positions forward.
    func refreshLocalization() {
        DispatchQueue.main.async { [weak self] in
            self?.performLocalizationRefresh()
        }
    }

    private func performLocalizationRefresh(reloadingReplacement: Bool = true) {
        guard let window else { return }
        DevTypeTheme.styleWindow(window, title: LocalizationManager.shared.s("window.preferences"))
        guard let current = preferences else { return }

        switch PreferencesLocalizationRefreshDecision.resolve(
            needsRefresh: renderedLanguage != LocalizationManager.shared.language,
            hasAttachedSheet: window.attachedSheet != nil,
            hasBlockingOperation: current.blocksLocalizationReplacement
        ) {
        case .upToDate:
            localizationRefreshDeferred = false
            return
        case .deferRefresh:
            localizationRefreshDeferred = true
            return
        case .rebuild:
            localizationRefreshDeferred = false
        }

        let state = current.localizationState()
        current.prepareForLocalizationReplacement()
        let replacement = makePreferencesController(restorationState: state)
        preferences = replacement
        window.contentViewController = replacement
        if reloadingReplacement { replacement.reloadAll() }
        renderedLanguage = LocalizationManager.shared.language
    }

    private func makePreferencesController(
        restorationState: PreferencesLocalizationState? = nil
    ) -> PreferencesViewController {
        PreferencesViewController(
            hotkeyManager: hotkeyManager,
            restorationState: restorationState,
            onLocalizationBlockingOperationDidEnd: { [weak self] in
                self?.retryDeferredLocalizationRefresh()
            }
        )
    }

    private func retryDeferredLocalizationRefresh() {
        guard localizationRefreshDeferred else { return }
        // Sheet-end notifications and async completions can arrive while AppKit is still unwinding
        // their callbacks. Rebuild on the next main-loop turn, after ownership has been released.
        DispatchQueue.main.async { [weak self] in
            guard self?.localizationRefreshDeferred == true else { return }
            self?.performLocalizationRefresh()
        }
    }
}
