import Foundation

/// Pure policy for "which selection, if any, may an explicit AI / text command act on?".
///
/// Split out of `SelectionReader` so every branch is reachable without a window server, an AX
/// connection, or a focused app. `SelectionReader` does the AX I/O and hands the *values* here.
///
/// Why this exists: the whole gate used to be a chain of `guard … else { return nil }` inside
/// `SelectionReader.readSelectedText()`. Every distinct cause — Accessibility revoked, Secure
/// Input locked, the app muted, no focused element, an unreadable selection, a selection that is
/// really just a stray drag — collapsed into one `nil`, and every caller printed the same
/// "No selected text. Select text first." That message is wrong four times out of five, and it
/// sends the user back to re-select text that was already selected.
public extension SelectionReader {

    /// Why no usable selection was produced. Each case maps to its own user-facing message.
    enum Failure: Equatable, Sendable {
        /// `AXIsProcessTrusted` is false — the AX grant was revoked or the binary changed.
        case accessibilityUntrusted
        /// `IsSecureEventInputEnabled()` — macOS refuses AX text reads while a password field
        /// holds the keyboard, even in a *different* app.
        case secureInputActive
        /// The frontmost app is on the user's mute list.
        case appMuted(String)
        /// No AX probe resolved a focused element (common in Electron / some web views).
        case noFocusedElement
        /// Focus was readable and there genuinely is nothing selected (or only whitespace).
        case emptySelection

        /// Stable, non-localized label for logs and the diagnostic report.
        public var diagnosticLabel: String {
            switch self {
            case .accessibilityUntrusted: return "axUntrusted"
            case .secureInputActive: return "secureInput"
            case .appMuted: return "appMuted"
            case .noFocusedElement: return "noFocus"
            case .emptySelection: return "emptySelection"
            }
        }

        public var titleKey: String {
            switch self {
            case .emptySelection: return "ai.alert.noSelection.title"
            case .accessibilityUntrusted, .secureInputActive, .appMuted, .noFocusedElement:
                return "ai.selection.unavailable.title"
            }
        }

        public var messageKey: String {
            switch self {
            case .accessibilityUntrusted: return "ai.selection.fail.axUntrusted"
            case .secureInputActive: return "ai.selection.fail.secureInput"
            case .appMuted: return "ai.selection.fail.muted"
            case .noFocusedElement: return "ai.selection.fail.noFocus"
            case .emptySelection: return "ai.alert.noSelection.message"
            }
        }

        public func title(loc: LocalizationManager = .shared) -> String {
            loc.s(titleKey)
        }

        public func message(loc: LocalizationManager = .shared) -> String {
            switch self {
            case .appMuted(let bundleID):
                return loc.s(messageKey, bundleID)
            case .accessibilityUntrusted, .secureInputActive, .noFocusedElement, .emptySelection:
                return loc.s(messageKey)
            }
        }
    }

    /// Where the text came from. Recorded for diagnostics; never changes what is injected.
    enum Source: String, Equatable, Sendable {
        /// Read live from a focused AX element at command time.
        case live
        /// Recovered from `SelectionMonitor`'s last-known-good cache because the live read
        /// resolved to DevType's own panel (or to nothing at all).
        case cached
    }

    enum Outcome: Equatable {
        case selection(Result)
        case failure(Failure)

        /// Back-compat accessor for callers that only care whether there is text.
        public var result: Result? {
            if case .selection(let result) = self { return result }
            return nil
        }

        public var failure: Failure? {
            if case .failure(let failure) = self { return failure }
            return nil
        }
    }

    /// One focused-element probe result: the text it reported (if any) and whether the element
    /// belongs to DevType itself.
    struct Candidate: Equatable, Sendable {
        public let text: String?
        public let isOwnProcess: Bool
        /// Bundle ID of the app that owns the element, when resolvable. Not always the frontmost
        /// app: the system-wide probe can still resolve into the *previous* app mid-switch, and
        /// reading a muted app's text through that window would sidestep the mute list.
        public let bundleID: String?

        public init(text: String?, isOwnProcess: Bool, bundleID: String? = nil) {
            self.text = text
            self.isOwnProcess = isOwnProcess
            self.bundleID = bundleID
        }
    }

    /// Characters that make a "selection" carry no transformable content.
    ///
    /// Plain `isEmpty` is not enough. A stray drag in a text view selects a single space; a
    /// selected image attachment in Mail reports `U+FFFC` and nothing else; Electron editors hand
    /// back zero-width joiners. All three used to sail through the gate and reach the model,
    /// which then failed with `emptyInput` or a guardrail refusal several seconds later.
    static var blankSelectionCharacters: CharacterSet {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(.controlCharacters)
        set.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{FFFC}\u{FFFD}")
        return set
    }

    /// True when `text` is nil, empty, or contains nothing but blank/placeholder scalars.
    static func isBlankSelection(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return true }
        return text.unicodeScalars.allSatisfy { blankSelectionCharacters.contains($0) }
    }

    /// Resolve the selection an explicit command should act on.
    ///
    /// Precedence, and why:
    /// 1. Hard blocks first (AX untrusted → Secure Input → muted), so the user is told the real
    ///    reason instead of being asked to re-select text that is already selected.
    /// 2. A live selection from another app's focused element. This is the normal path.
    /// 3. `SelectionMonitor`'s cache. This is what saves the ⌘⌥A press made while a DevType panel
    ///    or alert is already frontmost: the live probe then resolves to *our* search field, and
    ///    without this step the command reports "no selection" while the user's text sits
    ///    selected behind the panel.
    /// 4. A live selection from DevType's own UI, last — so editing a snippet in our own window
    ///    still works, but never at the cost of silently transforming the palette query itself
    ///    when the user meant the text behind it.
    static func evaluate(
        axTrusted: Bool,
        secureInputActive: Bool,
        frontmostBundleID: String?,
        frontmostIsOwnProcess: Bool,
        focusAvailable: Bool,
        candidates: [Candidate],
        cached: SelectionMonitor.CachedSelection?,
        cacheMaxAge: TimeInterval = SelectionMonitor.defaultTTL,
        now: Date = Date(),
        isMuted: (String) -> Bool = { AppMuteStore.shared.isMuted($0) },
        isWeakAX: (String) -> Bool = { SelectionReader.isWeakAXApp(bundleID: $0) }
    ) -> Outcome {
        guard axTrusted else { return .failure(.accessibilityUntrusted) }
        guard !secureInputActive else { return .failure(.secureInputActive) }

        if let frontmostBundleID,
           !frontmostBundleID.isEmpty,
           !frontmostIsOwnProcess,
           isMuted(frontmostBundleID) {
            return .failure(.appMuted(frontmostBundleID))
        }

        let usableLive = candidates.first { candidate in
            guard !candidate.isOwnProcess, !isBlankSelection(candidate.text) else { return false }
            // The mute list is per app, not per frontmost app.
            if let bundleID = candidate.bundleID, !bundleID.isEmpty, isMuted(bundleID) {
                return false
            }
            return true
        }
        if let usableLive, let text = usableLive.text {
            let bundleID = usableLive.bundleID ?? frontmostBundleID
            return .selection(
                Result(
                    text: text,
                    bundleID: bundleID,
                    isWeakAX: bundleID.map(isWeakAX) ?? false,
                    source: .live
                )
            )
        }

        if let cached,
           !isBlankSelection(cached.text),
           cached.isFresh(asOf: now, maxAge: cacheMaxAge),
           !isMuted(cached.bundleID),
           cacheMatchesFrontmost(
               cachedBundleID: cached.bundleID,
               frontmostBundleID: frontmostBundleID,
               frontmostIsOwnProcess: frontmostIsOwnProcess
           ) {
            return .selection(
                Result(
                    text: cached.text,
                    bundleID: cached.bundleID,
                    isWeakAX: isWeakAX(cached.bundleID),
                    source: .cached
                )
            )
        }

        if let own = candidates.first(where: { $0.isOwnProcess && !isBlankSelection($0.text) }),
           let text = own.text {
            return .selection(
                Result(
                    text: text,
                    bundleID: own.bundleID ?? frontmostBundleID,
                    isWeakAX: false,
                    source: .live
                )
            )
        }

        if !focusAvailable, candidates.isEmpty {
            return .failure(.noFocusedElement)
        }
        return .failure(.emptySelection)
    }

    /// A cached selection may only be used for the app it came from.
    ///
    /// The one exception is DevType being frontmost: that is exactly the case the cache exists
    /// for (our panel stole focus), and the cache then legitimately holds the *previous* app's
    /// text. Without this exception the fallback would never fire where it is needed most.
    private static func cacheMatchesFrontmost(
        cachedBundleID: String,
        frontmostBundleID: String?,
        frontmostIsOwnProcess: Bool
    ) -> Bool {
        if frontmostIsOwnProcess { return true }
        guard let frontmostBundleID, !frontmostBundleID.isEmpty else { return true }
        return cachedBundleID == frontmostBundleID
    }
}
