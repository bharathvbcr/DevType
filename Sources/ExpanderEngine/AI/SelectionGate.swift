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
        /// DevType itself was frontmost and nothing had been captured from the app behind it.
        ///
        /// Distinct from `.noFocusedElement` because the advice is opposite. That one says "click
        /// into the text and select it" — advice that, given here, sends the user to click inside
        /// *our own panel*. The real situation is that the command was invoked with DevType in
        /// front and no live selection anywhere to read.
        case noSourceSelection
        /// Focus was readable and there genuinely is nothing selected (or only whitespace).
        case emptySelection
        /// The selection is past `SelectionReader.maxSelectionCharacters`. Carries its length.
        case selectionTooLarge(Int)

        /// Stable, non-localized label for logs and the diagnostic report.
        public var diagnosticLabel: String {
            switch self {
            case .accessibilityUntrusted: return "axUntrusted"
            case .secureInputActive: return "secureInput"
            case .appMuted: return "appMuted"
            case .noFocusedElement: return "noFocus"
            case .noSourceSelection: return "noSource"
            case .emptySelection: return "emptySelection"
            case .selectionTooLarge: return "tooLarge"
            }
        }

        public var titleKey: String {
            switch self {
            case .emptySelection: return "ai.alert.noSelection.title"
            case .accessibilityUntrusted, .secureInputActive, .appMuted, .noFocusedElement,
                 .noSourceSelection, .selectionTooLarge:
                return "ai.selection.unavailable.title"
            }
        }

        public var messageKey: String {
            switch self {
            case .accessibilityUntrusted: return "ai.selection.fail.axUntrusted"
            case .secureInputActive: return "ai.selection.fail.secureInput"
            case .appMuted: return "ai.selection.fail.muted"
            case .noFocusedElement: return "ai.selection.fail.noFocus"
            case .noSourceSelection: return "ai.selection.fail.noSource"
            case .emptySelection: return "ai.alert.noSelection.message"
            case .selectionTooLarge: return "ai.selection.fail.tooLarge"
            }
        }

        public func title(loc: LocalizationManager = .shared) -> String {
            loc.s(titleKey)
        }

        public func message(loc: LocalizationManager = .shared) -> String {
            switch self {
            case .appMuted(let bundleID):
                return loc.s(messageKey, bundleID)
            case .selectionTooLarge(let characters):
                return loc.s(
                    messageKey,
                    "\(characters)",
                    "\(SelectionReader.maxSelectionCharacters)"
                )
            case .accessibilityUntrusted, .secureInputActive, .noFocusedElement,
                 .noSourceSelection, .emptySelection:
                return loc.s(messageKey)
            }
        }
    }

    /// Which rung of the AX ladder produced the text. Diagnostics only — never changes what is
    /// injected, but it is the single most useful field in a "no selection" bug report: it says
    /// whether an app answers the plain attribute, needs the range pair, or is marker-only.
    enum ReadVia: Equatable, Sendable {
        /// `kAXSelectedText`.
        case selectedText
        /// `kAXSelectedText` after the long-timeout retry (large selection).
        case selectedTextSlow
        /// `kAXSelectedTextRange` + `kAXStringForRange`.
        case stringForRange
        /// `kAXSelectedTextRange` + `kAXAttributedStringForRange`.
        case attributedStringForRange
        /// `kAXSelectedTextRange` sliced out of `kAXValue`.
        case valueSubstring
        /// `AXSelectedTextRanges` (discontinuous / multi-cursor).
        case selectedTextRanges
        /// `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange` (WebKit / Chromium).
        case textMarker
        /// Read off an ancestor `n` hops above the focused element.
        case ancestor(Int)
        /// Read off the application element itself.
        case applicationElement
        /// Recovered from `SelectionMonitor`'s cache.
        case cache
        /// Captured by the brokered ⌘C fallback (`PasteboardBroker.captureSelectionViaCopy`).
        case clipboardCopy
        /// No rung answered, or the caller did not track one.
        case unknown

        public var rawValue: String {
            switch self {
            case .selectedText: return "selectedText"
            case .selectedTextSlow: return "selectedTextSlow"
            case .stringForRange: return "stringForRange"
            case .attributedStringForRange: return "attributedStringForRange"
            case .valueSubstring: return "valueSubstring"
            case .selectedTextRanges: return "selectedTextRanges"
            case .textMarker: return "textMarker"
            case .ancestor(let hops): return "ancestor+\(hops)"
            case .applicationElement: return "applicationElement"
            case .cache: return "cache"
            case .clipboardCopy: return "clipboardCopy"
            case .unknown: return "unknown"
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
        /// Captured by the ⌘C clipboard fallback after every AX tier failed.
        case clipboard
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
        /// Which AX rung answered for this element.
        public let via: ReadVia

        public init(
            text: String?,
            isOwnProcess: Bool,
            bundleID: String? = nil,
            via: ReadVia = .unknown
        ) {
            self.text = text
            self.isOwnProcess = isOwnProcess
            self.bundleID = bundleID
            self.via = via
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
        cacheMaxAge: TimeInterval? = nil,
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
            return accept(
                Result(
                    text: text,
                    bundleID: bundleID,
                    isWeakAX: bundleID.map(isWeakAX) ?? false,
                    source: .live,
                    via: usableLive.via
                )
            )
        }

        if let cached,
           !isBlankSelection(cached.text),
           cached.isFresh(
               asOf: now,
               maxAge: cacheMaxAge ?? Self.cacheMaxAge(frontmostIsOwnProcess: frontmostIsOwnProcess)
           ),
           !isMuted(cached.bundleID),
           cacheMatchesFrontmost(
               cachedBundleID: cached.bundleID,
               frontmostBundleID: frontmostBundleID,
               frontmostIsOwnProcess: frontmostIsOwnProcess
           ) {
            return accept(
                Result(
                    text: cached.text,
                    bundleID: cached.bundleID,
                    isWeakAX: isWeakAX(cached.bundleID),
                    source: .cached,
                    via: .cache
                )
            )
        }

        if let own = candidates.first(where: { $0.isOwnProcess && !isBlankSelection($0.text) }),
           let text = own.text {
            return accept(
                Result(
                    text: text,
                    bundleID: own.bundleID ?? frontmostBundleID,
                    isWeakAX: false,
                    source: .live,
                    via: own.via
                )
            )
        }

        // Name the situation the user is actually in. With DevType frontmost and nothing captured,
        // "no text field has keyboard focus — click into the text and select it" points at our own
        // panel; the honest answer is that the command was invoked with nothing behind it to read.
        if frontmostIsOwnProcess, candidates.allSatisfy({ isBlankSelection($0.text) }) {
            return .failure(.noSourceSelection)
        }
        if !focusAvailable, candidates.isEmpty {
            return .failure(.noFocusedElement)
        }
        return .failure(.emptySelection)
    }

    /// Pure policy: how old a cached selection may be before this command refuses it.
    ///
    /// Two tiers, because the clock means two different things. With the user's app frontmost the
    /// selection can change at any keystroke, so the cache is a bridge across a few hundred
    /// milliseconds and `defaultTTL` is generous already. With *DevType* frontmost the user is in
    /// our panel and cannot be changing that selection — and the moment they activate any other
    /// app, `SelectionMonitor` clears the entry outright rather than ageing it. Holding both cases
    /// to six seconds is what turned "select text, open the palette, read the options, choose one"
    /// into `outcome=noFocus`.
    static func cacheMaxAge(frontmostIsOwnProcess: Bool) -> TimeInterval {
        frontmostIsOwnProcess ? SelectionMonitor.ownFocusTTL : SelectionMonitor.defaultTTL
    }

    /// Final size check on a selection that has otherwise won the gate.
    ///
    /// Deliberately at the end rather than as a candidate filter: an oversized selection is the
    /// user's actual selection, so falling through to a *different* one and silently
    /// transforming that would be worse than refusing. They get told the length and the limit.
    private static func accept(_ result: Result) -> Outcome {
        let characters = result.text.count
        guard characters <= SelectionReader.maxSelectionCharacters else {
            return .failure(.selectionTooLarge(characters))
        }
        return .selection(result)
    }

    /// Pure policy: may the brokered ⌘C fallback run after this failure?
    ///
    /// `.noFocusedElement` **only** — the app published no usable accessibility tree at all
    /// (Java without the a11y bridge, custom OpenGL views, a Chromium tree that never settled),
    /// so a synthetic copy is the only read left. Never on `.emptySelection`: there AX resolved a
    /// focused element and answered "nothing selected", and that answer must be believed —
    /// VS Code-family editors treat ⌘C with no selection as "copy the whole current line", which
    /// would surface a line the user never selected as their "selection".
    ///
    /// Every hard block stays hard: an untrusted / secure-input / muted failure never reaches
    /// here as `.noFocusedElement` (precedence in `evaluate`), and the live re-checks guard the
    /// time that has passed since. `frontmostIsOwnProcess` because a ⌘C while DevType is
    /// frontmost lands on our own panel.
    static func shouldAttemptClipboardFallback(
        failure: Failure,
        frontmostIsOwnProcess: Bool,
        canPostEvents: Bool,
        secureInputActive: Bool
    ) -> Bool {
        guard case .noFocusedElement = failure else { return false }
        return !frontmostIsOwnProcess && canPostEvents && !secureInputActive
    }

    /// Pure: turn a copy-capture outcome into a selection outcome, or `nil` to keep the
    /// original failure.
    ///
    /// A blank capture keeps the original failure rather than becoming `.emptySelection` —
    /// "the app answered ⌘C with whitespace" is not evidence the user's real problem changed.
    /// The size ceiling applies exactly as it does to AX reads: an oversized capture is the
    /// user's actual selection, so it is refused by name, never silently dropped.
    static func outcomeForClipboardCapture(
        text: String?,
        bundleID: String?,
        isWeakAX: (String) -> Bool = { SelectionReader.isWeakAXApp(bundleID: $0) }
    ) -> Outcome? {
        guard let text, !isBlankSelection(text) else { return nil }
        guard text.count <= SelectionReader.maxSelectionCharacters else {
            return .failure(.selectionTooLarge(text.count))
        }
        return .selection(
            Result(
                text: text,
                bundleID: bundleID,
                isWeakAX: bundleID.map(isWeakAX) ?? false,
                source: .clipboard,
                via: .clipboardCopy
            )
        )
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
