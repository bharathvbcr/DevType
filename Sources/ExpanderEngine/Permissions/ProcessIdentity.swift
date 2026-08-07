import Cocoa
import Foundation

/// Process identity for TCC: bundle ID, path, cached CDHash, siblings, packaging checks.
public final class ProcessIdentity {
    public static let shared = ProcessIdentity()
    public static let expectedBundleIdentifier = "com.devtype.app"
    /// Pre-rename / stale TCC identity — grants for this ID do not apply to com.devtype.app.
    public static let legacyStaleBundleIdentifier = "app.devtype.DevType"

    public static let onboardingCompletedDefaultsKey = "devtype.permissions.onboardingCompleted"
    public static let onboardingCDHashDefaultsKey = "devtype.permissions.onboardingCDHash"
    public static let onboardingPathDefaultsKey = "devtype.permissions.onboardingPath"
    /// Designated requirement string from `codesign -d -r-`. TCC pins grants to this, not CDHash,
    /// when the app is certificate-signed.
    public static let onboardingDesignatedRequirementDefaultsKey = "devtype.permissions.onboardingDesignatedRequirement"
    public static let lastKnownCDHashDefaultsKey = "devtype.permissions.lastKnownCDHash"
    public static let lastKnownPathDefaultsKey = "devtype.permissions.lastKnownPath"
    public static let lastKnownDesignatedRequirementDefaultsKey = "devtype.permissions.lastKnownDesignatedRequirement"
    public static let accessibilityGrantedCDHashDefaultsKey = "devtype.permissions.accessibilityGrantedCDHash"
    /// Persisted inverse of `EventTapEngine.isEnabled` (user pause).
    public static let userPausedDefaultsKey = "devtype.engine.userPaused"

    /// Ceiling for `codesign` identity probes. Healthy runs are tens of milliseconds; this only
    /// bounds the pathological case (stalled network mount) that would otherwise strand Setup.
    public static let codesignTimeout: TimeInterval = 5.0
    /// Ceiling for Spotlight discovery. Shorter than `codesignTimeout` — a rebuilding index must
    /// not delay a purely advisory dual-install warning.
    public static let mdfindTimeout: TimeInterval = 3.0

    private let cacheLock = NSLock()
    private var cachedCDHash: String?
    private var cachedDesignatedRequirement: String?
    private var cachedCDHashPath: String?
    private var cdHashInFlight = false
    private var cdHashPendingCompletions: [(String?) -> Void] = []
    private var cachedDevBundlePresent: Bool?
    private var devBundleProbeInFlight = false
    private var devBundlePendingCompletions: [(Bool) -> Void] = []

    public init() {}

    public var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? Self.expectedBundleIdentifier
    }

    public var bundlePath: String {
        Bundle.main.bundleURL.path
    }

    public var executablePath: String {
        Bundle.main.executableURL?.path
            ?? Self.executablePath(forAppBundlePath: bundlePath)
    }

    public var isPackaged: Bool {
        Self.isPackagedAppBundle(bundlePath: bundlePath)
    }

    /// Cached CDHash if already resolved for the current path; nil until async load finishes.
    public var cachedCodeDirectoryHash: String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cachedCDHashPath == Self.normalizedBundlePath(bundlePath) else { return nil }
        return cachedCDHash
    }

    /// Cached designated requirement for the current path; nil until async load finishes.
    public var cachedDesignatedRequirementString: String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cachedCDHashPath == Self.normalizedBundlePath(bundlePath) else { return nil }
        return cachedDesignatedRequirement
    }

    /// Loads CDHash + designated requirement off the main thread and caches them. Safe to call repeatedly.
    public func refreshCDHashAsync(completion: ((String?) -> Void)? = nil) {
        let path = bundlePath
        let normalized = Self.normalizedBundlePath(path)

        cacheLock.lock()
        if cachedCDHashPath == normalized, cachedCDHash != nil {
            let value = cachedCDHash
            cacheLock.unlock()
            DispatchQueue.main.async { completion?(value) }
            return
        }
        if let completion {
            cdHashPendingCompletions.append(completion)
        }
        if cdHashInFlight {
            cacheLock.unlock()
            return
        }
        cdHashInFlight = true
        cacheLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hash = Self.readCDHash(forPath: path)
            let requirement = Self.readDesignatedRequirement(forPath: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cacheLock.lock()
                self.cachedCDHash = hash
                self.cachedDesignatedRequirement = requirement
                self.cachedCDHashPath = normalized
                self.cdHashInFlight = false
                let pending = self.cdHashPendingCompletions
                self.cdHashPendingCompletions = []
                self.cacheLock.unlock()
                if let hash {
                    UserDefaults.standard.set(hash, forKey: Self.lastKnownCDHashDefaultsKey)
                    UserDefaults.standard.set(normalized, forKey: Self.lastKnownPathDefaultsKey)
                }
                if let requirement, !requirement.isEmpty {
                    UserDefaults.standard.set(
                        requirement,
                        forKey: Self.lastKnownDesignatedRequirementDefaultsKey
                    )
                }
                // Quietly keep onboarding CDHash/requirement current when TCC identity is unchanged.
                Self.reconcileOnboardingIdentityIfStable(
                    currentCDHash: hash,
                    currentRequirement: requirement,
                    currentPath: path
                )
                for callback in pending {
                    callback(hash)
                }
            }
        }
    }

    /// Last resolved answer to "is a `.build/DevType.app` present?", or `false` until the first
    /// async probe lands.
    ///
    /// Setup and Recovery re-render on every activation, button press, and post-request settle.
    /// Resolving this synchronously meant spawning `mdfind` on the main thread on each of those,
    /// so a slow Spotlight index beach-balled the very window the user opened to unstick
    /// themselves. The warning it feeds is advisory, so showing nothing for the first few hundred
    /// milliseconds is strictly better than blocking the run loop.
    public var cachedDevelopmentBundlePresent: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedDevBundlePresent ?? false
    }

    /// Resolves dual-install presence off the main thread and caches it. Safe to call repeatedly;
    /// concurrent callers coalesce onto one probe. `completion` runs on the main queue.
    public func refreshDevelopmentBundlePresenceAsync(completion: ((Bool) -> Void)? = nil) {
        let runningPath = bundlePath
        let siblings = siblingPaths()

        cacheLock.lock()
        if let completion {
            devBundlePendingCompletions.append(completion)
        }
        if devBundleProbeInFlight {
            cacheLock.unlock()
            return
        }
        devBundleProbeInFlight = true
        cacheLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let present = Self.developmentAppBundlePresentIncludingOnDisk(
                runningPath: runningPath,
                siblingPaths: siblings
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.cacheLock.lock()
                self.cachedDevBundlePresent = present
                self.devBundleProbeInFlight = false
                let pending = self.devBundlePendingCompletions
                self.devBundlePendingCompletions = []
                self.cacheLock.unlock()
                for callback in pending {
                    callback(present)
                }
            }
        }
    }

    public func siblingPaths() -> [String] {
        Self.siblingDevTypePaths(
            fromRunningApps: NSWorkspace.shared.runningApplications.map {
                (
                    bundleIdentifier: $0.bundleIdentifier,
                    bundlePath: $0.bundleURL?.path,
                    localizedName: $0.localizedName
                )
            },
            currentBundleID: bundleIdentifier,
            currentPath: bundlePath
        )
    }

    // MARK: - Pure helpers

    public static func isPackagedAppBundle(bundlePath: String) -> Bool {
        let trimmed = bundlePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (trimmed as NSString).pathExtension == "app"
            || bundlePath.hasSuffix(".app")
            || bundlePath.hasSuffix(".app/")
    }

    public static func normalizedBundlePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func executablePath(forAppBundlePath appPath: String) -> String {
        (appPath as NSString).appendingPathComponent("Contents/MacOS/DevType")
    }

    /// Prefer matching bundle ID (incl. stale legacy); localized name is secondary for unpackaged helpers only.
    public static func siblingDevTypePaths(
        fromRunningApps apps: [(bundleIdentifier: String?, bundlePath: String?, localizedName: String?)],
        currentBundleID: String,
        currentPath: String
    ) -> [String] {
        let current = normalizedBundlePath(currentPath)
        var seen = Set<String>()
        var result: [String] = []
        for app in apps {
            let id = app.bundleIdentifier
            let matchesID = id == currentBundleID
                || id == expectedBundleIdentifier
                || id == legacyStaleBundleIdentifier
            // Name match only when bundle ID is missing (raw Mach-O) to avoid false siblings.
            let matchesName = (id == nil || id?.isEmpty == true)
                && (app.localizedName ?? "").localizedCaseInsensitiveContains("DevType")
            guard matchesID || matchesName else { continue }
            guard let rawPath = app.bundlePath, !rawPath.isEmpty else { continue }
            let path = normalizedBundlePath(rawPath)
            guard path != current else { continue }
            if seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result.sorted()
    }

    /// True when a path looks like the development package (`.build/DevType.app`).
    public static func isDevelopmentAppBundlePath(_ path: String) -> Bool {
        path.contains("/.build/DevType.app") || path.hasSuffix(".build/DevType.app")
    }

    /// True when any running sibling (or known path list) looks like a `.build/DevType.app` package.
    public static func developmentAppBundlePresent(
        runningPath: String,
        siblingPaths: [String],
        additionalExistingPaths: [String] = []
    ) -> Bool {
        let paths = [runningPath] + siblingPaths + additionalExistingPaths
        return paths.contains { isDevelopmentAppBundlePath($0) }
    }

    /// Resolve a `.build/DevType.app` path that contains `path`, or sits under a parent of `path`.
    /// Does not require the development app to be running — only that it exists on disk.
    public static func developmentAppBundlePath(
        containingOrNear path: String,
        fileManager: FileManager = .default
    ) -> String? {
        let normalized = normalizedBundlePath(path)
        // Nested path like .../.build/DevType.app/Contents/MacOS/DevType → bundle root.
        if let range = normalized.range(of: "/.build/DevType.app") {
            let bundle = String(normalized[..<range.upperBound])
            if fileManager.fileExists(atPath: bundle) {
                return normalizedBundlePath(bundle)
            }
        }
        if isDevelopmentAppBundlePath(normalized), fileManager.fileExists(atPath: normalized) {
            return normalized
        }
        var dir = (normalized as NSString).deletingLastPathComponent
        for _ in 0..<16 {
            let candidate = (dir as NSString).appendingPathComponent(".build/DevType.app")
            if fileManager.fileExists(atPath: candidate) {
                return normalizedBundlePath(candidate)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return nil
    }

    /// On-disk `.build/DevType.app` paths discovered from seeds + last-known defaults.
    /// Use for dual-install warnings even when the development copy is not running.
    /// - Parameter spotlightPaths: Inject Spotlight/`mdfind` results in tests; pass `nil` to query
    ///   `mdfind` for `com.devtype.app` bundles (empty array skips Spotlight).
    public static func onDiskDevelopmentAppBundlePaths(
        seedPaths: [String],
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        spotlightPaths: [String]? = nil
    ) -> [String] {
        var found = Set<String>()
        var seeds = seedPaths
        if let last = defaults.string(forKey: lastKnownPathDefaultsKey), !last.isEmpty {
            seeds.append(last)
        }
        if let onboard = defaults.string(forKey: onboardingPathDefaultsKey), !onboard.isEmpty {
            seeds.append(onboard)
        }
        for seed in seeds {
            if let match = developmentAppBundlePath(containingOrNear: seed, fileManager: fileManager) {
                found.insert(normalizedBundlePath(match))
            }
        }
        let spotlight: [String]
        if let spotlightPaths {
            spotlight = spotlightPaths
        } else {
            spotlight = mdfindDevTypeAppPaths()
        }
        for path in spotlight where isDevelopmentAppBundlePath(path) {
            let normalized = normalizedBundlePath(path)
            if fileManager.fileExists(atPath: normalized) {
                found.insert(normalized)
            }
        }
        return found.sorted()
    }

    /// Convenience: development package present among running paths **or** on disk.
    ///
    /// Spawns `mdfind` when `spotlightPaths` is nil — blocking. UI callers must go through
    /// `refreshDevelopmentBundlePresenceAsync` / `cachedDevelopmentBundlePresent` instead.
    public static func developmentAppBundlePresentIncludingOnDisk(
        runningPath: String,
        siblingPaths: [String],
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        spotlightPaths: [String]? = nil
    ) -> Bool {
        let onDisk = onDiskDevelopmentAppBundlePaths(
            seedPaths: [runningPath] + siblingPaths + [preferredInstalledAppPath],
            fileManager: fileManager,
            defaults: defaults,
            spotlightPaths: spotlightPaths
        )
        return developmentAppBundlePresent(
            runningPath: runningPath,
            siblingPaths: siblingPaths,
            additionalExistingPaths: onDisk
        )
    }

    /// Spotlight discovery of installed DevType.app bundles (best-effort; may be empty).
    ///
    /// Blocking and process-spawning — never call from the main thread. UI reads the cached
    /// result via `cachedDevelopmentBundlePresent`; see `refreshDevelopmentBundlePresenceAsync`.
    public static func mdfindDevTypeAppPaths() -> [String] {
        guard let result = BoundedProcess.run(
            executable: "/usr/bin/mdfind",
            arguments: ["kMDItemCFBundleIdentifier == '\(expectedBundleIdentifier)'"],
            timeout: mdfindTimeout
        ) else {
            return []
        }
        if result.timedOut {
            DevTypeLog.identity.notice(
                "[Identity] mdfind timed out — dual-install detection falls back to seed paths only"
            )
        }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map { normalizedBundlePath(String($0)) }
            .filter { $0.hasSuffix(".app") }
    }

    /// Warn when Privacy lists may still show the pre-rename bundle id.
    public static func staleLegacyBundleWarning(
        runningBundleIDs: [String?]
    ) -> String? {
        let stale = runningBundleIDs.contains { $0 == legacyStaleBundleIdentifier }
        guard stale else { return nil }
        return """
        A process still uses the stale bundle id \(legacyStaleBundleIdentifier). Quit it and remove that entry from Accessibility / Input Monitoring — only \(expectedBundleIdentifier) grants apply to this app.
        """
    }

    /// Static guidance when Settings toggles look on but CG/AX preflight is still denied.
    public static func settingsToggleMismatchGuidance(
        executablePath: String,
        cdHash: String?
    ) -> String {
        var lines = [
            "If Settings shows DevType enabled but Listen/AX/Post below are Denied, you enabled a different DevType copy.",
            "Remove other DevType entries (including \(legacyStaleBundleIdentifier) if listed), click Request for THIS path, enable that exact entry, then Relaunch.",
            "This binary: \(executablePath)"
        ]
        if let cdHash, !cdHash.isEmpty {
            lines.append("This CDHash: \(cdHash)")
        }
        lines.append("Recommended identity: \(preferredInstalledAppPath) (\(expectedBundleIdentifier)).")
        return lines.joined(separator: "\n")
    }

    public static func duplicateProcessWarning(siblingPaths: [String]) -> String? {
        guard !siblingPaths.isEmpty else { return nil }
        let listed = siblingPaths.joined(separator: "\n• ")
        return """
        Other DevType copies are running — quit them so Settings toggles apply to THIS identity:
        • \(listed)
        """
    }

    /// Canonical installed path for Launchpad / stable TCC identity.
    public static let preferredInstalledAppPath = "/Applications/DevType.app"

    /// Development package path (secondary to Applications).
    public static let developmentAppPathHint = ".build/DevType.app"

    public static func unpackagedBinaryWarning(bundlePath: String) -> String? {
        guard !isPackagedAppBundle(bundlePath: bundlePath) else { return nil }
        return "This process is not a packaged .app (\(bundlePath)). Quit and open \(preferredInstalledAppPath) (or package + ./Scripts/install-app.sh) so TCC can list \(expectedBundleIdentifier)."
    }

    /// Warn when both Applications and a `.build` package exist — prefer Applications.
    public static func dualInstallWarning(
        runningPath: String,
        applicationsExists: Bool,
        buildBundleExists: Bool
    ) -> String? {
        guard applicationsExists, buildBundleExists else { return nil }
        let running = normalizedBundlePath(runningPath)
        let apps = normalizedBundlePath(preferredInstalledAppPath)
        let runningApps = running == apps
        return """
        Both \(preferredInstalledAppPath) and a \(developmentAppPathHint) exist. Prefer \(preferredInstalledAppPath) for TCC and Launchpad — quit the other copy\(runningApps ? " (.build is also present)" : " (you are not running Applications)").
        """
    }

    /// True when Finish / markOnboardingCompleted is allowed.
    /// Requires Accessibility + finished CDHash load. Listen + running tap are not required to
    /// Finish (menu/Recovery stay honest about Active vs incomplete Listen/tap).
    /// `canListenTap` / `tapRunning` remain in the signature for call-site compatibility.
    public static func canFinishOnboarding(
        canListenTap: Bool,
        tapRunning: Bool,
        canUseAX: Bool,
        cdHash: String?,
        cdHashLoadFinished: Bool
    ) -> Bool {
        _ = canListenTap
        _ = tapRunning
        guard canUseAX, cdHashLoadFinished else { return false }
        // `cdHash` is recorded by the caller when non-nil; nil after load means codesign unavailable.
        _ = cdHash
        return true
    }

    /// Input Monitoring → Accessibility advance rule.
    ///
    /// Mirrors `canAdvanceFromVerify`: Listen is needed for Active expansion, but it must never be
    /// a dead end. The step gated hard on `canListenTap`, so a user whose Input Monitoring grant
    /// cannot be established (stale TCC record for a previous copy is the common one) could not
    /// reach Verify — and therefore could never Finish — even though Verify and Done both treat a
    /// missing Listen as non-blocking. Advancing after a real request attempt keeps the ordering
    /// intact while letting such a user get to Accessibility and finish in the degraded mode the
    /// later steps already support.
    public static func canAdvanceFromInputMonitoring(
        canListenTap: Bool,
        didAttemptRequest: Bool
    ) -> Bool {
        canListenTap || didAttemptRequest
    }

    /// Verify → Done advances when Accessibility is granted.
    /// Listen + tap may still be incomplete (surfaced in UI; not blocking).
    public static func canAdvanceFromVerify(
        canListenTap: Bool,
        tapRunning: Bool,
        canUseAX: Bool
    ) -> Bool {
        _ = canListenTap
        _ = tapRunning
        return canUseAX
    }

    public static func parseCDHash(fromCodesignOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("CDHash=") {
                let value = trimmed.dropFirst("CDHash=".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : String(value)
            }
        }
        return nil
    }

    /// Parses `codesign -d -r-` output (`designated => …` or `# designated => …`).
    public static func parseDesignatedRequirement(fromCodesignRequirementOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                trimmed = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("designated => ") {
                let value = trimmed.dropFirst("designated => ".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : String(value)
            }
        }
        return nil
    }

    public static func readCDHash(forPath path: String) -> String? {
        // Bounded: a hung `codesign` used to leave `cdHashLoadFinished` false forever, which
        // permanently disables Finish in the Setup wizard. See `BoundedProcess`.
        guard let result = BoundedProcess.run(
            executable: "/usr/bin/codesign",
            arguments: ["-dvvv", path],
            timeout: codesignTimeout,
            mergeStandardError: true
        ) else {
            return nil
        }
        let hash = parseCDHash(fromCodesignOutput: result.output)
        if hash == nil {
            DevTypeLog.identity.notice(
                "[Identity] CDHash unavailable for path=\(path, privacy: .public) exit=\(result.exitCode, privacy: .public) timedOut=\(result.timedOut, privacy: .public)"
            )
        }
        return hash
    }

    public static func readDesignatedRequirement(forPath path: String) -> String? {
        // Requirement text is written to stdout; some codesign versions also use stderr.
        guard let result = BoundedProcess.run(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "-r-", path],
            timeout: codesignTimeout,
            mergeStandardError: true
        ) else {
            return nil
        }
        return parseDesignatedRequirement(fromCodesignRequirementOutput: result.output)
    }

    /// Remembers Accessibility grant bound to the current CDHash (not sticky forever).
    public static func rememberAccessibilityGranted(
        _ granted: Bool,
        cdHash: String?,
        defaults: UserDefaults = .standard
    ) {
        guard granted, let cdHash, !cdHash.isEmpty else { return }
        defaults.set(cdHash, forKey: accessibilityGrantedCDHashDefaultsKey)
    }

    public static func accessibilityAppearsReset(
        grantedCDHash: String?,
        currentCDHash: String?,
        isCurrentlyGranted: Bool
    ) -> Bool {
        guard !isCurrentlyGranted else { return false }
        guard let granted = grantedCDHash, !granted.isEmpty else { return false }
        // Same binary identity previously had AX; now missing → reset for this CDHash.
        if let current = currentCDHash, !current.isEmpty {
            return granted == current
        }
        return true
    }

    public static func binaryIdentityChanged(
        storedCDHash: String?,
        storedPath: String?,
        currentCDHash: String?,
        currentPath: String,
        storedDesignatedRequirement: String? = nil,
        currentDesignatedRequirement: String? = nil
    ) -> Bool {
        let normalizedCurrent = normalizedBundlePath(currentPath)
        if let storedPath, !storedPath.isEmpty,
           normalizedBundlePath(storedPath) != normalizedCurrent {
            return true
        }
        // TCC pins certificate-signed apps to the designated requirement, not CDHash.
        // Requirement change (ad-hoc ↔ cert, or different cert) invalidates grants.
        if let storedReq = storedDesignatedRequirement, !storedReq.isEmpty,
           let currentReq = currentDesignatedRequirement, !currentReq.isEmpty,
           storedReq != currentReq {
            return true
        }
        // Legacy / still-loading: fall back to CDHash only when neither side has a requirement.
        // CDHash-only churn under a stable requirement must NOT count as identity change.
        let haveRequirement = !(storedDesignatedRequirement ?? "").isEmpty
            || !(currentDesignatedRequirement ?? "").isEmpty
        if !haveRequirement,
           let stored = storedCDHash, !stored.isEmpty,
           let current = currentCDHash, !current.isEmpty {
            return stored != current
        }
        return false
    }

    /// When onboarding completed without a CDHash (legacy / codesign race), backfill once hash arrives.
    @discardableResult
    public static func backfillOnboardingCDHashIfNeeded(
        currentCDHash: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: onboardingCompletedDefaultsKey) else { return false }
        let stored = defaults.string(forKey: onboardingCDHashDefaultsKey)
        guard stored == nil || stored?.isEmpty == true else { return false }
        guard let currentCDHash, !currentCDHash.isEmpty else { return false }
        defaults.set(currentCDHash, forKey: onboardingCDHashDefaultsKey)
        DevTypeLog.identity.info(
            "[Identity] backfilled onboarding CDHash=\(currentCDHash, privacy: .public)"
        )
        return true
    }

    /// Keep stored onboarding CDHash/requirement current when path + requirement are stable.
    /// Avoids Recovery loops after cert-signed rebuilds that only change CDHash.
    @discardableResult
    public static func reconcileOnboardingIdentityIfStable(
        currentCDHash: String?,
        currentRequirement: String?,
        currentPath: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: onboardingCompletedDefaultsKey) else { return false }
        let storedPath = defaults.string(forKey: onboardingPathDefaultsKey)
        let storedReq = defaults.string(forKey: onboardingDesignatedRequirementDefaultsKey)
        let storedHash = defaults.string(forKey: onboardingCDHashDefaultsKey)
        if binaryIdentityChanged(
            storedCDHash: storedHash,
            storedPath: storedPath,
            currentCDHash: currentCDHash,
            currentPath: currentPath,
            storedDesignatedRequirement: storedReq,
            currentDesignatedRequirement: currentRequirement
        ) {
            return false
        }
        var changed = false
        if let currentCDHash, !currentCDHash.isEmpty, currentCDHash != storedHash {
            defaults.set(currentCDHash, forKey: onboardingCDHashDefaultsKey)
            changed = true
        }
        if let currentRequirement, !currentRequirement.isEmpty, currentRequirement != storedReq {
            // First-time requirement backfill for legacy onboarding rows (same CDHash path).
            defaults.set(currentRequirement, forKey: onboardingDesignatedRequirementDefaultsKey)
            changed = true
        }
        if changed {
            defaults.set(normalizedBundlePath(currentPath), forKey: onboardingPathDefaultsKey)
            DevTypeLog.identity.info(
                "[Identity] reconciled onboarding identity path=\(normalizedBundlePath(currentPath), privacy: .public) cdHash=\(currentCDHash ?? "nil", privacy: .public) requirement=\(currentRequirement ?? "nil", privacy: .public)"
            )
        }
        return changed
    }

    public static func markOnboardingCompleted(
        cdHash: String?,
        path: String,
        designatedRequirement: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: onboardingCompletedDefaultsKey)
        defaults.set(normalizedBundlePath(path), forKey: onboardingPathDefaultsKey)
        if let cdHash, !cdHash.isEmpty {
            defaults.set(cdHash, forKey: onboardingCDHashDefaultsKey)
        }
        let requirement = designatedRequirement
            ?? ProcessIdentity.shared.cachedDesignatedRequirementString
        if let requirement, !requirement.isEmpty {
            defaults.set(requirement, forKey: onboardingDesignatedRequirementDefaultsKey)
        }
        DevTypeLog.identity.info(
            "[Identity] onboardingCompleted=true path=\(normalizedBundlePath(path), privacy: .public) cdHash=\(cdHash ?? "nil", privacy: .public)"
        )
    }

    /// After Recovery re-grant for a new binary identity, update stored onboarding CDHash/path
    /// so the next launch does not re-open Recovery in a loop.
    public static func updateOnboardingIdentity(
        cdHash: String?,
        path: String,
        designatedRequirement: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.bool(forKey: onboardingCompletedDefaultsKey) else { return }
        defaults.set(normalizedBundlePath(path), forKey: onboardingPathDefaultsKey)
        if let cdHash, !cdHash.isEmpty {
            defaults.set(cdHash, forKey: onboardingCDHashDefaultsKey)
        }
        let requirement = designatedRequirement
            ?? ProcessIdentity.shared.cachedDesignatedRequirementString
        if let requirement, !requirement.isEmpty {
            defaults.set(requirement, forKey: onboardingDesignatedRequirementDefaultsKey)
        }
        DevTypeLog.identity.info(
            "[Identity] updated onboarding identity path=\(normalizedBundlePath(path), privacy: .public) cdHash=\(cdHash ?? "nil", privacy: .public)"
        )
    }

    public static func isOnboardingCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: onboardingCompletedDefaultsKey)
    }

    public static func shouldReOnboardForIdentityChange(
        defaults: UserDefaults = .standard,
        currentCDHash: String?,
        currentPath: String,
        currentDesignatedRequirement: String? = nil
    ) -> Bool {
        guard defaults.bool(forKey: onboardingCompletedDefaultsKey) else { return false }
        return binaryIdentityChanged(
            storedCDHash: defaults.string(forKey: onboardingCDHashDefaultsKey),
            storedPath: defaults.string(forKey: onboardingPathDefaultsKey),
            currentCDHash: currentCDHash,
            currentPath: currentPath,
            storedDesignatedRequirement: defaults.string(forKey: onboardingDesignatedRequirementDefaultsKey),
            currentDesignatedRequirement: currentDesignatedRequirement
        )
    }
}
