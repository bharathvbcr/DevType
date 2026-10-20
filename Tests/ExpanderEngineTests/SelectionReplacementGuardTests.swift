import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// A replace pastes over whatever is selected when ⌘V lands. Field report (1.3.0, Messages): the
/// AI result was pasted after the source app came back to the front, by which time Messages had
/// collapsed the selection to a caret — so the result landed beside the original and the message
/// read twice. These pin the guard that now stands between that state and the paste.
final class SelectionReplacementGuardTests: XCTestCase {
    private let original = "teh quick brown fox"

    private func observation(
        value: String?,
        selectedText: String? = nil,
        range: NSRange? = nil
    ) -> DeliveryVerifier.FocusedTextObservation {
        DeliveryVerifier.FocusedTextObservation(value: value, selectedText: selectedText, selectedRange: range)
    }

    // MARK: - decide

    func testIntactSelectionProceeds() {
        let field = "say: \(original)"
        let decision = SelectionReplacementGuard.decide(
            original: original,
            observation: observation(value: field, selectedText: original, range: NSRange(location: 5, length: 19))
        )
        XCTAssertEqual(decision, .proceed)
    }

    func testSelectionReadThroughValueAndRangeWhenSelectedTextIsUnanswered() {
        let field = "say: \(original)"
        let decision = SelectionReplacementGuard.decide(
            original: original,
            observation: observation(value: field, selectedText: nil, range: NSRange(location: 5, length: 19))
        )
        XCTAssertEqual(decision, .proceed)
    }

    func testEmptySelectedTextBesideANonEmptyRangeIsJudgedByTheRange() {
        let field = "say: \(original)"
        let decision = SelectionReplacementGuard.decide(
            original: original,
            observation: observation(value: field, selectedText: "", range: NSRange(location: 5, length: 19))
        )
        XCTAssertEqual(decision, .proceed)
    }

    /// The Messages incident: caret collapsed at the end of the original. Pre-fix this state was
    /// pasted into directly — the duplicate.
    func testCollapsedCaretAfterTheOriginalReselectsIt() {
        let field = "say: \(original)"
        let decision = SelectionReplacementGuard.decide(
            original: original,
            observation: observation(value: field, selectedText: "", range: NSRange(location: 24, length: 0))
        )
        XCTAssertEqual(decision, .reselect(NSRange(location: 5, length: 19)))
    }

    func testCaretMovedElsewhereStillReselectsAUniqueOriginal() {
        let field = "\(original) and more"
        let decision = SelectionReplacementGuard.decide(
            original: original,
            observation: observation(value: field, selectedText: nil, range: NSRange(location: 0, length: 0))
        )
        XCTAssertEqual(decision, .reselect(NSRange(location: 0, length: 19)))
    }

    func testSelectAllOnReturnIsNotTheOriginalAndReselectsIt() {
        let field = "hi — \(original)"
        let decision = SelectionReplacementGuard.decide(
            original: original,
            observation: observation(
                value: field, selectedText: field, range: NSRange(location: 0, length: (field as NSString).length)
            )
        )
        XCTAssertEqual(decision, .reselect(NSRange(location: 5, length: 19)))
    }

    func testEditedAwayOriginalRefuses() {
        let decision = SelectionReplacementGuard.decide(
            original: original,
            observation: observation(value: "something else entirely", selectedText: "", range: NSRange(location: 4, length: 0))
        )
        XCTAssertEqual(decision, .refuse(.originalNotFound))
    }

    func testRepeatedOriginalIsResolvedOnlyByTheCaretEdge() {
        let word = "ok ok"
        let field = "\(word)\n\(word)"
        // Caret at the end of the second occurrence: that one.
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: word,
                observation: observation(value: field, selectedText: "", range: NSRange(location: 11, length: 0))
            ),
            .reselect(NSRange(location: 6, length: 5))
        )
        // Caret touching neither: no way to know which one the user selected.
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: "ok",
                observation: observation(value: "ok, then ok", selectedText: "", range: NSRange(location: 3, length: 0))
            ),
            .refuse(.originalAmbiguous)
        )
    }

    func testSurrogatePairsAreSearchedInUTF16() {
        let emojiOriginal = "fix 👍🏽 this"
        let field = "👋 \(emojiOriginal)"
        let decision = SelectionReplacementGuard.decide(
            original: emojiOriginal,
            observation: observation(value: field, selectedText: "", range: NSRange(location: 0, length: 0))
        )
        let expected = (field as NSString).range(of: emojiOriginal)
        XCTAssertEqual(decision, .reselect(expected))
    }

    func testMismatchWithAnUnreadableFieldRefuses() {
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: original,
                observation: observation(value: nil, selectedText: "", range: NSRange(location: 3, length: 0))
            ),
            .refuse(.selectionChanged)
        )
    }

    func testNothingReadableIsUnverifiable() {
        XCTAssertEqual(
            SelectionReplacementGuard.decide(original: original, observation: observation(value: nil)),
            .unverifiable
        )
        XCTAssertEqual(SelectionReplacementGuard.decide(original: original, observation: nil), .unverifiable)
    }

    func testNotFoundSentinelRangeIsIgnoredNotTrusted() {
        // Messages reports an empty compose field's range as location NSNotFound.
        let decision = SelectionReplacementGuard.decide(
            original: original,
            observation: observation(value: nil, selectedText: nil, range: NSRange(location: NSNotFound, length: 0))
        )
        XCTAssertEqual(decision, .unverifiable)
    }

    func testOversizedFieldIsRefusedNotScanned() {
        let field = String(repeating: "a", count: SelectionReplacementGuard.maxSearchUTF16 + 1)
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: original,
                observation: observation(value: field, selectedText: "", range: NSRange(location: 0, length: 0))
            ),
            .refuse(.fieldTooLarge)
        )
    }

    func testOccurrenceScanIsCapped() {
        let field = String(repeating: "x", count: 10_000) as NSString
        XCTAssertEqual(
            SelectionReplacementGuard.occurrences(of: "x", in: field).count,
            SelectionReplacementGuard.maxOccurrences
        )
        XCTAssertTrue(SelectionReplacementGuard.occurrences(of: "longer than field", in: "short").isEmpty)
    }

    func testEmptyOriginalIsNotAReplacement() {
        XCTAssertNil(SelectionReplacement(original: ""))
    }

    // MARK: - Confirmer

    /// Scripted field: each `observe` returns the next reading (the last one repeats).
    private final class FakeField {
        var readings: [DeliveryVerifier.FocusedTextObservation]
        var selected: [NSRange] = []
        var selectSucceeds = true
        var scheduled = 0
        var observed = 0

        init(_ readings: [DeliveryVerifier.FocusedTextObservation]) { self.readings = readings }

        var access: SelectionReplacementGuard.Confirmer.Access {
            SelectionReplacementGuard.Confirmer.Access(
                observe: { _ in
                    self.observed += 1
                    return self.readings.count > 1 ? self.readings.removeFirst() : self.readings[0]
                },
                select: { range, _ in
                    self.selected.append(range)
                    return self.selectSucceeds
                },
                schedule: { _, action in
                    self.scheduled += 1
                    action()
                }
            )
        }
    }

    private let element = AXUIElementCreateApplication(getpid())

    private func confirm(
        _ field: FakeField,
        replacement: SelectionReplacement? = nil,
        element: AXUIElement?? = nil
    ) -> SelectionReplacementGuard.Confirmer.Verdict? {
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: field.access).confirm(
            replacement ?? SelectionReplacement(original: original)!,
            element: element ?? self.element
        ) { verdict = $0 }
        return verdict
    }

    func testConfirmerPassesAnIntactSelectionWithoutWriting() {
        let field = FakeField([observation(value: original, selectedText: original, range: NSRange(location: 0, length: 19))])
        XCTAssertEqual(confirm(field), .confirmed(reselected: false))
        XCTAssertTrue(field.selected.isEmpty)
    }

    func testConfirmerReselectsACollapsedSelectionAndReadsItBack() {
        let text = "say: \(original)"
        let field = FakeField([
            observation(value: text, selectedText: "", range: NSRange(location: 24, length: 0)),
            observation(value: text, selectedText: original, range: NSRange(location: 5, length: 19))
        ])
        XCTAssertEqual(confirm(field), .confirmed(reselected: true))
        XCTAssertEqual(field.selected, [NSRange(location: 5, length: 19)])
    }

    /// A host that answers `.success` to the range write and keeps its caret must be refused,
    /// not pasted into — the write's return value is not evidence.
    func testConfirmerRefusesWhenTheReselectDoesNotTake() {
        let text = "say: \(original)"
        let collapsed = observation(value: text, selectedText: "", range: NSRange(location: 24, length: 0))
        let field = FakeField([collapsed])
        XCTAssertEqual(confirm(field), .refused(.reselectFailed))
        XCTAssertEqual(field.selected.count, 1, "one write, never a retry loop of writes")
        XCTAssertEqual(field.scheduled, SelectionReplacementGuard.Confirmer.readBackAttempts)
    }

    func testConfirmerWaitsForAHostThatPublishesTheSelectionLate() {
        let text = "say: \(original)"
        let collapsed = observation(value: text, selectedText: "", range: NSRange(location: 24, length: 0))
        let field = FakeField([
            collapsed, collapsed,
            observation(value: text, selectedText: original, range: NSRange(location: 5, length: 19))
        ])
        XCTAssertEqual(confirm(field), .confirmed(reselected: true))
        XCTAssertEqual(field.scheduled, 2)
    }

    func testConfirmerRefusesARejectedRangeWrite() {
        let field = FakeField([observation(value: "say: \(original)", selectedText: "", range: NSRange(location: 24, length: 0))])
        field.selectSucceeds = false
        XCTAssertEqual(confirm(field), .refused(.reselectFailed))
    }

    /// Field report (1.3.0, Safari proofread): the selection read live through `kAXSelectedText`,
    /// the transform succeeded, and the replace was refused as unreadable — the one reading the
    /// guard took landed while Safari was still restoring focus after DevType's panel resigned.
    /// A host that answers a moment later must be waited for, not refused on the first blank.
    func testConfirmerWaitsForAHostStillRestoringFocus() {
        let blind = observation(value: nil)
        let field = FakeField([
            blind, blind,
            observation(value: nil, selectedText: original)
        ])
        XCTAssertEqual(confirm(field), .confirmed(reselected: false))
        XCTAssertEqual(field.scheduled, 2)
        XCTAssertTrue(field.selected.isEmpty)
    }

    /// The settle is bounded, and a copy-read original (no AX evidence) is never waited for.
    func testConfirmerStopsSettlingAfterItsBudget() {
        let blindField = FakeField([observation(value: nil)])
        XCTAssertEqual(confirm(blindField), .refused(.unreadable))
        XCTAssertEqual(blindField.scheduled, SelectionReplacementGuard.Confirmer.settleAttempts)

        let copied = FakeField([observation(value: nil)])
        XCTAssertEqual(
            confirm(copied, replacement: SelectionReplacement(original: original, requiresEvidence: false)),
            .unverified
        )
        XCTAssertEqual(copied.scheduled, 0)
    }

    /// No element at entry (focus still in flight): the settle resolves one and reports it, so the
    /// pipeline judges the rest of the inject on that element rather than on the stale nil.
    func testConfirmerRefocusesWhenNoElementWasResolved() {
        let field = FakeField([observation(value: nil, selectedText: original)])
        var access = field.access
        var refocused = 0
        access.refocus = {
            refocused += 1
            return refocused < 2 ? nil : self.element
        }
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: nil
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false, refocusedOn: element))
        XCTAssertEqual(refocused, 2)
    }

    func testLadderFillsOnlyAnObservationWithNoSelectionAndNoRange() {
        let blank = observation(value: nil, selectedText: "")
        XCTAssertEqual(
            SelectionReplacementGuard.Confirmer.fillingSelection(blank) { self.original }.selectedText,
            original
        )
        // A caret is the host saying the selection collapsed; the ladder must not overrule it.
        let caret = observation(value: "say: \(original)", selectedText: "", range: NSRange(location: 24, length: 0))
        var consulted = false
        let kept = SelectionReplacementGuard.Confirmer.fillingSelection(caret) {
            consulted = true
            return self.original
        }
        XCTAssertEqual(kept, caret)
        XCTAssertFalse(consulted)
        // An answered selection is not re-read.
        let answered = observation(value: nil, selectedText: "other")
        XCTAssertEqual(SelectionReplacementGuard.Confirmer.fillingSelection(answered) { self.original }, answered)
    }

    func testUnreadableFieldRefusesUnlessTheOriginalCameFromACopy() {
        let blind = observation(value: nil)
        XCTAssertEqual(confirm(FakeField([blind])), .refused(.unreadable))
        XCTAssertEqual(
            confirm(FakeField([blind]), replacement: SelectionReplacement(original: original, requiresEvidence: false)),
            .unverified
        )
        XCTAssertEqual(confirm(FakeField([blind]), element: .some(nil)), .refused(.unreadable))
    }

    // MARK: - Pipeline seam

    /// End to end through `TextInjectionPipeline.inject`: a replace whose selection is gone and
    /// cannot be put back is refused before any branch posts ⌘V, and the generated payload is
    /// kept rather than lost. Pre-fix, this request shape had no way to say "replace", and the
    /// same delivery went straight to the clipboard paste — into the collapsed caret.
    func testPipelineRefusesAReplaceWhoseSelectionIsGoneInsteadOfPasting() throws {
        let field = FakeField([
            observation(value: "say: \(original)", selectedText: "", range: NSRange(location: 24, length: 0))
        ])
        let suite = "SelectionReplacementGuardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var kept: [String] = []
        let pipeline = TextInjectionPipeline(
            defaults: defaults,
            selectionConfirmer: SelectionReplacementGuard.Confirmer(access: field.access),
            keepRefusedReplacement: { kept.append($0); return true }
        )

        let result = "the quick brown fox"
        var outcome: PermissionCoordinator.InjectOutcome?
        let done = expectation(description: "inject completed")
        pipeline.inject(
            snippet: SnippetModel(title: "AI", triggerKeyword: "", replacementText: result),
            triggerLength: 0,
            swallowed: .notSwallowed,
            erasePlan: .empty,
            preResolvedText: result,
            secureClipboardPaste: true,
            replacingSelection: SelectionReplacement(original: original)
        ) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        // With no focused element at all (a headless runner) the guard is still reached and
        // refuses for lack of evidence — same contract, different cause.
        if outcome == .refused(SelectionReplacementGuard.Refusal.unreadable.reason) {
            XCTAssertEqual(kept, [result])
            return
        }
        // The entry gate runs first and compares live focus against the target captured at
        // enqueue; if this machine's focus moved between the two, the gate refuses before the
        // selection check is reached. That is an environment fact, not a pass.
        if field.observed == 0 {
            throw XCTSkip("entry gate refused before the selection check: \(String(describing: outcome))")
        }
        XCTAssertEqual(outcome, .refused(SelectionReplacementGuard.Refusal.reselectFailed.reason))
        XCTAssertEqual(kept, [result])
        XCTAssertEqual(field.selected, [NSRange(location: 5, length: 19)])
    }

    // MARK: - Refusal vocabulary

    func testEveryRefusalClassifiesUnderItsOwnKindAndKeepsItsSentence() {
        for refusal in SelectionReplacementGuard.Refusal.allCases {
            let classified = InjectRefusalKind.classify(refusal.reason, path: SelectionReplacementGuard.refusalPath)
            XCTAssertEqual(classified.kind, .selectionReplaceUnconfirmed)
            XCTAssertEqual(classified.sentence, refusal.reason)
            XCTAssertFalse(classified.kind.warrantsEngineRestart)
        }
        // Prose that is not the guard's own vocabulary never reaches the report verbatim.
        let foreign = InjectRefusalKind.classify("field said: secret text", path: SelectionReplacementGuard.refusalPath)
        XCTAssertEqual(foreign.sentence, SelectionReplacementGuard.Refusal.selectionChanged.reason)
    }
}
