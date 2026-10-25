import CoreGraphics
import Foundation

/// Whether an erase continue-check is looking at the field before anything is deleted, while
/// backspaces are being posted, or after they have finished and before the expansion is inserted.
enum EraseContinuationPhase: String, Equatable {
    case beforeErase
    /// Between HID backspaces. A node swap may continue only when the new element is this field
    /// with at most as many graphemes removed as this post has already authorized.
    case duringErase
    case beforeInsertion
}

/// What the live field says about the text the erase plan was going to delete.
///
/// `.triggerPresent` is positive evidence the erase did not land in this element: the planned
/// text is still the caret window. `.triggerAbsent` is positive evidence it is not.
/// `.unreadable` is neither — the value or the caret could not be judged, and a missing answer
/// must not be stored as "absent".
enum EraseFieldReading: String, Equatable {
    case triggerPresent
    case triggerAbsent
    case unreadable
}

/// Everything `EraseContinuation.decide` is allowed to see. No AX element, no field text, no
/// window server — the pipeline reads those and passes the answers in, so every branch is
/// reachable from a unit test.
struct EraseContinuationFacts: Equatable {
    var phase: EraseContinuationPhase
    var revisionCurrent: Bool
    var continuationBlock: InjectCompletionGuard.ContinuationBlock?
    var secureInputBlocked: Bool
    var axUntrusted: Bool
    /// `nil` when the captured target still matches the live focus under this phase's gates.
    var mismatch: PasteboardBroker.PasteTarget.Mismatch?
    /// Typed expansion whose caret was vouched and that is not replacing a selection.
    /// Undo, voice, and a selection replace stay false: they must not follow an element swap.
    var allowsRetarget: Bool
    /// The live field is the pre-delete field with a deletion this phase accepts.
    /// Ignored before the erase. During the post: no more graphemes are gone than have been
    /// posted. After the post: the whole trigger is gone, or the value is unreadable and the
    /// screen frames are the same control. The default refuses; a caller that did not look
    /// does not get a retarget.
    var deletionMatched: Bool = false
    /// Live erase precondition of the element focus points at now. Consulted only before the erase,
    /// and only `.ok` is a voucher. The reading taken on the element captured at inject start is
    /// not this value — that element can still say `.ok` after focus has moved.
    var livePrecondition: ErasePreconditionResult?
    /// Role of the element live focus just returned. `nil` when it could not be read.
    var liveRole: String?
    /// Caret-window reading of the live field. Consulted only after the erase.
    var fieldReading: EraseFieldReading?
    /// After the post: the live field is the pre-delete field with *some but not all* of the
    /// trigger gone. Every backspace has been posted by then, so this is a mirror still catching
    /// up, not a verdict — `mayClearOnReread` is what turns it into a second look.
    var deletionLagging: Bool = false
}

struct EraseContinuationRefusal: Equatable {
    var path: String
    var reason: String
    /// Attached to the diagnostic only for a target refusal, as `beforeErase:elementChanged`.
    /// Hard stops leave this nil so a Secure Input block is not printed as a focus bug.
    var recordedMismatch: String?
}

enum EraseContinuationDecision: Equatable {
    case proceed
    case retarget
    case refuse(EraseContinuationRefusal)
}

/// Pure owner of "the continue-check failed; do we follow the new element or refuse?"
///
/// A WebKit text field and a trusted app's caret both change identity between the moment the
/// target is captured and the moment `canContinue` reads them again, while the trigger the user
/// just typed is still at the caret. Refusing there drops a vouched expansion. Following the new
/// element when the process changed, the revision moved, or the live text cannot be vouched
/// pastes into whatever is focused now. This type is the whole policy; the pipeline only supplies
/// the readings and, on `.retarget`, adopts the element it just read.
enum EraseContinuation {
    /// Roles an element swap may land on, before the erase and after it. `AXSecureTextField` is a
    /// text-entry role and is deliberately absent: a secure field is not a retarget destination.
    /// Unstable roles (combo box, menu, list) are absent too — they already skip element identity
    /// after the erase, and a swap onto one is not a text field we may paste into.
    static let insertionRetargetRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
    ]

    static func roleAllowsInsertionRetarget(_ role: String?) -> Bool {
        guard let role else { return false }
        return insertionRetargetRoles.contains(role)
    }

    /// `.ok` is a voucher only when it means "the trigger is at the caret". An empty plan, a
    /// count-only plan, and a whitespace-only plan are also `.ok` — there was nothing to
    /// compare — and that answer must not license following a different element.
    static func substantivePrecondition(
        _ result: ErasePreconditionResult?,
        expectedText: String?
    ) -> ErasePreconditionResult? {
        guard let result else { return nil }
        guard case .ok = result else { return result }
        guard let expectedText, expectedText.contains(where: { !$0.isWhitespace }) else { return nil }
        return result
    }

    static func decide(_ facts: EraseContinuationFacts) -> EraseContinuationDecision {
        if let refusal = operationRefusal(facts) {
            return .refuse(refusal)
        }
        guard let mismatch = facts.mismatch else {
            return .proceed
        }
        let refusal = targetRefusal(facts.phase, mismatch)
        switch mismatch {
        case .noCapturedProcess, .processChanged, .focusLost, .focusArrived:
            return .refuse(refusal)
        case .elementChanged, .rangeChanged:
            break
        }
        guard facts.allowsRetarget else {
            return .refuse(refusal)
        }
        switch facts.phase {
        case .beforeErase:
            // The destination is a text field or it is not. A secure field, a combo box, a menu,
            // and a role we could not read are not places an expansion may follow a node swap,
            // even when their caret window happens to equal the trigger.
            guard roleAllowsInsertionRetarget(facts.liveRole) else {
                return .refuse(refusal)
            }
            // `.mismatch` and `.unavailable` both refuse. Unavailable includes the caret-geometry
            // downgrade and a split that the checker could not vouch; only a live `.ok` — the
            // expected text sitting at the caret of the element we just read — may retarget.
            // A vacuous `.ok` (nothing to delete) is not this voucher; the caller strips it
            // with `substantivePrecondition` before it arrives here.
            guard case .ok = facts.livePrecondition else {
                return .refuse(refusal)
            }
            return .retarget
        case .duringErase:
            // Still deleting. The trigger, or a suffix of it, is supposed to be at the caret
            // until the last key. `deletionMatched` is the only voucher: the live element is
            // the field we started from, with no more graphemes removed than we have posted.
            // A different empty field matches neither, so the post stops before the first key.
            guard mismatch == .elementChanged else {
                return .refuse(refusal)
            }
            guard roleAllowsInsertionRetarget(facts.liveRole) else {
                return .refuse(refusal)
            }
            guard facts.deletionMatched else {
                return .refuse(refusal)
            }
            return .retarget
        case .beforeInsertion:
            // Our backspaces are supposed to move the caret. A range change here is not evidence
            // of a new field, and it is not a license to paste elsewhere.
            guard mismatch == .elementChanged else {
                return .refuse(refusal)
            }
            guard roleAllowsInsertionRetarget(facts.liveRole) else {
                return .refuse(refusal)
            }
            // The trigger being gone, or the value being unreadable, is not a destination.
            // A different empty field and a different-text field both look like that. The
            // deletion has to be the one this erase posted.
            guard facts.deletionMatched else {
                return .refuse(refusal)
            }
            // The planned text still at the caret contradicts a completed deletion. Fail closed
            // rather than paste the expansion on top of the trigger.
            if facts.fieldReading == .triggerPresent {
                return .refuse(refusal)
            }
            return .retarget
        }
    }

    /// How many times a refusal after the erase may be re-read before it stands. Each re-read is
    /// one `AXSettleRetry.settleDelay`, so the whole wait is bounded at roughly 90 ms — and any
    /// keystroke in that time moves the input revision, which is a hard stop that is never
    /// re-read.
    static let maxSettleRereads = 3

    static func rereadBudgetRemains(attempt: Int) -> Bool {
        attempt >= 0 && attempt < maxSettleRereads
    }

    /// Whether a `.beforeInsertion` refusal may be a transient reading rather than a verdict.
    ///
    /// By then the trigger is *already gone* from the user's field: refusing leaves them with
    /// neither the trigger nor the expansion, and no way to restore either into a field that
    /// cannot be vouched. So before that stands, a reading that WebKit produces while a node is
    /// being replaced gets another look:
    ///
    /// * focus momentarily nothing (`.focusLost`),
    /// * focus momentarily on something that is not a text field (web area, group, window) or a
    ///   role that could not be read,
    /// * a live text field whose value is the pre-delete field with part of the trigger still in
    ///   it — the AX mirror lagging the backspaces.
    ///
    /// This widens nothing: the second look goes back through `decide` with the same vouchers. A
    /// different field, a secure field, another process, a moved caret, a hard stop and anything
    /// not a vouched typed expansion are never re-read.
    static func mayClearOnReread(_ facts: EraseContinuationFacts) -> Bool {
        guard facts.phase == .beforeInsertion,
              facts.allowsRetarget,
              operationRefusal(facts) == nil,
              let mismatch = facts.mismatch else {
            return false
        }
        switch mismatch {
        case .focusLost:
            return true
        case .elementChanged:
            if roleAllowsInsertionRetarget(facts.liveRole) {
                return !facts.deletionMatched && facts.deletionLagging
            }
            // A secure field is a destination we never follow, however briefly it is focused.
            return facts.liveRole != "AXSecureTextField"
        case .noCapturedProcess, .processChanged, .focusArrived, .rangeChanged:
            return false
        }
    }

    /// Whether the live field is `anchor` with a proper part of the trigger removed — including
    /// none of it. Only meaningful after the whole post: there, anything short of the full
    /// deletion is the mirror behind the keys, because the keys themselves are all sent.
    static func deletionIsLagging(
        anchor: EraseFieldPicture?,
        live: EraseFieldPicture?,
        expectedText: String?,
        caseInsensitive: Bool
    ) -> Bool {
        guard let expectedText,
              case .progress(let removed)? = deletionMatch(
                anchor: anchor,
                live: live,
                expectedText: expectedText,
                caseInsensitive: caseInsensitive,
                maxRemovedGraphemes: expectedText.count
              ) else {
            return false
        }
        return removed < expectedText.count
    }

    /// One AX reading of a field, with the text left out of `EraseContinuationFacts`. The
    /// pipeline stores the pre-delete reading and compares a later one; `decide` only sees
    /// whether that comparison succeeded.
    struct EraseFieldPicture: Equatable {
        var value: String?
        var caretLocation: Int?
        var selectionLength: Int?
        /// Screen frame (`kAXPosition` + `kAXSize`). Nil when either attribute is missing or
        /// the rect is not a positive finite size — a zero frame is not a control.
        var frame: CGRect?
    }

    /// How a live field relates to the field the erase started in.
    enum EraseDeletionMatch: Equatable {
        /// `removedGraphemes` of the trigger, taken from the caret backward, are gone and the
        /// caret sits where that deletion lands. `0` is the field before any backspace.
        case progress(removedGraphemes: Int)
        /// The value could not be read, and both screen frames are the same positive rect.
        /// A readable value that merely disagrees is not this case.
        case sameFrame
    }

    /// Screen points of slack for "this is the same control". WebKit's replacement node lands
    /// on the same text field; a different control does not sit one point away.
    static let frameIdentityTolerance: CGFloat = 1

    /// Nil when `frame` is missing, non-finite, or has no positive area.
    static func usableFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame else { return nil }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0 else {
            return nil
        }
        return frame
    }

    static func framesIdentifySameControl(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard let left = usableFrame(lhs), let right = usableFrame(rhs) else { return false }
        let slack = frameIdentityTolerance
        return abs(left.origin.x - right.origin.x) <= slack
            && abs(left.origin.y - right.origin.y) <= slack
            && abs(left.size.width - right.size.width) <= slack
            && abs(left.size.height - right.size.height) <= slack
    }

    /// Whether `live` is `anchor` after removing at most `maxRemovedGraphemes` graphemes of
    /// `expectedText` from the caret backward.
    ///
    /// A readable anchor matches only when its caret window is the trigger, so a picture of a
    /// different field cannot be the origin. An anchor whose value could not be read has no
    /// window; it matches an unreadable live value only when the screen frames are the same
    /// control. `k` runs from 0 upward and the first hit wins, which means a field that already
    /// looks partly deleted does not match when `maxRemovedGraphemes` is still 0. A remainder
    /// that does not name the field — nothing left, or only whitespace, controls, and
    /// default-ignorable characters such as a zero-width space — also requires those frames.
    /// A remainder that names the field matches on the surviving text and the caret; the frame
    /// may have moved because the view scrolled. A missing or negative live caret is not a
    /// position, so the text then matches only when the frames agree. A nil live value matches
    /// only `.sameFrame`. Readable text that is simply wrong does not fall through to the frame.
    static func deletionMatch(
        anchor: EraseFieldPicture?,
        live: EraseFieldPicture?,
        expectedText: String?,
        caseInsensitive: Bool,
        maxRemovedGraphemes: Int
    ) -> EraseDeletionMatch? {
        guard let anchor, let live, maxRemovedGraphemes >= 0 else { return nil }
        guard let expectedText, expectedText.contains(where: { !$0.isWhitespace }) else { return nil }
        if (anchor.selectionLength ?? 0) > 0 || (live.selectionLength ?? 0) > 0 { return nil }
        if let removed = textProgress(
            anchor: anchor,
            live: live,
            expectedText: expectedText,
            caseInsensitive: caseInsensitive,
            maxRemovedGraphemes: maxRemovedGraphemes
        ) {
            return .progress(removedGraphemes: removed)
        }
        // Empty string is a readable value (the field is empty). Only a missing value is
        // unreadable, and only then may the frame stand in for the text. A readable anchor
        // still has to have had the trigger at the caret. A missing anchor value has no
        // window, so the frame is the only evidence this is the field the erase started in.
        guard live.value == nil else { return nil }
        guard let anchorFrame = anchor.frame, let liveFrame = live.frame,
              framesIdentifySameControl(anchorFrame, liveFrame) else {
            return nil
        }
        if let anchorValue = anchor.value {
            guard let anchorCaret = anchor.caretLocation,
                  anchorCaretWindowIsTrigger(
                    value: anchorValue,
                    caret: anchorCaret,
                    expectedText: expectedText,
                    caseInsensitive: caseInsensitive
                  ) else {
                return nil
            }
        }
        return .sameFrame
    }

    /// The phase rule on top of `deletionMatch`. During the post any authorized prefix of the
    /// deletion continues. After the post only the whole trigger, or an unreadable value on the
    /// same frame, does. A partial suffix left in the field is still the trigger.
    static func deletionConfirms(
        phase: EraseContinuationPhase,
        anchor: EraseFieldPicture?,
        live: EraseFieldPicture?,
        expectedText: String?,
        caseInsensitive: Bool,
        maxRemovedGraphemes: Int
    ) -> Bool {
        guard phase != .beforeErase else { return false }
        switch deletionMatch(
            anchor: anchor,
            live: live,
            expectedText: expectedText,
            caseInsensitive: caseInsensitive,
            maxRemovedGraphemes: maxRemovedGraphemes
        ) {
        case nil:
            return false
        case .sameFrame:
            return true
        case .progress(let removed):
            if phase == .duringErase { return true }
            return removed == expectedText?.count
        }
    }

    private static func textProgress(
        anchor: EraseFieldPicture,
        live: EraseFieldPicture,
        expectedText: String,
        caseInsensitive: Bool,
        maxRemovedGraphemes: Int
    ) -> Int? {
        guard let anchorValue = anchor.value, let anchorCaret = anchor.caretLocation, anchorCaret >= 0 else {
            return nil
        }
        guard let liveValue = live.value else { return nil }
        // A negative caret is "no selection info", the same fact as a missing one.
        let liveCaret = live.caretLocation.flatMap { $0 >= 0 ? $0 : nil }
        guard anchorCaretWindowIsTrigger(
            value: anchorValue,
            caret: anchorCaret,
            expectedText: expectedText,
            caseInsensitive: caseInsensitive
        ) else {
            return nil
        }
        let graphemes = Array(expectedText)
        let limit = min(maxRemovedGraphemes, graphemes.count)
        for removedCount in 0...limit {
            let removedUnits = String(graphemes.suffix(removedCount)).utf16.count
            let newCaret = anchorCaret - removedUnits
            guard newCaret >= 0 else { continue }
            guard !ErasePreconditionChecker.splitsCharacter(anchorValue, start: newCaret, end: anchorCaret) else {
                continue
            }
            guard let expectedValue = deletingUTF16(anchorValue, from: newCaret, to: anchorCaret) else {
                continue
            }
            // A remainder that does not name the field is the same case as an empty value:
            // another control can hold exactly that whitespace, control, or zero-width scalar.
            if !remainderIdentifiesField(expectedValue) {
                guard framesAgree(anchor, live) else { continue }
            }
            guard sameFieldText(liveValue, expectedValue, caseInsensitive: caseInsensitive) else { continue }
            if let liveCaret {
                guard liveCaret == newCaret else { continue }
            } else {
                // No caret. The text alone can be another control; the frame has to agree.
                guard framesAgree(anchor, live) else { continue }
            }
            return removedCount
        }
        return nil
    }

    /// Strict window: the trigger sits immediately before the anchor caret. A trigger somewhere
    /// else in the field is not this caret, and the geometry downgrade is not a voucher for
    /// deleting from a picture we cannot align.
    private static func anchorCaretWindowIsTrigger(
        value: String,
        caret: Int,
        expectedText: String,
        caseInsensitive: Bool
    ) -> Bool {
        guard case .ok = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: expectedText, caseInsensitive: caseInsensitive),
            value: value,
            caretLocation: caret,
            selectionLength: 0,
            insertionPointFollowsExpectedText: false
        ) else {
            return false
        }
        return true
    }

    private static func deletingUTF16(_ value: String, from start: Int, to end: Int) -> String? {
        guard start >= 0, end >= start else { return nil }
        let units = value.utf16
        guard end <= units.count else { return nil }
        if start == end { return value }
        let lower = units.index(units.startIndex, offsetBy: start)
        let upper = units.index(lower, offsetBy: end - start)
        var kept: [UInt16] = []
        kept.reserveCapacity(units.count - (end - start))
        kept.append(contentsOf: units[..<lower])
        kept.append(contentsOf: units[upper...])
        return String(utf16CodeUnits: kept, count: kept.count)
    }

    /// Text the user can see. Whitespace, controls, and default-ignorable scalars (zero-width
    /// space, joiners, byte-order mark, soft hyphen, bidi marks) do not distinguish one control
    /// from another.
    private static func remainderIdentifiesField(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let properties = scalar.properties
            return !properties.isWhitespace
                && !properties.isDefaultIgnorableCodePoint
                && properties.generalCategory != .control
        }
    }

    private static func framesAgree(_ anchor: EraseFieldPicture, _ live: EraseFieldPicture) -> Bool {
        guard let anchorFrame = anchor.frame, let liveFrame = live.frame else { return false }
        return framesIdentifySameControl(anchorFrame, liveFrame)
    }

    private static func sameFieldText(_ lhs: String, _ rhs: String, caseInsensitive: Bool) -> Bool {
        let left = lhs.normalizedWhitespace
        let right = rhs.normalizedWhitespace
        if caseInsensitive {
            return left.lowercased() == right.lowercased()
        }
        return left == right
    }

    /// Caret-window reading. The planned text still at the caret means this element was not
    /// erased. The same text earlier in a long field does not: the erase can have landed and the
    /// word can remain above the caret. An empty plan cannot prove absence, so it fails closed
    /// as present. A live selection fails closed the same way — pasting would replace text the
    /// user has highlighted. `boundedContains` returning nil (the value is too large and no caret
    /// bounds it) stays `.unreadable`, never absent.
    static func fieldReading(
        expected: String?,
        value: String?,
        caretLocation: Int?,
        selectionLength: Int?,
        caseInsensitive: Bool
    ) -> EraseFieldReading {
        guard let expected, !expected.isEmpty else { return .triggerPresent }
        if let selectionLength, selectionLength > 0 { return .triggerPresent }
        guard let value else { return .unreadable }
        guard DeliveryVerifier.boundedContains(
            expected, in: value, caretLocation: caretLocation, caseInsensitive: caseInsensitive
        ) != nil else {
            return .unreadable
        }
        // `insertionPointFollowsExpectedText: false` keeps a readable disagreement as `.mismatch`
        // (absent) instead of the geometry downgrade, which is a before-erase HID recovery and
        // not evidence about whether the erase landed.
        switch ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: expected, caseInsensitive: caseInsensitive),
            value: value,
            caretLocation: caretLocation,
            selectionLength: selectionLength,
            insertionPointFollowsExpectedText: false
        ) {
        case .ok:
            return .triggerPresent
        case .mismatch:
            return .triggerAbsent
        case .unavailable:
            return .unreadable
        }
    }

    private static func operationRefusal(_ facts: EraseContinuationFacts) -> EraseContinuationRefusal? {
        let blocked = !facts.revisionCurrent
            || facts.continuationBlock != nil
            || facts.secureInputBlocked
            || facts.axUntrusted
        guard blocked else { return nil }
        // `targetCurrent: true` so this call never returns `.targetChanged`. The operation
        // conditions are exactly the ones `EntryGateRefusal` already names, in the same order,
        // and a mismatch that happens to be true beside them is not recorded.
        let refusal = EntryGateRefusal.classify(
            revisionCurrent: facts.revisionCurrent,
            continuationBlock: facts.continuationBlock,
            secureInputBlocked: facts.secureInputBlocked,
            axUntrusted: facts.axUntrusted,
            targetCurrent: true
        )
        return EraseContinuationRefusal(path: refusal.path, reason: refusal.reason, recordedMismatch: nil)
    }

    /// Refusal used when a retarget was not adopted. `mismatch` is nil only when the element
    /// that would have been adopted was missing; the recorded token is omitted then rather than
    /// inventing a half that did not move.
    static func unadoptedRefusal(
        _ phase: EraseContinuationPhase,
        _ mismatch: PasteboardBroker.PasteTarget.Mismatch?
    ) -> EraseContinuationRefusal {
        EraseContinuationRefusal(
            path: "eraseContextChanged",
            reason: phase == .beforeErase
                ? "Expansion cancelled — input or target application changed before erase"
                : "Expansion cancelled — input or target application changed before insertion",
            recordedMismatch: mismatch.map { "\(phase.rawValue):\($0.rawValue)" }
        )
    }

    private static func targetRefusal(
        _ phase: EraseContinuationPhase,
        _ mismatch: PasteboardBroker.PasteTarget.Mismatch
    ) -> EraseContinuationRefusal {
        unadoptedRefusal(phase, mismatch)
    }
}
