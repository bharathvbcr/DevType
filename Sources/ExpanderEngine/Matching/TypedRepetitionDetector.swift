import Foundation
import CryptoKit

/// Notices that you keep typing the same thing, so DevType can offer to make it a snippet.
///
/// # Why this is built the way it is
///
/// Everything else in DevType goes out of its way *not* to retain what you type: the engine's
/// ring buffer is 64 characters, exists only to match a trigger, and is emptied the moment
/// Secure Input turns on. A feature that spots repetition needs to remember across minutes, and
/// that is a genuinely different privacy posture for a process that sees every keystroke.
///
/// So it does not remember text. It remembers **salted hashes and counts**:
///
/// * A phrase is hashed with a salt generated fresh at launch. The salt never leaves memory and
///   is never written down, so a hash is meaningless outside this process and across restarts,
///   and the table cannot be turned back into what you typed.
/// * Only when a phrase crosses `repeatThreshold` is text kept at all — and then only *that*
///   phrase, taken from the occurrence in hand, held until the suggestion is taken or dropped.
/// * Nothing here is ever written to disk. There is no encoder, no defaults key, no file.
///
/// The upstream gates matter as much as this type: the caller feeds it only from the existing
/// ring buffer, never while Secure Input is active, never in a muted app, and only when the user
/// has switched the feature on and confirmed the consent prompt.
public final class TypedRepetitionDetector: @unchecked Sendable {

    public static let shared = TypedRepetitionDetector()

    /// How many times a phrase must recur before it is worth offering.
    public static let repeatThreshold = 3

    /// Below this a phrase is not worth a snippet — an abbreviation is already shorter.
    public static let minimumPhraseLength = 12

    /// The engine's ring buffer is 64 characters, so this is a ceiling rather than a limit that
    /// bites in practice. Stated anyway: this type must never be the reason a long secret is held.
    public static let maximumPhraseLength = EventTapEngine.maxBufferCapacity

    /// Hash-table ceiling. Bounded because this is a keystroke-driven map in a long-lived
    /// process; past this the least-recently-seen entries are dropped.
    public static let maximumTrackedPhrases = 500

    public struct Candidate: Equatable, Sendable {
        public let text: String
        public let occurrences: Int
        public let bundleID: String?

        public init(text: String, occurrences: Int, bundleID: String?) {
            self.text = text
            self.occurrences = occurrences
            self.bundleID = bundleID
        }
    }

    private struct Entry {
        var count: Int
        var lastSeen: UInt64
    }

    private let lock = UnfairLock()
    /// Salted hash → count. No text.
    private var counts: [String: Entry] = [:]
    private var tick: UInt64 = 0
    /// Regenerated on every `forgetAll`, so forgetting is not merely dropping the table — the
    /// old hashes become uncomputable even from the same text.
    private var salt: Data

    public init() {
        salt = Self.makeSalt()
    }

    private static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    // MARK: - Eligibility

    /// Whether a phrase is worth counting at all.
    ///
    /// The space requirement is doing privacy work, not just quality work: it keeps long
    /// unbroken tokens — the shape of a password, key, or hash pasted or typed into a field that
    /// does not raise Secure Input — out of the table entirely.
    public static func isEligible(_ phrase: String) -> Bool {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumPhraseLength, trimmed.count <= maximumPhraseLength else {
            return false
        }
        guard trimmed.contains(" ") else { return false }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        // A phrase that is mostly digits is far more likely to be an account number or a code
        // than a sentence worth expanding.
        let digits = trimmed.filter(\.isNumber).count
        guard digits * 2 < trimmed.count else { return false }
        return true
    }

    /// Normalized so trivial variations count as the same phrase.
    static func normalize(_ phrase: String) -> String {
        phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private func digest(_ normalized: String) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(normalized.utf8))
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Recording

    /// Counts one occurrence. Returns a candidate **only** on the occurrence that reaches
    /// `repeatThreshold`, and only then is any text retained — by the caller, from the copy it
    /// already has in hand.
    @discardableResult
    public func record(phrase: String, bundleID: String? = nil) -> Candidate? {
        guard Self.isEligible(phrase) else { return nil }
        let normalized = Self.normalize(phrase)
        let key = digest(normalized)

        lock.lock()
        defer { lock.unlock() }

        tick &+= 1
        var entry = counts[key] ?? Entry(count: 0, lastSeen: tick)
        entry.count += 1
        entry.lastSeen = tick
        counts[key] = entry

        if counts.count > Self.maximumTrackedPhrases {
            evictOldestLocked()
        }

        guard entry.count == Self.repeatThreshold else { return nil }
        // Fires once, on the crossing. The count keeps rising but the offer is not repeated
        // every keystroke afterwards.
        return Candidate(
            text: phrase.trimmingCharacters(in: .whitespacesAndNewlines),
            occurrences: entry.count,
            bundleID: bundleID
        )
    }

    /// Drops a single phrase — "not this one" without switching the feature off.
    public func forget(phrase: String) {
        let key = digest(Self.normalize(phrase))
        lock.lock()
        counts[key] = nil
        lock.unlock()
    }

    /// Drops everything and re-salts, so nothing recorded before this call can be recognised
    /// again even if the same text is typed.
    public func forgetAll() {
        lock.lock()
        counts.removeAll()
        tick = 0
        salt = Self.makeSalt()
        lock.unlock()
    }

    /// A hash *of the salt*, so a test can prove `forgetAll` rotated the key without the salt
    /// itself ever leaving this type.
    ///
    /// This exists because the re-salt is otherwise unobservable — `forgetAll` also empties the
    /// table, so behaviour is identical with or without it — and an unobservable rule is one
    /// nobody would notice losing. The consent prompt tells the user the key is thrown away on
    /// Forget, so that claim gets an assertion rather than a comment.
    var saltFingerprintForTesting: String {
        lock.lock()
        defer { lock.unlock() }
        return SHA256.hash(data: salt).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Diagnostics only: how many distinct phrases are being counted. Never the phrases.
    public var trackedPhraseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.count
    }

    private func evictOldestLocked() {
        let overflow = counts.count - Self.maximumTrackedPhrases
        guard overflow > 0 else { return }
        let doomed = counts
            .sorted { $0.value.lastSeen < $1.value.lastSeen }
            .prefix(overflow)
            .map(\.key)
        for key in doomed { counts[key] = nil }
    }
}

// MARK: - Preference

/// Two switches, both required. The feature flag alone is not enough: turning it on presents a
/// prompt describing exactly what is retained, and only confirming that sets `hasConsent`.
/// Recording them separately means a future change to the wording can revoke consent without
/// silently continuing under the old one.
public enum TypedRepetitionPreferences {
    public static let enabledKey = "devtype.repetition.enabled"
    public static let consentKey = "devtype.repetition.consentVersion"

    /// Bump when the prompt's description of what is retained changes materially.
    public static let currentConsentVersion = 1

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static var grantedConsentVersion: Int {
        get { UserDefaults.standard.integer(forKey: consentKey) }
        set { UserDefaults.standard.set(newValue, forKey: consentKey) }
    }

    public static var hasCurrentConsent: Bool {
        grantedConsentVersion >= currentConsentVersion
    }

    /// The only thing the engine should ask.
    public static var isActive: Bool {
        isEnabled && hasCurrentConsent
    }

    /// Withdrawing consent must also stop the feature — leaving `isEnabled` true would let a
    /// later consent bump silently resume it.
    public static func revokeConsent() {
        grantedConsentVersion = 0
        isEnabled = false
        TypedRepetitionDetector.shared.forgetAll()
    }
}

// MARK: - Already covered?

/// Whether a repeated phrase is something the library can already type for you.
///
/// The interesting case for a text expander: you typed it three times *by hand*, so either you
/// have no snippet for it — or you have one and did not remember the trigger. Offering to create
/// a second snippet in the latter case is the wrong answer twice over: it duplicates the library
/// and it fails to tell you the thing you actually needed to know.
public enum RepeatedPhraseLookup {

    /// The snippet whose body is this phrase, if the library already has one.
    ///
    /// Compared on the same normalization the detector counts by, so casing and spacing do not
    /// hide a match. Only expandable snippets count — a secret has no body to compare, and a
    /// snippet in a disabled group cannot type anything.
    public static func existingSnippet(
        for phrase: String,
        in groups: [SnippetGroup]
    ) -> SnippetModel? {
        let needle = TypedRepetitionDetector.normalize(phrase)
        guard !needle.isEmpty else { return nil }
        return SnippetStore.expandableSnippets(in: groups).first { snippet in
            guard snippet.enabled, !snippet.isSecret, !snippet.isImageSnippet else { return false }
            return TypedRepetitionDetector.normalize(snippet.replacementText) == needle
        }
    }
}
