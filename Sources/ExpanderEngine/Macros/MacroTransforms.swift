// §3.5: Macro capabilities DevType was missing versus TextExpander / Espanso / Alfred —
// case transforms, random values, UUIDs, and persistent counters.
//
// Deliberately NOT implemented here: **clipboard history** (`{clipboard:1}`). macOS exposes no
// pasteboard history API; the only way to provide it is a persistent polling watcher that
// snapshots `NSPasteboard.general` on a timer and keeps every copied item — including passwords
// from password managers — in DevType's own storage. That is a materially different privacy
// posture from "read the clipboard at expansion time", so the feature is skipped rather than
// half-built. See §3.5.

import Foundation

// MARK: - Case transforms

/// §3.5: Case transform applied to fill-in values, nested snippet output, or any literal text.
///
/// Available as `{{upper:…}}` / `{{lower:…}}` / `{{title:…}}` / `{{sentence:…}}` in the mustache
/// syntax, and as the block form `%case:upper%…%caseend%` in the TextExpander syntax.
public enum TextCaseTransform: String, Equatable, CaseIterable {
    case upper
    case lower
    case title
    case sentence

    /// Case-insensitive lookup used by both parsers. Also accepts a few friendly aliases.
    public static func named(_ raw: String) -> TextCaseTransform? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "upper", "uppercase", "uc": return .upper
        case "lower", "lowercase", "lc": return .lower
        case "title", "titlecase", "capitalize": return .title
        case "sentence", "sentencecase": return .sentence
        default: return nil
        }
    }

    public func apply(to text: String, locale: Locale = .current) -> String {
        guard !text.isEmpty else { return text }
        switch self {
        case .upper: return text.uppercased(with: locale)
        case .lower: return text.lowercased(with: locale)
        case .title: return text.capitalized(with: locale)
        case .sentence: return Self.sentenceCased(text, locale: locale)
        }
    }

    /// Lower-cases everything, then re-capitalizes the first letter of each sentence.
    private static func sentenceCased(_ text: String, locale: Locale) -> String {
        let lowered = text.lowercased(with: locale)
        var result = ""
        result.reserveCapacity(lowered.count)
        var atSentenceStart = true
        for character in lowered {
            if atSentenceStart, character.isLetter {
                result += String(character).uppercased(with: locale)
                atSentenceStart = false
                continue
            }
            result.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                atSentenceStart = true
            }
        }
        return result
    }
}

// MARK: - Random values

/// §3.5: `%random:SPEC%` / `{{random:SPEC}}`.
///
/// | spec | result |
/// |---|---|
/// | *(empty)*    | integer 0–99 |
/// | `1-100`      | integer in the inclusive range |
/// | `a\|b\|c`    | one of the pipe-separated choices (verbatim, whitespace-trimmed) |
/// | `hex:8`      | 8 lowercase hex characters |
/// | `alnum:12`   | 12 alphanumeric characters |
/// | `digits:6`   | 6 digits |
/// | `letters:8`  | 8 lowercase letters |
public enum MacroRandom {

    /// Hard cap so a malformed spec cannot ask for a megabyte of noise mid-expansion.
    public static let maxGeneratedLength = 256

    public static func value(spec rawSpec: String) -> String {
        let spec = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.isEmpty {
            return String(Int.random(in: 0...99))
        }

        // Pipe list wins first: a choice list may legitimately contain "-" or ":".
        if spec.contains("|") {
            let choices = spec.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return choices.randomElement() ?? ""
        }

        if let colon = spec.firstIndex(of: ":") {
            let kind = String(spec[..<colon]).lowercased()
            let countText = String(spec[spec.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let count = min(max(Int(countText) ?? 0, 0), maxGeneratedLength)
            if count > 0, let pool = alphabet(for: kind) {
                return String((0..<count).map { _ in pool.randomElement() ?? "0" })
            }
        }

        if let dash = numericRangeSeparator(in: spec) {
            let lowText = String(spec[..<dash]).trimmingCharacters(in: .whitespaces)
            let highText = String(spec[spec.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
            if let low = Int(lowText), let high = Int(highText) {
                let range = low <= high ? low...high : high...low
                return String(Int.random(in: range))
            }
        }

        // Unrecognized spec — behave like the bare form rather than emitting nothing.
        return String(Int.random(in: 0...99))
    }

    /// Finds the `-` that separates a numeric range, skipping a leading sign (`-5--1`).
    private static func numericRangeSeparator(in spec: String) -> String.Index? {
        var index = spec.startIndex
        if index < spec.endIndex, spec[index] == "-" || spec[index] == "+" {
            index = spec.index(after: index)
        }
        while index < spec.endIndex {
            if spec[index] == "-" { return index }
            index = spec.index(after: index)
        }
        return nil
    }

    private static func alphabet(for kind: String) -> [Character]? {
        switch kind {
        case "hex": return Array("0123456789abcdef")
        case "alnum", "alphanumeric": return Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        case "digits", "digit", "num", "number": return Array("0123456789")
        case "letters", "letter", "alpha": return Array("abcdefghijklmnopqrstuvwxyz")
        default: return nil
        }
    }
}

// MARK: - Counters

/// §3.5: Persistent named counters backing `%counter:name%` / `{{counter:name}}`.
///
/// Values survive relaunch (stored as a single small `UserDefaults` dictionary). The store only
/// ever *reports* values; advancing is driven by `MacroVolatileStore` so that the injection
/// pipeline's preview pass and the real expansion observe the same number (see below).
public final class MacroCounterStore: @unchecked Sendable {

    public static let shared = MacroCounterStore()

    public static let defaultDefaultsKey = "devtype.macroCounters"

    private let lock = UnfairLock()
    private let defaults: UserDefaults
    private let defaultsKey: String
    private var values: [String: Int]

    public init(defaults: UserDefaults = .standard, defaultsKey: String = MacroCounterStore.defaultDefaultsKey) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.values = (defaults.dictionary(forKey: defaultsKey) as? [String: Int]) ?? [:]
    }

    private static func normalize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// Current value without advancing. Used by previews so the editor never mutates state.
    public func value(for name: String) -> Int {
        let key = Self.normalize(name)
        return lock.withLock { values[key] ?? 0 }
    }

    /// Advances and returns the new value.
    @discardableResult
    public func advance(_ name: String, by step: Int = 1) -> Int {
        let key = Self.normalize(name)
        let snapshot: [String: Int]
        let next: Int
        lock.lock()
        next = (values[key] ?? 0) + step
        values[key] = next
        snapshot = values
        lock.unlock()
        defaults.set(snapshot, forKey: defaultsKey)
        return next
    }

    public func set(_ name: String, to newValue: Int) {
        let key = Self.normalize(name)
        let snapshot: [String: Int]
        lock.lock()
        values[key] = newValue
        snapshot = values
        lock.unlock()
        defaults.set(snapshot, forKey: defaultsKey)
    }

    public func reset(_ name: String) {
        set(name, to: 0)
    }

    public func resetAll() {
        lock.lock()
        values.removeAll()
        lock.unlock()
        defaults.removeObject(forKey: defaultsKey)
    }

    public func allCounters() -> [String: Int] {
        lock.withLock { values }
    }
}

// MARK: - Volatile value memoization

/// §3.5: Short-window memo for macro values that are *not* pure functions of the template
/// (`random`, `counter`).
///
/// This exists because one expansion runs the macro pipeline more than once: the event tap
/// renders a preview to decide the injection strategy (`EventTapEngine` → `InjectionPlanner`),
/// and the injection pipeline then renders the real payload a few milliseconds later. Without
/// memoization a `{{random:1-100}}` snippet would plan against one string and inject another,
/// and a counter would advance twice per expansion.
///
/// The window is deliberately short (0.5 s). Re-triggering the same snippet requires retyping a
/// multi-character abbreviation, which takes far longer than that, so a genuine second expansion
/// always sees a fresh value.
public final class MacroVolatileStore: @unchecked Sendable {

    public static let shared = MacroVolatileStore()

    public static let defaultWindow: TimeInterval = 0.5

    private struct Entry {
        let value: String
        let stamp: TimeInterval
    }

    private let lock = UnfairLock()
    private var entries: [String: Entry] = [:]
    private let window: TimeInterval
    private let clock: () -> TimeInterval

    /// Bounded so a long session cannot accumulate stale keys.
    private static let capacity = 128

    public init(
        window: TimeInterval = MacroVolatileStore.defaultWindow,
        clock: @escaping () -> TimeInterval = MacroVolatileStore.monotonicNow
    ) {
        self.window = window
        self.clock = clock
    }

    public static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Returns the memoized value for `key`, or produces (and stores) a fresh one.
    public func value(forKey key: String, produce: () -> String) -> String {
        let now = clock()
        lock.lock()
        if let existing = entries[key], now - existing.stamp <= window {
            lock.unlock()
            return existing.value
        }
        lock.unlock()

        let produced = produce()

        lock.lock()
        if entries.count >= Self.capacity {
            entries = entries.filter { now - $0.value.stamp <= window }
            if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        }
        entries[key] = Entry(value: produced, stamp: now)
        lock.unlock()
        return produced
    }

    public func invalidate() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - Macro environment

/// §3.5: Injectable collaborators for the macro renderers.
///
/// Everything defaults to the process-wide singletons, so existing call sites are unaffected;
/// tests can substitute isolated stores. `memoSalt` scopes `MacroVolatileStore` keys to a single
/// template so two different snippets expanded in the same half-second do not share a random
/// value.
public struct MacroEnvironment {
    public var locale: Locale
    public var timeZone: TimeZone
    public var counters: MacroCounterStore
    public var volatileValues: MacroVolatileStore
    public var memoSalt: String

    public init(
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        counters: MacroCounterStore = .shared,
        volatileValues: MacroVolatileStore = .shared,
        memoSalt: String = ""
    ) {
        self.locale = locale
        self.timeZone = timeZone
        self.counters = counters
        self.volatileValues = volatileValues
        self.memoSalt = memoSalt
    }

    public static var `default`: MacroEnvironment { MacroEnvironment() }

    private static let keySeparator = "\u{1}"

    /// Memo key for a volatile token. `syntax` separates the TextExpander and mustache passes so
    /// their occurrence counters cannot collide.
    public func memoKey(syntax: String, kind: String, spec: String, occurrence: Int) -> String {
        [syntax, kind, spec, "\(occurrence)", memoSalt].joined(separator: Self.keySeparator)
    }

    /// Resolves a `random` token, memoized for the current expansion.
    public func randomValue(spec: String, syntax: String, occurrence: Int) -> String {
        volatileValues.value(forKey: memoKey(syntax: syntax, kind: "random", spec: spec, occurrence: occurrence)) {
            MacroRandom.value(spec: spec)
        }
    }

    /// Resolves a `counter` token, advancing it at most once per expansion.
    /// Counter identity is intentionally *not* salted by template or occurrence: every
    /// `{{counter:invoice}}` in one expansion renders the same number.
    public func counterValue(name: String, step: Int) -> String {
        let key = ["counter", name.trimmingCharacters(in: .whitespaces).lowercased(), "\(step)", memoSalt]
            .joined(separator: Self.keySeparator)
        return volatileValues.value(forKey: key) {
            String(counters.advance(name, by: step))
        }
    }

    /// Resolves a `uuid` token. Fixed width, so no memoization is needed for the preview pass to
    /// agree with the injected payload on length.
    public func uuidValue(spec: String) -> String {
        let raw = UUID().uuidString
        switch spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "short": return String(raw.prefix(8))
        case "lower", "lowercase": return raw.lowercased()
        case "compact": return raw.replacingOccurrences(of: "-", with: "")
        default: return raw
        }
    }
}

/// §3.5: Parses `name` / `name:+5` out of a counter macro body.
public enum MacroCounterSpec {
    public static func parse(_ body: String) -> (name: String, step: Int) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":") else {
            return (trimmed.isEmpty ? "default" : trimmed, 1)
        }
        let tail = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard tail.hasPrefix("+") || tail.hasPrefix("-"), let step = Int(tail) else {
            return (trimmed, 1)
        }
        let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "default" : name, step)
    }
}
