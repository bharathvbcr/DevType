import XCTest
@testable import ExpanderEngine

final class EngineDisplayStatusTests: XCTestCase {

    // MARK: - Engine display status (Listen-only gate)

    func testEngineDisplayStatusNeedsPermissionsWhenListenMissing() {
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: false,
                isTapRunning: true,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .needsPermissions
        )
    }

    func testEngineDisplayStatusActiveWithDegradedPostOnly() {
        // Missing Post must NOT demote Active when Listen + AX + tap are OK.
        // Missing AX is Needs Permissions (defaultTap cannot start without it).
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                canUseAX: true,
                isTapRunning: true,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .active
        )
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                canUseAX: false,
                isTapRunning: false,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .needsPermissions
        )
    }

    func testEngineDisplayStatusTapFailedWhenListenAndAXOkButNoTap() {
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                canUseAX: true,
                isTapRunning: false,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .tapFailed
        )
    }

    func testEngineDisplayStatusActiveRequiresTapEnabledNotSecure() {
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: true,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .active
        )
        XCTAssertNotEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: false,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .active
        )
    }

    func testEngineDisplayStatusPausedAndSecure() {
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: true,
                isEnabled: false,
                isSecureInputActive: false
            ),
            .paused
        )
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: true,
                isEnabled: true,
                isSecureInputActive: true
            ),
            .secure
        )
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: true,
                isEnabled: false,
                isSecureInputActive: true
            ),
            .secure
        )
    }

    func testEngineDisplayStatusToolTipListsMissingAndFlagsInputMonitoring() {
        let tip = EngineDisplayStatus.needsPermissions.toolTip(
            missingCapabilityNames: ["Accessibility", "Input Monitoring"],
            canListenTap: false
        )
        XCTAssertTrue(tip.contains("Missing: Accessibility and Input Monitoring"))
        XCTAssertTrue(tip.localizedCaseInsensitiveContains("event tap"))
        XCTAssertTrue(tip.contains("⌘⇧P"))
    }

    func testEngineDisplayStatusActiveTooltipShowsDegraded() {
        let tip = EngineDisplayStatus.active.toolTip(
            missingCapabilityNames: ["Post Events"],
            canListenTap: true,
            degradedInject: true
        )
        XCTAssertTrue(tip.contains("Post Events"))
        XCTAssertTrue(tip.localizedCaseInsensitiveContains("degraded"))
    }

    func testEngineDisplayStatusActionHintAndRequiresAction() {
        XCTAssertTrue(EngineDisplayStatus.needsPermissions.requiresAction)
        XCTAssertTrue(EngineDisplayStatus.tapFailed.requiresAction)
        XCTAssertFalse(EngineDisplayStatus.active.requiresAction)
        XCTAssertEqual(
            EngineDisplayStatus.needsPermissions.menuTitleWithActionHint,
            "Status: Needs Permissions ⚠"
        )
        XCTAssertEqual(EngineDisplayStatus.active.menuTitleWithActionHint, "Status: Active")
    }

    func testTapFailedRecoveryGuidanceMentionsOtherCopies() {
        let guide = EngineDisplayStatus.tapFailedRecoveryGuidance
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("quit"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("DevType"))
    }
}
