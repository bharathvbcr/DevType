import Foundation
import os.log

/// Shared `os.Logger` facade for DevType. Prefer these over ad-hoc `print` / local loggers.
///
/// Filter in Console.app / `log stream`:
///   `subsystem:com.devtype.app`
///   `subsystem:com.devtype.app AND category:Permission`
public enum DevTypeLog {
    public static let subsystem = "com.devtype.app"

    public static let permission = Logger(subsystem: subsystem, category: "Permission")
    public static let eventTap = Logger(subsystem: subsystem, category: "EventTap")
    public static let secureInput = Logger(subsystem: subsystem, category: "SecureInput")
    public static let inject = Logger(subsystem: subsystem, category: "Inject")
    public static let identity = Logger(subsystem: subsystem, category: "Identity")
    public static let app = Logger(subsystem: subsystem, category: "App")
    public static let store = Logger(subsystem: subsystem, category: "Store")

    /// Prefix-debounce hold lifecycle (arm / extend / fire / cancel / absorbed races).
    ///
    /// Its own category because a hold's whole story spans two threads and up to three timers;
    /// mixed into `EventTap` it is buried under per-keystroke traffic. Never logs trigger or
    /// suffix *content* — only lengths, generations, and outcomes.
    public static let debounce = Logger(subsystem: subsystem, category: "Debounce")

    /// AX selection reads for the AI paths.
    ///
    /// Its own category because "Prompt Enhance says no text is selected" is diagnosed from a
    /// 30-minute log window, and mixed into `EventTap` these lines are buried under per-keystroke
    /// traffic. Never logs the selected text — only outcome, app, attribute, and length.
    public static let selection = Logger(subsystem: subsystem, category: "Selection")

    /// Boolean TCC-style result for CG/AX preflights (macOS has no notDetermined here).
    public static func grantLabel(_ granted: Bool) -> String {
        granted ? "granted" : "denied"
    }

    public static func snapshotSummary(_ snapshot: PermissionSnapshot) -> String {
        let listen = grantLabel(snapshot.canListenTap)
        let ax = grantLabel(snapshot.canUseAX)
        let post = grantLabel(snapshot.canPostEvents)
        let missing = snapshot.missingCapabilitiesSummary
        return "listen=\(listen) ax=\(ax) post=\(post) (\(missing))"
    }

    public static func kindName(_ kind: PermissionKind) -> String {
        switch kind {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "InputMonitoring"
        case .postEvent: return "PostEvents"
        case .microphone: return "Microphone"
        case .speechRecognition: return "SpeechRecognition"
        }
    }

    public static func requestResultSummary(_ result: PermissionRequester.RequestResult) -> String {
        var parts = [
            "kind=\(kindName(result.kind))",
            "apiReturned=\(result.apiReturnedTrue)",
            "preflight=\(grantLabel(result.preflightGranted))"
        ]
        if result.usedListenOnlyProbe {
            parts.append("listenOnlyProbe=true")
        }
        return parts.joined(separator: " ")
    }
}
