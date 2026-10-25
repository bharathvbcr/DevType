import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

/// A trigger that matched, was swallowed, and then abandoned before the inject pipeline took it
/// must say so in "Matched-then-dropped". The three drops the tap callback records are the ones
/// that happen *before* the claim; every abort after it (`refuseAfterSwallow`) used to leave that
/// section reading "none", which then proved nothing about a snippet that did not expand.
///
/// These drive the real `finishDeferredInject`, whose first branches (a render failure, input
/// since arm, focus left the armed app) run before any AX query, so they are reachable without a
/// focused field.
final class MatchDropAbortTests: TapEventTestCase {

    private func resolved(failure: MacroRenderFailure? = nil) -> MacroExpansionResult {
        MacroExpansionResult(
            text: "expanded", cursorOffset: nil, trailingKeys: [], fillFields: [],
            needsFillIn: false, failure: failure
        )
    }

    private func finish(
        quiescence: InputQuiescenceGuard,
        armedFocusPID: pid_t? = nil,
        resolved: MacroExpansionResult? = nil
    ) {
        XCTAssertTrue(engine.tryBeginExpansion())
        engine.finishDeferredInject(
            snippet: prefixTriggerSnippet("`slm"),
            triggerUTF16Length: 4,
            lastEventUTF16Count: 1,
            swallowed: .notSwallowed,
            terminator: "",
            eraseCountOverride: nil,
            erasePlan: ErasePlan.forMatch(
                matchedTrigger: "`slm", terminator: "", swallowed: .notSwallowed, caseInsensitive: true
            ),
            resolved: resolved ?? self.resolved(),
            clipboardSnapshot: nil,
            quiescence: quiescence,
            armedFocusPID: armedFocusPID
        )
    }

    /// Input arrived after the arm: the quiescence guard refuses a swallowed expansion.
    func testInputAfterArmIsCountedAsAMatchedThenDroppedExpansion() {
        let armed = InputQuiescenceGuard(armedAt: 0)
        engine.inputClock.mark(at: InputClock.monotonicNow())
        finish(quiescence: armed)

        XCTAssertEqual(engine.matchDropCounters.userInputAfterArm, 1)
        XCTAssertEqual(engine.matchDropCounters.total, 1)
        XCTAssertEqual(engine.matchDropCounters.lastReason, "userInputAfterArm")
        let report = engine.matchDropDiagnostics().joined(separator: "\n")
        XCTAssertTrue(report.contains("user-input-after-arm=1"), report)
        XCTAssertFalse(report.contains("none"), report)
    }

    func testFocusMovingAwayAfterTheMatchIsCounted() {
        let armed = InputQuiescenceGuard(armedAt: .greatestFiniteMagnitude)
        finish(quiescence: armed, armedFocusPID: -7)

        XCTAssertEqual(engine.matchDropCounters.focusMoved, 1)
        XCTAssertEqual(engine.matchDropCounters.lastReason, "focusMoved")
    }

    func testAMacroThatCouldNotBeRenderedIsCounted() {
        let armed = InputQuiescenceGuard(armedAt: .greatestFiniteMagnitude)
        finish(quiescence: armed, resolved: resolved(failure: .sourceChanged))

        XCTAssertEqual(engine.matchDropCounters.renderFailed, 1)
        XCTAssertEqual(engine.matchDropCounters.lastReason, "renderFailed")
    }

    /// The report line never carries the trigger itself, only its shape.
    func testTheDropCarriesNoTriggerTextAndNamesTheApp() {
        let armed = InputQuiescenceGuard(armedAt: 0)
        engine.inputClock.mark(at: InputClock.monotonicNow())
        finish(quiescence: armed)

        let report = engine.matchDropDiagnostics().joined(separator: "\n")
        XCTAssertFalse(report.contains("`slm"), report)
        XCTAssertTrue(report.contains("triggerChars=4"), report)
    }

    /// Existing reasons keep their counters and the total still adds up.
    func testTheTapCallbackReasonsStillCountAndTotalTogether() {
        engine.recordMatchDrop(reason: "plannerRefused", trigger: nil, bundleID: nil)
        engine.recordMatchDrop(reason: "secureInputLive", trigger: nil, bundleID: nil)
        engine.recordMatchDrop(reason: "expansionInFlight", trigger: nil, bundleID: nil)
        engine.recordMatchDrop(reason: "somethingNew", trigger: nil, bundleID: nil)
        let drops = engine.matchDropCounters
        XCTAssertEqual(drops.plannerRefused, 1)
        XCTAssertEqual(drops.secureInputLive, 1)
        XCTAssertEqual(drops.expansionInFlight, 1)
        XCTAssertEqual(drops.total, 3, "an unrecognised reason is labelled unknown and not folded into a real counter")
        XCTAssertEqual(drops.lastReason, "unknown")
    }

    // MARK: - Wiring

    /// The pipeline's own silent exit: a delivery whose continue-check fails when it is about to be
    /// recorded used to complete `.postedUnverified` and write nothing, so the report showed no
    /// attempt at all for an expansion that had in fact been posted.
    func testAFinishedDeliveryThatTheContinuationRefusesStillLeavesARecord() throws {
        let pipeline = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        )
        let body = try SourceTree.functionBody("private func finishSucceeded(", in: pipeline)
        XCTAssertFalse(
            body.contains("else { completion(.postedUnverified); return }"),
            "a bare completion records nothing"
        )
        XCTAssertTrue(body.contains("finishAbandonedPaste("), "the abandoned delivery goes through the one recorder")
    }

    /// Every abort between the claim and the pipeline goes through `refuseAfterSwallow`, which is
    /// the one owner of the drop. A call site that cannot name why it dropped does not compile.
    func testEveryAbortAfterTheClaimNamesItsDropReason() throws {
        let source = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/EventTapEngine+Expansion.swift")
        )
        let owner = try SourceTree.functionBody("func refuseAfterSwallow(", in: source)
        XCTAssertTrue(owner.contains("recordMatchDrop("), "the one owner must record the drop")
        let calls = source.components(separatedBy: "refuseAfterSwallow(").dropFirst()
        XCTAssertGreaterThanOrEqual(calls.count, 15, "the enumeration below is of the real call sites")
        for call in calls.dropLast() {
            // The last piece is the declaration's own parameter list tail; every other piece is a call.
            XCTAssertTrue(
                call.prefix(400).contains("drop: ."),
                "a refusal after the swallow without a drop reason: \(call.prefix(120))"
            )
        }
    }
}
