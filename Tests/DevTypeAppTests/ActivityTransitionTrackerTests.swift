import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class ActivityTransitionTrackerTests: XCTestCase {
    private let healthy = PermissionSnapshot(
        canListenTap: true,
        canUseAX: true,
        canPostEvents: true
    )

    func testHealthyLaunchIsQuietButPermissionRegressionsAndRecoveryAreRecorded() {
        var tracker = ActivityTransitionTracker()

        XCTAssertEqual(tracker.signals(for: status(snapshot: healthy, tapRunning: true)), [])

        let denied = PermissionSnapshot(
            canListenTap: false,
            canUseAX: true,
            canPostEvents: true
        )
        XCTAssertEqual(
            tracker.signals(for: status(snapshot: denied, tapRunning: false)),
            [.permissionState(snapshot: denied, tapRunning: false)]
        )
        XCTAssertEqual(
            tracker.signals(for: status(snapshot: denied, tapRunning: false)),
            [],
            "Polling the same state must not rewrite activity history"
        )
        XCTAssertEqual(
            tracker.signals(for: status(snapshot: healthy, tapRunning: true)),
            [.permissionState(snapshot: healthy, tapRunning: true)]
        )
    }

    func testInjectFailureIsEdgeTriggeredAndRearmsAfterSuccess() {
        var tracker = ActivityTransitionTracker()
        _ = tracker.signals(for: status(snapshot: healthy, tapRunning: true))

        XCTAssertEqual(
            tracker.signals(for: status(snapshot: healthy, tapRunning: true, outcome: .refused("sensitive reason"))),
            [.injectionRefused]
        )
        XCTAssertEqual(
            tracker.signals(for: status(snapshot: healthy, tapRunning: true, outcome: .refused("different reason"))),
            [],
            "Free-form refusal text must not create distinct persistent events"
        )
        XCTAssertEqual(
            tracker.signals(for: status(snapshot: healthy, tapRunning: true, outcome: .succeeded)),
            []
        )
        XCTAssertEqual(
            tracker.signals(for: status(snapshot: healthy, tapRunning: true, outcome: .failedSilent)),
            [.injectionFailed]
        )
    }

    func testSecureInputRecordsOnlyTransitionsAndSkipsInitialInactiveState() {
        var tracker = ActivityTransitionTracker()

        XCTAssertNil(tracker.signalForSecureInput(active: false))
        XCTAssertEqual(tracker.signalForSecureInput(active: true), .secureInputChanged(active: true))
        XCTAssertNil(tracker.signalForSecureInput(active: true))
        XCTAssertEqual(tracker.signalForSecureInput(active: false), .secureInputChanged(active: false))
    }

    private func status(
        snapshot: PermissionSnapshot,
        tapRunning: Bool,
        outcome: PermissionCoordinator.InjectOutcome? = nil
    ) -> PermissionCoordinator.Status {
        PermissionCoordinator.Status(
            snapshot: snapshot,
            tapRunning: tapRunning,
            recommendsRelaunchForAX: false,
            lastInjectOutcome: outcome
        )
    }
}
