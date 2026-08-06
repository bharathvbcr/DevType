import XCTest
@testable import ExpanderEngine

// MARK: - ProcessIdentity permission audit tests

final class ProcessIdentityOnboardingTests: XCTestCase {

    // MARK: - updateOnboardingIdentity with nil CDHash

    /// When cdHash is nil, the stored onboarding hash must not be overwritten.
    /// Regression for: Recovery calling updateOnboardingIdentity(cdHash: nil, ...) before
    /// async CDHash load finishes, leaving the stored hash stale and causing infinite-Recovery
    /// loop on next launch after a rebuild/re-sign.
    func testUpdateOnboardingIdentityNilCDHashDoesNotOverwriteStoredHash() {
        let defaults = makeIsolatedDefaults()
        // Simulate a previous onboarding that stored a real hash.
        let oldHash = "aabbccdd00112233"
        let oldPath = "/Applications/DevType.app"
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set(oldHash, forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set(oldPath, forKey: ProcessIdentity.onboardingPathDefaultsKey)

        // Call update with nil CDHash (as happens when the async load hasn't finished yet).
        let newPath = "/Applications/Xcode.app/DevType.app"
        ProcessIdentity.updateOnboardingIdentity(cdHash: nil, path: newPath, defaults: defaults)

        // The path should be updated, but the CDHash must remain the original value.
        XCTAssertEqual(
            defaults.string(forKey: ProcessIdentity.onboardingPathDefaultsKey),
            ProcessIdentity.normalizedBundlePath(newPath),
            "Path should update even when CDHash is nil"
        )
        XCTAssertEqual(
            defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey),
            oldHash,
            "CDHash must NOT be overwritten when nil is passed — avoids stale-hash loop"
        )
    }

    /// When cdHash is empty string, treat same as nil — do not overwrite.
    func testUpdateOnboardingIdentityEmptyCDHashDoesNotOverwriteStoredHash() {
        let defaults = makeIsolatedDefaults()
        let oldHash = "deadbeef"
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set(oldHash, forKey: ProcessIdentity.onboardingCDHashDefaultsKey)

        ProcessIdentity.updateOnboardingIdentity(cdHash: "", path: "/Applications/DevType.app", defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey),
            oldHash,
            "Empty-string CDHash must not overwrite stored hash"
        )
    }

    /// When a real CDHash is supplied, both path and hash are updated.
    func testUpdateOnboardingIdentityWithRealHashUpdatesAll() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("oldhash", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set("/old/path.app", forKey: ProcessIdentity.onboardingPathDefaultsKey)

        let newHash = "newhash123"
        let newPath = "/Applications/DevType.app"
        ProcessIdentity.updateOnboardingIdentity(cdHash: newHash, path: newPath, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), newHash)
        XCTAssertEqual(
            defaults.string(forKey: ProcessIdentity.onboardingPathDefaultsKey),
            ProcessIdentity.normalizedBundlePath(newPath)
        )
    }

    /// updateOnboardingIdentity must be a no-op when onboarding is not completed.
    func testUpdateOnboardingIdentityNoOpWhenOnboardingNotCompleted() {
        let defaults = makeIsolatedDefaults()
        // onboardingCompleted == false (default)
        ProcessIdentity.updateOnboardingIdentity(cdHash: "abc", path: "/foo.app", defaults: defaults)

        XCTAssertNil(defaults.string(forKey: ProcessIdentity.onboardingPathDefaultsKey))
        XCTAssertNil(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey))
    }

    // MARK: - shouldReOnboardForIdentityChange with nil current CDHash

    /// When current CDHash is nil (still loading at launch), identity must not be
    /// treated as changed if the path also hasn't changed — prevents spurious Recovery.
    func testShouldReOnboardNilCurrentCDHashSamePathReturnsFalse() {
        let defaults = makeIsolatedDefaults()
        let path = "/Applications/DevType.app"
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("someoldhash", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set(ProcessIdentity.normalizedBundlePath(path), forKey: ProcessIdentity.onboardingPathDefaultsKey)

        // CDHash not yet loaded (nil) but path is the same.
        let result = ProcessIdentity.shouldReOnboardForIdentityChange(
            defaults: defaults,
            currentCDHash: nil,
            currentPath: path
        )
        XCTAssertFalse(result, "Nil CDHash + same path must not trigger re-onboard")
    }

    /// When path changes, identity must be detected as changed regardless of CDHash.
    func testShouldReOnboardPathChangedReturnsTrue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("somehash", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set(ProcessIdentity.normalizedBundlePath("/old/DevType.app"), forKey: ProcessIdentity.onboardingPathDefaultsKey)

        let result = ProcessIdentity.shouldReOnboardForIdentityChange(
            defaults: defaults,
            currentCDHash: nil,
            currentPath: "/new/DevType.app"
        )
        XCTAssertTrue(result, "Path change must trigger re-onboard even with nil CDHash")
    }

    /// When CDHash changes at the same path with no stored designated requirement
    /// (legacy ad-hoc rows), re-onboard. With a stable requirement, CDHash churn must not.
    func testShouldReOnboardHashChangeLegacyWithoutRequirement() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("oldhash", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set(ProcessIdentity.normalizedBundlePath("/Applications/DevType.app"), forKey: ProcessIdentity.onboardingPathDefaultsKey)

        let result = ProcessIdentity.shouldReOnboardForIdentityChange(
            defaults: defaults,
            currentCDHash: "newhash",
            currentPath: "/Applications/DevType.app"
        )
        XCTAssertTrue(result, "Legacy CDHash-only change (no requirement) must trigger re-onboard")
    }

    func testShouldReOnboardHashChangeStableRequirementReturnsFalse() {
        let defaults = makeIsolatedDefaults()
        let req = "identifier \"com.devtype.app\" and certificate root = H\"abc\""
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("oldhash", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set(req, forKey: ProcessIdentity.onboardingDesignatedRequirementDefaultsKey)
        defaults.set(ProcessIdentity.normalizedBundlePath("/Applications/DevType.app"), forKey: ProcessIdentity.onboardingPathDefaultsKey)

        let result = ProcessIdentity.shouldReOnboardForIdentityChange(
            defaults: defaults,
            currentCDHash: "newhash",
            currentPath: "/Applications/DevType.app",
            currentDesignatedRequirement: req
        )
        XCTAssertFalse(result, "CDHash churn under a stable designated requirement must not re-onboard")
    }

    func testShouldReOnboardRequirementChangeReturnsTrue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("samehash", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set("cdhash H\"old\"", forKey: ProcessIdentity.onboardingDesignatedRequirementDefaultsKey)
        defaults.set(ProcessIdentity.normalizedBundlePath("/Applications/DevType.app"), forKey: ProcessIdentity.onboardingPathDefaultsKey)

        let result = ProcessIdentity.shouldReOnboardForIdentityChange(
            defaults: defaults,
            currentCDHash: "samehash",
            currentPath: "/Applications/DevType.app",
            currentDesignatedRequirement: "identifier \"com.devtype.app\" and certificate root = H\"new\""
        )
        XCTAssertTrue(result, "Designated requirement change must trigger re-onboard")
    }

    /// After updateOnboardingIdentity stores the new CDHash + path, re-onboard is false.
    func testAfterUpdateOnboardingIdentityNoLongerReOnboards() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("oldhash", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set(ProcessIdentity.normalizedBundlePath("/Applications/DevType.app"), forKey: ProcessIdentity.onboardingPathDefaultsKey)

        let newPath = "/Applications/DevType.app"
        let newHash = "newhash"

        // Simulate what the deferred-update fix does.
        ProcessIdentity.updateOnboardingIdentity(cdHash: newHash, path: newPath, defaults: defaults)

        let result = ProcessIdentity.shouldReOnboardForIdentityChange(
            defaults: defaults,
            currentCDHash: newHash,
            currentPath: newPath
        )
        XCTAssertFalse(result, "After identity update, re-onboard check must return false")
    }

    // MARK: - binaryIdentityChanged edge cases

    func testBinaryIdentityChangedNilCurrentHashNilStoredHashSamePath() {
        XCTAssertFalse(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: nil, storedPath: nil,
                currentCDHash: nil, currentPath: "/Applications/DevType.app"
            ),
            "No stored data + nil current CDHash must not signal identity changed"
        )
    }

    func testBinaryIdentityChangedKnownHashesDifferentReturnsTrue() {
        XCTAssertTrue(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa", storedPath: nil,
                currentCDHash: "bbb", currentPath: "/Applications/DevType.app"
            ),
            "Legacy CDHash-only compare when no requirement is present"
        )
    }

    func testBinaryIdentityChangedStableRequirementIgnoresCDHashChurn() {
        let req = "identifier \"com.devtype.app\" and certificate root = H\"abc\""
        XCTAssertFalse(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/Applications/DevType.app",
                currentCDHash: "bbb",
                currentPath: "/Applications/DevType.app",
                storedDesignatedRequirement: req,
                currentDesignatedRequirement: req
            )
        )
    }

    func testBinaryIdentityChangedRequirementChangeReturnsTrue() {
        XCTAssertTrue(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/Applications/DevType.app",
                currentCDHash: "aaa",
                currentPath: "/Applications/DevType.app",
                storedDesignatedRequirement: "cdhash H\"old\"",
                currentDesignatedRequirement: "identifier \"com.devtype.app\" and certificate root = H\"new\""
            )
        )
    }

    func testParseDesignatedRequirement() {
        let sample = #"""
        Executable=/Applications/DevType.app/Contents/MacOS/DevType
        designated => identifier "com.devtype.app" and certificate root = H"686fbcdf"
        """#
        XCTAssertEqual(
            ProcessIdentity.parseDesignatedRequirement(fromCodesignRequirementOutput: sample),
            "identifier \"com.devtype.app\" and certificate root = H\"686fbcdf\""
        )
        XCTAssertEqual(
            ProcessIdentity.parseDesignatedRequirement(
                fromCodesignRequirementOutput: "# designated => cdhash H\"99ef\""
            ),
            "cdhash H\"99ef\""
        )
        XCTAssertNil(ProcessIdentity.parseDesignatedRequirement(fromCodesignRequirementOutput: "Identifier=com.devtype.app\n"))
    }

    func testReconcileOnboardingIdentityUpdatesCDHashUnderStableRequirement() {
        let defaults = makeIsolatedDefaults()
        let req = "identifier \"com.devtype.app\" and certificate root = H\"abc\""
        let path = "/Applications/DevType.app"
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("oldhash", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)
        defaults.set(req, forKey: ProcessIdentity.onboardingDesignatedRequirementDefaultsKey)
        defaults.set(ProcessIdentity.normalizedBundlePath(path), forKey: ProcessIdentity.onboardingPathDefaultsKey)

        XCTAssertTrue(
            ProcessIdentity.reconcileOnboardingIdentityIfStable(
                currentCDHash: "newhash",
                currentRequirement: req,
                currentPath: path,
                defaults: defaults
            )
        )
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "newhash")
        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "newhash",
                currentPath: path,
                currentDesignatedRequirement: req
            )
        )
    }

    func testBinaryIdentityChangedSameHashReturnsFalse() {
        XCTAssertFalse(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "abc", storedPath: nil,
                currentCDHash: "abc", currentPath: "/Applications/DevType.app"
            )
        )
    }

    /// CDHash not yet loaded (nil current) with known stored hash → not yet determined → false.
    func testBinaryIdentityChangedNilCurrentWithKnownStoredReturnsFalse() {
        XCTAssertFalse(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "known", storedPath: nil,
                currentCDHash: nil, currentPath: "/Applications/DevType.app"
            ),
            "Nil current CDHash means loading in progress — must not flag identity changed"
        )
    }

    // MARK: - backfillOnboardingCDHashIfNeeded

    func testBackfillWritesMissingHash() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        // No stored CDHash yet (backfill scenario: onboarding completed before hash resolved).

        let filled = ProcessIdentity.backfillOnboardingCDHashIfNeeded(
            currentCDHash: "freshHash",
            defaults: defaults
        )

        XCTAssertTrue(filled)
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "freshHash")
    }

    func testBackfillNoOpWhenHashAlreadyPresent() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("existing", forKey: ProcessIdentity.onboardingCDHashDefaultsKey)

        let filled = ProcessIdentity.backfillOnboardingCDHashIfNeeded(
            currentCDHash: "shouldNotOverwrite",
            defaults: defaults
        )

        XCTAssertFalse(filled)
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "existing")
    }

    func testBackfillNoOpWhenOnboardingNotCompleted() {
        let defaults = makeIsolatedDefaults()
        // onboardingCompleted is false by default

        let filled = ProcessIdentity.backfillOnboardingCDHashIfNeeded(
            currentCDHash: "irrelevant",
            defaults: defaults
        )

        XCTAssertFalse(filled)
        XCTAssertNil(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey))
    }

    // MARK: - accessibilityAppearsReset

    func testAccessibilityAppearsResetTrueWhenGrantedThenDenied() {
        XCTAssertTrue(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: "h1",
                currentCDHash: "h1",
                isCurrentlyGranted: false
            ),
            "Same CDHash was previously granted but now denied → reset detected"
        )
    }

    func testAccessibilityAppearsResetFalseWhenCurrentlyGranted() {
        XCTAssertFalse(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: "h1",
                currentCDHash: "h1",
                isCurrentlyGranted: true
            )
        )
    }

    func testAccessibilityAppearsResetFalseWhenNoGrantedHash() {
        XCTAssertFalse(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: nil,
                currentCDHash: "h1",
                isCurrentlyGranted: false
            ),
            "No record of prior grant → cannot detect reset"
        )
    }

    // MARK: - canFinishOnboarding

    func testCanFinishOnboardingRequiresAXAndCDHashLoaded() {
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true, tapRunning: true,
                canUseAX: true, cdHash: "h", cdHashLoadFinished: true
            )
        )
        XCTAssertFalse(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true, tapRunning: true,
                canUseAX: false, cdHash: nil, cdHashLoadFinished: true
            ),
            "AX required"
        )
        XCTAssertFalse(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true, tapRunning: true,
                canUseAX: true, cdHash: nil, cdHashLoadFinished: false
            ),
            "CDHash load must be finished"
        )
    }

    /// Listen + tap are NOT required to finish onboarding.
    func testCanFinishOnboardingDoesNotRequireListenOrTap() {
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: false, tapRunning: false,
                canUseAX: true, cdHash: nil, cdHashLoadFinished: true
            ),
            "Listen and tap are optional for Finish — only AX + CDHash load matter"
        )
    }

    // MARK: - canAdvanceFromVerify

    func testCanAdvanceFromVerifyRequiresAX() {
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromVerify(canListenTap: false, tapRunning: false, canUseAX: true)
        )
        XCTAssertFalse(
            ProcessIdentity.canAdvanceFromVerify(canListenTap: true, tapRunning: true, canUseAX: false)
        )
    }

    // MARK: - Helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.devtype.permissionaudit.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { d.removePersistentDomain(forName: suiteName) }
        return d
    }
}

// MARK: - PermissionSnapshot audit tests

final class PermissionSnapshotAuditTests: XCTestCase {

    func testFullyCapableWhenAllGranted() {
        let s = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)
        XCTAssertTrue(s.isFullyCapable)
        XCTAssertTrue(s.missingCapabilityNames.isEmpty)
    }

    func testDegradedInjectWhenListenAndAXButMissingPost() {
        let noPost = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: false)
        XCTAssertTrue(noPost.isDegradedInject)

        // AX missing blocks the defaultTap and refuses inject — not "degraded inject".
        let noAX = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: true)
        XCTAssertFalse(noAX.isDegradedInject)
        XCTAssertTrue(noAX.blocksDefaultEventTap)

        let listenOnly = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: false)
        XCTAssertFalse(listenOnly.isDegradedInject)
        XCTAssertTrue(listenOnly.blocksDefaultEventTap)
    }

    func testInputMonitoringBlocksEventTapWhenListenMissing() {
        let noListen = PermissionSnapshot(canListenTap: false, canUseAX: true, canPostEvents: true)
        XCTAssertTrue(noListen.inputMonitoringBlocksEventTap)
        XCTAssertTrue(noListen.blocksDefaultEventTap)
    }

    func testAccessibilityBlocksEventTapWhenAXMissing() {
        let noAX = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: true)
        XCTAssertTrue(noAX.accessibilityBlocksEventTap)
        XCTAssertTrue(noAX.blocksDefaultEventTap)
    }

    func testMissingCapabilityNamesOrderAXThenListenThenPost() {
        let none = PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: false)
        XCTAssertEqual(none.missingCapabilityNames, ["Accessibility", "Input Monitoring", "Post Events"])
    }

    func testMissingCapabilitiesSummaryAllGranted() {
        let full = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)
        XCTAssertEqual(full.missingCapabilitiesSummary, "All capabilities granted")
    }

    func testMissingCapabilitiesSummaryOneItem() {
        let s = PermissionSnapshot(canListenTap: false, canUseAX: true, canPostEvents: true)
        XCTAssertEqual(s.missingCapabilitiesSummary, "Missing: Input Monitoring")
    }

    func testMissingCapabilitiesSummaryTwoItems() {
        let s = PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: true)
        XCTAssertEqual(s.missingCapabilitiesSummary, "Missing: Accessibility and Input Monitoring")
    }
}

// MARK: - InjectionPlanner audit tests

final class InjectionPlannerAuditTests: XCTestCase {

    func testRefuseWhenAXMissing() {
        let snapshot = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: true)
        let plan = InjectionPlanner().plan(snapshot: snapshot, isTerminal: false, needsCursorHID: false)
        if case .refuse = plan { } else {
            XCTFail("Expected refuse when AX missing, got \(plan)")
        }
    }

    func testAXPlusHIDWhenFullyCapable() {
        let snapshot = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)
        let plan = InjectionPlanner().plan(snapshot: snapshot, isTerminal: false, needsCursorHID: false)
        XCTAssertEqual(plan, .axPlusHID)
    }

    func testAXOnlyWhenPostMissingNonTerminal() {
        let snapshot = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: false)
        let plan = InjectionPlanner().plan(snapshot: snapshot, isTerminal: false, needsCursorHID: false)
        XCTAssertEqual(plan, .axOnly)
    }

    func testRefuseTerminalWhenPostMissing() {
        let snapshot = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: false)
        let plan = InjectionPlanner().plan(snapshot: snapshot, isTerminal: true, needsCursorHID: false)
        if case .refuse = plan { } else {
            XCTFail("Expected refuse for terminal without Post Events, got \(plan)")
        }
    }
}

// MARK: - EngineDisplayStatus audit tests

final class EngineDisplayStatusAuditTests: XCTestCase {

    func testNeedsPermissionsWhenListenMissing() {
        let s = EngineDisplayStatus.resolve(
            canListenTap: false, isTapRunning: false, isEnabled: true, isSecureInputActive: false
        )
        XCTAssertEqual(s, .needsPermissions)
        XCTAssertTrue(s.requiresAction)
    }

    func testTapFailedWhenListenAndAXGrantedButTapNotRunning() {
        let s = EngineDisplayStatus.resolve(
            canListenTap: true, canUseAX: true, isTapRunning: false, isEnabled: true, isSecureInputActive: false
        )
        XCTAssertEqual(s, .tapFailed)
        XCTAssertTrue(s.requiresAction)
    }

    func testNeedsPermissionsWhenAXMissingEvenIfListenGranted() {
        let s = EngineDisplayStatus.resolve(
            canListenTap: true, canUseAX: false, isTapRunning: false, isEnabled: true, isSecureInputActive: false
        )
        XCTAssertEqual(s, .needsPermissions)
    }

    func testActiveWhenFullyOperational() {
        let s = EngineDisplayStatus.resolve(
            canListenTap: true, canUseAX: true, isTapRunning: true, isEnabled: true, isSecureInputActive: false
        )
        XCTAssertEqual(s, .active)
        XCTAssertFalse(s.requiresAction)
    }

    func testSecureWhenSecureInputActive() {
        let s = EngineDisplayStatus.resolve(
            canListenTap: true, canUseAX: true, isTapRunning: true, isEnabled: true, isSecureInputActive: true
        )
        XCTAssertEqual(s, .secure)
    }

    func testPausedWhenDisabled() {
        let s = EngineDisplayStatus.resolve(
            canListenTap: true, canUseAX: true, isTapRunning: true, isEnabled: false, isSecureInputActive: false
        )
        XCTAssertEqual(s, .paused)
    }

    /// Missing Post alone (Listen + AX + tap running) must NOT show needsPermissions.
    /// Missing AX blocks defaultTap install and must show needsPermissions.
    func testMissingPostDoesNotCauseNeedsPermissionsWhileAXMissingDoes() {
        let postMissing = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: false)
        let active = EngineDisplayStatus.resolve(
            snapshot: postMissing, isTapRunning: true, isEnabled: true, isSecureInputActive: false
        )
        XCTAssertEqual(active, .active, "Post missing must not demote to needsPermissions when tap is running")

        let axMissing = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: true)
        let needs = EngineDisplayStatus.resolve(
            snapshot: axMissing, isTapRunning: false, isEnabled: true, isSecureInputActive: false
        )
        XCTAssertEqual(needs, .needsPermissions, "AX missing must be Needs Permissions, not Tap Failed")
    }
}
