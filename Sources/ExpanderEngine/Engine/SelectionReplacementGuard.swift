import AppKit
import ApplicationServices
import Foundation

/// The selection a "replace what I selected" delivery was asked to overwrite.
///
/// A paste replaces whatever the target has selected *when ⌘V lands*, not what was selected when
/// the text was read. A panel-driven delivery — the AI picker, its preview, a voice command —
/// takes focus away from the source app and hands it back between those two moments, and not
/// every host hands the selection back with it. Messages collapses it to a caret, so the result
/// was pasted beside the text it was meant to replace and the user saw their message twice.
///
/// An insert at the caret (a typed trigger whose selection the typing already replaced, a
/// palette insert) carries no `SelectionReplacement`; nothing below applies to it.
public struct SelectionReplacement: Equatable, Sendable {
    /// The exact text that was selected when the command read it.
    public let original: String
    /// False only when the original never came through AX (the ⌘C fallback for an app whose
    /// accessibility tree does not expose the selection). AX cannot confirm anything about such
    /// an app, so a delivery there stays as unverified as it always was. Everywhere else an
    /// unreadable selection is a refusal: the app answered AX when the text was read, and a
    /// paste into a selection nobody can see is how the duplicate happened.
    public let requiresEvidence: Bool
    /// The AX element the original was read from, when it was read live. Focus at replace time is
    /// resolved again from scratch, and a host that is still restoring a page answers with its
    /// window; this is the one element known to have held the selection. It is evidence to *read*
    /// and, when focus still resolves to nothing that can hold a selection, a place to put focus
    /// back — never a paste target on its own (see `Confirmer.restoreFocus`).
    public let capturedElement: AXUIElement?

    public init?(original: String, requiresEvidence: Bool = true, capturedElement: AXUIElement? = nil) {
        guard !original.isEmpty else { return nil }
        self.original = original
        self.requiresEvidence = requiresEvidence
        self.capturedElement = capturedElement
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.original == rhs.original, lhs.requiresEvidence == rhs.requiresEvidence else { return false }
        switch (lhs.capturedElement, rhs.capturedElement) {
        case (nil, nil): return true
        case let (left?, right?): return CFEqual(left, right)
        default: return false
        }
    }
}

/// Decides, from one reading of the target field, whether a replace may paste now.
///
/// Pure over `DeliveryVerifier.FocusedTextObservation`, so every branch is reachable in tests
/// without a window server; `Confirmer` below owns the AX reads and the one range write.
public enum SelectionReplacementGuard {

    /// Why a replace was refused. One case per cause, because each says something different
    /// about the host, and the report line is the only place the user's lost delivery is named.
    public enum Refusal: String, Equatable, Sendable, CaseIterable {
        /// Neither the selection nor the field could be read, in an app that answered AX when
        /// the text was captured.
        case unreadable
        /// The live selection is not the original, and the field cannot be searched for it.
        case selectionChanged
        /// The original text is no longer anywhere in the field — the user (or the app) edited it.
        case originalNotFound
        /// The original occurs more than once and nothing says which one was selected.
        case originalAmbiguous
        /// The original was found and re-selected, but the field did not report it selected.
        case reselectFailed
        /// The field is larger than this guard will scan on the main thread.
        case fieldTooLarge
        /// The selection was confirmed, but while that waited focus left the element it was
        /// confirmed on: the paste would land somewhere the confirm never looked.
        case focusMoved
        /// The paste was posted and the field was read back unchanged: the original is still
        /// there and the result is not. Unlike every other case, ⌘V did go out — the result is
        /// kept on the clipboard because nothing re-pastes it (a late paste would duplicate it).
        case notLanded

        /// Report-ready sentence. Carries no field content, so `InjectRefusalKind.classify` passes
        /// it through to the report intact.
        public var reason: String {
            // The one cause that is not about the selection going stale before the paste, so it
            // must not wear that prefix: the report would send its reader after the wrong stage.
            if self == .notLanded {
                return "Replace not confirmed — the field still held the original after the paste"
            }
            let detail: String
            switch self {
            case .unreadable: detail = "the selection could not be read back"
            case .selectionChanged: detail = "the selection no longer holds the original text"
            case .originalNotFound: detail = "the original text is no longer in the field"
            case .originalAmbiguous: detail = "the original text occurs more than once"
            case .reselectFailed: detail = "re-selecting the original text did not take"
            case .fieldTooLarge: detail = "the field is too large to search for the original text"
            case .focusMoved: detail = "focus left the field while its selection was being confirmed"
            case .notLanded: detail = ""
            }
            return "\(SelectionReplacementGuard.refusalPrefix)\(detail)"
        }
    }

    public enum Decision: Equatable, Sendable {
        /// The live selection is exactly the original: ⌘V replaces it.
        case proceed
        /// The selection moved, and the original sits at this UTF-16 range of the field.
        case reselect(NSRange)
        case refuse(Refusal)
        /// The observation carried nothing to judge by. The caller decides through
        /// `SelectionReplacement.requiresEvidence` — never this type, which cannot see it.
        case unverifiable
    }

    static let refusalPrefix = "Selection changed before replace — "

    /// The pipeline path every refusal from this guard is recorded under.
    public static let refusalPath = "selectionReplace"

    /// Fields above this many UTF-16 units are not searched. `NSString.range(of:)` is linear, but
    /// this runs on main inside the inject, and a multi-megabyte document is not a compose box.
    public static let maxSearchUTF16 = 1_000_000

    /// At most this many occurrences are collected; past two the answer only matters when one of
    /// them touches the caret, and a pathological field must not turn into an unbounded list.
    static let maxOccurrences = 64

    /// The selection text the observation actually carries, or nil when it carries none.
    ///
    /// `kAXSelectedText` first; hosts that do not answer it still expose value + range. An empty
    /// answer beside a non-empty range is the host contradicting itself, so the range slice
    /// decides — otherwise an intact selection could never reach `.proceed`, not even on the
    /// read-back after a re-select. An empty answer beside nothing is not a selection at all: it
    /// is what a host returns before it has published one, and it must not be read as a readable
    /// selection that differs from the original.
    static func liveSelectionText(of observation: DeliveryVerifier.FocusedTextObservation) -> String? {
        if let selected = observation.selectedText, !selected.isEmpty { return selected }
        guard let value = observation.value.map({ $0 as NSString }),
              let range = validRange(observation.selectedRange),
              range.length > 0, NSMaxRange(range) <= value.length else { return nil }
        let sliced = value.substring(with: range)
        return sliced.isEmpty ? nil : sliced
    }

    private static func validRange(_ range: NSRange?) -> NSRange? {
        guard let range, range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    public static func decide(
        original: String,
        observation: DeliveryVerifier.FocusedTextObservation?
    ) -> Decision {
        guard !original.isEmpty else { return .proceed }
        guard let observation else { return .unverifiable }

        let value = observation.value.map { $0 as NSString }
        let range = validRange(observation.selectedRange)
        let liveSelection = liveSelectionText(of: observation)

        if let liveSelection, liveSelection == original {
            return .proceed
        }

        guard let value, value.length > 0 else {
            // A readable selection that is not the original, with no field to look in, is a
            // known mismatch. Nothing readable at all is no evidence either way.
            if liveSelection != nil || range != nil { return .refuse(.selectionChanged) }
            return .unverifiable
        }
        guard value.length <= maxSearchUTF16 else { return .refuse(.fieldTooLarge) }

        // Literal first: an exact match is the strongest evidence and the cheapest search. Only a
        // field with no exact match is searched again for the same text in another Unicode
        // normalisation — the one fold `String ==` (and so the `.proceed` test above) already
        // accepts, and the one a host can apply without anything having been edited.
        var canonical = false
        var hits = occurrences(of: original, in: value)
        if hits.isEmpty {
            hits = canonicalOccurrences(of: original, in: value, within: NSRange(location: 0, length: value.length))
            canonical = !hits.isEmpty
        }
        switch hits.count {
        case 0:
            return .refuse(.originalNotFound)
        case 1:
            return .reselect(hits[0])
        default:
            // A collapsed caret is the usual shape of a lost selection, and it is left at one
            // edge of what was selected. Only an occurrence that edge identifies is safe to pick.
            // The scan keeps at most `maxOccurrences`; past that, the occurrences the caret can
            // touch are searched for directly, because the one it sits against may not be among
            // the ones kept.
            if let range {
                let candidates = hits.count < maxOccurrences
                    ? hits
                    : occurrencesNear(range, original: original, in: value, canonical: canonical)
                let touching = candidates.filter { hit in
                    range.location == hit.location || range.location == NSMaxRange(hit)
                        || NSIntersectionRange(range, hit).length > 0
                }
                if touching.count == 1 { return .reselect(touching[0]) }
            }
            return .refuse(.originalAmbiguous)
        }
    }

    /// Non-overlapping literal occurrences, in UTF-16 coordinates, capped at `maxOccurrences`.
    static func occurrences(of needle: String, in haystack: NSString) -> [NSRange] {
        let target = needle as NSString
        guard target.length > 0, target.length <= haystack.length else { return [] }
        return scan(needle, in: haystack, within: NSRange(location: 0, length: haystack.length), options: .literal) { _ in true }
    }

    /// Occurrences of `needle` that `String ==` calls equal to it, inside `window`, capped at
    /// `maxOccurrences`. The search itself is Foundation's canonical-equivalence one, whose
    /// notion of a match is wider than ours (it can step over ignorable characters), so every
    /// range it returns is re-checked as text before it counts. The needle may be longer than
    /// the text it matches, so there is no length shortcut here.
    static func canonicalOccurrences(of needle: String, in haystack: NSString, within window: NSRange) -> [NSRange] {
        scan(needle, in: haystack, within: window, options: []) { haystack.substring(with: $0) == needle }
    }

    /// The occurrences around `range`, for a field with more of them than the scan keeps. The
    /// caret edge decides which one was selected, so what matters is every occurrence it can
    /// touch — and those all lie within one needle length of the range, wherever in the field.
    private static func occurrencesNear(
        _ range: NSRange, original: String, in haystack: NSString, canonical: Bool
    ) -> [NSRange] {
        // A canonically equivalent match can be longer than the needle (decomposed against
        // composed), so the reach is widened rather than trusted to be one needle length.
        let reach = (original as NSString).length * (canonical ? 3 : 1)
        let start = max(0, range.location - reach)
        let end = min(haystack.length, NSMaxRange(range) + reach)
        guard end > start else { return [] }
        let window = NSRange(location: start, length: end - start)
        if canonical { return canonicalOccurrences(of: original, in: haystack, within: window) }
        return scan(original, in: haystack, within: window, options: .literal) { _ in true }
    }

    private static func scan(
        _ needle: String,
        in haystack: NSString,
        within window: NSRange,
        options: NSString.CompareOptions,
        accepting: (NSRange) -> Bool
    ) -> [NSRange] {
        guard !needle.isEmpty, window.location >= 0, NSMaxRange(window) <= haystack.length else { return [] }
        var hits: [NSRange] = []
        var searchStart = window.location
        while searchStart < NSMaxRange(window), hits.count < maxOccurrences {
            let found = haystack.range(
                of: needle,
                options: options,
                range: NSRange(location: searchStart, length: NSMaxRange(window) - searchStart)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            if accepting(found) { hits.append(found) }
            searchStart = NSMaxRange(found)
        }
        return hits
    }

    // MARK: - Confirmer

    /// Runs the decision against a live field: reads it, re-selects the original when it moved,
    /// and reads it back before answering. The AX reads and the one range write are injectable
    /// so the whole sequence is testable without a window server.
    public struct Confirmer {
        public enum Verdict: Equatable {
            /// The original is selected now; ⌘V replaces it. `reselected` says this guard had to
            /// put it back, which is worth a log line — it means the host lost it. `refocusedOn`
            /// is set when the confirmed element is not the one handed in: focus was missing, or
            /// it was a window-level container and the settle found the field. The caller's focus
            /// is stale, and this is the element to judge from here.
            case confirmed(reselected: Bool, refocusedOn: AXUIElement? = nil, trail: Trail = Trail())
            /// Nothing could be checked and the replacement does not require evidence.
            case unverified
            /// `trail` says where the settle ended; it never takes part in equality, because two
            /// refusals for the same cause are the same refusal however long they took to reach it.
            case refused(Refusal, trail: Trail = Trail())

            public static func == (lhs: Self, rhs: Self) -> Bool {
                switch (lhs, rhs) {
                case let (.confirmed(left, leftFocus, _), .confirmed(right, rightFocus, _)):
                    guard left == right else { return false }
                    switch (leftFocus, rightFocus) {
                    case (nil, nil): return true
                    case let (leftElement?, rightElement?): return CFEqual(leftElement, rightElement)
                    default: return false
                    }
                case (.unverified, .unverified): return true
                case let (.refused(left, _), .refused(right, _)): return left == right
                default: return false
                }
            }
        }

        /// What the settle did, for the report line. A refusal that says only "unreadable" cannot
        /// tell a host that answered with the window four times from one whose field stayed blank
        /// three times, and those want different fixes; the role of the element the *last*
        /// reading came from, and how many times the settle waited and re-resolved focus, can.
        public struct Trail: Equatable, Sendable {
            /// Settle ticks that ran: each waited `settleInterval` and read again.
            public var settles = 0
            /// How many of those asked the host for its focused element again.
            public var refocuses = 0
            /// `kAXRole` of the element handed in, "none" when there was none, nil when the
            /// host did not answer it or no settle ran (the caller already knows that role).
            public var startRole: String?
            /// The same for the element the last reading was taken from.
            public var endRole: String?
            /// How many times focus was asked to go back to the element the selection was read
            /// from, because it still resolved to nothing that could hold one.
            public var capturedFocusAttempts = 0

            public init() {}

            /// Report-ready, and free of field content: counts and AX role names only.
            public var summary: String {
                var line = "settles=\(settles) refocuses=\(refocuses) startRole=\(startRole ?? "unread") endRole=\(endRole ?? "unread")"
                if capturedFocusAttempts > 0 { line += " capturedFocusAttempts=\(capturedFocusAttempts)" }
                return line
            }
        }

        public struct Access {
            public var observe: (AXUIElement) -> DeliveryVerifier.FocusedTextObservation
            public var select: (NSRange, AXUIElement) -> Bool
            /// Schedules the read-back after a range write. Hosts publish the new selection on
            /// their next run-loop turn, not synchronously with the `.success` they return.
            public var schedule: (TimeInterval, @escaping () -> Void) -> Void
            /// Resolves the focused element again. Used when the settle started with none, and
            /// when it started on a window-level container that cannot hold the selection.
            public var refocus: () -> AXUIElement?
            /// `kAXRoleAttribute` of an element, or nil when the host did not answer. A nil role
            /// is not a container: the settle keeps the element it has.
            public var role: (AXUIElement) -> String?
            /// Asks the host to make this element the focused one; true only when it accepted.
            /// Acceptance is not evidence: the caller resolves focus again and compares. The
            /// default declines, so an `Access` that cannot move focus never claims to have.
            public var focus: (AXUIElement) -> Bool

            public init(
                observe: @escaping (AXUIElement) -> DeliveryVerifier.FocusedTextObservation,
                select: @escaping (NSRange, AXUIElement) -> Bool,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                refocus: @escaping () -> AXUIElement? = { nil },
                role: @escaping (AXUIElement) -> String? = { _ in nil },
                focus: @escaping (AXUIElement) -> Bool = { _ in false }
            ) {
                self.observe = observe
                self.select = select
                self.schedule = schedule
                self.refocus = refocus
                self.role = role
                self.focus = focus
            }

            public static let live = Access(
                observe: { element in
                    Confirmer.fillingSelection(DeliveryVerifier.fullObservation(for: element)) {
                        SelectionReader.copySelectedText(from: element)
                    }
                },
                select: { AXTextWriter.shared.selectRange($0, in: $1) },
                schedule: { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                },
                refocus: { AXContextChecker.shared.queryFocusedElement(allowTimeoutRetry: false).element },
                role: { AXContextChecker.shared.focusedElementRole(element: $0) },
                focus: {
                    AXUIElementSetAttributeValue($0, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
                }
            )
        }

        /// The three plain attributes are not how the selection was read. `SelectionReader` climbs
        /// a ladder — parameterized ranges, plural ranges, text markers — and a WebKit field can
        /// answer the original on one rung and leave `kAXSelectedText` blank on the next reading.
        /// Judging the replace on a weaker read than the capture made an intact selection look
        /// unreadable. The ladder is consulted only when the observation has no selected text and
        /// no range: a caret range is a real answer (the selection collapsed) and stays one — to the
        /// ladder. `judge` still waits on a caret it cannot repair, because a host restoring a
        /// selection reports the caret first, and refuses as `selectionChanged` only if it stays.
        static func fillingSelection(
            _ observation: DeliveryVerifier.FocusedTextObservation,
            ladder: () -> String?
        ) -> DeliveryVerifier.FocusedTextObservation {
            guard observation.selectedText?.isEmpty ?? true,
                  observation.selectedRange == nil,
                  let laddered = ladder(), !laddered.isEmpty else { return observation }
            return DeliveryVerifier.FocusedTextObservation(
                value: observation.value,
                selectedText: laddered,
                selectedRange: observation.selectedRange,
                target: observation.target,
                numberOfCharacters: observation.numberOfCharacters
            )
        }

        /// Read-backs after a range write, and the gap before each. Bounded: a host that never
        /// reports the selection costs at most `readBackAttempts × readBackInterval`, then refuses.
        public static let readBackAttempts = 3
        public static let readBackInterval: TimeInterval = 0.03

        /// Re-readings of a field that answered nothing, and the gap before each. The selection is
        /// read with the source app frontmost; the replace is judged the moment it is frontmost
        /// *again*. A host restoring focus can answer blank for that instant, or answer with the
        /// window while its content process restores the field (Safari, after a panel took focus).
        /// A blank text element is re-read. A blank window-level container cannot publish the
        /// selection, so the settle resolves focus again instead of pinning the container.
        /// Bounded: a field that stays blind costs at most `settleAttempts × settleInterval`,
        /// then refuses as before.
        public static let settleAttempts = 4
        public static let settleInterval: TimeInterval = 0.05

        /// A blank reading from a window-level container (`AXContextChecker.windowLevelContainerRoles`)
        /// abandons the element: none of them expose the selection the replace has to confirm.
        static func blankReadingAbandonsElement(role: String?) -> Bool {
            AXContextChecker.isWindowLevelContainer(role: role)
        }

        private let access: Access

        public init(access: Access = .live) {
            self.access = access
        }

        public func confirm(
            _ replacement: SelectionReplacement,
            element: AXUIElement?,
            completion: @escaping (Verdict) -> Void
        ) {
            judge(
                replacement, element: element, refocused: false,
                settlesRemaining: Self.settleAttempts, trail: Trail(), completion: completion
            )
        }

        /// A refusal with the trail finished: the role of the element the last reading came from,
        /// which is where the settle died — not necessarily the element it started on.
        private func refusal(_ refusal: Refusal, element: AXUIElement?, trail: Trail) -> Verdict {
            var finished = trail
            finished.endRole = element.map { access.role($0) } ?? "none"
            return .refused(refusal, trail: finished)
        }

        private func judge(
            _ replacement: SelectionReplacement,
            element: AXUIElement?,
            refocused: Bool,
            settlesRemaining: Int,
            trail: Trail,
            lastRefusal: Refusal? = nil,
            completion: @escaping (Verdict) -> Void
        ) {
            let observation = element.map { access.observe($0) }
            var decision = observation.map {
                SelectionReplacementGuard.decide(original: replacement.original, observation: $0)
            } ?? .unverifiable
            // A caret beside a field nobody can read is a mismatch `decide` can name but cannot
            // repair. It is also what a host reports while it restores a selection, one turn
            // before the selection itself. So when nothing readable says otherwise it is waited on
            // like a blank reading, and only the refusal that was actually seen is reported if the
            // wait runs out. Text that *was* readable and foreign refuses at once.
            var observedRefusal = lastRefusal
            if replacement.requiresEvidence, decision == .refuse(.selectionChanged),
               let observation, SelectionReplacementGuard.liveSelectionText(of: observation) == nil {
                observedRefusal = .selectionChanged
                decision = .unverifiable
            }
            let refocusedOn = refocused ? element : nil
            switch decision {
            case .proceed:
                completion(.confirmed(reselected: false, refocusedOn: refocusedOn, trail: trail))
            case .unverifiable:
                // Only a replacement that must prove its selection is worth waiting for; one read
                // by copy is delivered unverified either way.
                guard replacement.requiresEvidence, settlesRemaining > 0 else {
                    if replacement.requiresEvidence {
                        completion(refusal(observedRefusal ?? .unreadable, element: element, trail: trail))
                    } else {
                        completion(.unverified)
                    }
                    return
                }
                // No element, or a window-level container: the field is whoever holds focus
                // after the host settles. A text element that answered blank stays put — that
                // is the host publishing the selection a moment late, and following focus away
                // from it would drop the element that is about to answer.
                let heldRole = element.flatMap { access.role($0) }
                let abandon = element == nil || Self.blankReadingAbandonsElement(role: heldRole)
                var trail = trail
                if trail.settles == 0 { trail.startRole = element == nil ? "none" : heldRole }
                trail.settles += 1
                if abandon { trail.refocuses += 1 }
                access.schedule(Self.settleInterval) {
                    var next = element
                    var tick = trail
                    if abandon, let resolved = access.refocus() { next = resolved }
                    // Focus still resolves to nothing that can hold a selection. The element the
                    // selection was read from is the one place known to have held it, so focus is
                    // asked to go back there — and only trusted once resolving it again says so.
                    if abandon, replacement.requiresEvidence, let captured = replacement.capturedElement,
                       next.map({ Self.blankReadingAbandonsElement(role: access.role($0)) }) ?? true,
                       let restored = restoreFocus(to: captured, trail: &tick) {
                        next = restored
                    }
                    let gained: Bool
                    switch (element, next) {
                    case let (held?, moved?): gained = !CFEqual(held, moved)
                    case (nil, _?): gained = true
                    default: gained = false
                    }
                    judge(
                        replacement, element: next, refocused: refocused || gained,
                        settlesRemaining: settlesRemaining - 1, trail: tick,
                        lastRefusal: observedRefusal, completion: completion
                    )
                }
            case .refuse(let reason):
                completion(refusal(reason, element: element, trail: trail))
            case .reselect(let range):
                guard let element, access.select(range, element) else {
                    completion(refusal(.reselectFailed, element: element, trail: trail))
                    return
                }
                readBack(
                    replacement, element: element, refocusedOn: refocusedOn, trail: trail,
                    remaining: Self.readBackAttempts, completion: completion
                )
            }
        }

        /// Puts focus back on the element the selection was read from, and returns it only when
        /// the host's own answer to "what is focused" now names it. A paste goes to the first
        /// responder, not to an element this guard happens to hold: confirming against an element
        /// that is not focused and pasting anyway would land the text in a window, or in whatever
        /// else had focus, and report the delivery as made. The write being accepted proves
        /// nothing — hosts accept an `AXFocused` they then ignore — so the comparison decides.
        private func restoreFocus(to captured: AXUIElement, trail: inout Trail) -> AXUIElement? {
            trail.capturedFocusAttempts += 1
            guard access.focus(captured) else { return nil }
            trail.refocuses += 1
            guard let live = access.refocus(), CFEqual(live, captured) else { return nil }
            return live
        }

        private func readBack(
            _ replacement: SelectionReplacement,
            element: AXUIElement,
            refocusedOn: AXUIElement?,
            trail: Trail,
            remaining: Int,
            completion: @escaping (Verdict) -> Void
        ) {
            access.schedule(Self.readBackInterval) {
                // Only `.proceed` counts. A second `.reselect` here means the write reported
                // success and changed nothing — writing again would not make it more true.
                if SelectionReplacementGuard.decide(
                    original: replacement.original,
                    observation: access.observe(element)
                ) == .proceed {
                    completion(.confirmed(reselected: true, refocusedOn: refocusedOn, trail: trail))
                } else if remaining > 1 {
                    readBack(
                        replacement, element: element, refocusedOn: refocusedOn, trail: trail,
                        remaining: remaining - 1, completion: completion
                    )
                } else {
                    completion(refusal(.reselectFailed, element: element, trail: trail))
                }
            }
        }
    }
}
