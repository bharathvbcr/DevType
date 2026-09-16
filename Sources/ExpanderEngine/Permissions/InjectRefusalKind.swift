import Foundation

/// The finite, structured vocabulary of *why* an injection was refused.
///
/// ## Why this type exists
///
/// `InjectOutcome.refused` carries a `String`. Before this type, the pipeline's own branch
/// identifier (`path` — `"erasePrecondition"`, `"entryGate_secureInput"`, `"axOnlyRange"`, …)
/// was consumed by `PermissionCoordinator.sanitizedRefusalReason` to pick a sentence and then
/// **discarded**. Every downstream consumer that needed to know what actually happened had to
/// re-derive it by substring-matching that English sentence.
///
/// That re-derivation was lossy in both directions:
///
///   * Most refusals matched nothing and fell through to the generic "click into a normal text
///     field (not a password field)" guidance — including `erasePrecondition`, where the user
///     *was* in a normal text field, and the Post Events refusals, where the advice named the
///     wrong subsystem entirely.
///   * Matching on prose is also a localisation trap: the sanitised sentence is English by
///     construction, so any consumer keyed to it silently stops working the moment that
///     assumption changes.
///
/// ## The invariant
///
/// `classify(reason:path:)` is the **single** owner of the (reason, path) → meaning mapping.
/// It returns the kind *and* the sentence from one switch, so a new refusal path cannot acquire
/// a sentence without also acquiring a kind — the two cannot drift apart. `sanitizedRefusalReason`
/// delegates here rather than keeping a parallel switch.
///
/// Callers that need to *act* on a refusal (guidance, remedy, whether restarting the engine could
/// plausibly help) switch over `InjectRefusalKind`. Callers that need to *show* the refusal use
/// `sentence`. Nothing string-matches prose.
public enum InjectRefusalKind: String, Equatable, Sendable, CaseIterable {
    // Attachment / payload
    case imageMissing
    case imageUnavailable
    case fillInRequired

    // Post Events (HID) permission, by the surface that needed it
    case shellPostEventsRequired
    case axFallbackPostEventsRequired
    case postEventsRequired

    // Erase guard — the field did not hold what we were about to delete
    case erasePrecondition
    case eraseIncomplete

    // Target moved out from under the insertion
    case targetChangedBeforeInsertion
    case targetAppChanged
    case targetElementChanged
    case contextChanged
    case superseded

    // Secure clipboard
    case secureClipboardImageUnsupported
    case secureClipboardUnavailable

    // Undo
    case undoUnverifiable
    case undoOriginalPosition
    case undoSelectionActive
    case undoContextChanged
    case undoUnsafe

    // Environment gates
    case secureInput
    case accessibilityUnavailable
    case imeMarkedText
    case focusUnavailable

    // Panel-driven delivery (AI result, palette value, inline search expansion)
    case selectionSourceUnavailable

    case unknown

    /// Whether restarting the event tap could plausibly change this outcome.
    ///
    /// This gates the "Expansion Failed — Restart Engine" menu item. Almost every refusal here is
    /// a *correct, per-expansion decision* by a guard that was working: the erase precondition
    /// held the line, the target moved, Secure Input was up, a newer expansion superseded this
    /// one. Restarting the engine does nothing for any of them, and offering it as the remedy
    /// sends the user to Permission Recovery to read "All capabilities granted" — which is how a
    /// healthy engine comes to look broken.
    ///
    /// Only `unknown` qualifies: an unclassified refusal is the one case where we genuinely do not
    /// know that the engine is fine, so the escape hatch stays offered. Permission problems are
    /// deliberately excluded — a missing TCC grant is fixed in System Settings, not by a restart,
    /// and those kinds route to their own guidance below.
    public var warrantsEngineRestart: Bool {
        self == .unknown
    }

    /// Localisation key for the Permission Recovery guidance line — what the user should actually
    /// do. Every kind names a remedy; `unknown` keeps the historical generic sentence.
    public var guidanceKey: String {
        switch self {
        case .accessibilityUnavailable:
            return "recovery.refuse.ax"
        case .secureInput:
            return "recovery.refuse.secureInput"
        case .imeMarkedText:
            return "recovery.refuse.ime"
        case .focusUnavailable:
            return "recovery.refuse.focus"
        case .erasePrecondition, .eraseIncomplete:
            return "recovery.refuse.erase"
        case .postEventsRequired, .shellPostEventsRequired, .axFallbackPostEventsRequired:
            return "recovery.refuse.postEvents"
        case .targetChangedBeforeInsertion, .targetAppChanged, .targetElementChanged,
             .contextChanged, .superseded:
            return "recovery.refuse.targetMoved"
        case .fillInRequired:
            return "recovery.refuse.fillIn"
        case .imageMissing, .imageUnavailable:
            return "recovery.refuse.image"
        case .secureClipboardImageUnsupported, .secureClipboardUnavailable:
            return "recovery.refuse.secureClipboard"
        case .undoUnverifiable, .undoOriginalPosition, .undoSelectionActive,
             .undoContextChanged, .undoUnsafe:
            return "recovery.refuse.undo"
        case .selectionSourceUnavailable:
            return "recovery.refuse.selectionSource"
        case .unknown:
            return "recovery.refuse.generic"
        }
    }

    /// Whether `guidanceKey`'s string takes the refusal sentence as a `%@` argument.
    ///
    /// Kept beside `guidanceKey` on purpose: a key and its arity are one fact, and splitting them
    /// across two switches is how a format-specifier crash gets introduced. `LocalizationParityTests`
    /// enforces the specifier count in the tables; this enforces that we pass what they expect.
    public var guidanceTakesReason: Bool {
        switch self {
        case .accessibilityUnavailable, .unknown:
            return true
        default:
            return false
        }
    }
}

/// A classified refusal: the structured meaning plus the sanitised sentence, produced together.
public struct InjectRefusal: Equatable, Sendable {
    public let kind: InjectRefusalKind
    public let sentence: String

    public init(kind: InjectRefusalKind, sentence: String) {
        self.kind = kind
        self.sentence = sentence
    }
}

extension InjectRefusalKind {
    /// The single owner of (raw reason, pipeline path) → meaning.
    ///
    /// Raw refusal prose can contain attachment paths or text-mismatch evidence, so the sentence
    /// this returns is the only form allowed to reach public OSLog, the telemetry ring, status UI,
    /// or a copied diagnostic report.
    public static func classify(_ reason: String, path: String?) -> InjectRefusal {
        switch path {
        case "imagePaste":
            return reason.contains("missing or unreadable")
                ? InjectRefusal(kind: .imageMissing, sentence: "Image attachment missing or unreadable")
                : InjectRefusal(kind: .imageUnavailable, sentence: "Image paste unavailable")
        case "fillInRequired":
            return InjectRefusal(kind: .fillInRequired,
                                 sentence: "Fill-in values are required before insertion")
        case "shellNoPostEvents":
            return InjectRefusal(
                kind: .shellPostEventsRequired,
                sentence: "Post Events permission is required for multi-line shell insertion"
            )
        case "eraseContextChanged":
            return InjectRefusal(kind: .targetChangedBeforeInsertion,
                                 sentence: "Input or target application changed before insertion")
        case "eraseIncomplete":
            return InjectRefusal(kind: .eraseIncomplete, sentence: "Trigger erase did not complete")
        case "erasePrecondition", "guardedErase":
            return InjectRefusal(kind: .erasePrecondition,
                                 sentence: "Erase precondition failed — the target text changed")
        case "axOnlyRange":
            return InjectRefusal(
                kind: .axFallbackPostEventsRequired,
                sentence: "AX insertion failed — Post Events permission is required for fallback"
            )
        case "secureClipboardPaste":
            return reason.contains("image")
                ? InjectRefusal(kind: .secureClipboardImageUnsupported,
                                sentence: "Secure clipboard insertion does not support images")
                : InjectRefusal(kind: .secureClipboardUnavailable,
                                sentence: "Secure clipboard insertion unavailable")
        case "undoUnverifiable":
            return InjectRefusal(
                kind: .undoUnverifiable,
                sentence: "Undo refused — target could not be read after intervening input"
            )
        case "undoOriginalPosition":
            return InjectRefusal(
                kind: .undoOriginalPosition,
                sentence: "Undo refused — original insertion position could not be verified"
            )
        case "undoSelection":
            return InjectRefusal(kind: .undoSelectionActive,
                                 sentence: "Undo refused — a text selection is active")
        case "undoContextChanged":
            return InjectRefusal(kind: .undoContextChanged,
                                 sentence: "Undo cancelled — input, target, or settings changed")
        case "undo", "undoAXRange", "undoAXDirect", "undoPaste":
            return InjectRefusal(kind: .undoUnsafe,
                                 sentence: "Undo refused — safe reversal could not be verified")
        // Entry gate. These stay distinct from each other on purpose: they are the difference
        // between "the source app never came back to the front" and "it did, then the focused
        // element moved", and collapsing them would leave the next report as uninformative as
        // the silent `return` these replaced.
        case "entryGate_superseded":
            return InjectRefusal(kind: .superseded, sentence: "Insertion superseded by a newer one")
        case "entryGate_continuation":
            return InjectRefusal(kind: .targetAppChanged,
                                 sentence: "Target application changed before insertion")
        case "entryGate_secureInput":
            return InjectRefusal(kind: .secureInput,
                                 sentence: "Secure Input is active — expansion blocked")
        case "entryGate_accessibility":
            return InjectRefusal(kind: .accessibilityUnavailable,
                                 sentence: "Accessibility unavailable — expansion blocked")
        case "entryGate_targetChanged":
            return InjectRefusal(kind: .targetElementChanged,
                                 sentence: "Target element or selection changed before insertion")
        case "entryGate_unreproduced":
            return InjectRefusal(kind: .contextChanged,
                                 sentence: "Insertion context changed before insertion")
        // Panel-driven delivery (AI result, palette value, inline search expansion): the payload
        // was already generated, so each of these is lost work, not a declined expansion.
        case "aiResultDelivery", "paletteTextDelivery", "searchExpansionDelivery":
            // `SelectionReader.SourceUnavailability` owns this vocabulary and already speaks the
            // report's register, so it passes through intact. Flattening every cause to one
            // sentence here is what made a refusal with DevType itself frontmost read as "the
            // source app did not come back" — a sentence about an app that had never left.
            // Anything outside that vocabulary is internal prose and still gets the generic one.
            let known = SelectionReader.SourceUnavailability.allCases.contains { $0.reason == reason }
            return InjectRefusal(
                kind: .selectionSourceUnavailable,
                sentence: known ? reason : SelectionReader.SourceUnavailability.focusNeverReturned.reason
            )
        case "aiResultPlanRefused", "searchExpansionPlanRefused":
            return reason.localizedCaseInsensitiveContains("post events")
                ? InjectRefusal(kind: .postEventsRequired,
                                sentence: "Post Events permission is required for insertion")
                : InjectRefusal(kind: .accessibilityUnavailable,
                                sentence: "Accessibility unavailable — expansion blocked")
        default:
            break
        }

        if reason.localizedCaseInsensitiveContains("secure input") {
            return InjectRefusal(kind: .secureInput,
                                 sentence: "Secure Input is active — expansion blocked")
        }
        if reason.localizedCaseInsensitiveContains("ime") {
            return InjectRefusal(kind: .imeMarkedText,
                                 sentence: "Active IME marked text — expansion blocked")
        }
        if reason.localizedCaseInsensitiveContains("accessibility")
            || reason.contains("AXIsProcessTrusted") {
            return InjectRefusal(kind: .accessibilityUnavailable,
                                 sentence: "Accessibility unavailable — expansion blocked")
        }
        if reason.localizedCaseInsensitiveContains("post events") {
            return InjectRefusal(kind: .postEventsRequired,
                                 sentence: "Post Events permission is required for insertion")
        }
        if reason.localizedCaseInsensitiveContains("focused")
            || reason.localizedCaseInsensitiveContains("focus") {
            return InjectRefusal(kind: .focusUnavailable,
                                 sentence: "Focused text field unavailable — expansion blocked")
        }
        if reason.localizedCaseInsensitiveContains("erase precondition") {
            return InjectRefusal(kind: .erasePrecondition,
                                 sentence: "Erase precondition failed — the target text changed")
        }
        if reason.localizedCaseInsensitiveContains("target application changed")
            || reason.localizedCaseInsensitiveContains("input or target") {
            return InjectRefusal(kind: .targetChangedBeforeInsertion,
                                 sentence: "Input or target application changed before insertion")
        }
        return InjectRefusal(kind: .unknown, sentence: "Injection refused")
    }
}
