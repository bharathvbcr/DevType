import Foundation
import Speech

/// Speech-recognition authorization, split into an observation and a request.
///
/// Keeping these apart matters. `SFSpeechRecognizer.requestAuthorization` shows a system
/// prompt, so calling it from a readiness check means asking "is this engine ready?"
/// silently asks the user for permission — a status query with a side effect. Preferences
/// lists engine readiness, and listing must never prompt.
///
/// `status()` observes and never prompts. `request()` prompts, and is called only where the
/// user has expressed intent by starting a dictation.
public enum SpeechAuthorization {

    public enum Status: Sendable, Equatable {
        case authorized
        /// The user has not been asked yet. Only `request()` may change this.
        case notDetermined
        /// The user denied access. A second prompt will not appear; Settings is the recovery path.
        case denied
        /// Device-management or parental policy prevents access.
        case restricted

        public var diagnosticLabel: String {
            switch self {
            case .authorized: return "authorized"
            case .notDetermined: return "notDetermined"
            case .denied: return "denied"
            case .restricted: return "restricted"
            }
        }
    }

    public static func status() -> Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    /// Shows the system prompt when the user has not been asked, and reports the outcome.
    /// Already-decided states return immediately without prompting again.
    public static func request() async -> Status {
        guard status() == .notDetermined else { return status() }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume(returning: status())
            }
        }
    }
}
