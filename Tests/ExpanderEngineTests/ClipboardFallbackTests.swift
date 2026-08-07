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
                secureInputActive: false
            )
        )
        // Every other failure keeps its own meaning. `.emptySelection` above all — that is the
        // VS Code copy-a-line-you-never-selected case.
        let never: [SelectionReader.Failure] = [
            .emptySelection, .accessibilityUntrusted, .secureInputActive,
            .appMuted("com.example"), .selectionTooLarge(1),
        ]
        for failure in never {
            XCTAssertFalse(
                SelectionReader.shouldAttemptClipboardFallback(
                    failure: failure,
                    frontmostIsOwnProcess: false,
                    canPostEvents: true,
                    secureInputActive: false
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
                secureInputActive: false
            )
        )
        // Post Events revoked mid-session: nothing to post with.
        XCTAssertFalse(
            SelectionReader.shouldAttemptClipboardFallback(
                failure: .noFocusedElement,
                frontmostIsOwnProcess: false,
                canPostEvents: false,
                secureInputActive: false
            )
        )
        // Secure Input engaged while the AX ladder was failing: the re-check is live, not the
        // value captured at read start.
        XCTAssertFalse(
            SelectionReader.shouldAttemptClipboardFallback(
                failure: .noFocusedElement,
                frontmostIsOwnProcess: false,
                canPostEvents: true,
                secureInputActive: true
            )
        )
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

    func testCaptureReadsTheCopyAndRestoresThePriorClipboard() {
        let pasteboard = makePasteboard()
        pasteboard.setString("user's precious clipboard", forType: .string)

        let broker = PasteboardBroker()
        let outcome = broker.captureSelectionViaCopy(
            pasteboard: pasteboard,
            timeout: 0.2,
            pollInterval: 0.005,
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
            timeout: 0.05,
            pollInterval: 0.005,
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
            timeout: 5.0,  // deliberately huge: a failed post must not wait on it
            pollInterval: 0.005,
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
            timeout: 0.2,
            pollInterval: 0.005,
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
            timeout: 0.2,
            pollInterval: 0.005,
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
            "allowClipboardFallback defaults to false; only the AI hotkey path opts in."
        )
    }
}
