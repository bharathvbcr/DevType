import XCTest
@testable import ExpanderEngine

final class SecureInputPresentationTests: XCTestCase {
    func testSecureTooltipOffersMouseCopyAndManualPaste() {
        let tooltip = EngineDisplayStatus.secure.toolTip
        XCTAssertTrue(tooltip.contains(LocalizationManager.shared.s("menu.copySecret")))
        XCTAssertTrue(tooltip.contains("⌘V"))
        XCTAssertFalse(tooltip.contains("⌘/"), "Secure Input can suppress registered hotkeys")
    }

    func testStopSuppressesAQueuedMonitorNotification() {
        XCTAssertTrue(Thread.isMainThread)
        let monitor = SecureInputMonitor()
        let obsoleteCallback = expectation(description: "Stopped monitor must not update the UI")
        obsoleteCallback.isInverted = true
        monitor.startMonitoring(interval: 0.01) { _ in obsoleteCallback.fulfill() }
        // Hold main so the background timer can queue its first delivery, then stop
        // before yielding main back to the callback. No secure-input state is changed.
        Thread.sleep(forTimeInterval: 0.15)
        monitor.stopMonitoring()
        wait(for: [obsoleteCallback], timeout: 0.1)
    }

    /// Exhaustive over all 32 inputs. The expectation below is the *specification*, written as
    /// rules rather than as a copy of `resolve`'s branch order — the previous version of this test
    /// mirrored that order verbatim, so it agreed with the implementation by construction and could
    /// never catch a precedence bug. It did not catch this one: a paused engine has no tap, and
    /// reporting that as Tap Failed sent users into TCC recovery for a one-click state.
    func testEngineDiagnosisStillPreservesPermissionAndPauseStates() {
        /// Rule 1: `.defaultTap` needs Listen and Accessibility; without either, nothing else matters.
        /// Rule 2: a tap can only have *failed* if the engine asked it to run.
        /// Rule 3: Secure Input outranks pause, as it always has.
        /// Rule 4: a disabled engine is paused.
        func expectation(listen: Bool, ax: Bool, running: Bool, enabled: Bool, secure: Bool) -> EngineDisplayStatus {
            if !listen || !ax { return .needsPermissions }
            if enabled && !running { return .tapFailed }
            if secure { return .secure }
            if !enabled { return .paused }
            return .active
        }

        for listen in [false, true] {
            for ax in [false, true] {
                for running in [false, true] {
                    for enabled in [false, true] {
                        for secure in [false, true] {
                            let actual = EngineDisplayStatus.resolve(
                                canListenTap: listen, canUseAX: ax, isTapRunning: running,
                                isEnabled: enabled, isSecureInputActive: secure
                            )
                            XCTAssertEqual(
                                actual,
                                expectation(listen: listen, ax: ax, running: running, enabled: enabled, secure: secure),
                                "listen=\(listen) ax=\(ax) running=\(running) enabled=\(enabled) secure=\(secure)"
                            )
                        }
                    }
                }
            }
        }

        // The combination the running app actually produces while paused, called out so it is not
        // just one row of a loop: the coordinator never starts a tap for a disabled engine.
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true, canUseAX: true, isTapRunning: false, isEnabled: false, isSecureInputActive: false
            ),
            .paused
        )
    }
}
