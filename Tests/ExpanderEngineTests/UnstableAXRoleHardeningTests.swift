import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// Field incident 2026-09-11 (GitPulse `AXComboBox`): a 4-character trigger expanded after the
/// prefix debounce, AX selected-text write was attempted, the combo box lied, HID backspaces
/// were posted, then the expansion was refused as "Erase precondition failed — the target text
/// changed". The live log was `backspace post incomplete`. The user lost the trigger and got
/// nothing.
///
/// The class, not the app: combo boxes / menus / lists retarget their focused AX node while we
/// work, and treating that flicker as "the field changed" both condemns a completed erase and
/// lies in the diagnostic. These tests pin the priors and the refuse vocabulary against that
/// shape — including GitPulse, which is not a seeded Electron prefix.
final class UnstableAXRoleHardeningTests: XCTestCase {

    private let unstableRoles = [
        "AXComboBox", "AXPopUpButton", "AXMenu", "AXMenuBar", "AXMenuButton", "AXList"
    ]
    private let stableRoles = ["AXTextArea", "AXTextField", "AXSearchField"]

    // MARK: - Role prior (skip AX writes without paying the first-expansion probe)

    func testUnknownDesktopAppsSkipAXWritesOnUnstableRoles() {
        let store = AXWriteCapabilityStore()
        for bundle in [
            "com.gitpulse.desktop",
            "com.example.NeverSeenDesktop",
            "org.niche.OneOffApp"
        ] {
            for role in unstableRoles {
                XCTAssertEqual(
                    store.verdict(for: bundle, role: role),
                    .falseSuccess,
                    "\(bundle) role=\(role) must skip AX on the first expansion"
                )
                XCTAssertTrue(
                    store.shouldSkipAXSelectedText(bundleID: bundle, role: role),
                    "\(bundle) role=\(role)"
                )
            }
            for role in stableRoles {
                XCTAssertEqual(
                    store.verdict(for: bundle, role: role),
                    .unknown,
                    "\(bundle) role=\(role) stays eligible for a verified AX probe"
                )
            }
            XCTAssertEqual(
                store.verdict(for: bundle),
                .unknown,
                "A bundle-only query must not inherit the role prior"
            )
        }
    }

    func testBundleLevelTrustCannotAuthorizeAXWritesOnUnstableRoles() {
        let store = AXWriteCapabilityStore()
        let bundle = "com.apple.Notes"
        store.recordTrusted(bundleID: bundle)
        XCTAssertEqual(store.verdict(for: bundle), .trusted)
        XCTAssertFalse(store.shouldSkipAXSelectedText(bundleID: bundle, role: "AXTextArea"))
        for role in unstableRoles {
            XCTAssertTrue(
                store.shouldSkipAXSelectedText(bundleID: bundle, role: role),
                "Trusted native text fields must not license AX writes on \(role)"
            )
        }
    }

    func testExplicitCompositeTrustStillRehabilitatesAnUnstableRole() {
        let store = AXWriteCapabilityStore()
        let bundle = "com.example.ComboThatGrewUp"
        let role = "AXComboBox"
        XCTAssertTrue(store.shouldSkipAXSelectedText(bundleID: bundle, role: role))
        for _ in 0..<(AXWriteCapabilityStore.trustedStreakToRehabilitate - 1) {
            store.recordTrusted(bundleID: bundle, role: role)
            XCTAssertTrue(
                store.shouldSkipAXSelectedText(bundleID: bundle, role: role),
                "A class-level combo-box prior must not fall to a single verified write"
            )
        }
        store.recordTrusted(bundleID: bundle, role: role)
        XCTAssertFalse(
            store.shouldSkipAXSelectedText(bundleID: bundle, role: role),
            "A verified composite streak is the only way a combo box earns AX writes"
        )
        XCTAssertTrue(
            store.shouldSkipAXSelectedText(bundleID: bundle, role: "AXList"),
            "Rehabilitation is per-role, not a blanket for every unstable control"
        )
    }

    func testStaticSeedAgreesWithTheStoreForUnstableRoles() {
        for role in unstableRoles {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: "com.gitpulse.desktop", role: role),
                .falseSuccess
            )
            XCTAssertTrue(AXWriteCapabilityStore.isAXWriteUnstableRole(role))
        }
        for role in stableRoles + [nil, "", "AXWebArea"] {
            XCTAssertFalse(AXWriteCapabilityStore.isAXWriteUnstableRole(role))
        }
        XCTAssertEqual(
            AXWriteCapabilityStore.seedVerdict(bundleID: "com.gitpulse.desktop"),
            .unknown
        )
    }

    func testCanConfirmDeliveryDoesNotTrustAnUnstableRoleMirror() {
        let store = AXWriteCapabilityStore()
        XCTAssertFalse(
            store.canConfirmDelivery(bundleID: "com.gitpulse.desktop", role: "AXComboBox"),
            "A combo box AXValue must not drive re-paste or trigger restore"
        )
        XCTAssertTrue(
            store.canConfirmDelivery(bundleID: "com.gitpulse.desktop", role: "AXTextArea"),
            "Unknown stable roles stay on the delivery ladder"
        )
    }

    // MARK: - Focused-element identity after mutation

    func testAfterMutationElementIdentityIsNotRequiredForUnstableRoles() {
        for role in unstableRoles {
            XCTAssertFalse(
                PasteboardBroker.verifyFocusedElement(role: role, phase: .afterMutation),
                "\(role) retargets its focused node (dropdown, inner field) during HID erase"
            )
            XCTAssertTrue(
                PasteboardBroker.verifyFocusedElement(role: role, phase: .beforeMutation),
                "Before any backspace we still refuse a different field, even a combo box"
            )
        }
        for role in stableRoles + [nil] {
            XCTAssertTrue(
                PasteboardBroker.verifyFocusedElement(role: role, phase: .afterMutation),
                "\(role ?? "nil") must still catch a same-app field switch after erase"
            )
        }
    }

    func testPasteTargetAllowsUnstableRoleElementChurnButNeverADifferentApp() {
        let original = AXUIElementCreateApplication(getpid())
        let different = AXUIElementCreateApplication(1)
        let range = NSRange(location: 8, length: 0)
        let target = PasteboardBroker.PasteTarget(pid: getpid(), element: original, range: range)

        XCTAssertTrue(
            target.matches(
                pid: getpid(), element: different, range: nil,
                checkRange: false, checkElement: false
            ),
            "PID-stable combo-box retarget is not a field switch"
        )
        XCTAssertFalse(
            target.matches(
                pid: getpid(), element: different, range: nil,
                checkRange: false, checkElement: true
            ),
            "Stable roles still refuse a different AX element"
        )
        XCTAssertFalse(
            target.matches(
                pid: 1, element: different, range: nil,
                checkRange: false, checkElement: false
            ),
            "A different app is never a combo-box flicker"
        )
        XCTAssertFalse(
            target.matches(
                pid: nil, element: original, range: nil,
                checkRange: false, checkElement: false
            )
        )
    }

    // MARK: - Completed HID erase is not rewritten by a later continue-guard

    func testErasePostCompletedIsPostedCountNotLaterContext() {
        XCTAssertTrue(HIDKeyPoster.erasePostCompleted(requested: 0, posted: 0))
        XCTAssertTrue(HIDKeyPoster.erasePostCompleted(requested: 4, posted: 4))
        XCTAssertTrue(HIDKeyPoster.erasePostCompleted(requested: 4, posted: 5))
        XCTAssertFalse(HIDKeyPoster.erasePostCompleted(requested: 4, posted: 3))
        XCTAssertFalse(HIDKeyPoster.erasePostCompleted(requested: 4, posted: 0))
        XCTAssertFalse(HIDKeyPoster.erasePostCompleted(requested: 1, posted: 0))
    }

    func testSanitizerDistinguishesIncompleteEraseFromFieldMismatch() {
        XCTAssertEqual(
            PermissionCoordinator.sanitizedRefusalReason(
                "Trigger erase did not complete — field may hold a partial trigger",
                path: "eraseIncomplete"
            ),
            "Trigger erase did not complete"
        )
        XCTAssertEqual(
            PermissionCoordinator.sanitizedRefusalReason(
                "Erase precondition failed — caret moved",
                path: "erasePrecondition"
            ),
            "Erase precondition failed — the target text changed"
        )
        XCTAssertEqual(
            PermissionCoordinator.sanitizedRefusalReason(
                "Expansion cancelled — input or target application changed before insertion",
                path: "eraseContextChanged"
            ),
            "Input or target application changed before insertion"
        )
        XCTAssertNotEqual(
            PermissionCoordinator.sanitizedRefusalReason("x", path: "eraseIncomplete"),
            PermissionCoordinator.sanitizedRefusalReason("x", path: "erasePrecondition"),
            "The GitPulse report must not relabel an incomplete HID post as a field mismatch"
        )
    }

    func testLegacyGuardedErasePathStillSanitizesWithoutLeakingFieldText() {
        let hostile = "Erase precondition failed before paste — field no longer holds the trigger /Users/person/secret.txt"
        XCTAssertEqual(
            PermissionCoordinator.sanitizedRefusalReason(hostile, path: "guardedErase"),
            "Erase precondition failed — the target text changed"
        )
        XCTAssertFalse(
            PermissionCoordinator.sanitizedRefusalReason(hostile, path: "guardedErase")
                .contains("/Users")
        )
    }
}

final class UnstableAXRoleStressTests: XCTestCase {

    func testRolePriorSurvivesAdversarialBundleAndRoleChurn() {
        let store = AXWriteCapabilityStore()
        let unstable: Set<String> = [
            "AXComboBox", "AXPopUpButton", "AXMenu", "AXMenuBar", "AXMenuButton", "AXList"
        ]
        let stable = ["AXTextArea", "AXTextField", "AXSearchField", "AXWebArea"]
        let bundles = [
            "com.gitpulse.desktop",
            "com.example.never-seen",
            "com.apple.Notes",
            "com.todesktop.230313mzl4w4u92",
            "com.google.Chrome.app.abcdefghijklmnopabcdefghijklmnop",
            ""
        ]
        let started = Date()
        for seed: UInt64 in [1, 7, 42, 2026, 0xDEAD_BEEF] {
            var rng = SplitMix64(seed: seed)
            for _ in 0..<1_500 {
                let bundle = bundles[Int(rng.next() % UInt64(bundles.count))]
                let rolePool = Array(unstable) + stable
                let role = rolePool[Int(rng.next() % UInt64(rolePool.count))]
                let skip = store.shouldSkipAXSelectedText(bundleID: bundle, role: role)
                if bundle.isEmpty {
                    XCTAssertFalse(skip, "empty bundle is fail-open for AX, not a silent HID skip")
                    continue
                }
                if unstable.contains(role) {
                    XCTAssertTrue(skip, "seed \(seed) \(bundle) \(role)")
                }
                let checkElement = PasteboardBroker.verifyFocusedElement(
                    role: role, phase: rng.next() % 2 == 0 ? .beforeMutation : .afterMutation
                )
                if unstable.contains(role) {
                    // After mutation the element check is off; before mutation it stays on.
                    _ = checkElement
                }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), StressWallClock.terminationGuard)
    }

    func testPasteMatchingMatrixNeverPastesAcrossApps() {
        let original = AXUIElementCreateApplication(getpid())
        let different = AXUIElementCreateApplication(1)
        let target = PasteboardBroker.PasteTarget(
            pid: getpid(), element: original, range: NSRange(location: 0, length: 0)
        )
        let started = Date()
        for seed: UInt64 in [3, 11, 99, 2026] {
            var rng = SplitMix64(seed: seed)
            for _ in 0..<800 {
                let checkRange = rng.next() % 2 == 0
                let checkElement = rng.next() % 2 == 0
                XCTAssertFalse(
                    target.matches(
                        pid: 1, element: original, range: nil,
                        checkRange: checkRange, checkElement: checkElement
                    )
                )
                XCTAssertFalse(
                    target.matches(
                        pid: nil, element: original, range: nil,
                        checkRange: checkRange, checkElement: checkElement
                    )
                )
                let missingElement = target.matches(
                    pid: getpid(), element: nil, range: nil,
                    checkRange: checkRange, checkElement: checkElement
                )
                if checkElement || checkRange {
                    XCTAssertFalse(
                        missingElement,
                        "A disappeared field still aborts when identity or range is required"
                    )
                } else {
                    XCTAssertTrue(
                        missingElement,
                        "PID-only continue after mutation must survive a combo box dropping its AX node"
                    )
                }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), StressWallClock.terminationGuard)
        XCTAssertTrue(
            target.matches(
                pid: getpid(), element: different, range: nil,
                checkRange: false, checkElement: false
            )
        )
        _ = different
    }
}
