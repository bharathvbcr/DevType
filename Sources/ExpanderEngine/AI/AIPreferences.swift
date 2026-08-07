import Foundation

/// Persistence for the Preferences AI tab and runtime gates (`devtype.ai.*`).
///
/// Master enable defaults **off** (`UserDefaults.bool` is false when unset).
/// Per-action output mode falls back to `AITransformKind.defaultOutputMode` when unset.
/// Typed-path allowlist: empty means all apps; non-empty restricts to listed bundle IDs.
public enum AIPreferences {
    public static let enabledKey = SelectionMonitor.featureEnabledDefaultsKey
    public static let typedPathAllowlistKey = "devtype.ai.typedPathAllowlist"

    private static func outputModeKey(for kind: AITransformKind) -> String {
        "devtype.ai.outputMode.\(kind.rawValue)"
    }

    // MARK: - Master enable

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            SelectionMonitor.shared.isFeatureEnabled = newValue
        }
    }

    // MARK: - Output mode

    public static func outputMode(for kind: AITransformKind) -> AIOutputMode {
        let key = outputModeKey(for: kind)
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = AIOutputMode(rawValue: raw) else {
            return kind.defaultOutputMode
        }
        return mode
    }

    public static func setOutputMode(_ mode: AIOutputMode, for kind: AITransformKind) {
        UserDefaults.standard.set(mode.rawValue, forKey: outputModeKey(for: kind))
    }

    public static func resetOutputMode(for kind: AITransformKind) {
        UserDefaults.standard.removeObject(forKey: outputModeKey(for: kind))
    }

    // MARK: - Typed-path allowlist

    /// Bundle IDs allowed to use the typed AI path. Empty = every app.
    public static var typedPathAllowlist: [String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: typedPathAllowlistKey),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return decoded.filter { !$0.isEmpty }.sorted()
        }
        set {
            let cleaned = Array(Set(newValue.filter { !$0.isEmpty })).sorted()
            guard let data = try? JSONEncoder().encode(cleaned) else { return }
            UserDefaults.standard.set(data, forKey: typedPathAllowlistKey)
        }
    }

    public static func isTypedPathAllowed(bundleID: String) -> Bool {
        let list = typedPathAllowlist
        if list.isEmpty { return true }
        guard !bundleID.isEmpty else { return false }
        return list.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    public static func addTypedPathApp(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var list = typedPathAllowlist
        if list.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) { return }
        list.append(bundleID)
        typedPathAllowlist = list
    }

    public static func removeTypedPathApps(_ bundleIDs: [String]) {
        let remove = Set(bundleIDs.map { $0.lowercased() })
        typedPathAllowlist = typedPathAllowlist.filter { !remove.contains($0.lowercased()) }
    }

    // MARK: - Semantic routing (C4 Stage 2)

    public static let semanticRoutingEnabledKey = "devtype.ai.semanticRoutingEnabled"

    /// When true, palette queries may use on-device Tool routing after a debounce.
    /// Off by default — Stage 1 NLEmbedding is the default soft-rank path.
    public static var isSemanticRoutingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: semanticRoutingEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: semanticRoutingEnabledKey) }
    }
}

// MARK: - Localization keys for AI errors / availability

public extension AIModelAvailability {
    /// Key under LocalizationManager (`ai.availability.*`).
    var localizationKey: String {
        switch self {
        case .available:
            return "ai.availability.available"
        case .unavailable(let reason):
            return reason.localizationKey
        }
    }
}

public extension AIModelAvailability.Reason {
    var localizationKey: String {
        switch self {
        case .unsupportedOS: return "ai.availability.unsupportedOS"
        case .deviceNotEligible: return "ai.availability.deviceNotEligible"
        case .appleIntelligenceNotEnabled: return "ai.availability.notEnabled"
        case .modelNotReady: return "ai.availability.modelNotReady"
        }
    }
}

public extension AITransformError {
    /// Key under LocalizationManager (`ai.error.*` / refuse keys).
    var localizationKey: String {
        switch self {
        case .unavailable(let reason):
            return reason.localizationKey
        case .busy, .concurrentRequests:
            return "ai.error.busy"
        case .emptyInput:
            return "ai.error.emptyInput"
        case .inputTooLarge:
            return "ai.error.inputTooLarge"
        case .guardrailViolation:
            return "ai.error.guardrail"
        case .exceededContextWindowSize:
            return "ai.error.contextWindow"
        case .rateLimited:
            return "ai.error.rateLimited"
        case .unsupportedLanguageOrLocale:
            return "ai.error.language"
        case .assetsUnavailable:
            return "ai.error.assets"
        case .decodingFailure:
            return "ai.error.decoding"
        case .refusal:
            return "ai.error.refusal"
        case .unsupportedGuide:
            return "ai.error.unsupportedGuide"
        case .discarded:
            return "ai.error.discarded"
        case .unknown:
            return "ai.error.unknown"
        }
    }
}
