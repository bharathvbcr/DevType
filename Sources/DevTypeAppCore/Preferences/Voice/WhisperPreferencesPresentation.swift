import Foundation
import ExpanderEngine

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
