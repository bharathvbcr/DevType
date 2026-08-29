import Foundation

/// Persistence for the update checker (`devtype.updates.*`).
///
/// **Automatic checking defaults to off.** DevType's posture is that no network request is made
/// unless the user asked for it, so `automaticCheckEnabled` follows the same shape as
/// `AIPreferences.isEnabled`: `UserDefaults.bool` is `false` when unset, and nothing contacts
/// GitHub until the user turns it on in Preferences. A manual "Check for Updates…" from the menu
/// is an explicit request and runs regardless of this flag.
public enum UpdatePreferences {

    public static let automaticCheckEnabledKey = "devtype.updates.automaticCheckEnabled"
    public static let lastCheckDateKey = "devtype.updates.lastCheckDate"
    public static let lastFoundVersionKey = "devtype.updates.lastFoundVersion"
    public static let skippedVersionKey = "devtype.updates.skippedVersion"

    /// Minimum spacing between *automatic* checks. A manual check ignores it.
    ///
    /// A day is the shortest interval that is still clearly a background convenience rather than
    /// a polling loop: DevType is a menu-bar agent that can stay running for weeks, and a shorter
    /// window would turn "check for updates" into repeated unrequested traffic to GitHub.
    public static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private static var defaults: UserDefaults { .standard }

    // MARK: - Master enable

    /// Whether DevType may check for updates on its own. Off unless the user opts in.
    public static var automaticCheckEnabled: Bool {
        get { defaults.bool(forKey: automaticCheckEnabledKey) }
        set { defaults.set(newValue, forKey: automaticCheckEnabledKey) }
    }

    // MARK: - Check bookkeeping

    /// When a check last *completed successfully*. Never written for a failed check, so a
    /// week of network failures cannot masquerade as a week of clean checks.
    public static var lastSuccessfulCheck: Date? {
        get {
            let seconds = defaults.double(forKey: lastCheckDateKey)
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: lastCheckDateKey)
            } else {
                defaults.removeObject(forKey: lastCheckDateKey)
            }
        }
    }

    /// The newest version seen by any successful check, so Preferences can show a pending
    /// update without re-hitting the network every time the window opens.
    public static var lastFoundVersion: String? {
        get { defaults.string(forKey: lastFoundVersionKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: lastFoundVersionKey)
            } else {
                defaults.removeObject(forKey: lastFoundVersionKey)
            }
        }
    }

    // MARK: - Skip

    /// A version the user dismissed with "Skip This Version".
    public static var skippedVersion: String? {
        get { defaults.string(forKey: skippedVersionKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: skippedVersionKey)
            } else {
                defaults.removeObject(forKey: skippedVersionKey)
            }
        }
    }

    /// Whether `version` was skipped.
    ///
    /// Compares parsed versions, not strings, so skipping `1.3.0` also suppresses a
    /// re-announcement of `v1.3.0`. A *newer* release than the skipped one is always announced —
    /// skipping one version must never silently mute every future release.
    public static func isSkipped(_ version: AppVersion) -> Bool {
        guard let skipped = skippedVersion.flatMap(AppVersion.init) else { return false }
        return AppVersion.compare(version, skipped) != .orderedDescending
    }

    public static func skip(_ version: AppVersion) {
        skippedVersion = version.rawValue
    }

    /// Whether an automatic check is due. False when the user has not opted in.
    public static func isAutomaticCheckDue(now: Date = Date()) -> Bool {
        guard automaticCheckEnabled else { return false }
        guard let last = lastSuccessfulCheck else { return true }
        // A clock moved backwards (timezone edit, NTP correction) leaves `last` in the future.
        // Treat that as due rather than blocking checks until real time catches up.
        if last > now { return true }
        return now.timeIntervalSince(last) >= automaticCheckInterval
    }

    /// Clears all update state. Used by tests and by a Preferences "reset" path.
    public static func reset() {
        defaults.removeObject(forKey: automaticCheckEnabledKey)
        defaults.removeObject(forKey: lastCheckDateKey)
        defaults.removeObject(forKey: lastFoundVersionKey)
        defaults.removeObject(forKey: skippedVersionKey)
    }
}
