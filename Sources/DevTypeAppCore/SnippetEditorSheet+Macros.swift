import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

extension SnippetEditorController {
    // MARK: Macro insertion

    /// §2: opens the searchable palette. This used to pop a flat `NSMenu` with a
    /// Date submenu plus nine hardcoded `(title, rawToken)` tuples — no search,
    /// no descriptions, no examples, and no exposure at all for the macros the
    /// engine gained since it was written (date arithmetic, case transforms,
    /// `%uuid%`, `%random:…%`, `%counter:…%`, the whole mustache syntax).
    @objc func showMacroMenu(_ sender: NSButton) {
        guard !hasImage else { return }
        let presented = MacroPalettePanel.present(
            from: view.window,
            loc: loc,
            onInsert: { [weak self] descriptor in
                self?.insert(descriptor: descriptor)
            }
        )
        // Lightweight fallback so the affordance is never dead.
        if !presented { showFallbackMacroMenu(from: sender) }
    }

    /// The command palette and this menu share one catalogue.
    private func macros(in category: MacroCategory) -> [MacroDescriptor] {
        CommandPaletteCatalog.macros(in: category)
    }

    func macro(id: String) -> MacroDescriptor? {
        CommandPaletteCatalog.macros.first { $0.id == id }
    }

    /// Fallback menu, built from the *same* catalogue as the palette so the two
    /// can never drift apart the way the old hardcoded menu drifted from the
    /// engine.
    private func showFallbackMacroMenu(from sender: NSButton) {
        let menu = NSMenu()
        for category in MacroCategory.allCases {
            let descriptors = macros(in: category)
            guard !descriptors.isEmpty else { continue }
            let parent = NSMenuItem(title: loc.s(category.titleKey), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for descriptor in descriptors {
                let name = descriptor.name(using: loc)
                let example = descriptor.example
                let item = NSMenuItem(
                    title: example.isEmpty ? name : "\(name) — \(example)",
                    action: #selector(insertMacroFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = descriptor.id
                item.toolTip = descriptor.detail(using: loc)
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func insertMacroFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let descriptor = macro(id: id) else { return }
        insert(descriptor: descriptor)
    }

    /// §2: smart insertion — the biggest win over the old menu. The token goes
    /// in, then its first editable span is *selected* so the user types straight
    /// over it instead of hand-editing raw macro syntax. Tab walks the rest.
    private func insert(descriptor: MacroDescriptor) {
        // Cleared first so the `didChangeText()` below has nothing stale to
        // shift; that notification also refreshes `lastTextLength` for us.
        placeholderRanges = []
        placeholderCursor = 0

        let selected = replacementView.selectedRange()
        let origin = selected.location
        replacementView.insertText(descriptor.token, replacementRange: selected)
        replacementView.didChangeText()
        view.window?.makeFirstResponder(replacementView)

        placeholderRanges = descriptor.placeholders.map {
            NSRange(location: origin + $0.offset, length: $0.length)
        }
        placeholderCursor = 0
        if !advanceToNextPlaceholder() {
            // No editable span: park the caret just after the token. That is the
            // right place for `%|`, `{{cursor}}` and the bare key macros.
            let length = (replacementView.string as NSString).length
            let end = min(origin + (descriptor.token as NSString).length, length)
            replacementView.setSelectedRange(NSRange(location: max(0, end), length: 0))
        }
        refreshPreview()
    }

    @discardableResult
    func advanceToNextPlaceholder() -> Bool {
        let length = (replacementView.string as NSString).length
        while placeholderCursor < placeholderRanges.count {
            let range = placeholderRanges[placeholderCursor]
            placeholderCursor += 1
            guard range.location >= 0, range.location <= length else { continue }
            let safe = NSRange(
                location: range.location,
                length: min(range.length, length - range.location)
            )
            replacementView.setSelectedRange(safe)
            replacementView.scrollRangeToVisible(safe)
            return true
        }
        placeholderRanges = []
        placeholderCursor = 0
        return false
    }
}
