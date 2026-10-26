import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// `AXTextWriter.performAXRangeReplace` judged "the write did not land" (`.falseSuccess`) from one
/// synchronous read taken straight after the write. A host whose AX tree lags a real edit (Safari,
/// Chromium, Electron: the same hosts the surrounding comments already name) answers that read with
/// the OLD value, and the verdict then (1) restored the selection to where the caret was before the
/// write — inside an expansion that had landed, (2) recorded a permanent condemnation of a merely
/// slow app, and (3) sent the HID fallback at the new text. These tests script a host that lags,
/// one that lies, and one that is fresh, and pin what each is told.
final class AXRangeReplaceStaleReadTests: XCTestCase {

    /// A text field behind the writer's AX surface. `lag`: reads keep showing the pre-write
    /// value until `catchUp()`. `lies`: `setSelectedText` reports success and changes nothing.
    private final class Field {
        var real: String
        var selection: CFRange
        var visible: String
        var lag = false
        var lies = false
        /// Every selection the writer asked for, in order.
        var selectionWrites: [CFRange] = []
        /// What `value` returns, when set: lets a test hide the baseline from the writer.
        var valueReadable = true
        var selectedTextReadable = true
        /// While lagging, the selected text a read still reports (the widened trigger).
        var staleSelectedText: String?

        init(_ text: String, caret: Int) {
            real = text
            visible = text
            selection = CFRange(location: caret, length: 0)
        }

        func catchUp() {
            visible = real
            staleSelectedText = nil
        }

        var access: AXTextWriter.ElementAccess {
            AXTextWriter.ElementAccess(
                role: { _ in "AXTextArea" },
                selectedRange: { [unowned self] _ in selection },
                setSelectedRange: { [unowned self] _, range in
                    selection = range
                    selectionWrites.append(range)
                    return .success
                },
                value: { [unowned self] _ in valueReadable ? visible : nil },
                setSelectedText: { [unowned self] _, text in
                    guard !lies else { return .success }
                    let ns = real as NSString
                    if lag { staleSelectedText = ns.substring(with: NSRange(location: selection.location, length: selection.length)) }
                    real = ns.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: text)
                    selection = CFRange(location: selection.location + text.utf16.count, length: 0)
                    if !lag { visible = real }
                    return .success
                },
                selectedText: { [unowned self] _ in
                    guard selectedTextReadable else { return nil }
                    if let staleSelectedText { return staleSelectedText }
                    let ns = visible as NSString
                    guard selection.location + selection.length <= ns.length else { return "" }
                    return ns.substring(with: NSRange(location: selection.location, length: selection.length))
                }
            )
        }
    }

    private let element = AXUIElementCreateApplication(getpid())

    private func writer(_ field: Field) -> AXTextWriter {
        AXTextWriter(verifier: DeliveryVerifier(), access: field.access)
    }

    private func replace(_ writer: AXTextWriter) -> AXTextWriter.AXReplaceOutcome {
        // `bundleID: nil` keeps the process-wide capability store out of the test.
        writer.performAXRangeReplace(text: "ScholarLM", eraseCount: 3, bundleID: nil, focus: .resolved(element))
    }

    private let original = CFRange(location: 10, length: 0)

    // MARK: - A host that lags a real edit

    /// The red case: the write landed, the first read shows the old value.
    func testALaggingHostIsNotJudgedFromTheFirstRead() throws {
        let field = Field("some text slm", caret: 13)
        field.selection = CFRange(location: 13, length: 0)
        field.lag = true
        let writer = writer(field)

        let outcome = replace(writer)

        guard case .unconfirmed(let pending) = outcome else {
            return XCTFail("a read straight after the write cannot condemn it: \(outcome)")
        }
        XCTAssertTrue(outcome.fieldMayHaveMutated)
        XCTAssertEqual(field.real, "some text ScholarLM", "the write really landed")
        XCTAssertEqual(field.selectionWrites.count, 1,
                       "only the widening: the caret is NOT put back inside the expansion that landed")
        XCTAssertEqual(field.selection.location, 19, "the caret is where the host left it, after the text")

        field.catchUp()
        XCTAssertEqual(writer.confirmRangeReplace(pending), .replaced)
        XCTAssertEqual(field.selectionWrites.count, 1, "and a confirmed landing restores nothing")
    }

    // MARK: - A host that lies

    func testALyingHostIsJudgedOnlyAfterTheSettle() throws {
        let field = Field("some text slm", caret: 13)
        field.lies = true
        let writer = writer(field)

        let outcome = replace(writer)
        guard case .unconfirmed(let pending) = outcome else {
            return XCTFail("the lie is not yet distinguishable from a lag: \(outcome)")
        }
        XCTAssertEqual(field.selectionWrites.count, 1, "the widened selection stays until the verdict")

        // The settle passes and the field still shows nothing: now it is evidence.
        XCTAssertEqual(writer.confirmRangeReplace(pending), .falseSuccess)
        XCTAssertEqual(field.selectionWrites.count, 2)
        XCTAssertEqual(field.selectionWrites.last?.location, 13, "the caret goes back where it was found")
        XCTAssertEqual(field.selectionWrites.last?.length, 0)
        XCTAssertEqual(field.real, "some text slm", "a lie changed nothing")
    }

    // MARK: - A fresh host

    func testAFreshHostIsConfirmedImmediately() throws {
        let field = Field("some text slm", caret: 13)
        let outcome = replace(writer(field))
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(field.selectionWrites.count, 1)
    }

    // MARK: - The other two judgements that used to condemn on one read

    /// No baseline (the value could not be read before the write), then a stale value that lacks
    /// the text: the containment judgement is just as stale-prone.
    func testNoBaselineAndAStaleValueIsNotCondemned() throws {
        let field = Field("some text slm", caret: 13)
        field.lag = true
        var reads = 0
        var access = field.access
        let lagging = access.value
        access.value = { element in
            reads += 1
            return reads == 1 ? nil : lagging(element)
        }
        let writer = AXTextWriter(verifier: DeliveryVerifier(), access: access)

        guard case .unconfirmed = replace(writer) else {
            return XCTFail("a containment miss on a stale read is not a verdict")
        }
    }

    /// AXValue unreadable; the selection read straight after the write still shows the widened
    /// trigger because the host has not collapsed it yet.
    func testAStaleSelectionIsNotCondemned() throws {
        let field = Field("some text slm", caret: 13)
        field.valueReadable = false
        field.lag = true
        let writer = writer(field)

        guard case .unconfirmed = replace(writer) else {
            return XCTFail("a selection that has not caught up is not a verdict")
        }
    }

    /// Nothing readable at all stays what it always was: applied, unverified, nothing learned.
    func testAnUnreadableFieldIsStillAppliedButUnverified() throws {
        let field = Field("some text slm", caret: 13)
        field.valueReadable = false
        field.selectedTextReadable = false
        XCTAssertEqual(replace(writer(field)), .replaced)
    }

    // MARK: - Unchanged contract

    func testAFailedSelectedTextWriteStillRestoresTheSelection() throws {
        let field = Field("some text slm", caret: 13)
        var access = field.access
        access.setSelectedText = { _, _ in .cannotComplete }
        let writer = AXTextWriter(verifier: DeliveryVerifier(), access: access)

        guard case .unavailable = replace(writer) else { return XCTFail("expected .unavailable") }
        XCTAssertEqual(field.selectionWrites.count, 2)
        XCTAssertEqual(field.selectionWrites.last?.location, 13)
    }

    func testAnUnreadableRangeIsNotAttempted() throws {
        let field = Field("some text slm", caret: 13)
        var access = field.access
        access.selectedRange = { _ in nil }
        let writer = AXTextWriter(verifier: DeliveryVerifier(), access: access)
        guard case .notAttempted = replace(writer) else { return XCTFail("expected .notAttempted") }
        XCTAssertTrue(field.selectionWrites.isEmpty, "nothing touched")
    }
}
