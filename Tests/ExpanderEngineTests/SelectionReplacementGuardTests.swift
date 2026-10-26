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

    // MARK: - decide: what a host can do to the text between capture and replace

    /// The host answered `kAXSelectedText` with an empty string and nothing else: no value, no
    /// range. That is the shape of "not published yet", the one `Confirmer.fillingSelection` sends
    /// to the ladder as blank. `decide` used to read the empty string as a *readable* selection
    /// that was not the original and refused at once, which is why a host mid-restore skipped the
    /// settle entirely.
    func testEmptySelectedTextWithNothingElseIsUnverifiableNotAMismatch() {
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: original,
                observation: observation(value: nil, selectedText: "", range: nil)
            ),
            .unverifiable
        )
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: original,
                observation: observation(value: "", selectedText: "", range: nil)
            ),
            .unverifiable
        )
    }

    /// A readable selection that is not the original is still a known mismatch, with or without
    /// a field to search: the host is saying something else is selected.
    func testNonEmptyForeignSelectionWithoutAFieldStillRefuses() {
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: original,
                observation: observation(value: nil, selectedText: "something else", range: nil)
            ),
            .refuse(.selectionChanged)
        )
    }

    /// `String ==` is canonical equivalence, so a host that hands back the selection decomposed
    /// already proceeds; the search for the original has to agree with it. Pre-fix the search was
    /// `.literal` and found nothing in a decomposed field, refusing a selection it could re-make.
    func testReselectFindsACanonicallyEquivalentOriginal() {
        let nfc = "caf\u{E9} au lait"
        let nfd = "cafe\u{301} au lait"
        XCTAssertNotEqual(nfc.utf16.count, nfd.utf16.count)
        let field = "say: \(nfd)"
        let decision = SelectionReplacementGuard.decide(
            original: nfc,
            observation: observation(value: field, selectedText: "", range: NSRange(location: 0, length: 0))
        )
        XCTAssertEqual(decision, .reselect(NSRange(location: 5, length: nfd.utf16.count)))

        let reverse = SelectionReplacementGuard.decide(
            original: nfd,
            observation: observation(value: "say: \(nfc)", selectedText: "", range: NSRange(location: 0, length: 0))
        )
        XCTAssertEqual(reverse, .reselect(NSRange(location: 5, length: nfc.utf16.count)))

        // And the live selection compared as text, in either normalisation, still proceeds.
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: nfc,
                observation: observation(value: field, selectedText: nfd, range: NSRange(location: 5, length: nfd.utf16.count))
            ),
            .proceed
        )
    }

    /// Canonical equivalence is the only fold the search accepts. A host-inserted zero-width
    /// character, a different quote, a different line ending, a no-break space or a trailing
    /// newline each make a different selection: pasting over it would consume characters the user
    /// never selected, which is the same family of corruption this guard exists to stop. A
    /// refusal costs a manual paste; a wrong replace costs the user's text.
    func testSearchDoesNotFoldAnythingButCanonicalEquivalence() {
        let cases: [(original: String, hostText: String, label: String)] = [
            ("ab", "x a\u{200B}b y", "zero-width"),
            ("don't stop", "x don\u{2019}t stop y", "smart quote"),
            ("one\ntwo", "x one\r\ntwo y", "CRLF"),
            ("one two", "x one\u{A0}two y", "no-break space"),
            ("Cafe", "x cafe y", "case"),
        ]
        for item in cases {
            XCTAssertEqual(
                SelectionReplacementGuard.decide(
                    original: item.original,
                    observation: observation(
                        value: item.hostText, selectedText: "", range: NSRange(location: 0, length: 0)
                    )
                ),
                .refuse(.originalNotFound),
                item.label
            )
            // With no field to search, the host's own selection text is compared the same way.
            XCTAssertEqual(
                SelectionReplacementGuard.decide(
                    original: item.original,
                    observation: observation(value: nil, selectedText: item.hostText, range: nil)
                ),
                .refuse(.selectionChanged),
                item.label
            )
        }
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: original,
                observation: observation(value: nil, selectedText: original + "\n", range: nil)
            ),
            .refuse(.selectionChanged),
            "trailing newline the host added"
        )
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: original + "\n",
                observation: observation(value: nil, selectedText: original, range: nil)
            ),
            .refuse(.selectionChanged),
            "trailing newline the host trimmed"
        )
    }

    /// Ranges are UTF-16 units. A selection that follows an astral character is sliced in those
    /// units and still proceeds; a range that lands inside a surrogate pair is garbage and must
    /// not be mistaken for the original.
    func testSurrogatePairsInTheRangeAreSlicedInUTF16Units() {
        let field = "\u{1F44B} \(original)"
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: original,
                observation: observation(value: field, selectedText: nil, range: NSRange(location: 3, length: 19))
            ),
            .proceed
        )
        let split = SelectionReplacementGuard.decide(
            original: "\u{1F44B} x",
            observation: observation(value: "\u{1F44B} x", selectedText: nil, range: NSRange(location: 1, length: 3))
        )
        XCTAssertNotEqual(split, .proceed)
    }

    /// The scan is capped at `maxOccurrences`, and the caret edge was looked for only inside that
    /// capped list. On a long field the occurrence the caret sits against can be past the cap, so
    /// the guard refused as ambiguous a selection the caret identifies exactly.
    func testCaretEdgeIsFoundPastTheOccurrenceCap() {
        let unit = "ok, "
        let count = SelectionReplacementGuard.maxOccurrences * 3
        let field = String(repeating: unit, count: count)
        let target = count - 5
        let end = target * unit.utf16.count + 2
        let decision = SelectionReplacementGuard.decide(
            original: "ok",
            observation: observation(value: field, selectedText: "", range: NSRange(location: end, length: 0))
        )
        XCTAssertEqual(decision, .reselect(NSRange(location: end - 2, length: 2)))

        // Between two occurrences, touching neither: still no way to know which.
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: "ok",
                observation: observation(
                    value: field, selectedText: "", range: NSRange(location: end + 1, length: 0)
                )
            ),
            .refuse(.originalAmbiguous)
        )
        // A selection spanning several occurrences identifies none of them.
        XCTAssertEqual(
            SelectionReplacementGuard.decide(
                original: "ok",
                observation: observation(
                    value: field, selectedText: "", range: NSRange(location: end - 12, length: 12)
                )
            ),
            .refuse(.originalAmbiguous)
        )
    }

    // MARK: - Confirmer

    /// A host mid-restore answers an empty selection beside nothing else. That is a reading to
    /// wait on, not a verdict: the settle re-reads and the selection arrives.
    func testConfirmerSettlesOnAnEmptyAnswerBesideNothingElse() {
        let field = FakeField([
            observation(value: nil, selectedText: ""),
            observation(value: nil, selectedText: ""),
            observation(value: nil, selectedText: original),
        ])
        XCTAssertEqual(confirm(field), .confirmed(reselected: false))
    }

    /// A caret with no field to search cannot be repaired, but a host restoring a selection can
    /// report the caret first. It waits like any other blank reading, and when the caret never
    /// moves the refusal is the one that was actually observed, not a claim that nothing was read.
    func testConfirmerSettlesOnACaretItCannotSearchThenRefusesAsChanged() {
        let caret = observation(value: nil, selectedText: "", range: NSRange(location: 3, length: 0))
        let arrives = FakeField([caret, observation(value: nil, selectedText: original)])
        XCTAssertEqual(confirm(arrives), .confirmed(reselected: false))

        let stays = FakeField([caret])
        XCTAssertEqual(confirm(stays), .refused(.selectionChanged))
        XCTAssertEqual(stays.observed, SelectionReplacementGuard.Confirmer.settleAttempts + 1)

        // A clipboard capture is never waited on: it refuses a caret as it always has.
        let copied = FakeField([caret])
        XCTAssertEqual(
            confirm(copied, replacement: SelectionReplacement(original: original, requiresEvidence: false)),
            .refused(.selectionChanged)
        )
        XCTAssertEqual(copied.observed, 1)
    }

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

    /// Field report (1.3.0 build 389, Safari proofread): the selection read live, the transform
    /// succeeded, and the replace was refused `unreadable` with `role=AXWindow`. Focus had landed
    /// on the browser window while WebKit restored the page, and the settle re-read that window
    /// until the budget ran out. A window cannot publish the selection, so the settle has to
    /// resolve focus again and confirm on the element that appears.
    func testConfirmerRefocusesWhenTheFocusedElementIsAWindow() {
        let window = AXUIElementCreateApplication(1)
        let field = element
        var lookups = 0
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { candidate in
                if CFEqual(candidate, field) {
                    return self.observation(value: nil, selectedText: self.original)
                }
                return self.observation(value: nil)
            },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: {
                lookups += 1
                return lookups < 2 ? window : field
            },
            role: { candidate in
                CFEqual(candidate, field) ? "AXTextArea" : "AXWindow"
            }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false, refocusedOn: field))
        XCTAssertEqual(lookups, 2)
    }

    /// The earlier Safari failure was the field itself answering blank for a moment. Following
    /// focus away from that field would drop the element that is about to publish the selection.
    func testConfirmerKeepsABlankTextElementInsteadOfFollowingFocus() {
        let text = element
        let elsewhere = AXUIElementCreateApplication(1)
        var reads = 0
        var lookups = 0
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { candidate in
                XCTAssertTrue(CFEqual(candidate, text))
                reads += 1
                if reads < 2 { return self.observation(value: nil) }
                return self.observation(value: nil, selectedText: self.original)
            },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: {
                lookups += 1
                return elsewhere
            },
            role: { _ in "AXTextArea" }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: text
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false))
        XCTAssertEqual(lookups, 0)
    }

    /// The same handoff lands on a sheet, drawer, popover, or the application element. Each is a
    /// window-level container: a blank reading there is not the field, and re-reading it cannot
    /// see the selection arrive on the element that takes focus next.
    func testConfirmerRefocusesOffEveryWindowLevelContainer() {
        let roles = [
            kAXApplicationRole, kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXPopoverRole,
        ].map { $0 as String }
        let field = element
        for (index, role) in roles.enumerated() {
            let container = AXUIElementCreateApplication(pid_t(1_000 + Int32(index)))
            var lookups = 0
            let access = SelectionReplacementGuard.Confirmer.Access(
                observe: { candidate in
                    if CFEqual(candidate, field) {
                        return self.observation(value: nil, selectedText: self.original)
                    }
                    return self.observation(value: nil)
                },
                select: { _, _ in false },
                schedule: { _, action in action() },
                refocus: {
                    lookups += 1
                    return field
                },
                role: { candidate in CFEqual(candidate, field) ? "AXTextArea" : role }
            )
            var verdict: SelectionReplacementGuard.Confirmer.Verdict?
            SelectionReplacementGuard.Confirmer(access: access).confirm(
                SelectionReplacement(original: original)!, element: container
            ) { verdict = $0 }
            XCTAssertEqual(verdict, .confirmed(reselected: false, refocusedOn: field), role)
            XCTAssertEqual(lookups, 1, role)
        }
    }

    /// A container that itself publishes the original is the field for this replace. Resolving
    /// focus away from it would drop a selection the host has already handed back.
    func testConfirmerTrustsAContainerThatPublishesTheSelection() {
        let window = AXUIElementCreateApplication(1)
        var lookups = 0
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { _ in self.observation(value: nil, selectedText: self.original) },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: {
                lookups += 1
                return nil
            },
            role: { _ in kAXWindowRole as String }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false))
        XCTAssertEqual(lookups, 0)
    }

    /// Safari's page is an `AXWebArea`. The window is abandoned once; the web area is then the
    /// field, and a blank answer from it is waited on rather than treated as another container.
    func testConfirmerWaitsOnTheWebAreaAfterLeavingTheWindow() {
        let window = AXUIElementCreateApplication(1)
        let web = element
        var webReads = 0
        var lookups = 0
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { candidate in
                guard CFEqual(candidate, web) else { return self.observation(value: nil) }
                webReads += 1
                if webReads < 2 { return self.observation(value: nil) }
                return self.observation(value: nil, selectedText: self.original)
            },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: {
                lookups += 1
                return web
            },
            role: { candidate in CFEqual(candidate, web) ? "AXWebArea" : "AXWindow" }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false, refocusedOn: web))
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(webReads, 2)
    }

    /// The field behind the window has the original, but the caret collapsed when focus left.
    /// The re-select has to land on that field, and the rest of the inject has to be told about it.
    func testConfirmerReselectsOnTheFieldFoundAfterTheWindow() {
        let window = AXUIElementCreateApplication(1)
        let field = element
        let text = "say: \(original)"
        var fieldReads = 0
        var selected: [NSRange] = []
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { candidate in
                guard CFEqual(candidate, field) else { return self.observation(value: nil) }
                fieldReads += 1
                if fieldReads == 1 {
                    return self.observation(value: text, selectedText: "", range: NSRange(location: 24, length: 0))
                }
                return self.observation(
                    value: text, selectedText: self.original, range: NSRange(location: 5, length: 19)
                )
            },
            select: { range, candidate in
                XCTAssertTrue(CFEqual(candidate, field))
                selected.append(range)
                return true
            },
            schedule: { _, action in action() },
            refocus: { field },
            role: { candidate in CFEqual(candidate, field) ? "AXTextArea" : "AXWindow" }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: true, refocusedOn: field))
        XCTAssertEqual(selected, [NSRange(location: 5, length: 19)])
    }

    /// A window that never hands focus to a field still refuses, and the lookups are bounded by
    /// the same settle budget as a blank text element.
    func testConfirmerStopsRefocusingAWindowThatNeverYieldsAField() {
        let window = AXUIElementCreateApplication(1)
        var lookups = 0
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { _ in self.observation(value: nil) },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: {
                lookups += 1
                return window
            },
            role: { _ in "AXWindow" }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .refused(.unreadable))
        XCTAssertEqual(lookups, SelectionReplacementGuard.Confirmer.settleAttempts)
    }

    /// An unreadable role is not evidence of a container. A clipboard capture is not waited on
    /// even when the focused element is a window.
    func testConfirmerKeepsABlankElementWhoseRoleCannotBeRead() {
        for role in [nil, ""] {
            let text = element
            let elsewhere = AXUIElementCreateApplication(1)
            var reads = 0
            var lookups = 0
            let access = SelectionReplacementGuard.Confirmer.Access(
                observe: { candidate in
                    XCTAssertTrue(CFEqual(candidate, text))
                    reads += 1
                    if reads < 2 { return self.observation(value: nil) }
                    return self.observation(value: nil, selectedText: self.original)
                },
                select: { _, _ in false },
                schedule: { _, action in action() },
                refocus: {
                    lookups += 1
                    return elsewhere
                },
                role: { _ in role }
            )
            var verdict: SelectionReplacementGuard.Confirmer.Verdict?
            SelectionReplacementGuard.Confirmer(access: access).confirm(
                SelectionReplacement(original: original)!, element: text
            ) { verdict = $0 }
            XCTAssertEqual(verdict, .confirmed(reselected: false), role ?? "nil")
            XCTAssertEqual(lookups, 0, role ?? "nil")
        }

        let window = AXUIElementCreateApplication(1)
        var lookups = 0
        let copied = SelectionReplacementGuard.Confirmer.Access(
            observe: { _ in self.observation(value: nil) },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: {
                lookups += 1
                return nil
            },
            role: { _ in "AXWindow" }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: copied).confirm(
            SelectionReplacement(original: original, requiresEvidence: false)!, element: window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .unverified)
        XCTAssertEqual(lookups, 0)
    }

    // MARK: - Where the settle died

    private func trail(
        of verdict: SelectionReplacementGuard.Confirmer.Verdict?
    ) -> SelectionReplacementGuard.Confirmer.Trail? {
        switch verdict {
        case .refused(_, let trail), .confirmed(_, _, let trail): return trail
        default: return nil
        }
    }

    /// The refuse line used to log the role of the element the inject *started* on, so after the
    /// settle left a window for a web area that stayed blank it still said `role=AXWindow` — the
    /// one thing the report could not afford to get wrong. The trail names the last reading's
    /// element and counts what the settle did.
    func testRefusalTrailNamesTheElementTheSettleEndedOn() {
        let window = AXUIElementCreateApplication(1)
        let web = element
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { _ in self.observation(value: nil) },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: { web },
            role: { candidate in CFEqual(candidate, web) ? "AXWebArea" : "AXWindow" }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .refused(.unreadable))
        let settle = trail(of: verdict)
        XCTAssertEqual(settle?.startRole, "AXWindow")
        XCTAssertEqual(settle?.endRole, "AXWebArea")
        XCTAssertEqual(settle?.settles, SelectionReplacementGuard.Confirmer.settleAttempts)
        XCTAssertEqual(settle?.refocuses, 1, "the web area is waited on, not followed away from")
        XCTAssertEqual(
            settle?.summary,
            "settles=4 refocuses=1 startRole=AXWindow endRole=AXWebArea"
        )
    }

    func testRefusalTrailCountsEveryRefocusOfAWindowThatNeverYieldsAField() {
        let window = AXUIElementCreateApplication(1)
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { _ in self.observation(value: nil) },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: { window },
            role: { _ in "AXWindow" }
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original)!, element: window
        ) { verdict = $0 }
        let settle = trail(of: verdict)
        XCTAssertEqual(settle?.refocuses, SelectionReplacementGuard.Confirmer.settleAttempts)
        XCTAssertEqual(settle?.endRole, "AXWindow")
    }

    func testTrailOfAFocuslessInjectSaysSoAndAnImmediateAnswerRanNoSettle() {
        let blind = FakeField([observation(value: nil)])
        let none = trail(of: confirm(blind, element: .some(nil)))
        XCTAssertEqual(none?.startRole, "none")
        XCTAssertEqual(none?.endRole, "none")
        XCTAssertEqual(none?.settles, SelectionReplacementGuard.Confirmer.settleAttempts)

        let intact = FakeField([observation(value: nil, selectedText: original)])
        XCTAssertEqual(trail(of: confirm(intact))?.settles, 0)

        let late = FakeField([observation(value: nil), observation(value: nil, selectedText: original)])
        XCTAssertEqual(trail(of: confirm(late))?.settles, 1)
    }

    /// A refusal for the same cause is the same refusal however the settle got there.
    func testTrailDoesNotTakePartInVerdictEquality() {
        var longer = SelectionReplacementGuard.Confirmer.Trail()
        longer.settles = 4
        XCTAssertEqual(
            SelectionReplacementGuard.Confirmer.Verdict.refused(.unreadable, trail: longer),
            .refused(.unreadable)
        )
    }

    /// After a confirm that waited the entry gate is shown where focus is *now*. Handed the focus
    /// the inject resolved before the wait — or the element the target was just recaptured from —
    /// it compared a reading with itself and passed whatever the host had done in between.
    func testAConfirmThatWaitedResolvesFocusAgainBeforeTheEntryGate() throws {
        let suite = "SelectionReplacementGuardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let field = element
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { candidate in
                CFEqual(candidate, field)
                    ? self.observation(value: nil, selectedText: self.original)
                    : self.observation(value: nil)
            },
            select: { _, _ in false },
            schedule: { _, action in action() },
            refocus: { field },
            role: { _ in "AXTextArea" }
        )
        var queries = 0
        var kept: [String] = []
        let pipeline = TextInjectionPipeline(
            defaults: defaults,
            selectionConfirmer: SelectionReplacementGuard.Confirmer(access: access),
            keepRefusedReplacement: { kept.append($0); return true },
            focusQuery: { completion in
                queries += 1
                // The inject resolved no element; by the time the confirm is done the host has
                // lost focus again. Nothing may be pasted on the strength of the confirm.
                completion(.missing)
            }
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
            targetFocus: .resolved(nil),
            replacingSelection: SelectionReplacement(original: original)
        ) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        if queries < 2 {
            throw XCTSkip("entry gate refused before the confirm ran: \(String(describing: outcome))")
        }
        XCTAssertEqual(queries, 2, "one query for the inject, one after the confirm waited")
        XCTAssertEqual(outcome, .refused(SelectionReplacementGuard.Refusal.focusMoved.reason))
        XCTAssertEqual(kept, [result], "the generated payload survives the refusal")
    }

    // MARK: - The element the selection was read from

    /// Everything a `restoreFocus` scenario scripts: the window the host answers with, the field
    /// the selection was read from, and what each hook did.
    private final class CapturedScenario {
        let window = AXUIElementCreateApplication(1)
        let field: AXUIElement
        /// Whether the host honours the focus request: true moves `focused` to the field.
        var hostHonoursFocus = true
        var focusRequests: [AXUIElement] = []
        var focused: AXUIElement
        var refocuses = 0
        var fieldReadings: [DeliveryVerifier.FocusedTextObservation]

        init(field: AXUIElement, fieldReadings: [DeliveryVerifier.FocusedTextObservation]) {
            self.field = field
            self.fieldReadings = fieldReadings
            focused = window
        }

        func access(
            observe: @escaping (DeliveryVerifier.FocusedTextObservation) -> DeliveryVerifier.FocusedTextObservation = { $0 },
            focusAccepted: Bool = true
        ) -> SelectionReplacementGuard.Confirmer.Access {
            SelectionReplacementGuard.Confirmer.Access(
                observe: { candidate in
                    guard CFEqual(candidate, self.field) else { return DeliveryVerifier.FocusedTextObservation(value: nil, selectedText: nil) }
                    let reading = self.fieldReadings.count > 1 ? self.fieldReadings.removeFirst() : self.fieldReadings[0]
                    return observe(reading)
                },
                select: { _, _ in false },
                schedule: { _, action in action() },
                refocus: {
                    self.refocuses += 1
                    return self.focused
                },
                role: { CFEqual($0, self.field) ? "AXTextArea" : "AXWindow" },
                focus: { element in
                    self.focusRequests.append(element)
                    if focusAccepted, self.hostHonoursFocus { self.focused = element }
                    return focusAccepted
                }
            )
        }
    }

    /// The replace-time focus query resolves from scratch and, while WebKit restores a page,
    /// answers with the window every time. The element the 67 characters were read from is not
    /// that window. With the window still in front after a refocus, the guard asks focus to go
    /// back to the field, resolves focus again, and only when the host's own answer names the
    /// field does it confirm there — so the paste lands where the confirm looked.
    func testConfirmerRestoresFocusToTheCapturedFieldWhenFocusStaysOnTheWindow() {
        let scenario = CapturedScenario(
            field: element, fieldReadings: [observation(value: nil, selectedText: original)]
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: scenario.access()).confirm(
            SelectionReplacement(original: original, capturedElement: scenario.field)!,
            element: scenario.window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false, refocusedOn: scenario.field))
        XCTAssertEqual(scenario.focusRequests.count, 1)
        XCTAssertTrue(CFEqual(scenario.focusRequests[0], scenario.field))
        XCTAssertEqual(trail(of: verdict)?.capturedFocusAttempts, 1)
    }

    /// Also for an inject that resolved no element at all.
    func testConfirmerRestoresFocusWhenTheInjectResolvedNoElement() {
        let scenario = CapturedScenario(
            field: element, fieldReadings: [observation(value: nil, selectedText: original)]
        )
        scenario.focused = scenario.window
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: scenario.access()).confirm(
            SelectionReplacement(original: original, capturedElement: scenario.field)!, element: nil
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false, refocusedOn: scenario.field))
    }

    /// A host that accepts the focus request and ignores it is the case the comparison exists
    /// for. The field still reports the original selected, and confirming on that alone would
    /// paste into the window: it must refuse, and stop asking within the settle budget.
    func testConfirmerNeverConfirmsOnAFieldFocusDidNotReach() {
        let scenario = CapturedScenario(
            field: element, fieldReadings: [observation(value: nil, selectedText: original)]
        )
        scenario.hostHonoursFocus = false
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: scenario.access()).confirm(
            SelectionReplacement(original: original, capturedElement: scenario.field)!,
            element: scenario.window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .refused(.unreadable))
        XCTAssertEqual(scenario.focusRequests.count, SelectionReplacementGuard.Confirmer.settleAttempts)
        XCTAssertEqual(trail(of: verdict)?.endRole, "AXWindow")
    }

    func testConfirmerRefusesWhenTheHostDeclinesToMoveFocus() {
        let scenario = CapturedScenario(
            field: element, fieldReadings: [observation(value: nil, selectedText: original)]
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: scenario.access(focusAccepted: false)).confirm(
            SelectionReplacement(original: original, capturedElement: scenario.field)!,
            element: scenario.window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .refused(.unreadable))
    }

    /// Focus comes back, but the selection in the field is no longer the original: the usual
    /// judgement applies on the restored element, including its refusals.
    func testConfirmerJudgesTheRestoredFieldLikeAnyOther() {
        let scenario = CapturedScenario(
            field: element,
            fieldReadings: [observation(value: "something else entirely", selectedText: "", range: NSRange(location: 4, length: 0))]
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: scenario.access()).confirm(
            SelectionReplacement(original: original, capturedElement: scenario.field)!,
            element: scenario.window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .refused(.originalNotFound))
    }

    /// The captured element is the last resort, not the first: a refocus that finds a field that
    /// can hold a selection is judged as it always was, and never has focus moved under it.
    func testConfirmerLeavesFocusAloneWhenTheRefocusFindsAField() {
        let scenario = CapturedScenario(
            field: element, fieldReadings: [observation(value: nil, selectedText: original)]
        )
        let other = AXUIElementCreateApplication(2)
        scenario.focused = other
        var access = scenario.access()
        let inner = access.observe
        access.observe = { candidate in
            CFEqual(candidate, other)
                ? self.observation(value: nil, selectedText: self.original)
                : inner(candidate)
        }
        access.role = { CFEqual($0, scenario.window) ? "AXWindow" : "AXTextArea" }
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: access).confirm(
            SelectionReplacement(original: original, capturedElement: scenario.field)!,
            element: scenario.window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .confirmed(reselected: false, refocusedOn: other))
        XCTAssertTrue(scenario.focusRequests.isEmpty)
    }

    /// A copy capture cannot be confirmed through AX, so nothing here moves focus for one.
    func testConfirmerNeverMovesFocusForAReplacementThatDoesNotRequireEvidence() {
        let scenario = CapturedScenario(
            field: element, fieldReadings: [observation(value: nil, selectedText: original)]
        )
        var verdict: SelectionReplacementGuard.Confirmer.Verdict?
        SelectionReplacementGuard.Confirmer(access: scenario.access()).confirm(
            SelectionReplacement(original: original, requiresEvidence: false, capturedElement: scenario.field)!,
            element: scenario.window
        ) { verdict = $0 }
        XCTAssertEqual(verdict, .unverified)
        XCTAssertTrue(scenario.focusRequests.isEmpty)
    }

    /// With no `focus` hook an `Access` cannot move focus, so it never claims to have.
    func testAccessThatCannotMoveFocusDeclines() {
        let access = SelectionReplacementGuard.Confirmer.Access(
            observe: { _ in self.observation(value: nil) },
            select: { _, _ in false },
            schedule: { _, action in action() }
        )
        XCTAssertFalse(access.focus(element))
    }

    /// Capture to replacement: the element a live read came from rides along, and a read that
    /// never touched one (cache recovery, ⌘C) carries none.
    func testCapturedElementRidesFromTheLiveReadIntoTheReplacement() throws {
        func resolve(
            _ candidates: [SelectionReader.Candidate],
            cached: SelectionMonitor.CachedSelection? = nil
        ) -> SelectionReader.Result? {
            SelectionReader.evaluate(
                axTrusted: true, secureInputActive: false, frontmostBundleID: "com.apple.Safari",
                frontmostIsOwnProcess: false, focusAvailable: true, candidates: candidates, cached: cached,
                isMuted: { _ in false }, isWeakAX: { _ in false }
            ).result
        }
        let live = try XCTUnwrap(resolve([
            SelectionReader.Candidate(text: original, isOwnProcess: false, bundleID: "com.apple.Safari", element: element),
        ]))
        let captured = try XCTUnwrap(live.replacement?.capturedElement)
        XCTAssertTrue(CFEqual(captured, element))

        let copied = SelectionReader.outcomeForClipboardCapture(
            text: original, bundleID: "com.example", isWeakAX: { _ in false }
        )?.result
        XCTAssertNil(copied?.replacement?.capturedElement)
        XCTAssertNil(SelectionReader.Result(text: original, bundleID: nil, isWeakAX: false, source: .cached).replacement?.capturedElement)
    }

    func testBlankReadingAbandonsOnlyWindowLevelContainers() {
        let containers = [
            kAXApplicationRole, kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXPopoverRole,
        ].map { $0 as String }
        for role in containers {
            XCTAssertTrue(
                SelectionReplacementGuard.Confirmer.blankReadingAbandonsElement(role: role),
                role
            )
        }
        for role in ["AXTextArea", "AXTextField", "AXWebArea", "AXGroup", "AXScrollArea", "AXComboBox", ""] {
            XCTAssertFalse(
                SelectionReplacementGuard.Confirmer.blankReadingAbandonsElement(role: role),
                role
            )
        }
        XCTAssertFalse(SelectionReplacementGuard.Confirmer.blankReadingAbandonsElement(role: nil))
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
