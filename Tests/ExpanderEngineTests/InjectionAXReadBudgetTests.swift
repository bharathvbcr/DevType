import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// §2.2 / §2.6 read budgets: the erase re-check queries focus only when its answer depends on it,
/// and the paste-hold tick reads a window of the field instead of all of it.
final class InjectionAXReadBudgetTests: XCTestCase {

    // MARK: - liveMismatch focus queries

    private let element = AXUIElementCreateApplication(4321)
    private let other = AXUIElementCreateApplication(8765)

    private func target() -> PasteboardBroker.PasteTarget {
        .init(pid: 4321, element: element, range: nil)
    }

    func testAnEraseBurstWithNeitherFlagIssuesNoFocusQuery() {
        var seamQueries = 0
        let probed = FocusQueryProbe.counting {
            for _ in 0..<12 {
                let result = target().liveMismatch(
                    checkRange: false, checkElement: false,
                    observeFocus: { seamQueries += 1; return nil }, currentPID: { 4321 }
                )
                XCTAssertNil(result)
            }
            // The default (live) seam is just as quiet.
            for _ in 0..<12 {
                _ = target().liveMismatch(checkRange: false, checkElement: false, currentPID: { 4321 })
            }
        }
        XCTAssertEqual(seamQueries, 0)
        XCTAssertEqual(probed, 0)
    }

    func testPidChangeStillRefusesWithoutAFocusQuery() {
        var queries = 0
        let result = target().liveMismatch(
            checkRange: false, checkElement: false,
            observeFocus: { queries += 1; return nil }, currentPID: { 99 }
        )
        XCTAssertEqual(result, .processChanged)
        XCTAssertEqual(queries, 0)
    }

    func testRefusalOnMidEraseFocusChangeStillFiresWhenElementIsChecked() {
        var focus: AXUIElement? = element
        var queries = 0
        var results: [PasteboardBroker.PasteTarget.Mismatch?] = []
        for step in 0..<6 {
            if step == 3 { focus = other }
            results.append(target().liveMismatch(
                checkRange: false, checkElement: true,
                observeFocus: { queries += 1; return focus }, currentPID: { 4321 }
            ))
        }
        XCTAssertEqual(results, [nil, nil, nil, .elementChanged, .elementChanged, .elementChanged])
        XCTAssertEqual(queries, 6, "A checked burst keeps its live per-step query")
    }

    func testFocusLossIsRefusedWhenOnlyTheRangeIsChecked() {
        var queries = 0
        let result = PasteboardBroker.PasteTarget(pid: 4321, element: element, range: NSRange(location: 1, length: 0))
            .liveMismatch(checkRange: true, checkElement: false,
                          observeFocus: { queries += 1; return nil }, currentPID: { 4321 })
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(result, .rangeChanged, "No element to read the caret from reads as a moved range")
    }

    // MARK: - windowed paste-hold verification

    private final class Field {
        var text: String
        var selection: NSRange
        var supportsCount = true
        var supportsRange = true
        var fullReads = 0
        var windowReads: [NSRange] = []
        var maxWindow = 0
        let element: AXUIElement
        init(_ text: String, selection: NSRange, element: AXUIElement) {
            self.text = text; self.selection = selection; self.element = element
        }

        func access() -> DeliveryVerifier.TextAccess {
            .init(
                focusedElement: { [unowned self] in self.element },
                numberOfCharacters: { [unowned self] _ in self.supportsCount ? (self.text as NSString).length : nil },
                selectedRange: { [unowned self] _ in self.selection },
                stringForRange: { [unowned self] _, range in
                    guard self.supportsRange else { return nil }
                    self.windowReads.append(range)
                    self.maxWindow = max(self.maxWindow, range.length)
                    let ns = self.text as NSString
                    guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
                    return ns.substring(with: range)
                },
                observation: { [unowned self] element in
                    self.fullReads += 1
                    return .init(value: self.text, selectedText: nil, selectedRange: self.selection, target: element)
                }
            )
        }
    }

    /// Baseline = `before` with the caret at `caret`; the paste then inserts `payload` there.
    private func run(
        before: String, caret: Int, payload: String, after: String? = nil,
        configure: (Field) -> Void = { _ in }
    ) -> (DeliveryVerifier.TextDeliveryVerification, Field) {
        let ns = before as NSString
        let field = Field(before, selection: NSRange(location: caret, length: 0), element: element)
        let verifier = DeliveryVerifier(access: field.access())
        let baseline = verifier.captureFocusedTextObservation(focus: .resolved(element))
        field.fullReads = 0
        let landed = after ?? ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: payload)
        field.text = landed
        field.selection = NSRange(location: caret + (payload as NSString).length, length: 0)
        configure(field)
        return (verifier.verifyFocusedTextDelivery(expectedText: payload, baseline: baseline), field)
    }

    func testDeliveryInTheMiddleReadsAWindowAndNeverTheWholeField() {
        let before = String(repeating: "a", count: 5_000)
        let (verdict, field) = run(before: before, caret: 2_500, payload: "HELLO")
        XCTAssertEqual(verdict, .delivered)
        XCTAssertEqual(field.fullReads, 0)
        XCTAssertEqual(field.windowReads.count, 1)
        XCTAssertLessThanOrEqual(field.maxWindow, 2 * DeliveryVerifier.verificationCaretSlackUTF16 + 5)
    }

    func testWindowAtStartOfField() {
        let (verdict, field) = run(before: "world", caret: 0, payload: "hello ")
        XCTAssertEqual(verdict, .delivered)
        XCTAssertEqual(field.fullReads, 0)
        XCTAssertEqual(field.windowReads.first?.location, 0)
    }

    func testWindowAtEndOfField() {
        let (verdict, field) = run(before: "hello", caret: 5, payload: " world")
        XCTAssertEqual(verdict, .delivered)
        XCTAssertEqual(field.fullReads, 0)
        XCTAssertEqual(field.windowReads.first.map { $0.location + $0.length }, 11)
    }

    func testEmptyFieldDelivery() {
        let (verdict, field) = run(before: "", caret: 0, payload: "x")
        XCTAssertEqual(verdict, .delivered)
        XCTAssertEqual(field.fullReads, 0)
    }

    func testNothingLandedYetAnswersUnavailableWithoutAnyFieldRead() {
        let (verdict, field) = run(before: "hello", caret: 5, payload: " world", after: "hello")
        XCTAssertEqual(verdict, .unavailable)
        XCTAssertEqual(field.fullReads, 0)
        XCTAssertTrue(field.windowReads.isEmpty)
    }

    func testFieldShorterThanExpectedIsNotDelivered() {
        let (verdict, _) = run(before: "hello", caret: 5, payload: " world", after: "hell")
        XCTAssertNotEqual(verdict, .delivered)
    }

    func testWrongTextOfTheRightLengthIsNotDelivered() {
        let (verdict, _) = run(before: "hello", caret: 5, payload: " world", after: "hello XXXXX")
        XCTAssertNotEqual(verdict, .delivered)
    }

    func testUnsupportedNumberOfCharactersFallsBackToTheFullRead() {
        let (verdict, field) = run(before: "hello", caret: 5, payload: " world") { $0.supportsCount = false }
        XCTAssertEqual(verdict, .delivered)
        XCTAssertEqual(field.fullReads, 1)
        XCTAssertTrue(field.windowReads.isEmpty)
    }

    func testUnsupportedStringForRangeFallsBackToTheFullRead() {
        let (verdict, field) = run(before: "hello", caret: 5, payload: " world") { $0.supportsRange = false }
        XCTAssertEqual(verdict, .delivered)
        XCTAssertEqual(field.fullReads, 1)
    }

    func testUnsupportedAttributesNeverInventADelivery() {
        let (verdict, _) = run(before: "hello", caret: 5, payload: " world", after: "hello") {
            $0.supportsCount = false
            $0.supportsRange = false
        }
        XCTAssertEqual(verdict, .unavailable)
    }

    func testCountInDifferentUnitsFallsBackToTheFullRead() {
        // A host that counts composed characters reports 5 for a 6-unit field; the whole-field
        // read decides, exactly as before.
        let payload = "x😀y"   // 4 UTF-16 units
        let field = Field("ab", selection: NSRange(location: 2, length: 0), element: element)
        let verifier = DeliveryVerifier(access: field.access())
        let baseline = verifier.captureFocusedTextObservation(focus: .resolved(element))
        field.text = "ab" + payload
        field.selection = NSRange(location: 6, length: 0)
        var access = field.access()
        access.numberOfCharacters = { _ in 5 }
        let verdict = DeliveryVerifier(access: access).verifyFocusedTextDelivery(expectedText: payload, baseline: baseline)
        XCTAssertEqual(verdict, .delivered)
    }

    func testEmojiAndSurrogateOffsetsAreInUTF16Units() {
        let before = "😀😀😀 tail"      // 3 emoji = 6 units, caret after them
        let (verdict, field) = run(before: before, caret: 6, payload: "👍🏽é")
        XCTAssertEqual(verdict, .delivered)
        XCTAssertEqual(field.fullReads, 0)
        let window = field.windowReads[0]
        XCTAssertEqual(window.location, 0)
        XCTAssertEqual(window.length, ("😀😀😀👍🏽é tail" as NSString).length)
    }

    func testPayloadReplacingASelectionWithSurrogates() {
        let field = Field("a😀b", selection: NSRange(location: 1, length: 2), element: element)
        let verifier = DeliveryVerifier(access: field.access())
        let baseline = verifier.captureFocusedTextObservation(focus: .resolved(element))
        field.fullReads = 0
        field.text = "a🎉b"
        field.selection = NSRange(location: 3, length: 0)
        XCTAssertEqual(verifier.verifyFocusedTextDelivery(expectedText: "🎉", baseline: baseline), .delivered)
        XCTAssertEqual(field.fullReads, 0)
    }

    func testFocusMovingMidHoldIsUnavailable() {
        let field = Field("hello", selection: NSRange(location: 5, length: 0), element: element)
        var access = field.access()
        let verifier = DeliveryVerifier(access: access)
        let baseline = verifier.captureFocusedTextObservation(focus: .resolved(element))
        field.text = "hello world"
        access.focusedElement = { [other] in other }
        XCTAssertEqual(DeliveryVerifier(access: access).verifyFocusedTextDelivery(
            expectedText: " world", baseline: baseline), .unavailable)
    }
}
