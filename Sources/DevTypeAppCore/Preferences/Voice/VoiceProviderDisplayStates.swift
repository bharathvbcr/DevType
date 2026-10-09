import AppKit
import ExpanderEngine

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
    case buildLacksSpeechAnalyzer

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
        case .unsupported(reason: .buildLacksSpeechAnalyzer):
            return .buildLacksSpeechAnalyzer
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
        case .buildLacksSpeechAnalyzer:
            return "prefs.voice.speechModels.status.buildLacksSpeech"
        }
    }

    var tintRole: TintRole {
        switch self {
        case .checking: return .checking
        case .ready: return .ready
        case .needsPermission, .denied, .restricted, .onDeviceUnavailable, .buildLacksSpeechAnalyzer: return .attention
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
    case buildLacksSpeechAnalyzer

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
        case .buildLacksSpeechAnalyzer: return .buildLacksSpeechAnalyzer
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
        case .buildLacksSpeechAnalyzer: return "prefs.voice.speechModels.status.buildLacksSpeech"
        }
    }

    var tintRole: AppleSpeechReadinessDisplayState.TintRole {
        switch self {
        case .checking: return .checking
        case .ready: return .ready
        case .basicCleanup, .needsPermission, .denied, .restricted, .onDeviceUnavailable, .buildLacksSpeechAnalyzer:
            return .attention
        }
    }
}
