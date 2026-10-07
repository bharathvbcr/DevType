import XCTest
@testable import ExpanderEngine

final class OnboardingIdentityTests: XCTestCase {

    func testCanFinishOnboardingGates() {
        // Finish/Verify advance on Accessibility (+ CDHash load for Finish); Listen/tap optional.
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: false,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            ),
            "Listen/tap incomplete must not block Finish when AX is granted"
        )
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: false,
                tapRunning: false,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            ),
            "Finish with AX only (Listen denied)"
        )
        XCTAssertFalse(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: true,
                canUseAX: false,
                cdHash: "abc",
                cdHashLoadFinished: true
            ),
            "AX required for Finish"
        )
        XCTAssertFalse(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: true,
                canUseAX: true,
                cdHash: nil,
                cdHashLoadFinished: false
            ),
            "Block Finish while CDHash still loading"
        )
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: true,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            )
        )
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromVerify(
                canListenTap: true,
                tapRunning: true,
                canUseAX: true
            )
        )
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromVerify(
                canListenTap: false,
                tapRunning: false,
                canUseAX: true
            ),
            "Verify advances with AX even when Listen/tap incomplete"
        )
        XCTAssertFalse(
            ProcessIdentity.canAdvanceFromVerify(
                canListenTap: true,
                tapRunning: true,
                canUseAX: false
            )
        )
    }

    func testIdentityChangeDetectionNilToHash() {
        let suite = "devtype.tests.identity.nilhash.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        ProcessIdentity.markOnboardingCompleted(
            cdHash: "stored-hash",
            path: "/Applications/DevType.app",
            defaults: defaults
        )

        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: nil,
                currentPath: "/Applications/DevType.app"
            ),
            "Nil current CDHash (still loading) must not look like a stable match or mismatch"
        )
        // Legacy rows without a stored designated requirement still treat CDHash churn as identity change.
        XCTAssertTrue(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "different-hash",
                currentPath: "/Applications/DevType.app"
            ),
            "After nil→hash resolves to a different value with no stored requirement, re-onboard"
        )
        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "stored-hash",
                currentPath: "/Applications/DevType.app"
            )
        )
        // Once a requirement is recorded, CDHash churn alone must not re-onboard.
        defaults.set(
            "identifier \"com.devtype.app\" and certificate root = H\"abc\"",
            forKey: ProcessIdentity.onboardingDesignatedRequirementDefaultsKey
        )
        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "different-hash",
                currentPath: "/Applications/DevType.app",
                currentDesignatedRequirement: "identifier \"com.devtype.app\" and certificate root = H\"abc\""
            )
        )
    }

    func testRequestNeverAutoOpensSettings() {
        XCTAssertFalse(
            PermissionRequester.autoOpensSettingsAfterRequest,
            "Request must never auto-open Settings; Open is an explicit separate action"
        )
    }

    func testDualInstallWarningWhenBothExist() {
        let warning = ProcessIdentity.dualInstallWarning(
            runningPath: "/Users/me/Code/DevType/.build/DevType.app",
            applicationsExists: true,
            buildBundleExists: true
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains(ProcessIdentity.preferredInstalledAppPath))
        // Running Applications while a .build package is also present must still warn.
        let appsRunning = ProcessIdentity.dualInstallWarning(
            runningPath: "/Applications/DevType.app",
            applicationsExists: true,
            buildBundleExists: true
        )
        XCTAssertNotNil(appsRunning)
        XCTAssertTrue(appsRunning!.contains(".build"))
        XCTAssertNil(
            ProcessIdentity.dualInstallWarning(
                runningPath: "/Applications/DevType.app",
                applicationsExists: true,
                buildBundleExists: false
            )
        )
    }

    func testBackfillOnboardingCDHashIfNeeded() {
        let suite = "devtype.tests.backfill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("/Applications/DevType.app", forKey: ProcessIdentity.onboardingPathDefaultsKey)
        XCTAssertTrue(
            ProcessIdentity.backfillOnboardingCDHashIfNeeded(currentCDHash: "newhash", defaults: defaults)
        )
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "newhash")
        XCTAssertFalse(
            ProcessIdentity.backfillOnboardingCDHashIfNeeded(currentCDHash: "other", defaults: defaults)
        )
    }

    func testRememberAccessibilityGrantedBoundToCDHash() {
        let suite = "devtype.tests.tcc.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.string(forKey: ProcessIdentity.accessibilityGrantedCDHashDefaultsKey))
        ProcessIdentity.rememberAccessibilityGranted(false, cdHash: "abc", defaults: defaults)
        XCTAssertNil(defaults.string(forKey: ProcessIdentity.accessibilityGrantedCDHashDefaultsKey))
        ProcessIdentity.rememberAccessibilityGranted(true, cdHash: "abc", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.accessibilityGrantedCDHashDefaultsKey), "abc")
    }

    func testOnboardingCompletedPersistence() {
        let suite = "devtype.tests.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ProcessIdentity.isOnboardingCompleted(defaults: defaults))
        ProcessIdentity.markOnboardingCompleted(
            cdHash: "hash1",
            path: "/Users/me/.build/DevType.app",
            defaults: defaults
        )
        XCTAssertTrue(ProcessIdentity.isOnboardingCompleted(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "hash1")
        XCTAssertEqual(
            defaults.string(forKey: ProcessIdentity.onboardingPathDefaultsKey),
            ProcessIdentity.normalizedBundlePath("/Users/me/.build/DevType.app")
        )
    }

    func testUpdateOnboardingIdentityStopsRecoveryLoop() {
        let suite = "devtype.tests.onboarding.update.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ProcessIdentity.markOnboardingCompleted(
            cdHash: "old-hash",
            path: "/Applications/DevType.app",
            defaults: defaults
        )
        XCTAssertTrue(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "new-hash",
                currentPath: "/Applications/DevType.app"
            )
        )
        ProcessIdentity.updateOnboardingIdentity(
            cdHash: "new-hash",
            path: "/Applications/DevType.app",
            defaults: defaults
        )
        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "new-hash",
                currentPath: "/Applications/DevType.app"
            )
        )
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "new-hash")
    }

    func testNeedsCursorHIDHelper() {
        XCTAssertFalse(InjectionPlanner.needsCursorHID(cursorOffset: nil, totalLength: 10))
        XCTAssertFalse(InjectionPlanner.needsCursorHID(cursorOffset: 10, totalLength: 10))
        XCTAssertTrue(InjectionPlanner.needsCursorHID(cursorOffset: 3, totalLength: 10))
        XCTAssertTrue(InjectionPlanner.needsCursorHID(cursorOffset: 3, totalUTF16Length: 10))
    }

    func testCanFinishOnboardingWithoutPostEvents() {
        // Post is optional — Finish needs AX (+ CDHash load finished); Listen/tap not required.
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: true,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            )
        )
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: false,
                tapRunning: false,
                canUseAX: true,
                cdHash: nil,
                cdHashLoadFinished: true
            ),
            "AX-only Finish without Listen/tap/Post"
        )
    }
}
