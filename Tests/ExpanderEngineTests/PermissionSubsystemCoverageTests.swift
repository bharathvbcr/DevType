import AppKit
import Foundation
import XCTest
@testable import ExpanderEngine

final class PermissionSubsystemCoverageTests: XCTestCase {

    // MARK: - PermissionProbe

    func testPermissionProbeWrappers() {
        let probe = PermissionProbe()
        let snapshot = probe.snapshot()

        XCTAssertEqual(probe.canListenTap(), snapshot.canListenTap)
        XCTAssertEqual(probe.canUseAX(), snapshot.canUseAX)
        XCTAssertEqual(probe.canPostEvents(), snapshot.canPostEvents)
    }

    // MARK: - AppRelauncher

    func testAppRelauncherWaiterArguments() {
        let pid: pid_t = 12345
        let bundlePath = "/Applications/Dev Type.app"
        let args = AppRelauncher.waiterArguments(pid: pid, bundlePath: bundlePath)

        XCTAssertEqual(args[0], "-c")
        XCTAssertEqual(args[1], AppRelauncher.waiterScript)
        XCTAssertEqual(args[2], "sh")
        XCTAssertEqual(args[3], "12345")
        XCTAssertEqual(args[4], bundlePath)
        XCTAssertEqual(args[5], AppRelauncher.pollInterval)
        XCTAssertEqual(args[6], AppRelauncher.settleDelay)
        let expectedIterations = max(1, Int((Double(AppRelauncher.maxWaitSeconds) / (Double(AppRelauncher.pollInterval) ?? 0.2)).rounded()))
        XCTAssertEqual(args[7], String(expectedIterations))
    }

    func testAppRelauncherRelaunchWithCustomTerminate() {
        var terminated = false
        let dummyURL = URL(fileURLWithPath: "/tmp/NonExistentDevTypeApp.app")
        let spawned = AppRelauncher.relaunch(bundleURL: dummyURL) {
            terminated = true
        }
        XCTAssertTrue(spawned)
        XCTAssertTrue(terminated)
    }

    // MARK: - PermissionObserver

    func testPermissionObserverLifecycleAndNotifications() {
        let observer = PermissionObserver()
        let snapshot = observer.currentSnapshot
        XCTAssertNotNil(snapshot)

        var notifiedSnapshot: PermissionSnapshot?
        observer.start { snap in
            notifiedSnapshot = snap
        }

        observer.refreshNow()
        XCTAssertNotNil(notifiedSnapshot)

        // Reset and fire didBecomeActiveNotification
        notifiedSnapshot = nil
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertNotNil(notifiedSnapshot)

        // Reset and fire didActivateApplicationNotification
        notifiedSnapshot = nil
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Might or might not notify if snapshot didn't change (force: false)
        // But stop should clean everything up
        observer.stop()

        notifiedSnapshot = nil
        observer.refreshNow()
        XCTAssertNil(notifiedSnapshot, "Observer stopped should not invoke callback")
    }

    // MARK: - PermissionCopy Localized

    func testPermissionCopyLocalizedEnumKinds() {
        let loc = PermissionCopy.localized()
        let kinds: [PermissionKind] = [.accessibility, .inputMonitoring, .postEvent, .microphone, .speechRecognition]

        for kind in kinds {
            let desc = loc.unlockDescription(for: kind)
            XCTAssertFalse(desc.isEmpty)

            let name = loc.settingsToggleDisplayName(for: kind)
            XCTAssertFalse(name.isEmpty)

            let button = loc.openSettingsButtonTitle(for: kind)
            XCTAssertFalse(button.isEmpty)

            let hint = loc.openSettingsWithoutRequestHint(for: kind, bundleID: "com.test.app")
            XCTAssertFalse(hint.isEmpty)

            let notListed = loc.notListedInSettingsGuidance(
                for: kind,
                bundleID: "com.test.app",
                appPath: "/Applications/DevType.app",
                siblingPaths: ["/Applications/Other.app"],
                binaryPath: "/Applications/DevType.app/Contents/MacOS/DevType"
            )
            XCTAssertFalse(notListed.isEmpty)

            let failureMsg = loc.settingsOpenFailureMessage(for: kind)
            XCTAssertFalse(failureMsg.isEmpty)
        }

        let noneFailureMsg = loc.settingsOpenFailureMessage(for: nil)
        XCTAssertFalse(noneFailureMsg.isEmpty)
    }

    func testPermissionCopyLocalizedIdentityAndGuidance() {
        let loc = PermissionCopy.localized()

        let binaryChanged1 = loc.binaryChangedGuidance(appPath: "/Applications/DevType.app", cdHash: "hash123")
        XCTAssertTrue(binaryChanged1.contains("hash123"))
        let binaryChanged2 = loc.binaryChangedGuidance(appPath: "/Applications/DevType.app", cdHash: nil)
        XCTAssertFalse(binaryChanged2.isEmpty)

        let unpackagedWarn = loc.unpackagedBinaryWarning(bundlePath: "/usr/local/bin/devtype")
        XCTAssertNotNil(unpackagedWarn)
        let packagedWarn = loc.unpackagedBinaryWarning(bundlePath: "/Applications/DevType.app")
        XCTAssertNil(packagedWarn)

        let dupWarn = loc.duplicateProcessWarning(siblingPaths: ["/tmp/app1", "/tmp/app2"])
        XCTAssertNotNil(dupWarn)
        XCTAssertNil(loc.duplicateProcessWarning(siblingPaths: []))

        let mismatch1 = loc.settingsToggleMismatchGuidance(executablePath: "/path/bin", cdHash: "cdhash")
        XCTAssertTrue(mismatch1.contains("cdhash"))
        let mismatch2 = loc.settingsToggleMismatchGuidance(executablePath: "/path/bin", cdHash: nil)
        XCTAssertFalse(mismatch2.isEmpty)

        let staleWarn = loc.staleLegacyBundleWarning(runningBundleIDs: [ProcessIdentity.legacyStaleBundleIdentifier])
        XCTAssertNotNil(staleWarn)
        XCTAssertNil(loc.staleLegacyBundleWarning(runningBundleIDs: ["com.random.app"]))

        let dualWarn1 = loc.dualInstallWarning(
            runningPath: ProcessIdentity.preferredInstalledAppPath,
            applicationsExists: true,
            buildBundleExists: true
        )
        XCTAssertNotNil(dualWarn1)
        let dualWarn2 = loc.dualInstallWarning(
            runningPath: "/some/other/path",
            applicationsExists: true,
            buildBundleExists: true
        )
        XCTAssertNotNil(dualWarn2)
        XCTAssertNil(loc.dualInstallWarning(runningPath: "/path", applicationsExists: false, buildBundleExists: true))

        let degradedTooltip = loc.degradedInjectTooltip(snapshot: PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: false))
        XCTAssertFalse(degradedTooltip.isEmpty)

        let preflightSummary = loc.livePreflightSummary(snapshot: PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: true))
        XCTAssertFalse(preflightSummary.isEmpty)

        XCTAssertFalse(loc.tapCreateFailedDespiteListenGuidance.isEmpty)
        XCTAssertFalse(loc.relaunchAfterSettingsGuidance(missingNames: []).isEmpty)
        XCTAssertFalse(loc.relaunchAfterSettingsGuidance(missingNames: ["Accessibility"]).isEmpty)
        XCTAssertFalse(loc.staleTCCRecordGuidance.isEmpty)
        XCTAssertFalse(loc.staleLegacyBundleIdGuidance.isEmpty)

        // Missing summaries: 0, 1, 2, 3
        let snap0 = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)
        XCTAssertFalse(loc.missingCapabilitiesSummary(snap0).isEmpty)

        let snap1 = PermissionSnapshot(canListenTap: false, canUseAX: true, canPostEvents: true)
        XCTAssertFalse(loc.missingCapabilitiesSummary(snap1).isEmpty)

        let snap2 = PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: true)
        XCTAssertFalse(loc.missingCapabilitiesSummary(snap2).isEmpty)

        let snap3 = PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: false)
        XCTAssertFalse(loc.missingCapabilitiesSummary(snap3).isEmpty)
    }

    func testPermissionCopyStaticFallbacks() {
        let kinds: [PermissionKind] = [.accessibility, .inputMonitoring, .postEvent, .microphone, .speechRecognition]
        for kind in kinds {
            XCTAssertFalse(PermissionCopy.unlockDescription(for: kind).isEmpty)
            XCTAssertFalse(PermissionCopy.openSettingsButtonTitle(for: kind).isEmpty)
            XCTAssertFalse(PermissionCopy.settingsToggleDisplayName(for: kind).isEmpty)
            XCTAssertFalse(PermissionCopy.openSettingsWithoutRequestHint(for: kind, bundleID: "com.test").isEmpty)
            XCTAssertFalse(PermissionCopy.notListedInSettingsGuidance(
                for: kind,
                bundleID: "com.test",
                appPath: "/Applications/DevType.app",
                siblingPaths: []
            ).isEmpty)
            XCTAssertFalse(PermissionCopy.settingsOpenFailureMessage(for: kind).isEmpty)
        }
        XCTAssertFalse(PermissionCopy.settingsOpenFailureMessage(for: nil).isEmpty)
        XCTAssertFalse(PermissionCopy.binaryChangedGuidance(appPath: "/Applications/DevType.app", cdHash: "hash").isEmpty)
        XCTAssertFalse(PermissionCopy.relaunchAfterSettingsGuidance(missingNames: []).isEmpty)
        XCTAssertFalse(PermissionCopy.relaunchAfterSettingsGuidance(missingNames: ["Input Monitoring"]).isEmpty)
        let snap = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: false)
        XCTAssertFalse(PermissionCopy.degradedInjectTooltip(snapshot: snap).isEmpty)
        XCTAssertFalse(PermissionCopy.livePreflightSummary(snapshot: snap).isEmpty)
        XCTAssertFalse(PermissionCopy.tapCreateFailedDespiteListenGuidance.isEmpty)
        XCTAssertFalse(PermissionCopy.staleTCCRecordGuidance.isEmpty)
        XCTAssertFalse(PermissionCopy.staleLegacyBundleIdGuidance.isEmpty)
        XCTAssertFalse(PermissionCopy.manualPrivacySecurityPath.isEmpty)
        XCTAssertFalse(PermissionCopy.modernPrivacySecurityScheme.isEmpty)
        XCTAssertFalse(PermissionCopy.legacySecurityScheme.isEmpty)
    }
}
