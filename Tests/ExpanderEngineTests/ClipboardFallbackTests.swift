import AppKit
import XCTest
@testable import ExpanderEngine

/// The brokered ⌘C tier — the read of last resort behind the whole AX ladder.
///
/// The policy under test is deliberately narrow: the fallback may run **only** when the app
/// published no focused AX element at all. An AX answer of "focus is readable and nothing is
/// selected" must be believed — VS Code-family editors treat ⌘C with no selection as "copy the
/// current line", and surfacing that line as the user's "selection" would hand the transform
/// text the user never chose.
final class ClipboardFallbackTests: XCTestCase {

    // MARK: - Gate policy

    func testFallbackRunsOnlyForNoFocusedElement() {
        XCTAssertTrue(
            SelectionReader.shouldAttemptClipboardFallback(
                failure: .noFocusedElement,
                frontmostIsOwnProcess: false,
                canPostEvents: true,
                secureInputActive: false,
                sourceAppStillFrontmost: true
            )
        )
        // Every other failure keeps its own meaning. `.emptySelection` above all — that is the
        // VS Code copy-a-line-you-never-selected case.
        let never: [SelectionReader.Failure] = [
            .emptySelection, .accessibilityUntrusted, .secureInputActive,
            .appMuted("com.example"), .noSourceSelection, .selectionTooLarge(1),
        ]
        for failure in never {
            XCTAssertFalse(
                SelectionReader.shouldAttemptClipboardFallback(
                    failure: failure,
                    frontmostIsOwnProcess: false,
                    canPostEvents: true,
                    secureInputActive: false,
                    sourceAppStillFrontmost: true
                ),
                "\(failure.diagnosticLabel) must never trigger a synthetic copy"
            )
        }
    }

    func testEveryGateBlocksIndependently() {
        // Our own panel frontmost: the ⌘C would land on DevType itself.
        XCTAssertFalse(
            SelectionReader.shouldAttemptClipboardFallback(
                failure: .noFocusedElement,
                frontmostIsOwnProcess: true,
                canPostEvents: true,
                secureInputActive: false,
                sourceAppStillFrontmost: true
            )
        )
        // Post Events revoked mid-session: nothing to post with.
        XCTAssertFalse(
            SelectionReader.shouldAttemptClipboardFallback(
                failure: .noFocusedElement,
                frontmostIsOwnProcess: false,
                canPostEvents: false,
                secureInputActive: false,
                sourceAppStillFrontmost: true
            )
        )
        // Secure Input engaged while the AX ladder was failing: the re-check is live, not the
        // value captured at read start.
        XCTAssertFalse(
            SelectionReader.shouldAttemptClipboardFallback(
                failure: .noFocusedElement,
                frontmostIsOwnProcess: false,
                canPostEvents: true,
                secureInputActive: true,
                sourceAppStillFrontmost: true
            )
        )
        // The user moved to another app while AX probing was in flight.
        XCTAssertFalse(
            SelectionReader.shouldAttemptClipboardFallback(
                failure: .noFocusedElement,
                frontmostIsOwnProcess: false,
                canPostEvents: true,
                secureInputActive: false,
                sourceAppStillFrontmost: false
            )
        )
    }

    func testFallbackPolicyExhaustiveBooleanMatrixHasExactlyOneAuthorizedState() {
        let failures: [SelectionReader.Failure] = [
            .accessibilityUntrusted,
            .secureInputActive,
            .appMuted("muted.example"),
            .noFocusedElement,
            .noSourceSelection,
            .emptySelection,
            .selectionTooLarge(SelectionReader.maxSelectionCharacters + 1),
        ]
        var authorized: [(SelectionReader.Failure, Bool, Bool, Bool, Bool)] = []

        for failure in failures {
            for ownProcess in [false, true] {
                for canPost in [false, true] {
                    for secureInput in [false, true] {
                        for sourceMatches in [false, true] {
                            if SelectionReader.shouldAttemptClipboardFallback(
                                failure: failure,
                                frontmostIsOwnProcess: ownProcess,
                                canPostEvents: canPost,
                                secureInputActive: secureInput,
                                sourceAppStillFrontmost: sourceMatches
                            ) {
                                authorized.append((
                                    failure, ownProcess, canPost, secureInput, sourceMatches
                                ))
                            }
                        }
                    }
                }
            }
        }

        XCTAssertEqual(authorized.count, 1)
        guard let only = authorized.first else { return }
        XCTAssertEqual(only.0, .noFocusedElement)
        XCTAssertFalse(only.1)
        XCTAssertTrue(only.2)
        XCTAssertFalse(only.3)
        XCTAssertTrue(only.4)
    }

    // MARK: - Source-focus recovery

    func testFocusRecoveryReadsOnlyTheExactLiveSourceProcess() {
        XCTAssertEqual(
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: 42,
                frontmostPID: 42,
                sourceTerminated: false,
                remainingPolls: 0
            ),
            .read,
            "An exact match is safe even on the last permitted poll."
        )
        XCTAssertEqual(
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: 42,
                frontmostPID: 7,
                sourceTerminated: false,
                remainingPolls: 2
            ),
            .wait(remainingPolls: 1)
        )
        XCTAssertEqual(
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: 42,
                frontmostPID: nil,
                sourceTerminated: false,
                remainingPolls: 1
            ),
            .wait(remainingPolls: 0),
            "A transient nil from NSWorkspace consumes budget; it never authorizes a read."
        )
    }

    func testFocusRecoveryFailsClosedForTerminationInvalidPIDsAndInvalidBudgets() {
        let failures: [SelectionReader.SourceFocusRetryDecision] = [
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: 42,
                frontmostPID: 42,
                sourceTerminated: true,
                remainingPolls: 1
            ),
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: 0,
                frontmostPID: 0,
                sourceTerminated: false,
                remainingPolls: 1
            ),
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: -1,
                frontmostPID: -1,
                sourceTerminated: false,
                remainingPolls: 1
            ),
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: 42,
                frontmostPID: 7,
                sourceTerminated: false,
                remainingPolls: 0
            ),
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: 42,
                frontmostPID: 7,
                sourceTerminated: false,
                remainingPolls: -1
            ),
            SelectionReader.sourceFocusRetryDecision(
                sourcePID: 42,
                frontmostPID: 7,
                sourceTerminated: false,
                remainingPolls: SelectionReader.sourceFocusMaxPolls + 1
            ),
        ]
        XCTAssertEqual(failures, Array(repeating: .fail, count: failures.count))
    }

    func testFocusRecoveryBudgetIsPositiveAndCappedAtHalfASecond() {
        XCTAssertGreaterThan(SelectionReader.sourceFocusMaxPolls, 0)
        XCTAssertGreaterThan(SelectionReader.sourceFocusPollInterval, 0)
        XCTAssertLessThanOrEqual(
            Double(SelectionReader.sourceFocusMaxPolls)
                * SelectionReader.sourceFocusPollInterval,
            0.5
        )
    }

    func testFrontmostProcessMatchFailsClosedForUnknownAndInvalidIdentities() {
        XCTAssertTrue(PasteboardBroker.frontmostProcessMatches(expectedPID: 42, actualPID: 42))
        XCTAssertFalse(PasteboardBroker.frontmostProcessMatches(expectedPID: 42, actualPID: 7))
        XCTAssertFalse(PasteboardBroker.frontmostProcessMatches(expectedPID: 42, actualPID: nil))
        XCTAssertFalse(PasteboardBroker.frontmostProcessMatches(expectedPID: 0, actualPID: 0))
        XCTAssertFalse(PasteboardBroker.frontmostProcessMatches(expectedPID: -1, actualPID: -1))
    }

    // MARK: - Capture → outcome

    func testCapturedTextBecomesAClipboardSourcedSelection() {
        let outcome = SelectionReader.outcomeForClipboardCapture(
            text: "make this prompt sharper",
            bundleID: "com.google.antigravity",
            isWeakAX: { _ in true }
        )
        XCTAssertEqual(outcome?.result?.text, "make this prompt sharper")
        XCTAssertEqual(outcome?.result?.source, .clipboard)
        XCTAssertEqual(outcome?.result?.via, .clipboardCopy)
        XCTAssertEqual(outcome?.result?.bundleID, "com.google.antigravity")
        XCTAssertEqual(outcome?.result?.isWeakAX, true)
        if let outcome {
            XCTAssertEqual(
                SelectionReader.describe(outcome), "clipboard",
                "The diagnostic outcome label must say the text came off the board, not from AX."
            )
        }
    }

    func testBlankCaptureKeepsTheOriginalFailure() {
        XCTAssertNil(SelectionReader.outcomeForClipboardCapture(text: nil, bundleID: "a"))
        XCTAssertNil(SelectionReader.outcomeForClipboardCapture(text: "", bundleID: "a"))
        XCTAssertNil(
            SelectionReader.outcomeForClipboardCapture(text: " \n\u{200B}", bundleID: "a"),
            "A whitespace answer to ⌘C is not a selection, and must not repaint the failure "
                + "as emptySelection either."
        )
    }

    func testOversizedCaptureIsRefusedByNameNotSilentlyDropped() {
        let huge = String(repeating: "x", count: SelectionReader.maxSelectionCharacters + 1)
        let outcome = SelectionReader.outcomeForClipboardCapture(text: huge, bundleID: "a")
        XCTAssertEqual(outcome?.failure, .selectionTooLarge(huge.count))

        let atLimit = String(repeating: "y", count: SelectionReader.maxSelectionCharacters)
        XCTAssertNotNil(
            SelectionReader.outcomeForClipboardCapture(text: atLimit, bundleID: "a")?.result
        )
    }

    // MARK: - Labels

    func testClipboardLabelsAreDistinctAndStable() {
        XCTAssertEqual(SelectionReader.ReadVia.clipboardCopy.rawValue, "clipboardCopy")
        XCTAssertEqual(SelectionReader.Source.clipboard.rawValue, "clipboard")

        let outcomes: [PasteboardBroker.CopyCaptureOutcome] = [
            .captured("x"), .boardUnchanged, .noStringOnBoard, .postFailed,
            .sourceAppChanged, .secureInputActive,
        ]
        XCTAssertEqual(Set(outcomes.map(\.diagnosticLabel)).count, outcomes.count)
    }

    // MARK: - Restore verification policy

    func testRestoreOnlyWhenTheBoardStillShowsOurObservedCopy() {
        XCTAssertTrue(
            PasteboardBroker.shouldRestoreAfterCopyCapture(
                changeCountNow: 7, changeCountAfterCopy: 7
            )
        )
        XCTAssertFalse(
            PasteboardBroker.shouldRestoreAfterCopyCapture(
                changeCountNow: 8, changeCountAfterCopy: 7
            ),
            "Another writer got there after the capture; restoring would eat their data to "
                + "clean up after ours."
        )
    }

    // MARK: - Capture mechanics against a real (private) pasteboard

    /// A unique named pasteboard per test: the general board belongs to the user running the
    /// tests, and these tests exist precisely to prove we do not trample clipboards.
    private func makePasteboard(_ function: String = #function) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("devtype.test.\(function).\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    func testFocusTheftStopsBeforePostingOrTouchingTheClipboard() {
        let pasteboard = makePasteboard()
        pasteboard.setString("user clipboard", forType: .string)
        let before = pasteboard.changeCount
        var postRan = false

        let outcome = PasteboardBroker().captureSelectionViaCopy(
            pasteboard: pasteboard,
            expectedFrontmostPID: 42,
            timeout: 5,
            pollInterval: 0.005,
            frontmostPIDProvider: { 7 },
            secureInputProvider: { false },
            postCopy: {
                postRan = true
                return true
            }
        )

        XCTAssertEqual(outcome, .sourceAppChanged)
        XCTAssertFalse(postRan)
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
    }

    func testLateSecureInputStopsBeforePostingOrTouchingTheClipboard() {
        let pasteboard = makePasteboard()
        pasteboard.setString("user clipboard", forType: .string)
        let before = pasteboard.changeCount
        var postRan = false

        let outcome = PasteboardBroker().captureSelectionViaCopy(
            pasteboard: pasteboard,
            expectedFrontmostPID: 42,
            timeout: 5,
            pollInterval: 0.005,
            frontmostPIDProvider: { 42 },
            secureInputProvider: { true },
            postCopy: {
                postRan = true
                return true
            }
        )

        XCTAssertEqual(outcome, .secureInputActive)
        XCTAssertFalse(postRan)
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
    }

    func testCaptureReadsTheCopyAndRestoresThePriorClipboard() {
        let pasteboard = makePasteboard()
        pasteboard.setString("user's precious clipboard", forType: .string)

        let broker = PasteboardBroker()
        let outcome = broker.captureSelectionViaCopy(
            pasteboard: pasteboard,
            expectedFrontmostPID: 4_242,
            timeout: 0.2,
            pollInterval: 0.005,
            frontmostPIDProvider: { 4_242 },
            secureInputProvider: { false },
            postCopy: {
                // The "target app" answering ⌘C.
                pasteboard.clearContents()
                pasteboard.setString("the selection", forType: .string)
                return true
            }
        )

        XCTAssertEqual(outcome, .captured("the selection"))
        XCTAssertEqual(
            pasteboard.string(forType: .string), "user's precious clipboard",
            "The capture is a read, not a clipboard mutation the user can observe afterwards."
        )
    }

    func testUnansweredCopyLeavesTheBoardCompletelyUntouched() {
        let pasteboard = makePasteboard()
        pasteboard.setString("still here", forType: .string)
        let before = pasteboard.changeCount

        let broker = PasteboardBroker()
        let outcome = broker.captureSelectionViaCopy(
            pasteboard: pasteboard,
            expectedFrontmostPID: 4_242,
            timeout: 0.05,
            pollInterval: 0.005,
            frontmostPIDProvider: { 4_242 },
            secureInputProvider: { false },
            postCopy: { true }  // posted, but the app never writes the board
        )

        XCTAssertEqual(outcome, .boardUnchanged)
        XCTAssertEqual(
            pasteboard.changeCount, before,
            "No write happened, so not even a restore may touch the board."
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "still here")
    }

    func testFailedPostShortCircuitsBeforeAnyWaiting() {
        let pasteboard = makePasteboard()
        let started = Date()
        let outcome = PasteboardBroker().captureSelectionViaCopy(
            pasteboard: pasteboard,
            expectedFrontmostPID: 4_242,
            timeout: 5.0,  // deliberately huge: a failed post must not wait on it
            pollInterval: 0.005,
            frontmostPIDProvider: { 4_242 },
            secureInputProvider: { false },
            postCopy: { false }
        )
        XCTAssertEqual(outcome, .postFailed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testNonStringCopyIsReportedAndTheClipboardStillRestored() {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)

        let broker = PasteboardBroker()
        let outcome = broker.captureSelectionViaCopy(
            pasteboard: pasteboard,
            expectedFrontmostPID: 4_242,
            timeout: 0.2,
            pollInterval: 0.005,
            frontmostPIDProvider: { 4_242 },
            secureInputProvider: { false },
            postCopy: {
                pasteboard.clearContents()
                pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
                return true
            }
        )

        XCTAssertEqual(outcome, .noStringOnBoard)
        XCTAssertEqual(
            pasteboard.string(forType: .string), "original",
            "An image copy is not usable, but the user's clipboard still comes back."
        )
    }

    func testCaptureWithEmptyPriorClipboardRestoresToEmpty() {
        let pasteboard = makePasteboard()  // nothing on it

        let broker = PasteboardBroker()
        let outcome = broker.captureSelectionViaCopy(
            pasteboard: pasteboard,
            expectedFrontmostPID: 4_242,
            timeout: 0.2,
            pollInterval: 0.005,
            frontmostPIDProvider: { 4_242 },
            secureInputProvider: { false },
            postCopy: {
                pasteboard.clearContents()
                pasteboard.setString("transient selection", forType: .string)
                return true
            }
        )

        XCTAssertEqual(outcome, .captured("transient selection"))
        XCTAssertNil(
            pasteboard.string(forType: .string),
            "Leaving the captured selection on an empty board hands it to every clipboard "
                + "manager watching."
        )
    }

    // MARK: - Reader integration

    /// End-to-end through `readSelection`'s fallback branch is not reachable headless (it needs
    /// a frontmost app that is not the test runner and live AX). What is checkable is the
    /// contract: the reader must never invoke the capture unless the caller opted in — the
    /// palette-open path reads selections too and must never post keys.
    func testReaderDefaultsToNoClipboardFallback() {
        var captureRan = false
        _ = SelectionReader.readSelection(
            diagnostics: nil,
            clipboardCapture: {
                captureRan = true
                return .boardUnchanged
            }
        )
        XCTAssertFalse(
            captureRan,
            "The ordinary reader is AX-only; only the named explicit-AI entry point may copy."
        )
    }
}
