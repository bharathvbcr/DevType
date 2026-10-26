import ApplicationServices
import CoreGraphics
import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

/// A single-page app can re-render a *different* text control at the same frame — a search box
/// replaced by an inline editor pre-filled with the same text. Process, role and frame cannot tell
/// them apart, and that was the whole of what every path that follows a replaced node checked.
/// `ControlIdentity` is the one owner of that decision now; these tests pin its rule and that each
/// path asks it:
///
/// * an identity attribute present on both sides and different is a different control;
/// * present on both and equal is corroboration, and widens nothing;
/// * absent on either side is no evidence, so a host that publishes nothing is judged as before.
final class ControlIdentityTests: XCTestCase {

    private let frame = CGRect(x: 120, y: 340, width: 480, height: 28)

    private func identity(
        pid: pid_t? = 777, role: String? = "AXTextField", frame: CGRect? = CGRect(x: 120, y: 340, width: 480, height: 28),
        _ attributes: ControlIdentity.Attributes = .none
    ) -> ControlIdentity {
        ControlIdentity(pid: pid, role: role, frame: frame, attributes: attributes)
    }

    // MARK: - The owner's rule

    func testWithNothingPublishedTheFrameRuleDecidesAsItAlwaysDid() {
        XCTAssertEqual(ControlIdentity.compare(baseline: identity(), live: identity()), .frameOnly)
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(), live: identity(frame: frame.offsetBy(dx: 0, dy: 60))),
            .notSame
        )
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(), live: identity(frame: frame.offsetBy(dx: 1, dy: -1))),
            .frameOnly, "one point of slack is the tolerance the frame rule always had"
        )
    }

    func testAnAttributeBothSidesPublishAndDifferIsADifferentControlAtTheSameFrame() {
        let cases: [(ControlIdentity.Attributes, ControlIdentity.Attributes, ControlIdentity.Mark)] = [
            (.init(domIdentifier: "search"), .init(domIdentifier: "inline-editor"), .domIdentifier),
            (.init(identifier: "a"), .init(identifier: "b"), .identifier),
            (.init(placeholder: "Search"), .init(placeholder: "Reply"), .placeholder),
            (.init(domClassList: ["search"]), .init(domClassList: ["editor"]), .domClassList),
            (.init(parentRole: "AXGroup"), .init(parentRole: "AXScrollArea"), .parent),
            (.init(parentFrame: frame), .init(parentFrame: frame.offsetBy(dx: 0, dy: 200)), .parent),
        ]
        for (baseline, live, mark) in cases {
            XCTAssertEqual(
                ControlIdentity.compare(baseline: identity(baseline), live: identity(live)),
                .contradicted(mark), "\(mark)"
            )
            XCTAssertEqual(ControlIdentity.conflict(baseline, live), mark)
        }
    }

    func testTheSameDOMIdentifierOnANewElementIsTheSameControl() {
        let verdict = ControlIdentity.compare(
            baseline: identity(.init(domIdentifier: "search", placeholder: "Search")),
            live: identity(.init(domIdentifier: "search", placeholder: "Search"))
        )
        XCTAssertEqual(verdict, .corroborated)
        XCTAssertTrue(verdict.isSameControl)
    }

    func testAnAttributeOneSideDoesNotPublishIsNoEvidenceEitherWay() {
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(.init(domIdentifier: "search")), live: identity()),
            .frameOnly
        )
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(), live: identity(.init(domIdentifier: "search"))),
            .frameOnly
        )
        XCTAssertEqual(
            ControlIdentity.compare(
                baseline: identity(.init(domIdentifier: "a")), live: identity(.init(identifier: "b"))
            ),
            .frameOnly, "different attributes on each side are not a shared attribute that differs"
        )
    }

    /// WebKit answers an element with no `id` with `""` and one with no classes with `[]`. Two
    /// unrelated controls that both have none must not read as equal.
    func testAnEmptyAnswerIsAbsentNotAnEqualValue() {
        let blank = ControlIdentity.Attributes(
            domIdentifier: "", identifier: "  ", placeholder: "\n", domClassList: [], parentRole: ""
        )
        XCTAssertEqual(blank, .none)
        XCTAssertEqual(ControlIdentity.compare(baseline: identity(blank), live: identity(blank)), .frameOnly)
        XCTAssertFalse(ControlIdentity.corroborates(blank, blank))
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(blank), live: identity(.init(domIdentifier: "x"))),
            .frameOnly
        )
        XCTAssertEqual(ControlIdentity.Attributes(domClassList: ["", " "]), .none)
    }

    /// A control's classes move with its state, so one list holding the other is the same control.
    func testClassListsThatOnlyGainOrLoseStateClassesAreTheSameControl() {
        let resting = ControlIdentity.Attributes(domClassList: ["field", "search"])
        let focused = ControlIdentity.Attributes(domClassList: ["search", "field", "is-focused"])
        XCTAssertNil(ControlIdentity.conflict(resting, focused))
        XCTAssertNil(ControlIdentity.conflict(focused, resting))
        XCTAssertEqual(
            ControlIdentity.conflict(resting, .init(domClassList: ["field", "inline-editor"])), .domClassList
        )
    }

    func testAMatchingIdentityNeverRelaxesTheFrameOrTheOtherGates() {
        let same = ControlIdentity.Attributes(domIdentifier: "search")
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(same), live: identity(frame: frame.offsetBy(dx: 0, dy: 60), same)),
            .notSame, "corroboration is evidence, not a second way to be accepted"
        )
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(same), live: identity(pid: 778, same)), .notSame
        )
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(pid: nil, same), live: identity(same)), .notSame
        )
        for role in [nil, "AXWebArea", "AXSecureTextField", "AXComboBox", ""] {
            XCTAssertEqual(
                ControlIdentity.compare(baseline: identity(same), live: identity(role: role, same)), .notSame,
                "role \(role ?? "nil")"
            )
        }
        XCTAssertEqual(ControlIdentity.compare(baseline: identity(frame: nil), live: identity()), .notSame)
        XCTAssertEqual(
            ControlIdentity.compare(baseline: identity(), live: identity(frame: CGRect(x: 0, y: 0, width: 0, height: 20))),
            .notSame
        )
    }

    // MARK: - The delivery verifier

    private let original = AXUIElementCreateApplication(4321)
    private let replacement = AXUIElementCreateApplication(4322)

    private final class Page {
        var focused: AXUIElement?
        var values: [String: String] = [:]
        var selections: [String: NSRange] = [:]
        var frames: [String: CGRect] = [:]
        var roles: [String: String] = [:]
        var pids: [String: pid_t] = [:]
        var attributes: [String: ControlIdentity.Attributes] = [:]
        var counts: [String: Int] = [:]
        var windows: [String: String] = [:]

        func key(_ element: AXUIElement) -> String { String(describing: element) }

        func access() -> DeliveryVerifier.TextAccess {
            .init(
                focusedElement: { [unowned self] in self.focused },
                numberOfCharacters: { [unowned self] element in
                    self.counts[self.key(element)] ?? self.values[self.key(element)].map { ($0 as NSString).length }
                },
                selectedRange: { [unowned self] element in self.selections[self.key(element)] },
                stringForRange: { [unowned self] element, range in
                    self.windows[self.key(element)].map { ($0 as NSString).substring(with: range) }
                },
                observation: { [unowned self] element in
                    let k = self.key(element)
                    return .init(value: self.values[k], selectedText: nil,
                                 selectedRange: self.selections[k], target: element)
                },
                frame: { [unowned self] element in self.frames[self.key(element)] },
                role: { [unowned self] element in self.roles[self.key(element)] },
                pid: { [unowned self] element in self.pids[self.key(element)] },
                attributes: { [unowned self] element in self.attributes[self.key(element)] ?? .none }
            )
        }
    }

    private func page(
        baselineAttributes: ControlIdentity.Attributes
    ) -> (Page, DeliveryVerifier, DeliveryVerifier.FocusedTextObservation) {
        let page = Page()
        for element in [original, replacement] {
            let k = page.key(element)
            page.roles[k] = "AXTextField"
            page.pids[k] = 777
            page.frames[k] = frame
        }
        page.attributes[page.key(original)] = baselineAttributes
        page.focused = original
        page.values[page.key(original)] = "see "
        page.selections[page.key(original)] = NSRange(location: 4, length: 0)
        let verifier = DeliveryVerifier(access: page.access())
        return (page, verifier, verifier.captureFocusedTextObservation(focus: .resolved(original))!)
    }

    private func swapNodeAfterPaste(_ page: Page, attributes: ControlIdentity.Attributes) {
        page.focused = replacement
        page.values[page.key(replacement)] = "see EXPANSION"
        page.selections[page.key(replacement)] = NSRange(location: 13, length: 0)
        page.attributes[page.key(replacement)] = attributes
    }

    func testTheBaselineCarriesWhatTheFieldPublishedBeforeItsNodeWasSwapped() {
        let published = ControlIdentity.Attributes(domIdentifier: "search")
        let (_, _, baseline) = page(baselineAttributes: published)
        XCTAssertEqual(baseline.attributes, published)
    }

    func testAnotherControlAtTheSameFrameNeverVerifiesTheDelivery() {
        let (page, verifier, baseline) = page(baselineAttributes: .init(domIdentifier: "search"))
        swapNodeAfterPaste(page, attributes: .init(domIdentifier: "inline-editor"))
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
        )
        XCTAssertEqual(reading.verification, .unavailable)
        XCTAssertEqual(reading.unavailableReason, .focusReplaced)
        XCTAssertNil(reading.replacementElement)
        let outcome = verifier.readReplacementOutcome(
            expectedText: "EXPANSION", baseline: baseline, mirrorTrusted: true
        )
        XCTAssertNotEqual(outcome, .landed, "text that is in some other control proves nothing about this one")
    }

    func testTheSameDOMIdentifierOnANewNodeStillVerifiesTheDelivery() {
        let (page, verifier, baseline) = page(baselineAttributes: .init(domIdentifier: "search"))
        swapNodeAfterPaste(page, attributes: .init(domIdentifier: "search"))
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
        )
        XCTAssertEqual(reading.verification, .delivered)
        XCTAssertNotNil(reading.replacementElement)
    }

    func testAHostThatPublishesNothingIsJudgedByTheFrameAsBefore() {
        let (page, verifier, baseline) = page(baselineAttributes: .none)
        swapNodeAfterPaste(page, attributes: .none)
        XCTAssertEqual(
            verifier.readFocusedTextDelivery(
                expectedText: "EXPANSION", baseline: baseline, vouchingReplacement: true
            ).verification,
            .delivered
        )
    }

    // MARK: - The vouched read is the same comparison as the plain one

    /// `readFocusedTextDelivery` promises the comparison is unchanged for a vouched replacement.
    /// The plain read answers from `kAXNumberOfCharacters` plus a ranged read when the host will
    /// not hand over the value; the vouched read used to skip that and report the field unreadable.
    func testAVouchedReplacementIsReadWithTheSameWindowedComparison() {
        let (page, verifier, _) = page(baselineAttributes: .none)
        let windowedBaseline = DeliveryVerifier.FocusedTextObservation(
            value: "see ", selectedText: nil, selectedRange: NSRange(location: 4, length: 0),
            target: original, numberOfCharacters: 4, frame: frame
        )
        swapNodeAfterPaste(page, attributes: .none)
        page.values[page.key(replacement)] = nil
        page.counts[page.key(replacement)] = 13
        page.windows[page.key(replacement)] = "see EXPANSION"
        let reading = verifier.readFocusedTextDelivery(
            expectedText: "EXPANSION", baseline: windowedBaseline, vouchingReplacement: true
        )
        XCTAssertEqual(reading.verification, .delivered)
        XCTAssertNotNil(reading.replacementElement)
        // The same element answered the same way before the swap.
        page.focused = original
        page.counts[page.key(original)] = 13
        page.values[page.key(original)] = nil
        page.windows[page.key(original)] = "see EXPANSION"
        page.selections[page.key(original)] = NSRange(location: 13, length: 0)
        XCTAssertEqual(
            verifier.readFocusedTextDelivery(expectedText: "EXPANSION", baseline: windowedBaseline).verification,
            .delivered
        )
    }

    // MARK: - The erase continuation

    private func picture(
        _ value: String, caret: Int? = nil, attributes: ControlIdentity.Attributes = .none
    ) -> EraseContinuation.EraseFieldPicture {
        EraseContinuation.EraseFieldPicture(
            value: value, caretLocation: caret ?? value.utf16.count, selectionLength: 0,
            frame: frame, attributes: attributes
        )
    }

    private func facts(
        phase: EraseContinuationPhase, matched: Bool = false, contradicted: Bool = false,
        precondition: ErasePreconditionResult? = nil, reading: EraseFieldReading = .triggerAbsent
    ) -> EraseContinuationFacts {
        EraseContinuationFacts(
            phase: phase, revisionCurrent: true, continuationBlock: nil, secureInputBlocked: false,
            axUntrusted: false, mismatch: .elementChanged, allowsRetarget: true,
            deletionMatched: matched, livePrecondition: precondition, liveRole: "AXTextField",
            fieldReading: reading, identityContradicted: contradicted
        )
    }

    /// The same text at the same frame in another control: every text and frame check passes.
    func testAFieldWithTheSameTextAtTheSameFrameButAnotherIdentityIsNotTheFieldTheEraseStartedIn() {
        let anchor = picture("hello sig", attributes: .init(domIdentifier: "search"))
        let lookalike = picture("hello ", caret: 6, attributes: .init(domIdentifier: "inline-editor"))
        for maxRemoved in [0, 3] {
            XCTAssertNil(EraseContinuation.deletionMatch(
                anchor: anchor, live: lookalike, expectedText: "sig", caseInsensitive: false,
                maxRemovedGraphemes: maxRemoved
            ), "maxRemoved \(maxRemoved)")
        }
        XCTAssertFalse(EraseContinuation.deletionConfirms(
            phase: .beforeInsertion, anchor: anchor, live: lookalike, expectedText: "sig",
            caseInsensitive: false, maxRemovedGraphemes: 3
        ))
        XCTAssertFalse(EraseContinuation.deletionConfirms(
            phase: .duringErase, anchor: anchor, live: lookalike, expectedText: "sig",
            caseInsensitive: false, maxRemovedGraphemes: 3
        ))
        XCTAssertFalse(EraseContinuation.deletionIsLagging(
            anchor: anchor, live: picture("hello s", caret: 7, attributes: .init(domIdentifier: "inline-editor")),
            expectedText: "sig", caseInsensitive: false
        ))
        XCTAssertFalse(EraseContinuation.partialEraseLanded(
            anchor: anchor, live: picture("hello si", caret: 8, attributes: .init(domIdentifier: "inline-editor")),
            expectedText: "sig", caseInsensitive: false, posted: 1
        ), "a restore must not write the removed tail into another control")
        // An unreadable value matches on the frame alone; identity still refuses it.
        let blank = EraseContinuation.EraseFieldPicture(
            value: nil, caretLocation: nil, selectionLength: nil, frame: frame,
            attributes: .init(domIdentifier: "inline-editor")
        )
        XCTAssertNil(EraseContinuation.deletionMatch(
            anchor: anchor, live: blank, expectedText: "sig", caseInsensitive: false, maxRemovedGraphemes: 3
        ))
    }

    func testTheSameDOMIdentifierOnTheReplacementNodeIsStillTheFieldTheEraseStartedIn() {
        let anchor = picture("hello sig", attributes: .init(domIdentifier: "search"))
        let swapped = picture("hello ", caret: 6, attributes: .init(domIdentifier: "search"))
        XCTAssertEqual(
            EraseContinuation.deletionMatch(
                anchor: anchor, live: swapped, expectedText: "sig", caseInsensitive: false, maxRemovedGraphemes: 3
            ),
            .progress(removedGraphemes: 3)
        )
        XCTAssertTrue(EraseContinuation.deletionConfirms(
            phase: .beforeInsertion, anchor: anchor, live: swapped, expectedText: "sig",
            caseInsensitive: false, maxRemovedGraphemes: 3
        ))
        XCTAssertTrue(EraseContinuation.partialEraseLanded(
            anchor: anchor,
            live: picture("hello si", caret: 8, attributes: .init(domIdentifier: "search")),
            expectedText: "sig", caseInsensitive: false, posted: 1
        ))
        // A host that publishes nothing: the text evidence decides, as before.
        XCTAssertTrue(EraseContinuation.partialEraseLanded(
            anchor: picture("hello sig"), live: picture("hello si", caret: 8),
            expectedText: "sig", caseInsensitive: false, posted: 1
        ))
    }

    /// Before the erase there is no text progress to compare — the live field only has to hold the
    /// trigger at its caret, which the same-text control satisfies. Only identity can refuse it.
    func testAContradictedIdentityRefusesTheRetargetInEveryPhase() {
        let rows: [(EraseContinuationPhase, EraseContinuationFacts)] = [
            (.beforeErase, facts(phase: .beforeErase, contradicted: true, precondition: .ok)),
            (.duringErase, facts(phase: .duringErase, matched: true, contradicted: true)),
            (.beforeInsertion, facts(phase: .beforeInsertion, matched: true, contradicted: true)),
        ]
        for (phase, row) in rows {
            guard case .refuse = EraseContinuation.decide(row) else {
                return XCTFail("\(phase) followed a control the host says is another one")
            }
            var uncontradicted = row
            uncontradicted.identityContradicted = false
            XCTAssertEqual(
                EraseContinuation.decide(uncontradicted), .retarget,
                "\(phase): the same facts without a contradiction are the WebKit swap, and must still follow"
            )
        }
    }

    /// A contradiction is a verdict, not a reading a second look can clear.
    func testAContradictedIdentityIsNeverReread() {
        var lagging = facts(phase: .beforeInsertion)
        lagging.deletionLagging = true
        XCTAssertTrue(EraseContinuation.mayClearOnReread(lagging), "the control: a lagging mirror is read again")
        lagging.identityContradicted = true
        XCTAssertFalse(EraseContinuation.mayClearOnReread(lagging))
        var container = facts(phase: .beforeInsertion)
        container.liveRole = "AXWebArea"
        XCTAssertTrue(EraseContinuation.mayClearOnReread(container))
        container.identityContradicted = true
        XCTAssertFalse(EraseContinuation.mayClearOnReread(container))
    }

    // MARK: - Wiring

    /// `adoptVouchedContinuation` reads the live control's attributes against the baseline taken
    /// when the inject began, before any phase is judged, and every follow of a replaced node
    /// (the erase, the paste, the restore) goes through it. Its reads are not injectable, so this is
    /// the contract the behavioural tests above rely on.
    func testEveryFollowOfAReplacedNodeAsksTheOneOwner() throws {
        let pipeline = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        )
        let adopt = try SourceTree.functionBody("private func adoptVouchedContinuation(", in: pipeline)
        let read = try XCTUnwrap(adopt.range(of: "ControlIdentity.conflict(context.adopted.baseline"))
        let decide = try XCTUnwrap(adopt.range(of: "EraseContinuation.decide(facts)"))
        XCTAssertLessThan(read.lowerBound, decide.lowerBound)
        XCTAssertTrue(adopt.contains("identityContradicted: identityContradicted"))
        XCTAssertTrue(pipeline.contains("baseline: allowsEraseRetarget(request)"), "the baseline is read ahead of the erase")
        XCTAssertTrue(
            pipeline.contains("self.verifier.vouchesAsSameControl(baseline: confirmedIdentity, live: liveElement)"),
            "the AI replace confirm judges a swapped node by the same owner"
        )
        let verifier = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/DeliveryVerifier.swift")
        )
        XCTAssertTrue(verifier.contains("ControlIdentity.compare(baseline:"))
        let erase = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/EraseContinuation.swift")
        )
        for source in [pipeline, verifier, erase] {
            XCTAssertFalse(source.contains("abs(left.origin"), "no second frame-tolerance comparison")
            XCTAssertFalse(source.contains("frameIdentityTolerance"))
        }
    }
}
