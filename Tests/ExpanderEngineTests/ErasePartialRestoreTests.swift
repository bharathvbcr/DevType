import XCTest
@testable import ExpanderEngine

/// A backspace burst that stops part-way (a continue-check fails between two pairs) leaves the
/// head of the trigger in the field: `tri` + swallowed `g` became `tr`, and replaying the
/// swallowed key then produced `trg` — neither the trigger the user typed nor the expansion.
/// What was removed is exactly known (the last N graphemes of the plan, N = pairs authorized), so
/// it can be put back before the key is replayed.
final class ErasePartialRestoreTests: XCTestCase {

    func testTheErasedTailIsTheLastPostedGraphemesOfThePlan() {
        let plan = ErasePlan(text: "trig")
        XCTAssertEqual(plan.erasedTail(graphemes: 1)?.expectedText, "g")
        XCTAssertEqual(plan.erasedTail(graphemes: 2)?.expectedText, "ig")
        XCTAssertEqual(plan.erasedTail(graphemes: 4)?.expectedText, "trig")
    }

    func testTheTailCarriesConsistentCountsInBothUnitSystems() {
        let tail = ErasePlan(text: "a😀é").erasedTail(graphemes: 2)
        XCTAssertEqual(tail?.expectedText, "😀é")
        XCTAssertEqual(tail?.backspaceCount, 2)
        XCTAssertEqual(tail?.utf16Count, "😀é".utf16.count)
        XCTAssertNil(tail?.validationFailure)
    }

    func testACombiningSequenceIsRestoredWholeNotSplit() {
        // One backspace removes the whole grapheme, so one posted pair restores the whole thing.
        let plan = ErasePlan(text: "ae\u{0301}")
        XCTAssertEqual(plan.erasedTail(graphemes: 1)?.expectedText, "e\u{0301}")
    }

    func testMoreThanThePlanIsClampedToThePlan() {
        XCTAssertEqual(ErasePlan(text: "trig").erasedTail(graphemes: 99)?.expectedText, "trig")
    }

    func testNothingPostedOrNothingKnownRestoresNothing() {
        XCTAssertNil(ErasePlan(text: "trig").erasedTail(graphemes: 0))
        XCTAssertNil(ErasePlan(text: "trig").erasedTail(graphemes: -3))
        XCTAssertNil(ErasePlan.counted(4).erasedTail(graphemes: 2), "a count-only plan has no text to restore")
        XCTAssertNil(ErasePlan.empty.erasedTail(graphemes: 2))
    }

    func testCaseSensitivityIsCarriedSoTheRestoredTextIsWhatTheUserTyped() {
        XCTAssertEqual(ErasePlan(text: "TrIg", caseInsensitive: true).erasedTail(graphemes: 2)?.expectedText, "Ig")
    }

    // MARK: - Kept head

    func testTheKeptHeadIsWhatThePostedCountShouldHaveLeft() {
        let plan = ErasePlan(text: "trig")
        XCTAssertEqual(plan.keptHead(graphemes: 1)?.expectedText, "tri")
        XCTAssertEqual(plan.keptHead(graphemes: 3)?.expectedText, "t")
        XCTAssertEqual(ErasePlan(text: "a😀é").keptHead(graphemes: 2)?.expectedText, "a")
        XCTAssertEqual(ErasePlan(text: "TrIg", caseInsensitive: true).keptHead(graphemes: 2)?.caseInsensitive, true)
    }

    func testNoHeadIsClaimedWhereNoReadingCouldConfirmIt() {
        // A count that covers the whole plan leaves nothing to read back — and is exactly the count
        // an authorized-but-never-created last pair produces, with one character still in the field.
        XCTAssertNil(ErasePlan(text: "trig").keptHead(graphemes: 4))
        XCTAssertNil(ErasePlan(text: "trig").keptHead(graphemes: 9))
        XCTAssertNil(ErasePlan(text: "trig").keptHead(graphemes: 0))
        XCTAssertNil(ErasePlan.counted(4).keptHead(graphemes: 2))
    }

    func testAnOverstatedCountIsCaughtByTheHeadCheck() throws {
        // Two pairs authorized, one posted: the field holds `tri`, the count says `tr`. `tri` does
        // not end in `tr`, so the check does not answer `.ok` (it downgrades to `.unavailable` for
        // text past the expected run, which the erase path treats as best-effort) — and the restore
        // is admitted only on `.ok`, so the `ig` that would have produced `triig` never goes in.
        let head = try XCTUnwrap(ErasePlan(text: "trig").keptHead(graphemes: 2))
        let overstated = ErasePreconditionChecker.evaluate(
            plan: head, value: "hello tri", caretLocation: 9, selectionLength: 0
        )
        XCTAssertNotEqual(overstated, .ok)
        let unreadable = ErasePreconditionChecker.evaluate(
            plan: head, value: nil, caretLocation: nil, selectionLength: nil
        )
        XCTAssertNotEqual(unreadable, .ok, "An unreadable field must not admit a restore")
        let exact = ErasePreconditionChecker.evaluate(
            plan: head, value: "hello tr", caretLocation: 8, selectionLength: 0
        )
        XCTAssertEqual(exact, .ok)
    }

    // MARK: - Exact comparison against the pre-erase field

    private func picture(_ value: String?, caret: Int? = nil) -> EraseContinuation.EraseFieldPicture {
        EraseContinuation.EraseFieldPicture(
            value: value, caretLocation: caret ?? value?.utf16.count, selectionLength: 0,
            frame: CGRect(x: 10, y: 20, width: 200, height: 22)
        )
    }

    /// The suffix check cannot tell how many graphemes are gone when the head repeats them: `aaa`
    /// with two pairs authorized and one posted leaves `xaa`, which ends in the claimed head `a`.
    func testTheHeadSuffixCheckAloneAdmitsARepeatedHeadWithAnOverstatedCount() throws {
        let head = try XCTUnwrap(ErasePlan(text: "aaa").keptHead(graphemes: 2))
        XCTAssertEqual(
            ErasePreconditionChecker.evaluate(plan: head, value: "xaa", caretLocation: 3, selectionLength: 0),
            .ok,
            "the characterization: this is the hole the exact comparison closes"
        )
    }

    func testTheExactComparisonRefusesAnOverstatedCountThatARepeatedHeadHides() {
        let before = picture("xaaa")
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: before, live: picture("xaa"), expectedText: "aaa", caseInsensitive: false, posted: 2
        ), "two authorized, one landed: restoring the tail would add a character the user never typed")
        XCTAssertTrue(EraseContinuation.partialEraseLanded(
            anchor: before, live: picture("xaa"), expectedText: "aaa", caseInsensitive: false, posted: 1
        ))
        XCTAssertTrue(EraseContinuation.partialEraseLanded(
            anchor: before, live: picture("xa"), expectedText: "aaa", caseInsensitive: false, posted: 2
        ))
        let semicolons = picture("see;;x")
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: semicolons, live: picture("see;;"), expectedText: ";;x", caseInsensitive: false, posted: 2
        ))
        XCTAssertTrue(EraseContinuation.partialEraseLanded(
            anchor: semicolons, live: picture("see;;"), expectedText: ";;x", caseInsensitive: false, posted: 1
        ))
    }

    func testNoPreEraseReadingOrNoLiveReadingMeansNoRestore() {
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: nil, live: picture("xa"), expectedText: "aaa", caseInsensitive: false, posted: 2
        ), "without a picture of the field before the erase there is nothing to compare against")
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: picture("xaaa"), live: nil, expectedText: "aaa", caseInsensitive: false, posted: 2
        ))
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: picture("xaaa"), live: picture(nil), expectedText: "aaa", caseInsensitive: false, posted: 2
        ), "an unreadable field is not evidence of how much landed")
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: picture("xaaa"), live: picture("xa"), expectedText: "aaa", caseInsensitive: false, posted: 0
        ))
    }

    func testAFieldThatIsNotTheOneTheEraseStartedInIsNotRestored() {
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: picture("xaaa"), live: picture("another field"), expectedText: "aaa",
            caseInsensitive: false, posted: 2
        ))
    }

    // MARK: - A mirror one key behind the backspaces

    /// The exact comparison is stricter than the old suffix check, so a readable host whose value
    /// lags the keys by one now reads as "not landed" on the first look. That is not a verdict: the
    /// same field read after the mirror settles is. These pin the pair of readings.
    func testAFieldOneKeyBehindIsReadAgainAndThenRestored() {
        let before = picture("xaaa")
        let lagging = picture("xaa")
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: before, live: lagging, expectedText: "aaa", caseInsensitive: false, posted: 2
        ), "the first look: two keys posted, the mirror shows one")
        XCTAssertTrue(EraseContinuation.partialEraseMayLag(
            anchor: before, live: lagging, expectedText: "aaa", caseInsensitive: false, posted: 2
        ))
        XCTAssertTrue(EraseContinuation.partialEraseLanded(
            anchor: before, live: picture("xa"), expectedText: "aaa", caseInsensitive: false, posted: 2
        ), "the second look, after the mirror caught up")
    }

    /// An overstated count (an authorized pair whose key never existed) looks exactly like a lagging
    /// mirror on the first reading and never changes on the second, so it is never restored.
    func testAnOverstatedCountStaysRefusedAfterTheSecondLook() {
        let before = picture("xaaa")
        let stuck = picture("xaa")
        XCTAssertTrue(EraseContinuation.partialEraseMayLag(
            anchor: before, live: stuck, expectedText: "aaa", caseInsensitive: false, posted: 2
        ))
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: before, live: stuck, expectedText: "aaa", caseInsensitive: false, posted: 2
        ))
    }

    func testOnlyAFieldThatVerifiablyShowsPartOfTheDeletionEarnsTheSecondLook() {
        let before = picture("xaaa")
        func mayLag(_ anchor: EraseContinuation.EraseFieldPicture?, _ live: EraseContinuation.EraseFieldPicture?,
                    posted: Int = 2) -> Bool {
            EraseContinuation.partialEraseMayLag(
                anchor: anchor, live: live, expectedText: "aaa", caseInsensitive: false, posted: posted
            )
        }
        XCTAssertTrue(mayLag(before, picture("xaaa")), "no key visible yet is the extreme of a lagging mirror")
        XCTAssertFalse(mayLag(before, picture("xa")), "already exactly the posted count: nothing to wait for")
        XCTAssertFalse(mayLag(before, picture("another field")), "not the field the erase started in")
        XCTAssertFalse(mayLag(before, picture(nil)), "an unreadable field is not evidence of progress")
        XCTAssertFalse(mayLag(nil, picture("xaa")), "no pre-erase picture to compare against")
        XCTAssertFalse(mayLag(before, nil))
        XCTAssertFalse(mayLag(before, picture("xaa"), posted: 0))
        XCTAssertFalse(mayLag(before, picture("x")), "more gone than was posted is not a lagging mirror")
    }

    // MARK: - The pipeline
    //
    // A burst that stops part-way, run through the pipeline: Post Events drops for one pair after
    // the second backspace and is back before the burst reports. The swallowed key is a space the
    // tap ate; the refusal that follows owes it back, and owes it *after* the trigger is whole.

    private let space = SwallowedKey(didSwallow: true, unicode: " ", keyCode: 49)

    private func stopAfterTwoBackspaces(_ harness: InjectionHarness) {
        harness.onBackspace = { harness, index in
            guard index == 2 else { return }
            harness.canPostEvents = false
            DispatchQueue.main.async { harness.canPostEvents = true }
        }
    }

    private func isPaste(_ event: InjectionHarness.Event) -> Bool {
        if case .paste = event { return true }
        return false
    }

    func testAnIncompleteEraseRestoresTheTailBeforeTheKeyIsReplayed() throws {
        let harness = try InjectionHarness()
        stopAfterTwoBackspaces(harness)
        let run = harness.typeExpansion(in: self, swallowed: space)

        guard case .refused = run.outcome else { return XCTFail("expected a refusal: \(harness.timeline)") }
        XCTAssertEqual(run.text, "say: `slm", "the two erased graphemes are back: the trigger the user typed")
        let order = harness.order
        let restore = try XCTUnwrap(order.firstIndex(where: isPaste), "the tail was pasted back: \(order)")
        let replay = try XCTUnwrap(order.firstIndex(of: .key(49)), "the swallowed key was replayed: \(order)")
        XCTAssertEqual(order.filter { $0 == .backspace }.count, 2)
        XCTAssertLessThan(restore, replay, "restore first, then the refusal replays the key: \(order)")
        XCTAssertEqual(order.filter(isPaste).count, 1, "one restore, not a second")
    }

    /// The restore goes into a field the continue-check still vouches for and nowhere else: if the
    /// user has moved on, nothing is pasted and the key is not replayed into the new place.
    func testNoRestoreIsPastedIntoAFieldTheContinueCheckNoLongerVouchesFor() throws {
        let harness = try InjectionHarness()
        harness.page.values[harness.page.key(harness.elsewhere)] = "an unrelated field"
        harness.page.selections[harness.page.key(harness.elsewhere)] = NSRange(location: 18, length: 0)
        harness.onBackspace = { harness, index in
            guard index == 2 else { return }
            harness.canPostEvents = false
            harness.page.focused = harness.elsewhere
            DispatchQueue.main.async { harness.canPostEvents = true }
        }
        let run = harness.typeExpansion(in: self, swallowed: space)

        guard case .refused = run.outcome else { return XCTFail("expected a refusal: \(harness.timeline)") }
        XCTAssertEqual(harness.order.filter(isPaste).count, 0, "nothing was pasted into a field the user left")
        XCTAssertFalse(harness.order.contains(.key(49)), "and the key was not typed into it either")
        XCTAssertEqual(run.text, "say: `s", "what the posted backspaces left is what is left")
        XCTAssertEqual(harness.page.value(of: harness.elsewhere), "an unrelated field")
    }

    /// Two pairs were authorized but the host only acted on one: the field holds more of the
    /// trigger than the count implies, so restoring the tail would write text the user never typed.
    func testAnOverstatedCountIsNeverRestoredOver() throws {
        let harness = try InjectionHarness()
        harness.hostDropsBackspaces = 1
        stopAfterTwoBackspaces(harness)
        let run = harness.typeExpansion(in: self, swallowed: space)

        guard case .refused = run.outcome else { return XCTFail("expected a refusal: \(harness.timeline)") }
        XCTAssertEqual(run.text, "say: `sl", "one grapheme went, and nothing was added to a count that overstated it")
        XCTAssertEqual(harness.order.filter(isPaste).count, 0)
    }

    /// The head check is a suffix check and cannot see how many graphemes of a repeating head are
    /// gone: with `aaa` and two pairs authorized but one acted on, the field `xaa` still ends in
    /// the head the count implies. Only comparing the whole field with the pre-erase one refuses it.
    func testARepeatedHeadWithAnOverstatedCountIsNeverRestoredOver() throws {
        let harness = try InjectionHarness()
        harness.hostDropsBackspaces = 1
        stopAfterTwoBackspaces(harness)
        let run = harness.typeExpansion(in: self, trigger: "aaa", lead: "x", swallowed: space)

        guard case .refused = run.outcome else { return XCTFail("expected a refusal: \(harness.timeline)") }
        XCTAssertEqual(run.text, "xaa", "no character the user never typed was added")
        XCTAssertEqual(harness.order.filter(isPaste).count, 0)
    }

    /// A host whose field lags the backspaces by one key reads as "not landed" on the first look and
    /// exactly right after it settles. The restore takes one second look, a settle later, and then
    /// puts the tail back — the trigger the user typed, whole, before the swallowed key.
    func testAFieldThatCatchesUpWithinTheSettleIsRestoredAfterTheSecondLook() throws {
        let harness = try InjectionHarness()
        harness.hostDropsBackspaces = 1
        harness.onBackspace = { harness, index in
            guard index == 2 else { return }
            harness.canPostEvents = false
            DispatchQueue.main.async { harness.canPostEvents = true }
            // The dropped key lands late: after the first look (the burst's own settle, two keys plus
            // the trailing delay) and before the second (one `settleDelay` after that). Main-queue
            // timers fire in deadline order, so the catch-up sits between the looks however late
            // the run loop runs.
            let firstLook = 2 * InjectTiming.backspacePerKeyDelay + InjectTiming.backspaceTrailingDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + firstLook + AXSettleRetry.settleDelay / 2) {
                harness.page.deleteBackward(in: harness.field)
            }
        }
        let run = harness.typeExpansion(in: self, swallowed: space)

        guard case .refused = run.outcome else { return XCTFail("expected a refusal: \(harness.timeline)") }
        XCTAssertEqual(run.text, "say: `slm", "the trigger is whole again once the late key landed and was restored")
        XCTAssertEqual(harness.order.filter(isPaste).count, 1, "one restore, after one second look")
        let order = harness.order
        let restore = try XCTUnwrap(order.firstIndex(where: isPaste))
        let replay = try XCTUnwrap(order.firstIndex(of: .key(49)), "the swallowed key was replayed: \(order)")
        XCTAssertLessThan(restore, replay)
    }

    /// A key typed while the second look waits is a hard stop: the field is the user's again, so
    /// nothing is restored into it — even though the field, read again, shows exactly the head.
    func testInputDuringTheSecondLookStopsTheRestore() throws {
        let harness = try InjectionHarness()
        harness.hostDropsBackspaces = 1
        harness.onBackspace = { harness, index in
            guard index == 2 else { return }
            harness.canPostEvents = false
            DispatchQueue.main.async { harness.canPostEvents = true }
            // Between the two looks (see the test above): the late key lands, and the user types.
            let firstLook = 2 * InjectTiming.backspacePerKeyDelay + InjectTiming.backspaceTrailingDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + firstLook + AXSettleRetry.settleDelay / 2) {
                harness.page.deleteBackward(in: harness.field)
                harness.pipeline.noteDeliveryInput(units: 1)
            }
        }
        let run = harness.typeExpansion(in: self, swallowed: space)

        guard case .refused = run.outcome else { return XCTFail("expected a refusal: \(harness.timeline)") }
        XCTAssertEqual(harness.order.filter(isPaste).count, 0, "no restore into a field the user typed in")
    }
}
