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

    /// Voice dictation: session lifecycle, live segments, reconciliation decisions and
    /// injections.
    ///
    /// Its own category because the live-typing path is where text can be *erased*, and
    /// diagnosing that needs the whole sequence — which segment arrived, what the assembler
    /// made of it, what the reconciler decided, how many characters were removed. Mixed
    /// into `App` those lines are unfindable.
    ///
    /// Logs lengths, counts and outcomes — never dictated content. Content goes only to the
    /// opt-in `VoiceDiagnosticsRecorder`, which writes to a local file the user chooses to
    /// share.
    public static let voice = Logger(subsystem: subsystem, category: "Voice")

    /// AX selection reads for the AI paths.
    ///
    /// Its own category because "Prompt Enhance says no text is selected" is diagnosed from a
    /// 30-minute log window, and mixed into `EventTap` these lines are buried under per-keystroke
    /// traffic. Never logs the selected text — only outcome, app, attribute, and length.
    public static let selection = Logger(subsystem: subsystem, category: "Selection")

    /// Update checks: whether one ran, and how it ended.
    ///
    /// Its own category because "DevType never told me about the update" and "DevType keeps
    /// telling me to update" are both diagnosed from the sequence of check outcomes, which is
    /// unfindable mixed into `App`. Logs outcomes and version strings only — the check sends no
    /// user data, and nothing about the machine is written here either.
    public static let updates = Logger(subsystem: subsystem, category: "Updates")

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

    /// Public-safe metadata for arbitrary errors. `localizedDescription`, `NSError.domain`, and
    /// `String(describing:)` can contain provider response bodies, user-selected paths, prompts,
    /// or text. A concrete type plus numeric code keeps failures distinguishable without making
    /// any free-form payload public in OSLog or the mirrored support report.
    ///
    /// Wrapped causes are appended as `causes=domain:code,…`. Without them a framework failure
    /// logs as its outermost wrapper only — `type=NSError code=-1` — which is how an on-device
    /// model refusal under memory pressure left no trace of its cause. Domains follow the rule
    /// above: only the framework domains in `publicErrorDomains` are written verbatim, every
    /// other domain is a salted fingerprint.
    public static func errorMetadata(_ error: Error) -> String {
        let fullType = String(reflecting: type(of: error))
        let boundedType = String(fullType.prefix(96))
        let nsError = error as NSError
        var line = "type=\(boundedType) code=\(nsError.code) domain=\(publicErrorDomain(nsError.domain))"
        let walk = ErrorGraph.walk(error, maxDepth: 4, maxNodes: 9)
        let causes = walk.nodes.dropFirst()
        if !causes.isEmpty || walk.truncated {
            var parts = causes.map { "\(publicErrorDomain($0.domain)):\($0.code)" }
            if walk.truncated { parts.append("+more") }
            line += " causes=" + parts.joined(separator: ",")
        }
        return line
    }

    /// Framework error domains that name a subsystem and never carry request content. Anything
    /// else — a provider-defined domain, a Swift error's module-qualified type — is fingerprinted.
    static let publicErrorDomains: Set<String> = [
        NSCocoaErrorDomain,
        NSPOSIXErrorDomain,
        NSOSStatusErrorDomain,
        NSMachErrorDomain,
        NSURLErrorDomain,
        // The on-device model's failure chain, as observed on macOS 27.0.1.
        "FoundationModels.LanguageModelError",
        "com.apple.SensitiveContentAnalysisML",
        "SensitiveContentAnalysisML.CombinedTextSanitizerBackend.BackendError",
        "ModelManagerServices.ModelManagerError",
    ]

    static func publicErrorDomain(_ domain: String) -> String {
        if publicErrorDomains.contains(domain) { return domain }
        return "domain#" + DiagnosticPrivacy.fingerprint(domain, domain: "public-error-domain")
    }

    /// Shape-only projection for an unavoidable free-form framework string (for example an
    /// `NSException.reason`). The process-random salt permits correlation inside one report but
    /// prevents copied hashes of short values from becoming a reusable lookup table.
    public static func publicTextMetadata(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "text=absent" }
        return DiagnosticPrivacy.textShape(value, label: "text", domain: "public-error-text")
    }

    /// Shape-only public-log projection for a filesystem path. Paths routinely contain account
    /// names and private directory structure, so even normal-sized values are never emitted
    /// verbatim. The salted hash remains useful for correlating repeated failures in one run.
    public static func publicPathMetadata(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "path=absent" }
        return DiagnosticPrivacy.textShape(value, label: "path", domain: "public-file-path")
    }

    /// OS-provided identifiers are useful verbatim at ordinary sizes. A malformed application can
    /// still advertise a hostile-length name or bundle ID, so oversized values become bounded
    /// shape metadata instead of dominating OSLog and its in-process mirror.
    public static func boundedPublicIdentifier(_ value: String?, label: String) -> String {
        guard let value, !value.isEmpty else { return "(unknown)" }
        return DiagnosticPrivacy.boundedIdentifier(
            value,
            label: label,
            domain: "public-identifier-\(label)",
            maxUTF8Bytes: 256
        )
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
