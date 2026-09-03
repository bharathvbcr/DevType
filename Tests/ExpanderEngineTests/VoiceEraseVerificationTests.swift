import XCTest
@testable import ExpanderEngine

/// Voice dictation erases by posting backspaces at the caret. That is only safe while the
/// caret is still where dictation left it — and with pre-existing text in the field the user
/// is free to click somewhere else between two segments, seconds apart.
///
/// The app already owns the guard for this (`ErasePlan` + `ErasePreconditionChecker`: "the
/// trigger must actually be sitting left of the caret, a mismatch means our model of the field
/// is wrong, and erasing would eat the user's own text — refuse instead"). Dictation used to
/// pass a bare *count*, which sets `expectedText: nil` and makes the guard degrade to
/// "proceed best-effort" — no verification at all. These tests pin the wiring that closes it.
final class VoiceEraseVerificationTests: XCTestCase {

    // MARK: - The reconciler names the text it is about to destroy

    /// The invariant the `ErasePlan` rests on: `erasedText` is exactly the volatile suffix
    /// being dropped, so a plan built from it describes the real deletion in both unit systems.
    func testEveryEditNamesExactlyTheVolatileSuffixItErases() {
        for seed in UInt64(1)...200 {
            var rng = SplitMix64(seed: seed)
            let reconciler = VoiceTranscriptReconciler()
            var spoken: [String] = []

            for step in 0..<24 {
                if step % 7 == 6 {
                    reconciler.commitBoundary()
                    continue
                }
                // Revise the tail the way an endpointing recognizer does.
                if !spoken.isEmpty, Int.random(in: 0..<3, using: &rng) == 0 { spoken.removeLast() }
                spoken.append(["roadmap", "deploy", "parser", "😀", "café", "budget"].randomElement(using: &rng)!)

                let tailBefore = reconciler.volatileText
                let edit = reconciler.reconcile(target: spoken.joined(separator: " "))
                guard edit.eraseCount > 0 else { continue }

                guard let erased = edit.erasedText else {
                    return XCTFail("seed \(seed): an erase with no named text cannot be verified")
                }
                XCTAssertEqual(
                    erased.count, edit.eraseCount,
                    "seed \(seed): named text and erase count must describe the same deletion"
                )
                XCTAssertTrue(
                    tailBefore.hasSuffix(erased),
                    "seed \(seed): the erase must name a suffix of the volatile tail, not \(erased.debugDescription)"
                )
            }
        }
    }

    func testRollbackNamesEverythingItOwns() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "first utterance")
        reconciler.commitBoundary()
        _ = reconciler.reconcile(target: "first utterance second part")

        let owned = reconciler.ownedText
        let edit = reconciler.rollbackAll()
        XCTAssertEqual(edit.erasedText, owned)
        XCTAssertEqual(edit.eraseCount, owned.count)
    }

    // MARK: - A moved caret is refused instead of eating the user's text

    /// The reported shape: existing text in the field, voice typing on, and the caret no longer
    /// sitting after the dictated tail.
    func testMovedCaretRefusesTheEraseThatWouldDeleteExistingText() throws {
        // "Dear Bob, " was already in the field; dictation typed "hello world" after it.
        let document = "Dear Bob, hello world"
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "hello world")

        // The recognizer revises the last word: erase "world", type "there".
        let edit = reconciler.reconcile(target: "hello there")
        let erased = try XCTUnwrap(edit.erasedText)
        XCTAssertEqual(erased, "world")
        let verified = ErasePlan(text: erased)

        // Caret still at the end — ordinary dictation, and it must keep working.
        XCTAssertEqual(
            ErasePreconditionChecker.evaluate(
                plan: verified,
                value: document,
                caretLocation: document.utf16.count,
                selectionLength: 0,
                insertionPointFollowsExpectedText: false
            ),
            .ok,
            "Dictation with an untouched caret must not be refused."
        )

        // The user clicked back into their own text: the caret now sits after "Dear Bob,".
        let moved = ErasePreconditionChecker.evaluate(
            plan: verified,
            value: document,
            caretLocation: 9,
            selectionLength: 0,
            insertionPointFollowsExpectedText: false
        )
        XCTAssertTrue(
            moved.blocksErase,
            "Erasing 5 chars at caret 9 deletes the user's own \"Bob,\" — it must refuse. Got \(moved)."
        )

        // Why the count-only plan could not catch it: no expected text, no verification.
        let countOnly = ErasePreconditionChecker.evaluate(
            plan: .counted(erased.count),
            value: document,
            caretLocation: 9,
            selectionLength: 0,
            insertionPointFollowsExpectedText: false
        )
        XCTAssertFalse(
            countOnly.blocksErase,
            "Regression witness: a bare count cannot be verified, so the erase proceeded."
        )

        // And why dictation must not claim the caret vouch the expand path is entitled to:
        // the dictated word is still somewhere in the field, so a vouched check downgrades
        // the mismatch to best-effort and the backspaces run anyway.
        let vouched = ErasePreconditionChecker.evaluate(
            plan: verified,
            value: document,
            caretLocation: 9,
            selectionLength: 0,
            insertionPointFollowsExpectedText: true
        )
        XCTAssertFalse(
            vouched.blocksErase,
            "Regression witness: vouching for a caret dictation cannot vouch for reopens the hole."
        )
    }

    /// `ErasePlan.counted` reuses one number for both unit systems. A grapheme count fed in as
    /// a UTF-16 width under-selects on the AX replace path for anything outside the BMP —
    /// dictated emoji, in practice. Deriving the plan from the text keeps both counts honest.
    func testNamedEraseCarriesBothUnitSystemsForAstralText() throws {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "score 😀")
        let edit = reconciler.reconcile(target: "score")
        let erased = try XCTUnwrap(edit.erasedText)
        XCTAssertEqual(erased, " 😀")

        let verified = ErasePlan(text: erased)
        XCTAssertEqual(verified.backspaceCount, 2, "two backspaces: the space and the emoji")
        XCTAssertEqual(verified.utf16Count, 3, "the emoji is a surrogate pair — 3 UTF-16 units")

        let legacy = ErasePlan.counted(edit.eraseCount)
        XCTAssertEqual(legacy.utf16Count, 2, "regression witness: the count-only plan under-selects")
    }

    // MARK: - A refused edit must not desynchronise the model

    func testRevertVolatileIsCompareAndSwap() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "hello world")
        let before = reconciler.volatileText
        _ = reconciler.reconcile(target: "hello there")
        let after = reconciler.volatileText

        // A stale revert (some other tail is live now) must be refused, not applied.
        XCTAssertFalse(reconciler.revertVolatile(from: "something else", to: before))
        XCTAssertEqual(reconciler.volatileText, after)

        // The matching revert restores what the document still shows.
        XCTAssertTrue(reconciler.revertVolatile(from: after, to: before))
        XCTAssertEqual(reconciler.volatileText, before)

        // And the next diff is computed against the restored tail, so nothing compounds.
        let edit = reconciler.reconcile(target: "hello world again")
        XCTAssertEqual(edit.eraseCount, 0, "an append after a refused edit must not erase")
        XCTAssertEqual(edit.textToInject, " again")
    }

    // MARK: - The two policies, as policies

    /// Mutation testing caught this: the reseat used to be two statements in a closure inside a
    /// `@MainActor` singleton, where deleting half of it broke no test. As one operation on the
    /// reconciler it is directly testable — and the half that went missing is the half that
    /// keeps dictation alive after a refusal.
    func testRecoveryFromARefusedEditRestoresTheTailAndRetiresIt() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "hello world")
        let before = reconciler.volatileText
        _ = reconciler.reconcile(target: "hello there")
        let after = reconciler.volatileText

        reconciler.recoverFromRefusedEdit(expected: after, previous: before)

        // Restored: the document still shows the old tail, and so does the model.
        XCTAssertEqual(reconciler.ownedText, "hello world")
        // Retired: the tail is behind the barrier, so the next edit cannot try to erase it
        // again — which is what turned one refusal into a dead session.
        XCTAssertEqual(reconciler.volatileText, "")
        XCTAssertEqual(reconciler.committedText, "hello world")

        let next = reconciler.reconcile(target: "hello world and then some")
        XCTAssertEqual(next.eraseCount, 0, "Recovery must leave the next segment a pure append.")
        XCTAssertEqual(next.textToInject, " and then some")
    }

    /// A stale recovery (newer segments already reconciled) must not clobber them, and must not
    /// seal a boundary on state it did not restore.
    func testRecoveryIsIgnoredWhenTheTailHasMovedOn() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "first")
        _ = reconciler.reconcile(target: "first second")

        reconciler.recoverFromRefusedEdit(expected: "something stale", previous: "first")
        XCTAssertEqual(
            reconciler.ownedText, "first second",
            "A recovery for a tail that is no longer live must change nothing."
        )
    }

    /// The lease gate as a pure rule. It refuses only on a *positive* mismatch: an unclaimed
    /// lease or an unknown frontmost app is not evidence the user switched away, and treating
    /// it as such would withhold dictation from the very session that owns the field.
    func testLiveSegmentWithholdingIsAPositiveMismatchOnly() {
        typealias S = VoiceInsertionService
        // The mismatch that matters: the user switched apps mid-dictation.
        XCTAssertTrue(S.shouldWithholdLiveSegment(leasePID: 501, frontmostPID: 902))
        // Same app — the ordinary case, and it must never be withheld.
        XCTAssertFalse(S.shouldWithholdLiveSegment(leasePID: 501, frontmostPID: 501))
        // No claim, or nothing known: proceed rather than silently swallow the session.
        XCTAssertFalse(S.shouldWithholdLiveSegment(leasePID: nil, frontmostPID: 902))
        XCTAssertFalse(S.shouldWithholdLiveSegment(leasePID: 0, frontmostPID: 902))
        XCTAssertFalse(S.shouldWithholdLiveSegment(leasePID: 501, frontmostPID: nil))
        XCTAssertFalse(S.shouldWithholdLiveSegment(leasePID: nil, frontmostPID: nil))
    }

    // MARK: - The wiring itself

    /// `deliver` has always refused to type into an app that is no longer the dictation
    /// target. Live typing had no such gate, so a segment arriving after an app switch
    /// revised whatever now had focus — erasing text this session never wrote.
    func testLiveTypingRefusesToWriteOutsideTheDictationTarget() throws {
        let service = try Self.voiceInsertionSource()
        let apply = try XCTUnwrap(service.range(of: "public func applyLiveSegment("))
        let end = try XCTUnwrap(service.range(of: "// MARK: - Final delivery"))
        let body = String(service[apply.lowerBound..<end.lowerBound])

        let gate = try XCTUnwrap(
            body.range(of: "Self.shouldWithholdLiveSegment("),
            "Live typing must consult the lease rule before writing"
        )
        let reconcile = try XCTUnwrap(body.range(of: "reconciler.reconcile("))
        XCTAssertLessThan(
            gate.lowerBound, reconcile.lowerBound,
            "The lease must be checked before the reconciler is advanced, or a withheld "
                + "segment still desynchronises the model from the document"
        )
        XCTAssertTrue(
            service.contains("public func beginSession(targetLease: TargetLease? = nil)"),
            "The session must hand its lease to the delivery layer for the gate to work"
        )
        // The rule is fed the *live* frontmost pid, not a value captured at session start —
        // otherwise it compares the target against itself and can never fire.
        XCTAssertTrue(
            body.contains("frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier"),
            "The gate must sample the frontmost app at the moment the segment arrives"
        )
    }

    private static func voiceInsertionSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ExpanderEngine/Voice/Delivery/VoiceInsertionService.swift"),
            encoding: .utf8
        )
    }

    func testDictationSendsAVerifiedPlanAndDoesNotVouchForTheCaret() throws {
        let service = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ExpanderEngine/Voice/Delivery/VoiceInsertionService.swift"),
            encoding: .utf8
        )
        let inject = try XCTUnwrap(service.range(of: "private func inject("))
        let body = String(service[inject.lowerBound...])
        XCTAssertTrue(
            body.contains("edit.erasedText.map { ErasePlan(text: $0) }"),
            "Dictation must build a verifiable plan from the text it named, not a bare count"
        )
        XCTAssertTrue(
            body.contains("eraseCaretVouched: false"),
            "Dictation cannot promise the caret is still after its tail — segments arrive seconds apart"
        )
        XCTAssertTrue(
            body.contains("case .refused"),
            "A refused edit must be observed, or the reconciler's model silently diverges"
        )
        XCTAssertTrue(
            service.contains("reconciler.recoverFromRefusedEdit("),
            "The refusal repair must go through the one operation that cannot be half-applied"
        )
        XCTAssertTrue(
            service.contains("Self.shouldWithholdLiveSegment("),
            "The lease gate must go through the pure rule, so neutering it fails a test"
        )
    }
}
