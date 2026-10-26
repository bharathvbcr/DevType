import Foundation

public enum Step: Equatable, Sendable {
    /// Presses the page's reset button through AX: clears every field and restores the SPA widgets.
    case reset
    case focus(PageField)
    case pause(ms: Int)
    case typeTrigger(Pace)
    case typeLiteral(String, Pace)
    /// Types the trigger, then presses the modifier at the instant the last key is released, so the
    /// modifier is down while the expansion runs. Typing the trigger under a held modifier would
    /// change its characters and it would not match.
    case typeTriggerThenHold(Modifier, Pace)
    case releaseModifier(Modifier)
    /// Records whether the system's Secure Event Input is on right now.
    case recordSecureInput
    case selectAll(PageField)
    /// Opens DevType's AI palette with its hotkey, picks Proofread, waits for the rewrite.
    case aiProofread
}

public enum Check: Equatable, Sendable {
    /// The field holds exactly `count` expansions followed by `suffix`.
    case expansions(PageField, count: Int, suffix: String, trimTrailingNewline: Bool)
    /// The expansion must not appear in `b`, the control that replaced `a` in the same frame.
    case spaNotLanded(a: PageField, b: PageField)
    /// The trigger typed into a password field stays literal.
    case passwordNotExpanded(PageField)
    /// The selected text was rewritten, once, and nothing else was added.
    case aiRewrote(PageField)

    public var fields: [PageField] {
        switch self {
        case .expansions(let f, _, _, _), .passwordNotExpanded(let f), .aiRewrote(let f): return [f]
        case .spaNotLanded(let a, let b): return [a, b]
        }
    }
}

public struct HarnessCase: Equatable, Sendable {
    public let id: String
    public let title: String
    /// What a failure here would mean for a user.
    public let proves: String
    public let steps: [Step]
    public let check: Check
    public let needsAI: Bool
    public let observesChords: Bool
    public let deadlineSeconds: Double

    public init(id: String, title: String, proves: String, steps: [Step], check: Check,
                needsAI: Bool = false, observesChords: Bool = false, deadlineSeconds: Double = 60) {
        self.id = id
        self.title = title
        self.proves = proves
        self.steps = steps
        self.check = check
        self.needsAI = needsAI
        self.observesChords = observesChords
        self.deadlineSeconds = deadlineSeconds
    }
}

public enum CaseTable {
    /// The text the page pre-fills into the AI field. Mirrors `AI_TEXT` in the fixture; a contract
    /// test keeps the two equal.
    public static let aiOriginalText = "teh quick brown fox jumpd over teh lazy dog"

    public static func all() -> [HarnessCase] {
        let single = { (field: PageField, trim: Bool) in Check.expansions(field, count: 1, suffix: "", trimTrailingNewline: trim) }
        let prelude = { (field: PageField) -> [Step] in [.reset, .focus(field), .pause(ms: 300)] }
        return [
            HarnessCase(
                id: "plain-input", title: "Plain <input>",
                proves: "An expansion lands in an ordinary text field in Safari.",
                steps: prelude(.plain) + [.typeTrigger(.human), .pause(ms: 2000)],
                check: single(.plain, false)),
            HarnessCase(
                id: "textarea", title: "<textarea>",
                proves: "An expansion lands in a multi-line text field.",
                steps: prelude(.area) + [.typeTrigger(.human), .pause(ms: 2000)],
                check: single(.area, false)),
            HarnessCase(
                id: "contenteditable", title: "contenteditable <div>",
                proves: "An expansion lands in rich-text editing surfaces (mail composers, chat boxes).",
                steps: prelude(.editable) + [.typeTrigger(.human), .pause(ms: 2000)],
                check: single(.editable, true)),
            HarnessCase(
                id: "rerender-input", title: "Field that replaces its DOM node on every input",
                proves: "The expansion survives the WebKit node swap: the element DevType verified is replaced by an identical one mid-typing.",
                steps: prelude(.rerender) + [.typeTrigger(.human), .pause(ms: 2500)],
                check: single(.rerender, false)),
            HarnessCase(
                id: "spa-swap-immediate", title: "SPA swap to a different control, on the last trigger character",
                proves: "An expansion verified against one control is refused when a different control now holds the same frame.",
                steps: prelude(.spaImmediateA) + [.typeTrigger(.human), .pause(ms: 2500)],
                check: .spaNotLanded(a: .spaImmediateA, b: .spaImmediateB)),
            HarnessCase(
                id: "spa-swap-delayed", title: "SPA swap to a different control, 60 ms later (mid-expansion)",
                proves: "The same refusal when the swap lands while the erase and paste are already in flight.",
                steps: prelude(.spaDelayedA) + [.typeTrigger(.human), .pause(ms: 2500)],
                check: .spaNotLanded(a: .spaDelayedA, b: .spaDelayedB)),
            HarnessCase(
                id: "two-triggers-fast", title: "Two triggers back to back, no pause",
                proves: "Type-ahead and the pasteboard hold-off: the second trigger typed while the first expansion is in flight still expands, in order.",
                steps: prelude(.plain) + [.typeTrigger(.fast), .typeTrigger(.fast), .pause(ms: 3500)],
                check: .expansions(.plain, count: 2, suffix: "", trimTrailingNewline: false)),
            HarnessCase(
                id: "two-triggers-paced", title: "Two triggers 350 ms apart",
                proves: "Baseline for the fast case: two ordinary expansions in a row.",
                steps: prelude(.plain) + [.typeTrigger(.human), .pause(ms: 350), .typeTrigger(.human), .pause(ms: 2500)],
                check: .expansions(.plain, count: 2, suffix: "", trimTrailingNewline: false)),
            HarnessCase(
                id: "type-during-expansion", title: "Typing continues during the expansion",
                proves: "Characters typed after the trigger while it expands are neither lost nor reordered.",
                steps: prelude(.plain) + [.typeTrigger(.human), .typeLiteral("xyz", .fast), .pause(ms: 2500)],
                check: .expansions(.plain, count: 1, suffix: "xyz", trimTrailingNewline: false)),
            HarnessCase(
                id: "secure-password-field", title: "Trigger typed into a password field",
                proves: "With Secure Event Input on, nothing expands and the trigger stays literal.",
                steps: prelude(.password) + [.pause(ms: 300), .recordSecureInput, .typeTrigger(.human), .pause(ms: 1500)],
                check: .passwordNotExpanded(.password)),
            HarnessCase(
                id: "secure-released", title: "Back to a normal field after the password field",
                proves: "Leaving a password field turns expansion back on without relaunching anything.",
                steps: [.reset, .focus(.password), .pause(ms: 600), .focus(.plain), .pause(ms: 800), .recordSecureInput,
                        .typeTrigger(.human), .pause(ms: 2000)],
                check: single(.plain, false)),
            HarnessCase(
                id: "held-shift-at-paste", title: "Shift held while the expansion runs",
                proves: "The paste is not turned into Paste and Match Style (shift-command-V) by a physically held Shift.",
                steps: prelude(.plain) + [.typeTriggerThenHold(.shift, .human), .pause(ms: 2200), .releaseModifier(.shift), .pause(ms: 400)],
                check: single(.plain, false), observesChords: true),
            HarnessCase(
                id: "held-option-at-paste", title: "Option held while the expansion runs",
                proves: "A held Option does not change the paste chord (option-command-V variants differ by app).",
                steps: prelude(.plain) + [.typeTriggerThenHold(.option, .human), .pause(ms: 2200), .releaseModifier(.option), .pause(ms: 400)],
                check: single(.plain, false), observesChords: true),
            HarnessCase(
                id: "ai-proofread", title: "AI proofread on a selection",
                proves: "Select text in Safari, open the AI palette with its hotkey, pick Proofread: the selection is replaced once, with a rewrite.",
                steps: [.reset, .focus(.ai), .pause(ms: 300), .selectAll(.ai), .pause(ms: 300), .aiProofread],
                check: .aiRewrote(.ai), needsAI: true, deadlineSeconds: 150)
        ]
    }

    public static func select(ids: [String]?) -> [HarnessCase] {
        guard let ids, !ids.isEmpty else { return all() }
        return all().filter { ids.contains($0.id) }
    }
}

/// One control as the harness read it. A source that could not be read is nil, never an empty string.
public struct FieldReading: Equatable, Sendable {
    public let field: PageField
    public var axValue: String?
    public var jsValue: String?
    public var caret: Int?
    public var axRole: String?
    public var note: String?

    public init(field: PageField, axValue: String? = nil, jsValue: String? = nil, caret: Int? = nil, axRole: String? = nil, note: String? = nil) {
        self.field = field
        self.axValue = axValue
        self.jsValue = jsValue
        self.caret = caret
        self.axRole = axRole
        self.note = note
    }

    public var hasAnyValue: Bool { axValue != nil || jsValue != nil }

    public var dump: String {
        func q(_ s: String?) -> String { s.map { String(reflecting: $0) } ?? "unreadable" }
        var out = "\(field.domID): ax=\(q(axValue)) js=\(jsValue == nil ? "n/a" : q(jsValue))"
        if let caret { out += " caret=\(caret)" }
        if let note { out += " (\(note))" }
        return out
    }
}

public enum CaseStatus: String, Equatable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case skip = "SKIP"
    case error = "ERROR"
    case aborted = "ABORT"
    case notRun = "NOT RUN"
    case dryRun = "DRY"
}

public struct Verdict: Equatable, Sendable {
    public let pass: Bool
    /// `true` when the condition the case needs was never established, so neither pass nor fail is meaningful.
    public let inconclusive: Bool
    public let summary: String

    static func pass(_ s: String) -> Verdict { Verdict(pass: true, inconclusive: false, summary: s) }
    static func fail(_ s: String) -> Verdict { Verdict(pass: false, inconclusive: false, summary: s) }
    static func inconclusive(_ s: String) -> Verdict { Verdict(pass: false, inconclusive: true, summary: s) }
}

public enum Evaluator {
    public static func evaluate(
        _ check: Check,
        readings: [PageField: FieldReading],
        spec: HarnessSnippetSpec,
        secureInputWasOn: Bool?
    ) -> Verdict {
        switch check {
        case .expansions(let field, let count, let suffix, let trim):
            guard let reading = readings[field], reading.hasAnyValue else {
                return .inconclusive("\(field.domID) could not be read through AX or the page")
            }
            let expected = String(repeating: spec.expansion, count: count) + suffix
            return perSource(reading) { value in
                let v = trim && value.hasSuffix("\n") ? String(value.dropLast()) : value
                return v == expected ? nil : explain(v, expected: expected, count: count, suffix: suffix, spec: spec)
            }
        case .spaNotLanded(let a, let b):
            let readingA = readings[a], readingB = readings[b]
            guard let readingB, readingB.hasAnyValue else {
                return .inconclusive("the replacement control \(b.domID) was never found, so the page did not swap (page script blocked, or typing never reached the field)")
            }
            let landed = [readingB.axValue, readingB.jsValue].compactMap { $0 }.contains { $0.contains(spec.expansion) }
            let aValue = readingA.flatMap { $0.jsValue ?? $0.axValue }
            let tail = " (\(a.domID) held \(aValue.map { String(reflecting: $0) } ?? "nothing: replaced"); \(b.domID) held \(String(reflecting: readingB.jsValue ?? readingB.axValue ?? "")))"
            if landed { return .fail("the expansion LANDED in the replacement control" + tail) }
            let carried = readingB.jsValue ?? readingB.axValue ?? ""
            let damage = carried.count < spec.trigger.count && carried != spec.trigger
            return .pass("expansion did not land in the replacement control" + tail + (damage ? " NOTE: the replacement control lost characters it was handed" : ""))
        case .passwordNotExpanded(let field):
            guard let reading = readings[field], reading.hasAnyValue else {
                return .inconclusive("\(field.domID) could not be read")
            }
            if secureInputWasOn == false {
                return .inconclusive("Secure Event Input was not on while the password field was focused, so this case cannot show what DevType does under it")
            }
            var failures: [String] = []
            if let js = reading.jsValue, js != spec.trigger {
                failures.append(js.contains(spec.expansion) ? "page value contains the expansion" : "page value is \(String(reflecting: js)), not the literal trigger")
            }
            if let ax = reading.axValue {
                if ax.contains(spec.expansion) { failures.append("AX value contains the expansion") }
                else if ax.count != spec.trigger.count { failures.append("AX value has \(ax.count) characters, the trigger has \(spec.trigger.count)") }
            }
            let secure = secureInputWasOn.map { $0 ? "Secure Event Input on" : "Secure Event Input off" } ?? "Secure Event Input state unknown"
            return failures.isEmpty ? .pass("trigger stayed literal (\(secure))") : .fail(failures.joined(separator: "; ") + " (\(secure))")
        case .aiRewrote(let field):
            guard let reading = readings[field], reading.hasAnyValue else {
                return .inconclusive("\(field.domID) could not be read")
            }
            let original = CaseTable.aiOriginalText
            return perSource(reading) { value in
                if value == original { return "unchanged: the rewrite never landed (palette not opened, model unavailable, or the pick missed)" }
                if value.isEmpty { return "the field is empty: the selection was deleted and nothing replaced it" }
                if value.contains(original) { return "the original text is still present: the rewrite was inserted instead of replacing it" }
                if value.contains(spec.expansion) { return "contains the snippet expansion" }
                let ratio = Double(value.count) / Double(original.count)
                if ratio < 0.5 || ratio > 2.0 { return "length \(value.count) vs \(original.count) is not a proofread of the text (possible duplication or truncation)" }
                let lower = value.lowercased()
                if !lower.contains("quick") || !lower.contains("fox") { return "key words of the original are gone: \(String(reflecting: value))" }
                return nil
            }
        }
    }

    /// Passes only if every source that could be read passes. Disagreement between AX and the page
    /// is itself reported.
    private static func perSource(_ reading: FieldReading, judge: (String) -> String?) -> Verdict {
        var failures: [String] = []
        var passes: [String] = []
        for (label, value) in [("ax", reading.axValue), ("js", reading.jsValue)] {
            guard let value else { continue }
            if let problem = judge(value) { failures.append("\(label): \(problem)") } else { passes.append(label) }
        }
        if failures.isEmpty { return .pass("holds exactly the expected text (\(passes.joined(separator: "+")))") }
        return .fail(failures.joined(separator: "; "))
    }

    static func explain(_ value: String, expected: String, count: Int, suffix: String, spec: HarnessSnippetSpec) -> String {
        let quoted = String(reflecting: value)
        if value.isEmpty { return "field is empty, expected \(String(reflecting: expected))" }
        let occurrences = value.components(separatedBy: spec.expansion).count - 1
        if occurrences > count { return "expansion appears \(occurrences) times, expected \(count): \(quoted)" }
        if occurrences == 0 {
            if value.contains(spec.trigger) { return "nothing expanded, the trigger is still in the field: \(quoted)" }
            return "no expansion in the field: \(quoted)"
        }
        if value.contains(spec.trigger) { return "\(occurrences) of \(count) expansions, and a literal trigger was left behind: \(quoted)" }
        if occurrences == count { return "expansion present but surrounding text differs, expected \(String(reflecting: expected)): \(quoted)" }
        return "\(occurrences) of \(count) expansions: \(quoted)"
    }
}
