import Foundation

public enum DictationFailure: Equatable, Sendable {
    case audio
    case noMicrophone
    case noAudio
    case network(String)
    case auth
    case modelAccess
    case rateLimited
    case quotaExhausted
    case timeout
    case validation
    case safetyBlocked
    case noAPIKey
}

public enum DictationOutcome: Equatable, Sendable {
    case inserted
    case copiedToClipboard
    case silent
    case queuedForRetry
}

public enum DictationMode: Equatable, Sendable {
    case hold
    case handsFree
}

public enum DictationState: Equatable, Sendable {
    case idle
    case recording(mode: DictationMode)
    case encoding
    case transcribing
    case inserting
    case success(text: String, outcome: DictationOutcome)
    case failed(DictationFailure)
    case cancelled
}

public enum DictationEvent: Equatable, Sendable {
    case hotkeyDown
    case hotkeyUp
    case lockIn
    case cancel
    case audioReady(URL)
    case encodingComplete(URL)
    case transcriptReady(String)
    case insertionComplete(DictationOutcome)
    case error(DictationFailure)
}

public enum DictationStateMachine {
    /// Pure function that evaluates the next state given a current state and an event.
    /// Returns the new state, or the current state if the transition is invalid.
    public static func transition(_ state: DictationState, on event: DictationEvent) -> DictationState {
        switch (state, event) {
        
        // Idle transitions
        case (.idle, .hotkeyDown):
            return .recording(mode: .hold)
            
        // Recording transitions
        case (.recording(.hold), .hotkeyUp):
            return .encoding
        case (.recording(.hold), .lockIn):
            return .recording(mode: .handsFree)
        case (.recording(.handsFree), .hotkeyDown):
            return .encoding
        case (.recording, .cancel):
            return .cancelled
            
        // Encoding transitions
        case (.encoding, .encodingComplete):
            return .transcribing
        case (.encoding, .cancel):
            return .cancelled
            
        // Transcribing transitions
        case (.transcribing, .transcriptReady):
            return .inserting
        case (.transcribing, .cancel):
            return .cancelled
            
        // Inserting transitions
        case (.inserting, .insertionComplete(let outcome)):
            return .success(text: "", outcome: outcome)
        case (.inserting, .cancel):
            return .cancelled
            
        // Restarting from terminal states
        case (.success, .hotkeyDown),
             (.failed, .hotkeyDown),
             (.cancelled, .hotkeyDown):
            return .recording(mode: .hold)
            
        // Global error handling
        case (_, .error(let failure)):
            return .failed(failure)
            
        // Ignore invalid transitions (no-op)
        default:
            return state
        }
    }
}
