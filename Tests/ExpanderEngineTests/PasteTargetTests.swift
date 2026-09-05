import ApplicationServices
import XCTest
@testable import ExpanderEngine

final class PasteTargetTests: XCTestCase {
    func testSameApplicationDifferentFieldAndSelectionChangesInvalidatePaste() {
        let original = AXUIElementCreateApplication(getpid())
        let different = AXUIElementCreateApplication(1)
        let range = NSRange(location: 12, length: 3)
        let target = PasteboardBroker.PasteTarget(pid: getpid(), element: original, range: range)
        XCTAssertTrue(target.matches(pid: getpid(), element: original, range: range, checkRange: true))
        XCTAssertFalse(target.matches(pid: getpid(), element: different, range: range, checkRange: true))
        XCTAssertFalse(target.matches(pid: getpid(), element: original, range: NSRange(location: 0, length: 0), checkRange: true))
        XCTAssertFalse(target.matches(pid: getpid(), element: original, range: nil, checkRange: true))
        XCTAssertFalse(target.matches(pid: 1, element: original, range: range, checkRange: true))
        XCTAssertFalse(target.matches(pid: nil, element: original, range: range, checkRange: true))
        XCTAssertFalse(target.matches(pid: getpid(), element: nil, range: range, checkRange: true))
        // Delivery itself intentionally changes the range after the key has posted.
        XCTAssertTrue(target.matches(pid: getpid(), element: original, range: nil, checkRange: false))
    }

    func testSelectionRangePolicyIsClosedForUnknownProcessesAndOpenAfterMutation() {
        XCTAssertTrue(
            PasteboardBroker.verifySelectionRange(
                verdict: nil, bundleKnown: false, phase: .beforeMutation
            ),
            "An unnamed process must keep the caret check — we cannot classify its AX"
        )
        XCTAssertFalse(
            PasteboardBroker.verifySelectionRange(
                verdict: nil, bundleKnown: false, phase: .afterMutation
            )
        )

        for verdict: AXWriteCapabilityStore.Verdict? in [.unknown, .falseSuccess, .trusted, nil] {
            XCTAssertFalse(
                PasteboardBroker.verifySelectionRange(
                    verdict: verdict, bundleKnown: true, phase: .afterMutation
                ),
                "After HID erase, AX selectedRange is not caret identity (verdict=\(String(describing: verdict)))"
            )
        }

        XCTAssertFalse(
            PasteboardBroker.verifySelectionRange(
                verdict: .unknown, bundleKnown: true, phase: .beforeMutation
            ),
            "Unclassified hosts include first-expand Electron; their range must not refuse erase"
        )
        XCTAssertFalse(
            PasteboardBroker.verifySelectionRange(
                verdict: .falseSuccess, bundleKnown: true, phase: .beforeMutation
            )
        )
        XCTAssertTrue(
            PasteboardBroker.verifySelectionRange(
                verdict: .trusted, bundleKnown: true, phase: .beforeMutation
            ),
            "A proven native writer can still stop an expansion when the caret moved"
        )
    }

    /// Cursor 0.1.7 (165): HID erase of the trigger succeeded, the immediate paste gate
    /// passed, then 15ms later a range-checking Cmd+V continuation aborted and restored
    /// the trigger. Pid + element must still refuse a different field.
    func testPostMutationRangeChurnKeepsTheSameFieldAndRejectsADifferentField() {
        let store = AXWriteCapabilityStore()
        let original = AXUIElementCreateApplication(getpid())
        let different = AXUIElementCreateApplication(1)
        let captured = NSRange(location: 40, length: 0)
        let target = PasteboardBroker.PasteTarget(pid: getpid(), element: original, range: captured)
        let flickered = NSRange(location: 35, length: 0)

        for bundle in [
            "com.todesktop.230313mzl4w4u92",
            "com.google.antigravity",
            "com.openai.codex",
            "com.example.never-seen",
            "com.apple.Notes"
        ] {
            let checkRange = PasteboardBroker.verifySelectionRange(
                bundleID: bundle, role: "AXTextArea", phase: .afterMutation, store: store
            )
            XCTAssertFalse(checkRange, bundle)
            XCTAssertTrue(
                target.matches(pid: getpid(), element: original, range: nil, checkRange: checkRange),
                bundle
            )
            XCTAssertTrue(
                target.matches(pid: getpid(), element: original, range: flickered, checkRange: checkRange),
                bundle
            )
            XCTAssertFalse(
                target.matches(pid: getpid(), element: different, range: nil, checkRange: checkRange),
                "\(bundle) must still refuse a different AX element"
            )
            XCTAssertFalse(
                target.matches(pid: 1, element: original, range: nil, checkRange: checkRange),
                "\(bundle) must still refuse a different app"
            )
        }
    }

    func testProvenWritersRegainBeforeMutationSelectionChecks() {
        let store = AXWriteCapabilityStore()
        let bundle = "com.example.native-notes"
        let role = "AXTextArea"
        XCTAssertEqual(store.verdict(for: bundle, role: role), .unknown)
        XCTAssertFalse(
            PasteboardBroker.verifySelectionRange(
                bundleID: bundle, role: role, phase: .beforeMutation, store: store
            )
        )
        store.recordTrusted(bundleID: bundle, role: role)
        XCTAssertTrue(
            PasteboardBroker.verifySelectionRange(
                bundleID: bundle, role: role, phase: .beforeMutation, store: store
            )
        )
        XCTAssertFalse(
            PasteboardBroker.verifySelectionRange(
                bundleID: bundle, role: role, phase: .afterMutation, store: store
            ),
            "Even a proven writer must not re-check range after our own HID erase"
        )
    }

    func testSeededFalseSuccessNeverRegainsRangeChecksFromDeliveryTrustAlone() {
        let store = AXWriteCapabilityStore()
        let cursor = "com.todesktop.230313mzl4w4u92"
        XCTAssertFalse(store.canConfirmDelivery(bundleID: cursor, role: "AXTextArea"))
        XCTAssertFalse(
            PasteboardBroker.verifySelectionRange(
                bundleID: cursor, role: "AXTextArea", phase: .beforeMutation, store: store
            )
        )
        XCTAssertFalse(
            PasteboardBroker.verifySelectionRange(
                bundleID: cursor, role: "AXTextArea", phase: .afterMutation, store: store
            )
        )
    }

    func testCmdVAbortReasonsStayDistinct() {
        XCTAssertEqual(
            PasteboardBroker.cmdVAbortReason(
                generationMatches: false, clipboardOwned: true, shouldContinue: true,
                canPost: true, secureInputBlocked: false, targetCurrent: true
            ),
            .superseded
        )
        XCTAssertEqual(
            PasteboardBroker.cmdVAbortReason(
                generationMatches: true, clipboardOwned: false, shouldContinue: true,
                canPost: true, secureInputBlocked: false, targetCurrent: true
            ),
            .clipboardOwnershipLost
        )
        XCTAssertEqual(
            PasteboardBroker.cmdVAbortReason(
                generationMatches: true, clipboardOwned: true, shouldContinue: false,
                canPost: true, secureInputBlocked: false, targetCurrent: true
            ),
            .cancelled
        )
        XCTAssertEqual(
            PasteboardBroker.cmdVAbortReason(
                generationMatches: true, clipboardOwned: true, shouldContinue: true,
                canPost: false, secureInputBlocked: false, targetCurrent: true
            ),
            .postEventsDenied
        )
        XCTAssertEqual(
            PasteboardBroker.cmdVAbortReason(
                generationMatches: true, clipboardOwned: true, shouldContinue: true,
                canPost: true, secureInputBlocked: true, targetCurrent: true
            ),
            .secureInput
        )
        XCTAssertEqual(
            PasteboardBroker.cmdVAbortReason(
                generationMatches: true, clipboardOwned: true, shouldContinue: true,
                canPost: true, secureInputBlocked: false, targetCurrent: false
            ),
            .targetChanged
        )
        XCTAssertNil(
            PasteboardBroker.cmdVAbortReason(
                generationMatches: true, clipboardOwned: true, shouldContinue: true,
                canPost: true, secureInputBlocked: false, targetCurrent: true
            )
        )
    }

    func testCmdVAbortPriorityIsStableAcrossEveryFlagCombination() {
        let flags: [(Bool, Bool, Bool, Bool, Bool, Bool)] = {
            var cases: [(Bool, Bool, Bool, Bool, Bool, Bool)] = []
            for g in [false, true] {
                for c in [false, true] {
                    for s in [false, true] {
                        for p in [false, true] {
                            for i in [false, true] {
                                for t in [false, true] {
                                    cases.append((g, c, s, p, i, t))
                                }
                            }
                        }
                    }
                }
            }
            return cases
        }()
        XCTAssertEqual(flags.count, 64)
        for (generation, owned, shouldContinue, canPost, secure, target) in flags {
            let reason = PasteboardBroker.cmdVAbortReason(
                generationMatches: generation,
                clipboardOwned: owned,
                shouldContinue: shouldContinue,
                canPost: canPost,
                secureInputBlocked: secure,
                targetCurrent: target
            )
            if !generation {
                XCTAssertEqual(reason, .superseded)
            } else if !owned {
                XCTAssertEqual(reason, .clipboardOwnershipLost)
            } else if !shouldContinue {
                XCTAssertEqual(reason, .cancelled)
            } else if !canPost {
                XCTAssertEqual(reason, .postEventsDenied)
            } else if secure {
                XCTAssertEqual(reason, .secureInput)
            } else if !target {
                XCTAssertEqual(reason, .targetChanged)
            } else {
                XCTAssertNil(reason)
            }
        }
    }
}
