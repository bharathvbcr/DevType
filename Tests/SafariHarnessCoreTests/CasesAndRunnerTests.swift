import XCTest
@testable import SafariHarnessCore
import SourceTreeTestSupport

final class CaseTableTests: XCTestCase {
    func testIdsAreUniqueAndEveryRequiredCaseIsPresent() {
        let ids = CaseTable.all().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for required in ["plain-input", "textarea", "contenteditable", "rerender-input", "spa-swap-immediate", "spa-swap-delayed",
                         "two-triggers-fast", "type-during-expansion", "secure-password-field", "secure-released",
                         "held-shift-at-paste", "held-option-at-paste", "ai-proofread"] {
            XCTAssertTrue(ids.contains(required), required)
        }
    }

    func testNoCaseTypesIntoTheResetButtonAndEveryTypingStepFollowsAFocus() {
        for c in CaseTable.all() {
            var focused = false
            for step in c.steps {
                switch step {
                case .focus(let f): XCTAssertTrue(f.acceptsTyping, c.id); focused = true
                case .typeTrigger, .typeLiteral, .typeTriggerThenHold: XCTAssertTrue(focused, "\(c.id) types before focusing a field")
                case .reset: focused = false
                default: break
                }
            }
        }
    }

    func testHeldModifierCasesAlwaysReleaseTheModifier() {
        for c in CaseTable.all() {
            let held = c.steps.compactMap { step -> Modifier? in if case .typeTriggerThenHold(let m, _) = step { return m } else { return nil } }
            let released = c.steps.compactMap { step -> Modifier? in if case .releaseModifier(let m) = step { return m } else { return nil } }
            XCTAssertEqual(held, released, c.id)
            XCTAssertEqual(c.observesChords, !held.isEmpty, c.id)
        }
    }

    func testOnlyTheAICaseNeedsAIAndSelectIsAFilter() {
        XCTAssertEqual(CaseTable.all().filter(\.needsAI).map(\.id), ["ai-proofread"])
        XCTAssertEqual(CaseTable.select(ids: ["textarea"]).map(\.id), ["textarea"])
        XCTAssertEqual(CaseTable.select(ids: nil).count, CaseTable.all().count)
    }

    func testPlannedEventCountMatchesTheKeyPlan() {
        let spec = HarnessSnippetSpec()
        let plain = CaseTable.all().first { $0.id == "plain-input" }!
        XCTAssertEqual(Planner.plannedEventCount(plain, spec: spec, hotkey: .default), spec.trigger.count * 2)
        let two = CaseTable.all().first { $0.id == "two-triggers-fast" }!
        XCTAssertEqual(Planner.plannedEventCount(two, spec: spec, hotkey: .default), spec.trigger.count * 4)
    }

    /// The fixture and the case table must agree on every id and on the AI text.
    func testFixtureHoldsEveryPageFieldAndTheAIText() throws {
        let html = try String(contentsOf: SourceTree.root.appendingPathComponent(HarnessConstants.fixtureRelativePath), encoding: .utf8)
        XCTAssertTrue(html.contains("<title>\(HarnessConstants.pageTitle)</title>"))
        for field in PageField.allCases {
            XCTAssertTrue(html.contains("'\(field.domID)'") || html.contains("\"\(field.domID)\""), "\(field.domID) missing from the fixture")
        }
        XCTAssertTrue(html.contains("var AI_TEXT = '\(CaseTable.aiOriginalText)'"))
        XCTAssertTrue(html.contains("id=\"dth-reset\""))
        XCTAssertTrue(PageField.allCases.allSatisfy { $0.domID.hasPrefix(HarnessConstants.domPrefix) })
    }
}

final class EvaluatorTests: XCTestCase {
    private let spec = HarnessSnippetSpec()

    private func reading(_ f: PageField, ax: String? = nil, js: String? = nil) -> [PageField: FieldReading] {
        [f: FieldReading(field: f, axValue: ax, jsValue: js)]
    }

    private func expansions(_ count: Int, suffix: String = "", trim: Bool = false) -> Check {
        .expansions(.plain, count: count, suffix: suffix, trimTrailingNewline: trim)
    }

    func testExactExpansionPassesAndNeedsEveryReadableSourceToAgree() {
        let ok = spec.expansion
        XCTAssertTrue(Evaluator.evaluate(expansions(1), readings: reading(.plain, ax: ok, js: ok), spec: spec, secureInputWasOn: nil).pass)
        XCTAssertFalse(Evaluator.evaluate(expansions(1), readings: reading(.plain, ax: ok, js: ok + "x"), spec: spec, secureInputWasOn: nil).pass)
        XCTAssertTrue(Evaluator.evaluate(expansions(1), readings: reading(.plain, ax: ok), spec: spec, secureInputWasOn: nil).pass)
    }

    func testFailureExplanationsNameWhatWentWrong() {
        func why(_ value: String, count: Int = 1) -> String {
            Evaluator.evaluate(expansions(count), readings: reading(.plain, ax: value), spec: spec, secureInputWasOn: nil).summary
        }
        XCTAssertTrue(why(spec.trigger).contains("nothing expanded"))
        XCTAssertTrue(why("").contains("empty"))
        XCTAssertTrue(why(spec.expansion + spec.expansion).contains("2 times"))
        XCTAssertTrue(why(spec.expansion + spec.trigger, count: 2).contains("literal trigger"))
        XCTAssertTrue(why("hello").contains("no expansion"))
    }

    func testSuffixAndTrailingNewlineNormalisation() {
        let withSuffix = Evaluator.evaluate(expansions(1, suffix: "xyz"), readings: reading(.plain, js: spec.expansion + "xyz"), spec: spec, secureInputWasOn: nil)
        XCTAssertTrue(withSuffix.pass)
        let reorder = Evaluator.evaluate(expansions(1, suffix: "xyz"), readings: reading(.plain, js: "xyz" + spec.expansion), spec: spec, secureInputWasOn: nil)
        XCTAssertFalse(reorder.pass)
        XCTAssertTrue(Evaluator.evaluate(expansions(1, trim: true), readings: reading(.plain, ax: spec.expansion + "\n"), spec: spec, secureInputWasOn: nil).pass)
        XCTAssertFalse(Evaluator.evaluate(expansions(1, trim: false), readings: reading(.plain, ax: spec.expansion + "\n"), spec: spec, secureInputWasOn: nil).pass)
    }

    func testUnreadableFieldIsInconclusiveNotAFailureOrAPass() {
        let v = Evaluator.evaluate(expansions(1), readings: [.plain: FieldReading(field: .plain)], spec: spec, secureInputWasOn: nil)
        XCTAssertTrue(v.inconclusive)
        XCTAssertFalse(v.pass)
    }

    func testSpaCaseFailsOnlyWhenTheExpansionLandedInTheReplacementControl() {
        let check = Check.spaNotLanded(a: .spaImmediateA, b: .spaImmediateB)
        func readings(b: String?, a: String? = nil) -> [PageField: FieldReading] {
            [.spaImmediateA: FieldReading(field: .spaImmediateA, jsValue: a),
             .spaImmediateB: FieldReading(field: .spaImmediateB, jsValue: b)]
        }
        XCTAssertFalse(Evaluator.evaluate(check, readings: readings(b: spec.expansion), spec: spec, secureInputWasOn: nil).pass)
        let refused = Evaluator.evaluate(check, readings: readings(b: spec.trigger), spec: spec, secureInputWasOn: nil)
        XCTAssertTrue(refused.pass)
        XCTAssertFalse(refused.summary.contains("lost characters"))
        let damaged = Evaluator.evaluate(check, readings: readings(b: ""), spec: spec, secureInputWasOn: nil)
        XCTAssertTrue(damaged.pass)
        XCTAssertTrue(damaged.summary.contains("lost characters"))
        XCTAssertTrue(Evaluator.evaluate(check, readings: readings(b: nil), spec: spec, secureInputWasOn: nil).inconclusive,
                      "no swap means the case proved nothing")
    }

    func testPasswordCase() {
        let check = Check.passwordNotExpanded(.password)
        let bullets = String(repeating: "•", count: spec.trigger.count)
        XCTAssertTrue(Evaluator.evaluate(check, readings: reading(.password, ax: bullets, js: spec.trigger), spec: spec, secureInputWasOn: true).pass)
        XCTAssertFalse(Evaluator.evaluate(check, readings: reading(.password, ax: bullets, js: spec.expansion), spec: spec, secureInputWasOn: true).pass)
        XCTAssertFalse(Evaluator.evaluate(check, readings: reading(.password, ax: "•••"), spec: spec, secureInputWasOn: true).pass)
        XCTAssertTrue(Evaluator.evaluate(check, readings: reading(.password, ax: bullets), spec: spec, secureInputWasOn: false).inconclusive,
                      "secure input off means the premise failed")
    }

    func testAICase() {
        let check = Check.aiRewrote(.ai)
        let original = CaseTable.aiOriginalText
        func verdict(_ v: String) -> Verdict { Evaluator.evaluate(check, readings: reading(.ai, js: v), spec: spec, secureInputWasOn: nil) }
        XCTAssertTrue(verdict("The quick brown fox jumped over the lazy dog.").pass)
        XCTAssertFalse(verdict(original).pass)
        XCTAssertFalse(verdict("").pass)
        XCTAssertFalse(verdict(original + " The quick brown fox jumped over the lazy dog.").pass)
        XCTAssertFalse(verdict("ok").pass)
        XCTAssertFalse(verdict("A completely different sentence of similar length ok").pass)
    }
}

// MARK: - Runner with fake ports

private final class FakeKeyboard: KeyboardPort {
    var events: [KeyEvent] = []
    var onPost: ((KeyEvent) -> Void)?
    var releases = 0
    func post(_ event: KeyEvent) throws { events.append(event); onPost?(event) }
    func releaseHeldModifiers() { releases += 1 }
}

private final class FakePage: PagePort {
    let spec: HarnessSnippetSpec
    var snapshot = FocusSnapshot(frontBundleID: "com.apple.Safari", frontPID: 10, focusedPID: 10,
                                 focusedDOMID: "dth-plain", focusedRole: "AXTextField", webAreaPath: "/fixture.html")
    var values: [PageField: String] = [:]
    var typed = ""
    var secure = true
    var snapshotThrows = false
    var expandOnTrigger = true

    init(spec: HarnessSnippetSpec) { self.spec = spec }

    func focusSnapshot() throws -> FocusSnapshot {
        if snapshotThrows { throw NSError(domain: "t", code: 1) }
        return snapshot
    }
    func reset() throws { values = [:]; typed = "" }
    func focus(_ field: PageField) throws { snapshot.focusedDOMID = field.domID; typed = "" }
    func read(_ field: PageField) -> FieldReading { FieldReading(field: field, axValue: values[field], jsValue: values[field]) }
    func selectAll(_ field: PageField) throws -> String? { CaseTable.aiOriginalText }
    func secureInputEnabled() -> Bool { secure }
    func drainPageLog() -> [String] { [] }

    private static let characterForKeyCode: [UInt16: Character] = {
        var map: [UInt16: Character] = [:]
        for scalar in 32...126 {
            let c = Character(UnicodeScalar(UInt8(scalar)))
            if let (code, shift) = KeyPlan.keyCode(for: c), !shift { map[code] = c }
        }
        return map
    }()

    /// Simulates DevType: once the trigger text has been typed, it is replaced by the expansion.
    func typedKey(_ event: KeyEvent) {
        guard event.down, let focused = snapshot.focusedDOMID, let field = PageField(rawValue: focused),
              let character = Self.characterForKeyCode[event.keyCode] else { return }
        typed.append(character)
        values[field] = typed
        if expandOnTrigger, typed.hasSuffix(spec.trigger) {
            typed = String(typed.dropLast(spec.trigger.count)) + spec.expansion
            values[field] = typed
        }
    }
}

private final class VirtualTime: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var escapeAfter: Date?
    lazy var clock = Clock(now: { self.now }, sleep: { self.now = self.now.addingTimeInterval($0) })
    var escapeDown: Bool { escapeAfter.map { now >= $0 } ?? false }
}

final class RunnerTests: XCTestCase {
    private let spec = HarnessSnippetSpec()

    private final class Rig {
        let runner: Runner
        let keyboard: FakeKeyboard
        let page: FakePage
        let clipboard: InMemoryClipboard
        let time: VirtualTime
        let spec: HarnessSnippetSpec

        init(runner: Runner, keyboard: FakeKeyboard, page: FakePage, clipboard: InMemoryClipboard, time: VirtualTime, spec: HarnessSnippetSpec) {
            self.runner = runner
            self.keyboard = keyboard
            self.page = page
            self.clipboard = clipboard
            self.time = time
            self.spec = spec
        }
    }

    private func rig(mode: RunMode = .live, ai: AIAvailability = .unavailable("off"), timeout: Double = 600) -> Rig {
        let time = VirtualTime()
        let keyboard = FakeKeyboard()
        let page = FakePage(spec: spec)
        keyboard.onPost = { [unowned page] in page.typedKey($0) }
        let clipboard = InMemoryClipboard(ClipboardSnapshot(items: [["public.utf8-plain-text": Data("keep me".utf8)]]))
        let start = time.now.timeIntervalSince1970
        let abort = AbortController(timeoutSeconds: timeout, now: { time.now.timeIntervalSince1970 - start },
                                    escapeDown: { time.escapeDown }, signalled: { false })
        let context = RunContext(mode: mode, spec: spec, fixturePath: "/fixture.html", devTypePID: 77, ai: ai, hotkey: .default, seed: 3)
        let runner = Runner(keyboard: keyboard, page: page, clipboard: clipboard, chords: nil, abort: abort, clock: time.clock, context: context)
        return Rig(runner: runner, keyboard: keyboard, page: page, clipboard: clipboard, time: time, spec: spec)
    }

    private func only(_ id: String) -> [HarnessCase] { CaseTable.select(ids: [id]) }

    func testLivePlainInputPassesAndTypesEveryTriggerKey() {
        let r = rig()
        let outcome = r.runner.run(only("plain-input"))
        XCTAssertEqual(outcome.results.first?.status, .pass, outcome.results.first?.summary ?? "")
        XCTAssertEqual(r.keyboard.events.count, spec.trigger.count * 2)
        XCTAssertNil(outcome.abort)
        XCTAssertGreaterThan(r.keyboard.releases, 0, "modifiers are released on every exit")
        XCTAssertTrue(outcome.results[0].notes.contains { $0.contains("effective key-to-key gap") })
    }

    func testFailedExpansionIsAFailWithTheFieldValueInTheEvidence() {
        let r = rig()
        r.page.expandOnTrigger = false
        let result = r.runner.run(only("plain-input")).results[0]
        XCTAssertEqual(result.status, .fail)
        XCTAssertTrue(result.summary.contains("nothing expanded"))
        XCTAssertTrue(result.fields.joined().contains(spec.trigger))
    }

    func testForeignFocusStopsPostingImmediatelyAndMarksTheRestNotRun() {
        let r = rig()
        r.keyboard.onPost = { [unowned r] _ in
            if r.keyboard.events.count == 2 { r.page.snapshot.frontBundleID = "com.apple.Terminal" }
        }
        let outcome = r.runner.run(CaseTable.select(ids: ["plain-input", "textarea"]))
        XCTAssertEqual(r.keyboard.events.count, 2, "no key after the focus guard refused")
        XCTAssertEqual(outcome.results[0].status, .aborted)
        XCTAssertEqual(outcome.results[1].status, .notRun)
        if case .unsafeFocus = outcome.abort {} else { XCTFail("abort reason \(String(describing: outcome.abort))") }
        XCTAssertGreaterThan(r.keyboard.releases, 0)
    }

    func testUnreadableFocusFailsClosed() {
        let r = rig()
        r.page.snapshotThrows = true
        let outcome = r.runner.run(only("plain-input"))
        XCTAssertEqual(r.keyboard.events.count, 0)
        XCTAssertEqual(outcome.results[0].status, .aborted)
    }

    func testEscapeAbortsMidTypingAndLatches() {
        let r = rig()
        r.time.escapeAfter = r.time.now.addingTimeInterval(0.45)
        let outcome = r.runner.run(CaseTable.select(ids: ["plain-input", "textarea"]))
        XCTAssertEqual(outcome.abort, .escapePressed)
        XCTAssertLessThan(r.keyboard.events.count, spec.trigger.count * 2)
        XCTAssertEqual(outcome.results[0].status, .aborted)
        XCTAssertEqual(outcome.results[1].status, .notRun)
    }

    func testRunDeadlineAborts() {
        let r = rig(timeout: 1)
        let outcome = r.runner.run(only("plain-input"))
        XCTAssertEqual(outcome.abort, .timeout(seconds: 1))
        XCTAssertEqual(outcome.results[0].status, .aborted)
    }

    func testClipboardLeftModifiedIsAFailureAndIsPutBack() {
        let r = rig()
        let original = r.clipboard.current
        r.keyboard.onPost = { [unowned r] e in
            r.page.typedKey(e)
            if r.page.values[.plain] == r.spec.expansion {
                r.clipboard.overwrite(ClipboardSnapshot(items: [["public.utf8-plain-text": Data(r.spec.expansion.utf8)]]))
            }
        }
        let result = r.runner.run(only("plain-input")).results[0]
        XCTAssertEqual(result.status, .fail)
        XCTAssertTrue(result.clipboard.isFailure)
        XCTAssertTrue(result.summary.contains("clipboard"))
        XCTAssertEqual(r.clipboard.current, original, "the harness restores the user's clipboard")
        XCTAssertFalse(result.clipboard.summary.contains("keep me"), "contents are never printed")
    }

    func testCleanClipboardIsReportedRestored() {
        let r = rig()
        XCTAssertEqual(r.runner.run(only("plain-input")).results[0].clipboard, .restored(r.clipboard.current.summary))
    }

    func testAICaseIsSkippedNotPassedWhenAIIsOff() {
        let r = rig(ai: .unavailable("AI is off in DevType"))
        let result = r.runner.run(only("ai-proofread")).results[0]
        XCTAssertEqual(result.status, .skip)
        XCTAssertTrue(result.summary.contains("not passed"))
        XCTAssertEqual(r.keyboard.events.count, 0)
    }

    func testHeldModifierCaseHoldsTheModifierDuringTheExpansionThenReleasesIt() {
        let r = rig()
        let outcome = r.runner.run(only("held-shift-at-paste"))
        XCTAssertEqual(outcome.results[0].status, .pass, outcome.results[0].summary)
        let events = r.keyboard.events
        let down = events.firstIndex { $0.keyCode == 56 && $0.down }
        let up = events.firstIndex { $0.keyCode == 56 && !$0.down }
        XCTAssertEqual(down, spec.trigger.count * 2, "shift goes down right after the last trigger key is released")
        XCTAssertNotNil(up)
        XCTAssertGreaterThan(up ?? 0, down ?? 0)
        XCTAssertEqual(outcome.results[0].chords, ["not observed: no chord observer"])
    }

    func testAbortWhileAModifierIsHeldStillReleasesIt() {
        let r = rig()
        r.keyboard.onPost = { [unowned r] e in
            r.page.typedKey(e)
            if e.keyCode == 58, e.down { r.page.snapshot.frontBundleID = "com.apple.Terminal" }
        }
        let outcome = r.runner.run(only("held-option-at-paste"))
        XCTAssertNotNil(outcome.abort)
        XCTAssertGreaterThan(r.keyboard.releases, 0)
    }

    func testSecurePasswordCaseWithNoExpansionPasses() {
        let r = rig()
        r.page.expandOnTrigger = false
        let result = r.runner.run(only("secure-password-field")).results[0]
        XCTAssertEqual(result.status, .pass, result.summary)
    }

    func testDryRunLabelsEveryCaseDRYAndNeverClaimsAPass() {
        let r = rig(mode: .dryRun)
        let results = r.runner.run(CaseTable.select(ids: ["plain-input", "secure-password-field"])).results
        XCTAssertTrue(results.allSatisfy { $0.status == .dryRun })
        XCTAssertTrue(results.allSatisfy { $0.summary.hasPrefix("dry run:") })
    }

    func testDryRunOfTheAICaseRecordsItsKeysAndDoesNotWaitForAPaletteThatNeverOpens() {
        let r = rig(mode: .dryRun, ai: .available)
        let result = r.runner.run(only("ai-proofread")).results[0]
        XCTAssertEqual(result.status, .dryRun, result.summary)
        // hotkey chord (6) + "proofread" (9 chars x 2) + Return (2)
        XCTAssertEqual(r.keyboard.events.count, AIHotkey.default.events.count + 18 + 2)
        XCTAssertEqual(result.plannedEvents, r.keyboard.events.count)
        XCTAssertEqual(result.plannedEvents, Planner.plannedEventCount(only("ai-proofread")[0], spec: spec, hotkey: .default))
    }

    func testSpaCaseSimulatedLandingFailsAndSimulatedRefusalPasses() {
        let landed = rig()
        landed.keyboard.onPost = { [unowned landed] e in
            landed.page.snapshot.focusedDOMID = "dth-spa-immediate-a"
            landed.page.typedKey(e)
            landed.page.values[.spaImmediateB] = landed.page.values[.spaImmediateA]
        }
        XCTAssertEqual(landed.runner.run(only("spa-swap-immediate")).results[0].status, .fail)

        let refused = rig()
        refused.page.expandOnTrigger = false
        refused.keyboard.onPost = { [unowned refused] e in
            refused.page.snapshot.focusedDOMID = "dth-spa-immediate-a"
            refused.page.typedKey(e)
            refused.page.values[.spaImmediateB] = refused.page.values[.spaImmediateA]
        }
        XCTAssertEqual(refused.runner.run(only("spa-swap-immediate")).results[0].status, .pass)
    }
}

final class ReportAndOptionsTests: XCTestCase {
    private func result(_ id: String, _ status: CaseStatus) -> CaseResult {
        CaseResult(id: id, title: id, status: status, summary: "s", started: Date(), ended: Date())
    }

    func testExitCodeNeverTreatsSkipErrorOrAbortAsAPass() {
        XCTAssertEqual(ReportRenderer.exitCode([result("a", .pass), result("b", .skip)], mode: .live, abort: nil), 0)
        XCTAssertEqual(ReportRenderer.exitCode([result("a", .pass), result("b", .fail)], mode: .live, abort: nil), 1)
        XCTAssertEqual(ReportRenderer.exitCode([result("a", .error)], mode: .live, abort: nil), 1)
        XCTAssertEqual(ReportRenderer.exitCode([result("a", .pass), result("b", .notRun)], mode: .live, abort: nil), 3)
        XCTAssertEqual(ReportRenderer.exitCode([result("a", .pass)], mode: .live, abort: .escapePressed), 3)
        XCTAssertEqual(ReportRenderer.exitCode([result("a", .dryRun)], mode: .dryRun, abort: nil), 0)
    }

    func testReportCarriesTableLogsAndTheUnitsAssertion() {
        var r = result("plain-input", .pass)
        r.fields = ["dth-plain: ax=\"[[X]]\" js=n/a"]
        let header = ReportHeader(mode: .live, started: Date(), finished: Date(),
                                  preflight: [PreflightRow(name: "Safari installed", ok: true, detail: "/Applications/Safari.app"),
                                              PreflightRow(name: "Accessibility", ok: false, detail: "no", remedy: "grant Terminal")],
                                  seed: 5, trigger: ";t", pageReadMode: "AX only", libraryOutcome: "unchanged", libraryBackup: "b",
                                  clipboardFinal: "unchanged", abort: nil, notes: ["n"])
        let logs = CollectedLogs(perCase: ["plain-input": (["[SourceFocus] read after 3 ms"], 2)],
                                 unitsLine: "[Debounce] event timestamp units ratio=1.0000",
                                 unitsVerdict: .nanoseconds(ratio: 1), outcomes: ["plain-input": [.succeeded]], queryNote: "q")
        let text = ReportRenderer.render(header: header, results: [r], logs: logs)
        for needle in ["PREFLIGHT", "-> grant Terminal", "plain-input", "PASS", "TIMESTAMP UNITS  PASS", "[SourceFocus]",
                       "2 more dropped by the per-case cap", "inject outcomes in the log: succeeded", "library:", "LOG QUERY"] {
            XCTAssertTrue(text.contains(needle), needle)
        }
    }

    func testOptionsParsing() throws {
        XCTAssertEqual(try Options.parse([]).command, .help)
        let o = try Options.parse(["--live", "--only", "plain-input,textarea", "--timeout", "90", "--no-js", "--seed", "4", "--trigger", ";zzzz"])
        XCTAssertEqual(o.command, .live)
        XCTAssertEqual(o.only, ["plain-input", "textarea"])
        XCTAssertEqual(o.timeoutSeconds, 90)
        XCTAssertTrue(o.noJS)
        XCTAssertEqual(o.seed, 4)
        XCTAssertEqual(o.trigger, ";zzzz")
        XCTAssertThrowsError(try Options.parse(["--bogus"]))
        XCTAssertThrowsError(try Options.parse(["--only", "nope"]))
        XCTAssertThrowsError(try Options.parse(["--timeout", "5"]))
        XCTAssertThrowsError(try Options.parse(["--trigger"]))
    }

    func testNothingRunsLiveUnlessAskedFor() throws {
        XCTAssertNotEqual(try Options.parse(["--dry-run"]).command, .live)
        XCTAssertNotEqual(try Options.parse([]).command, .live)
    }
}
