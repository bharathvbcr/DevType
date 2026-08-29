import Foundation

/// A resolved AI action: which transform to run, and the user's own instructions when the
/// transform is `.custom`.
///
/// `.custom`'s own prompt is a thin wrapper ("transform the text according to the additional
/// instructions provided with the request") — it carries no direction at all. The direction
/// lives entirely in `customInstructions`, so any path that produces a `.custom` action
/// without carrying that text forward runs the model on nothing. This type exists so the
/// two pickers that can produce one — `AIActionPanel` (hotkey) and the ⌘/ command palette —
/// resolve it the same way, and so the pairing cannot be split apart in transit.
public struct AIActionSelection: Equatable, Sendable {
    public let kind: AITransformKind
    /// User-authored prompt. `nil` for built-in kinds, and never empty: an empty string and
    /// "no instructions" mean the same thing to the model, so only one of them is
    /// representable here.
    public let customInstructions: String?

    public init(kind: AITransformKind, customInstructions: String? = nil) {
        self.kind = kind
        self.customInstructions = customInstructions.flatMap(Self.normalized)
    }

    /// Whether the result must be shown in the preview panel rather than injected directly.
    ///
    /// A user-authored instruction is open-ended — nothing bounds what the model returns —
    /// so it is never written straight over the selection, regardless of the per-kind output
    /// mode a user configured for `.custom`.
    public var requiresPreview: Bool {
        kind == .custom || customInstructions != nil
    }

    // MARK: - Normalization

    /// Trims user-typed instruction text; `nil` when nothing is left to run.
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Joins instruction fragments in the order given, dropping the empty ones.
    ///
    /// Additive on purpose: a preset (the preview panel's tone menu) refines the user's
    /// request, it does not stand in for it. Overwriting is how a typed instruction
    /// disappeared behind a tone choice.
    public static func merged(_ parts: [String?]) -> String? {
        let pieces = parts.compactMap { $0.flatMap(normalized) }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    // MARK: - Panel resolution

    /// What ⏎ in the AI action panel should run.
    ///
    /// The instruction field wins while it is being edited — the user typed there last, and
    /// the highlighted row is only the list's resting selection. Everything else confirms
    /// the highlighted built-in action. `nil` means there is nothing to run (empty field,
    /// no matching row) and the keystroke should do nothing.
    public static func confirmingReturn(
        instructionFieldText: String,
        isEditingInstructionField: Bool,
        highlightedAction: AITransformKind?
    ) -> AIActionSelection? {
        if isEditingInstructionField, let instructions = normalized(instructionFieldText) {
            return AIActionSelection(kind: .custom, customInstructions: instructions)
        }
        guard let highlightedAction else { return nil }
        return AIActionSelection(kind: highlightedAction)
    }
}
