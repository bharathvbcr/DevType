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
