import Foundation
import ExpanderEngine

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
