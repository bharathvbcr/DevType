import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Guidance and voice messages must name the **fix**, not just the fault.
///
/// Both halves of this file are regressions against the same defect: a structured remedy was
/// computed inside the engine and then dropped at the user-facing boundary.
///
///   * Inject refusals: the pipeline's branch identifier was consumed to pick a sentence and
///     discarded, so Permission Recovery re-derived intent by substring-matching that sentence.
///     Almost everything missed and fell through to "click into a normal text field (not a
///     password field)" — wrong for an erase-precondition refusal (the user *was* in one) and
///     misleading for a Post Events refusal (a permission problem).
///   * Voice failures: `VoiceFailure.userAction` already carried the remedy, and
///     `VoiceDictationController.message(for:)` never read it — while its own doc comment claimed
///     the opposite.
final class RefusalRemedyTests: XCTestCase {

    private let loc = LocalizationManager.shared

    private func guidance(for kind: InjectRefusalKind, canUseAX: Bool = true) -> String {
        PermissionRecoveryController.guidanceForInjectRefuse(
            kind: kind,
            reason: "Erase precondition failed — the target text changed",
            canUseAX: canUseAX
        )
    }

    // MARK: - Inject refusal guidance

    /// The refusal that started this: a healthy engine, all permissions granted, the user in an
    /// ordinary text field — and the advice was "click into a normal text field".
    func testErasePreconditionDoesNotAdviseClickingIntoATextField() {
        let advice = guidance(for: .erasePrecondition)
        XCTAssertEqual(advice, loc.s("recovery.refuse.erase"))
        XCTAssertNotEqual(advice, loc.s("recovery.refuse.generic",
                                        "Erase precondition failed — the target text changed"))
        XCTAssertFalse(advice.isEmpty)
    }

    /// A missing Post Events grant is a permission problem. Sending the user to click into a
    /// text field cannot fix it.
    func testPostEventsRefusalsPointAtThePermission() {
        for kind in [InjectRefusalKind.postEventsRequired,
                     .shellPostEventsRequired,
                     .axFallbackPostEventsRequired] {
            XCTAssertEqual(guidance(for: kind), loc.s("recovery.refuse.postEvents"),
                           "\(kind.rawValue) does not name the Post Events permission")
        }
    }

    /// Every kind must produce non-empty advice, and only the unclassified one may reuse the
    /// historical generic sentence.
    func testEveryKindProducesItsOwnAdvice() {
        for kind in InjectRefusalKind.allCases {
            let advice = guidance(for: kind)
            XCTAssertFalse(advice.isEmpty, "\(kind.rawValue) produced empty guidance")
            // A key that failed to resolve comes back as the key itself.
            XCTAssertNotEqual(advice, kind.guidanceKey,
                              "\(kind.rawValue) guidance key did not resolve")
            if kind != .unknown {
                XCTAssertNotEqual(
                    advice,
                    loc.s("recovery.refuse.generic",
                          "Erase precondition failed — the target text changed"),
                    "\(kind.rawValue) still falls back to the generic sentence"
                )
            }
        }
    }

    /// A missing Accessibility grant outranks whichever branch refused — nothing else is
    /// actionable until it is restored.
    func testMissingAccessibilityOutranksTheBranchKind() {
        for kind in InjectRefusalKind.allCases {
            let advice = guidance(for: kind, canUseAX: false)
            XCTAssertEqual(
                advice,
                loc.s("recovery.refuse.ax", "Erase precondition failed — the target text changed"),
                "\(kind.rawValue) ignored a missing Accessibility grant"
            )
        }
    }

    // MARK: - Status item wording

    private func tooltip(safeRefusal: Bool) -> String {
        EngineDisplayPresentation(
            display: .active,
            snapshot: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true),
            urgentInject: true,
            injectIssueIsSafeRefusal: safeRefusal,
            loc: loc
        ).toolTip
    }

    /// A guard that refused correctly did not "fail". Saying so is what sends the user looking
    /// for a broken engine that is running perfectly.
    func testSafeRefusalTooltipDoesNotClaimTheInsertionFailed() {
        let refused = tooltip(safeRefusal: true)
        XCTAssertEqual(refused, loc.s("status.tooltip.injectRefused"))
        XCTAssertNotEqual(refused, loc.s("status.tooltip.injectIssue"))
    }

    /// A genuine failure must keep its original wording — this change narrows what counts as a
    /// failure, it does not stop reporting one.
    func testGenuineFailureKeepsTheFailureTooltip() {
        XCTAssertEqual(tooltip(safeRefusal: false), loc.s("status.tooltip.injectIssue"))
    }

    /// The urgent badge is unchanged either way: something did not land, and the user should see
    /// that. Only the *wording* and the offered remedy differ.
    func testBothStatesStillRaiseTheUrgentBadge() {
        for safeRefusal in [true, false] {
            let presentation = StatusItemPresentation(
                display: .active,
                snapshot: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true),
                isSecureInputActive: false,
                urgentInject: true,
                libraryUnhealthy: false,
                differentiateWithoutColor: false,
                highlighted: false,
                injectIssueIsSafeRefusal: safeRefusal,
                loc: loc
            )
            XCTAssertTrue(presentation.needsAttention,
                          "safeRefusal=\(safeRefusal) stopped flagging the user")
            XCTAssertEqual(presentation.statusName, loc.s("status.injectIssue"))
        }
    }

    // MARK: - Voice remedies

    private func failure(_ code: FailureCode, action: UserAction?) -> VoiceFailure {
        VoiceFailure(
            stage: .persistence,
            code: code,
            retryClass: .afterUserAction,
            artifactState: .absent,
            userAction: action
        )
    }

    /// The report's `manifestWriteFailed … recoverability=userActionRequired` demanded an action
    /// and named none. The failure knew it was `.freeDiskSpace` all along.
    func testManifestWriteFailureNamesTheDiskSpaceRemedy() {
        let message = VoiceDictationController.message(
            for: failure(.manifestWriteFailed, action: .freeDiskSpace),
            localization: loc
        )
        XCTAssertTrue(message.contains(loc.s("voice.error.sessionSave")),
                      "the fault should still be named")
        XCTAssertTrue(message.contains(loc.s("voice.remedy.freeDiskSpace")),
                      "the remedy the failure carried was dropped: \(message)")
    }

    /// The doc comment's promise, made enforceable: a failure that carries a remedy must either
    /// already state it or have it appended. No code may silently drop one.
    func testEveryFailureCarryingARemedyStatesIt() {
        for code in FailureCode.allCases {
            for action in UserAction.allCases {
                let message = VoiceDictationController.message(
                    for: failure(code, action: action), localization: loc
                )
                XCTAssertFalse(message.isEmpty, "\(code.rawValue) produced no message")
                if VoiceDictationController.codesNamingTheirOwnRemedy.contains(code) {
                    continue
                }
                XCTAssertTrue(
                    message.contains(loc.s(action.remedyKey)),
                    "\(code.rawValue) + \(action.rawValue) dropped its remedy: \(message)"
                )
            }
        }
    }

    /// Codes that already say "Allow microphone access in System Settings" must not then repeat
    /// the same instruction — over-correcting is its own defect.
    func testCodesThatNameTheirOwnRemedyDoNotRepeatIt() {
        for code in VoiceDictationController.codesNamingTheirOwnRemedy {
            let withAction = VoiceDictationController.message(
                for: failure(code, action: .freeDiskSpace), localization: loc
            )
            let withoutAction = VoiceDictationController.message(
                for: failure(code, action: nil), localization: loc
            )
            XCTAssertEqual(withAction, withoutAction,
                           "\(code.rawValue) appended a redundant remedy")
        }
    }

    /// A failure with no `userAction` must be left exactly as it was.
    func testFailuresWithoutARemedyAreUnchanged() {
        for code in FailureCode.allCases {
            let message = VoiceDictationController.message(
                for: failure(code, action: nil), localization: loc
            )
            XCTAssertFalse(message.isEmpty, "\(code.rawValue) produced no message")
            for action in UserAction.allCases {
                XCTAssertFalse(
                    message.contains(loc.s(action.remedyKey)),
                    "\(code.rawValue) invented a \(action.rawValue) remedy it never carried"
                )
            }
        }
    }

    /// Remedy sentences must exist, be non-empty, and take no format arguments in any language.
    func testRemedyStringsResolveInEveryLanguage() {
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for action in UserAction.allCases {
                guard let raw = table[action.remedyKey] else {
                    XCTFail("\(language.rawValue) is missing \(action.remedyKey)")
                    continue
                }
                XCTAssertFalse(raw.isEmpty, "\(language.rawValue) \(action.remedyKey) is empty")
                XCTAssertFalse(raw.contains("%@"),
                               "\(language.rawValue) \(action.remedyKey) takes an argument nobody passes")
                XCTAssertFalse(raw.contains("%d"),
                               "\(language.rawValue) \(action.remedyKey) takes an argument nobody passes")
            }
        }
    }
}
