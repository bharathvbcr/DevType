import XCTest
@testable import ExpanderEngine

/// §3.1d/§3.1e: two backspace-after-expansion hardenings, as pure policies.
///
/// **Delivery contamination** — a real key that passes through *while an expansion is being
/// delivered* reaches the field at an unknowable point around the paste. The undo record that
/// delivery writes rests on "the caret sits right after `injectedText`", so such a key must
/// poison that premise; before this predicate existed it was silently forgiven and the next
/// backspace blind-erased from a caret one unit left of where the record believed.
///
/// **Backspace return** — the tap swallows a real backspace to attempt an undo. A refused undo
/// that keeps the keystroke turns the user's delete into a dead keypress; the exit classifier
/// decides when the key must go back.
final class UndoBackspaceReinjectTests: XCTestCase {

    // MARK: - Which pass-through keys poison a blind undo

    func testNavigationKeysContaminate() {
        XCTAssertTrue(TextInjectionPipeline.deliveryPassThroughContaminatesBlindUndo(
            resetsCaret: true, isDelete: false, unicodeCount: 0
        ))
    }

    func testDeleteKeysContaminate() {
        XCTAssertTrue(TextInjectionPipeline.deliveryPassThroughContaminatesBlindUndo(
            resetsCaret: false, isDelete: true, unicodeCount: 0
        ))
    }

    func testTypedCharactersContaminate() {
        XCTAssertTrue(TextInjectionPipeline.deliveryPassThroughContaminatesBlindUndo(
            resetsCaret: false, isDelete: false, unicodeCount: 1
        ))
    }

    /// Lone F-keys / dead modifier chords produce no characters and move no caret — they must
    /// not cost the user their undo in AX-opaque hosts.
    func testInertKeysDoNotContaminate() {
        XCTAssertFalse(TextInjectionPipeline.deliveryPassThroughContaminatesBlindUndo(
            resetsCaret: false, isDelete: false, unicodeCount: 0
        ))
    }

    /// Fuzz: the predicate is a pure OR — any single truthy input contaminates, all-falsy does
    /// not, regardless of combination order.
    func testPredicateUnderFuzz() {
        var rng = SplitMix64(seed: 0xDE11F3)
        for _ in 0..<2000 {
            let resets = rng.next() % 2 == 0
            let delete = rng.next() % 2 == 0
            let unicode = Int(rng.next() % 4)   // includes 0
            let expected = resets || delete || unicode > 0
            XCTAssertEqual(
                TextInjectionPipeline.deliveryPassThroughContaminatesBlindUndo(
                    resetsCaret: resets, isDelete: delete, unicodeCount: unicode
                ),
                expected,
                "resets=\(resets) delete=\(delete) unicode=\(unicode)"
            )
        }
    }

    // MARK: - When a refused undo owes the swallowed backspace back

    private func heldKey(didSwallow: Bool) -> SwallowedKey {
        .init(didSwallow: didSwallow, unicode: "\u{7F}", keyCode: 51, flags: [])
    }

    func testAcceptedUndoReturnsNothing() {
        XCTAssertEqual(
            TextInjectionPipeline.classifyUndoExit(accepted: true, heldBackspace: heldKey(didSwallow: true)),
            .accepted
        )
        XCTAssertEqual(
            TextInjectionPipeline.classifyUndoExit(accepted: true, heldBackspace: nil),
            .accepted,
            "An accepted undo owes nothing even without a held key."
        )
    }

    func testRefusedUndoReturnsAHeldBackspace() {
        XCTAssertEqual(
            TextInjectionPipeline.classifyUndoExit(accepted: false, heldBackspace: heldKey(didSwallow: true)),
            .refusedWithBackspaceReturned,
            "The exact case that used to eat the user's keystroke."
        )
    }

    func testRefusedProgrammaticUndoHasNoKeyToReturn() {
        XCTAssertEqual(
            TextInjectionPipeline.classifyUndoExit(accepted: false, heldBackspace: nil),
            .refusedWithoutHeldKey
        )
    }

    /// A `SwallowedKey` with `didSwallow == false` means no key was actually eaten (explicit
    /// inject paths) — there is nothing to give back.
    func testUnswallowedPayloadIsNotReturned() {
        XCTAssertEqual(
            TextInjectionPipeline.classifyUndoExit(accepted: false, heldBackspace: heldKey(didSwallow: false)),
            .refusedWithoutHeldKey
        )
    }
}
