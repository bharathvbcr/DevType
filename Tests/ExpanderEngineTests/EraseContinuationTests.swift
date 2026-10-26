import CoreGraphics
import XCTest
@testable import ExpanderEngine

/// Adversarial lock for the erase continue-check.
///
/// The bug: `canContinue` failing was always `eraseContextChanged`, including when WebKit had
/// replaced the AX node of the same text field, or a trusted app's caret had moved because the
/// firing key landed, while the trigger was still sitting at the caret. The same check is what
/// stops a click, an app switch, Secure Input, and a paste into a field that still shows the
/// trigger. These tests try to make `decide` retarget when it must refuse, and refuse when the
/// live field is vouched.
final class EraseContinuationTests: XCTestCase {

    private let secret = "user-typed-secret-trigger"

    // MARK: - The false refuse

    func testSafariNodeReplacementContinuesWhenTheTriggerIsStillAtTheCaret() {
        let decision = EraseContinuation.decide(facts(
            phase: .beforeErase,
            mismatch: .elementChanged,
            allowsRetarget: true,
            livePrecondition: .ok,
            liveRole: "AXTextField"
        ))
        XCTAssertEqual(decision, .retarget)
    }

    func testTrustedCaretMoveContinuesWhenTheLivePlanMatches() {
        for mismatch: PasteboardBroker.PasteTarget.Mismatch in [.elementChanged, .rangeChanged] {
            let decision = EraseContinuation.decide(facts(
                phase: .beforeErase,
                mismatch: mismatch,
                allowsRetarget: true,
                livePrecondition: .ok,
                liveRole: "AXTextArea"
            ))
            XCTAssertEqual(decision, .retarget, "\(mismatch)")
        }
    }

    func testSearchFieldNodeReplacementContinuesWhenVouched() {
        XCTAssertEqual(
            EraseContinuation.decide(facts(
                phase: .beforeErase, mismatch: .elementChanged, allowsRetarget: true, livePrecondition: .ok,
                liveRole: "AXSearchField"
            )),
            .retarget
        )
    }

    func testNoMismatchProceedsAndLeavesTheEraseCheckToSpeak() {
        let decision = EraseContinuation.decide(facts(
            phase: .beforeErase, mismatch: nil, allowsRetarget: true, livePrecondition: .mismatch(secret)
        ))
        XCTAssertEqual(decision, .proceed)
    }

    func testSecondReadingThatMatchesAgainProceedsWithoutRetargeting() {
        XCTAssertEqual(
            EraseContinuation.decide(facts(phase: .beforeInsertion, mismatch: nil, allowsRetarget: true,
                                           liveRole: "AXTextField", fieldReading: .triggerAbsent)),
            .proceed
        )
    }

    // MARK: - Before the erase, anything short of a live .ok refuses

    func testLiveMismatchDoesNotRetargetEvenOnAStableTextField() {
        let decision = refuse(facts(
            phase: .beforeErase, mismatch: .elementChanged, allowsRetarget: true,
            livePrecondition: .mismatch(secret), liveRole: "AXTextField"
        ))
        XCTAssertEqual(decision.path, "eraseContextChanged")
        XCTAssertEqual(decision.recordedMismatch, "beforeErase:elementChanged")
        XCTAssertFalse(decision.reason.contains(secret))
        XCTAssertFalse(decision.recordedMismatch?.contains(secret) ?? false)
    }

    func testLiveUnavailableDoesNotRetarget() {
        for result: ErasePreconditionResult in [
            .unavailable("virtualised field"),
            .unavailable(secret),
            .unavailable(""),
        ] {
            let decision = refuse(facts(
                phase: .beforeErase, mismatch: .rangeChanged, allowsRetarget: true,
                livePrecondition: result, liveRole: "AXTextArea"
            ))
            XCTAssertEqual(decision.recordedMismatch, "beforeErase:rangeChanged")
            XCTAssertFalse(decision.reason.contains(secret))
        }
    }

    func testMissingLivePreconditionDoesNotRetarget() {
        let decision = refuse(facts(
            phase: .beforeErase, mismatch: .elementChanged, allowsRetarget: true, livePrecondition: nil
        ))
        XCTAssertEqual(decision.recordedMismatch, "beforeErase:elementChanged")
    }

    func testSplitOrGeometryDowngradeIsNotAVoucher() {
        // The checker returns `.mismatch` for a split window and `.unavailable` for the
        // caret-geometry downgrade. Neither is `.ok`, so neither continues.
        for result: ErasePreconditionResult in [
            .mismatch("erase window splits a Unicode character"),
            .unavailable("caret geometry untrusted, proceeding best-effort"),
        ] {
            XCTAssertEqual(
                EraseContinuation.decide(facts(
                    phase: .beforeErase, mismatch: .elementChanged, allowsRetarget: true, livePrecondition: result
                )),
                .refuse(EraseContinuationRefusal(
                    path: "eraseContextChanged",
                    reason: "Expansion cancelled — input or target application changed before erase",
                    recordedMismatch: "beforeErase:elementChanged"
                ))
            )
        }
    }

    // MARK: - Who may follow a new element

    func testUndoVoiceAndSelectionReplaceNeverRetarget() {
        let vouched = facts(
            phase: .beforeErase, mismatch: .elementChanged, allowsRetarget: false, livePrecondition: .ok,
            liveRole: "AXTextField", fieldReading: .triggerAbsent
        )
        for phase: EraseContinuationPhase in [.beforeErase, .duringErase, .beforeInsertion] {
            var row = vouched
            row.phase = phase
            row.deletionMatched = true
            let decision = refuse(row)
            XCTAssertEqual(decision.path, "eraseContextChanged", "\(phase)")
            XCTAssertEqual(decision.recordedMismatch, "\(phase.rawValue):elementChanged")
        }
    }

    func testAllowsRetargetFalseWinsOverEveryBenignReading() {
        for phase: EraseContinuationPhase in [.duringErase, .beforeInsertion] {
            for mismatch: PasteboardBroker.PasteTarget.Mismatch in [.elementChanged, .rangeChanged] {
                for reading: EraseFieldReading in [.triggerAbsent, .unreadable, .triggerPresent] {
                    let decision = EraseContinuation.decide(facts(
                        phase: phase, mismatch: mismatch, allowsRetarget: false,
                        livePrecondition: .ok, liveRole: "AXTextField", fieldReading: reading,
                        deletionMatched: true
                    ))
                    guard case .refuse = decision else {
                        return XCTFail("retargeted \(phase) \(mismatch) \(reading)")
                    }
                }
            }
        }
    }

    // MARK: - Hard stops dominate a vouched field

    func testInputRevisionRefusesAnEmptyFieldThatLooksErased() {
        let decision = refuse(facts(
            phase: .beforeInsertion, revisionCurrent: false, mismatch: .elementChanged,
            allowsRetarget: true, livePrecondition: .ok, liveRole: "AXTextField", fieldReading: .triggerAbsent
        ))
        XCTAssertEqual(decision.path, EntryGateRefusal.superseded.path)
        XCTAssertEqual(decision.reason, EntryGateRefusal.superseded.reason)
        XCTAssertNil(decision.recordedMismatch)
        XCTAssertEqual(
            InjectRefusalKind.classify(decision.reason, path: decision.path).sentence,
            "Insertion superseded by a newer one"
        )
    }

    func testEachContinuationBlockRefusesBeforeTheFieldIsConsidered() {
        let rows: [(InjectCompletionGuard.ContinuationBlock, EntryGateRefusal)] = [
            (.callerStopped, .continuation),
            (.cancelled, .superseded),
            (.timedOut, .superseded),
            (.alreadyCompleted, .superseded),
        ]
        for (block, expected) in rows {
            let decision = refuse(facts(
                phase: .beforeErase, continuationBlock: block, mismatch: .elementChanged,
                allowsRetarget: true, livePrecondition: .ok
            ))
            XCTAssertEqual(decision.path, expected.path, "\(block)")
            XCTAssertEqual(decision.reason, expected.reason)
            XCTAssertNil(decision.recordedMismatch)
        }
    }

    func testSecureInputRefusesAVouchedFieldAndDoesNotRecordTheMismatch() {
        let decision = refuse(facts(
            phase: .beforeErase, secureInputBlocked: true, mismatch: .rangeChanged,
            allowsRetarget: true, livePrecondition: .ok
        ))
        XCTAssertEqual(decision.path, EntryGateRefusal.secureInput.path)
        XCTAssertEqual(decision.reason, EntryGateRefusal.secureInput.reason)
        XCTAssertNil(decision.recordedMismatch)
        XCTAssertEqual(
            InjectRefusalKind.classify(decision.reason, path: decision.path).sentence,
            "Secure Input is active — expansion blocked"
        )
    }

    func testAccessibilityUntrustRefusesWithoutBorrowingTheTargetMismatch() {
        let decision = refuse(facts(
            phase: .beforeInsertion, axUntrusted: true, mismatch: .elementChanged,
            allowsRetarget: true, liveRole: "AXTextField", fieldReading: .unreadable
        ))
        XCTAssertEqual(decision.path, EntryGateRefusal.accessibility.path)
        XCTAssertNil(decision.recordedMismatch)
    }

    func testHardStopPriorityIsRevisionThenBlockThenSecureInputThenAccessibility() {
        let decision = refuse(facts(
            phase: .beforeErase,
            revisionCurrent: false,
            continuationBlock: .callerStopped,
            secureInputBlocked: true,
            axUntrusted: true,
            mismatch: .processChanged,
            allowsRetarget: true,
            livePrecondition: .ok
        ))
        XCTAssertEqual(decision.path, EntryGateRefusal.superseded.path)
        XCTAssertNil(decision.recordedMismatch)

        let secureOverAX = refuse(facts(
            phase: .beforeErase, secureInputBlocked: true, axUntrusted: true,
            mismatch: .elementChanged, allowsRetarget: true, livePrecondition: .ok
        ))
        XCTAssertEqual(secureOverAX.path, EntryGateRefusal.secureInput.path)
    }

    // MARK: - Process and focus never follow the new target

    func testAppSwitchFocusLossAndMissingProcessNeverRetarget() {
        let stopped: [PasteboardBroker.PasteTarget.Mismatch] = [
            .noCapturedProcess, .processChanged, .focusLost, .focusArrived,
        ]
        for mismatch in stopped {
            for phase: EraseContinuationPhase in [.beforeErase, .duringErase, .beforeInsertion] {
                let decision = refuse(facts(
                    phase: phase, mismatch: mismatch, allowsRetarget: true, livePrecondition: .ok,
                    liveRole: "AXTextField", fieldReading: .triggerAbsent, deletionMatched: true
                ))
                XCTAssertEqual(decision.path, "eraseContextChanged", "\(phase) \(mismatch)")
                XCTAssertEqual(decision.recordedMismatch, "\(phase.rawValue):\(mismatch.rawValue)")
                XCTAssertEqual(
                    InjectRefusalKind.classify(decision.reason, path: decision.path).sentence,
                    "Input or target application changed before insertion"
                )
            }
        }
    }

    // MARK: - After the erase

    func testAfterEraseAFieldThatStillShowsTheTriggerRefuses() {
        let decision = refuse(facts(
            phase: .beforeInsertion, mismatch: .elementChanged, allowsRetarget: true,
            livePrecondition: .ok, liveRole: "AXTextField", fieldReading: .triggerPresent
        ))
        XCTAssertEqual(decision.recordedMismatch, "beforeInsertion:elementChanged")
        XCTAssertEqual(
            decision.reason,
            "Expansion cancelled — input or target application changed before insertion"
        )
    }

    func testAfterEraseTriggerAbsentOrUnreadableWithoutADeletionMatchRefuses() {
        for reading: EraseFieldReading in [.triggerAbsent, .unreadable] {
            for role in ControlIdentity.insertionRetargetRoles {
                let decision = refuse(facts(
                    phase: .beforeInsertion, mismatch: .elementChanged, allowsRetarget: true,
                    livePrecondition: .mismatch("gone"), liveRole: role, fieldReading: reading,
                    deletionMatched: false
                ))
                XCTAssertEqual(
                    decision.recordedMismatch, "beforeInsertion:elementChanged", "\(role) \(reading)"
                )
            }
        }
    }

    func testAfterEraseAConfirmedDeletionOnATextRoleRetargets() {
        for reading: EraseFieldReading? in [.triggerAbsent, .unreadable, nil] {
            for role in ControlIdentity.insertionRetargetRoles {
                XCTAssertEqual(
                    EraseContinuation.decide(facts(
                        phase: .beforeInsertion, mismatch: .elementChanged, allowsRetarget: true,
                        livePrecondition: .mismatch("gone"), liveRole: role, fieldReading: reading,
                        deletionMatched: true
                    )),
                    .retarget,
                    "\(role) \(String(describing: reading))"
                )
            }
        }
    }

    func testAfterEraseTriggerPresentRefusesEvenWhenTheDeletionMatched() {
        let decision = refuse(facts(
            phase: .beforeInsertion, mismatch: .elementChanged, allowsRetarget: true,
            liveRole: "AXTextField", fieldReading: .triggerPresent, deletionMatched: true
        ))
        XCTAssertEqual(decision.recordedMismatch, "beforeInsertion:elementChanged")
    }

    func testDuringEraseFollowsAMatchedFieldEvenWhileTheTriggerRemains() {
        XCTAssertEqual(
            EraseContinuation.decide(facts(
                phase: .duringErase, mismatch: .elementChanged, allowsRetarget: true,
                liveRole: "AXTextField", fieldReading: .triggerPresent, deletionMatched: true
            )),
            .retarget
        )
        let unmatched = refuse(facts(
            phase: .duringErase, mismatch: .elementChanged, allowsRetarget: true,
            liveRole: "AXTextField", fieldReading: .triggerAbsent, deletionMatched: false
        ))
        XCTAssertEqual(unmatched.recordedMismatch, "duringErase:elementChanged")
        let movedCaret = refuse(facts(
            phase: .duringErase, mismatch: .rangeChanged, allowsRetarget: true,
            liveRole: "AXTextField", fieldReading: .triggerAbsent, deletionMatched: true
        ))
        XCTAssertEqual(movedCaret.recordedMismatch, "duringErase:rangeChanged")
    }

    func testAfterEraseIgnoresThePreconditionBecauseTheTriggerWasDeletedOnPurpose() {
        // A live `.ok` after the erase would mean the trigger is still there. The field reading
        // is the evidence this phase uses; a stale `.ok` from the pre-erase element must not
        // force a retarget, and a `.mismatch` must not block one the reading already vouched.
        XCTAssertEqual(
            EraseContinuation.decide(facts(
                phase: .beforeInsertion, mismatch: .elementChanged, allowsRetarget: true,
                livePrecondition: .ok, liveRole: "AXTextField", fieldReading: .triggerPresent
            )),
            .refuse(EraseContinuationRefusal(
                path: "eraseContextChanged",
                reason: "Expansion cancelled — input or target application changed before insertion",
                recordedMismatch: "beforeInsertion:elementChanged"
            ))
        )
        XCTAssertEqual(
            EraseContinuation.decide(facts(
                phase: .beforeInsertion, mismatch: .elementChanged, allowsRetarget: true,
                livePrecondition: .mismatch("deleted"), liveRole: "AXTextArea",
                fieldReading: .triggerAbsent, deletionMatched: true
            )),
            .retarget
        )
    }

    func testAfterEraseAMissingReadingRefuses() {
        let decision = refuse(facts(
            phase: .beforeInsertion, mismatch: .elementChanged, allowsRetarget: true,
            liveRole: "AXTextField", fieldReading: nil
        ))
        XCTAssertEqual(decision.recordedMismatch, "beforeInsertion:elementChanged")
    }

    func testAfterEraseRangeChangeRefusesEvenWhenTheTriggerIsGone() {
        let decision = refuse(facts(
            phase: .beforeInsertion, mismatch: .rangeChanged, allowsRetarget: true,
            liveRole: "AXTextField", fieldReading: .triggerAbsent, deletionMatched: true
        ))
        XCTAssertEqual(decision.recordedMismatch, "beforeInsertion:rangeChanged")
    }

    func testAfterEraseSecureWindowButtonNilAndUnstableRolesDoNotReceiveThePaste() {
        var roles: [String?] = [
            nil, "", " ", "AXTextField ", "axtextfield", "AXTEXTFIELD",
            "AXSecureTextField", "AXWindow", "AXButton", "AXGroup", "AXStaticText",
            "AXWebArea", "AXScrollArea", "\u{200B}AXTextField",
        ]
        roles.append(contentsOf: AXWriteCapabilityStore.axWriteUnstableRoles.map { Optional($0) })
        for phase: EraseContinuationPhase in [.duringErase, .beforeInsertion] {
            for role in roles {
                let decision = EraseContinuation.decide(facts(
                    phase: phase, mismatch: .elementChanged, allowsRetarget: true,
                    liveRole: role, fieldReading: .triggerAbsent, deletionMatched: true
                ))
                guard case .refuse = decision else {
                    return XCTFail("\(phase) retargeted onto \(role ?? "nil")")
                }
            }
        }
    }

    func testInsertionRolesAreTheStableNonSecureTextRoles() {
        XCTAssertEqual(
            ControlIdentity.insertionRetargetRoles,
            ["AXTextField", "AXTextArea", "AXSearchField"]
        )
        XCTAssertTrue(
            ControlIdentity.insertionRetargetRoles.isDisjoint(with: AXWriteCapabilityStore.axWriteUnstableRoles)
        )
        XCTAssertFalse(ControlIdentity.insertionRetargetRoles.contains("AXSecureTextField"))
        XCTAssertEqual(
            AXWriteCapabilityStore.textEntryRoles.subtracting(["AXSecureTextField"]),
            ControlIdentity.insertionRetargetRoles
        )
    }

    func testBeforeEraseRefusesASecureOrUnstableRoleEvenWhenTheTriggerMatches() {
        var roles: [String?] = [
            nil, "", " ", "AXTextField ", "axtextfield", "AXTEXTFIELD",
            "AXSecureTextField", "AXWindow", "AXButton", "AXGroup", "AXWebArea",
            "\u{0391}XTextField", "AXTextField\n", "AXTextField\u{200B}",
        ]
        roles.append(contentsOf: AXWriteCapabilityStore.axWriteUnstableRoles.map { Optional($0) })
        for role in roles {
            for mismatch: PasteboardBroker.PasteTarget.Mismatch in [.elementChanged, .rangeChanged] {
                let decision = EraseContinuation.decide(facts(
                    phase: .beforeErase, mismatch: mismatch, allowsRetarget: true,
                    livePrecondition: .ok, liveRole: role, fieldReading: .triggerAbsent
                ))
                guard case .refuse(let refusal) = decision else {
                    return XCTFail("followed \(mismatch) onto \(role ?? "nil")")
                }
                XCTAssertEqual(refusal.path, "eraseContextChanged", "\(role ?? "nil")")
                XCTAssertEqual(refusal.recordedMismatch, "beforeErase:\(mismatch.rawValue)")
                XCTAssertNil(refusal.reason.range(of: "Secure Input"))
            }
        }
    }

    func testVacuousOkIsNotAVoucherForADifferentElement() {
        let kept: [ErasePreconditionResult] = [
            .mismatch(secret),
            .unavailable("virtualised field"),
            .unavailable(secret),
        ]
        for result in kept {
            XCTAssertEqual(
                EraseContinuation.substantivePrecondition(result, expectedText: nil),
                result,
                "a real disagreement must survive even when the plan has no text"
            )
        }
        XCTAssertEqual(EraseContinuation.substantivePrecondition(.ok, expectedText: "sig"), .ok)
        XCTAssertEqual(EraseContinuation.substantivePrecondition(.ok, expectedText: "sig "), .ok)
        let blanks: [String?] = [nil, "", " ", "\t", "\u{00A0}", "\n "]
        for blank in blanks {
            XCTAssertNil(
                EraseContinuation.substantivePrecondition(.ok, expectedText: blank),
                "vacuous .ok for \(blank ?? "nil")"
            )
        }
        XCTAssertNil(EraseContinuation.substantivePrecondition(nil, expectedText: "sig"))
        // The downgraded answer is what decide sees, so an empty plan cannot follow a node swap.
        let downgraded = EraseContinuation.substantivePrecondition(.ok, expectedText: "")
        let decision = refuse(facts(
            phase: .beforeErase, mismatch: .elementChanged, allowsRetarget: true,
            livePrecondition: downgraded, liveRole: "AXTextField"
        ))
        XCTAssertEqual(decision.recordedMismatch, "beforeErase:elementChanged")
    }

    func testPublicSentenceForTheTargetPathDoesNotChange() {
        for phase: EraseContinuationPhase in [.beforeErase, .duringErase, .beforeInsertion] {
            let decision = refuse(facts(
                phase: phase, mismatch: .elementChanged, allowsRetarget: true, deletionMatched: true
            ))
            XCTAssertEqual(
                PermissionCoordinator.sanitizedRefusalReason(decision.reason, path: decision.path),
                "Input or target application changed before insertion"
            )
        }
    }

    func testRecordedMismatchIsASingleTokenTheReportCanPrint() throws {
        let decision = refuse(facts(
            phase: .beforeErase, mismatch: .focusArrived, allowsRetarget: true, livePrecondition: .ok
        ))
        let recorded = try XCTUnwrap(decision.recordedMismatch)
        XCTAssertLessThan(recorded.utf8.count, 512)
        XCTAssertNotNil(recorded.range(of: #"^[A-Za-z]+:[A-Za-z]+$"#, options: .regularExpression))
    }

    // MARK: - Field reading

    func testTriggerStillAtTheCaretIsPresent() {
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: "hello sig", caretLocation: 9, selectionLength: 0, caseInsensitive: false
            ),
            .triggerPresent
        )
    }

    func testTriggerEarlierInTheFieldIsNotEvidenceTheEraseMissed() {
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: "sig and more", caretLocation: 12, selectionLength: 0, caseInsensitive: false
            ),
            .triggerAbsent
        )
    }

    func testTriggerAbsentWhenTheCaretWindowDiffers() {
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: "hello", caretLocation: 5, selectionLength: 0, caseInsensitive: false
            ),
            .triggerAbsent
        )
    }

    func testEmptyPlanAndLiveSelectionFailClosedAsPresent() {
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: nil, value: "", caretLocation: 0, selectionLength: 0, caseInsensitive: false
            ),
            .triggerPresent
        )
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "", value: "sig", caretLocation: 3, selectionLength: 0, caseInsensitive: false
            ),
            .triggerPresent
        )
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: "sig", caretLocation: 3, selectionLength: 2, caseInsensitive: false
            ),
            .triggerPresent
        )
    }

    func testUnreadableValueCaretAndUnboundedScanStayUnreadable() {
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: nil, caretLocation: 3, selectionLength: 0, caseInsensitive: false
            ),
            .unreadable
        )
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: "sig", caretLocation: nil, selectionLength: 0, caseInsensitive: false
            ),
            .unreadable
        )
        let huge = String(repeating: "x", count: DeliveryVerifier.maxVerificationScanUTF16 + 1)
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: huge, caretLocation: nil, selectionLength: 0, caseInsensitive: false
            ),
            .unreadable
        )
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: huge + "sig", caretLocation: -1, selectionLength: 0, caseInsensitive: false
            ),
            .unreadable
        )
    }

    func testHugeFieldUsesTheCaretWindow() {
        let filler = String(repeating: "q", count: DeliveryVerifier.maxVerificationScanUTF16)
        let value = filler + "sig"
        let caret = value.utf16.count
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: value, caretLocation: caret, selectionLength: 0, caseInsensitive: false
            ),
            .triggerPresent
        )
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: "sig" + filler, caretLocation: ("sig" + filler).utf16.count,
                selectionLength: 0, caseInsensitive: false
            ),
            .triggerAbsent
        )
    }

    func testCaseFoldAndNonBreakingSpace() {
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "Sig", value: "sig", caretLocation: 3, selectionLength: 0, caseInsensitive: true
            ),
            .triggerPresent
        )
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "Sig", value: "sig", caretLocation: 3, selectionLength: 0, caseInsensitive: false
            ),
            .triggerAbsent
        )
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "a b", value: "a\u{00A0}b", caretLocation: 3, selectionLength: 0, caseInsensitive: false
            ),
            .triggerPresent
        )
    }

    func testEmojiCaretWindowAndASplitSurrogateDoNotTrap() {
        let emoji = "hi😀"
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "😀", value: emoji, caretLocation: emoji.utf16.count, selectionLength: 0,
                caseInsensitive: false
            ),
            .triggerPresent
        )
        // Caret in the middle of the emoji. The window splits a scalar; that is not "present".
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "x", value: "😀", caretLocation: 1, selectionLength: 0, caseInsensitive: false
            ),
            .triggerAbsent
        )
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "e\u{0301}", value: "e\u{0301}", caretLocation: 2, selectionLength: 0,
                caseInsensitive: false
            ),
            .triggerPresent
        )
    }

    func testFieldReadingSurvivesHostileCoordinates() {
        let hostile: [Int?] = [nil, -1, 0, 1, Int.max, Int.min]
        let selections: [Int?] = [nil, -5, 0, 1, 10_000, Int.max]
        for caret in hostile {
            for selection in selections {
                let reading = EraseContinuation.fieldReading(
                    expected: "sig", value: "sig", caretLocation: caret, selectionLength: selection,
                    caseInsensitive: false
                )
                XCTAssertNotNil(EraseFieldReading(rawValue: reading.rawValue))
            }
        }
    }

    func testFieldReadingAgreesWithTheCaretWindowExceptTheFailClosedCases() {
        let values: [String?] = [nil, "", "sig", "sig sig", "nope", "a\u{00A0}b", "😀"]
        let expectedTexts = ["sig", "a b", "😀", "nope"]
        for value in values {
            for expected in expectedTexts {
                for caret in [0, expected.utf16.count, value?.utf16.count ?? 0, -1] {
                    let reading = EraseContinuation.fieldReading(
                        expected: expected, value: value, caretLocation: caret, selectionLength: 0,
                        caseInsensitive: false
                    )
                    let evaluated = ErasePreconditionChecker.evaluate(
                        plan: ErasePlan(text: expected),
                        value: value,
                        caretLocation: caret,
                        selectionLength: 0,
                        insertionPointFollowsExpectedText: false
                    )
                    let mapped: EraseFieldReading
                    switch evaluated {
                    case .ok: mapped = .triggerPresent
                    case .mismatch: mapped = .triggerAbsent
                    case .unavailable: mapped = .unreadable
                    }
                    // boundedContains nil forces unreadable before the checker runs. Everywhere
                    // else the two answers are the same function of the caret window.
                    if value != nil,
                       DeliveryVerifier.boundedContains(expected, in: value ?? "", caretLocation: caret) == nil {
                        XCTAssertEqual(reading, .unreadable, "\(expected) @ \(caret) in \(value ?? "nil")")
                    } else {
                        XCTAssertEqual(reading, mapped, "\(expected) @ \(caret) in \(value ?? "nil")")
                    }
                }
            }
        }
    }

    func testEmptyFieldIsUnreadableRatherThanAbsent() {
        // A different empty field and a field we just erased look the same to the caret-window
        // reading: both are `.unreadable`. The deletion match, not this reading, decides which
        // one may take the paste.
        XCTAssertEqual(
            EraseContinuation.fieldReading(
                expected: "sig", value: "", caretLocation: 0, selectionLength: 0, caseInsensitive: false
            ),
            .unreadable
        )
    }

    // MARK: - Deletion match

    func testDeletionMatchTracksOnlyGraphemesThisPostHasAuthorized() {
        let anchor = picture("sig")
        XCTAssertEqual(
            match(anchor, picture("sig"), maxRemoved: 0),
            .progress(removedGraphemes: 0),
            "the untouched field is the field we are about to delete"
        )
        XCTAssertEqual(
            match(anchor, picture("si", caret: 2), maxRemoved: 1),
            .progress(removedGraphemes: 1)
        )
        XCTAssertNil(
            match(anchor, picture("si", caret: 2), maxRemoved: 0),
            "a field that is already one grapheme ahead is not this post"
        )
        XCTAssertNil(match(anchor, picture("other"), maxRemoved: 3))
        XCTAssertNil(
            match(anchor, picture("", caret: 0), maxRemoved: 0),
            "an empty field is not the untouched trigger"
        )
        XCTAssertNil(
            match(picture("hello"), picture("he", caret: 2), maxRemoved: 3),
            "a picture whose caret window is not the trigger cannot describe the deletion"
        )
        XCTAssertNil(match(nil, picture("sig"), maxRemoved: 0), "no origin, so the new field is not adopted as one")
    }

    func testFullDeletionOfANonEmptyRemainderMatchesEvenWhenTheFrameMoved() {
        let anchor = picture("hello sig", frame: fieldFrame)
        let live = picture("hello ", caret: 6, frame: fieldFrame.offsetBy(dx: 40, dy: 40))
        XCTAssertEqual(match(anchor, live, maxRemoved: 3), .progress(removedGraphemes: 3))
        XCTAssertTrue(confirms(.beforeInsertion, anchor, live, maxRemoved: 3))
        XCTAssertFalse(
            confirms(.beforeInsertion, anchor, picture("hello s", caret: 7), maxRemoved: 3),
            "a leftover suffix is still the trigger"
        )
        XCTAssertFalse(
            confirms(.duringErase, anchor, picture("hello s", caret: 7), maxRemoved: 1),
            "two graphemes are gone and this post has authorized one"
        )
        XCTAssertTrue(confirms(.duringErase, anchor, picture("hello s", caret: 7), maxRemoved: 2))
    }

    func testDifferentTextThatLacksTheTriggerIsNotADeletion() {
        let anchor = picture("sig")
        let live = picture("completely different")
        XCTAssertNil(match(anchor, live, maxRemoved: 3))
        XCTAssertFalse(confirms(.beforeInsertion, anchor, live, maxRemoved: 3))
        XCTAssertFalse(confirms(.duringErase, anchor, live, maxRemoved: 3))
    }

    func testEmptyRemainderRequiresTheSamePositiveFrame() {
        let anchor = picture("sig", frame: fieldFrame)
        let emptied = picture("", caret: 0, frame: fieldFrame)
        XCTAssertEqual(match(anchor, emptied, maxRemoved: 3), .progress(removedGraphemes: 3))
        XCTAssertTrue(confirms(.beforeInsertion, anchor, emptied, maxRemoved: 3))
        XCTAssertNil(match(anchor, picture("", caret: 0, frame: fieldFrame.offsetBy(dx: 40, dy: 0)), maxRemoved: 3))
        XCTAssertNil(match(anchor, picture("", caret: 0, frame: nil), maxRemoved: 3))
        XCTAssertNil(match(picture("sig", frame: nil), picture("", caret: 0, frame: nil), maxRemoved: 3))
        XCTAssertNil(
            match(anchor, picture("", caret: 4, frame: fieldFrame), maxRemoved: 3),
            "the caret has to sit where the deletion landed"
        )
    }

    func testUnreadableValueMatchesOnlyTheSameFrame() {
        let anchor = picture("sig", frame: fieldFrame)
        let blank = EraseContinuation.EraseFieldPicture(
            value: nil, caretLocation: nil, selectionLength: 0, frame: fieldFrame
        )
        XCTAssertEqual(match(anchor, blank, maxRemoved: 0), .sameFrame)
        XCTAssertEqual(match(anchor, blank, maxRemoved: 3), .sameFrame)
        XCTAssertTrue(confirms(.duringErase, anchor, blank, maxRemoved: 0))
        XCTAssertTrue(confirms(.beforeInsertion, anchor, blank, maxRemoved: 3))
        let noFrame = EraseContinuation.EraseFieldPicture(
            value: nil, caretLocation: nil, selectionLength: 0, frame: nil
        )
        XCTAssertNil(match(anchor, noFrame, maxRemoved: 3))
        XCTAssertNil(match(noFrame, noFrame, maxRemoved: 3))
        XCTAssertNil(
            match(anchor, picture("nope", frame: fieldFrame), maxRemoved: 3),
            "readable text that is wrong does not borrow the frame"
        )
    }

    func testSameFrameDoesNotAdoptAReadableAnchorWhoseWindowIsNotTheTrigger() {
        let blank = EraseContinuation.EraseFieldPicture(
            value: nil, caretLocation: nil, selectionLength: 0, frame: fieldFrame
        )
        XCTAssertNil(
            match(picture("hello", frame: fieldFrame), blank, maxRemoved: 3),
            "a different field's frame is not a voucher for an unreadable replacement"
        )
        XCTAssertNil(
            match(picture("sig", caret: 0, frame: fieldFrame), blank, maxRemoved: 3),
            "the trigger is in the field, but not at the caret"
        )
        XCTAssertNil(
            match(picture("sig ", caret: 4, frame: fieldFrame), blank, maxRemoved: 3),
            "a trailing space puts a different window at the caret"
        )
        XCTAssertNil(
            match(picture("", caret: 0, frame: fieldFrame), blank, maxRemoved: 3),
            "an empty readable value is not an unreadable one, and it is not the trigger"
        )
        XCTAssertNil(
            match(picture("sig", caret: -1, frame: fieldFrame), blank, maxRemoved: 0),
            "a negative caret is not a window"
        )
        var selected = blank
        selected.selectionLength = 1
        XCTAssertNil(
            match(picture("sig", frame: fieldFrame), selected, maxRemoved: 0),
            "a selection still blocks the frame recovery"
        )
        // The snapshot itself was unreadable. There is no window to check, and the frame is
        // the only evidence this blank control is the field the erase started in.
        let unreadAnchor = EraseContinuation.EraseFieldPicture(
            value: nil, caretLocation: nil, selectionLength: nil, frame: fieldFrame
        )
        XCTAssertEqual(match(unreadAnchor, blank, maxRemoved: 0), .sameFrame)
        XCTAssertTrue(confirms(.duringErase, unreadAnchor, blank, maxRemoved: 0))
        XCTAssertTrue(confirms(.beforeInsertion, unreadAnchor, blank, maxRemoved: 3))
    }

    func testWhitespaceOnlyRemainderRequiresTheSameFrame() {
        let distant = fieldFrame.offsetBy(dx: 40, dy: 0)
        let anchor = picture("sig ", caret: 3, frame: fieldFrame)
        let space = picture(" ", caret: 0, frame: fieldFrame)
        let movedSpace = picture(" ", caret: 0, frame: distant)
        XCTAssertEqual(match(anchor, space, maxRemoved: 3), .progress(removedGraphemes: 3))
        XCTAssertTrue(confirms(.beforeInsertion, anchor, space, maxRemoved: 3))
        XCTAssertTrue(confirms(.duringErase, anchor, space, maxRemoved: 3))
        XCTAssertNil(
            match(anchor, movedSpace, maxRemoved: 3),
            "a different field whose whole value is a space is not this deletion"
        )
        XCTAssertFalse(confirms(.duringErase, anchor, movedSpace, maxRemoved: 3))
        XCTAssertFalse(confirms(.beforeInsertion, anchor, movedSpace, maxRemoved: 3))
        XCTAssertNil(
            match(anchor, space, maxRemoved: 2),
            "three graphemes are gone and this post has authorized two"
        )
        // One grapheme removed still leaves letters ("si "), so a scroll must not refuse it.
        XCTAssertEqual(
            match(anchor, picture("si ", caret: 2, frame: distant), maxRemoved: 1),
            .progress(removedGraphemes: 1)
        )

        let newlineAnchor = picture("sig\n", caret: 3, frame: fieldFrame)
        XCTAssertNil(match(newlineAnchor, picture("\n", caret: 0, frame: distant), maxRemoved: 3))
        XCTAssertEqual(
            match(newlineAnchor, picture("\n", caret: 0, frame: fieldFrame), maxRemoved: 3),
            .progress(removedGraphemes: 3)
        )

        let tabAnchor = picture("sig\t", caret: 3, frame: fieldFrame)
        XCTAssertNil(match(tabAnchor, picture("\t", caret: 0, frame: distant), maxRemoved: 3))
        XCTAssertEqual(
            match(tabAnchor, picture("\t", caret: 0, frame: fieldFrame), maxRemoved: 3),
            .progress(removedGraphemes: 3)
        )
        XCTAssertNil(
            match(tabAnchor, picture(" ", caret: 0, frame: fieldFrame), maxRemoved: 3),
            "a tab is not a space, so the same frame does not make them the same field"
        )

        // NBSP folds to a space in the comparison. The frame is what keeps that fold from
        // adopting a different field that happens to hold one space.
        let nbspAnchor = picture("sig\u{00A0}", caret: 3, frame: fieldFrame)
        XCTAssertNil(match(nbspAnchor, movedSpace, expected: "sig", maxRemoved: 3))
        XCTAssertEqual(
            match(nbspAnchor, space, expected: "sig", maxRemoved: 3),
            .progress(removedGraphemes: 3)
        )
    }

    func testInvisibleOrControlRemainderRequiresTheSameFrame() {
        let distant = fieldFrame.offsetBy(dx: 40, dy: 0)
        // Zero-width and control scalars do not name a field. Each is one UTF-16 unit and does
        // not extend the preceding grapheme, so the caret sits on the trigger and the leftover
        // is exactly that scalar. A joiner or variation selector does extend it, and a caret
        // between the two is not a deletion window.
        let blanks = ["\u{200B}", "\u{FEFF}", "\u{2060}", "\u{00AD}", "\u{200E}", "\u{200F}", "\u{0000}", "\u{007F}"]
        for blank in blanks {
            let scalar = blank.unicodeScalars.first?.value ?? 0
            let anchor = picture("sig" + blank, caret: 3, frame: fieldFrame)
            let moved = picture(blank, caret: 0, frame: distant)
            let stayed = picture(blank, caret: 0, frame: fieldFrame)
            XCTAssertNil(
                match(anchor, moved, maxRemoved: 3),
                String(format: "U+%04X does not name the field", scalar)
            )
            XCTAssertFalse(confirms(.duringErase, anchor, moved, maxRemoved: 3))
            XCTAssertFalse(confirms(.beforeInsertion, anchor, moved, maxRemoved: 3))
            XCTAssertEqual(match(anchor, stayed, maxRemoved: 3), .progress(removedGraphemes: 3))
            XCTAssertTrue(confirms(.beforeInsertion, anchor, stayed, maxRemoved: 3))
        }
        let marked = picture("sigx\u{200B}", caret: 3, frame: fieldFrame)
        XCTAssertEqual(
            match(marked, picture("x\u{200B}", caret: 0, frame: distant), maxRemoved: 3),
            .progress(removedGraphemes: 3),
            "a visible character beside a zero-width mark still names the field"
        )
    }

    func testMissingCaretMatchesOnlyWhenTheTextAndFrameAgree() {
        let anchor = picture("hello sig", frame: fieldFrame)
        let distant = fieldFrame.offsetBy(dx: 40, dy: 0)
        func live(_ value: String, caret: Int?, frame: CGRect?) -> EraseContinuation.EraseFieldPicture {
            EraseContinuation.EraseFieldPicture(
                value: value, caretLocation: caret, selectionLength: 0, frame: frame
            )
        }
        XCTAssertEqual(
            match(anchor, live("hello ", caret: nil, frame: fieldFrame), maxRemoved: 3),
            .progress(removedGraphemes: 3),
            "the caret read failed and the frame is the same control"
        )
        XCTAssertTrue(confirms(
            .beforeInsertion, anchor, live("hello ", caret: nil, frame: fieldFrame), maxRemoved: 3
        ))
        XCTAssertNil(
            match(anchor, live("hello ", caret: nil, frame: distant), maxRemoved: 3),
            "without a caret, the same text in another control is not this deletion"
        )
        XCTAssertEqual(
            match(anchor, live("hello ", caret: -1, frame: fieldFrame), maxRemoved: 3),
            .progress(removedGraphemes: 3)
        )
        XCTAssertNil(match(anchor, live("hello ", caret: -1, frame: distant), maxRemoved: 3))
        XCTAssertNil(
            match(anchor, live("hello ", caret: 7, frame: fieldFrame), maxRemoved: 3),
            "a caret that disagrees is not a missing caret"
        )
        let partial = live("hello s", caret: nil, frame: fieldFrame)
        XCTAssertEqual(match(anchor, partial, maxRemoved: 2), .progress(removedGraphemes: 2))
        XCTAssertTrue(confirms(.duringErase, anchor, partial, maxRemoved: 2))
        XCTAssertFalse(
            confirms(.beforeInsertion, anchor, partial, maxRemoved: 2),
            "a partial deletion is not a finished erase"
        )
        let spaceAnchor = picture("sig ", caret: 3, frame: fieldFrame)
        XCTAssertEqual(
            match(spaceAnchor, live(" ", caret: nil, frame: fieldFrame), maxRemoved: 3),
            .progress(removedGraphemes: 3)
        )
        XCTAssertNil(match(spaceAnchor, live(" ", caret: nil, frame: distant), maxRemoved: 3))
    }

    func testSelectionOnEitherSideBlocksTheMatch() {
        let anchor = picture("sig")
        var selected = anchor
        selected.selectionLength = 2
        XCTAssertNil(match(selected, picture("si", caret: 2), maxRemoved: 1))
        var liveSelection = picture("si", caret: 2)
        liveSelection.selectionLength = 1
        XCTAssertNil(match(anchor, liveSelection, maxRemoved: 1))
    }

    func testCaseFoldAndNonBreakingSpaceStillMatch() {
        let anchor = picture("Sig\u{00A0}")
        XCTAssertEqual(
            match(anchor, picture("sig "), expected: "Sig ", caseInsensitive: true, maxRemoved: 0),
            .progress(removedGraphemes: 0)
        )
        XCTAssertEqual(
            match(anchor, picture("Sig", caret: 3), expected: "Sig ", caseInsensitive: true, maxRemoved: 1),
            .progress(removedGraphemes: 1)
        )
        XCTAssertNil(
            match(anchor, picture("sig "), expected: "Sig ", caseInsensitive: false, maxRemoved: 0)
        )
    }

    func testEmojiDeletionRemovesTheWholeGrapheme() {
        let trigger = "hi😀"
        let anchor = picture(trigger)
        XCTAssertEqual(trigger.utf16.count, 4)
        XCTAssertEqual(
            match(anchor, picture("hi", caret: 2), expected: trigger, maxRemoved: 1),
            .progress(removedGraphemes: 1),
            "one backspace deletes both UTF-16 units of the emoji"
        )
        XCTAssertNil(match(anchor, picture("hi", caret: 3), expected: trigger, maxRemoved: 1))
        XCTAssertTrue(confirms(
            .beforeInsertion, anchor, picture("", caret: 0, frame: fieldFrame),
            expected: trigger, maxRemoved: trigger.count
        ))
    }

    func testACaretInsideASurrogateDoesNotMatch() {
        let broken = EraseContinuation.EraseFieldPicture(
            value: "😀", caretLocation: 1, selectionLength: 0, frame: fieldFrame
        )
        XCTAssertNil(match(broken, broken, expected: "😀", maxRemoved: 1))
        XCTAssertNil(match(broken, picture("", caret: 0), expected: "😀", maxRemoved: 1))
    }

    func testVacuousAndCountOnlyPlansCannotConfirmADeletion() {
        let anchor = picture("sig")
        XCTAssertNil(match(anchor, picture(""), expected: nil, maxRemoved: 3))
        XCTAssertNil(match(anchor, picture(""), expected: "", maxRemoved: 0))
        XCTAssertNil(match(anchor, picture(""), expected: " ", maxRemoved: 1))
        XCTAssertNil(match(anchor, picture(""), expected: "\u{00A0}", maxRemoved: 1))
        XCTAssertFalse(confirms(.beforeInsertion, anchor, picture(""), expected: nil, maxRemoved: 3))
        XCTAssertFalse(confirms(.beforeErase, anchor, picture("sig"), maxRemoved: 0))
    }

    func testFrameIdentityRejectsANonPositiveOrDistantRect() {
        let anchor = picture("sig", frame: fieldFrame)
        let emptied = { (frame: CGRect?) in self.picture("", caret: 0, frame: frame) }
        XCTAssertNotNil(match(anchor, emptied(fieldFrame.offsetBy(dx: 1, dy: -1)), maxRemoved: 3))
        XCTAssertNil(match(anchor, emptied(fieldFrame.offsetBy(dx: 1.1, dy: 0)), maxRemoved: 3))
        XCTAssertNil(match(anchor, emptied(CGRect(x: 10, y: 20, width: 0, height: 22)), maxRemoved: 3))
        XCTAssertNil(match(anchor, emptied(CGRect(x: 10, y: 20, width: -4, height: 22)), maxRemoved: 3))
        XCTAssertNil(match(
            anchor,
            emptied(CGRect(x: CGFloat.nan, y: 20, width: 200, height: 22)),
            maxRemoved: 3
        ))
        XCTAssertNil(match(
            picture("sig", frame: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)),
            picture("", caret: 0, frame: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)),
            maxRemoved: 3
        ))
    }

    // MARK: - Whole space

    func testRetargetOnlyFollowsAVouchedTypedExpansion() {
        var retargets = 0
        walk { row, decision in
            guard decision == .retarget else { return }
            retargets += 1
            XCTAssertTrue(row.revisionCurrent, label(row))
            XCTAssertNil(row.continuationBlock, label(row))
            XCTAssertFalse(row.secureInputBlocked, label(row))
            XCTAssertFalse(row.axUntrusted, label(row))
            XCTAssertTrue(row.allowsRetarget, label(row))
            switch row.mismatch {
            case .elementChanged, .rangeChanged:
                break
            default:
                XCTFail("retarget on \(String(describing: row.mismatch)) \(label(row))")
            }
            switch row.phase {
            case .beforeErase:
                XCTAssertTrue(ControlIdentity.roleAllowsInsertionRetarget(row.liveRole), label(row))
                guard case .ok = row.livePrecondition else {
                    return XCTFail("before-erase retarget without a live .ok \(label(row))")
                }
            case .duringErase:
                XCTAssertEqual(row.mismatch, .elementChanged, label(row))
                XCTAssertTrue(ControlIdentity.roleAllowsInsertionRetarget(row.liveRole), label(row))
                XCTAssertTrue(row.deletionMatched, label(row))
            case .beforeInsertion:
                XCTAssertEqual(row.mismatch, .elementChanged, label(row))
                XCTAssertTrue(ControlIdentity.roleAllowsInsertionRetarget(row.liveRole), label(row))
                XCTAssertTrue(row.deletionMatched, label(row))
                XCTAssertNotEqual(row.fieldReading, .triggerPresent, label(row))
            }
        }
        XCTAssertGreaterThan(retargets, 0, "the vouched case must be reachable, or the sweep never leaves refuse")
    }

    func testHardStopsNeverRetargetAndNeverRecordAMismatch() {
        var failures: [String] = []
        walk { row, decision in
            let blocked = !row.revisionCurrent || row.continuationBlock != nil
                || row.secureInputBlocked || row.axUntrusted
            guard blocked else { return }
            guard case .refuse(let refusal) = decision else {
                failures.append("hard stop retargeted or proceeded \(label(row))")
                return
            }
            if refusal.recordedMismatch != nil {
                failures.append("recorded \(refusal.recordedMismatch ?? "") \(label(row))")
            }
            if !refusal.path.hasPrefix("entryGate_") || refusal.path == "eraseContextChanged" {
                failures.append("path \(refusal.path) \(label(row))")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count) hard-stop rows failed\n" + failures.prefix(8).joined(separator: "\n"))
        }
    }

    func testProcessAndFocusMismatchesNeverRetargetAcrossTheSpace() {
        let stopped: Set<PasteboardBroker.PasteTarget.Mismatch> = [
            .noCapturedProcess, .processChanged, .focusLost, .focusArrived,
        ]
        var failures: [String] = []
        walk { row, decision in
            guard let mismatch = row.mismatch, stopped.contains(mismatch) else { return }
            guard !operationBlocked(row) else { return }
            guard case .refuse(let refusal) = decision else {
                failures.append("followed \(mismatch) \(label(row))")
                return
            }
            let recorded = "\(row.phase.rawValue):\(mismatch.rawValue)"
            if refusal.recordedMismatch != recorded || refusal.path != "eraseContextChanged"
                || refusal.reason.contains(secret) {
                failures.append("\(refusal.path) \(refusal.recordedMismatch ?? "nil") \(label(row))")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count) process/focus rows failed\n" + failures.prefix(8).joined(separator: "\n"))
        }
    }

    func testDecideAgreesWithTheIndependentRuleAndNeverLeaksFieldText() {
        var seen: Set<String> = []
        var failures: [String] = []
        walk { row, decision in
            let expected = Self.expected(row)
            if decision != expected {
                failures.append("\(label(row))\n got \(decision)\n want \(expected)")
            }
            switch decision {
            case .proceed:
                seen.insert("proceed")
            case .retarget:
                seen.insert("retarget")
            case .refuse(let refusal):
                seen.insert("refuse")
                if refusal.reason.contains(secret) || (refusal.recordedMismatch?.contains(secret) ?? false) {
                    failures.append("leaked field text \(label(row))")
                }
                let sentence = InjectRefusalKind.classify(refusal.reason, path: refusal.path).sentence
                if sentence == "Injection refused" {
                    failures.append("unclassified \(refusal.path) \(label(row))")
                }
            }
        }
        XCTAssertEqual(seen, ["proceed", "retarget", "refuse"])
        if !failures.isEmpty {
            XCTFail(failures.prefix(8).joined(separator: "\n---\n"))
        }
    }

    func testSameFactsDecideTheSameWay() {
        let row = facts(
            phase: .beforeErase, mismatch: .elementChanged, allowsRetarget: true,
            livePrecondition: .ok, liveRole: "AXTextField"
        )
        XCTAssertEqual(EraseContinuation.decide(row), EraseContinuation.decide(row))
        var copy = row
        copy.allowsRetarget = false
        XCTAssertNotEqual(EraseContinuation.decide(row), EraseContinuation.decide(copy))
    }

    // MARK: - Support

    private let fieldFrame = CGRect(x: 10, y: 20, width: 200, height: 22)

    private func picture(
        _ value: String?,
        caret: Int? = nil,
        frame: CGRect? = CGRect(x: 10, y: 20, width: 200, height: 22)
    ) -> EraseContinuation.EraseFieldPicture {
        EraseContinuation.EraseFieldPicture(
            value: value,
            caretLocation: caret ?? value?.utf16.count,
            selectionLength: 0,
            frame: frame
        )
    }

    private func match(
        _ anchor: EraseContinuation.EraseFieldPicture?,
        _ live: EraseContinuation.EraseFieldPicture?,
        expected: String? = "sig",
        caseInsensitive: Bool = false,
        maxRemoved: Int
    ) -> EraseContinuation.EraseDeletionMatch? {
        EraseContinuation.deletionMatch(
            anchor: anchor,
            live: live,
            expectedText: expected,
            caseInsensitive: caseInsensitive,
            maxRemovedGraphemes: maxRemoved
        )
    }

    private func confirms(
        _ phase: EraseContinuationPhase,
        _ anchor: EraseContinuation.EraseFieldPicture?,
        _ live: EraseContinuation.EraseFieldPicture?,
        expected: String? = "sig",
        caseInsensitive: Bool = false,
        maxRemoved: Int
    ) -> Bool {
        EraseContinuation.deletionConfirms(
            phase: phase,
            anchor: anchor,
            live: live,
            expectedText: expected,
            caseInsensitive: caseInsensitive,
            maxRemovedGraphemes: maxRemoved
        )
    }

    private func refuse(_ facts: EraseContinuationFacts) -> EraseContinuationRefusal {
        guard case .refuse(let refusal) = EraseContinuation.decide(facts) else {
            XCTFail("expected a refusal")
            return EraseContinuationRefusal(path: "", reason: "", recordedMismatch: nil)
        }
        return refusal
    }

    private func facts(
        phase: EraseContinuationPhase,
        revisionCurrent: Bool = true,
        continuationBlock: InjectCompletionGuard.ContinuationBlock? = nil,
        secureInputBlocked: Bool = false,
        axUntrusted: Bool = false,
        mismatch: PasteboardBroker.PasteTarget.Mismatch? = nil,
        allowsRetarget: Bool = true,
        livePrecondition: ErasePreconditionResult? = nil,
        liveRole: String? = nil,
        fieldReading: EraseFieldReading? = nil,
        deletionMatched: Bool = false
    ) -> EraseContinuationFacts {
        EraseContinuationFacts(
            phase: phase,
            revisionCurrent: revisionCurrent,
            continuationBlock: continuationBlock,
            secureInputBlocked: secureInputBlocked,
            axUntrusted: axUntrusted,
            mismatch: mismatch,
            allowsRetarget: allowsRetarget,
            deletionMatched: deletionMatched,
            livePrecondition: livePrecondition,
            liveRole: liveRole,
            fieldReading: fieldReading
        )
    }

    private func operationBlocked(_ row: EraseContinuationFacts) -> Bool {
        !row.revisionCurrent || row.continuationBlock != nil || row.secureInputBlocked || row.axUntrusted
    }

    private func label(_ row: EraseContinuationFacts) -> String {
        "phase=\(row.phase.rawValue) rev=\(row.revisionCurrent) block=\(String(describing: row.continuationBlock)) "
            + "secure=\(row.secureInputBlocked) ax=\(row.axUntrusted) mismatch=\(String(describing: row.mismatch)) "
            + "retarget=\(row.allowsRetarget) deleted=\(row.deletionMatched) "
            + "pre=\(String(describing: row.livePrecondition)) "
            + "role=\(row.liveRole ?? "nil") reading=\(String(describing: row.fieldReading))"
    }

    private func walk(_ body: (EraseContinuationFacts, EraseContinuationDecision) -> Void) {
        let blocks: [InjectCompletionGuard.ContinuationBlock?] = [
            nil, .cancelled, .timedOut, .alreadyCompleted, .callerStopped,
        ]
        let mismatches: [PasteboardBroker.PasteTarget.Mismatch?] = [
            nil, .noCapturedProcess, .processChanged, .focusLost, .focusArrived, .elementChanged, .rangeChanged,
        ]
        let preconditions: [ErasePreconditionResult?] = [
            nil, .ok, .mismatch(secret), .unavailable("no focused element"),
        ]
        let roles: [String?] = [
            nil, "", "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField",
            "AXWindow", "AXComboBox", "AXList",
        ]
        let readings: [EraseFieldReading?] = [nil, .triggerPresent, .triggerAbsent, .unreadable]
        for phase in [EraseContinuationPhase.beforeErase, .duringErase, .beforeInsertion] {
            for revision in [true, false] {
                for block in blocks {
                    for secure in [true, false] {
                        for ax in [true, false] {
                            for mismatch in mismatches {
                                for allows in [true, false] {
                                    for precondition in preconditions {
                                        for role in roles {
                                            for reading in readings {
                                                for deletionMatched in [false, true] {
                                                let row = EraseContinuationFacts(
                                                    phase: phase,
                                                    revisionCurrent: revision,
                                                    continuationBlock: block,
                                                    secureInputBlocked: secure,
                                                    axUntrusted: ax,
                                                    mismatch: mismatch,
                                                    allowsRetarget: allows,
                                                    deletionMatched: deletionMatched,
                                                    livePrecondition: precondition,
                                                    liveRole: role,
                                                    fieldReading: reading
                                                )
                                                body(row, EraseContinuation.decide(row))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The rule, written out a second time so a change to `decide` has to change this too.
    /// The property tests above do not use it; they only state what a retarget is not allowed to be.
    private static func expected(_ row: EraseContinuationFacts) -> EraseContinuationDecision {
        if !row.revisionCurrent {
            return .refuse(gate(.superseded))
        }
        if let block = row.continuationBlock {
            return .refuse(gate(block == .callerStopped ? .continuation : .superseded))
        }
        if row.secureInputBlocked {
            return .refuse(gate(.secureInput))
        }
        if row.axUntrusted {
            return .refuse(gate(.accessibility))
        }
        guard let mismatch = row.mismatch else {
            return .proceed
        }
        let refusal = EraseContinuationRefusal(
            path: "eraseContextChanged",
            reason: row.phase == .beforeErase
                ? "Expansion cancelled — input or target application changed before erase"
                : "Expansion cancelled — input or target application changed before insertion",
            recordedMismatch: "\(row.phase.rawValue):\(mismatch.rawValue)"
        )
        switch mismatch {
        case .noCapturedProcess, .processChanged, .focusLost, .focusArrived:
            return .refuse(refusal)
        case .elementChanged, .rangeChanged:
            break
        }
        guard row.allowsRetarget else { return .refuse(refusal) }
        switch row.phase {
        case .beforeErase:
            guard ControlIdentity.roleAllowsInsertionRetarget(row.liveRole) else { return .refuse(refusal) }
            guard case .ok = row.livePrecondition else { return .refuse(refusal) }
            return .retarget
        case .duringErase:
            guard mismatch == .elementChanged else { return .refuse(refusal) }
            guard ControlIdentity.roleAllowsInsertionRetarget(row.liveRole) else { return .refuse(refusal) }
            guard row.deletionMatched else { return .refuse(refusal) }
            return .retarget
        case .beforeInsertion:
            guard mismatch == .elementChanged else { return .refuse(refusal) }
            guard ControlIdentity.roleAllowsInsertionRetarget(row.liveRole) else { return .refuse(refusal) }
            guard row.deletionMatched else { return .refuse(refusal) }
            if row.fieldReading == .triggerPresent { return .refuse(refusal) }
            return .retarget
        }
    }

    private static func gate(_ refusal: EntryGateRefusal) -> EraseContinuationRefusal {
        EraseContinuationRefusal(path: refusal.path, reason: refusal.reason, recordedMismatch: nil)
    }
}
