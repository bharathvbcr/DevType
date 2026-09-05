import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

/// Typed presentation keeps a temporarily unreadable Keychain distinct from an absent API key.
/// Neither state carries the credential value into UI state.
enum GeminiCredentialDisplayState: Equatable {
    enum TintRole: Equatable { case success, warning, failure }

    case configured
    case missing
    case unavailable

    static func resolve(_ state: GeminiAPIKeyStore.ReadState) -> Self {
        switch state {
        case .available(let key):
            return key.isEmpty ? .missing : .configured
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        }
    }

    var statusKey: String {
        switch self {
        case .configured: return "prefs.voice.gemini.keyConfigured"
        case .missing: return "prefs.voice.gemini.noKey"
        case .unavailable: return "prefs.voice.keychain.unavailable.pill"
        }
    }

    var placeholderKey: String {
        switch self {
        case .configured: return "prefs.voice.gemini.placeholder.saved"
        case .missing: return "prefs.voice.gemini.placeholder.paste"
        case .unavailable: return "prefs.voice.gemini.placeholder.unavailable"
        }
    }

    var tintRole: TintRole {
        switch self {
        case .configured: return .success
        case .missing: return .warning
        case .unavailable: return .failure
        }
    }

    var tint: NSColor {
        switch tintRole {
        case .success: return DevTypeTheme.statusGreen
        case .warning: return DevTypeTheme.statusOrange
        case .failure: return DevTypeTheme.accentBright
        }
    }
}

/// Provider responses can include English or endpoint-specific detail. Preferences presents a
/// bounded localized verdict instead of passing that transport text into the UI.
enum GeminiValidationDisplayState: CaseIterable, Equatable {
    case valid
    case invalid
    case rateLimited
    case quotaExhausted
    case networkError

    static func resolve(_ result: APIKeyValidationResult) -> Self {
        switch result {
        case .valid: return .valid
        case .invalidKey: return .invalid
        case .rateLimited: return .rateLimited
        case .quotaExhausted: return .quotaExhausted
        case .networkError: return .networkError
        }
    }

    var localizationKey: String {
        switch self {
        case .valid: return "prefs.voice.gemini.validation.valid"
        case .invalid: return "prefs.voice.gemini.validation.invalid"
        case .rateLimited: return "prefs.voice.gemini.validation.rateLimited"
        case .quotaExhausted: return "prefs.voice.gemini.validation.quotaExhausted"
        case .networkError: return "prefs.voice.gemini.validation.networkError"
        }
    }
}

/// Preferences may render Apple-backed speech as ready only after the same capability probe used
/// by the runtime confirms that the current recognizer can stay on device. Authorization alone is
/// insufficient: some locales require Apple's network service even when TCC is granted.
enum AppleSpeechReadinessDisplayState: Equatable {
    enum TintRole: Equatable { case checking, ready, attention }

    case checking
    case ready
    case needsPermission
    case denied
    case restricted
    case onDeviceUnavailable

    static func resolve(
        authorization: SpeechAuthorization.Status,
        providerReadiness: ProviderReadiness?
    ) -> AppleSpeechReadinessDisplayState {
        switch authorization {
        case .notDetermined: return .needsPermission
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: break
        }

        guard let providerReadiness else { return .checking }
        switch providerReadiness {
        case .ready: return .ready
        case .requiresPermission: return .needsPermission
        case .downloading, .requiresConfiguration, .temporarilyUnavailable,
             .incompatible, .corrupt, .unsupported:
            return .onDeviceUnavailable
        }
    }

    var statusKey: String {
        switch self {
        case .checking: return "status.checking"
        case .ready: return "prefs.voice.speechModels.status.ready"
        case .needsPermission: return "prefs.voice.speechModels.status.needsSpeech"
        case .denied: return "prefs.voice.speechModels.status.speechDenied"
        case .restricted: return "prefs.voice.speechModels.status.speechRestricted"
        case .onDeviceUnavailable:
            return "prefs.voice.speechModels.status.onDeviceUnavailable"
        }
    }

    var tintRole: TintRole {
        switch self {
        case .checking: return .checking
        case .ready: return .ready
        case .needsPermission, .denied, .restricted, .onDeviceUnavailable: return .attention
        }
    }
}

/// Local AI is a two-stage engine: Apple speech recognition plus the first ready model-backed
/// correction provider in the snapshot's ordered chain. A deterministic-only floor remains usable,
/// but is shown distinctly so Preferences never calls basic rules "Local AI ready".
enum LocalAIReadinessDisplayState: Equatable {
    case checking
    case ready
    case basicCleanup
    case needsPermission
    case denied
    case restricted
    case onDeviceUnavailable

    static func resolve(
        authorization: SpeechAuthorization.Status,
        speechReadiness: ProviderReadiness?,
        selectedCorrectionProviderID: String?
    ) -> LocalAIReadinessDisplayState {
        switch AppleSpeechReadinessDisplayState.resolve(
            authorization: authorization,
            providerReadiness: speechReadiness
        ) {
        case .checking: return .checking
        case .needsPermission: return .needsPermission
        case .denied: return .denied
        case .restricted: return .restricted
        case .onDeviceUnavailable: return .onDeviceUnavailable
        case .ready: break
        }

        guard let selectedCorrectionProviderID else { return .checking }
        return selectedCorrectionProviderID == VoiceSessionSnapshotFactory.ProviderID.deterministicCorrector
            ? .basicCleanup
            : .ready
    }

    var statusKey: String {
        switch self {
        case .checking: return "status.checking"
        case .ready: return "prefs.voice.speechModels.status.ready"
        case .basicCleanup: return "prefs.voice.speechModels.status.basicCleanup"
        case .needsPermission: return "prefs.voice.speechModels.status.needsSpeech"
        case .denied: return "prefs.voice.speechModels.status.speechDenied"
        case .restricted: return "prefs.voice.speechModels.status.speechRestricted"
        case .onDeviceUnavailable: return "prefs.voice.speechModels.status.onDeviceUnavailable"
        }
    }

    var tintRole: AppleSpeechReadinessDisplayState.TintRole {
        switch self {
        case .checking: return .checking
        case .ready: return .ready
        case .basicCleanup, .needsPermission, .denied, .restricted, .onDeviceUnavailable:
            return .attention
        }
    }
}

/// A cancelled probe can still return from Speech.framework. Only the latest generation may
/// update the long-lived Preferences labels, and each completion is consumed once.
struct AppleSpeechReadinessRefreshLifecycle {
    typealias Generation = UInt64

    private var nextGeneration: Generation = 0
    private var activeGeneration: Generation?

    mutating func begin() -> Generation {
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        activeGeneration = nextGeneration
        return nextGeneration
    }

    mutating func claim(_ generation: Generation) -> Bool {
        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        return true
    }

    mutating func invalidate() {
        activeGeneration = nil
    }
}

/// Single-flight ownership for the user-initiated SpeechAnalyzer asset installation. Asset
/// installation is intentionally separate from readiness probing: merely opening Preferences may
/// observe system state, but only this explicit action is allowed to request a download.
struct AppleSpeechAssetInstallLifecycle {
    enum CancellationDisposition: Equatable {
        /// The request was invalidated or superseded, so another path already retired its UI.
        case ignore
        /// The owning task was cancelled while this request was current. Release without an alert.
        case retireSilently
        /// A dependency threw CancellationError while the owning task remained active.
        case reportFailure
    }

    struct Request: Equatable {
        fileprivate let generation: UInt64
    }

    private var nextGeneration: UInt64 = 0
    private var activeRequest: Request?

    var isActive: Bool { activeRequest != nil }

    mutating func begin() -> Request? {
        guard activeRequest == nil else { return nil }
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        let request = Request(generation: nextGeneration)
        activeRequest = request
        return request
    }

    mutating func claimCompletion(_ request: Request) -> Bool {
        guard activeRequest == request else { return false }
        activeRequest = nil
        return true
    }

    mutating func claimCancellation(
        _ request: Request,
        taskIsCancelled: Bool
    ) -> CancellationDisposition {
        guard activeRequest == request else { return .ignore }
        activeRequest = nil
        return taskIsCancelled ? .retireSilently : .reportFailure
    }

    mutating func invalidate() {
        activeRequest = nil
    }
}

struct AppleSpeechAssetControlsPresentation: Equatable {
    let titleKey: String
    let isHidden: Bool
    let isEnabled: Bool

    static func resolve(
        platformSupportsAnalyzer: Bool,
        analyzerReadiness: ProviderReadiness?,
        isInstalling: Bool
    ) -> AppleSpeechAssetControlsPresentation {
        guard platformSupportsAnalyzer else {
            return AppleSpeechAssetControlsPresentation(
                titleKey: "prefs.voice.appleAssets.unavailable",
                isHidden: true,
                isEnabled: false
            )
        }
        if isInstalling {
            return AppleSpeechAssetControlsPresentation(
                titleKey: "prefs.voice.appleAssets.installing",
                isHidden: false,
                isEnabled: false
            )
        }
        guard let analyzerReadiness else {
            return AppleSpeechAssetControlsPresentation(
                titleKey: "status.checking",
                isHidden: false,
                isEnabled: false
            )
        }
        switch analyzerReadiness {
        case .ready:
            return AppleSpeechAssetControlsPresentation(
                titleKey: "prefs.voice.appleAssets.installed",
                isHidden: false,
                isEnabled: false
            )
        case .requiresConfiguration(.missingModelDownload):
            return AppleSpeechAssetControlsPresentation(
                titleKey: "prefs.voice.appleAssets.install",
                isHidden: false,
                isEnabled: true
            )
        case .downloading:
            return AppleSpeechAssetControlsPresentation(
                titleKey: "prefs.voice.appleAssets.installing",
                isHidden: false,
                isEnabled: false
            )
        case .requiresPermission, .temporarilyUnavailable, .incompatible, .corrupt,
             .unsupported, .requiresConfiguration:
            return AppleSpeechAssetControlsPresentation(
                titleKey: "prefs.voice.appleAssets.unavailable",
                isHidden: false,
                isEnabled: false
            )
        }
    }
}

/// Mirrors production provider resolution while preserving the analyzer's independent setup state.
/// The engine status reports the provider that can actually run; the asset control may still offer
/// an analyzer download when the independently-ready legacy recognizer is the current fallback.
struct AppleSpeechPreferencesResolution: Equatable {
    let readiness: ProviderReadiness
    let providerID: String?

    static func resolve(
        platformSupportsAnalyzer: Bool,
        analyzerReadiness: ProviderReadiness,
        legacyReadiness: ProviderReadiness
    ) -> AppleSpeechPreferencesResolution {
        if platformSupportsAnalyzer, analyzerReadiness.isReady {
            return AppleSpeechPreferencesResolution(
                readiness: analyzerReadiness,
                providerID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer
            )
        }
        if legacyReadiness.isReady {
            return AppleSpeechPreferencesResolution(
                readiness: legacyReadiness,
                providerID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy
            )
        }
        return AppleSpeechPreferencesResolution(
            readiness: platformSupportsAnalyzer ? analyzerReadiness : legacyReadiness,
            providerID: nil
        )
    }
}

/// Latest-wins ownership for Preferences operations whose result is meaningful only for the
/// endpoint captured when work began. Claiming consumes the request even when its endpoint is no
/// longer current, so changing a field away and back cannot revive a completion that arrived stale.
struct EndpointBoundRefreshLifecycle {
    struct Request: Equatable {
        fileprivate let generation: UInt64
        let endpoint: URL
    }

    private var nextGeneration: UInt64 = 0
    private var activeRequest: Request?

    mutating func begin(endpoint: URL) -> Request {
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        let request = Request(generation: nextGeneration, endpoint: endpoint)
        activeRequest = request
        return request
    }

    mutating func claim(_ request: Request, currentEndpoint: URL) -> Bool {
        guard activeRequest == request else { return false }
        activeRequest = nil
        return request.endpoint == currentEndpoint
    }

    mutating func invalidate() {
        activeRequest = nil
    }
}

/// Latest-wins ownership for API-key validation. The request deliberately carries no key bytes:
/// the task already owns the submitted value for the duration of the network request, and keeping
/// another credential copy in controller state would extend its lifetime unnecessarily.
///
/// `draftMatches` is evaluated only when the current request claims its completion. A field edit,
/// explicit delete, or view teardown invalidates the active generation, so a transport that ignores
/// cancellation still cannot save a revoked key or update detached UI.
struct GeminiKeyValidationLifecycle {
    struct Request: Equatable {
        fileprivate let generation: UInt64
    }

    private var nextGeneration: UInt64 = 0
    private var activeRequest: Request?

    var isActive: Bool { activeRequest != nil }

    mutating func begin() -> Request {
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        let request = Request(generation: nextGeneration)
        activeRequest = request
        return request
    }

    mutating func claim(_ request: Request, draftMatches: Bool) -> Bool {
        guard activeRequest == request else { return false }
        activeRequest = nil
        return draftMatches
    }

    mutating func invalidate() {
        activeRequest = nil
    }
}

enum WhisperActionKind: Equatable, Sendable {
    case modelDownload
    case serverStart
}

/// View-scoped ownership for a long-running Whisper button action. Only one action is admitted at
/// a time, so a readiness refresh cannot make two backend operations race. Progress checks are
/// non-consuming because URLSession may enqueue many of them; completion consumes ownership once
/// so a late progress block or closed window cannot repaint controls that no longer represent the
/// operation. Localization replacement waits until this owner retires.
struct WhisperActionLifecycle {
    struct Request: Equatable, Sendable {
        fileprivate let generation: UInt64
        let kind: WhisperActionKind
    }

    private var nextGeneration: UInt64 = 0
    private var activeRequest: Request?

    var activeAction: WhisperActionKind? { activeRequest?.kind }

    mutating func begin(_ kind: WhisperActionKind) -> Request? {
        guard activeRequest == nil else { return nil }
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        let request = Request(generation: nextGeneration, kind: kind)
        activeRequest = request
        return request
    }

    func allowsProgress(_ request: Request) -> Bool {
        request.kind == .modelDownload && activeRequest == request
    }

    mutating func claimCompletion(_ request: Request) -> Bool {
        guard activeRequest == request else { return false }
        activeRequest = nil
        return true
    }

    mutating func cancel(_ kind: WhisperActionKind) -> Bool {
        guard activeRequest?.kind == kind else { return false }
        activeRequest = nil
        return true
    }

    mutating func invalidate() {
        activeRequest = nil
    }
}

/// The readiness probe owns the baseline labels, while an active action owns whether its controls
/// can be used. Keeping that precedence in a pure projection prevents reloads from erasing download
/// progress or exposing a second Start/Get Model action before the first one has retired.
struct WhisperControlsPresentation: Equatable {
    let serverButtonTitleKey: String
    let isServerButtonEnabled: Bool
    let isModelButtonHidden: Bool
    let isModelButtonEnabled: Bool
    /// `nil` preserves the current percentage/download title while progress callbacks are active.
    let modelButtonTitleKey: String?

    static func resolve(
        readiness: WhisperReadinessPresentation,
        activeAction: WhisperActionKind?
    ) -> WhisperControlsPresentation {
        switch activeAction {
        case .modelDownload:
            return WhisperControlsPresentation(
                serverButtonTitleKey: readiness.serverButtonTitleKey,
                isServerButtonEnabled: false,
                isModelButtonHidden: false,
                isModelButtonEnabled: false,
                modelButtonTitleKey: nil
            )
        case .serverStart:
            return WhisperControlsPresentation(
                serverButtonTitleKey: "common.cancel",
                isServerButtonEnabled: true,
                isModelButtonHidden: readiness.isModelButtonHidden,
                isModelButtonEnabled: false,
                modelButtonTitleKey: readiness.isModelButtonHidden
                    ? nil
                    : "prefs.voice.whisper.getModel"
            )
        case nil:
            return WhisperControlsPresentation(
                serverButtonTitleKey: readiness.serverButtonTitleKey,
                isServerButtonEnabled: readiness.isServerButtonEnabled,
                isModelButtonHidden: readiness.isModelButtonHidden,
                isModelButtonEnabled: readiness.isModelButtonEnabled,
                modelButtonTitleKey: readiness.isModelButtonHidden
                    ? nil
                    : "prefs.voice.whisper.getModel"
            )
        }
    }
}

enum WhisperServerToggleDecision: Equatable {
    case cancelPendingStart
    case ignoreWhileDownloading
    case stopManagedServer
    case startServer

    static func resolve(
        activeAction: WhisperActionKind?,
        isManagedByApp: Bool
    ) -> WhisperServerToggleDecision {
        switch activeAction {
        case .serverStart: return .cancelPendingStart
        case .modelDownload: return .ignoreWhileDownloading
        case nil: return isManagedByApp ? .stopManagedServer : .startServer
        }
    }
}

/// One immutable projection drives both the Whisper inventory row and its server button. A
/// reachable configured endpoint wins over local installation state because it may be an external
/// server that DevType must use but must not attempt to stop.
struct WhisperReadinessPresentation: Equatable {
    enum TintRole: Equatable { case checking, ready, attention }

    let statusKey: String
    let tintRole: TintRole
    let detailState: WhisperServerSetup.State?
    let serverButtonTitleKey: String
    let isServerButtonEnabled: Bool
    let isModelButtonHidden: Bool
    let isModelButtonEnabled: Bool

    static func resolve(
        setupState: WhisperServerSetup.State?,
        isManagedByApp: Bool,
        hasLocalModel: Bool
    ) -> WhisperReadinessPresentation {
        // Do not advertise a local download until the endpoint probe establishes that the
        // configured server is unavailable. A reachable external server needs no local artifact.
        let shouldOfferModelDownload = setupState != nil
            && setupState != .running
            && !hasLocalModel

        guard let setupState else {
            return WhisperReadinessPresentation(
                statusKey: "status.checking",
                tintRole: .checking,
                detailState: nil,
                serverButtonTitleKey: "status.checking",
                isServerButtonEnabled: false,
                isModelButtonHidden: !shouldOfferModelDownload,
                isModelButtonEnabled: shouldOfferModelDownload
            )
        }

        let buttonTitleKey: String
        let buttonEnabled: Bool
        if isManagedByApp {
            buttonTitleKey = "prefs.voice.whisper.stop"
            buttonEnabled = true
        } else if setupState == .running {
            buttonTitleKey = "prefs.voice.whisper.external"
            buttonEnabled = false
        } else {
            buttonTitleKey = "prefs.voice.whisper.start"
            buttonEnabled = true
        }

        switch setupState {
        case .running:
            return WhisperReadinessPresentation(
                statusKey: "prefs.voice.speechModels.status.ready",
                tintRole: .ready,
                detailState: nil,
                serverButtonTitleKey: buttonTitleKey,
                isServerButtonEnabled: buttonEnabled,
                isModelButtonHidden: !shouldOfferModelDownload,
                isModelButtonEnabled: shouldOfferModelDownload
            )
        case .installedNotRunning:
            return WhisperReadinessPresentation(
                statusKey: "prefs.voice.speechModels.status.needsServer",
                tintRole: .attention,
                detailState: setupState,
                serverButtonTitleKey: buttonTitleKey,
                isServerButtonEnabled: buttonEnabled,
                isModelButtonHidden: !shouldOfferModelDownload,
                isModelButtonEnabled: shouldOfferModelDownload
            )
        case .notInstalled:
            return WhisperReadinessPresentation(
                statusKey: "prefs.voice.speechModels.status.needsSetup",
                tintRole: .attention,
                detailState: setupState,
                serverButtonTitleKey: buttonTitleKey,
                isServerButtonEnabled: buttonEnabled,
                isModelButtonHidden: !shouldOfferModelDownload,
                isModelButtonEnabled: shouldOfferModelDownload
            )
        }
    }
}

/// Typed UI projection for clearing the always-on, content-free voice outcome history. Keeping
/// the recorder operation injectable makes the button's one-shot behavior testable without
/// touching the user's real Application Support files.
struct VoiceTerminalDiagnosticsDeletionPresentation: Equatable {
    let statusKey: String
    let isWarning: Bool
    let alertTitleKey: String?
    let alertMessageKey: String?
    let failure: VoiceDiagnosticsRecorder.IOFailure?

    static func perform(
        delete: () -> VoiceDiagnosticsRecorder.IOStatus
    ) -> VoiceTerminalDiagnosticsDeletionPresentation {
        switch delete() {
        case .succeeded:
            return VoiceTerminalDiagnosticsDeletionPresentation(
                statusKey: "prefs.voice.terminalDiagnostics.status.deleted",
                isWarning: false,
                alertTitleKey: nil,
                alertMessageKey: nil,
                failure: nil
            )
        case .failed(let failure):
            return VoiceTerminalDiagnosticsDeletionPresentation(
                statusKey: "prefs.voice.terminalDiagnostics.status.deleteFailed",
                isWarning: true,
                alertTitleKey: "prefs.voice.terminalDiagnostics.deleteFailed.title",
                alertMessageKey: "prefs.voice.terminalDiagnostics.deleteFailed.message",
                failure: failure
            )
        case .notAttempted:
            return VoiceTerminalDiagnosticsDeletionPresentation(
                statusKey: "prefs.voice.terminalDiagnostics.status.deleteFailed",
                isWarning: true,
                alertTitleKey: "prefs.voice.terminalDiagnostics.deleteFailed.title",
                alertMessageKey: "prefs.voice.terminalDiagnostics.deleteFailed.message",
                failure: nil
            )
        }
    }
}

/// Canonical Advanced-pane projection for deferred Keychain cleanup debt. Reloading the pane must
/// render both branches: otherwise a successful automatic retry leaves an earlier red failure (or
/// unrelated maintenance result) on screen even though the store has returned to a healthy state.
struct SecretCleanupMaintenancePresentation: Equatable {
    let text: String
    let isWarning: Bool

    static func resolve(
        pendingCount: Int,
        localization: LocalizationManager = .shared
    ) -> SecretCleanupMaintenancePresentation {
        let pending = max(0, pendingCount)
        guard pending > 0 else {
            return SecretCleanupMaintenancePresentation(
                text: localization.s("prefs.advanced.secretCleanup.none"),
                isWarning: false
            )
        }
        return SecretCleanupMaintenancePresentation(
            text: localization.s("prefs.advanced.secretCleanup.failed", pending),
            isWarning: true
        )
    }
}

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

/// Keeps the pasteboard's Boolean result attached to the visible status and semantic tint.
struct AdvancedDiagnosticsCopyPresentation: Equatable {
    enum TintRole: Equatable { case success, failure }

    let statusKey: String
    let tintRole: TintRole

    static func resolve(didWrite: Bool) -> Self {
        didWrite
            ? Self(statusKey: "prefs.advanced.copied", tintRole: .success)
            : Self(statusKey: "prefs.advanced.copyFailed", tintRole: .failure)
    }
}

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private var preferences: PreferencesViewController?
    private weak var hotkeyManager: HotkeyManager?
    private var renderedLanguage: AppLanguage?
    private var localizationRefreshDeferred = false
    private var sheetEndObserver: NSObjectProtocol?

    private init() {
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
            performLocalizationRefresh()
        }
        preferences?.refreshHotkeyManager(hotkeyManager)
        if let tab { preferences?.select(tab) }
        preferences?.reloadAll()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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

    private func performLocalizationRefresh() {
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

// MARK: - Flipped scroll document

/// Marker views let the shared card stack stretch rows and table areas while
/// preserving intrinsic widths for individual controls and buttons.
private final class PreferenceRowView: NSView {}
private final class PreferenceTableAreaView: NSView {}

// MARK: - Sidebar nav row

/// System Settings–style sidebar row: icon + label, rounded selection, hover
/// wash, and a ⌘1…⌘N key equivalent so the window is keyboard-navigable.
private final class SidebarNavRow: NSButton {
    let tab: PreferencesTab
    private let symbolName: String
    var isSelectedRow = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(tab: PreferencesTab, index: Int, target: AnyObject?, action: Selector?) {
        self.tab = tab
        self.symbolName = tab.symbol
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = tab.title
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        keyEquivalent = String(index + 1)
        keyEquivalentModifierMask = [.command]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityRole(NSAccessibility.Role.button)
        setAccessibilityLabel(tab.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceTrackingAreaOverBounds()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if isSelectedRow {
            DevTypeTheme.accent.withAlphaComponent(hovering ? 0.30 : 0.24).setFill()
            path.fill()
            DevTypeTheme.accent.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            DevTypeTheme.contrastOverlay(0.07).setFill()
            path.fill()
        }

        let tint: NSColor = isSelectedRow ? DevTypeTheme.accentBright : DevTypeTheme.textSecondary
        let icon = DevTypeTheme.tintedSymbol(symbolName, size: 12, weight: .semibold, color: tint)
        let iconY = (bounds.height - (icon?.size.height ?? 0)) / 2
        icon?.draw(
            in: NSRect(x: 10, y: iconY, width: icon?.size.width ?? 0, height: icon?.size.height ?? 0),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: DevTypeTheme.font(12.5, isSelectedRow ? .semibold : .medium),
            .foregroundColor: isSelectedRow ? DevTypeTheme.textPrimary : DevTypeTheme.textSecondary
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 34, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - Preferences content

final class PreferencesViewController: NSViewController,
                                       NSTableViewDataSource,
                                       NSTableViewDelegate,
                                       NSTextFieldDelegate {

    private let loc = LocalizationManager.shared
    private let store = SnippetStore.shared
    private weak var hotkeyManager: HotkeyManager?

    private var navRows: [SidebarNavRow] = []
    private var selectedTab: PreferencesTab = .home
    private var panes: [PreferencesTab: NSView] = [:]
    /// Host every pane is pinned into. Retained so panes can be built on first selection
    /// rather than all at once: General, Snippets, Hotkeys, Voice (a 639-line builder), AI,
    /// Advanced and the whole `HomeViewController` used to be constructed, constrained and
    /// left resident before the window appeared, with six of seven merely `isHidden`. Most
    /// users open one pane.
    private weak var paneHostView: NSView?
    private var paneTitleLabel: NSTextField?
    private var paneSubtitleLabel: NSTextField?
    private var paneIconBadge: IconBadgeView?
    private var tabsShownAtLeastOnce: Set<PreferencesTab> = [.home]
    private var removalButtons: [ObjectIdentifier: CapsuleButton] = [:]
    /// Glanceable engine state pinned to the bottom of the sidebar.
    private var engineStatusPill: PillBadgeView?
    private var homeViewController: HomeViewController?

    // General
    private let openAtLoginSwitch = NSSwitch()
    private let automaticUpdateSwitch = NSSwitch()
    /// Only meaningful while the library lives somewhere the user chose; disabled otherwise.
    private var libraryStopSyncButton: CapsuleButton?
    private let updateStatusLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )
    private var updateStatusObserver: NSObjectProtocol?
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mutedTable = NSTableView()
    private let mutedEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private var mutedApps: [String] = []

    // Snippets
    private lazy var stats = StatsViewController(store: store)
    private let libraryPathLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.mono(10.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )
    private let conflictsLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.statusOrange,
        wrapping: true
    )

    // Hotkeys
    private var inlineRecorder: ShortcutRecorderView?
    private let hotkeyWarningLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5, .medium),
        color: DevTypeTheme.statusOrange,
        wrapping: true
    )
    private let macroTable = NSTableView()
    private let macroEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private var macros: [HotkeyMacroAction] = []
    private var macroRecorder: ShortcutRecorderView?
    private let macroKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let macroArgumentField = NSTextField()

    // Advanced
    private let tapThreadSwitch = NSSwitch()
    private let advancedReadout = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.mono(10.5),
        color: DevTypeTheme.textSecondary,
        wrapping: true
    )
    private let maintenanceStatus = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.statusGreen,
        wrapping: true
    )
    private var secretCleanupButton: NSButton?

    // AI
    private let aiEnabledSwitch = NSSwitch()
    private let aiRemoveMarkdownSwitch = NSSwitch()
    private let aiTagSuggestionsSwitch = NSSwitch()
    private let aiSemanticRoutingSwitch = NSSwitch()
    private let repetitionSwitch = NSSwitch()
    private let requireBiometrySwitch = NSSwitch()
    private let aiAvailabilityLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.textSecondary,
        wrapping: true
    )
    private var aiPaletteRecorder: ShortcutRecorderView?
    private var aiOutputModePopups: [AITransformKind: NSPopUpButton] = [:]
    private let aiAllowlistTable = NSTableView()
    private let aiAllowlistEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private let aiAllowlistField = NSTextField()
    private var aiAllowlist: [String] = []

    // Voice & Smart Dictation
    private let voiceModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceEngines = TranscriptionEngine.allCases
    private let voiceTonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceLiveDeliveryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceTracingSwitch = NSSwitch()
    private let voiceTraceStatusLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )
    private let voiceProofreadSwitch = NSSwitch()
    private let appleSpeechAssetButton = NSButton()
    private weak var appleSpeechAssetRow: NSView?
    private let whisperServerButton = NSButton()
    private let whisperModelButton = NSButton()
    private let voiceAutoPunctuateSwitch = NSSwitch()
    private let voiceDisfluenciesSwitch = NSSwitch()
    private let voiceSoundFeedbackSwitch = NSSwitch()
    private var voiceShortcutRecorder: ShortcutRecorderView?
    private let voiceDictionaryTable = NSTableView()
    private let voiceDictionaryEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private let voiceDictSpokenField = NSTextField()
    private let voiceDictReplacementField = NSTextField()
    private var voiceDictEntries: [(spoken: String, replacement: String)] = []
    private let voiceTriggersTable = NSTableView()
    private let voiceTriggersEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private let voiceTriggerPhraseField = NSTextField()
    private let voiceTriggerActionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var voiceTriggerEntries: [(phrase: String, action: String)] = []
    private var voiceMicPermissionPill: PillBadgeView?
    private var voiceSpeechPermissionPill: PillBadgeView?
    private var voiceEngineStatusLabels: [TranscriptionEngine: NSTextField] = [:]
    private var appleSpeechReadiness: ProviderReadiness?
    private var appleSpeechAnalyzerReadiness: ProviderReadiness?
    private var resolvedAppleSpeechProviderID: String?
    private var localAICorrectionProviderID: String?
    private var appleSpeechReadinessRefresh = AppleSpeechReadinessRefreshLifecycle()
    private var appleSpeechReadinessTask: Task<Void, Never>?
    private var appleSpeechAssetInstallLifecycle = AppleSpeechAssetInstallLifecycle()
    private var appleSpeechAssetInstallTask: Task<Void, Never>?
    private var whisperReadinessState: WhisperServerSetup.State?
    private var whisperModelStatus: WhisperModelStatus?
    private var whisperReadinessRefresh = EndpointBoundRefreshLifecycle()
    private var whisperReadinessTask: Task<Void, Never>?
    private var whisperActionLifecycle = WhisperActionLifecycle()
    private var whisperModelDownloadTask: Task<Void, Never>?
    private var whisperServerStartTask: Task<Void, Never>?
    private let onLocalizationBlockingOperationDidEnd: (() -> Void)?
    /// Cleared immediately after first view load so an unsaved credential draft is not retained
    /// in a second long-lived String after it has been restored to the secure field.
    private var restorationState: PreferencesLocalizationState?

    // Voice Engine & API Settings
    private let geminiAPIKeyField = NSSecureTextField()
    private let geminiCloudConsentSwitch = NSSwitch()
    private var geminiKeyStatusPill: PillBadgeView?
    private var geminiKeySaveButton: CapsuleButton?
    private var geminiKeyDeleteButton: CapsuleButton?
    private var geminiKeyValidationLifecycle = GeminiKeyValidationLifecycle()
    private var geminiKeyValidationTask: Task<Void, Never>?
    private let geminiConfigContainer = NSStackView()
    private let localLLMEndpointField = NSTextField()
    private let localLLMModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let localLLMModelField = NSTextField()
    private var localLLMScanButton: CapsuleButton?
    private var localLLMStatusPill: PillBadgeView?
    private let localLLMConfigContainer = NSStackView()
    private var localModelScanRefresh = EndpointBoundRefreshLifecycle()
    private var localModelScanTask: Task<Void, Never>?

    init(
        hotkeyManager: HotkeyManager?,
        restorationState: PreferencesLocalizationState? = nil,
        onLocalizationBlockingOperationDidEnd: (() -> Void)? = nil
    ) {
        self.hotkeyManager = hotkeyManager
        self.restorationState = restorationState
        self.onLocalizationBlockingOperationDidEnd = onLocalizationBlockingOperationDidEnd
        super.init(nibName: nil, bundle: nil)
        updateStatusObserver = NotificationCenter.default.addObserver(
            forName: UpdatePreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshUpdateStatusLabel()
        }
    }

    deinit {
        appleSpeechReadinessTask?.cancel()
        appleSpeechAssetInstallTask?.cancel()
        whisperReadinessTask?.cancel()
        whisperModelDownloadTask?.cancel()
        whisperServerStartTask?.cancel()
        localModelScanTask?.cancel()
        geminiKeyValidationTask?.cancel()
        if let updateStatusObserver {
            NotificationCenter.default.removeObserver(updateStatusObserver)
        }
    }

    /// Re-point at the live manager. Called by `PreferencesWindowController.show`
    /// on every presentation so a window that is already open never keeps acting
    /// on the manager (or absence of one) it was created with.
    func refreshHotkeyManager(_ manager: HotkeyManager?) {
        hotkeyManager = manager
        homeViewController?.refreshHotkeyManager(manager)
    }

    var blocksLocalizationReplacement: Bool {
        geminiKeyValidationLifecycle.isActive
            || appleSpeechAssetInstallLifecycle.isActive
            || whisperActionLifecycle.activeAction != nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        appleSpeechReadinessTask?.cancel()
        appleSpeechReadinessTask = nil
        appleSpeechReadinessRefresh.invalidate()
        invalidateAppleSpeechAssetInstall()
        invalidateGeminiKeyValidation(resetPresentation: false)
        invalidateLocalModelScan(resetPresentation: true)
        whisperReadinessTask?.cancel()
        whisperReadinessTask = nil
        whisperReadinessRefresh.invalidate()
        whisperModelStatus = nil
        invalidateWhisperActions()
    }

    /// The window controller gates replacement until every view-owned operation has retired.
    /// Keep the assertion here so future replacement call sites cannot silently bypass that gate;
    /// normal window teardown still invalidates through `viewWillDisappear`.
    func prepareForLocalizationReplacement() {
        precondition(
            !blocksLocalizationReplacement,
            "Preferences localization replacement cannot detach live async operations"
        )
    }

    // MARK: Layout

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        // MARK: Sidebar — brand, nav rows, engine status.
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.layer?.backgroundColor = DevTypeTheme.cardBackground.cgColor

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let brand = DevTypeTheme.makeBrandHeader(
            title: "DevType",
            subtitle: "v\(version)",
            logoSize: 32
        )

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 3
        navStack.translatesAutoresizingMaskIntoConstraints = false
        navStack.setAccessibilityRole(NSAccessibility.Role.tabGroup)
        navStack.setAccessibilityLabel(loc.s("ax.preferences.tabs"))
        for (index, tab) in PreferencesTab.visibleCases.enumerated() {
            let row = SidebarNavRow(tab: tab, index: index, target: self, action: #selector(navRowTapped(_:)))
            row.isSelectedRow = tab == selectedTab
            navRows.append(row)
            navStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
        }

        let sidebarHairline = DevTypeTheme.makeHairline()
        let engineCaption = DevTypeTheme.makeLabel(
            loc.s("prefs.advanced.engine"),
            font: DevTypeTheme.font(10, .semibold),
            color: DevTypeTheme.textTertiary
        )
        engineCaption.translatesAutoresizingMaskIntoConstraints = false
        let statusPill = PillBadgeView(
            text: loc.s("status.active"),
            tint: DevTypeTheme.statusGreen,
            showsDot: true
        )
        engineStatusPill = statusPill

        sidebar.addSubview(brand)
        sidebar.addSubview(navStack)
        sidebar.addSubview(sidebarHairline)
        sidebar.addSubview(engineCaption)
        sidebar.addSubview(statusPill)

        // MARK: Content — section title + swappable pane host.
        // Vertical rule — `makeHairline()` carries a fixed 1pt *height*, so a
        // plain layer-backed view is used for the vertical variant instead.
        let separator = NSView()
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.layer?.backgroundColor = DevTypeTheme.hairline.cgColor
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let paneIcon = IconBadgeView(
            symbol: selectedTab.symbol,
            tint: DevTypeTheme.accent,
            size: 34,
            pointSize: 15
        )
        paneIconBadge = paneIcon

        let paneTitle = DevTypeTheme.makeLabel(
            selectedTab.title,
            font: DevTypeTheme.font(21, .bold),
            color: DevTypeTheme.textPrimary
        )
        paneTitleLabel = paneTitle

        let paneSubtitle = DevTypeTheme.makeLabel(
            selectedTab.subtitle,
            font: DevTypeTheme.font(11.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        paneSubtitleLabel = paneSubtitle

        let paneHeadingText = NSStackView(views: [paneTitle, paneSubtitle])
        paneHeadingText.orientation = .vertical
        paneHeadingText.alignment = .leading
        paneHeadingText.spacing = 2
        paneHeadingText.translatesAutoresizingMaskIntoConstraints = false

        let paneHeader = NSStackView(views: [paneIcon, paneHeadingText])
        paneHeader.orientation = .horizontal
        paneHeader.alignment = .centerY
        paneHeader.spacing = 11
        paneHeader.translatesAutoresizingMaskIntoConstraints = false
        paneHeadingText.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let paneHost = NSView()
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paneHeader)
        content.addSubview(paneHost)

        paneHostView = paneHost
        // Only the pane about to be shown. The rest are built by `ensurePane(_:)` the first
        // time they are selected.
        _ = ensurePane(selectedTab)

        root.addSubview(sidebar)
        root.addSubview(separator)
        root.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 196),

            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -12),

            navStack.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 20),
            navStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            sidebarHairline.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarHairline.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            sidebarHairline.bottomAnchor.constraint(equalTo: engineCaption.topAnchor, constant: -10),

            engineCaption.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            engineCaption.bottomAnchor.constraint(equalTo: statusPill.topAnchor, constant: -6),

            statusPill.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            statusPill.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            paneHeader.topAnchor.constraint(equalTo: content.topAnchor, constant: 42),
            paneHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            paneHeader.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

            paneHost.topAnchor.constraint(equalTo: paneHeader.bottomAnchor, constant: 16),
            paneHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paneHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadAll()
        if let restorationState {
            self.restorationState = nil
            restoreLocalizationState(restorationState)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadAll()
    }

    func select(_ tab: PreferencesTab) {
        let resolved = PreferencesTab.visibleCases.contains(tab) ? tab : .general
        applyTabSelection(resolved, animated: false)
    }

    @objc private func navRowTapped(_ sender: SidebarNavRow) {
        applyTabSelection(sender.tab, animated: true)
    }

    /// Returns the pane for `tab`, building and installing it on first use.
    @discardableResult
    private func ensurePane(_ tab: PreferencesTab) -> NSView? {
        if let existing = panes[tab] { return existing }
        guard let host = paneHostView else { return nil }
        let pane = makeScrollingPane(for: tab)
        pane.isHidden = tab != selectedTab
        host.addSubview(pane)
        panes[tab] = pane
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: host.topAnchor),
            pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        // A pane built after `reloadAll()` has already run would otherwise show whatever its
        // builder happened to set rather than current preferences. Populate it now — the
        // reloads are idempotent, and `reloadVoice`/`reloadAI` already guard on the pane
        // existing, which it does by this point.
        reload(tab)
        return pane
    }

    /// Repopulates one pane's controls from current preferences.
    private func reload(_ tab: PreferencesTab) {
        switch tab {
        case .home: homeViewController?.refresh()
        case .general: reloadGeneral()
        case .snippets: reloadSnippets()
        case .hotkeys: reloadHotkeys()
        case .voice: reloadVoice()
        case .ai: reloadAI()
        case .advanced: reloadAdvanced()
        }
    }

    private func applyTabSelection(_ tab: PreferencesTab, animated: Bool) {
        let isFirstPresentation = tabsShownAtLeastOnce.insert(tab).inserted
        selectedTab = tab
        // Must precede the reload/refresh calls below, which read the pane's controls.
        ensurePane(tab)
        for row in navRows {
            let selected = row.tab == tab
            row.isSelectedRow = selected
            row.setAccessibilityValue(selected)
        }
        paneTitleLabel?.stringValue = tab.title
        paneSubtitleLabel?.stringValue = tab.subtitle
        paneIconBadge?.setSymbol(tab.symbol, tint: DevTypeTheme.accent)
        for (candidate, pane) in panes {
            pane.isHidden = candidate != tab
        }
        // Gentle cross-fade on the incoming pane; suppressed under Reduce Motion.
        if animated, !DevTypeAccessibility.reduceMotion, let pane = panes[tab] {
            pane.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                pane.animator().alphaValue = 1
            }
        } else {
            panes[tab]?.alphaValue = 1
        }
        if tab == .snippets { stats.refresh() }
        if tab == .advanced { reloadAdvanced() }
        if tab == .ai { reloadAI() }
        // Reloading controls (especially popups) can make AppKit reveal their
        // row. Reset after all pane work so first presentation still starts at
        // the page header rather than at the last selected action.
        if isFirstPresentation {
            resetScrollPosition(for: tab)
        }
    }

    /// Auto Layout sizes hidden scroll documents lazily. Their clip view can
    /// therefore inherit a non-zero origin before first display, which made long
    /// panes open in the middle. Reset once, after revealing and laying out; later
    /// visits preserve the user's own scroll position.
    private func resetScrollPosition(for tab: PreferencesTab) {
        guard let scroll = panes[tab] as? NSScrollView else { return }
        let scrollToTop = { [weak scroll] in
            guard let scroll else { return }
            scroll.documentView?.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        DispatchQueue.main.async(execute: scrollToTop)
    }

    /// Sidebar footer: one glance answers "is it on?" without opening the menu.
    private func refreshEngineStatus() {
        let snapshot = PermissionProbe().snapshot()
        let display = EngineDisplayStatus.resolve(
            snapshot: snapshot,
            isTapRunning: EventTapEngine.shared.isTapRunning,
            isEnabled: EventTapEngine.shared.isEnabled,
            isSecureInputActive: EventTapEngine.shared.isSecureInputActive
        )
        let text: String
        let tint: NSColor
        switch display {
        case .active:
            text = loc.s("status.active")
            tint = DevTypeTheme.statusGreen
        case .secure:
            text = loc.s("status.secure")
            tint = DevTypeTheme.statusBlue
        case .paused:
            text = loc.s("status.paused")
            tint = DevTypeTheme.statusGray
        case .needsPermissions:
            text = loc.s("status.needsPermissions")
            tint = DevTypeTheme.accent
        case .tapFailed:
            text = loc.s("status.tapFailed")
            tint = DevTypeTheme.accent
        }
        engineStatusPill?.update(text: text, tint: tint)
    }

    /// Re-pulls every value from its source of truth.
    func reloadAll() {
        guard isViewLoaded else { return }
        homeViewController?.refresh()
        reloadGeneral()
        reloadSnippets()
        reloadHotkeys()
        reloadVoice()
        reloadAI()
        reloadAdvanced()
        refreshEngineStatus()
    }

    /// Snapshot only state that is not already committed to a canonical preference store.
    func localizationState() -> PreferencesLocalizationState {
        var scrollOrigins: [PreferencesTab: NSPoint] = [:]
        for (tab, pane) in panes {
            guard let scroll = pane as? NSScrollView else { continue }
            scrollOrigins[tab] = scroll.contentView.bounds.origin
        }
        return PreferencesLocalizationState(
            selectedTab: selectedTab,
            macroArgument: transientValue(of: macroArgumentField),
            aiAllowlistBundleID: transientValue(of: aiAllowlistField),
            voiceDictionarySpoken: transientValue(of: voiceDictSpokenField),
            voiceDictionaryReplacement: transientValue(of: voiceDictReplacementField),
            voiceTriggerPhrase: transientValue(of: voiceTriggerPhraseField),
            geminiAPIKey: transientValue(of: geminiAPIKeyField),
            localLLMEndpoint: transientValue(of: localLLMEndpointField),
            localLLMModel: transientValue(of: localLLMModelField),
            scrollOrigins: scrollOrigins
        )
    }

    /// The field editor owns keystrokes while a text field is active. Reading only the control's
    /// cell can lag that editor, which would drop the last uncommitted characters during a rebuild.
    private func transientValue(of field: NSTextField) -> String {
        field.currentEditor()?.string ?? field.stringValue
    }

    private func restoreLocalizationState(_ state: PreferencesLocalizationState) {
        macroArgumentField.stringValue = state.macroArgument
        aiAllowlistField.stringValue = state.aiAllowlistBundleID
        voiceDictSpokenField.stringValue = state.voiceDictionarySpoken
        voiceDictReplacementField.stringValue = state.voiceDictionaryReplacement
        voiceTriggerPhraseField.stringValue = state.voiceTriggerPhrase
        geminiAPIKeyField.stringValue = state.geminiAPIKey
        localLLMEndpointField.stringValue = state.localLLMEndpoint
        localLLMModelField.stringValue = state.localLLMModel
        select(state.selectedTab)

        let scrollOrigins = state.scrollOrigins
        // Rebuild every pane the previous controller had. Panes are built on first selection, so
        // a pane carrying a scroll origin is one the user had opened — recreating it is what
        // makes their position survive the language change rather than silently resetting.
        for tab in scrollOrigins.keys { ensurePane(tab) }
        let restoreScrollPositions = { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            for (tab, origin) in scrollOrigins {
                guard let scroll = self.panes[tab] as? NSScrollView else { continue }
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        restoreScrollPositions()
        DispatchQueue.main.async(execute: restoreScrollPositions)
    }

    func refreshPermissionState() {
        guard isViewLoaded else { return }
        reloadVoice()
        refreshEngineStatus()
    }

    func refreshMaintenanceState() {
        guard isViewLoaded else { return }
        reloadAdvanced()
    }

    // MARK: Pane construction

    private func makeScrollingPane(for tab: PreferencesTab) -> NSView {
        if tab == .home {
            let homeVC = HomeViewController(store: store, hotkeyManager: hotkeyManager)
            homeViewController = homeVC
            let homeView = homeVC.view
            // The Home controller owns an NSScrollView, but its view is embedded in this
            // constraint-managed host just like every other Preferences pane.
            homeView.translatesAutoresizingMaskIntoConstraints = false
            return homeView
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        switch tab {
        case .home: break
        case .general: buildGeneral(into: stack)
        case .snippets: buildSnippets(into: stack)
        case .hotkeys: buildHotkeys(into: stack)
        case .voice: buildVoice(into: stack)
        case .ai: buildAI(into: stack)
        case .advanced: buildAdvanced(into: stack)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    // MARK: General (§4.1 / §4.8)

    private func buildGeneral(into stack: NSStackView) {
        // Startup
        let startupCard = makeCard(title: loc.s("prefs.general.startup"), symbol: "sunrise")
        let loginRow = makeToggleRow(
            title: loc.s("menu.openAtLogin"),
            toggle: openAtLoginSwitch,
            action: #selector(openAtLoginChanged)
        )
        let appearanceNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.appearanceNote"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        appearanceNote.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(startupCard, views: [loginRow, appearanceNote])

        // Language (§4.1: was a menu submenu)
        let languageCard = makeCard(title: loc.s("prefs.general.language"), symbol: "globe")
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.endonym)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.setAccessibilityLabel(loc.s("prefs.general.language"))
        let languageNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.languageNote"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        languageNote.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(languageCard, views: [languagePopup, languageNote])

        // Muted apps (§4.8: replaces the index-arithmetic alert)
        let mutedCard = makeCard(title: loc.s("prefs.general.mutedApps"), symbol: "speaker.slash.fill")
        let mutedHint = DevTypeTheme.makeLabel(
            loc.s("prefs.general.mutedApps.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        mutedHint.translatesAutoresizingMaskIntoConstraints = false

        let mutedArea = makeTableArea(
            table: mutedTable,
            accessibilityLabel: loc.s("prefs.general.mutedApps"),
            columnIdentifier: "muted",
            emptyLabel: mutedEmptyLabel,
            allowsMultipleSelection: true
        )

        let muteFrontmostButton = CapsuleButton(
            title: loc.s("prefs.general.muteFrontmost"),
            symbol: "speaker.slash",
            style: .secondary,
            target: self,
            action: #selector(muteFrontmost)
        )
        let unmuteButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(unmuteSelected)
        )
        bindRemovalButton(unmuteButton, to: mutedTable)
        let mutedButtons = NSStackView(views: [muteFrontmostButton, unmuteButton])
        mutedButtons.orientation = .horizontal
        mutedButtons.spacing = 8
        mutedButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(mutedCard, views: [mutedHint, mutedArea, mutedButtons])

        // Updates (§7.5). Off by default — the toggle governs only whether DevType checks on
        // its own; the menu bar's "Check for Updates…" works regardless.
        let updatesCard = makeCard(title: loc.s("prefs.general.updates"), symbol: "arrow.down.circle")
        let updatesRow = makeToggleRow(
            title: loc.s("prefs.general.updates.auto"),
            toggle: automaticUpdateSwitch,
            action: #selector(automaticUpdateCheckChanged)
        )
        let updatesNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.updates.note"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        updatesNote.translatesAutoresizingMaskIntoConstraints = false
        updateStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        let checkNowButton = CapsuleButton(
            title: loc.s("prefs.general.updates.checkNow"),
            symbol: "arrow.clockwise",
            style: .secondary,
            target: self,
            action: #selector(checkForUpdatesNow)
        )
        let updatesButtons = NSStackView(views: [checkNowButton])
        updatesButtons.orientation = .horizontal
        updatesButtons.spacing = 8
        updatesButtons.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(updatesCard, views: [updatesRow, updatesNote, updateStatusLabel, updatesButtons])

        stack.addArrangedSubview(startupCard)
        stack.addArrangedSubview(languageCard)
        stack.addArrangedSubview(updatesCard)
        stack.addArrangedSubview(mutedCard)
        pinWidth(of: [startupCard, languageCard, updatesCard, mutedCard], to: stack)
    }

    private func reloadGeneral() {
        openAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        automaticUpdateSwitch.state = UpdatePreferences.automaticCheckEnabled ? .on : .off
        refreshUpdateStatusLabel()
        let current = loc.language.rawValue
        for (index, language) in AppLanguage.allCases.enumerated()
        where language.rawValue == current {
            languagePopup.selectItem(at: index)
        }
        mutedApps = AppMuteStore.shared.allMuted().sorted()
        mutedTable.reloadData()
        mutedEmptyLabel.stringValue = mutedApps.isEmpty ? loc.s("prefs.general.mutedApps.empty") : ""
        mutedEmptyLabel.isHidden = !mutedApps.isEmpty
        refreshRemovalButton(for: mutedTable)
    }

    /// "Stop Syncing" is enabled only when there is something to stop — while the library is
    /// already at the default local path the button would be a no-op that still moves files.
    private func refreshLibraryLocation() {
        libraryPathLabel.stringValue = loc.s("prefs.snippets.libraryPath", store.activeLocationURL.path)
        let isCustom = UserDefaults.standard
            .string(forKey: SnippetStore.DeviceStateKey.storeLocationPath)?
            .isEmpty == false
        libraryStopSyncButton?.isEnabled = isCustom
    }

    /// Copies the library into a folder the user picks (an iCloud/Dropbox folder, typically)
    /// and switches to it. `saveSnippetsAs` backs up anything it overwrites there.
    @objc private func libraryMoveClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = loc.s("prefs.snippets.library.move")
        panel.message = loc.s("prefs.snippets.library.move.message")
        panel.prompt = loc.s("prefs.snippets.library.move")
        presentLibraryPanel(panel) { url in
            SnippetStore.shared.saveSnippetsAs(toDirectory: url)
        }
    }

    /// Adopts a library that already exists at the chosen file, backing up the local one first.
    /// This *replaces* what is on screen, so the confirmation says so before anything moves.
    @objc private func libraryLinkClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.title = loc.s("prefs.snippets.library.link")
        panel.message = loc.s("prefs.snippets.library.link.message")
        panel.prompt = loc.s("prefs.snippets.library.link")
        presentLibraryPanel(panel) { url in
            SnippetStore.shared.linkToSnippets(at: url)
        }
    }

    @objc private func libraryStopSyncingClicked() {
        let alert = NSAlert()
        alert.messageText = loc.s("prefs.snippets.library.stop")
        alert.informativeText = loc.s("prefs.snippets.library.stop.message")
        alert.addButton(withTitle: loc.s("prefs.snippets.library.stop"))
        alert.addButton(withTitle: loc.s("common.cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.reportRelocation(SnippetStore.shared.stopSyncing())
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func presentLibraryPanel(
        _ panel: NSOpenPanel,
        perform: @escaping (URL) -> SnippetStore.RelocationResult
    ) {
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.reportRelocation(perform(url))
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Always names the backup on success: a relocation the user cannot undo by hand is one
    /// they have to trust blindly, and the store already wrote the copy that makes it undoable.
    private func reportRelocation(_ result: SnippetStore.RelocationResult) {
        refreshLibraryLocation()
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        if result.success {
            var message = loc.s("prefs.snippets.library.done.body", result.activeLocation.path)
            if let backup = result.backupURL {
                message += "\n\n" + loc.s("prefs.snippets.library.done.backup", backup.path)
            }
            DevTypeAlert.info(
                title: loc.s("prefs.snippets.library.done.title"),
                message: message,
                window: view.window
            )
        } else {
            DevTypeAlert.warn(
                title: loc.s("prefs.snippets.library.failed.title"),
                message: result.message ?? loc.s("prefs.snippets.library.failed.title"),
                window: view.window
            )
        }
    }

    @objc private func automaticUpdateCheckChanged() {
        UpdatePreferences.automaticCheckEnabled = automaticUpdateSwitch.state == .on
        refreshUpdateStatusLabel()
    }

    @objc private func checkForUpdatesNow() {
        // Reports every outcome, including failures — the user asked.
        UpdateFlow.checkManually(window: view.window)
    }

    /// Shows the running version plus when a check last *succeeded*.
    ///
    /// "Never checked" is shown until one completes, so a run of failed checks never renders as
    /// a recent successful one.
    private func refreshUpdateStatusLabel() {
        let version = AppVersion.current()?.rawValue ?? "—"
        var lines = [loc.s("prefs.general.updates.currentVersion", version)]
        if let last = UpdatePreferences.lastSuccessfulCheck {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append(loc.s("prefs.general.updates.lastChecked", formatter.string(from: last)))
        } else {
            lines.append(loc.s("prefs.general.updates.never"))
        }
        updateStatusLabel.stringValue = lines.joined(separator: " · ")
    }

    @objc private func openAtLoginChanged() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            DevTypeAlert.warn(
                title: loc.s("alert.openAtLogin.title"),
                message: loc.s("alert.openAtLogin.message", error.localizedDescription),
                window: view.window
            )
        }
        reloadGeneral()
    }

    @objc private func languageChanged() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        loc.language = language
    }

    @objc private func muteFrontmost() {
        guard let bundleID = AppMuteStore.shared.muteFrontmost() else {
            DevTypeAlert.warn(
                title: loc.s("alert.muteFrontmost.failed.title"),
                message: loc.s("alert.muteFrontmost.failed.message"),
                window: view.window
            )
            return
        }
        DevTypeLog.app.info(
            "[Prefs] muted \(DevTypeLog.boundedPublicIdentifier(bundleID, label: "bundleID"), privacy: .public)"
        )
        reloadGeneral()
    }

    @objc private func unmuteSelected() {
        let selected = mutedTable.selectedRowIndexes
        guard !selected.isEmpty else { return }
        for row in selected where mutedApps.indices.contains(row) {
            AppMuteStore.shared.unmute(mutedApps[row])
        }
        reloadGeneral()
    }

    // MARK: Snippets (§4.5 / §0.4 / §1.9)

    /// Touch ID gate for secrets, on the tab that owns snippets.
    ///
    /// The note under the switch says what the check is *worth*, not just what it does. A security
    /// control whose limits are not stated invites the user to rely on it for more than it covers.
    private func buildSecretsCard(into stack: NSStackView) {
        let availability = BiometricGate.shared.availability()
        let card = makeCard(title: loc.s("prefs.secrets.card"), symbol: "key.fill")

        requireBiometrySwitch.state =
            SecretPreferences.requireBiometry(availability: availability) ? .on : .off
        requireBiometrySwitch.isEnabled = availability.canGate

        let row = makeToggleRow(
            title: loc.s("prefs.secrets.requireBiometry"),
            toggle: requireBiometrySwitch,
            action: #selector(requireBiometryChanged)
        )

        let detail: String
        switch availability {
        case .biometry(let name): detail = loc.s("prefs.secrets.note.biometry", name)
        case .passwordOnly: detail = loc.s("prefs.secrets.note.password")
        case .unavailable: detail = loc.s("prefs.secrets.note.unavailable")
        }
        let note = DevTypeTheme.makeLabel(
            detail,
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        note.translatesAutoresizingMaskIntoConstraints = false

        let scope = DevTypeTheme.makeLabel(
            loc.s("prefs.secrets.note.scope"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        scope.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(card, views: [row, note, scope])
        stack.addArrangedSubview(card)
        pinWidth(of: [card], to: stack)
    }

    func refreshSecretsCard() {
        let availability = BiometricGate.shared.availability()
        requireBiometrySwitch.state =
            SecretPreferences.requireBiometry(availability: availability) ? .on : .off
        requireBiometrySwitch.isEnabled = availability.canGate
    }

    @objc private func requireBiometryChanged() {
        SecretPreferences.setRequireBiometry(requireBiometrySwitch.state == .on)
        // Turning it on must take effect now, not after the current reuse window expires.
        BiometricGate.shared.invalidate()
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
    }

    private func buildSnippets(into stack: NSStackView) {
        buildSecretsCard(into: stack)

        addChild(stats)
        let statsView = stats.view
        statsView.translatesAutoresizingMaskIntoConstraints = false

        let libraryCard = makeCard(title: loc.s("manager.title"), symbol: "square.stack.3d.up")
        libraryPathLabel.translatesAutoresizingMaskIntoConstraints = false
        let ioButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("manager.import"),
                symbol: "square.and.arrow.down",
                style: .secondary,
                target: self,
                action: #selector(importLibrary)
            ),
            CapsuleButton(
                title: loc.s("manager.export"),
                symbol: "square.and.arrow.up",
                style: .primary,
                target: self,
                action: #selector(exportLibrary)
            )
        ])
        ioButtons.orientation = .horizontal
        ioButtons.spacing = 8
        ioButtons.translatesAutoresizingMaskIntoConstraints = false

        // Where the library lives. `SnippetStore.saveSnippetsAs` / `linkToSnippets` /
        // `stopSyncing` have always persisted the choice under `storeLocationPath` and been
        // read back by `resolveLocation` on launch — this row is the door to them. It belongs
        // beside the path label that already names the active location rather than in its own
        // card somewhere else.
        let locationNote = DevTypeTheme.makeLabel(
            loc.s("prefs.snippets.library.note"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        locationNote.translatesAutoresizingMaskIntoConstraints = false
        libraryStopSyncButton = CapsuleButton(
            title: loc.s("prefs.snippets.library.stop"),
            symbol: "xmark.circle",
            style: .secondary,
            target: self,
            action: #selector(libraryStopSyncingClicked)
        )
        let locationButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("prefs.snippets.library.move"),
                symbol: "externaldrive",
                style: .secondary,
                target: self,
                action: #selector(libraryMoveClicked)
            ),
            CapsuleButton(
                title: loc.s("prefs.snippets.library.link"),
                symbol: "link",
                style: .secondary,
                target: self,
                action: #selector(libraryLinkClicked)
            ),
            libraryStopSyncButton!
        ])
        locationButtons.orientation = .horizontal
        locationButtons.spacing = 8
        locationButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(libraryCard, views: [libraryPathLabel, ioButtons, locationNote, locationButtons])

        // §1.9: `SnippetSearch.conflictingTriggers` was dead code. Surfacing the
        // store's `triggerConflicts()` is how the user learns that `:Hi` and `:hi`
        // both live on disk while only one can ever fire.
        let conflictCard = makeCard(title: loc.s("prefs.snippets.conflicts"), symbol: "exclamationmark.triangle.fill")
        conflictsLabel.translatesAutoresizingMaskIntoConstraints = false
        let rescan = CapsuleButton(
            title: loc.s("prefs.snippets.rescan"),
            symbol: "arrow.triangle.2.circlepath",
            style: .secondary,
            target: self,
            action: #selector(rescanConflicts)
        )
        stackInCard(conflictCard, views: [conflictsLabel, rescan])

        stack.addArrangedSubview(statsView)
        stack.addArrangedSubview(libraryCard)
        stack.addArrangedSubview(conflictCard)
        pinWidth(of: [statsView, libraryCard, conflictCard], to: stack)
    }

    private func reloadSnippets() {
        refreshLibraryLocation()
        rescanConflicts()
    }

    @objc private func rescanConflicts() {
        let conflicts = store.triggerConflicts()
        guard !conflicts.isEmpty else {
            conflictsLabel.stringValue = loc.s("prefs.snippets.conflicts.none")
            conflictsLabel.textColor = DevTypeTheme.statusGreen
            return
        }
        var lines: [String] = []
        for conflict in conflicts.prefix(20) {
            let groups = conflict.groupNames.joined(separator: ", ")
            switch conflict.kind {
            case .emptyTrigger:
                lines.append(loc.s("prefs.snippets.conflict.empty", groups))
            case .duplicateTrigger:
                lines.append(loc.s("prefs.snippets.conflict.duplicate", conflict.trigger, groups))
            case .caseShadow:
                lines.append(loc.s("prefs.snippets.conflict.caseShadow", conflict.trigger, groups))
            case .prefixShadow:
                // snippetIDs[0] / groupNames[0] are the shadowing trigger; the rest are the
                // triggers it makes unreachable. Name them — "some snippet is shadowed" is
                // not actionable, "`slmabout can never fire" is.
                let blocked = conflict.blockedTriggerSummary ?? groups
                lines.append(loc.s("prefs.snippets.conflict.prefixShadow", conflict.trigger, blocked))
            }
        }
        conflictsLabel.stringValue = lines.joined(separator: "\n")
        conflictsLabel.textColor = DevTypeTheme.statusOrange
    }

    @objc private func exportLibrary() {
        LibraryExporter.present(from: view.window, store: store)
    }

    @objc private func importLibrary() {
        SnippetImportFlow.present(from: view.window) { [weak self] in
            self?.reloadSnippets()
        }
    }

    // MARK: Hotkeys (§4.2 / §4.3)

    private func buildHotkeys(into stack: NSStackView) {
        let searchCard = makeCard(title: loc.s("prefs.hotkeys.inlineSearch"), symbol: "magnifyingglass")
        let hint = DevTypeTheme.makeLabel(
            loc.s("prefs.hotkeys.inlineSearch.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hint.translatesAutoresizingMaskIntoConstraints = false

        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.inlineSearchShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyInlineShortcut(shortcut)
        }
        inlineRecorder = recorder

        let resetButton = CapsuleButton(
            title: loc.s("prefs.hotkeys.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetInlineShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false

        hotkeyWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(searchCard, views: [hint, recorderRow, hotkeyWarningLabel])

        // §4.3: the macro list that had no UI.
        let macroCard = makeCard(title: loc.s("prefs.hotkeys.macros"), symbol: "text.insert")
        let macroHint = DevTypeTheme.makeLabel(
            loc.s("prefs.hotkeys.macros.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        macroHint.translatesAutoresizingMaskIntoConstraints = false

        let macroArea = makeTableArea(
            table: macroTable,
            accessibilityLabel: loc.s("prefs.hotkeys.macros"),
            columnIdentifier: "macro",
            emptyLabel: macroEmptyLabel,
            rowHeight: 24
        )

        let newRecorder = ShortcutRecorderView(shortcut: nil)
        macroRecorder = newRecorder

        macroKindPopup.translatesAutoresizingMaskIntoConstraints = false
        macroKindPopup.removeAllItems()
        macroKindPopup.addItem(withTitle: loc.s("prefs.hotkeys.macros.kind.insertText"))
        macroKindPopup.lastItem?.representedObject = HotkeyMacroAction.Kind.insertText.rawValue
        macroKindPopup.addItem(withTitle: loc.s("prefs.hotkeys.macros.kind.openURL"))
        macroKindPopup.lastItem?.representedObject = HotkeyMacroAction.Kind.openURL.rawValue
        macroKindPopup.setAccessibilityLabel(loc.s("prefs.hotkeys.macros.kind"))

        macroArgumentField.translatesAutoresizingMaskIntoConstraints = false
        macroArgumentField.placeholderString = loc.s("prefs.hotkeys.macros.argument")
        macroArgumentField.font = DevTypeTheme.font(12)
        macroArgumentField.setAccessibilityLabel(loc.s("prefs.hotkeys.macros.argument"))
        macroArgumentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let editorRow = NSStackView(views: [newRecorder, macroKindPopup, macroArgumentField])
        editorRow.orientation = .horizontal
        editorRow.spacing = 8
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        let addMacroButton = CapsuleButton(
            title: loc.s("prefs.hotkeys.macros.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(addMacro)
        )
        let removeMacroButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(removeMacro)
        )
        bindRemovalButton(removeMacroButton, to: macroTable)
        let macroButtons = NSStackView(views: [addMacroButton, removeMacroButton])
        macroButtons.orientation = .horizontal
        macroButtons.spacing = 8
        macroButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(macroCard, views: [macroHint, macroArea, editorRow, macroButtons])

        stack.addArrangedSubview(searchCard)
        stack.addArrangedSubview(macroCard)
        pinWidth(of: [searchCard, macroCard], to: stack)
    }

    private func reloadHotkeys() {
        let shortcut = HotkeyPreferences.inlineSearchShortcut
        inlineRecorder?.setShortcut(shortcut)
        hotkeyWarningLabel.stringValue = shortcut.isDefaultInlineSearch
            ? loc.s("prefs.hotkeys.conflictWarning")
            : ""
        hotkeyWarningLabel.isHidden = !shortcut.isDefaultInlineSearch
        macros = hotkeyManager?.macros ?? HotkeyManager.loadMacros()
        macroTable.reloadData()
        macroEmptyLabel.stringValue = macros.isEmpty ? loc.s("prefs.hotkeys.macros.empty") : ""
        macroEmptyLabel.isHidden = !macros.isEmpty
        refreshRemovalButton(for: macroTable)
    }

    private func applyInlineShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        guard let manager = hotkeyManager else {
            HotkeyPreferences.inlineSearchShortcut = shortcut
            reloadHotkeys()
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
            return
        }
        let status = manager.applyInlineSearchShortcut(shortcut)
        if status != noErr {
            // §4.2: registration failure is surfaced, not silently logged.
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.failed.title"),
                message: loc.s("prefs.hotkeys.failed.message", shortcut.displayString, Int(status)),
                window: view.window
            )
        }
        reloadHotkeys()
    }

    @objc private func resetInlineShortcut() {
        HotkeyPreferences.resetInlineSearchShortcut()
        applyInlineShortcut(.inlineSearchDefault)
    }

    @objc private func addMacro() {
        guard let shortcut = macroRecorder?.shortcut else {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.macros.add"),
                message: loc.s("shortcut.needsModifier"),
                window: view.window
            )
            return
        }
        let argument = macroArgumentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.macros.add"),
                message: loc.s("prefs.hotkeys.macros.argument"),
                window: view.window
            )
            return
        }
        let rawKind = macroKindPopup.selectedItem?.representedObject as? String
        let kind = HotkeyMacroAction.Kind(rawValue: rawKind ?? "") ?? .insertText
        macros.append(
            HotkeyMacroAction(
                id: 0,
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                kind: kind,
                argument: argument
            )
        )
        let failures = hotkeyManager?.applyMacros(macros) ?? []
        if hotkeyManager == nil {
            HotkeyPreferences.saveMacros(macros)
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reportRegistrationFailures(failures)
        macroArgumentField.stringValue = ""
        macroRecorder?.setShortcut(nil)
        reloadHotkeys()
    }

    /// §4.2 parity for macros: a chord owned by another app must not produce a
    /// table row that silently does nothing forever. The app delegate suppresses
    /// its own alert while Preferences is visible, so this is the one channel
    /// that reaches the user here.
    private func reportRegistrationFailures(_ failures: [(label: String, status: OSStatus)]) {
        guard let first = failures.first else { return }
        DevTypeAlert.warn(
            title: loc.s("prefs.hotkeys.failed.title"),
            message: loc.s("prefs.hotkeys.failed.message", first.label, Int(first.status)),
            window: view.window
        )
    }

    @objc private func removeMacro() {
        let row = macroTable.selectedRow
        guard macros.indices.contains(row) else { return }
        macros.remove(at: row)
        hotkeyManager?.applyMacros(macros)
        if hotkeyManager == nil {
            HotkeyPreferences.saveMacros(macros)
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reloadHotkeys()
    }

    // MARK: Voice & Smart Dictation

    private func buildVoice(into stack: NSStackView) {
        // 0. Permission Card
        let permCard = makeCard(title: loc.s("prefs.voice.permission.card"), symbol: "mic.fill")
        let permHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.permission.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        permHint.translatesAutoresizingMaskIntoConstraints = false

        let micPill = PillBadgeView(text: loc.s("status.checking"), tint: DevTypeTheme.statusGray, showsDot: true)
        voiceMicPermissionPill = micPill

        let micActions = NSStackView(views: [
            micPill,
            CapsuleButton(
                title: loc.s("prefs.voice.requestMic"),
                symbol: "mic.fill",
                style: .primary,
                target: self,
                action: #selector(requestMicrophoneAccessClicked)
            ),
            CapsuleButton(
                title: loc.s("prefs.voice.openSettings"),
                symbol: "gearshape",
                style: .secondary,
                target: self,
                action: #selector(openMicrophoneSettingsClicked)
            )
        ])
        micActions.orientation = .horizontal
        micActions.spacing = 10
        micActions.alignment = .centerY
        let micRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.permission.microphone"),
            control: micActions,
            font: DevTypeTheme.font(11.5, .medium)
        )

        let speechPill = PillBadgeView(
            text: loc.s("status.checking"),
            tint: DevTypeTheme.statusGray,
            showsDot: true
        )
        voiceSpeechPermissionPill = speechPill
        let speechActions = NSStackView(views: [
            speechPill,
            CapsuleButton(
                title: loc.s("prefs.voice.requestSpeech"),
                symbol: "waveform",
                style: .primary,
                target: self,
                action: #selector(requestSpeechRecognitionAccessClicked)
            ),
            CapsuleButton(
                title: loc.s("prefs.voice.openSpeechSettings"),
                symbol: "gearshape",
                style: .secondary,
                target: self,
                action: #selector(openSpeechRecognitionSettingsClicked)
            )
        ])
        speechActions.orientation = .horizontal
        speechActions.spacing = 10
        speechActions.alignment = .centerY
        let speechRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.permission.speechRecognition"),
            control: speechActions,
            font: DevTypeTheme.font(11.5, .medium)
        )

        stackInCard(permCard, views: [permHint, micRow, speechRow])

        // 1. Models Card / Engine Configuration Card
        let modelsCard = makeCard(title: loc.s("prefs.voice.models.card"), symbol: "waveform.and.mic")
        let modelsHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.models.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        modelsHint.translatesAutoresizingMaskIntoConstraints = false

        // Active transcription engine selector row
        voiceModelPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceModelPopup.removeAllItems()
        for engine in TranscriptionEngine.allCases {
            voiceModelPopup.addItem(withTitle: loc.s(engine.localizationKey))
            voiceModelPopup.lastItem?.representedObject = engine.rawValue
        }
        voiceModelPopup.target = self
        voiceModelPopup.action = #selector(voiceModelPopupChanged(_:))
        voiceModelPopup.setAccessibilityLabel(loc.s("prefs.voice.activeModel"))

        let activeModelRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.activeModel"),
            control: voiceModelPopup,
            font: DevTypeTheme.font(12, .semibold)
        )

        let speechModelsLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.speechModels"),
            font: DevTypeTheme.font(11.5, .semibold),
            color: DevTypeTheme.textPrimary
        )
        let speechModelsInventory = makeVoiceRecognitionModelInventory()

        appleSpeechAssetButton.title = loc.s("status.checking")
        appleSpeechAssetButton.bezelStyle = .rounded
        appleSpeechAssetButton.controlSize = .small
        appleSpeechAssetButton.target = self
        appleSpeechAssetButton.action = #selector(installAppleSpeechAssets)
        appleSpeechAssetButton.translatesAutoresizingMaskIntoConstraints = false
        appleSpeechAssetButton.setAccessibilityLabel(loc.s("prefs.voice.appleAssets.install"))
        let appleAssetRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.appleAssets.label"),
            control: appleSpeechAssetButton,
            font: DevTypeTheme.font(11.5, .medium)
        )
        appleSpeechAssetRow = appleAssetRow

        let speechModelsHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.speechModels.hint"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        // Gemini API Configuration Box
        geminiConfigContainer.orientation = .vertical
        geminiConfigContainer.alignment = .leading
        geminiConfigContainer.spacing = 6
        geminiConfigContainer.translatesAutoresizingMaskIntoConstraints = false

        let initialCredential = GeminiCredentialDisplayState.resolve(GeminiAPIKeyStore.readState())
        let geminiLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.gemini.keyLabel"),
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textPrimary
        )

        geminiAPIKeyField.translatesAutoresizingMaskIntoConstraints = false
        geminiAPIKeyField.font = DevTypeTheme.font(12)
        geminiAPIKeyField.placeholderString = loc.s(initialCredential.placeholderKey)
        geminiAPIKeyField.delegate = self
        geminiAPIKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        geminiAPIKeyField.setAccessibilityLabel(loc.s("prefs.voice.gemini.keyLabel"))
        geminiAPIKeyField.setAccessibilityTitleUIElement(geminiLabel)

        let keyPill = PillBadgeView(
            text: loc.s(initialCredential.statusKey),
            tint: initialCredential.tint,
            showsDot: true
        )
        keyPill.translatesAutoresizingMaskIntoConstraints = false
        geminiKeyStatusPill = keyPill

        let saveBtn = CapsuleButton(
            title: loc.s("prefs.voice.gemini.saveValidate"),
            symbol: "key.fill",
            style: .primary,
            target: self,
            action: #selector(geminiKeySaveClicked)
        )
        geminiKeySaveButton = saveBtn

        let deleteBtn = CapsuleButton(
            title: loc.s("prefs.voice.gemini.delete"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(geminiKeyDeleteClicked)
        )
        geminiKeyDeleteButton = deleteBtn

        let geminiActionsRow = NSStackView(views: [geminiAPIKeyField, keyPill, saveBtn, deleteBtn])
        geminiActionsRow.orientation = .horizontal
        geminiActionsRow.spacing = 8
        geminiActionsRow.alignment = .centerY
        geminiActionsRow.translatesAutoresizingMaskIntoConstraints = false

        let geminiSubHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.gemini.hint"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        let cloudDisclosure = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.cloudDisclosure"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.statusOrange,
            wrapping: true
        )
        let cloudConsentRow = makeToggleRow(
            title: loc.s("prefs.voice.cloudConsent"),
            toggle: geminiCloudConsentSwitch,
            action: #selector(geminiCloudConsentChanged)
        )

        geminiConfigContainer.addArrangedSubview(geminiLabel)
        geminiConfigContainer.addArrangedSubview(geminiActionsRow)
        geminiConfigContainer.addArrangedSubview(geminiSubHint)
        geminiConfigContainer.addArrangedSubview(cloudDisclosure)
        geminiConfigContainer.addArrangedSubview(cloudConsentRow)
        cloudDisclosure.widthAnchor.constraint(equalTo: geminiConfigContainer.widthAnchor).isActive = true
        cloudConsentRow.widthAnchor.constraint(equalTo: geminiConfigContainer.widthAnchor).isActive = true

        // Local LLM Configuration Box
        localLLMConfigContainer.orientation = .vertical
        localLLMConfigContainer.alignment = .leading
        localLLMConfigContainer.spacing = 6
        localLLMConfigContainer.translatesAutoresizingMaskIntoConstraints = false

        let localEndpointLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.localLLM.endpointLabel"),
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textPrimary
        )

        localLLMEndpointField.translatesAutoresizingMaskIntoConstraints = false
        localLLMEndpointField.font = DevTypeTheme.font(12)
        localLLMEndpointField.placeholderString = "http://localhost:11434/v1/chat/completions"
        localLLMEndpointField.target = self
        localLLMEndpointField.action = #selector(localLLMEndpointChanged)
        localLLMEndpointField.delegate = self
        localLLMEndpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        localLLMEndpointField.setAccessibilityLabel(loc.s("prefs.voice.localLLM.endpointLabel"))
        localLLMEndpointField.setAccessibilityTitleUIElement(localEndpointLabel)

        let scanBtn = CapsuleButton(
            title: loc.s("prefs.voice.cleanupModels.scan"),
            symbol: "arrow.clockwise",
            style: .secondary,
            target: self,
            action: #selector(scanLocalModelsClicked)
        )
        localLLMScanButton = scanBtn

        let statusPill = PillBadgeView(
            text: loc.s("prefs.voice.localLLM.endpointStatus"),
            tint: DevTypeTheme.statusGray,
            showsDot: false
        )
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        localLLMStatusPill = statusPill

        let endpointRow = NSStackView(views: [localLLMEndpointField, scanBtn, statusPill])
        endpointRow.orientation = .horizontal
        endpointRow.spacing = 8
        endpointRow.alignment = .centerY
        endpointRow.translatesAutoresizingMaskIntoConstraints = false

        let localModelLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.cleanupModels"),
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textPrimary
        )

        localLLMModelPopup.translatesAutoresizingMaskIntoConstraints = false
        localLLMModelPopup.target = self
        localLLMModelPopup.action = #selector(localLLMModelPopupChanged(_:))
        localLLMModelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        localLLMModelPopup.setAccessibilityLabel(loc.s("prefs.voice.cleanupModels"))
        localLLMModelPopup.setAccessibilityTitleUIElement(localModelLabel)

        localLLMModelField.translatesAutoresizingMaskIntoConstraints = false
        localLLMModelField.font = DevTypeTheme.font(12)
        localLLMModelField.placeholderString = loc.s("prefs.voice.localLLM.customPlaceholder")
        localLLMModelField.target = self
        localLLMModelField.action = #selector(localLLMModelChanged)
        localLLMModelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        localLLMModelField.isHidden = true
        localLLMModelField.setAccessibilityLabel(loc.s("prefs.voice.cleanupModels"))
        localLLMModelField.setAccessibilityTitleUIElement(localModelLabel)

        let modelPickerRow = NSStackView(views: [localLLMModelPopup, localLLMModelField])
        modelPickerRow.orientation = .horizontal
        modelPickerRow.spacing = 8
        modelPickerRow.alignment = .centerY
        modelPickerRow.translatesAutoresizingMaskIntoConstraints = false

        let localSubHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.cleanupModels.hint"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        localLLMConfigContainer.addArrangedSubview(localEndpointLabel)
        localLLMConfigContainer.addArrangedSubview(endpointRow)
        localLLMConfigContainer.addArrangedSubview(localModelLabel)
        localLLMConfigContainer.addArrangedSubview(modelPickerRow)
        localLLMConfigContainer.addArrangedSubview(localSubHint)

        let modelCards: [NSView] = [
            modelsHint,
            activeModelRow,
            speechModelsLabel,
            speechModelsInventory,
            appleAssetRow,
            speechModelsHint,
            DevTypeTheme.makeHairline(),
            geminiConfigContainer,
            localLLMConfigContainer
        ]
        stackInCard(modelsCard, views: modelCards)

        // 2. Smart Dictation Options Card
        let optionsCard = makeCard(title: loc.s("prefs.voice.options.card"), symbol: "sparkles")

        voiceTonePopup.translatesAutoresizingMaskIntoConstraints = false
        voiceTonePopup.removeAllItems()
        for tone in DictationTone.allCases {
            voiceTonePopup.addItem(withTitle: loc.s(tone.localizationKey))
            voiceTonePopup.lastItem?.representedObject = tone.rawValue
        }
        voiceTonePopup.target = self
        voiceTonePopup.action = #selector(voiceTonePopupChanged(_:))
        voiceTonePopup.setAccessibilityLabel(loc.s("prefs.voice.tone"))

        let toneRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.tone"),
            control: voiceTonePopup,
            font: DevTypeTheme.font(12, .semibold)
        )

        voiceLiveDeliveryPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceLiveDeliveryPopup.removeAllItems()
        for mode in VoicePreferences.LiveDeliveryMode.allCases {
            voiceLiveDeliveryPopup.addItem(withTitle: loc.s(mode.localizationKey))
            voiceLiveDeliveryPopup.lastItem?.representedObject = mode.rawValue
        }
        voiceLiveDeliveryPopup.target = self
        voiceLiveDeliveryPopup.action = #selector(voiceLiveDeliveryModeChanged(_:))
        voiceLiveDeliveryPopup.setAccessibilityLabel(loc.s("prefs.voice.liveDelivery"))
        let realTimeTypingRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.liveDelivery"),
            control: voiceLiveDeliveryPopup,
            font: DevTypeTheme.font(12, .semibold)
        )
        let disfluencyRow = makeToggleRow(
            title: loc.s("prefs.voice.removeDisfluencies"),
            toggle: voiceDisfluenciesSwitch,
            action: #selector(voiceDisfluenciesChanged)
        )
        let autoPunctuateRow = makeToggleRow(
            title: loc.s("prefs.voice.autoPunctuate"),
            toggle: voiceAutoPunctuateSwitch,
            action: #selector(voiceAutoPunctuateChanged)
        )
        let soundFeedbackRow = makeToggleRow(
            title: loc.s("prefs.voice.soundFeedback"),
            toggle: voiceSoundFeedbackSwitch,
            action: #selector(voiceSoundFeedbackChanged)
        )
        let proofreadRow = makeToggleRow(
            title: loc.s("prefs.voice.proofreadBeforeInsert"),
            toggle: voiceProofreadSwitch,
            action: #selector(voiceProofreadChanged)
        )

        // Diagnostics. Off by default and last in the card, because switching it on starts
        // recording what the user dictates — it exists to capture a problem, not to run.
        let tracingRow = makeToggleRow(
            title: loc.s("prefs.voice.tracing"),
            toggle: voiceTracingSwitch,
            action: #selector(voiceTracingChanged)
        )
        // Local Whisper server control. Placed with the other voice controls rather than
        // buried in a sheet: it is something the user starts before dictating and stops
        // afterwards, not a one-time setup step.
        whisperServerButton.title = loc.s("prefs.voice.whisper.start")
        whisperServerButton.bezelStyle = .rounded
        whisperServerButton.controlSize = .small
        whisperServerButton.target = self
        whisperServerButton.action = #selector(toggleWhisperServer)
        whisperServerButton.translatesAutoresizingMaskIntoConstraints = false

        whisperModelButton.title = loc.s("prefs.voice.whisper.getModel")
        whisperModelButton.bezelStyle = .rounded
        whisperModelButton.controlSize = .small
        whisperModelButton.target = self
        whisperModelButton.action = #selector(downloadWhisperModel)
        whisperModelButton.translatesAutoresizingMaskIntoConstraints = false

        let whisperRow = PreferenceRowView()
        whisperRow.translatesAutoresizingMaskIntoConstraints = false
        let whisperLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.whisper.server"),
            font: DevTypeTheme.font(12.5, .medium),
            color: DevTypeTheme.textPrimary,
            wrapping: true
        )
        whisperLabel.translatesAutoresizingMaskIntoConstraints = false
        whisperRow.addSubview(whisperLabel)
        whisperRow.addSubview(whisperModelButton)
        whisperRow.addSubview(whisperServerButton)
        NSLayoutConstraint.activate([
            whisperLabel.leadingAnchor.constraint(equalTo: whisperRow.leadingAnchor),
            whisperLabel.centerYAnchor.constraint(equalTo: whisperRow.centerYAnchor),
            whisperLabel.trailingAnchor.constraint(lessThanOrEqualTo: whisperModelButton.leadingAnchor, constant: -12),
            whisperModelButton.trailingAnchor.constraint(equalTo: whisperServerButton.leadingAnchor, constant: -8),
            whisperModelButton.centerYAnchor.constraint(equalTo: whisperRow.centerYAnchor),
            whisperServerButton.trailingAnchor.constraint(equalTo: whisperRow.trailingAnchor),
            whisperServerButton.topAnchor.constraint(equalTo: whisperRow.topAnchor, constant: 2),
            whisperServerButton.bottomAnchor.constraint(equalTo: whisperRow.bottomAnchor, constant: -2)
        ])

        let revealTraceButton = NSButton(
            title: loc.s("prefs.voice.tracing.reveal"),
            target: self,
            action: #selector(revealVoiceTrace)
        )
        revealTraceButton.bezelStyle = .rounded
        revealTraceButton.controlSize = .small
        revealTraceButton.translatesAutoresizingMaskIntoConstraints = false

        let deleteTraceButton = NSButton(
            title: loc.s("prefs.voice.tracing.delete"),
            target: self,
            action: #selector(deleteVoiceTrace)
        )
        deleteTraceButton.bezelStyle = .rounded
        deleteTraceButton.controlSize = .small
        deleteTraceButton.translatesAutoresizingMaskIntoConstraints = false

        let deleteTerminalDiagnosticsButton = NSButton(
            title: loc.s("prefs.voice.terminalDiagnostics.delete"),
            target: self,
            action: #selector(deleteVoiceTerminalDiagnostics)
        )
        deleteTerminalDiagnosticsButton.bezelStyle = .rounded
        deleteTerminalDiagnosticsButton.controlSize = .small
        deleteTerminalDiagnosticsButton.translatesAutoresizingMaskIntoConstraints = false
        let terminalDiagnosticsHint = loc.s("prefs.voice.terminalDiagnostics.hint")
        deleteTerminalDiagnosticsButton.toolTip = terminalDiagnosticsHint
        deleteTerminalDiagnosticsButton.setAccessibilityHelp(terminalDiagnosticsHint)

        let revealRow = PreferenceRowView()
        revealRow.translatesAutoresizingMaskIntoConstraints = false
        revealRow.addSubview(revealTraceButton)
        revealRow.addSubview(deleteTraceButton)
        revealRow.addSubview(deleteTerminalDiagnosticsButton)
        voiceTraceStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        revealRow.addSubview(voiceTraceStatusLabel)
        NSLayoutConstraint.activate([
            revealTraceButton.leadingAnchor.constraint(equalTo: revealRow.leadingAnchor),
            revealTraceButton.topAnchor.constraint(equalTo: revealRow.topAnchor, constant: 2),
            deleteTraceButton.leadingAnchor.constraint(equalTo: revealTraceButton.trailingAnchor, constant: 8),
            deleteTraceButton.centerYAnchor.constraint(equalTo: revealTraceButton.centerYAnchor),
            deleteTerminalDiagnosticsButton.leadingAnchor.constraint(
                equalTo: deleteTraceButton.trailingAnchor,
                constant: 8
            ),
            deleteTerminalDiagnosticsButton.centerYAnchor.constraint(equalTo: revealTraceButton.centerYAnchor),
            deleteTerminalDiagnosticsButton.trailingAnchor.constraint(lessThanOrEqualTo: revealRow.trailingAnchor),
            voiceTraceStatusLabel.leadingAnchor.constraint(equalTo: revealRow.leadingAnchor),
            voiceTraceStatusLabel.trailingAnchor.constraint(equalTo: revealRow.trailingAnchor),
            voiceTraceStatusLabel.topAnchor.constraint(equalTo: revealTraceButton.bottomAnchor, constant: 6),
            voiceTraceStatusLabel.bottomAnchor.constraint(equalTo: revealRow.bottomAnchor, constant: -2)
        ])

        stackInCard(optionsCard, views: [
            toneRow, realTimeTypingRow, disfluencyRow, autoPunctuateRow, proofreadRow,
            soundFeedbackRow, whisperRow, tracingRow, revealRow
        ])
        // 3. Hotkey Card
        let hotkeyCard = makeCard(title: loc.s("prefs.voice.hotkey.card"), symbol: "keyboard")
        let hotkeyHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.hotkey.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false

        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.voiceShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyVoiceShortcut(shortcut)
        }
        voiceShortcutRecorder = recorder

        let resetButton = CapsuleButton(
            title: loc.s("prefs.voice.hotkey.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetVoiceShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(hotkeyCard, views: [hotkeyHint, recorderRow])

        // 4. Custom Dictionary Card
        let dictCard = makeCard(title: loc.s("prefs.voice.dict.card"), symbol: "text.badge.plus")
        let dictHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.dict.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        dictHint.translatesAutoresizingMaskIntoConstraints = false

        let dictionaryArea = makeTableArea(
            table: voiceDictionaryTable,
            accessibilityLabel: loc.s("prefs.voice.dict.card"),
            columnIdentifier: "voiceDictSpoken",
            emptyLabel: voiceDictionaryEmptyLabel
        )
        configureVoiceDictionaryTable()

        voiceDictSpokenField.translatesAutoresizingMaskIntoConstraints = false
        voiceDictSpokenField.placeholderString = loc.s("prefs.voice.dict.spokenPlaceholder")
        voiceDictSpokenField.font = DevTypeTheme.font(12)
        voiceDictSpokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        voiceDictSpokenField.setAccessibilityLabel(loc.s("prefs.voice.dict.column.spoken"))

        voiceDictReplacementField.translatesAutoresizingMaskIntoConstraints = false
        voiceDictReplacementField.placeholderString = loc.s("prefs.voice.dict.replacementPlaceholder")
        voiceDictReplacementField.font = DevTypeTheme.font(12)
        voiceDictReplacementField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        voiceDictReplacementField.setAccessibilityLabel(loc.s("prefs.voice.dict.column.replacement"))

        let addDictionaryButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(voiceDictAddEntry)
        )
        let removeDictionaryButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(voiceDictRemoveEntry)
        )
        bindRemovalButton(removeDictionaryButton, to: voiceDictionaryTable)
        let dictButtons = NSStackView(views: [
            voiceDictSpokenField,
            voiceDictReplacementField,
            addDictionaryButton,
            removeDictionaryButton
        ])
        dictButtons.orientation = .horizontal
        dictButtons.spacing = 8
        dictButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(dictCard, views: [dictHint, dictionaryArea, dictButtons])

        // 5. AI Voice Triggers & Rewrites Card
        let triggersCard = makeCard(title: loc.s("prefs.voice.triggers.card"), symbol: "wand.and.stars")

        let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.accent, showsDot: true)
        disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

        let disclaimerText = DevTypeTheme.makeLabel(
            loc.s("ai.availability.requirement"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        disclaimerText.translatesAutoresizingMaskIntoConstraints = false

        let disclaimerBox = NSStackView(views: [disclaimerPill, disclaimerText])
        disclaimerBox.orientation = .vertical
        disclaimerBox.alignment = .leading
        disclaimerBox.spacing = 3
        disclaimerBox.translatesAutoresizingMaskIntoConstraints = false

        let triggersHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.triggers.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        triggersHint.translatesAutoresizingMaskIntoConstraints = false

        let triggersArea = makeTableArea(
            table: voiceTriggersTable,
            accessibilityLabel: loc.s("prefs.voice.triggers.card"),
            columnIdentifier: "voiceTriggerPhrase",
            emptyLabel: voiceTriggersEmptyLabel,
            height: 120
        )
        configureVoiceTriggersTable()

        voiceTriggerPhraseField.translatesAutoresizingMaskIntoConstraints = false
        voiceTriggerPhraseField.placeholderString = loc.s("prefs.voice.triggers.phrasePlaceholder")
        voiceTriggerPhraseField.font = DevTypeTheme.font(12)
        voiceTriggerPhraseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        voiceTriggerPhraseField.setAccessibilityLabel(loc.s("prefs.voice.triggers.column.phrase"))

        voiceTriggerActionPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceTriggerActionPopup.removeAllItems()
        for kind in AITransformKind.builtInPalette {
            voiceTriggerActionPopup.addItem(withTitle: loc.s(kind.localizationKey))
            voiceTriggerActionPopup.lastItem?.representedObject = kind.rawValue
        }
        voiceTriggerActionPopup.setAccessibilityLabel(loc.s("prefs.voice.triggers.column.action"))

        let addTriggerButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(voiceTriggerAddEntry)
        )
        let removeTriggerButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(voiceTriggerRemoveEntry)
        )
        bindRemovalButton(removeTriggerButton, to: voiceTriggersTable)
        let triggerControls = NSStackView(views: [
            voiceTriggerPhraseField,
            voiceTriggerActionPopup,
            addTriggerButton,
            removeTriggerButton
        ])
        triggerControls.orientation = .horizontal
        triggerControls.spacing = 8
        triggerControls.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(triggersCard, views: [disclaimerBox, triggersHint, triggersArea, triggerControls])

        for card in [permCard, modelsCard, optionsCard, hotkeyCard, dictCard, triggersCard] {
            stack.addArrangedSubview(card)
        }
        pinWidth(of: [permCard, modelsCard, optionsCard, hotkeyCard, dictCard, triggersCard], to: stack)
    }

    private func configureVoiceDictionaryTable() {
        guard let spokenColumn = voiceDictionaryTable.tableColumns.first else { return }
        spokenColumn.title = loc.s("prefs.voice.dict.column.spoken")
        spokenColumn.minWidth = 160
        spokenColumn.width = 250
        spokenColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let replacementColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("voiceDictReplacement")
        )
        replacementColumn.title = loc.s("prefs.voice.dict.column.replacement")
        replacementColumn.minWidth = 160
        replacementColumn.width = 250
        replacementColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        voiceDictionaryTable.addTableColumn(replacementColumn)
        voiceDictionaryTable.headerView = NSTableHeaderView()
        voiceDictionaryTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        voiceDictionaryTable.allowsColumnReordering = false
    }

    private func configureVoiceTriggersTable() {
        guard let phraseColumn = voiceTriggersTable.tableColumns.first else { return }
        phraseColumn.title = loc.s("prefs.voice.triggers.column.phrase")
        phraseColumn.minWidth = 180
        phraseColumn.width = 260
        phraseColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let actionColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("voiceTriggerAction")
        )
        actionColumn.title = loc.s("prefs.voice.triggers.column.action")
        actionColumn.minWidth = 160
        actionColumn.width = 240
        actionColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        voiceTriggersTable.addTableColumn(actionColumn)
        voiceTriggersTable.headerView = NSTableHeaderView()
        voiceTriggersTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        voiceTriggersTable.allowsColumnReordering = false
    }

    private func makeVoiceRecognitionModelInventory() -> NSView {
        let inventory = PreferenceRowView()
        inventory.translatesAutoresizingMaskIntoConstraints = false
        inventory.wantsLayer = true
        inventory.layer?.cornerRadius = DevTypeTheme.Radius.control
        inventory.layer?.backgroundColor = DevTypeTheme.contrastOverlay(0.035).cgColor
        inventory.layer?.borderWidth = 1
        inventory.layer?.borderColor = DevTypeTheme.hairline.cgColor

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        inventory.addSubview(rows)

        for (index, engine) in voiceEngines.enumerated() {
            let presentation = voiceEngineStatus(for: engine)
            let name = DevTypeTheme.makeLabel(
                loc.s(engine.localizationKey),
                font: DevTypeTheme.font(11, .medium),
                color: DevTypeTheme.textPrimary
            )
            name.lineBreakMode = .byTruncatingTail

            let source = DevTypeTheme.makeLabel(
                loc.s(Self.sourceKey(for: engine)),
                font: DevTypeTheme.font(10.5),
                color: DevTypeTheme.textSecondary
            )
            source.widthAnchor.constraint(equalToConstant: 76).isActive = true

            let status = DevTypeTheme.makeLabel(
                presentation.text,
                font: DevTypeTheme.font(10.5, .medium),
                color: presentation.color
            )
            status.lineBreakMode = .byTruncatingTail
            status.toolTip = presentation.detail
            status.widthAnchor.constraint(greaterThanOrEqualToConstant: 176).isActive = true
            voiceEngineStatusLabels[engine] = status

            let row = NSStackView(views: [name, source, status])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true
            row.setAccessibilityLabel("\(name.stringValue), \(source.stringValue), \(status.stringValue)")
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            status.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true

            if index < voiceEngines.count - 1 {
                let separator = DevTypeTheme.makeHairline()
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: inventory.topAnchor, constant: 2),
            rows.leadingAnchor.constraint(equalTo: inventory.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: inventory.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: inventory.bottomAnchor, constant: -2)
        ])
        return inventory
    }

    private func reloadVoice() {
        guard panes[.voice] != nil else { return }

        let micStatus = DurableVoiceCapture.microphonePermissionStatus()
        let micPresentation = voicePermissionPresentation(for: micStatus)
        voiceMicPermissionPill?.update(
            text: micPresentation.text,
            tint: micPresentation.color
        )

        let speechAuthorization = SpeechAuthorization.status()
        let speechPresentation = voicePermissionPresentation(for: speechAuthorization)
        voiceSpeechPermissionPill?.update(
            text: speechPresentation.text,
            tint: speechPresentation.color
        )

        let currentEngine = VoicePreferences.transcriptionEngine
        if let index = TranscriptionEngine.allCases.firstIndex(of: currentEngine) {
            voiceModelPopup.selectItem(at: index)
        }

        refreshGeminiCredentialPresentation()
        geminiCloudConsentSwitch.state = VoicePreferences.hasCloudAudioConsent ? .on : .off

        // A previous capability result may be stale after a locale/TCC/system-resource change.
        // Show Checking until this refresh's probe earns Ready again.
        appleSpeechReadiness = nil
        localAICorrectionProviderID = nil
        whisperReadinessState = nil
        whisperModelStatus = nil
        for engine in voiceEngines {
            let presentation = voiceEngineStatus(
                for: engine,
                speechAuthorization: speechAuthorization
            )
            voiceEngineStatusLabels[engine]?.stringValue = presentation.text
            voiceEngineStatusLabels[engine]?.textColor = presentation.color
            voiceEngineStatusLabels[engine]?.toolTip = presentation.detail
            voiceEngineStatusLabels[engine]?.setAccessibilityLabel(presentation.text)
        }
        refreshAppleSpeechReadiness()
        refreshWhisperReadiness()

        geminiConfigContainer.isHidden = currentEngine != .gemini
        localLLMConfigContainer.isHidden = currentEngine != .localLLM

        if localLLMEndpointField.stringValue.isEmpty {
            localLLMEndpointField.stringValue = VoicePreferences.localLLMEndpoint.absoluteString
        }
        refreshLocalLLMModelsPopup()

        let currentTone = VoicePreferences.tone
        if let index = DictationTone.allCases.firstIndex(of: currentTone) {
            voiceTonePopup.selectItem(at: index)
        }

        if let index = VoicePreferences.LiveDeliveryMode.allCases
            .firstIndex(of: VoicePreferences.liveDeliveryMode) {
            voiceLiveDeliveryPopup.selectItem(at: index)
        }
        let traceRecorder = VoiceDiagnosticsRecorder.shared
        voiceTracingSwitch.state = traceRecorder.isEnabled ? .on : .off
        let traceHealth = traceRecorder.ioHealth
        if case .failed = traceHealth.terminalDelete {
            updateVoiceTraceStatus(
                "prefs.voice.terminalDiagnostics.status.deleteFailed",
                warning: true
            )
        } else if case .failed = traceHealth.delete {
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
        } else if traceRecorder.isEnabled, case .failed = traceHealth.write {
            updateVoiceTraceStatus("prefs.voice.tracing.status.incomplete", warning: true)
        } else {
            updateVoiceTraceStatus(
                traceRecorder.isEnabled
                    ? "prefs.voice.tracing.status.on"
                    : "prefs.voice.tracing.status.off",
                warning: false
            )
        }
        voiceProofreadSwitch.state = VoicePreferences.isProofreadBeforeInsertEnabled ? .on : .off
        voiceAutoPunctuateSwitch.state = VoicePreferences.isAutoPunctuateEnabled ? .on : .off
        voiceDisfluenciesSwitch.state = VoicePreferences.isRemoveDisfluenciesEnabled ? .on : .off
        voiceSoundFeedbackSwitch.state = VoicePreferences.isSoundFeedbackEnabled ? .on : .off

        voiceShortcutRecorder?.setShortcut(HotkeyPreferences.voiceShortcut)

        let dict = VoicePreferences.customDictionary
        voiceDictEntries = dict.map { (spoken: $0.key, replacement: $0.value) }.sorted { $0.spoken < $1.spoken }
        voiceDictionaryTable.reloadData()
        voiceDictionaryEmptyLabel.stringValue = voiceDictEntries.isEmpty ? loc.s("prefs.voice.dict.empty") : ""
        voiceDictionaryEmptyLabel.isHidden = !voiceDictEntries.isEmpty
        refreshRemovalButton(for: voiceDictionaryTable)

        let triggers = VoicePreferences.customVoiceTriggers
        voiceTriggerEntries = triggers.map { (phrase: $0.key, action: $0.value) }.sorted { $0.phrase < $1.phrase }
        voiceTriggersTable.reloadData()
        voiceTriggersEmptyLabel.stringValue = voiceTriggerEntries.isEmpty ? loc.s("prefs.voice.triggers.empty") : ""
        voiceTriggersEmptyLabel.isHidden = !voiceTriggerEntries.isEmpty
        refreshRemovalButton(for: voiceTriggersTable)
    }

    /// Reflects who owns the running server, if anyone. Three states, because they need
    /// three different actions: ours (stop it), someone else's (leave it alone), none
    /// (start one).
    private func refreshWhisperReadiness() {
        let endpoint = VoicePreferences.whisperEndpoint
        let request = whisperReadinessRefresh.begin(endpoint: endpoint)
        whisperReadinessTask?.cancel()
        whisperReadinessState = nil
        whisperModelStatus = nil
        applyWhisperReadinessPresentation()

        whisperReadinessTask = Task { [weak self] in
            async let state = WhisperServerSetup.detect(endpoint: endpoint)
            async let modelStatus = WhisperServerSetup.inspectModel()
            let (resolvedState, resolvedModelStatus) = await (state, modelStatus)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.whisperReadinessRefresh.claim(
                          request,
                          currentEndpoint: VoicePreferences.whisperEndpoint
                      ) else { return }
                self.whisperReadinessState = resolvedState
                self.whisperModelStatus = resolvedModelStatus
                self.whisperReadinessTask = nil
                self.applyWhisperReadinessPresentation()
            }
        }
    }

    private func applyWhisperReadinessPresentation() {
        let presentation = WhisperReadinessPresentation.resolve(
            setupState: whisperReadinessState,
            isManagedByApp: WhisperServerController.shared.isManagedByApp,
            hasLocalModel: whisperModelStatus?.isVerified == true
        )
        let controls = WhisperControlsPresentation.resolve(
            readiness: presentation,
            activeAction: whisperActionLifecycle.activeAction
        )
        let tint: NSColor
        switch presentation.tintRole {
        case .checking: tint = DevTypeTheme.statusGray
        case .ready: tint = DevTypeTheme.statusGreen
        case .attention: tint = DevTypeTheme.statusOrange
        }
        let detail = presentation.detailState.map {
            WhisperServerSetup.pendingCommands(
                for: $0,
                modelStatus: whisperModelStatus,
                endpoint: VoicePreferences.whisperEndpoint
            )
        }
        let statusText = loc.s(presentation.statusKey)
        voiceEngineStatusLabels[.whisperLocal]?.stringValue = statusText
        voiceEngineStatusLabels[.whisperLocal]?.textColor = tint
        voiceEngineStatusLabels[.whisperLocal]?.toolTip = detail
        voiceEngineStatusLabels[.whisperLocal]?.setAccessibilityLabel(statusText)
        whisperServerButton.title = loc.s(controls.serverButtonTitleKey)
        whisperServerButton.isEnabled = controls.isServerButtonEnabled
        whisperModelButton.isHidden = controls.isModelButtonHidden
        whisperModelButton.isEnabled = controls.isModelButtonEnabled
        if let modelButtonTitleKey = controls.modelButtonTitleKey {
            whisperModelButton.title = loc.s(modelButtonTitleKey)
        }
    }

    @objc private func downloadWhisperModel() {
        guard let request = whisperActionLifecycle.begin(.modelDownload) else { return }
        whisperModelButton.isEnabled = false
        whisperModelButton.title = loc.s("prefs.voice.whisper.downloading")

        let controller = WhisperServerController.shared
        whisperModelDownloadTask = Task { @MainActor [weak self] in
            let result = await controller.downloadModel { [weak self] fraction in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.whisperActionLifecycle.allowsProgress(request) else { return }
                    self.whisperModelButton.title = "\(Int(fraction * 100))%"
                }
            }
            guard !Task.isCancelled,
                  let self,
                  self.whisperActionLifecycle.claimCompletion(request) else { return }
            self.whisperModelDownloadTask = nil
            defer { self.onLocalizationBlockingOperationDidEnd?() }
            switch result {
            case .success:
                break
            case .failure(let failure):
                DevTypeAlert.warn(
                    title: self.loc.s("prefs.voice.whisper.modelFailed"),
                    message: failure.userMessage,
                    window: self.view.window
                )
            }
            self.refreshWhisperReadiness()
        }
    }

    @objc private func toggleWhisperServer() {
        let controller = WhisperServerController.shared
        switch WhisperServerToggleDecision.resolve(
            activeAction: whisperActionLifecycle.activeAction,
            isManagedByApp: controller.isManagedByApp
        ) {
        case .cancelPendingStart:
            cancelPendingWhisperServerStart()
            controller.stop()
            refreshWhisperReadiness()
            return
        case .ignoreWhileDownloading:
            return
        case .stopManagedServer:
            controller.stop()
            refreshWhisperReadiness()
            return
        case .startServer:
            break
        }

        guard let request = whisperActionLifecycle.begin(.serverStart) else { return }
        applyWhisperReadinessPresentation()

        whisperServerStartTask = Task { @MainActor [weak self] in
            let result = await controller.start()
            guard !Task.isCancelled,
                  let self,
                  self.whisperActionLifecycle.claimCompletion(request) else { return }
            self.whisperServerStartTask = nil
            defer { self.onLocalizationBlockingOperationDidEnd?() }
            switch result {
            case .success:
                break
            case .failure(let failure):
                DevTypeAlert.warn(
                    title: self.loc.s("prefs.voice.whisper.failed"),
                    message: failure.userMessage,
                    window: self.view.window
                )
            }
            self.refreshWhisperReadiness()
        }
    }

    private func cancelPendingWhisperServerStart() {
        whisperServerStartTask?.cancel()
        whisperServerStartTask = nil
        if whisperActionLifecycle.cancel(.serverStart) {
            onLocalizationBlockingOperationDidEnd?()
        }
    }

    private func invalidateWhisperActions() {
        let hadActiveAction = whisperActionLifecycle.activeAction != nil
        whisperModelDownloadTask?.cancel()
        whisperModelDownloadTask = nil
        whisperServerStartTask?.cancel()
        whisperServerStartTask = nil
        whisperActionLifecycle.invalidate()
        if hadActiveAction {
            onLocalizationBlockingOperationDidEnd?()
        }
    }

    @objc private func voiceProofreadChanged() {
        VoicePreferences.isProofreadBeforeInsertEnabled = voiceProofreadSwitch.state == .on
    }

    private func updateVoiceTraceStatus(_ key: String, warning: Bool) {
        voiceTraceStatusLabel.stringValue = loc.s(key)
        voiceTraceStatusLabel.textColor = warning ? DevTypeTheme.statusOrange : DevTypeTheme.textTertiary
    }

    private func presentVoiceDiagnosticsFailure(
        titleKey: String,
        messageKey: String,
        action: String,
        failure: VoiceDiagnosticsRecorder.IOFailure?
    ) {
        DevTypeLog.voice.error(
            "[VoiceDiagnostics] preferences action=\(action, privacy: .public) failure=\(failure?.rawValue ?? "notAttempted", privacy: .public)"
        )
        DevTypeAlert.warn(
            title: loc.s(titleKey),
            message: loc.s(messageKey),
            window: view.window
        )
    }

    @objc private func deleteVoiceTrace() {
        let recorder = VoiceDiagnosticsRecorder.shared
        switch recorder.deleteTrace() {
        case .succeeded:
            updateVoiceTraceStatus(
                recorder.isEnabled
                    ? "prefs.voice.tracing.status.deletedCapturing"
                    : "prefs.voice.tracing.status.deleted",
                warning: false
            )
        case .failed(let failure):
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.deleteFailed.title",
                messageKey: "prefs.voice.tracing.deleteFailed.message",
                action: "delete",
                failure: failure
            )
        case .notAttempted:
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.deleteFailed.title",
                messageKey: "prefs.voice.tracing.deleteFailed.message",
                action: "delete",
                failure: nil
            )
        }
    }

    @objc private func deleteVoiceTerminalDiagnostics() {
        let presentation = VoiceTerminalDiagnosticsDeletionPresentation.perform {
            VoiceDiagnosticsRecorder.shared.deleteTerminalDiagnostics()
        }
        updateVoiceTraceStatus(presentation.statusKey, warning: presentation.isWarning)
        guard let titleKey = presentation.alertTitleKey,
              let messageKey = presentation.alertMessageKey else {
            DevTypeLog.voice.info(
                "[VoiceDiagnostics] preferences action=delete-terminal outcome=succeeded"
            )
            return
        }
        presentVoiceDiagnosticsFailure(
            titleKey: titleKey,
            messageKey: messageKey,
            action: "delete-terminal",
            failure: presentation.failure
        )
    }

    @objc private func voiceTracingChanged() {
        let recorder = VoiceDiagnosticsRecorder.shared
        if voiceTracingSwitch.state == .on {
            // Keep acceptance off until the previous trace is definitely gone. Otherwise a failed
            // delete silently mixes old dictated text into what the UI calls a fresh capture.
            recorder.isEnabled = false
            switch recorder.deleteTrace() {
            case .succeeded:
                recorder.isEnabled = true
                updateVoiceTraceStatus("prefs.voice.tracing.status.on", warning: false)
            case .failed(let failure):
                recorder.isEnabled = false
                voiceTracingSwitch.state = .off
                updateVoiceTraceStatus("prefs.voice.tracing.status.startFailed", warning: true)
                presentVoiceDiagnosticsFailure(
                    titleKey: "prefs.voice.tracing.startFailed.title",
                    messageKey: "prefs.voice.tracing.startFailed.message",
                    action: "enable",
                    failure: failure
                )
            case .notAttempted:
                recorder.isEnabled = false
                voiceTracingSwitch.state = .off
                updateVoiceTraceStatus("prefs.voice.tracing.status.startFailed", warning: true)
                presentVoiceDiagnosticsFailure(
                    titleKey: "prefs.voice.tracing.startFailed.title",
                    messageKey: "prefs.voice.tracing.startFailed.message",
                    action: "enable",
                    failure: nil
                )
            }
            return
        }

        // This operation first blocks new submissions, drains accepted writes, and then deletes.
        // A failed delete still leaves tracing off; the warning is about retained local data only.
        switch recorder.disableAndDelete() {
        case .succeeded:
            updateVoiceTraceStatus("prefs.voice.tracing.status.off", warning: false)
        case .failed(let failure):
            voiceTracingSwitch.state = .off
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.disableDeleteFailed.title",
                messageKey: "prefs.voice.tracing.disableDeleteFailed.message",
                action: "disable",
                failure: failure
            )
        case .notAttempted:
            voiceTracingSwitch.state = .off
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.disableDeleteFailed.title",
                messageKey: "prefs.voice.tracing.disableDeleteFailed.message",
                action: "disable",
                failure: nil
            )
        }
    }

    @objc private func revealVoiceTrace() {
        let recorder = VoiceDiagnosticsRecorder.shared
        // read() is a queue barrier: it waits for every accepted append before the file is opened.
        let trace = recorder.read()
        let health = recorder.ioHealth
        switch health.read {
        case .failed(let failure):
            updateVoiceTraceStatus("prefs.voice.tracing.status.readFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.readFailed.title",
                messageKey: "prefs.voice.tracing.readFailed.message",
                action: "reveal",
                failure: failure
            )
            return
        case .notAttempted:
            updateVoiceTraceStatus("prefs.voice.tracing.status.readFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.readFailed.title",
                messageKey: "prefs.voice.tracing.readFailed.message",
                action: "reveal",
                failure: nil
            )
            return
        case .succeeded:
            break
        }

        guard let trace, !trace.isEmpty else {
            updateVoiceTraceStatus("prefs.voice.tracing.status.empty", warning: false)
            DevTypeAlert.info(
                title: loc.s("prefs.voice.tracing.empty.title"),
                message: loc.s("prefs.voice.tracing.empty.message"),
                window: view.window
            )
            return
        }

        if case .failed(let failure) = health.write {
            updateVoiceTraceStatus("prefs.voice.tracing.status.incomplete", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.incomplete.title",
                messageKey: "prefs.voice.tracing.incomplete.message",
                action: "reveal-incomplete",
                failure: failure
            )
        }
        let url = VoiceDiagnosticsRecorder.traceURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func voiceLiveDeliveryModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = VoicePreferences.LiveDeliveryMode(rawValue: raw) else { return }
        VoicePreferences.liveDeliveryMode = mode
    }

    @objc private func voiceTriggerAddEntry() {
        let phrase = voiceTriggerPhraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty,
              let rawAction = voiceTriggerActionPopup.selectedItem?.representedObject as? String else { return }

        VoicePreferences.addVoiceTrigger(phrase: phrase, action: rawAction)
        voiceTriggerPhraseField.stringValue = ""
        reloadVoice()
    }

    @objc private func voiceTriggerRemoveEntry() {
        let row = voiceTriggersTable.selectedRow
        guard voiceTriggerEntries.indices.contains(row) else { return }
        let entry = voiceTriggerEntries[row]
        VoicePreferences.removeVoiceTrigger(phrase: entry.phrase)
        reloadVoice()
    }

    @objc private func requestMicrophoneAccessClicked() {
        DurableVoiceCapture.requestMicrophonePermission { [weak self] _ in
            DispatchQueue.main.async {
                self?.reloadVoice()
            }
        }
    }

    @objc private func openMicrophoneSettingsClicked() {
        SettingsDeepLinker.shared.open(for: .microphone)
    }

    @objc private func requestSpeechRecognitionAccessClicked() {
        Task { [weak self] in
            _ = await SpeechAuthorization.request()
            await MainActor.run { self?.reloadVoice() }
        }
    }

    @objc private func openSpeechRecognitionSettingsClicked() {
        SettingsDeepLinker.shared.open(for: .speechRecognition)
    }

    @objc private func geminiCloudConsentChanged() {
        VoicePreferences.hasCloudAudioConsent = geminiCloudConsentSwitch.state == .on
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        reloadVoice()
    }

    @objc private func voiceModelPopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let engine = TranscriptionEngine(rawValue: raw) else { return }
        VoicePreferences.transcriptionEngine = engine
        reloadVoice()
    }

    @objc private func geminiKeySaveClicked() {
        let key = geminiAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        geminiKeyValidationTask?.cancel()
        let request = geminiKeyValidationLifecycle.begin()
        geminiKeySaveButton?.isEnabled = false
        geminiKeySaveButton?.title = loc.s("prefs.voice.gemini.validating")
        geminiKeyStatusPill?.update(
            text: loc.s("prefs.voice.gemini.validatingKey"),
            tint: DevTypeTheme.accent
        )

        geminiKeyValidationTask = Task { [weak self] in
            let result = await GeminiTranscriptionClient.shared.validateAPIKeyDetailed(key)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.geminiKeyValidationLifecycle.claim(
                          request,
                          draftMatches: self.transientValue(of: self.geminiAPIKeyField)
                              .trimmingCharacters(in: .whitespacesAndNewlines) == key
                      ) else { return }
                self.geminiKeyValidationTask = nil
                defer { self.onLocalizationBlockingOperationDidEnd?() }

                if result.isValid {
                    do {
                        try GeminiAPIKeyStore.save(key)
                        self.geminiAPIKeyField.stringValue = ""
                        self.geminiAPIKeyField.placeholderString = self.loc.s("prefs.voice.gemini.placeholder.saved")
                        self.reloadVoice()
                        let validation = GeminiValidationDisplayState.resolve(result)
                        self.geminiKeyStatusPill?.update(
                            text: self.loc.s(validation.localizationKey),
                            tint: DevTypeTheme.statusGreen
                        )
                    } catch {
                        self.presentGeminiKeychainFailure(action: .save, error: error)
                        self.finishGeminiKeyValidationControls()
                        return
                    }
                } else {
                    let validation = GeminiValidationDisplayState.resolve(result)
                    self.geminiKeyStatusPill?.update(
                        text: self.loc.s(validation.localizationKey),
                        tint: DevTypeTheme.statusOrange
                    )
                }
                self.finishGeminiKeyValidationControls()
            }
        }
    }

    @objc private func geminiKeyDeleteClicked() {
        // Delete is an explicit revocation and therefore wins over every older validation, even
        // when URLSession has already received a response and ignores task cancellation.
        invalidateGeminiKeyValidation(resetPresentation: true)
        do {
            try GeminiAPIKeyStore.delete()
            geminiAPIKeyField.stringValue = ""
            geminiAPIKeyField.placeholderString = loc.s("prefs.voice.gemini.placeholder.paste")
            reloadVoice()
        } catch {
            presentGeminiKeychainFailure(action: .delete, error: error)
        }
    }

    private func finishGeminiKeyValidationControls() {
        geminiKeySaveButton?.title = loc.s("prefs.voice.gemini.saveValidate")
        geminiKeySaveButton?.isEnabled = true
    }

    private func invalidateGeminiKeyValidation(resetPresentation: Bool) {
        let wasValidating = geminiKeyValidationLifecycle.isActive
        geminiKeyValidationTask?.cancel()
        geminiKeyValidationTask = nil
        geminiKeyValidationLifecycle.invalidate()
        if wasValidating {
            onLocalizationBlockingOperationDidEnd?()
        }
        guard resetPresentation, wasValidating else { return }
        finishGeminiKeyValidationControls()
        refreshGeminiCredentialPresentation()
    }

    private func refreshGeminiCredentialPresentation() {
        guard !geminiKeyValidationLifecycle.isActive else { return }
        let credential = GeminiCredentialDisplayState.resolve(GeminiAPIKeyStore.readState())
        geminiKeyStatusPill?.update(
            text: loc.s(credential.statusKey),
            tint: credential.tint
        )
        if geminiAPIKeyField.stringValue.isEmpty {
            geminiAPIKeyField.placeholderString = loc.s(credential.placeholderKey)
        }
    }

    private enum GeminiKeychainAction { case save, delete }

    private func presentGeminiKeychainFailure(action: GeminiKeychainAction, error: Error) {
        let nsError = error as NSError
        let titleKey: String
        let messageKey: String
        let pillKey: String
        switch action {
        case .save:
            titleKey = "prefs.voice.keychain.saveFailed.title"
            messageKey = "prefs.voice.keychain.saveFailed.message"
            pillKey = "prefs.voice.keychain.saveFailed.pill"
        case .delete:
            titleKey = "prefs.voice.keychain.deleteFailed.title"
            messageKey = "prefs.voice.keychain.deleteFailed.message"
            pillKey = "prefs.voice.keychain.deleteFailed.pill"
        }
        DevTypeLog.voice.error(
            "[Voice] Gemini Keychain operation failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
        geminiKeyStatusPill?.update(text: loc.s(pillKey), tint: DevTypeTheme.statusOrange)
        DevTypeAlert.warn(title: loc.s(titleKey), message: loc.s(messageKey), window: view.window)
    }

    @objc private func localLLMEndpointChanged() {
        invalidateLocalModelScan(resetPresentation: true)
        if commitLocalLLMEndpointField() {
            refreshLocalAIReadinessAfterConfigurationChange()
        }
    }

    @discardableResult
    private func commitLocalLLMEndpointField() -> Bool {
        let text = localLLMEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URL(string: text),
              VoicePreferences.setLocalLLMEndpoint(url) else {
            localLLMEndpointField.stringValue = VoicePreferences.localLLMEndpoint.absoluteString
            localLLMStatusPill?.update(
                text: loc.s("prefs.voice.localLLM.endpointInvalid.pill"),
                tint: DevTypeTheme.statusOrange
            )
            DevTypeAlert.warn(
                title: loc.s("prefs.voice.localLLM.endpointInvalid.title"),
                message: loc.s("prefs.voice.localLLM.endpointInvalid.message"),
                window: view.window
            )
            return false
        }
        localLLMEndpointField.stringValue = url.absoluteString
        localLLMStatusPill?.update(
            text: loc.s("prefs.voice.localLLM.endpointStatus"),
            tint: DevTypeTheme.statusGray
        )
        return true
    }

    @objc private func localLLMModelChanged() {
        let text = localLLMModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            VoicePreferences.localLLMModel = text
            refreshLocalAIReadinessAfterConfigurationChange()
        }
    }

    @objc private func localLLMModelPopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        if raw == "__custom__" {
            localLLMModelField.isHidden = false
            localLLMModelField.stringValue = VoicePreferences.localLLMModel
        } else {
            localLLMModelField.isHidden = true
            VoicePreferences.localLLMModel = raw
            localLLMModelField.stringValue = raw
            refreshLocalAIReadinessAfterConfigurationChange()
        }
    }

    private func refreshLocalAIReadinessAfterConfigurationChange() {
        localAICorrectionProviderID = nil
        let presentation = voiceEngineStatus(for: .localLLM)
        voiceEngineStatusLabels[.localLLM]?.stringValue = presentation.text
        voiceEngineStatusLabels[.localLLM]?.textColor = presentation.color
        voiceEngineStatusLabels[.localLLM]?.toolTip = presentation.detail
        voiceEngineStatusLabels[.localLLM]?.setAccessibilityLabel(presentation.text)
        refreshAppleSpeechReadiness()
    }

    @objc private func scanLocalModelsClicked() {
        guard commitLocalLLMEndpointField() else { return }
        localLLMScanButton?.isEnabled = false
        localLLMScanButton?.title = loc.s("prefs.voice.cleanupModels.scanning")
        localLLMStatusPill?.update(
            text: loc.s("prefs.voice.cleanupModels.scanning"),
            tint: DevTypeTheme.accent
        )

        let endpoint = VoicePreferences.localLLMEndpoint
        let request = localModelScanRefresh.begin(endpoint: endpoint)
        localModelScanTask?.cancel()
        localModelScanTask = Task { [weak self] in
            let discovered = await LocalLLMModelCatalog.shared.fetchAvailableLocalModels(endpoint: endpoint)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.localModelScanRefresh.claim(
                          request,
                          currentEndpoint: VoicePreferences.localLLMEndpoint
                      ) else { return }
                self.localModelScanTask = nil
                self.localLLMScanButton?.isEnabled = true
                self.localLLMScanButton?.title = self.loc.s("prefs.voice.cleanupModels.scan")
                if discovered.isEmpty {
                    self.localLLMStatusPill?.update(
                        text: self.loc.s("prefs.voice.cleanupModels.none"),
                        tint: DevTypeTheme.statusOrange
                    )
                } else {
                    self.localLLMStatusPill?.update(
                        text: self.loc.s("prefs.voice.cleanupModels.found", discovered.count),
                        tint: DevTypeTheme.statusGreen
                    )
                }
                self.refreshLocalLLMModelsPopup(additionalDiscoveredModels: discovered)
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === geminiAPIKeyField {
            // Editing the submitted draft is a newer user action. Cancellation is advisory; the
            // generation gate is what prevents the old response from saving or repainting later.
            invalidateGeminiKeyValidation(resetPresentation: true)
        } else if field === localLLMEndpointField {
            invalidateLocalModelScan(resetPresentation: true)
        }
    }

    private func invalidateLocalModelScan(resetPresentation: Bool) {
        localModelScanTask?.cancel()
        localModelScanTask = nil
        localModelScanRefresh.invalidate()
        guard resetPresentation else { return }
        localLLMScanButton?.isEnabled = true
        localLLMScanButton?.title = loc.s("prefs.voice.cleanupModels.scan")
        localLLMStatusPill?.update(
            text: loc.s("prefs.voice.localLLM.endpointStatus"),
            tint: DevTypeTheme.statusGray
        )
    }

    private func refreshLocalLLMModelsPopup(additionalDiscoveredModels: [String] = []) {
        let currentSelectedModel = VoicePreferences.localLLMModel
        localLLMModelPopup.removeAllItems()

        // 1. Preset recommended models
        let presets: [(title: String, id: String)] = [
            (loc.s("prefs.voice.localLLM.fastRecommended", "Llama 3.2"), "llama3.2"),
            (loc.s("prefs.voice.localLLM.ultraFast", "Llama 3.2 1B"), "llama3.2:1b"),
            ("Qwen 2.5 (3B)", "qwen2.5:3b"),
            ("Qwen 2.5 (7B)", "qwen2.5:7b"),
            ("Phi-3.5 (3.8B)", "phi3.5"),
            ("Mistral (7B)", "mistral"),
            ("Gemma 2 (2B)", "gemma2:2b"),
            ("DeepSeek R1 (1.5B)", "deepseek-r1:1.5b"),
            ("DeepSeek R1 (7B)", "deepseek-r1:7b")
        ]

        for p in presets {
            localLLMModelPopup.addItem(withTitle: p.title)
            localLLMModelPopup.lastItem?.representedObject = p.id
        }

        // 2. Add dynamically discovered models from Ollama / LM Studio (if not already in presets)
        var addedSeparator = false
        for modelName in additionalDiscoveredModels {
            if !presets.contains(where: { $0.id == modelName }) {
                if !addedSeparator {
                    localLLMModelPopup.menu?.addItem(NSMenuItem.separator())
                    addedSeparator = true
                }
                localLLMModelPopup.addItem(withTitle: loc.s("prefs.voice.localLLM.installed", modelName))
                localLLMModelPopup.lastItem?.representedObject = modelName
            }
        }

        // 3. Custom model option
        localLLMModelPopup.menu?.addItem(NSMenuItem.separator())
        localLLMModelPopup.addItem(withTitle: loc.s("prefs.voice.localLLM.customOption"))
        localLLMModelPopup.lastItem?.representedObject = "__custom__"

        // Select the active model
        if let matchIndex = localLLMModelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == currentSelectedModel }) {
            localLLMModelPopup.selectItem(at: matchIndex)
            localLLMModelField.isHidden = true
        } else {
            // It's a custom model
            localLLMModelPopup.selectItem(at: localLLMModelPopup.numberOfItems - 1)
            localLLMModelField.isHidden = false
            localLLMModelField.stringValue = currentSelectedModel
        }
    }

    @objc private func voiceTonePopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let tone = DictationTone(rawValue: raw) else { return }
        VoicePreferences.tone = tone
    }

    @objc private func voiceAutoPunctuateChanged() {
        VoicePreferences.isAutoPunctuateEnabled = voiceAutoPunctuateSwitch.state == .on
    }

    @objc private func voiceDisfluenciesChanged() {
        VoicePreferences.isRemoveDisfluenciesEnabled = voiceDisfluenciesSwitch.state == .on
    }

    @objc private func voiceSoundFeedbackChanged() {
        VoicePreferences.isSoundFeedbackEnabled = voiceSoundFeedbackSwitch.state == .on
    }

    private func applyVoiceShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        if let manager = hotkeyManager {
            manager.applyVoiceShortcut(shortcut)
        } else {
            HotkeyPreferences.voiceShortcut = shortcut
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reloadVoice()
    }

    @objc private func resetVoiceShortcut() {
        HotkeyPreferences.resetVoiceShortcut()
        if let manager = hotkeyManager {
            manager.applyVoiceShortcut(HotkeyPreferences.voiceShortcut)
        } else {
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reloadVoice()
    }

    @objc private func voiceDictAddEntry() {
        let spoken = voiceDictSpokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = voiceDictReplacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !replacement.isEmpty else { return }

        VoicePreferences.addDictionaryEntry(spoken: spoken, replacement: replacement)
        voiceDictSpokenField.stringValue = ""
        voiceDictReplacementField.stringValue = ""
        reloadVoice()
    }

    @objc private func voiceDictRemoveEntry() {
        let row = voiceDictionaryTable.selectedRow
        guard voiceDictEntries.indices.contains(row) else { return }
        let entry = voiceDictEntries[row]
        VoicePreferences.removeDictionaryEntry(spoken: entry.spoken)
        reloadVoice()
    }

    // MARK: AI

    private func buildAI(into stack: NSStackView) {
        let featureAvailable = AITextTransformSupport.isRunningOnCompatibleOS

        if !featureAvailable {
            let unsupportedCard = makeCard(title: loc.s("prefs.tab.ai"), symbol: "sparkles")
            let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.statusOrange, showsDot: true)
            disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

            let note = DevTypeTheme.makeLabel(
                loc.s("ai.availability.requirement"),
                font: DevTypeTheme.font(11.5),
                color: DevTypeTheme.textSecondary,
                wrapping: true
            )
            note.translatesAutoresizingMaskIntoConstraints = false
            stackInCard(unsupportedCard, views: [disclaimerPill, note])
            stack.addArrangedSubview(unsupportedCard)
            pinWidth(of: [unsupportedCard], to: stack)
            return
        }

        // Enable + availability
        let enableCard = makeCard(title: loc.s("prefs.ai.enable.card"), symbol: "sparkles")
        let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.accent, showsDot: true)
        disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

        let enableRow = makeToggleRow(
            title: loc.s("prefs.ai.enable"),
            toggle: aiEnabledSwitch,
            action: #selector(aiEnabledChanged)
        )
        let privacyNote = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.privacy"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        privacyNote.translatesAutoresizingMaskIntoConstraints = false
        aiAvailabilityLabel.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(enableCard, views: [disclaimerPill, enableRow, privacyNote, aiAvailabilityLabel])

        // Palette hotkey
        let hotkeyCard = makeCard(title: loc.s("prefs.ai.hotkey"), symbol: "keyboard")
        let hotkeyHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.hotkey.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false
        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.aiPaletteShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyAIPaletteShortcut(shortcut)
        }
        aiPaletteRecorder = recorder
        let resetButton = CapsuleButton(
            title: loc.s("prefs.ai.hotkey.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetAIPaletteShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(hotkeyCard, views: [hotkeyHint, recorderRow])

        // Per-action output modes
        let modesCard = makeCard(title: loc.s("prefs.ai.outputModes"), symbol: "arrow.left.arrow.right")
        let modesHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.outputModes.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        modesHint.translatesAutoresizingMaskIntoConstraints = false
        let markdownRow = makeToggleRow(
            title: loc.s("prefs.ai.removeMarkdown"),
            toggle: aiRemoveMarkdownSwitch,
            action: #selector(aiRemoveMarkdownChanged)
        )
        let markdownHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.removeMarkdown.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        markdownHint.translatesAutoresizingMaskIntoConstraints = false
        let routingRow = makeToggleRow(
            title: loc.s("prefs.ai.semanticRouting"),
            toggle: aiSemanticRoutingSwitch,
            action: #selector(aiSemanticRoutingChanged)
        )
        let routingHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.semanticRouting.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        routingHint.translatesAutoresizingMaskIntoConstraints = false
        let tagRow = makeToggleRow(
            title: loc.s("prefs.ai.tagSuggestions"),
            toggle: aiTagSuggestionsSwitch,
            action: #selector(aiTagSuggestionsChanged)
        )
        let tagHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.tagSuggestions.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        tagHint.translatesAutoresizingMaskIntoConstraints = false
        let repetitionRow = makeToggleRow(
            title: loc.s("prefs.repetition"),
            toggle: repetitionSwitch,
            action: #selector(repetitionChanged)
        )
        let repetitionHint = DevTypeTheme.makeLabel(
            loc.s("prefs.repetition.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        repetitionHint.translatesAutoresizingMaskIntoConstraints = false
        let forgetButton = NSButton(
            title: loc.s("prefs.repetition.forget"),
            target: self,
            action: #selector(repetitionForget)
        )
        forgetButton.translatesAutoresizingMaskIntoConstraints = false
        forgetButton.bezelStyle = .rounded
        var modeRows: [NSView] = [
            modesHint, markdownRow, markdownHint, routingRow, routingHint, tagRow, tagHint,
            repetitionRow, repetitionHint, forgetButton,
        ]
        aiOutputModePopups.removeAll()
        for kind in AITransformKind.builtInPalette {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.removeAllItems()
            popup.addItem(withTitle: loc.s("prefs.ai.output.direct"))
            popup.lastItem?.representedObject = AIOutputMode.direct.rawValue
            popup.addItem(withTitle: loc.s("prefs.ai.output.preview"))
            popup.lastItem?.representedObject = AIOutputMode.preview.rawValue
            popup.target = self
            popup.action = #selector(aiOutputModeChanged(_:))
            popup.setAccessibilityLabel(loc.s(kind.localizationKey))
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            aiOutputModePopups[kind] = popup

            let row = makeLabeledControlRow(
                title: loc.s(kind.localizationKey),
                control: popup
            )
            modeRows.append(row)
        }

        // Every popup above writes a per-kind override; without this there is no way back to
        // the built-in default short of knowing which mode each kind shipped with.
        let resetModesButton = CapsuleButton(
            title: loc.s("prefs.ai.output.restoreDefaults"),
            style: .secondary,
            target: self,
            action: #selector(aiOutputModeRestoreDefaultsClicked)
        )
        resetModesButton.translatesAutoresizingMaskIntoConstraints = false
        let resetRow = NSStackView(views: [resetModesButton])
        resetRow.orientation = .horizontal
        resetRow.alignment = .centerY
        resetRow.translatesAutoresizingMaskIntoConstraints = false
        modeRows.append(resetRow)

        stackInCard(modesCard, views: modeRows)

        // Typed-path allowlist
        let allowCard = makeCard(title: loc.s("prefs.ai.allowlist"), symbol: "checkmark.seal")
        let allowHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.allowlist.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        allowHint.translatesAutoresizingMaskIntoConstraints = false

        let allowlistArea = makeTableArea(
            table: aiAllowlistTable,
            accessibilityLabel: loc.s("prefs.ai.allowlist"),
            columnIdentifier: "aiAllow",
            emptyLabel: aiAllowlistEmptyLabel,
            allowsMultipleSelection: true
        )

        aiAllowlistField.translatesAutoresizingMaskIntoConstraints = false
        aiAllowlistField.placeholderString = loc.s("prefs.ai.allowlist.bundleID")
        aiAllowlistField.font = DevTypeTheme.font(12)
        aiAllowlistField.setAccessibilityLabel(loc.s("prefs.ai.allowlist.bundleID"))
        aiAllowlistField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let addFrontmostButton = CapsuleButton(
            title: loc.s("prefs.ai.allowlist.addFrontmost"),
            symbol: "plus.app",
            style: .secondary,
            target: self,
            action: #selector(aiAllowlistAddFrontmost)
        )
        let addAllowlistButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(aiAllowlistAddTyped)
        )
        let removeAllowlistButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(aiAllowlistRemove)
        )
        bindRemovalButton(removeAllowlistButton, to: aiAllowlistTable)
        let allowButtons = NSStackView(views: [
            addFrontmostButton,
            addAllowlistButton,
            removeAllowlistButton
        ])
        allowButtons.orientation = .horizontal
        allowButtons.spacing = 8
        allowButtons.translatesAutoresizingMaskIntoConstraints = false

        let editorRow = NSStackView(views: [aiAllowlistField])
        editorRow.orientation = .horizontal
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(allowCard, views: [allowHint, allowlistArea, editorRow, allowButtons])

        for card in [enableCard, hotkeyCard, modesCard, allowCard] {
            stack.addArrangedSubview(card)
        }
        pinWidth(of: [enableCard, hotkeyCard, modesCard, allowCard], to: stack)
    }

    private func reloadAI() {
        guard panes[.ai] != nil else { return }
        aiEnabledSwitch.state = AIPreferences.isEnabled ? .on : .off
        aiRemoveMarkdownSwitch.state = AIPreferences.removesMarkdown ? .on : .off
        aiTagSuggestionsSwitch.state = SnippetTagSuggester.isEnabled ? .on : .off
        aiSemanticRoutingSwitch.state = AIPreferences.isSemanticRoutingEnabled ? .on : .off
        repetitionSwitch.state = TypedRepetitionPreferences.isActive ? .on : .off
        aiAvailabilityLabel.stringValue = loc.s(
            "prefs.ai.availability",
            loc.s(AITextTransformSupport.availability.localizationKey)
        )
        switch AITextTransformSupport.availability {
        case .available:
            aiAvailabilityLabel.textColor = DevTypeTheme.statusGreen
        case .unavailable:
            aiAvailabilityLabel.textColor = DevTypeTheme.statusOrange
        }
        aiPaletteRecorder?.setShortcut(HotkeyPreferences.aiPaletteShortcut)
        for (kind, popup) in aiOutputModePopups {
            let mode = AIPreferences.outputMode(for: kind)
            let index = mode == .direct ? 0 : 1
            popup.selectItem(at: index)
        }
        aiAllowlist = AIPreferences.typedPathAllowlist
        aiAllowlistTable.reloadData()
        aiAllowlistEmptyLabel.stringValue = aiAllowlist.isEmpty
            ? loc.s("prefs.ai.allowlist.empty")
            : ""
        aiAllowlistEmptyLabel.isHidden = !aiAllowlist.isEmpty
        refreshRemovalButton(for: aiAllowlistTable)
    }

    @objc private func aiEnabledChanged() {
        AIPreferences.isEnabled = aiEnabledSwitch.state == .on
        reloadAI()
    }

    @objc private func aiRemoveMarkdownChanged() {
        AIPreferences.removesMarkdown = aiRemoveMarkdownSwitch.state == .on
    }

    @objc private func aiTagSuggestionsChanged() {
        SnippetTagSuggester.isEnabled = aiTagSuggestionsSwitch.state == .on
    }

    @objc private func aiSemanticRoutingChanged() {
        AIPreferences.isSemanticRoutingEnabled = aiSemanticRoutingSwitch.state == .on
    }

    /// Turning this on is a consent decision, not a preference toggle, so the switch does not
    /// take effect until the prompt is confirmed — and springs back if it is not. Turning it
    /// off revokes consent and forgets everything rather than merely pausing.
    @objc private func repetitionChanged() {
        guard repetitionSwitch.state == .on else {
            TypedRepetitionPreferences.revokeConsent()
            return
        }
        if TypedRepetitionPreferences.hasCurrentConsent {
            TypedRepetitionPreferences.isEnabled = true
            return
        }
        repetitionSwitch.state = .off
        DevTypeAlert.confirm(
            title: loc.s("prefs.repetition.consent.title"),
            message: loc.s("prefs.repetition.consent.body"),
            confirmTitle: loc.s("prefs.repetition.consent.confirm"),
            cancelTitle: loc.s("common.cancel"),
            style: .informational,
            window: view.window
        ) { [weak self] in
            TypedRepetitionPreferences.grantedConsentVersion =
                TypedRepetitionPreferences.currentConsentVersion
            TypedRepetitionPreferences.isEnabled = true
            self?.repetitionSwitch.state = .on
        }
    }

    @objc private func repetitionForget() {
        TypedRepetitionDetector.shared.forgetAll()
        DevTypeAlert.info(
            title: loc.s("prefs.repetition.forget"),
            message: loc.s("prefs.repetition.forget.done"),
            window: view.window
        )
    }

    /// Clears every per-kind output-mode override so each transform falls back to the
    /// built-in default. `resetOutputMode` removes the key rather than writing a value, so
    /// a later change to a default reaches users who never touched the setting.
    @objc private func aiOutputModeRestoreDefaultsClicked() {
        for kind in AITransformKind.builtInPalette {
            AIPreferences.resetOutputMode(for: kind)
        }
        reloadAI()
    }

    @objc private func aiOutputModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = AIOutputMode(rawValue: raw) else { return }
        guard let kind = aiOutputModePopups.first(where: { $0.value === sender })?.key else { return }
        AIPreferences.setOutputMode(mode, for: kind)
    }

    private func applyAIPaletteShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        guard let manager = hotkeyManager else {
            HotkeyPreferences.aiPaletteShortcut = shortcut
            reloadAI()
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
            return
        }
        let status = manager.applyAIPaletteShortcut(shortcut)
        if status != noErr {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.failed.title"),
                message: loc.s("prefs.hotkeys.failed.message", shortcut.displayString, Int(status)),
                window: view.window
            )
        }
        reloadAI()
    }

    @objc private func resetAIPaletteShortcut() {
        HotkeyPreferences.resetAIPaletteShortcut()
        applyAIPaletteShortcut(.aiPaletteDefault)
    }

    @objc private func aiAllowlistAddFrontmost() {
        guard let bundleID = AXContextChecker.shared.frontmostApplicationBundleIdentifier(),
              !bundleID.isEmpty else {
            DevTypeAlert.warn(
                title: loc.s("alert.muteFrontmost.failed.title"),
                message: loc.s("alert.muteFrontmost.failed.message"),
                window: view.window
            )
            return
        }
        AIPreferences.addTypedPathApp(bundleID)
        reloadAI()
    }

    @objc private func aiAllowlistAddTyped() {
        let bundleID = aiAllowlistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        AIPreferences.addTypedPathApp(bundleID)
        aiAllowlistField.stringValue = ""
        reloadAI()
    }

    @objc private func aiAllowlistRemove() {
        let selected = aiAllowlistTable.selectedRowIndexes
        guard !selected.isEmpty else { return }
        let ids = selected.compactMap { aiAllowlist.indices.contains($0) ? aiAllowlist[$0] : nil }
        AIPreferences.removeTypedPathApps(ids)
        reloadAI()
    }

    // MARK: Advanced (§2.10 / §3.9 / §3.2 / §3.7 readouts)

    private func buildAdvanced(into stack: NSStackView) {
        let engineCard = makeCard(title: loc.s("prefs.advanced.engine"), symbol: "bolt.fill")
        let threadRow = makeToggleRow(
            title: loc.s("prefs.advanced.tapThread"),
            toggle: tapThreadSwitch,
            action: #selector(tapThreadChanged)
        )
        let threadHint = DevTypeTheme.makeLabel(
            loc.s("prefs.advanced.tapThread.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        threadHint.translatesAutoresizingMaskIntoConstraints = false
        advancedReadout.translatesAutoresizingMaskIntoConstraints = false
        let copyButton = CapsuleButton(
            title: loc.s("prefs.advanced.copyDiagnostics"),
            symbol: "doc.on.doc",
            style: .secondary,
            target: self,
            action: #selector(copyAdvancedDiagnostics)
        )
        stackInCard(engineCard, views: [threadRow, threadHint, advancedReadout, copyButton])

        let maintenanceCard = makeCard(title: loc.s("prefs.advanced.maintenance"), symbol: "arrow.counterclockwise")
        maintenanceStatus.translatesAutoresizingMaskIntoConstraints = false
        let retrySecretCleanupButton = CapsuleButton(
            title: loc.s("prefs.advanced.secretCleanup.retry"),
            symbol: "key",
            style: .secondary,
            target: self,
            action: #selector(retrySecretCleanup)
        )
        secretCleanupButton = retrySecretCleanupButton
        let maintenanceButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("prefs.advanced.orphans"),
                symbol: "trash",
                style: .secondary,
                target: self,
                action: #selector(collectOrphans)
            ),
            retrySecretCleanupButton,
            CapsuleButton(
                title: loc.s("prefs.advanced.reset"),
                symbol: "arrow.counterclockwise",
                style: .destructive,
                target: self,
                action: #selector(resetLibrary)
            )
        ])
        maintenanceButtons.orientation = .horizontal
        maintenanceButtons.spacing = 8
        maintenanceButtons.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(maintenanceCard, views: [maintenanceButtons, maintenanceStatus])

        stack.addArrangedSubview(engineCard)
        stack.addArrangedSubview(maintenanceCard)
        pinWidth(of: [engineCard, maintenanceCard], to: stack)
    }

    private func reloadAdvanced() {
        tapThreadSwitch.state = EventTapEngine.useDedicatedTapThread ? .on : .off
        var lines: [String] = []
        lines.append(EventTapEngine.shared.tapDisableCounters.summaryLine)
        let telemetry = PermissionCoordinator.shared.injectTelemetrySummaryLines()
        lines.append(contentsOf: telemetry)
        lines.append(EventTapEngine.shared.prefixDebounceDiagnostics())
        let overlong = EventTapEngine.shared.overlongTriggerDiagnostics()
        if overlong.isEmpty {
            lines.append(loc.s("prefs.advanced.overlong.none"))
        } else {
            lines.append(contentsOf: overlong)
        }
        advancedReadout.stringValue = lines.joined(separator: "\n")
        let cleanup = SecretCleanupMaintenancePresentation.resolve(
            pendingCount: store.pendingSecretCleanupCount,
            localization: loc
        )
        maintenanceStatus.stringValue = cleanup.text
        maintenanceStatus.textColor = cleanup.isWarning
            ? DevTypeTheme.accentBright
            : DevTypeTheme.statusGreen
    }

    @objc private func tapThreadChanged() {
        let enabled = tapThreadSwitch.state == .on
        EventTapEngine.useDedicatedTapThread = enabled
        UserDefaults.standard.set(enabled, forKey: EventTapEngine.useDedicatedTapThreadDefaultsKey)
        reloadAdvanced()
    }

    @objc private func copyAdvancedDiagnostics() {
        let didWrite = DiagnosticReport.copyToPasteboard(advancedReadout.stringValue)
        let presentation = AdvancedDiagnosticsCopyPresentation.resolve(didWrite: didWrite)
        maintenanceStatus.stringValue = loc.s(presentation.statusKey)
        maintenanceStatus.textColor = presentation.tintRole == .success
            ? DevTypeTheme.statusGreen
            : DevTypeTheme.accentBright
    }

    @objc private func collectOrphans() {
        let removed = store.collectOrphanedImages(dryRun: false)
        maintenanceStatus.stringValue = removed.isEmpty
            ? loc.s("prefs.advanced.orphans.none")
            : loc.s("prefs.advanced.orphans.result", removed.count)
        maintenanceStatus.textColor = DevTypeTheme.statusGreen
    }

    @objc private func retrySecretCleanup() {
        secretCleanupButton?.isEnabled = false
        maintenanceStatus.stringValue = loc.s("prefs.advanced.secretCleanup.running")
        maintenanceStatus.textColor = DevTypeTheme.textSecondary
        let store = self.store
        store.requestOrphanSecretCleanupRetry { [weak self] summary in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.secretCleanupButton?.isEnabled = true
                if summary.failed > 0 {
                    self.maintenanceStatus.stringValue = self.loc.s(
                        "prefs.advanced.secretCleanup.failed",
                        summary.failed
                    )
                    self.maintenanceStatus.textColor = DevTypeTheme.accentBright
                } else if summary.removed > 0 {
                    self.maintenanceStatus.stringValue = self.loc.s(
                        "prefs.advanced.secretCleanup.result",
                        summary.removed
                    )
                    self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
                } else {
                    self.maintenanceStatus.stringValue = self.loc.s(
                        "prefs.advanced.secretCleanup.none"
                    )
                    self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
                }
            }
        }
    }

    @objc private func resetLibrary() {
        DevTypeAlert.confirm(
            title: loc.s("alert.reset.title"),
            message: loc.s("alert.reset.message"),
            confirmTitle: loc.s("alert.reset.confirm"),
            destructive: true,
            window: view.window
        ) { [weak self] in
            guard let self else { return }
            let result = self.store.resetToDefaults()
            let completion = SnippetManagerMutationCommitter.finish(
                result,
                deleteImage: { path in
                    let cleanup = self.store.deleteImageIfUnreferenced(path) { candidate in
                        if case .success = SnippetEditResourceAccess.live.deleteImage(candidate) {
                            return true
                        }
                        return false
                    }
                    return cleanup == .removed || cleanup == .retainedReferenced
                }
            )
            switch completion {
            case .committed(_, let cleanupFailures):
                if cleanupFailures == 0 {
                    self.maintenanceStatus.stringValue = self.loc.s("prefs.advanced.reset.done")
                    self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
                } else {
                    self.maintenanceStatus.stringValue = self.loc.s(
                        "manager.resources.cleanupFailed.message",
                        cleanupFailures
                    )
                    self.maintenanceStatus.textColor = DevTypeTheme.accentBright
                }
            case .refused:
                LibraryHealthMonitor.shared.refresh()
                self.maintenanceStatus.stringValue = self.loc.s("library.save.banner")
                self.maintenanceStatus.textColor = DevTypeTheme.accentBright
            case .unchanged:
                self.maintenanceStatus.stringValue = self.loc.s("prefs.advanced.reset.done")
                self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
            case .stale:
                self.maintenanceStatus.stringValue = self.loc.s("manager.action.stale.message")
                self.maintenanceStatus.textColor = DevTypeTheme.accentBright
            }
            self.reloadSnippets()
        }
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === mutedTable { return mutedApps.count }
        if tableView === macroTable { return macros.count }
        if tableView === aiAllowlistTable { return aiAllowlist.count }
        if tableView === voiceDictionaryTable { return voiceDictEntries.count }
        if tableView === voiceTriggersTable { return voiceTriggerEntries.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === mutedTable {
            guard mutedApps.indices.contains(row) else { return nil }
            text = mutedApps[row]
        } else if tableView === macroTable {
            guard macros.indices.contains(row) else { return nil }
            let macro = macros[row]
            let shortcut = DevTypeShortcut(keyCode: macro.keyCode, carbonModifiers: macro.modifiers)
            let kindTitle = macro.kind == .insertText
                ? loc.s("prefs.hotkeys.macros.kind.insertText")
                : loc.s("prefs.hotkeys.macros.kind.openURL")
            text = "\(shortcut.displayString)  ·  \(kindTitle)  ·  \(macro.argument)"
        } else if tableView === aiAllowlistTable {
            guard aiAllowlist.indices.contains(row) else { return nil }
            text = aiAllowlist[row]
        } else if tableView === voiceDictionaryTable {
            guard voiceDictEntries.indices.contains(row) else { return nil }
            let entry = voiceDictEntries[row]
            switch tableColumn?.identifier.rawValue {
            case "voiceDictSpoken": text = entry.spoken
            case "voiceDictReplacement": text = entry.replacement
            default: return nil
            }
        } else if tableView === voiceTriggersTable {
            guard voiceTriggerEntries.indices.contains(row) else { return nil }
            let entry = voiceTriggerEntries[row]
            switch tableColumn?.identifier.rawValue {
            case "voiceTriggerPhrase": text = entry.phrase
            case "voiceTriggerAction": text = loc.s("ai.kind.\(entry.action)")
            default: return nil
            }
        } else {
            return nil
        }

        let columnIdentifier = tableColumn?.identifier.rawValue ?? "single"
        let identifier = NSUserInterfaceItemIdentifier("prefsRow.\(columnIdentifier)")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
        }
        label.font = (tableView === voiceDictionaryTable || tableView === voiceTriggersTable)
            ? DevTypeTheme.font(11)
            : DevTypeTheme.mono(11)
        label.stringValue = text
        label.textColor = DevTypeTheme.textPrimary
        // §5.1: rows read as their content instead of "row N".
        label.setAccessibilityLabel(text)
        return label
    }

    /// Configuration readiness for each engine.
    ///
    /// Replaces an inventory of downloadable ASR models that no engine could actually use
    /// and whose download URLs no longer resolve. This reports something the user can act
    /// on: whether the selected engine will work, and what is missing if it will not.
    private func voiceEngineStatus(
        for engine: TranscriptionEngine,
        speechAuthorization: SpeechAuthorization.Status = SpeechAuthorization.status()
    ) -> (text: String, color: NSColor, detail: String?) {
        switch engine {
        case .gemini:
            switch GeminiAPIKeyStore.readState() {
            case .unavailable:
                return (
                    loc.s("prefs.voice.keychain.unavailable.pill"),
                    DevTypeTheme.accentBright,
                    loc.s("prefs.voice.keychain.unavailable.message")
                )
            case .missing, .available(""):
                return (loc.s("prefs.voice.speechModels.status.needsKey"), DevTypeTheme.statusOrange, nil)
            case .available:
                break
            }
            return VoicePreferences.hasCloudAudioConsent
                ? (loc.s("prefs.voice.speechModels.status.ready"), DevTypeTheme.statusGreen, nil)
                : (loc.s("prefs.voice.speechModels.status.needsConsent"), DevTypeTheme.statusOrange, nil)

        case .whisperLocal:
            let state = WhisperReadinessPresentation.resolve(
                setupState: whisperReadinessState,
                isManagedByApp: WhisperServerController.shared.isManagedByApp,
                hasLocalModel: whisperModelStatus?.isVerified == true
            )
            let color: NSColor
            switch state.tintRole {
            case .checking: color = DevTypeTheme.statusGray
            case .ready: color = DevTypeTheme.statusGreen
            case .attention: color = DevTypeTheme.statusOrange
            }
            let detail = state.detailState.map {
                WhisperServerSetup.pendingCommands(
                    for: $0,
                    modelStatus: whisperModelStatus,
                    endpoint: VoicePreferences.whisperEndpoint
                )
            }
            return (loc.s(state.statusKey), color, detail)

        case .localLLM:
            let state = LocalAIReadinessDisplayState.resolve(
                authorization: speechAuthorization,
                speechReadiness: appleSpeechReadiness,
                selectedCorrectionProviderID: localAICorrectionProviderID
            )
            let color: NSColor
            switch state.tintRole {
            case .checking: color = DevTypeTheme.statusGray
            case .ready: color = DevTypeTheme.statusGreen
            case .attention: color = DevTypeTheme.statusOrange
            }
            let statusKey = state == .ready
                ? resolvedAppleSpeechStatusKey(default: state.statusKey)
                : state.statusKey
            return (loc.s(statusKey), color, nil)

        case .appleSpeech:
            let state = AppleSpeechReadinessDisplayState.resolve(
                authorization: speechAuthorization,
                providerReadiness: appleSpeechReadiness
            )
            let color: NSColor
            switch state.tintRole {
            case .checking: color = DevTypeTheme.statusGray
            case .ready: color = DevTypeTheme.statusGreen
            case .attention: color = DevTypeTheme.statusOrange
            }
            let statusKey = state == .ready
                ? resolvedAppleSpeechStatusKey(default: state.statusKey)
                : state.statusKey
            return (loc.s(statusKey), color, nil)
        }
    }

    private func refreshAppleSpeechReadiness() {
        let generation = appleSpeechReadinessRefresh.begin()
        appleSpeechReadinessTask?.cancel()
        appleSpeechReadiness = nil
        appleSpeechAnalyzerReadiness = nil
        resolvedAppleSpeechProviderID = nil
        applyAppleSpeechAssetPresentation()

        let locale = Locale.current
        let analyzer = AppleSpeechAnalyzerAdapter(locale: locale)
        let legacy = LegacyAppleSpeechAdapter(locale: locale)
        let platformSupportsAnalyzer: Bool
        if #available(macOS 26.0, *) {
            platformSupportsAnalyzer = true
        } else {
            platformSupportsAnalyzer = false
        }
        let endpoint = VoicePreferences.localLLMEndpoint
        let model = VoicePreferences.localLLMModel
        let preferAppleFoundationModels: Bool
        if #available(macOS 26.0, *) {
            preferAppleFoundationModels = true
        } else {
            preferAppleFoundationModels = false
        }
        let correctionIDs = VoiceSessionSnapshotFactory.localCorrectionProviderIDs(
            for: endpoint,
            preferAppleFoundationModels: preferAppleFoundationModels
        )
        let correctionRegistry = CorrectionProviderRegistry(providers: [
            FoundationLanguageModelCorrector(),
            OllamaCorrector(endpointURL: endpoint, modelName: model),
            OpenAICompatibleCorrector(endpointURL: endpoint, modelName: model),
            DeterministicCorrector(),
        ])
        appleSpeechReadinessTask = Task { [weak self] in
            async let analyzerProbe = analyzer.probe()
            async let legacyProbe = legacy.probe()
            async let correctionProbe = correctionRegistry.resolveActiveCorrector(
                preferredID: correctionIDs.first,
                fallbackIDs: Array(correctionIDs.dropFirst()),
                privacyRoute: .localNetworkOnly
            )
            let (analyzerReadiness, legacyReadiness, correction) = await (
                analyzerProbe,
                legacyProbe,
                correctionProbe
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.appleSpeechReadinessRefresh.claim(generation) else { return }
                let resolution = AppleSpeechPreferencesResolution.resolve(
                    platformSupportsAnalyzer: platformSupportsAnalyzer,
                    analyzerReadiness: analyzerReadiness,
                    legacyReadiness: legacyReadiness
                )
                self.appleSpeechReadiness = resolution.readiness
                self.appleSpeechAnalyzerReadiness = analyzerReadiness
                self.resolvedAppleSpeechProviderID = resolution.providerID
                self.localAICorrectionProviderID = correction?.descriptor.id
                self.appleSpeechReadinessTask = nil
                self.applyAppleSpeechAssetPresentation()
                let authorization = SpeechAuthorization.status()
                for engine in [TranscriptionEngine.localLLM, .appleSpeech] {
                    let presentation = self.voiceEngineStatus(
                        for: engine,
                        speechAuthorization: authorization
                    )
                    self.voiceEngineStatusLabels[engine]?.stringValue = presentation.text
                    self.voiceEngineStatusLabels[engine]?.textColor = presentation.color
                    self.voiceEngineStatusLabels[engine]?.toolTip = presentation.detail
                    self.voiceEngineStatusLabels[engine]?.setAccessibilityLabel(presentation.text)
                }
            }
        }
    }

    private func resolvedAppleSpeechStatusKey(default defaultKey: String) -> String {
        switch resolvedAppleSpeechProviderID {
        case VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer:
            return "prefs.voice.speechModels.status.readyAnalyzer"
        case VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy:
            return "prefs.voice.speechModels.status.readyLegacy"
        default:
            return defaultKey
        }
    }

    private var platformSupportsAppleSpeechAnalyzer: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private func applyAppleSpeechAssetPresentation() {
        let presentation = AppleSpeechAssetControlsPresentation.resolve(
            platformSupportsAnalyzer: platformSupportsAppleSpeechAnalyzer,
            analyzerReadiness: appleSpeechAnalyzerReadiness,
            isInstalling: appleSpeechAssetInstallLifecycle.isActive
        )
        appleSpeechAssetRow?.isHidden = presentation.isHidden
        appleSpeechAssetButton.title = loc.s(presentation.titleKey)
        appleSpeechAssetButton.isEnabled = presentation.isEnabled
        appleSpeechAssetButton.setAccessibilityLabel(loc.s(presentation.titleKey))
    }

    @objc private func installAppleSpeechAssets() {
        guard platformSupportsAppleSpeechAnalyzer,
              let request = appleSpeechAssetInstallLifecycle.begin() else { return }
        applyAppleSpeechAssetPresentation()

        let locale = Locale.current
        let adapter = AppleSpeechAnalyzerAdapter(locale: locale)
        appleSpeechAssetInstallTask = Task { @MainActor [weak self] in
            let succeeded: Bool
            do {
                _ = try await adapter.installAssets(
                    for: locale,
                    deadline: Date().addingTimeInterval(15 * 60)
                )
                succeeded = true
            } catch is CancellationError {
                guard let self else { return }
                switch self.appleSpeechAssetInstallLifecycle.claimCancellation(
                    request,
                    taskIsCancelled: Task.isCancelled
                ) {
                case .ignore:
                    return
                case .retireSilently:
                    self.finishAppleSpeechAssetInstall(showFailure: false)
                case .reportFailure:
                    self.finishAppleSpeechAssetInstall(showFailure: true)
                }
                return
            } catch {
                succeeded = false
            }

            guard !Task.isCancelled,
                  let self,
                  self.appleSpeechAssetInstallLifecycle.claimCompletion(request) else { return }
            self.finishAppleSpeechAssetInstall(showFailure: !succeeded)
        }
    }

    private func finishAppleSpeechAssetInstall(showFailure: Bool) {
        appleSpeechAssetInstallTask = nil
        defer { onLocalizationBlockingOperationDidEnd?() }
        if showFailure {
            DevTypeAlert.warn(
                title: loc.s("prefs.voice.appleAssets.failed.title"),
                message: loc.s("prefs.voice.appleAssets.failed.message"),
                window: view.window
            )
        }
        refreshAppleSpeechReadiness()
    }

    private func invalidateAppleSpeechAssetInstall() {
        let wasActive = appleSpeechAssetInstallLifecycle.isActive
        appleSpeechAssetInstallTask?.cancel()
        appleSpeechAssetInstallTask = nil
        appleSpeechAssetInstallLifecycle.invalidate()
        if wasActive {
            onLocalizationBlockingOperationDidEnd?()
        }
    }

    private func voicePermissionPresentation(
        for status: DurableVoiceCapture.MicrophonePermissionStatus
    ) -> (text: String, color: NSColor) {
        switch status {
        case .authorized: return (loc.s("status.authorized"), DevTypeTheme.statusGreen)
        case .notDetermined: return (loc.s("status.notRequested"), DevTypeTheme.statusOrange)
        case .denied: return (loc.s("status.denied"), DevTypeTheme.statusOrange)
        case .restricted: return (loc.s("status.restricted"), DevTypeTheme.statusOrange)
        }
    }

    private func voicePermissionPresentation(
        for status: SpeechAuthorization.Status
    ) -> (text: String, color: NSColor) {
        switch status {
        case .authorized: return (loc.s("status.authorized"), DevTypeTheme.statusGreen)
        case .notDetermined: return (loc.s("status.notRequested"), DevTypeTheme.statusOrange)
        case .denied: return (loc.s("status.denied"), DevTypeTheme.statusOrange)
        case .restricted: return (loc.s("status.restricted"), DevTypeTheme.statusOrange)
        }
    }

    private static func sourceKey(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .gemini: return "prefs.voice.speechModels.source.cloud"
        case .whisperLocal: return "prefs.voice.speechModels.source.local"
        case .localLLM, .appleSpeech: return "prefs.voice.speechModels.source.system"
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = RoundedSelectionRowView.dequeue(from: tableView, owner: self)
        rowView.selectionRadius = 5
        rowView.selectionInset = NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 2)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        refreshRemovalButton(for: tableView)
    }

    // MARK: Small layout helpers

    /// One canonical list surface for every table-shaped preference. Empty
    /// messages sit inside the list bounds, so zero rows read as an intentional
    /// state rather than an unexplained blank card.
    private func makeTableArea(
        table: NSTableView,
        accessibilityLabel: String,
        columnIdentifier: String,
        emptyLabel: NSTextField,
        rowHeight: CGFloat = 22,
        height: CGFloat = 110,
        allowsMultipleSelection: Bool = false
    ) -> NSView {
        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = allowsMultipleSelection
        table.dataSource = self
        table.delegate = self
        if table.tableColumns.isEmpty {
            table.addTableColumn(NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(columnIdentifier)
            ))
        }
        table.setAccessibilityLabel(accessibilityLabel)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = table

        let area = PreferenceTableAreaView()
        area.translatesAutoresizingMaskIntoConstraints = false
        area.wantsLayer = true
        area.layer?.cornerRadius = DevTypeTheme.Radius.control
        area.layer?.backgroundColor = DevTypeTheme.contrastOverlay(0.035).cgColor
        area.layer?.borderWidth = 1
        area.layer?.borderColor = DevTypeTheme.hairline.cgColor

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        area.addSubview(scroll)
        area.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            area.heightAnchor.constraint(equalToConstant: height),
            scroll.topAnchor.constraint(equalTo: area.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: area.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -4),
            emptyLabel.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: area.trailingAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: area.centerXAnchor)
        ])
        return area
    }

    private func bindRemovalButton(_ button: CapsuleButton, to tableView: NSTableView) {
        removalButtons[ObjectIdentifier(tableView)] = button
        refreshRemovalButton(for: tableView)
    }

    private func refreshRemovalButton(for tableView: NSTableView) {
        removalButtons[ObjectIdentifier(tableView)]?.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    private func makeCard(title: String, symbol: String) -> GlassCardView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.05))
        card.translatesAutoresizingMaskIntoConstraints = false
        let badge = IconBadgeView(symbol: symbol, tint: DevTypeTheme.accent, size: 26, pointSize: 12)
        let header = DevTypeTheme.makeLabel(
            title,
            font: DevTypeTheme.font(13, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(badge)
        card.contentView.addSubview(header)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 12),
            badge.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            header.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        card.setAccessibilityLabel(title)
        return card
    }

    /// Stacks `views` below the card header and sizes the card to fit.
    private func stackInCard(_ card: GlassCardView, views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 46),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -14),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 14)
        ])
        // Wrapping labels and scroll views need a definite width to lay out; the
        // controls (buttons, popups, recorders) keep their intrinsic size so the
        // leading-aligned stack does not stretch them across the card.
        for subview in views {
            if subview is NSTextField
                || subview is NSScrollView
                || subview is PreferenceRowView
                || subview is PreferenceTableAreaView
                || (subview as? NSStackView)?.orientation == .horizontal {
                subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else {
                subview.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func makeToggleRow(title: String, toggle: NSSwitch, action: Selector) -> NSView {
        let row = PreferenceRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
        // §5.1: a bare NSSwitch is announced as "switch, on" with no subject.
        toggle.setAccessibilityLabel(title)

        let label = DevTypeTheme.makeLabel(
            title,
            font: DevTypeTheme.font(12.5, .medium),
            color: DevTypeTheme.textPrimary,
            wrapping: true
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(toggle)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2)
        ])
        return row
    }

    private func makeLabeledControlRow(
        title: String,
        control: NSView,
        font: NSFont = DevTypeTheme.font(12.5, .medium)
    ) -> NSView {
        let row = PreferenceRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let label = DevTypeTheme.makeLabel(title, font: font, color: DevTypeTheme.textPrimary)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 26)
        ])
        return row
    }

    private func pinWidth(of views: [NSView], to stack: NSStackView) {
        for subview in views {
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}
