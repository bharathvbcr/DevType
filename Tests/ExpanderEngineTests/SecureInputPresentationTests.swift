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

    func testEngineDiagnosisStillPreservesPermissionAndPauseStates() {
        for listen in [false, true] {
            for ax in [false, true] {
                for running in [false, true] {
                    for enabled in [false, true] {
                        for secure in [false, true] {
                            let actual = EngineDisplayStatus.resolve(
                                canListenTap: listen, canUseAX: ax, isTapRunning: running,
                                isEnabled: enabled, isSecureInputActive: secure
                            )
                            let expected: EngineDisplayStatus = !listen || !ax ? .needsPermissions
                                : !running ? .tapFailed : secure ? .secure : !enabled ? .paused : .active
                            XCTAssertEqual(actual, expected)
                        }
                    }
                }
            }
        }
    }
}
