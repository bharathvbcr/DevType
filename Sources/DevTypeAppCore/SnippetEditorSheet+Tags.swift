import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

extension SnippetEditorController {
    // MARK: Tag suggestion

    /// Debounce before asking the model. Long enough that it does not fire mid-sentence;
    /// short enough to have an answer by the time the user reaches for Save.
    private static let tagSuggestionDebounce = Duration.milliseconds(900)

    /// Asks `SnippetTagSuggester` for tags once typing settles.
    ///
    /// New snippets only. Re-tagging an existing one would silently rewrite metadata the user
    /// may have curated by hand, and the sheet gives them no way to see that it happened.
    func scheduleTagSuggestion() {
        suggestionTask?.cancel()
        suggestionTask = nil
        guard existing == nil, SnippetTagSuggester.isActive else { return }
        let body = replacementView.string
        guard SnippetTagSuggester.shouldSuggest(body: body, isSecret: false) else {
            clearSuggestionChips()
            acceptance = nil
            return
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        let title = titleField.stringValue
        let names = groups.map(\.name)
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: Self.tagSuggestionDebounce)
            guard !Task.isCancelled else { return }
            let suggestion = await SnippetTagSuggester.suggest(
                title: title,
                body: body,
                isSecret: false,
                groupNames: names
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.applyTagSuggestion(suggestion) }
        }
        #endif
    }

    /// Offers the suggestion. Applies none of it.
    ///
    /// Every chip starts off. A suggestion that the user never looks at therefore changes
    /// nothing about the snippet they save, which is the point: the model's read of a
    /// half-written body is a guess, and a guess should not be able to write to the library
    /// just because the user was typing quickly.
    private func applyTagSuggestion(_ suggestion: SnippetTagSuggester.Suggestion) {
        clearSuggestionChips()
        let acceptance = TagSuggestionAcceptance(suggestion: suggestion)
        guard acceptance.hasAnythingToOffer else {
            self.acceptance = nil
            return
        }
        self.acceptance = acceptance

        guard let chipsRow else { return }
        for tag in suggestion.tags {
            let chip = ToggleChip(
                title: tag,
                symbol: "tag",
                isOn: false,
                help: loc.s("editor.tags.suggested.help"),
                target: self,
                action: #selector(suggestedTagChipTapped(_:))
            )
            suggestionChips.append(chip)
            insertChipBeforeTagField(chip, in: chipsRow)
        }
        if let name = suggestion.groupName {
            let chip = ToggleChip(
                title: name,
                symbol: "folder",
                isOn: false,
                help: loc.s("editor.group.suggested.help"),
                target: self,
                action: #selector(suggestedGroupChipTapped(_:))
            )
            groupSuggestionChip = chip
            suggestionChips.append(chip)
            insertChipBeforeTagField(chip, in: chipsRow)
        }

    }

    private func insertChipBeforeTagField(_ chip: ToggleChip, in row: NSStackView) {
        if let index = row.arrangedSubviews.firstIndex(of: newTagField) {
            row.insertArrangedSubview(chip, at: index)
        } else {
            row.addArrangedSubview(chip)
        }
    }

    private func clearSuggestionChips() {
        for chip in suggestionChips {
            chipsRow?.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        suggestionChips.removeAll()
        groupSuggestionChip = nil
        // A chip-driven group selection does not outlive the chip that caused it.
        if acceptance?.isGroupAccepted == true, let previous = groupSelectionBeforeSuggestion {
            selectGroup(id: previous)
        }
        groupSelectionBeforeSuggestion = nil
    }

    @objc private func existingTagChipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
    }

    /// Opens the scope editor. Unlike the other chips this one does not toggle: "all apps" is
    /// not the opposite of a specific list, and silently clearing one on a click would throw
    /// away exactly the thing the chip is advertising.
    @objc func appScopeChipTapped() {
        SnippetAppScopeSheet.present(
            from: view.window,
            scope: appScope,
            loc: loc
        ) { [weak self] result in
            guard let self, let result else { return }
            self.appScope = result
            self.appScopeChip?.isOn = result.isScoped
            self.appScopeChip?.title = SnippetAppScopeSummary.chipTitle(
                include: result.includeApps, exclude: result.excludeApps, loc: self.loc
            )
            self.appScopeChip?.needsDisplay = true
        }
    }

    func makeExistingTagChip(_ tag: String) -> ToggleChip {
        ToggleChip(
            title: tag,
            symbol: "tag.fill",
            isOn: true,
            help: loc.s("editor.tags.existing.help"),
            target: self,
            action: #selector(existingTagChipTapped(_:))
        )
    }

    func configureNewTagField() {
        newTagField.translatesAutoresizingMaskIntoConstraints = false
        newTagField.placeholderString = loc.s("editor.tags.add.placeholder")
        newTagField.font = DevTypeTheme.font(11, .medium)
        newTagField.isBordered = false
        newTagField.drawsBackground = false
        newTagField.focusRingType = .none
        newTagField.target = self
        newTagField.action = #selector(newTagEntered)
        newTagField.setAccessibilityLabel(loc.s("editor.tags.add.placeholder"))
        newTagField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newTagField.widthAnchor.constraint(equalToConstant: 120).isActive = true
    }

    /// Return in the tag field. The typed text goes through the same normalizer the model's
    /// suggestions do, so a hand-typed tag cannot carry a delimiter the exporter would read back
    /// as structure, and cannot duplicate one the snippet already has.
    @objc private func newTagEntered() {
        let raw = newTagField.stringValue
        let accepted = SnippetTagSuggester.normalizedTags([raw], existing: keptExistingTags)
        guard let tag = accepted.first else {
            // Rejected: empty, a duplicate, too long, or delimiter-bearing. Leave the text in
            // place rather than silently discarding what the user typed.
            NSSound.beep()
            return
        }
        let chip = makeExistingTagChip(tag)
        existingTagChips.append(chip)
        // Always before the entry field, so the field stays the last thing in the row.
        if let row = chipsRow, let index = row.arrangedSubviews.firstIndex(of: newTagField) {
            row.insertArrangedSubview(chip, at: index)
        } else {
            chipsRow?.addArrangedSubview(chip)
        }
        newTagField.stringValue = ""
    }

    /// Tags the user left switched on, in their stored order.
    var keptExistingTags: [String] {
        existingTagChips.filter(\.isOn).map(\.title)
    }

    @objc private func suggestedTagChipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
        acceptance?.setTag(sender.title, accepted: sender.isOn)
    }

    /// The one suggestion chip with an immediate effect — the group popup has to show the
    /// change for the user to judge it. Switching it back off restores what was selected before.
    @objc private func suggestedGroupChipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
        acceptance?.setGroupAccepted(sender.isOn)
        if sender.isOn {
            groupSelectionBeforeSuggestion = selectedGroupID
            if let name = acceptance?.suggestion.groupName,
               let group = groups.first(where: { $0.name == name }) {
                selectGroup(id: group.id)
            }
        } else if let previous = groupSelectionBeforeSuggestion {
            selectGroup(id: previous)
            groupSelectionBeforeSuggestion = nil
        }
    }

    private func selectGroup(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groupPopup.selectItem(at: index)
    }
}
