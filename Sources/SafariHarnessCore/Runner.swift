import Foundation

// MARK: - Ports

/// Posts one keyboard event. The live implementation posts at the HID tap; the dry run records.
public protocol KeyboardPort: AnyObject {
    func post(_ event: KeyEvent) throws
    /// Releases any modifier the harness pressed. Cleanup only: bypasses the focus guard because
    /// leaving Shift stuck down is worse than one stray key-up.
    func releaseHeldModifiers()
}

public protocol PagePort: AnyObject {
    func focusSnapshot() throws -> FocusSnapshot
    func reset() throws
    func focus(_ field: PageField) throws
    func read(_ field: PageField) -> FieldReading
    /// Selects all text in the field and returns what AX reports as selected.
    func selectAll(_ field: PageField) throws -> String?
    func secureInputEnabled() -> Bool
    /// Page-side event log lines since the last call (empty when JavaScript is unavailable).
    func drainPageLog() -> [String]
}

public struct ChordRecord: Equatable, Sendable {
    public let keyCode: UInt16
    public let down: Bool
    public let flags: ModifierMask
    public let at: Date

    public init(keyCode: UInt16, down: Bool, flags: ModifierMask, at: Date) {
        self.keyCode = keyCode
        self.down = down
        self.flags = flags
        self.at = at
    }
}

/// Watches the events DevType itself posts (the ones carrying its synthetic marker).
public protocol ChordObserverPort: AnyObject {
    /// Why observation is unavailable, or nil when it is running.
    var unavailableReason: String? { get }
    func drain() -> [ChordRecord]
}

public struct Clock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Double) -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Double) -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = Clock(now: { Date() }, sleep: { Thread.sleep(forTimeInterval: $0) })
}

// MARK: - Context and results

public enum RunMode: Equatable, Sendable { case live, dryRun }

public enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

public struct RunContext: Sendable {
    public var mode: RunMode
    public var spec: HarnessSnippetSpec
    public var fixturePath: String
    public var devTypePID: Int32?
    public var ai: AIAvailability
    public var hotkey: AIHotkey
    public var seed: UInt64

    public init(mode: RunMode, spec: HarnessSnippetSpec, fixturePath: String, devTypePID: Int32?,
                ai: AIAvailability, hotkey: AIHotkey, seed: UInt64) {
        self.mode = mode
        self.spec = spec
        self.fixturePath = fixturePath
        self.devTypePID = devTypePID
        self.ai = ai
        self.hotkey = hotkey
        self.seed = seed
    }
}

public struct CaseResult: Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: CaseStatus
    public var summary: String
    public var fields: [String] = []
    public var clipboard: ClipboardVerdict = .unchecked("not run")
    public var notes: [String] = []
    public var pageEvents: [String] = []
    public var chords: [String] = []
    public var started: Date
    public var ended: Date
    public var plannedEvents: Int = 0

    public init(id: String, title: String, status: CaseStatus, summary: String, started: Date, ended: Date) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.started = started
        self.ended = ended
    }
}

public struct RunOutcome: Equatable, Sendable {
    public var results: [CaseResult]
    public var abort: AbortReason?
}

private struct SkipCase: Error { let reason: String }
private struct CaseError: Error { let message: String }

// MARK: - Runner

/// Executes the case table through the ports. Every posted event first passes `AbortController`
/// and `FocusSafety`; a refusal latches the abort, stops all posting, and the remaining cases are
/// reported as not run. Clipboard is checked after every case and restored if DevType left
/// something else on it.
public final class Runner {
    private let keyboard: KeyboardPort
    private let page: PagePort
    private let clipboard: ClipboardPort
    private let chords: ChordObserverPort?
    private let abort: AbortController
    private let clock: Clock
    private let context: RunContext
    private var rng: JitterRNG
    private var posted = 0
    private var pressedModifiers: Set<Modifier> = []
    private var keyDownTimes: [Date] = []
    private var lastGuardSeconds = 0.0
    private var secureInputWasOn: Bool?
    private var selectedByAX: String?

    /// How many times a momentarily unreadable focus is re-read before a key is refused.
    static let guardAttempts = 4
    static let guardRetrySeconds = 0.010
    static let clipboardSettleSeconds = 3.0

    public init(keyboard: KeyboardPort, page: PagePort, clipboard: ClipboardPort, chords: ChordObserverPort?,
                abort: AbortController, clock: Clock, context: RunContext) {
        self.keyboard = keyboard
        self.page = page
        self.clipboard = clipboard
        self.chords = chords
        self.abort = abort
        self.clock = clock
        self.context = context
        self.rng = JitterRNG(seed: context.seed)
    }

    public func run(_ cases: [HarnessCase]) -> RunOutcome {
        var results: [CaseResult] = []
        for testCase in cases {
            if let reason = abort.tripped {
                let now = clock.now()
                results.append(CaseResult(id: testCase.id, title: testCase.title, status: .notRun,
                                          summary: "not run: \(reason)", started: now, ended: now))
                continue
            }
            results.append(runCase(testCase))
        }
        keyboard.releaseHeldModifiers()
        return RunOutcome(results: results, abort: abort.tripped)
    }

    // MARK: Case

    private func runCase(_ testCase: HarnessCase) -> CaseResult {
        let started = clock.now()
        var result = CaseResult(id: testCase.id, title: testCase.title, status: .error, summary: "", started: started, ended: started)
        posted = 0
        keyDownTimes = []
        if testCase.observesChords { _ = chords?.drain() }
        secureInputWasOn = nil
        selectedByAX = nil

        if testCase.needsAI, case .unavailable(let why) = context.ai {
            result.status = .skip
            result.summary = "skipped, not passed: \(why)"
            result.clipboard = .unchecked("case skipped")
            result.ended = clock.now()
            return result
        }

        let before: ClipboardSnapshot?
        do { before = try clipboard.snapshot() } catch {
            before = nil
            result.notes.append("clipboard could not be read before the case: \(error)")
        }

        var verdict: Verdict?
        var failure: (CaseStatus, String)?
        do {
            for step in testCase.steps {
                try abort.check()
                try execute(step)
            }
            try abort.check()
            verdict = judge(testCase, into: &result)
        } catch let stop as HarnessAbort {
            failure = (.aborted, stop.description)
        } catch let skip as SkipCase {
            failure = (.skip, "skipped, not passed: \(skip.reason)")
        } catch let error as CaseError {
            failure = (.error, error.message)
        } catch {
            failure = (.error, "\(error)")
        }

        keyboard.releaseHeldModifiers()
        pressedModifiers.removeAll()
        if failure == nil || failure?.0 == .aborted {
            // Read what is there even after an abort: it is the evidence of where the run stopped.
            if result.fields.isEmpty { _ = judge(testCase, into: &result, evaluate: false) }
        }
        result.clipboard = settleClipboard(before)
        result.pageEvents = Array(page.drainPageLog().prefix(60))
        if testCase.observesChords {
            result.chords = chordLines()
        }
        result.plannedEvents = posted
        result.notes.append(contentsOf: paceNotes())
        result.ended = clock.now()

        if let (status, summary) = failure {
            result.status = status
            result.summary = summary
        } else if let verdict {
            switch context.mode {
            case .dryRun:
                result.status = .dryRun
                result.summary = "dry run: \(posted) key events were built and checked but none posted; the check on the untouched page would say: \(verdict.summary)"
            case .live:
                if verdict.inconclusive {
                    result.status = .error
                    result.summary = "inconclusive: \(verdict.summary)"
                } else if !verdict.pass {
                    result.status = .fail
                    result.summary = verdict.summary
                } else if result.clipboard.isFailure {
                    result.status = .fail
                    result.summary = verdict.summary + "; but the clipboard was not restored"
                } else {
                    result.status = .pass
                    result.summary = verdict.summary
                }
            }
        }
        return result
    }

    @discardableResult
    private func judge(_ testCase: HarnessCase, into result: inout CaseResult, evaluate: Bool = true) -> Verdict? {
        var readings: [PageField: FieldReading] = [:]
        for field in testCase.check.fields {
            let reading = page.read(field)
            readings[field] = reading
            result.fields.append(reading.dump)
        }
        guard evaluate else { return nil }
        return Evaluator.evaluate(testCase.check, readings: readings, spec: context.spec, secureInputWasOn: secureInputWasOn)
    }

    private func settleClipboard(_ before: ClipboardSnapshot?) -> ClipboardVerdict {
        guard let before else { return .unchecked("clipboard unreadable before the case") }
        var waited = 0.0
        var current: ClipboardSnapshot
        repeat {
            do { current = try clipboard.snapshot() } catch { return .unchecked("clipboard unreadable after the case: \(error)") }
            if current == before { return .restored(before.summary) }
            if waited >= Self.clipboardSettleSeconds { break }
            clock.sleep(0.2)
            waited += 0.2
        } while true
        do { try clipboard.restore(before) } catch {
            return .modified(before: before.summary, after: current.summary + " (and the harness could not put it back: \(error))")
        }
        return .modified(before: before.summary, after: current.summary)
    }

    private func chordLines() -> [String] {
        guard let chords else { return ["not observed: no chord observer"] }
        if let why = chords.unavailableReason { return ["not observed: \(why)"] }
        let records = chords.drain()
        if records.isEmpty { return ["observer ran but saw no event carrying DevType's synthetic marker (the expansion used the AX write path, not a paste chord)"] }
        return records.map { r in
            "DevType posted keyCode \(r.keyCode) \(r.down ? "down" : "up") flags=[\(r.flags.names.joined(separator: "+"))]"
        }
    }

    private func paceNotes() -> [String] {
        guard keyDownTimes.count >= 2 else { return [] }
        let gaps = zip(keyDownTimes, keyDownTimes.dropFirst()).map { $1.timeIntervalSince($0) * 1000 }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        return [String(format: "typed %d keys; effective key-to-key gap min %.0f / mean %.0f / max %.0f ms", keyDownTimes.count, gaps.min() ?? 0, mean, gaps.max() ?? 0)]
    }

    // MARK: Steps

    private func execute(_ step: Step) throws {
        switch step {
        case .reset:
            try page.reset()
        case .focus(let field):
            guard field.acceptsTyping else { throw CaseError(message: "\(field.domID) is not a typing target") }
            try page.focus(field)
        case .pause(let ms):
            try wait(Double(ms) / 1000)
        case .typeTrigger(let pace):
            try type(context.spec.trigger, pace: pace, policy: .harnessPage(fixturePath: context.fixturePath))
        case .typeLiteral(let text, let pace):
            try type(text, pace: pace, policy: .harnessPage(fixturePath: context.fixturePath))
        case .typeTriggerThenHold(let modifier, let pace):
            try type(context.spec.trigger, pace: pace, policy: .harnessPage(fixturePath: context.fixturePath), leadingGap: true)
            pressedModifiers.insert(modifier)
            try post(KeyEvent(keyCode: modifier.keyCode, down: true, flags: modifier.mask),
                     policy: .harnessPage(fixturePath: context.fixturePath))
        case .releaseModifier(let modifier):
            guard pressedModifiers.contains(modifier) else { return }
            pressedModifiers.remove(modifier)
            try post(KeyEvent(keyCode: modifier.keyCode, down: false),
                     policy: .harnessPage(fixturePath: context.fixturePath))
        case .recordSecureInput:
            secureInputWasOn = page.secureInputEnabled()
        case .selectAll(let field):
            selectedByAX = try page.selectAll(field)
            guard selectedByAX == CaseTable.aiOriginalText else {
                throw CaseError(message: "AX reports \(selectedByAX.map { "\($0.count) selected characters" } ?? "no selection") instead of the field's full text, so there is nothing valid to proofread")
            }
        case .aiProofread:
            try runAIProofread()
        }
    }

    private func wait(_ seconds: Double) throws {
        var remaining = seconds
        while remaining > 0 {
            try abort.check()
            let slice = min(remaining, 0.005)
            clock.sleep(slice)
            remaining -= slice
        }
        try abort.check()
    }

    /// Sleeps for what is left of a pacing interval after the focus guard's own cost.
    private func pace(_ ms: Int) throws {
        try wait(max(0, Double(ms) / 1000 - lastGuardSeconds))
    }

    private func type(_ text: String, pace: Pace, policy: FocusPolicy, leadingGap: Bool = true) throws {
        if leadingGap { try self.pace(pace.sampleGap(&rng)) }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            for event in try KeyPlan.events(for: character) {
                try post(event, policy: policy)
                let isModifierKey = Modifier.allCases.contains { $0.keyCode == event.keyCode }
                if event.down, !isModifierKey { try self.pace(pace.sampleHold(&rng)) }
            }
            if index < characters.count - 1 { try self.pace(pace.sampleGap(&rng)) }
        }
    }

    /// The only function that posts. Abort, then focus, then the key.
    private func post(_ event: KeyEvent, policy: FocusPolicy) throws {
        try abort.check()
        try requireSafeFocus(policy)
        try keyboard.post(event)
        posted += 1
        if event.down, !Modifier.allCases.contains(where: { $0.keyCode == event.keyCode }) {
            keyDownTimes.append(clock.now())
        }
    }

    private func requireSafeFocus(_ policy: FocusPolicy) throws {
        let began = clock.now()
        defer { lastGuardSeconds = clock.now().timeIntervalSince(began) }
        var lastDenial = "focus could not be read"
        for attempt in 0..<Self.guardAttempts {
            do {
                switch FocusSafety.decide(try page.focusSnapshot(), policy: policy) {
                case .allow: return
                case .deny(let why): lastDenial = why
                }
            } catch {
                lastDenial = "focus could not be read: \(error)"
            }
            if attempt < Self.guardAttempts - 1 { clock.sleep(Self.guardRetrySeconds) }
        }
        abort.trip(.unsafeFocus(lastDenial))
        throw HarnessAbort(reason: .unsafeFocus(lastDenial))
    }

    // MARK: AI

    private func runAIProofread() throws {
        guard let pid = context.devTypePID else { throw CaseError(message: "DevType's process id is unknown, so the palette cannot be recognised") }
        let pagePolicy = FocusPolicy.harnessPage(fixturePath: context.fixturePath)
        let palettePolicy = FocusPolicy.devTypePalette(devTypePID: pid)

        for event in context.hotkey.events { try post(event, policy: pagePolicy) }

        if context.mode == .dryRun {
            // The palette never opens without a posted hotkey, and the focus gate would rightly refuse
            // keys aimed at it. Record what would be typed so the plan and counts are complete.
            for character in "proofread" { for event in try KeyPlan.events(for: character) { try keyboard.post(event); posted += 1 } }
            for down in [true, false] { try keyboard.post(KeyEvent(keyCode: KeyPlan.returnKey, down: down)); posted += 1 }
            return
        }

        guard try waitUntil(timeout: 3.0, { isAllowed(palettePolicy) }) else {
            throw CaseError(message: "DevType's AI palette did not open within 3 s of \(context.hotkey.label) (hotkey taken by another app, or Preferences changed since the harness read it)")
        }
        try type("proofread", pace: .human, policy: palettePolicy)
        try pace(150)
        try post(KeyEvent(keyCode: KeyPlan.returnKey, down: true), policy: palettePolicy)
        try post(KeyEvent(keyCode: KeyPlan.returnKey, down: false), policy: palettePolicy)

        let returned = try waitUntil(timeout: 8.0, { isAllowed(pagePolicy) })
        if !returned, isAllowed(palettePolicy) {
            // No action matched (model unavailable lists only local actions). Close our own palette.
            abort.suppressEscape(forSeconds: 0.6)
            try post(KeyEvent(keyCode: KeyPlan.escapeKey, down: true), policy: palettePolicy)
            try post(KeyEvent(keyCode: KeyPlan.escapeKey, down: false), policy: palettePolicy)
            throw CaseError(message: "the palette stayed open after Return; no action matched \"proofread\" (the on-device model may be unavailable). The harness closed it")
        }
        guard returned else { throw CaseError(message: "focus did not return to the harness page after the palette closed") }

        let original = CaseTable.aiOriginalText
        _ = try waitUntil(timeout: 60.0) {
            let reading = page.read(.ai)
            return (reading.jsValue ?? reading.axValue).map { $0 != original } ?? false
        }
        try wait(1.5)
    }

    private func isAllowed(_ policy: FocusPolicy) -> Bool {
        guard let snapshot = try? page.focusSnapshot() else { return false }
        return FocusSafety.decide(snapshot, policy: policy).isAllowed
    }

    private func waitUntil(timeout: Double, _ condition: () -> Bool) throws -> Bool {
        var waited = 0.0
        while true {
            try abort.check()
            if condition() { return true }
            if waited >= timeout { return false }
            try wait(0.1)
            waited += 0.1
        }
    }
}
