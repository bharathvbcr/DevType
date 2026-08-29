import XCTest
@testable import ExpanderEngine

/// Property-based harness that drives `VoiceTranscriptReconciler` with a simulated
/// `SFSpeechRecognizer` — randomised partials, endpoint finalizations that re-case and
/// re-punctuate, dropped fillers, and adversarially unrelated output — while applying every
/// emitted edit to a modeled document.
///
/// The document model is the ground truth: `eraseCount` backspaces followed by typing
/// `textToInject`. If the reconciler ever over-erases, the model shows text loss that the
/// reconciler's own bookkeeping would hide.
final class VoiceReconcilerFuzzTests: XCTestCase {

    /// Applies an edit exactly as the injector would: delete from the end, then append.
    private func apply(_ edit: VoiceReconciledEdit, to document: String) -> String {
        var text = document
        XCTAssertLessThanOrEqual(
            edit.eraseCount, text.count,
            "Erase of \(edit.eraseCount) exceeds the document (\(text.count)) — pre-existing text would be destroyed"
        )
        text.removeLast(min(edit.eraseCount, text.count))
        return text + edit.textToInject
    }

    private let words = [
        "roadmap", "deploy", "parser", "latency", "budget", "review", "shipping",
        "kernel", "buffer", "session", "transcript", "endpoint", "cache", "token"
    ]

    // MARK: - F1. The document never loses committed text, under any recognizer behaviour

    func testCommittedPrefixIsNeverDestroyedUnderFuzz() {
        for seed in UInt64(1)...200 {
            var rng = SplitMix64(seed: seed)
            let reconciler = VoiceTranscriptReconciler()

            // The user's pre-existing document content. Dictation must never touch it.
            let preexisting = "PRE-EXISTING DOCUMENT TEXT. "
            var document = preexisting
            var committedSegments: [String] = []
            var sealedText = ""   // everything behind the commit barrier so far

            let utteranceCount = Int(rng.next() % 6) + 2

            for _ in 0..<utteranceCount {
                let wordCount = Int(rng.next() % 6) + 2
                var spoken: [String] = []

                // Streaming partials: the recognizer grows the utterance word by word.
                for _ in 0..<wordCount {
                    spoken.append(words[Int(rng.next() % UInt64(words.count))])
                    let partial = spoken.joined(separator: " ")
                    let cumulative = VoiceTranscriptReconciler.combineUtterances(
                        committed: committedSegments,
                        activePartial: partial
                    )
                    document = apply(reconciler.reconcile(target: cumulative), to: document)
                    XCTAssertTrue(
                        document.hasPrefix(preexisting + sealedText),
                        "seed \(seed): a live partial erased text behind the commit barrier"
                    )
                }

                // Endpoint: the recognizer re-cases and re-punctuates the whole utterance,
                // and sometimes drops a leading filler — the exact shape that used to wipe
                // the session.
                var finalized = spoken.joined(separator: " ")
                if rng.next() % 2 == 0 {
                    finalized = finalized.prefix(1).uppercased() + finalized.dropFirst()
                }
                if rng.next() % 2 == 0 { finalized += "." }
                if rng.next() % 3 == 0 { finalized = finalized.replacingOccurrences(of: " ", with: ", ") }

                let finalCumulative = VoiceTranscriptReconciler.combineUtterances(
                    committed: committedSegments,
                    activePartial: finalized
                )
                document = apply(reconciler.reconcile(target: finalCumulative), to: document)
                reconciler.commitBoundary(finalizedText: reconciler.ownedText)
                committedSegments.append(finalized)

                sealedText = reconciler.committedText
                XCTAssertTrue(
                    document.hasPrefix(preexisting + sealedText),
                    "seed \(seed): endpoint finalization destroyed committed text"
                )
                XCTAssertEqual(
                    document, preexisting + reconciler.ownedText,
                    "seed \(seed): reconciler bookkeeping drifted from the real document"
                )
            }
        }
    }

    // MARK: - F2. Adversarial garbage from the recognizer is never replayed destructively

    func testUnrelatedRecognizerOutputCannotEraseCommittedText() {
        var rng = SplitMix64(seed: 0xDEAD_BEEF)
        let reconciler = VoiceTranscriptReconciler()

        let firstUtterance = "This sentence is finalized and must survive."
        var document = apply(reconciler.reconcile(target: firstUtterance), to: "")
        reconciler.commitBoundary()

        for _ in 0..<500 {
            let length = Int(rng.next() % 40)
            let garbage = String((0..<length).map { _ in
                Character(UnicodeScalar(UInt8(65 + rng.next() % 58)))
            })
            let edit = reconciler.reconcile(target: garbage)
            document = apply(edit, to: document)

            XCTAssertTrue(
                document.hasPrefix(firstUtterance),
                "Committed sentence was destroyed by unrelated recognizer output: \(document)"
            )
        }
    }

    // MARK: - F3. Erase budget fails closed instead of issuing a huge backspace run

    func testOversizedRewriteFailsClosed() {
        let reconciler = VoiceTranscriptReconciler(maxEraseBudget: 16)
        let long = String(repeating: "alpha beta ", count: 40)
        _ = reconciler.reconcile(target: long)

        let edit = reconciler.reconcile(target: "totally different content")

        XCTAssertTrue(edit.isNoop, "An oversized rewrite must be dropped, not backspaced")
        XCTAssertTrue(edit.suppressedCommittedRevision)
        XCTAssertEqual(reconciler.ownedText, long, "On-screen text must be left intact")
    }

    // MARK: - F4. Session ceiling degrades to append-only rather than mass-erasing

    func testSessionCeilingDegradesSafely() {
        let reconciler = VoiceTranscriptReconciler(maxOwnedLength: 64)
        let filler = String(repeating: "x", count: 64)
        _ = reconciler.reconcile(target: filler)

        let edit = reconciler.reconcile(target: "something else entirely")
        XCTAssertTrue(edit.isNoop)
        XCTAssertEqual(reconciler.ownedText, filler)
    }

    // MARK: - F5. commitBoundary never adopts text that contradicts the screen

    func testCommitBoundaryRejectsContradictoryFinalizedText() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "On screen text")
        reconciler.commitBoundary()

        // A finalized transcript that disagrees with committed text must not be adopted,
        // otherwise the reconciler's model would drift from the real document.
        reconciler.commitBoundary(finalizedText: "Completely different finalized text")

        XCTAssertEqual(reconciler.committedText, "On screen text")
    }

    // MARK: - F6. Concurrent reconcile calls keep the invariant

    func testConcurrentReconcileIsThreadSafe() {
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "Base committed text.")
        reconciler.commitBoundary()

        let group = DispatchGroup()
        for i in 0..<64 {
            DispatchQueue.global().async(group: group) {
                _ = reconciler.reconcile(target: "Base committed text. tail \(i)")
            }
        }
        group.wait()

        XCTAssertTrue(
            reconciler.ownedText.hasPrefix("Base committed text."),
            "Concurrent reconciliation corrupted the commit barrier: \(reconciler.ownedText)"
        )
    }
}
