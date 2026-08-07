import CoreGraphics
import Foundation

/// §8.3: what to do with a keystroke typed *while an expansion is still being delivered*.
///
/// The gap this closes: a match fires, the trigger is erased, and the replacement goes out as an
/// asynchronous clipboard paste. From ⌘V being posted to the text appearing is ~60–120 ms in a
/// native field and longer in a Chromium/Electron host. The tap used to pass every real keystroke
/// straight through during that window, so a fast typist's next character reached the field
/// *before* the paste did: typing `` `slmabout `` produced `aScholarLM` — the `a` overtook the
/// expansion it was supposed to follow.
///
/// The rule is ordering, not exclusion: characters typed during delivery are held here and
/// replayed after it, so the field ends up exactly as it would have with an instant expansion.
///
/// # The invariant
///
/// **Every admitted keystroke is replayed exactly once.** A dropped keystroke is worse than the
/// bug being fixed — the user watches a character they typed simply not appear. Every rule below
/// exists to keep that true, and each one gives up buffering rather than risk a keystroke:
///
///   * a hard `deadline`, so a stalled or crashed injection flushes rather than swallowing on
///   * a `capacity`, so a pathological burst cannot grow unbounded
///   * anything whose replay would be wrong — navigation, chords, Return, focus changes —
///     flushes what is queued and passes through, rather than being queued itself
///   * the caller must not admit anything when it cannot post events, since replay is a post
public struct TypeAheadBuffer: Equatable {
    /// What the tap should do with the event it is holding.
    public enum Decision: Equatable {
        /// Not our business — hand the event to the app untouched.
        case passThrough
        /// Hold the event; it is now this buffer's responsibility to replay.
        case swallow
        /// Replay everything queued, in order, then hand this event through. The event itself is
        /// never queued: it is one whose ordering relative to the expansion cannot be honoured.
        case flushThenPassThrough(replay: String)
    }

    /// Longest an expansion may hold the user's typing before the buffer gives up and lets the
    /// keys through in the wrong order.
    ///
    /// The wrong order is the bug this type exists to fix, so this is a deliberate surrender: it
    /// exists only so a hung injection cannot swallow a sentence. It is well past the ~120 ms a
    /// real delivery takes, and comfortably past the 50 ms AX settle plus paste round trip, while
    /// staying under the point where a user would notice their typing stall.
    public static let defaultDeadline: TimeInterval = 0.35

    /// Most characters held before giving up. A normal expansion overlaps one or two keystrokes;
    /// needing more than this means the injection is not behaving and the queue is not the place
    /// to find out.
    public static let defaultCapacity = 24

    public private(set) var queued: String = ""
    /// When the current hold must end regardless of what the injection is doing. `nil` when no
    /// expansion is in flight.
    public private(set) var deadline: Date?
    /// The app the hold began in. Replaying into a *different* app would type the user's
    /// characters into somewhere they never typed them, so a change here flushes.
    public private(set) var holdPID: pid_t?

    public let capacity: Int
    public let holdWindow: TimeInterval

    public init(
        capacity: Int = TypeAheadBuffer.defaultCapacity,
        holdWindow: TimeInterval = TypeAheadBuffer.defaultDeadline
    ) {
        self.capacity = max(1, capacity)
        self.holdWindow = max(0, holdWindow)
    }

    public var isHolding: Bool { deadline != nil }
    public var isEmpty: Bool { queued.isEmpty }

    // MARK: - Lifecycle

    /// An expansion started. Opens the hold window.
    public mutating func beginExpansion(focusPID: pid_t?, now: Date = Date()) {
        queued = ""
        deadline = now.addingTimeInterval(holdWindow)
        holdPID = focusPID
    }

    /// The expansion finished. Returns the text to replay (possibly empty) and closes the window.
    ///
    /// Must be called on *every* path that leaves the expanding state — success, failure, refuse,
    /// and the deferred-refuse path — or the invariant breaks.
    public mutating func endExpansion() -> String {
        let replay = queued
        queued = ""
        deadline = nil
        holdPID = nil
        return replay
    }

    /// The caret moved by some route this type never sees — a mouse click, a focus change, an
    /// Escape handled before admission. Releases the hold without waiting for the expansion.
    ///
    /// This is not optional politeness. A click is not a `keyDown`, so it never reaches `admit`;
    /// without an explicit flush the held characters are replayed *after* the click and land
    /// wherever the user clicked. Passing them through unheld would at least have left them at
    /// the old caret — holding them and replaying late actively moves the user's text, which is
    /// a worse failure than the transposition this type exists to fix.
    public mutating func flushForCaretChange() -> String { flush() }

    // MARK: - Admission

    /// Decide one keystroke.
    ///
    /// - Parameters:
    ///   - unicode: characters the key produced; empty for navigation/modifier-only events.
    ///   - isSynthetic: true for events DevType itself posted. Never queued — queueing our own
    ///     backspaces or ⌘V would deadlock the expansion behind its own output.
    ///   - resetsBuffer: true for keys the engine treats as caret-moving (arrows, Escape,
    ///     chords). Their ordering cannot be honoured, so they flush.
    ///   - focusPID: frontmost process for this event.
    public mutating func admit(
        unicode: String,
        isSynthetic: Bool,
        resetsBuffer: Bool,
        focusPID: pid_t? = nil,
        now: Date = Date()
    ) -> Decision {
        guard let deadline else { return .passThrough }
        // Our own injection output must reach the app or the expansion never lands.
        if isSynthetic { return .passThrough }

        // Past the window: the injection is not delivering. Give up ordering, keep the keystrokes.
        if now >= deadline { return .flushThenPassThrough(replay: flush()) }

        // A different app is focused than the one the hold began in. Replaying there would put
        // the user's characters somewhere they never typed them.
        if let holdPID, let focusPID, holdPID != focusPID {
            return .flushThenPassThrough(replay: flush())
        }

        // Navigation / chords / Escape: the caret is moving, so "after the expansion" is not a
        // position we can define. Return and Tab land here too — in a chat box they submit, and a
        // replay after submission types into the *next* message.
        if resetsBuffer || unicode.isEmpty { return .flushThenPassThrough(replay: flush()) }
        if unicode.contains(where: { $0.isNewline || $0 == "\t" }) {
            return .flushThenPassThrough(replay: flush())
        }

        // Backspace during delivery edits text that is still arriving; queueing it would apply it
        // to the expansion instead of to what the user was looking at.
        if unicode.unicodeScalars.contains(where: { $0.value == 0x08 || $0.value == 0x7F }) {
            return .flushThenPassThrough(replay: flush())
        }

        guard queued.count + unicode.count <= capacity else {
            return .flushThenPassThrough(replay: flush())
        }

        queued += unicode
        return .swallow
    }

    /// Empties the queue and closes the window — after a flush this buffer is no longer holding,
    /// so subsequent keys pass through until the next `beginExpansion`.
    private mutating func flush() -> String {
        let replay = queued
        queued = ""
        deadline = nil
        holdPID = nil
        return replay
    }
}
