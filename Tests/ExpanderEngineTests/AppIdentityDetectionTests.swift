import XCTest
@testable import ExpanderEngine

final class AppIdentityDetectionTests: XCTestCase {

    // MARK: - Identity / Settings listing helpers

    func testIsPackagedAppBundlePaths() {
        XCTAssertTrue(ProcessIdentity.isPackagedAppBundle(bundlePath: "/Users/me/Code/DevType/.build/DevType.app"))
        XCTAssertTrue(ProcessIdentity.isPackagedAppBundle(bundlePath: "/Users/me/Code/DevType/.build/DevType.app/"))
        XCTAssertFalse(ProcessIdentity.isPackagedAppBundle(bundlePath: "/Users/me/Code/DevType/.build/debug/DevType"))
        XCTAssertFalse(ProcessIdentity.isPackagedAppBundle(bundlePath: "/Users/me/Code/DevType/.build/arm64-apple-macosx/debug"))
    }

    func testSiblingDevTypePathsExcludesCurrentAndDedupes() {
        let current = "/Users/me/Code/DevType/.build/DevType.app"
        let siblings = ProcessIdentity.siblingDevTypePaths(
            fromRunningApps: [
                (bundleIdentifier: "com.devtype.app", bundlePath: current, localizedName: "DevType"),
                (bundleIdentifier: "com.devtype.app", bundlePath: "/Users/me/Code/DevType/build/DevType.app", localizedName: "DevType"),
                (bundleIdentifier: "com.devtype.app", bundlePath: "/Users/me/Code/DevType/build/DevType.app", localizedName: "DevType"),
                (bundleIdentifier: "com.apple.Safari", bundlePath: "/Applications/Safari.app", localizedName: "Safari"),
                (bundleIdentifier: nil, bundlePath: "/tmp/OtherDevType.app", localizedName: "DevType Helper"),
                (
                    bundleIdentifier: ProcessIdentity.legacyStaleBundleIdentifier,
                    bundlePath: "/tmp/LegacyDevType.app",
                    localizedName: "DevType"
                )
            ],
            currentBundleID: "com.devtype.app",
            currentPath: current
        )
        XCTAssertEqual(
            siblings,
            [
                "/Users/me/Code/DevType/build/DevType.app",
                "/tmp/LegacyDevType.app",
                "/tmp/OtherDevType.app"
            ]
        )
    }

    func testLivePreflightSummaryAndSettingsMismatchGuidance() {
        let denied = PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: true)
        let line = PermissionCopy.livePreflightSummary(snapshot: denied)
        XCTAssertTrue(line.contains("LIVE preflight"))
        XCTAssertTrue(line.contains("Listen: Denied"))
        XCTAssertTrue(line.contains("AX: Denied"))
        XCTAssertTrue(line.contains("Post: Granted"))

        let guide = ProcessIdentity.settingsToggleMismatchGuidance(
            executablePath: "/Applications/DevType.app/Contents/MacOS/DevType",
            cdHash: "abc123"
        )
        XCTAssertTrue(guide.contains(ProcessIdentity.legacyStaleBundleIdentifier))
        XCTAssertTrue(guide.contains("abc123"))
        XCTAssertTrue(guide.contains(ProcessIdentity.preferredInstalledAppPath))
        XCTAssertTrue(PermissionCopy.staleLegacyBundleIdGuidance.contains(ProcessIdentity.legacyStaleBundleIdentifier))
        XCTAssertTrue(
            PermissionCopy.relaunchAfterSettingsGuidance(missingNames: ["Input Monitoring"])
                .localizedCaseInsensitiveContains("Relaunch")
        )
    }

    func testDevelopmentAppBundlePresentAndStaleLegacyWarning() {
        XCTAssertTrue(
            ProcessIdentity.developmentAppBundlePresent(
                runningPath: "/Applications/DevType.app",
                siblingPaths: ["/Users/me/Code/DevType/.build/DevType.app"]
            )
        )
        XCTAssertFalse(
            ProcessIdentity.developmentAppBundlePresent(
                runningPath: "/Applications/DevType.app",
                siblingPaths: []
            )
        )
        XCTAssertNotNil(
            ProcessIdentity.staleLegacyBundleWarning(
                runningBundleIDs: [ProcessIdentity.legacyStaleBundleIdentifier]
            )
        )
        XCTAssertNil(ProcessIdentity.staleLegacyBundleWarning(runningBundleIDs: ["com.devtype.app"]))
    }

    func testOnDiskDevelopmentAppBundlePathsWithoutRunningSibling() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devtype-ondisk-\(UUID().uuidString)")
        let buildApp = root.appendingPathComponent(".build/DevType.app")
        try fm.createDirectory(at: buildApp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let suite = "devtype.tests.ondisk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Seed from Applications-like path that walks up into the temp repo root.
        let seed = root.appendingPathComponent("Package.swift").path
        try "test".write(toFile: seed, atomically: true, encoding: .utf8)
        let found = ProcessIdentity.onDiskDevelopmentAppBundlePaths(
            seedPaths: [seed],
            fileManager: fm,
            defaults: defaults,
            spotlightPaths: []
        )
        XCTAssertEqual(found, [ProcessIdentity.normalizedBundlePath(buildApp.path)])

        XCTAssertTrue(
            ProcessIdentity.developmentAppBundlePresentIncludingOnDisk(
                runningPath: "/Applications/DevType.app",
                siblingPaths: [],
                fileManager: fm,
                defaults: defaults,
                spotlightPaths: [buildApp.path]
            )
        )
        XCTAssertFalse(
            ProcessIdentity.developmentAppBundlePresentIncludingOnDisk(
                runningPath: "/Applications/DevType.app",
                siblingPaths: [],
                fileManager: fm,
                defaults: defaults,
                spotlightPaths: []
            )
        )
    }

    func testSiblingDoesNotMatchUnrelatedNameOnlyAppsWithBundleID() {
        let siblings = ProcessIdentity.siblingDevTypePaths(
            fromRunningApps: [
                (bundleIdentifier: "com.example.Notes", bundlePath: "/tmp/Notes.app", localizedName: "DevType Notes")
            ],
            currentBundleID: "com.devtype.app",
            currentPath: "/Users/me/.build/DevType.app"
        )
        XCTAssertTrue(siblings.isEmpty)
    }

    func testDuplicateProcessWarningNilWhenEmpty() {
        XCTAssertNil(ProcessIdentity.duplicateProcessWarning(siblingPaths: []))
        let warning = ProcessIdentity.duplicateProcessWarning(
            siblingPaths: ["/Users/me/Code/DevType/build/DevType.app"]
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("build/DevType.app"))
        XCTAssertTrue(warning!.localizedCaseInsensitiveContains("quit"))
    }

    func testUnpackagedBinaryWarning() {
        XCTAssertNil(ProcessIdentity.unpackagedBinaryWarning(bundlePath: "/tmp/DevType.app"))
        let warning = ProcessIdentity.unpackagedBinaryWarning(bundlePath: "/tmp/.build/debug/DevType")
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("com.devtype.app"))
    }

    func testSettingsToggleAndOpenButtonTitles() {
        XCTAssertEqual(PermissionCopy.settingsToggleDisplayName(for: .accessibility), "Accessibility")
        XCTAssertEqual(PermissionCopy.settingsToggleDisplayName(for: .inputMonitoring), "Input Monitoring")
        XCTAssertEqual(PermissionCopy.settingsToggleDisplayName(for: .postEvent), "Accessibility")
        XCTAssertEqual(PermissionCopy.openSettingsButtonTitle(for: .accessibility), "Open Settings")
        XCTAssertEqual(PermissionCopy.openSettingsButtonTitle(for: .inputMonitoring), "Open Settings")
        XCTAssertEqual(PermissionCopy.openSettingsButtonTitle(for: .postEvent), "Open Accessibility")
    }

    func testOpenSettingsWithoutRequestHintMentionsRequestFirst() {
        let access = PermissionCopy.openSettingsWithoutRequestHint(
            for: .accessibility,
            bundleID: "com.devtype.app"
        )
        XCTAssertTrue(access.localizedCaseInsensitiveContains("Request"))
        XCTAssertTrue(access.contains("com.devtype.app"))

        let input = PermissionCopy.openSettingsWithoutRequestHint(
            for: .inputMonitoring,
            bundleID: "com.devtype.app"
        )
        XCTAssertTrue(input.localizedCaseInsensitiveContains("Request"))
        XCTAssertTrue(input.localizedCaseInsensitiveContains("Input Monitoring"))
        XCTAssertTrue(input.localizedCaseInsensitiveContains("DevType"))

        let post = PermissionCopy.openSettingsWithoutRequestHint(
            for: .postEvent,
            bundleID: "com.devtype.app"
        )
        XCTAssertTrue(post.localizedCaseInsensitiveContains("no Privacy list"))
        XCTAssertTrue(post.localizedCaseInsensitiveContains("Request"))
    }

    func testExecutablePathForAppBundle() {
        XCTAssertEqual(
            ProcessIdentity.executablePath(forAppBundlePath: "/Users/me/.build/DevType.app"),
            "/Users/me/.build/DevType.app/Contents/MacOS/DevType"
        )
    }

    func testNotListedInSettingsGuidanceIncludesPathAndToggle() {
        let guide = PermissionCopy.notListedInSettingsGuidance(
            for: .inputMonitoring,
            bundleID: "com.devtype.app",
            appPath: "/Users/me/.build/DevType.app",
            siblingPaths: ["/Users/me/build/DevType.app"],
            binaryPath: "/Users/me/.build/DevType.app/Contents/MacOS/DevType"
        )
        XCTAssertTrue(guide.contains("Input Monitoring"))
        XCTAssertTrue(guide.contains("com.devtype.app"))
        XCTAssertTrue(guide.contains("/Users/me/.build/DevType.app"))
        XCTAssertTrue(guide.contains("/Users/me/build/DevType.app"))
        XCTAssertTrue(guide.contains("Contents/MacOS/DevType"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("Request"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("+"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("scroll"))

        let post = PermissionCopy.notListedInSettingsGuidance(
            for: .postEvent,
            bundleID: "com.devtype.app",
            appPath: "/Users/me/.build/DevType.app",
            siblingPaths: []
        )
        XCTAssertTrue(post.localizedCaseInsensitiveContains("not a Settings list"))
        XCTAssertTrue(post.localizedCaseInsensitiveContains("Accessibility"))
    }

    func testSettingsOpenResultNeverProvisionalTrueWithoutOpen() {
        // Constructed results must reflect honest didOpen — callers must not invent true.
        let pending = SettingsDeepLinker.OpenResult(
            modernURL: URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!,
            legacyURL: URL(string: "x-apple.systempreferences:com.apple.preference.security")!,
            usedModern: true,
            didOpen: false
        )
        XCTAssertFalse(pending.didOpen)
    }

    func testSettingsOpenFailureMessageIncludesBundleID() {
        let message = PermissionCopy.settingsOpenFailureMessage(for: .accessibility)
        XCTAssertTrue(message.contains(ProcessIdentity.expectedBundleIdentifier))
    }

    func testParseCDHashFromCodesignOutput() {
        let sample = """
        Executable=/Users/me/.build/DevType.app/Contents/MacOS/DevType
        Identifier=com.devtype.app
        CDHash=bb726507e094387f8a1c200fe83254eb36c8b969
        Signature=adhoc
        """
        XCTAssertEqual(
            ProcessIdentity.parseCDHash(fromCodesignOutput: sample),
            "bb726507e094387f8a1c200fe83254eb36c8b969"
        )
        XCTAssertNil(ProcessIdentity.parseCDHash(fromCodesignOutput: "Identifier=com.devtype.app\n"))
    }

    func testAccessibilityAppearsResetBoundToCDHash() {
        XCTAssertTrue(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: "abc",
                currentCDHash: "abc",
                isCurrentlyGranted: false
            )
        )
        XCTAssertFalse(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: "abc",
                currentCDHash: "def",
                isCurrentlyGranted: false
            )
        )
        XCTAssertFalse(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: nil,
                currentCDHash: "abc",
                isCurrentlyGranted: false
            )
        )
        XCTAssertFalse(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: "abc",
                currentCDHash: "abc",
                isCurrentlyGranted: true
            )
        )
    }

    func testBinaryIdentityChangedDetectsCDHashAndPath() {
        XCTAssertTrue(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/old/DevType.app",
                currentCDHash: "bbb",
                currentPath: "/old/DevType.app"
            ),
            "Legacy CDHash churn without requirement"
        )
        XCTAssertTrue(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/old/DevType.app",
                currentCDHash: "aaa",
                currentPath: "/new/DevType.app"
            )
        )
        XCTAssertFalse(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/same/DevType.app",
                currentCDHash: "aaa",
                currentPath: "/same/DevType.app"
            )
        )
        let req = "identifier \"com.devtype.app\" and certificate root = H\"abc\""
        XCTAssertFalse(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/same/DevType.app",
                currentCDHash: "bbb",
                currentPath: "/same/DevType.app",
                storedDesignatedRequirement: req,
                currentDesignatedRequirement: req
            ),
            "Stable requirement must ignore CDHash churn"
        )
    }

    func testBinaryChangedGuidanceMentionsResignAndPath() {
        let text = PermissionCopy.binaryChangedGuidance(
            appPath: "/Users/me/Code/DevType/.build/DevType.app",
            cdHash: "abc123"
        )
        XCTAssertTrue(text.localizedCaseInsensitiveContains("re-signed") || text.localizedCaseInsensitiveContains("identity"))
        XCTAssertTrue(text.contains(ProcessIdentity.preferredInstalledAppPath))
        XCTAssertTrue(text.contains(".build/DevType.app"))
        XCTAssertTrue(text.contains("abc123"))
    }
}
