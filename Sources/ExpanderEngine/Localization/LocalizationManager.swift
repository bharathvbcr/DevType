import Combine
import Foundation

extension Notification.Name {
    /// §7.1: `public` because `LocalizationManager` moved out of `DevTypeApp` (an
    /// `executableTarget`, which the test target cannot import) and into `ExpanderEngine`,
    /// so the en/ko/ja key + format-specifier parity can actually be asserted.
    public static let devTypeLanguageChanged = Notification.Name("devtype.language.changed")
    /// Posted when preferences (hotkeys, voice, ai, general, secrets) are updated.
    public static let devTypePreferencesChanged = Notification.Name("devtype.preferences.changed")
}

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case ko
    case ja

    public var id: String { rawValue }

    public var endonym: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        }
    }

    /// §6.2: `effectiveLanguageCode()` used to hardcode `hasPrefix("ko")` /
    /// `hasPrefix("ja")` in a switch, so adding a fourth language meant editing
    /// that switch. Matching is now driven off this table — a new case only has
    /// to declare its own prefixes.
    public var localeMatchPrefixes: [String] {
        switch self {
        case .system: return []
        case .en: return ["en"]
        case .ko: return ["ko"]
        case .ja: return ["ja"]
        }
    }

    /// Concrete (non-`system`) languages, in resolution order.
    public static var concreteCases: [AppLanguage] {
        allCases.filter { $0 != .system }
    }

    /// §6.2: the list `Resources/Info.plist` needs under `CFBundleLocalizations`.
    /// DevTypeApp does not own Info.plist — this is the source of truth to copy from.
    public static var bundleLocalizationCodes: [String] {
        concreteCases.map(\.rawValue)
    }
}

/// §6.2: CLDR-ish plural categories. Only what DevType's three languages need.
public enum PluralCategory: String {
    case one
    case other
}

/// UI string lookup: language resolution, plural selection and formatting.
///
/// The strings themselves are resource tables under `Localization/Resources/<lang>.lproj/`,
/// loaded by `LocalizationTables`. When `Pseudolocalizer.isEnabled()` is set at launch every
/// lookup is pseudolocalized for layout checks.
public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    public static let deviceKey = "devtype.device.uiLanguage"

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.deviceKey)
            invalidateResolvedLanguage()
            NotificationCenter.default.post(name: .devTypeLanguageChanged, object: nil)
        }
    }

    private let tables: [AppLanguage: [String: String]]

    /// Resolved UI language, cached.
    ///
    /// `lookup` reaches `effectiveLanguageCode()` on every call, and in the default `.system`
    /// mode that walks `Locale.preferredLanguages` — a CFPreferences read returning fresh
    /// strings, measured at 783 ns, to guard a dictionary lookup that costs 16 ns. With 1,518
    /// `s(…)` call sites the overhead dominates every bulk fetch: building the Preferences
    /// window, rebuilding the menu, configuring table cells during a scroll.
    ///
    /// Guarded by `resolutionLock` rather than confined to main, because strings are fetched
    /// from the inject queue and the tap thread as well as from AppKit.
    private let resolutionLock = NSLock()
    private var _resolvedLanguage: AppLanguage?
    /// Bumped on every invalidation so a candidate computed before the bump
    /// cannot be published afterwards, even when `language` itself is unchanged.
    private var resolutionEpoch: UInt64 = 0
    private var localeObserver: NSObjectProtocol?

    /// Test seam. Nil in production. Runs on a cache miss after the lock is
    /// released and a candidate has been computed, before publication.
    /// `language.didSet` takes `resolutionLock`; calling this while the lock
    /// is held deadlocks.
    var resolutionMissHookForTesting: (() -> Void)?

    /// Published cache, or nil when the next lookup must resolve again.
    var cachedResolvedLanguageForTesting: AppLanguage? {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        return _resolvedLanguage
    }

    public init(pseudolocalize: Bool = Pseudolocalizer.isEnabled()) {
        let stored = UserDefaults.standard.string(forKey: Self.deviceKey)
        language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        let loaded = LocalizationTables.shared.tables
        tables = pseudolocalize
            ? loaded.mapValues { $0.mapValues(Pseudolocalizer.transform) }
            : loaded
        // The system language list can change while we run; `.system` mode must follow it.
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateResolvedLanguage()
        }
    }

    deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }

    /// Drops the cached resolution and retires any in-flight candidate so it
    /// cannot be published afterwards. Public so a test (or a caller that
    /// changed `AppleLanguages` itself) can force the next lookup to re-resolve.
    public func invalidateResolvedLanguage() {
        resolutionLock.lock()
        _resolvedLanguage = nil
        resolutionEpoch &+= 1
        resolutionLock.unlock()
    }

    public func s(_ key: String, _ args: CVarArg...) -> String {
        let format = lookup(key)
        if args.isEmpty { return format }
        return String(format: format, arguments: args)
    }

    /// §6.2: plural-aware lookup. Tables store `key.one` / `key.other`; the
    /// category is chosen per the resolved UI language, not the system locale,
    /// so a Korean UI on an English Mac still gets Korean's single form.
    ///
    /// `count` selects the variant; it is **not** auto-prepended to `args`, so
    /// formats stay readable — pass it explicitly where the string needs it:
    ///
    ///     loc.p("manager.group.delete.message", count: n, group.name, n)
    public func p(_ key: String, count: Int, _ args: CVarArg...) -> String {
        let language = resolvedLanguage()
        let category = Self.pluralCategory(for: count, language: language)
        let format = lookupPlural(key, category: category, language: language)
        if args.isEmpty { return format }
        return String(format: format, arguments: args)
    }

    /// Non-variadic overload for call sites that already have an argument array.
    public func plural(_ key: String, count: Int, arguments: [CVarArg]) -> String {
        let language = resolvedLanguage()
        let category = Self.pluralCategory(for: count, language: language)
        let format = lookupPlural(key, category: category, language: language)
        if arguments.isEmpty { return format }
        return String(format: format, arguments: arguments)
    }

    // MARK: - Resolution

    private func lookup(_ key: String) -> String {
        let language = resolvedLanguage()
        return tables[language]?[key] ?? tables[.en]?[key] ?? key
    }

    private func lookupPlural(
        _ key: String,
        category: PluralCategory,
        language: AppLanguage
    ) -> String {
        let table = tables[language]
        let fallback = tables[.en]
        let candidates = [
            "\(key).\(category.rawValue)",
            "\(key).other",
            key
        ]
        for candidate in candidates {
            if let hit = table?[candidate] { return hit }
        }
        for candidate in candidates {
            if let hit = fallback?[candidate] { return hit }
        }
        return key
    }

    private func resolvedLanguage() -> AppLanguage {
        resolutionLock.lock()
        if let cached = _resolvedLanguage {
            resolutionLock.unlock()
            return cached
        }
        let captured = language
        let capturedEpoch = resolutionEpoch
        let missHook = resolutionMissHookForTesting
        resolutionLock.unlock()

        // Both the locale walk and the miss hook stay outside the lock.
        // `Locale.preferredLanguages` can take Foundation locks, and the hook
        // may set `language`, whose `didSet` calls `invalidateResolvedLanguage()`.
        let resolved = AppLanguage(rawValue: code(for: captured)) ?? .en
        missHook?()

        resolutionLock.lock()
        if _resolvedLanguage == nil, language == captured, resolutionEpoch == capturedEpoch {
            _resolvedLanguage = resolved
            resolutionLock.unlock()
            return resolved
        }
        if let published = _resolvedLanguage {
            resolutionLock.unlock()
            return published
        }
        let observed = language
        resolutionLock.unlock()

        // The candidate was computed for a language that has since changed,
        // or an invalidation retired it. Do not store it. A concrete language
        // needs no locale walk; `.system` is resolved again, still outside
        // the lock, and left unpublished so the next caller resolves fresh.
        if observed != .system {
            return observed
        }
        return AppLanguage(rawValue: effectiveLanguageCode()) ?? .en
    }

    /// §6.2: table-driven. Walks the user's preferred languages in order and
    /// returns the first `AppLanguage` whose `localeMatchPrefixes` matches.
    public func effectiveLanguageCode() -> String {
        code(for: language)
    }

    /// Resolution for one setting. `.system` reads `Locale.preferredLanguages`
    /// and must not be called while `resolutionLock` is held.
    private func code(for setting: AppLanguage) -> String {
        guard setting == .system else { return setting.rawValue }
        for preferred in Locale.preferredLanguages {
            let lowered = preferred.lowercased()
            for candidate in AppLanguage.concreteCases {
                for prefix in candidate.localeMatchPrefixes where lowered.hasPrefix(prefix) {
                    return candidate.rawValue
                }
            }
        }
        return AppLanguage.en.rawValue
    }

    private static func pluralCategory(for count: Int, language: AppLanguage) -> PluralCategory {
        switch language {
        case .en:
            return abs(count) == 1 ? .one : .other
        case .ko, .ja, .system:
            // Korean and Japanese have no grammatical plural — one form covers all counts.
            return .other
        }
    }

    // MARK: - Tables

    /// §7.1: the string table for one language, as loaded from its resource files, so the
    /// key-set / format-specifier parity test can compare them. A `%d` in `en` and a `%@` in `ko`
    /// for the same key is a `String(format:arguments:)` crash at runtime, and nothing else
    /// catches it. Never pseudolocalized: it is the shipped data.
    ///
    /// `.system` is not a real table — it resolves to a concrete language at lookup time — so it
    /// returns empty.
    public static func stringTable(for language: AppLanguage) -> [String: String] {
        guard language != .system else { return [:] }
        return LocalizationTables.shared.tables[language] ?? [:]
    }
}
