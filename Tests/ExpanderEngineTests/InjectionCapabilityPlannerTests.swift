import XCTest
@testable import ExpanderEngine

final class InjectionCapabilityPlannerTests: XCTestCase {

    // MARK: - Capability snapshot + InjectionPlanner

    func testMissingCapabilitiesSummaryEmptyFullAndPartial() {
        XCTAssertEqual(
            PermissionSnapshot.missingSummary(from: []),
            "All capabilities granted"
        )
        XCTAssertEqual(
            PermissionSnapshot.missingSummary(from: ["Accessibility"]),
            "Missing: Accessibility"
        )
        XCTAssertEqual(
            PermissionSnapshot.missingSummary(from: ["Accessibility", "Input Monitoring"]),
            "Missing: Accessibility and Input Monitoring"
        )
        XCTAssertEqual(
            PermissionSnapshot.missingSummary(from: [
                "Accessibility", "Input Monitoring", "Post Events"
            ]),
            "Missing: Accessibility, Input Monitoring, and Post Events"
        )
    }

    func testPermissionSnapshotMissingNamesAndListenFlag() {
        let partial = PermissionSnapshot(
            canListenTap: false,
            canUseAX: true,
            canPostEvents: true
        )
        XCTAssertEqual(partial.missingCapabilityNames, ["Input Monitoring"])
        XCTAssertEqual(partial.missingCapabilitiesSummary, "Missing: Input Monitoring")
        XCTAssertTrue(partial.inputMonitoringBlocksEventTap)
        XCTAssertFalse(partial.isFullyCapable)

        let allMissing = PermissionSnapshot(
            canListenTap: false,
            canUseAX: false,
            canPostEvents: false
        )
        XCTAssertEqual(
            allMissing.missingCapabilityNames,
            ["Accessibility", "Input Monitoring", "Post Events"]
        )

        let full = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: true
        )
        XCTAssertEqual(full.missingCapabilityNames, [])
        XCTAssertTrue(full.isFullyCapable)
        XCTAssertFalse(full.inputMonitoringBlocksEventTap)

        let degraded = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: false
        )
        XCTAssertTrue(degraded.isDegradedInject)
        XCTAssertFalse(degraded.blocksDefaultEventTap)

        let axMissing = PermissionSnapshot(
            canListenTap: true,
            canUseAX: false,
            canPostEvents: true
        )
        XCTAssertFalse(axMissing.isDegradedInject)
        XCTAssertTrue(axMissing.accessibilityBlocksEventTap)
        XCTAssertTrue(axMissing.blocksDefaultEventTap)
    }

    func testInjectionPlannerFailClosedWithoutAX() {
        let planner = InjectionPlanner()
        let snap = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: true)
        if case .refuse(let reason) = planner.plan(snapshot: snap, isTerminal: false, needsCursorHID: false) {
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("fail-closed") || reason.localizedCaseInsensitiveContains("Accessibility"))
        } else {
            XCTFail("expected refuse without AX")
        }
    }

    func testInjectionPlannerAXOnlyWithoutPost() {
        let planner = InjectionPlanner()
        let snap = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: false)
        XCTAssertEqual(
            planner.plan(snapshot: snap, isTerminal: false, needsCursorHID: false),
            .axOnly
        )
        if case .refuse = planner.plan(snapshot: snap, isTerminal: true, needsCursorHID: false) {
            // ok — a terminal is clipboard-only, and the ⌘V still needs Post
        } else {
            XCTFail("terminal without Post should refuse")
        }
        // Non-shell multi-line + caret use AX range/caret — allowed without Post.
        XCTAssertEqual(
            planner.plan(snapshot: snap, isTerminal: false, needsCursorHID: true),
            .axOnly
        )
        XCTAssertEqual(
            planner.plan(
                snapshot: snap,
                isTerminal: false,
                needsCursorHID: false,
                isMultiLine: true
            ),
            .axOnly
        )
        XCTAssertEqual(
            planner.plan(
                snapshot: snap,
                isTerminal: false,
                needsCursorHID: true,
                isMultiLine: true
            ),
            .axOnly
        )
    }

    func testInjectionPlannerFullWithPost() {
        let planner = InjectionPlanner()
        let snap = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)
        XCTAssertEqual(
            planner.plan(snapshot: snap, isTerminal: true, needsCursorHID: true),
            .axPlusHID
        )
    }
}
