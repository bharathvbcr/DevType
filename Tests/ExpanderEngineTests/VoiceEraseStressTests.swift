import XCTest
@testable import ExpanderEngine

/// Adversarial model of the whole dictation write path: a document with the user's own text in
/// it, a caret that moves without warning, and a recognizer that revises, endpoints, and
/// contradicts itself.
///
/// The earlier fuzz harness models the document as "erase from the end, then append", which
/// silently assumes the caret never moves — the one assumption the reported bug violated. Here
/// the caret is an explicit, hostile variable, and every erase is put through the *real*
/// `ErasePreconditionChecker` before it is allowed to touch the model.
///
/// Invariant under test: the user's pre-existing text is never altered, no matter what the
/// recognizer emits or where the caret goes.
final class VoiceEraseStressTests: XCTestCase {

    private let preexisting = "USER TEXT THAT MUST SURVIVE. "

    /// A document plus a caret, edited the way the injector really edits: delete `n` graphemes
    /// immediately *before the caret*, then insert at the caret.
    private struct Document {
        var text: String
        var caret: Int // in graphemes

        mutating func apply(erase: Int, insert: String) {
            let start = max(0, caret - erase)
            let lower = text.index(text.startIndex, offsetBy: start)
            let upper = text.index(text.startIndex, offsetBy: caret)
            text.replaceSubrange(lower..<upper, with: insert)
            caret = start + insert.count
        }
    }

    /// The gate exactly as the pipeline runs it for dictation: a verified plan, and no caret
    /// vouch. Returns true when the erase is allowed to proceed.
    private func gateAllows(erasedText: String?, document: Document) -> Bool {
        guard let erasedText, !erasedText.isEmpty else { return true }
        let plan = ErasePlan(text: erasedText)
        // Caret is tracked in graphemes; the checker speaks UTF-16.
        let utf16Caret = String(document.text.prefix(document.caret)).utf16.count
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: document.text,
            caretLocation: utf16Caret,
            selectionLength: 0,
            insertionPointFollowsExpectedText: false
        )
        return !result.blocksErase
    }

    /// Order-preserving containment: every character of `needle` appears in `haystack` in
    /// order. Insertions between them are allowed; a single deletion breaks it.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for wanted in needle {
            var found = false
            while let candidate = iterator.next() {
                if candidate == wanted { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    func testHostileCaretNeverCostsTheUserTheirOwnText() {
        let vocabulary = ["roadmap", "deploy", "parser", "café", "😀", "budget", "review", "ship"]

        for seed in UInt64(1)...400 {
            var rng = SplitMix64(seed: seed)
            let reconciler = VoiceTranscriptReconciler()
            var document = Document(text: preexisting, caret: preexisting.count)
            var spoken: [String] = []
            var refusals = 0
            var consecutiveRefusals = 0
            var worstRefusalStreak = 0

            for step in 0..<40 {
                // The recognizer revises, grows, and occasionally endpoints.
                if step % 11 == 10 {
                    reconciler.commitBoundary()
                    continue
                }
                if !spoken.isEmpty, Int.random(in: 0..<4, using: &rng) == 0 { spoken.removeLast() }
                spoken.append(vocabulary[Int.random(in: 0..<vocabulary.count, using: &rng)])

                let tailBefore = reconciler.volatileText
                let edit = reconciler.reconcile(target: spoken.joined(separator: " "))
                let tailAfter = reconciler.volatileText
                if edit.isNoop { continue }

                // The user (or the host) moves the caret between segments, sometimes into
                // their own text, sometimes to the very start.
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    document.caret = Int.random(in: 0...document.text.count, using: &rng)
                }

                if gateAllows(erasedText: edit.erasedText, document: document) {
                    document.apply(erase: edit.eraseCount, insert: edit.textToInject)
                    consecutiveRefusals = 0
                } else {
                    // Refused: the document is untouched, so the model is put back *and
                    // reseated*, exactly as the service does it.
                    refusals += 1
                    consecutiveRefusals += 1
                    worstRefusalStreak = max(worstRefusalStreak, consecutiveRefusals)
                    reconciler.revertVolatile(from: tailAfter, to: tailBefore)
                    reconciler.commitBoundary()
                }
            }

            // Claim A — the safety property: dictation may insert at a caret the user moved
            // (that is what typing does), but it must never *delete* what was already there.
            XCTAssertTrue(
                Self.isSubsequence(preexisting, of: document.text),
                "seed \(seed): the user's own text was destroyed after \(refusals) refusals — \(document.text.prefix(72).debugDescription)"
            )
            // Claim B — the liveness property: a moved caret must not kill the session. Once
            // the tail is sealed the next segment appends cleanly, so refusals cannot run away.
            XCTAssertLessThanOrEqual(
                worstRefusalStreak, 2,
                "seed \(seed): dictation stopped recovering — \(worstRefusalStreak) refusals in a row"
            )
        }
    }

    /// The same run with the *old* count-only plan, kept as a live regression witness: it proves
    /// the harness above can actually detect the failure it is asserting the absence of.
    func testTheHarnessDetectsTheUnverifiedEraseItWasBuiltToCatch() {
        var destroyed = false

        for seed in UInt64(1)...400 where !destroyed {
            var rng = SplitMix64(seed: seed)
            let reconciler = VoiceTranscriptReconciler()
            var document = Document(text: preexisting, caret: preexisting.count)
            var spoken: [String] = []

            for step in 0..<40 {
                if step % 11 == 10 {
                    reconciler.commitBoundary()
                    continue
                }
                if !spoken.isEmpty, Int.random(in: 0..<4, using: &rng) == 0 { spoken.removeLast() }
                spoken.append(["roadmap", "deploy", "parser", "budget"][Int.random(in: 0..<4, using: &rng)])

                let edit = reconciler.reconcile(target: spoken.joined(separator: " "))
                if edit.isNoop { continue }
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    document.caret = Int.random(in: 0...document.text.count, using: &rng)
                }
                // Count-only: `expectedText` is nil, the checker cannot verify, the erase runs.
                let plan = ErasePlan.counted(edit.eraseCount)
                let utf16Caret = String(document.text.prefix(document.caret)).utf16.count
                let result = ErasePreconditionChecker.evaluate(
                    plan: plan, value: document.text, caretLocation: utf16Caret,
                    selectionLength: 0, insertionPointFollowsExpectedText: false
                )
                XCTAssertFalse(result.blocksErase, "a count-only plan is unverifiable by construction")
                document.apply(erase: edit.eraseCount, insert: edit.textToInject)
            }
            if !Self.isSubsequence(preexisting, of: document.text) { destroyed = true }
        }

        XCTAssertTrue(
            destroyed,
            "The harness must be able to observe the bug — otherwise the test above proves nothing."
        )
    }

    /// A refusal storm: every single edit is refused. The model must stay exactly aligned with
    /// the untouched document, and recover in one correct edit once writes are allowed again.
    func testTotalRefusalLeavesTheModelAlignedAndRecoverable() {
        let reconciler = VoiceTranscriptReconciler()
        let phrases = ["one", "one two", "one two three", "one two", "one two three four"]

        for phrase in phrases {
            let before = reconciler.volatileText
            _ = reconciler.reconcile(target: phrase)
            let after = reconciler.volatileText
            reconciler.revertVolatile(from: after, to: before)
        }
        XCTAssertEqual(reconciler.ownedText, "", "Nothing was written, so nothing may be owned.")

        let recovery = reconciler.reconcile(target: "one two three four")
        XCTAssertEqual(recovery.eraseCount, 0, "Recovery must not erase text that was never typed.")
        XCTAssertEqual(recovery.textToInject, "one two three four")
    }

    /// Concurrency: reconcile and revert from many threads at once. The compare-and-swap must
    /// keep the tail coherent, and nothing may erase more than it owns.
    func testConcurrentReconcileAndRevertStayCoherent() {
        let reconciler = VoiceTranscriptReconciler()
        let iterations = 500
        let group = DispatchGroup()

        for worker in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<iterations {
                    let before = reconciler.volatileText
                    let edit = reconciler.reconcile(target: "worker \(worker) step \(i)")
                    XCTAssertLessThanOrEqual(
                        edit.eraseCount, max(before.count, reconciler.ownedText.count) + 64,
                        "an erase escaped the tail it is bounded by"
                    )
                    if let erased = edit.erasedText {
                        XCTAssertEqual(erased.count, edit.eraseCount)
                    }
                    if i % 3 == 0 {
                        reconciler.revertVolatile(from: reconciler.volatileText, to: before)
                    }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "deadlock or livelock")
        XCTAssertEqual(reconciler.committedText, "", "no commit boundary ran; nothing may be sealed")
    }
}
