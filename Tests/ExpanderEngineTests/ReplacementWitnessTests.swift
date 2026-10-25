import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import ExpanderEngine

// MARK: - Nothing confirmed an AI replace after the paste
//
// Field report, Safari build 389: a proofread of a 67-character selection was refused because the
// paste target resolved to AXWindow. The first pass made the selection check careful. The ⌘V that
// follows it was still fire-and-forget: `injectSecureClipboardPasteOnMain` reported
// `postedUnverified` whatever happened, so a paste that landed nowhere (focus slipped back to the
// window after the confirm) lost the generated result the moment the broker restored the user's
// clipboard.
//
// The first half drives `DeliveryVerifier.readReplacementOutcome` against a scripted field; the
// second drives the real broker (private pasteboard, ⌘V counted, never posted) and the real
// pipeline method against the same field, with the clipboard keeper recorded.
final class ReplacementWitnessTests: XCTestCase {

    private let field = AXUIElementCreateApplication(5101)
    private let window = AXUIElementCreateApplication(5102)
    private let replacementNode = AXUIElementCreateApplication(5103)
    private let frame = CGRect(x: 40, y: 80, width: 600, height: 300)

    private let selected = "teh quick brwon fox"
    private let result = "the quick brown fox"
    private var before: String { "say: \(selected) now" }
    private var selection: NSRange { NSRange(location: 5, length: (selected as NSString).length) }

    /// One page: which element is focused, and what each element reports.
    private final class Page {
        var focused: AXUIElement?
        var values: [String: String] = [:]
        var selections: [String: NSRange] = [:]
        var frames: [String: CGRect] = [:]
        var roles: [String: String] = [:]
        var pids: [String: pid_t] = [:]
        var unreadable: Set<String> = []

        func key(_ element: AXUIElement) -> String { String(describing: element) }

        func access() -> DeliveryVerifier.TextAccess {
            .init(
                focusedElement: { [unowned self] in self.focused },
                numberOfCharacters: { [unowned self] element in
                    self.values[self.key(element)].map { ($0 as NSString).length }
                },
                selectedRange: { [unowned self] element in self.selections[self.key(element)] },
                stringForRange: { _, _ in nil },
                observation: { [unowned self] element in
                    let k = self.key(element)
                    if self.unreadable.contains(k) {
                        return .init(value: nil, selectedText: nil, selectedRange: nil, target: element)
                    }
                    return .init(value: self.values[k], selectedText: nil,
                                 selectedRange: self.selections[k], target: element)
                },
                frame: { [unowned self] element in self.frames[self.key(element)] },
                role: { [unowned self] element in self.roles[self.key(element)] },
                pid: { [unowned self] element in self.pids[self.key(element)] }
            )
        }
    }

    private func makePage() -> Page {
        let page = Page()
        for element in [field, replacementNode] {
            let k = page.key(element)
            page.roles[k] = "AXTextArea"
            page.pids[k] = 900
            page.frames[k] = frame
        }
        page.roles[page.key(window)] = "AXWindow"
        page.pids[page.key(window)] = 900
        page.focused = field
        page.values[page.key(field)] = before
        page.selections[page.key(field)] = selection
        return page
    }

    // MARK: - The reading

    private func reading(
        _ page: Page, mirrorTrusted: Bool = true, expected: String? = nil
    ) -> DeliveryVerifier.ReplacementOutcome {
        let verifier = DeliveryVerifier(access: page.access())
        // Taken before the paste, as the pipeline does; the page is then mutated by the caller.
        return verifier.readReplacementOutcome(
            expectedText: expected ?? result, baseline: baseline(page), mirrorTrusted: mirrorTrusted
        )
    }

    private var capturedBaseline: DeliveryVerifier.FocusedTextObservation?
    private func baseline(_ page: Page) -> DeliveryVerifier.FocusedTextObservation {
        if let capturedBaseline { return capturedBaseline }
        let captured = DeliveryVerifier(access: page.access()).captureFocusedTextObservation(focus: .resolved(field))!
        capturedBaseline = captured
        return captured
    }

    func testAResultThatReplacedTheSelectionLanded() {
        let page = makePage()
        _ = baseline(page)
        page.values[page.key(field)] = "say: \(result) now"
        page.selections[page.key(field)] = NSRange(location: 5 + (result as NSString).length, length: 0)
        XCTAssertEqual(reading(page), .landed)
    }

    func testAResultOnAReplacedNodeOfTheSameControlLanded() {
        let page = makePage()
        _ = baseline(page)
        page.focused = replacementNode
        page.values[page.key(replacementNode)] = "say: \(result) now"
        page.selections[page.key(replacementNode)] = NSRange(location: 5 + (result as NSString).length, length: 0)
        XCTAssertEqual(reading(page), .landed)
    }

    /// The report's own shape: focus is the window, so a focus-based read has nothing to say, but
    /// the field the selection came from still answers and still holds the original.
    func testAFieldStillHoldingTheOriginalWhileFocusIsTheWindowDidNotLand() {
        let page = makePage()
        _ = baseline(page)
        page.focused = window
        XCTAssertEqual(reading(page), .notLanded)
    }

    func testAFieldStillHoldingTheOriginalWhileItIsFocusedDidNotLand() {
        let page = makePage()
        _ = baseline(page)
        XCTAssertEqual(reading(page), .notLanded)
    }

    func testAMirrorThatCannotBeTrustedNeverProvesAMiss() {
        let page = makePage()
        _ = baseline(page)
        page.focused = window
        XCTAssertEqual(reading(page, mirrorTrusted: false), .unverified)
    }

    func testAFieldThatCannotBeReadNowIsNotAMiss() {
        let page = makePage()
        _ = baseline(page)
        page.focused = window
        page.unreadable.insert(page.key(field))
        XCTAssertEqual(reading(page), .unverified)
    }

    func testAFieldThatChangedInSomeOtherWayIsNotAMiss() {
        let page = makePage()
        _ = baseline(page)
        page.focused = window
        page.values[page.key(field)] = before + "!"
        XCTAssertEqual(reading(page), .unverified, "the user typed — the field is no longer the one that was read")
    }

    func testAResultThatReadsLikeTheSelectionProvesNothingByLeavingTheFieldAlone() {
        let page = makePage()
        _ = baseline(page)
        page.focused = window
        XCTAssertEqual(reading(page, expected: selected), .unverified)
        XCTAssertEqual(
            reading(page, expected: selected.replacingOccurrences(of: " ", with: "\u{00A0}")), .unverified,
            "a difference the field's own whitespace folding erases is not a difference"
        )
    }

    func testABaselineThatNeverReadTheFieldCannotJudgeAMiss() {
        let page = makePage()
        page.values[page.key(field)] = nil
        capturedBaseline = nil
        _ = baseline(page)
        page.focused = window
        XCTAssertEqual(reading(page), .unverified)
    }

    // MARK: - The pipeline, end to end

    private struct NoLayout: KeyboardLayoutProviding {
        func currentSourceID() -> String? { nil }
        func keyCode(for character: Character) -> CGKeyCode? { nil }
    }

    /// A broker on a private pasteboard whose ⌘V is counted, never posted, plus the pipeline
    /// wired to it. `chords` is how many full ⌘V chords went out (four events each).
    private final class Rig {
        let board = NSPasteboard.withUniqueName()
        let broker: PasteboardBroker
        let pipeline: TextInjectionPipeline
        let defaults: UserDefaults
        let suite: String
        var events = 0
        var chords: Int { events / 4 }
        var kept: [String] = []
        var keepAnswer = true
        var toasts: [Bool] = []
        /// Runs once the first chord is out — where a test lets the paste land, or focus slip.
        var afterPaste: (Rig) -> Void = { _ in }
        var targetMovedAfterPaste = false
        /// Makes the broker's own pre-⌘V target check fail — ⌘V is then never posted — while the
        /// pipeline's continue-check still passes.
        var brokerRefusesTarget = false

        init(verifier: DeliveryVerifier, defaults: UserDefaults, suite: String) {
            self.defaults = defaults
            self.suite = suite
            let board = board
            var env = PasteboardBroker.Environment()
            env.pasteboard = { board }
            env.canPostEvents = { true }
            env.secureInputActive = { false }
            let selfBox = Box()
            env.targetCurrent = { _, _, _ in
                guard let rig = selfBox.rig else { return false }
                return !(rig.targetMovedAfterPaste || rig.brokerRefusesTarget)
            }
            let hid = HIDKeyPoster(
                commandEventIO: .init(canPost: { true }, post: { _ in selfBox.rig!.noteEvent() }, pause: {}),
                layout: KeyboardLayoutState(provider: NoLayout())
            )
            broker = PasteboardBroker(
                hid: hid, verifier: verifier, timing: InjectTimingStore(), environment: env
            )
            var keeper: ((String) -> Bool)!
            pipeline = TextInjectionPipeline(
                defaults: defaults,
                selectionConfirmer: SelectionReplacementGuard.Confirmer(),
                keepRefusedReplacement: { keeper($0) },
                clipboard: broker,
                verifier: verifier,
                deliveryTrust: { _, _ in true }
            )
            keeper = { [unowned self] text in
                self.kept.append(text)
                return self.keepAnswer
            }
            selfBox.rig = self
            pipeline.onReplaceNotLanded = { [unowned self] copied in self.toasts.append(copied) }
        }

        final class Box { weak var rig: Rig? }

        func noteEvent() {
            events += 1
            if events == 4 { afterPaste(self) }
        }

        deinit {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makeRig(_ page: Page) throws -> Rig {
        let suite = "ReplacementWitnessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return Rig(verifier: DeliveryVerifier(access: page.access()), defaults: defaults, suite: suite)
    }

    /// Runs one replace through the secure-paste path and returns how it ended.
    @discardableResult
    private func replace(
        on rig: Rig, replacesSelection: Bool = true,
        operationStillOurs: @escaping () -> Bool = { true }
    ) throws -> PermissionCoordinator.InjectOutcome? {
        try XCTSkipIf(
            AXContextChecker.isSecureEventInputEnabledLive(),
            "Secure Input is on in this session; the path under test is the one it bypasses"
        )
        rig.board.clearContents()
        rig.board.setString("the user's own clipboard", forType: .string)
        var outcome: PermissionCoordinator.InjectOutcome?
        let done = expectation(description: "replace finished")
        let rigRef = rig
        rig.pipeline.injectSecureClipboardPasteOnMain(
            snippet: SnippetModel(title: "AI", triggerKeyword: "", replacementText: result),
            clipboardOverride: nil,
            swallowed: .notSwallowed,
            preResolvedText: result,
            trailingKeys: [],
            snippetLookup: nil,
            focus: .resolved(field),
            replacesSelection: replacesSelection,
            shouldContinue: { !rigRef.targetMovedAfterPaste && operationStillOurs() },
            operationIsCurrent: operationStillOurs,
            completion: { outcome = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 10)
        return outcome
    }

    /// The field report's failure: ⌘V goes out, focus has slipped back to the window, nothing is
    /// pasted. Pre-fix this ended `postedUnverified` with the result nowhere.
    func testAPasteThatLandedNowhereKeepsTheResultAndSaysSo() throws {
        let page = makePage()
        let rig = try makeRig(page)
        rig.afterPaste = { [unowned self] rig in
            page.focused = self.window
            rig.targetMovedAfterPaste = true
        }
        let outcome = try replace(on: rig)

        XCTAssertEqual(outcome, .refused(SelectionReplacementGuard.Refusal.notLanded.reason))
        XCTAssertEqual(rig.kept, [result], "the generated result is kept on the clipboard")
        XCTAssertEqual(rig.toasts, [true])
        XCTAssertEqual(rig.chords, 1, "a miss never re-pastes: a late host read would duplicate the result")
    }

    func testAKeeperThatCannotCopyIsToldToTheUser() throws {
        let page = makePage()
        let rig = try makeRig(page)
        rig.keepAnswer = false
        rig.afterPaste = { [unowned self] rig in
            page.focused = self.window
            rig.targetMovedAfterPaste = true
        }
        try replace(on: rig)
        XCTAssertEqual(rig.toasts, [false])
    }

    func testAPasteThatLandedIsSucceededAndKeepsNothing() throws {
        let page = makePage()
        let rig = try makeRig(page)
        rig.afterPaste = { [unowned self] rig in
            page.values[page.key(self.field)] = "say: \(self.result) now"
            page.selections[page.key(self.field)] =
                NSRange(location: 5 + (self.result as NSString).length, length: 0)
        }
        let outcome = try replace(on: rig)
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(rig.kept, [])
        XCTAssertEqual(rig.toasts, [])
    }

    /// WebKit swaps the node when the paste lands, so the strict gate sees focus move — and the
    /// result is in the field. That is a landing, not a slip.
    func testAPasteThatReplacedTheNodeUnderItIsNotCalledAMiss() throws {
        let page = makePage()
        let rig = try makeRig(page)
        rig.afterPaste = { [unowned self] rig in
            page.focused = self.replacementNode
            page.values[page.key(self.replacementNode)] = "say: \(self.result) now"
            page.selections[page.key(self.replacementNode)] =
                NSRange(location: 5 + (self.result as NSString).length, length: 0)
            rig.targetMovedAfterPaste = true
        }
        let outcome = try replace(on: rig)
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(rig.kept, [])
    }

    /// A field AX cannot read gives no evidence either way: exactly the outcome it always had.
    func testAFieldThatCannotBeReadStaysPostedUnverified() throws {
        let page = makePage()
        page.unreadable.insert(page.key(field))
        let rig = try makeRig(page)
        let outcome = try replace(on: rig)
        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(rig.kept, [])
        XCTAssertEqual(rig.toasts, [])
    }

    /// Only a replace owes the field a read; an insert at the caret is untouched.
    func testAnInsertIsNotWatched() throws {
        let page = makePage()
        let rig = try makeRig(page)
        rig.afterPaste = { [unowned self] rig in
            page.focused = self.window
            rig.targetMovedAfterPaste = true
        }
        let outcome = try replace(on: rig, replacesSelection: false)
        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(rig.kept, [])
    }

    /// A cancelled or superseded inject has no claim on the field, so it keeps nothing.
    func testACancelledReplaceIsNotJudged() throws {
        let page = makePage()
        let rig = try makeRig(page)
        var cancelled = false
        rig.afterPaste = { [unowned self] rig in
            page.focused = self.window
            rig.targetMovedAfterPaste = true
            cancelled = true
        }
        let outcome = try replace(on: rig, operationStillOurs: { !cancelled })
        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(rig.kept, [])
    }

    /// ⌘V never went out (the target moved before it): the broker has restored the user's
    /// clipboard, so without the keep the result would simply be gone.
    func testAPasteThatWasNeverPostedKeepsTheResult() throws {
        let page = makePage()
        let rig = try makeRig(page)
        rig.brokerRefusesTarget = true
        let outcome = try replace(on: rig)
        XCTAssertEqual(outcome, .failedSilent)
        XCTAssertEqual(rig.chords, 0)
        XCTAssertEqual(rig.kept, [result])
        XCTAssertEqual(rig.toasts, [true])
    }

    func testRefusalClassifiesAndKeepsItsSentence() {
        let refusal = SelectionReplacementGuard.Refusal.notLanded
        XCTAssertFalse(refusal.reason.hasPrefix(SelectionReplacementGuard.refusalPrefix))
        let classified = InjectRefusalKind.classify(refusal.reason, path: SelectionReplacementGuard.refusalPath)
        XCTAssertEqual(classified.kind, .selectionReplaceUnconfirmed)
        XCTAssertEqual(classified.sentence, refusal.reason)
    }
}
