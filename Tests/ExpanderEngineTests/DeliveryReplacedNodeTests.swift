import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// WebKit can replace the focused text node when a paste lands. The text is in the field, but the
/// element the baseline captured is no longer focused, so the verifier used to answer
/// `.unavailable` — printed as "field unreadable" and indistinguishable from a host whose AX is
/// blind. These tests pin the two halves of the fix: the reason is its own fact, and a replacement
/// that is demonstrably the same control may verify (read-only, deferred), while a different
/// field never does.
///
/// AX elements here are identity tokens only (`AXUIElementCreateApplication`); every read goes
/// through the injected `TextAccess`, so nothing touches another process.
final class DeliveryReplacedNodeTests: XCTestCase {

    private let original = AXUIElementCreateApplication(4321)
    private let replacement = AXUIElementCreateApplication(4322)

    private let frame = CGRect(x: 120, y: 340, width: 480, height: 28)

    /// A field whose text node can be swapped for another element after the baseline.
    private final class Page {
        var focused: AXUIElement?
        var values: [String: String] = [:]
        var selections: [String: NSRange] = [:]
        var frames: [String: CGRect] = [:]
        var roles: [String: String] = [:]
        var pids: [String: pid_t] = [:]

        func key(_ element: AXUIElement) -> String { String(describing: element) }

        func access() -> DeliveryVerifier.TextAccess {
            .init(
                focusedElement: { [unowned self] in self.focused },
                numberOfCharacters: { [unowned self] element in
                    self.values[self.key(element)].map { ($0 as NSString).length }
                },
                selectedRange: { [unowned self] element in self.selections[self.key(element)] },
                stringForRange: { _, _ in nil },
                observation: { [unowned self] element in
                    let k = self.key(element)
                    return .init(value: self.values[k], selectedText: nil,
                                 selectedRange: self.selections[k], target: element)
                },
                frame: { [unowned self] element in self.frames[self.key(element)] },
                role: { [unowned self] element in self.roles[self.key(element)] },
                pid: { [unowned self] element in self.pids[self.key(element)] }
            )
        }
    }

    private func page(
        originalValue: String = "see ", caret: Int = 4
    ) -> (Page, DeliveryVerifier, DeliveryVerifier.FocusedTextObservation) {
        let page = Page()
        for element in [original, replacement] {
            let k = page.key(element)
            page.roles[k] = "AXTextField"
            page.pids[k] = 777
            page.frames[k] = frame
        }
        page.focused = original
        page.values[page.key(original)] = originalValue
        page.selections[page.key(original)] = NSRange(location: caret, length: 0)
        let verifier = DeliveryVerifier(access: page.access())
        let baseline = verifier.captureFocusedTextObservation(focus: .resolved(original))!
        return (page, verifier, baseline)
    }

    /// The paste lands: the old node is gone and a new one holds the new text and caret.
    private func swapNodeAfterPaste(_ page: Page, payload: String, into text: String = "see ", at caret: Int = 4) {
        let landed = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: payload)
        page.focused = replacement
        page.values[page.key(replacement)] = landed
        page.selections[page.key(replacement)] =
            NSRange(location: caret + (payload as NSString).length, length: 0)
    }

    func testBaselineCarriesTheFrameOfTheFieldItWasTakenOn() {
        let (_, _, baseline) = page()
        XCTAssertEqual(baseline.frame, frame)
    }

    func testReplacedNodeIsReportedAsReplacedNotUnreadable() {
        let (page, verifier, baseline) = page()
        swapNodeAfterPaste(page, payload: "EXPANSION")
        let reading = verifier.readFocusedTextDelivery(expectedText: "EXPANSION", baseline: baseline)
        XCTAssertEqual(reading.verification, .unavailable)
        XCTAssertEqual(reading.unavailableReason, .focusReplaced)
        XCTAssertEqual(
            verifier.verifyFocusedTextDelivery(expectedText: "EXPANSION", baseline: baseline), .unavailable,
            "The strict gate every hold-loop tick uses must not change"
        )
    }

    func testVouchedReplacementVerifiesTheDeliveryOnTheNewNode() {
        let (page, verifier, baseline) = page()
        swapNodeAfterPaste(page, payload: "EXPANSION")
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
        )
        XCTAssertEqual(reading.verification, .delivered)
        XCTAssertNil(reading.unavailableReason)
        XCTAssertNotNil(reading.replacementElement)
        XCTAssertTrue(CFEqual(reading.replacementElement!, replacement))
    }

    func testReplacementAtADifferentFrameIsADifferentControl() {
        let (page, verifier, baseline) = page()
        swapNodeAfterPaste(page, payload: "EXPANSION")
        page.frames[page.key(replacement)] = frame.offsetBy(dx: 0, dy: 60)
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
        )
        XCTAssertEqual(reading.verification, .unavailable)
        XCTAssertEqual(reading.unavailableReason, .focusReplaced)
    }

    func testReplacementInAnotherProcessNeverVerifies() {
        let (page, verifier, baseline) = page()
        swapNodeAfterPaste(page, payload: "EXPANSION")
        page.pids[page.key(replacement)] = 778
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
        )
        XCTAssertEqual(reading.unavailableReason, .focusReplaced)
    }

    func testReplacementThatIsNotATextFieldNeverVerifies() {
        for role in ["AXWebArea", "AXGroup", "AXSecureTextField", "AXComboBox", ""] {
            let (page, verifier, baseline) = page()
            swapNodeAfterPaste(page, payload: "EXPANSION")
            page.roles[page.key(replacement)] = role
            let reading = verifier.readFocusedTextDelivery(
                expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
            )
            XCTAssertEqual(reading.unavailableReason, .focusReplaced, "role \(role)")
        }
    }

    func testMissingGeometryOrRoleFailsClosed() {
        let (page, verifier, baseline) = page()
        swapNodeAfterPaste(page, payload: "EXPANSION")
        page.frames[page.key(replacement)] = nil
        XCTAssertEqual(
            verifier.readFocusedTextDelivery(
                expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
            ).unavailableReason, .focusReplaced
        )
        page.frames[page.key(replacement)] = frame
        page.roles[page.key(replacement)] = nil
        XCTAssertEqual(
            verifier.readFocusedTextDelivery(
                expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
            ).unavailableReason, .focusReplaced
        )
    }

    func testBaselineWithoutAFrameCannotVouchForAReplacement() {
        let (page, verifier, _) = page()
        let noFrame = DeliveryVerifier.FocusedTextObservation(
            value: "see ", selectedText: nil, selectedRange: NSRange(location: 4, length: 0), target: original
        )
        swapNodeAfterPaste(page, payload: "EXPANSION")
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: noFrame, vouchingReplacement: true
        )
        XCTAssertEqual(reading.unavailableReason, .focusReplaced)
    }

    func testSameControlWhoseTextIsNotThePredictedOneDoesNotVerify() {
        // The user clicked into a sibling field that sits in the same place (a tab panel swap),
        // or the paste never landed: the replacement still does not hold baseline + payload.
        let (page, verifier, baseline) = page()
        page.focused = replacement
        page.values[page.key(replacement)] = "something else entirely"
        page.selections[page.key(replacement)] = NSRange(location: 4, length: 0)
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
        )
        XCTAssertEqual(reading.verification, .unavailable)
        XCTAssertEqual(reading.unavailableReason, .fieldUnreadable)
        XCTAssertNil(reading.replacementElement)
    }

    func testSameControlWhoseValueIsUnreadableIsUnreadableNotReplaced() {
        let (page, verifier, baseline) = page()
        swapNodeAfterPaste(page, payload: "EXPANSION")
        page.values[page.key(replacement)] = nil
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
        )
        XCTAssertEqual(reading.unavailableReason, .fieldUnreadable)
    }

    func testTheSameElementKeepsItsExistingVerdictsAndReasons() {
        let (page, verifier, baseline) = page()
        let k = page.key(original)
        page.values[k] = "see EXPANSION"
        page.selections[k] = NSRange(location: 13, length: 0)
        let delivered = verifier.readFocusedTextDelivery(expectedText: "EXPANSION", baseline: baseline)
        XCTAssertEqual(delivered.verification, .delivered)
        XCTAssertNil(delivered.unavailableReason)
        XCTAssertNil(delivered.replacementElement)

        page.values[k] = nil
        let unreadable = verifier.readFocusedTextDelivery(expectedText: "EXPANSION", baseline: baseline)
        XCTAssertEqual(unreadable.unavailableReason, .fieldUnreadable)
    }

    func testNoFocusAndNoBaselineAreTheirOwnReasons() {
        let (page, verifier, baseline) = page()
        page.focused = nil
        XCTAssertEqual(
            verifier.readFocusedTextDelivery(expectedText: "x", baseline: baseline).unavailableReason,
            .noFocusedElement
        )
        XCTAssertEqual(
            verifier.readFocusedTextDelivery(expectedText: "x", baseline: nil).unavailableReason,
            .noBaselineTarget
        )
    }
}
