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

    public init?(original: String, requiresEvidence: Bool = true) {
        guard !original.isEmpty else { return nil }
        self.original = original
        self.requiresEvidence = requiresEvidence
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

        /// Report-ready sentence. Carries no field content, so `InjectRefusalKind.classify` passes
        /// it through to the report intact.
        public var reason: String {
            let detail: String
            switch self {
            case .unreadable: detail = "the selection could not be read back"
            case .selectionChanged: detail = "the selection no longer holds the original text"
            case .originalNotFound: detail = "the original text is no longer in the field"
            case .originalAmbiguous: detail = "the original text occurs more than once"
            case .reselectFailed: detail = "re-selecting the original text did not take"
            case .fieldTooLarge: detail = "the field is too large to search for the original text"
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

    public static func decide(
        original: String,
        observation: DeliveryVerifier.FocusedTextObservation?
    ) -> Decision {
        guard !original.isEmpty else { return .proceed }
        guard let observation else { return .unverifiable }

        let value = observation.value.map { $0 as NSString }
        let range = observation.selectedRange.flatMap { range -> NSRange? in
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
            return range
        }
        // `kAXSelectedText` first; hosts that do not answer it still expose value + range. An
        // empty answer beside a non-empty range is the host contradicting itself, so the range
        // slice decides — otherwise an intact selection could never reach `.proceed`, not even
        // on the read-back after a re-select.
        let sliced: String? = {
            guard let value, let range, range.length > 0,
                  NSMaxRange(range) <= value.length else { return nil }
            return value.substring(with: range)
        }()
        let liveSelection: String?
        if let selected = observation.selectedText, !selected.isEmpty {
            liveSelection = selected
        } else {
            liveSelection = sliced ?? observation.selectedText
        }

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

        let hits = occurrences(of: original, in: value)
        switch hits.count {
        case 0:
            return .refuse(.originalNotFound)
        case 1:
            return .reselect(hits[0])
        default:
            // A collapsed caret is the usual shape of a lost selection, and it is left at one
            // edge of what was selected. Only an occurrence that edge identifies is safe to pick.
            if let range {
                let touching = hits.filter { hit in
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
        var hits: [NSRange] = []
        var searchStart = 0
        while searchStart <= haystack.length - target.length, hits.count < maxOccurrences {
            let found = haystack.range(
                of: needle,
                options: .literal,
                range: NSRange(location: searchStart, length: haystack.length - searchStart)
            )
            guard found.location != NSNotFound else { break }
            hits.append(found)
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
            /// is set only when no element was handed in and the settle had to resolve one: the
            /// caller's focus is stale, and this is the element the selection was confirmed on.
            case confirmed(reselected: Bool, refocusedOn: AXUIElement? = nil)
            /// Nothing could be checked and the replacement does not require evidence.
            case unverified
            case refused(Refusal)

            public static func == (lhs: Self, rhs: Self) -> Bool {
                switch (lhs, rhs) {
                case let (.confirmed(left, leftFocus), .confirmed(right, rightFocus)):
                    guard left == right else { return false }
                    switch (leftFocus, rightFocus) {
                    case (nil, nil): return true
                    case let (leftElement?, rightElement?): return CFEqual(leftElement, rightElement)
                    default: return false
                    }
                case (.unverified, .unverified): return true
                case let (.refused(left), .refused(right)): return left == right
                default: return false
                }
            }
        }

        public struct Access {
            public var observe: (AXUIElement) -> DeliveryVerifier.FocusedTextObservation
            public var select: (NSRange, AXUIElement) -> Bool
            /// Schedules the read-back after a range write. Hosts publish the new selection on
            /// their next run-loop turn, not synchronously with the `.success` they return.
            public var schedule: (TimeInterval, @escaping () -> Void) -> Void
            /// Resolves the focused element again, for a settle that started with none.
            public var refocus: () -> AXUIElement?

            public init(
                observe: @escaping (AXUIElement) -> DeliveryVerifier.FocusedTextObservation,
                select: @escaping (NSRange, AXUIElement) -> Bool,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                refocus: @escaping () -> AXUIElement? = { nil }
            ) {
                self.observe = observe
                self.select = select
                self.schedule = schedule
                self.refocus = refocus
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
                refocus: { AXContextChecker.shared.queryFocusedElement(allowTimeoutRetry: false).element }
            )
        }

        /// The three plain attributes are not how the selection was read. `SelectionReader` climbs
        /// a ladder — parameterized ranges, plural ranges, text markers — and a WebKit field can
        /// answer the original on one rung and leave `kAXSelectedText` blank on the next reading.
        /// Judging the replace on a weaker read than the capture made an intact selection look
        /// unreadable. The ladder is consulted only when the observation has no selected text and
        /// no range: a caret range is a real answer (the selection collapsed) and stays one.
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
        /// *again*, and a host restoring focus (Safari hands it to its web content over IPC) can
        /// answer blank for that instant. Bounded: a field that stays blind costs at most
        /// `settleAttempts × settleInterval`, then refuses as before.
        public static let settleAttempts = 4
        public static let settleInterval: TimeInterval = 0.05

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
                settlesRemaining: Self.settleAttempts, completion: completion
            )
        }

        private func judge(
            _ replacement: SelectionReplacement,
            element: AXUIElement?,
            refocused: Bool,
            settlesRemaining: Int,
            completion: @escaping (Verdict) -> Void
        ) {
            let decision = element.map {
                SelectionReplacementGuard.decide(original: replacement.original, observation: access.observe($0))
            } ?? .unverifiable
            let refocusedOn = refocused ? element : nil
            switch decision {
            case .proceed:
                completion(.confirmed(reselected: false, refocusedOn: refocusedOn))
            case .unverifiable:
                // Only a replacement that must prove its selection is worth waiting for; one read
                // by copy is delivered unverified either way.
                guard replacement.requiresEvidence, settlesRemaining > 0 else {
                    completion(Self.unjudged(replacement))
                    return
                }
                access.schedule(Self.settleInterval) {
                    let next = element ?? access.refocus()
                    judge(
                        replacement, element: next, refocused: refocused || (element == nil && next != nil),
                        settlesRemaining: settlesRemaining - 1, completion: completion
                    )
                }
            case .refuse(let refusal):
                completion(.refused(refusal))
            case .reselect(let range):
                guard let element, access.select(range, element) else {
                    completion(.refused(.reselectFailed))
                    return
                }
                readBack(
                    replacement, element: element, refocusedOn: refocusedOn,
                    remaining: Self.readBackAttempts, completion: completion
                )
            }
        }

        private func readBack(
            _ replacement: SelectionReplacement,
            element: AXUIElement,
            refocusedOn: AXUIElement?,
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
                    completion(.confirmed(reselected: true, refocusedOn: refocusedOn))
                } else if remaining > 1 {
                    readBack(
                        replacement, element: element, refocusedOn: refocusedOn,
                        remaining: remaining - 1, completion: completion
                    )
                } else {
                    completion(.refused(.reselectFailed))
                }
            }
        }

        private static func unjudged(_ replacement: SelectionReplacement) -> Verdict {
            replacement.requiresEvidence ? .refused(.unreadable) : .unverified
        }
    }
}
