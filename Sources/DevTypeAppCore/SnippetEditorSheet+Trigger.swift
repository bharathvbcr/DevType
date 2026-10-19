import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

extension SnippetEditorController {

    /// §1 / §3: one entry point for everything that reacts to the trigger — the
    /// hero chip, the guide's live rule sentence, and validation.
    func triggerDidChange() {
        let raw = triggerField.stringValue
        stage.updateTrigger(raw)
        // Rule (1): a punctuation-started trigger fires the moment it is typed and never
        // consults `requireWordBoundary`, so the chip must not present itself as live.
        let firstChar = raw.trimmingCharacters(in: .whitespacesAndNewlines).first
        let firesInstantly = firstChar.map { !AbbreviationMatcher.isWordCharacter($0) } ?? false
        boundaryChip?.inertReason = firesInstantly
            ? loc.s("editor.wordBoundary.inert", String(firstChar ?? " "))
            : nil
        guideView?.update(trigger: raw, requireWordBoundary: boundaryChip?.isOn ?? true)
        validateTriggerLive()
    }

    /// Live trigger check: a green ✓ when the trigger is usable, the conflict
    /// inline when it is not, and Save disabled until it is — no more
    /// type-everything-then-fail-on-Save.
    ///
    /// §3: also catches the silent failure mode. `AbbreviationMatcher`'s ring
    /// buffer caps at `matchableTriggerLimit` characters, so a longer trigger
    /// saves happily and then never fires; nothing used to say so.
    private func validateTriggerLive() {
        let trigger = triggerField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty else {
            isTriggerValid = false
            saveButton?.isEnabled = false
            triggerStatusLabel.stringValue = ""
            stage.setInvalid(false)
            setError(nil)
            setTriggerRule(loc.s("editor.trigger.hint"), isError: false)
            return
        }
        if trigger.count > AbbreviationMatcher.matchableTriggerLimit {
            isTriggerValid = false
            saveButton?.isEnabled = false
            triggerStatusLabel.stringValue = ""
            let message = loc.s("editor.error.tooLong", AbbreviationMatcher.matchableTriggerLimit)
            setError(message)
            stage.setInvalid(true)
            setTriggerRule(message, isError: true)
            return
        }
        if let conflict = SnippetTriggerAuthoringValidator.conflict(
            trigger: trigger,
            caseSensitive: caseChip?.isOn ?? false,
            requireWordBoundary: boundaryChip?.isOn ?? true,
            enabled: enabledChip?.isOn ?? true,
            excludingID: existing?.id,
            groups: groups
        ) {
            let message = triggerConflictMessage(conflict)
            isTriggerValid = false
            saveButton?.isEnabled = false
            triggerStatusLabel.stringValue = ""
            setError(message)
            stage.setInvalid(true)
            setTriggerRule(message, isError: true)
        } else {
            isTriggerValid = true
            saveButton?.isEnabled = true
            triggerStatusLabel.stringValue = "✓ " + loc.s("editor.trigger.available")
            triggerStatusLabel.textColor = DevTypeTheme.statusGreen
            triggerStatusLabel.setAccessibilityValue(loc.s("editor.trigger.available"))
            stage.setInvalid(false)
            setError(nil)
            // §1: the rule that only README ever stated, rendered against the
            // trigger the user actually typed.
            setTriggerRule(
                TriggerRuleDescription.text(
                    for: trigger,
                    requireWordBoundary: boundaryChip?.isOn ?? true,
                    loc: loc
                ),
                isError: false
            )
        }
    }

    func triggerConflictMessage(_ conflict: SnippetStore.TriggerConflict) -> String {
        switch conflict.kind {
        case .emptyTrigger:
            return loc.s("editor.error.emptyTrigger")
        case .duplicateTrigger:
            return loc.s("editor.error.conflict.duplicate", conflict.trigger)
        case .caseShadow:
            return loc.s("editor.error.conflict.caseShadow", conflict.trigger)
        case .prefixShadow:
            return loc.s(
                "editor.error.conflict.prefixShadow",
                conflict.trigger,
                conflict.blockedTriggerSummary ?? triggerField.stringValue
            )
        }
    }

    /// Single entry point for the inline error slot. `nil` collapses it to zero
    /// height so the space goes back to the composer; a message sizes the slot
    /// to the wrapped text (up to two lines) instead of letting it grow into the
    /// footer.
    func setError(_ message: String?) {
        guard let message, !message.isEmpty else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            errorHeightConstraint?.constant = 0
            if isViewLoaded { view.layoutSubtreeIfNeeded() }
            return
        }
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        // §4: an error that only appears visually is invisible to VoiceOver.
        errorLabel.setAccessibilityRole(NSAccessibility.Role.staticText)
        errorLabel.setAccessibilityValue(message)
        // Measured from the string, not `fittingSize` — the collapsing height
        // constraint below is part of the label's own layout, so asking the view
        // would just hand back whatever the constraint currently says.
        let font = errorLabel.font ?? DevTypeTheme.font(11, .medium)
        let bounds = (message as NSString).boundingRect(
            with: NSSize(width: errorLabel.preferredMaxLayoutWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        // Two lines max, matching `maximumNumberOfLines`. The slack matters: the
        // cell drops a line it cannot fit *entirely* rather than clipping it, so
        // a slot measured exactly to `boundingRect` silently loses line two.
        let lineCap = 2 * ceil(font.boundingRectForFont.height) + 6
        errorHeightConstraint?.constant = min(lineCap, ceil(bounds.height) + 6)
        if isViewLoaded { view.layoutSubtreeIfNeeded() }
    }

    private func setTriggerRule(_ text: String, isError: Bool) {
        triggerRuleLabel.stringValue = text
        triggerRuleLabel.textColor = isError ? DevTypeTheme.accentBright : DevTypeTheme.textTertiary
        triggerRuleLabel.toolTip = text
        // §5.2: colour never carries this alone — the sentence is the signal, and
        // the AX value repeats it verbatim.
        triggerRuleLabel.setAccessibilityValue(text)
    }
}
