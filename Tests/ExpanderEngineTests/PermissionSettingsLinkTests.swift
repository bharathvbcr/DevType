import XCTest
@testable import ExpanderEngine

final class PermissionSettingsLinkTests: XCTestCase {

    // MARK: - Settings URL builder (modern + legacy fallback)

    func testSettingsURLsAccessibilityModernAndLegacy() {
        let urls = SettingsDeepLinker.settingsURLs(for: .accessibility)
        XCTAssertEqual(
            urls.modern.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        XCTAssertEqual(
            urls.legacy.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testSettingsURLsInputMonitoringListenEvent() {
        let urls = SettingsDeepLinker.settingsURLs(for: .inputMonitoring)
        XCTAssertEqual(
            urls.modern.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
        )
        XCTAssertEqual(
            urls.legacy.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
    }

    func testSettingsURLsPostEventUsesAccessibilityPane() {
        let urls = SettingsDeepLinker.settingsURLs(for: .postEvent)
        XCTAssertTrue(urls.modern.absoluteString.contains("Privacy_Accessibility"))
        XCTAssertTrue(urls.legacy.absoluteString.contains("Privacy_Accessibility"))
        XCTAssertFalse(urls.modern.absoluteString.contains("Privacy_PostEvent"))
        XCTAssertEqual(
            urls.modern.absoluteString,
            SettingsDeepLinker.settingsURLs(for: .accessibility).modern.absoluteString
        )
    }

    func testSettingsURLsNilPermissionRootPanes() {
        let urls = SettingsDeepLinker.settingsURLs(for: nil)
        XCTAssertEqual(
            urls.modern.absoluteString,
            SettingsDeepLinker.modernPrivacySecurityScheme
        )
        XCTAssertEqual(
            urls.legacy.absoluteString,
            "\(SettingsDeepLinker.legacySecurityScheme)?Privacy"
        )
    }

    func testPrivacyRevealKeysPerPermissionKind() {
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .inputMonitoring),
            "Privacy_ListenEvent"
        )
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .accessibility),
            "Privacy_Accessibility"
        )
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .postEvent),
            "Privacy_Accessibility",
            "Post Event has no dedicated pane; deep-link Accessibility"
        )
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .microphone),
            "Privacy_Microphone"
        )
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .speechRecognition),
            "Privacy_SpeechRecognition"
        )
        XCTAssertNil(SettingsDeepLinker.privacyRevealKey(for: nil))
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .postEvent),
            SettingsDeepLinker.privacyRevealKey(for: .accessibility)
        )
    }

    func testPreferredKindForMissingCapabilitiesOrder() {
        XCTAssertEqual(
            SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: false,
                canUseAX: false
            ),
            .inputMonitoring,
            "Listen missing takes priority over Accessibility"
        )
        XCTAssertEqual(
            SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: true,
                canUseAX: false
            ),
            .accessibility
        )
        XCTAssertNil(
            SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: true,
                canUseAX: true,
                canPostEvents: true
            )
        )
    }

    func testPreferredKindWhenOnlyPostEventsMissing() {
        XCTAssertEqual(
            SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: true,
                canUseAX: true,
                canPostEvents: false
            ),
            .postEvent,
            "Post-only missing still offers Open Accessibility (not nil → Relaunch-only)"
        )
        XCTAssertEqual(
            PermissionCopy.openSettingsButtonTitle(for: .postEvent),
            "Open Accessibility"
        )
    }

    func testSystemSettingsBundleIdentifiersIncludeModernAndLegacy() {
        XCTAssertTrue(
            SettingsDeepLinker.systemSettingsBundleIdentifiers.contains("com.apple.systempreferences")
        )
        XCTAssertTrue(
            SettingsDeepLinker.systemSettingsBundleIdentifiers.contains("com.apple.Preferences")
        )
    }

    func testUnlockDescriptionsMentionEventTapAndPostEventPane() {
        let input = PermissionCopy.unlockDescription(for: .inputMonitoring)
        XCTAssertTrue(input.localizedCaseInsensitiveContains("event tap"))
        let post = PermissionCopy.unlockDescription(for: .postEvent)
        XCTAssertTrue(
            post.localizedCaseInsensitiveContains("Privacy_PostEvent")
                || post.localizedCaseInsensitiveContains("dedicated")
        )
        XCTAssertTrue(post.localizedCaseInsensitiveContains("Accessibility"))
    }

    func testSettingsOpenFailureMessageIncludesManualPath() {
        let message = PermissionCopy.settingsOpenFailureMessage(for: .inputMonitoring)
        XCTAssertTrue(message.contains(PermissionCopy.manualPrivacySecurityPath))
        XCTAssertTrue(message.contains("Input Monitoring"))
        let post = PermissionCopy.settingsOpenFailureMessage(for: .postEvent)
        XCTAssertTrue(post.contains("Accessibility"))
        XCTAssertTrue(post.contains(PermissionCopy.manualPrivacySecurityPath))
    }
}
