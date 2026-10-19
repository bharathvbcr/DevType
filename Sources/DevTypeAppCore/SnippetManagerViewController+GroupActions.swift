import AppKit
import Carbon.HIToolbox
import ExpanderEngine

extension SnippetManagerViewController {
    // MARK: - Group actions

    @objc func addGroup() {
        GroupEditorSheet.present(
            from: view.window,
            existing: nil,
            validate: { [weak self] name in
                guard let self else { return nil }
                let clash = self.groups.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                return clash ? self.loc.s("groupeditor.error.duplicate", name) : nil
            },
            completion: { [weak self] draft in
                guard let self, let draft else { return }
                let group = SnippetGroup(
                    name: draft.name,
                    enabled: draft.enabled,
                    symbol: draft.symbol,
                    colorHex: draft.colorHex,
                    includeApps: draft.scope.includeApps,
                    excludeApps: draft.scope.excludeApps,
                    snippets: []
                )
                self.mutateValidated(
                    self.loc.s("manager.undo.addGroup"),
                    onCommit: { self.selectedGroupID = group.id }
                ) { groups in
                    guard !groups.contains(where: {
                        $0.name.caseInsensitiveCompare(group.name) == .orderedSame
                    }) else { return false }
                    groups.append(group)
                    return true
                }
            }
        )
    }

    @objc private func editSelectedGroup() {
        let row = groupOutline.selectedRow
        guard row > 0, row - 1 < groups.count else { return }
        let group = groups[row - 1]
        GroupEditorSheet.present(
            from: view.window,
            existing: group,
            validate: { [weak self] name in
                guard let self else { return nil }
                let clash = self.groups.contains {
                    $0.id != group.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
                }
                return clash ? self.loc.s("groupeditor.error.duplicate", name) : nil
            },
            completion: { [weak self] draft in
                guard let self, let draft else { return }
                self.mutateValidated(self.loc.s("manager.undo.editGroup")) { groups in
                    guard let index = groups.firstIndex(where: { $0.id == group.id }),
                          groups[index] == group else { return false }
                    guard !groups.contains(where: {
                        $0.id != group.id
                            && $0.name.caseInsensitiveCompare(draft.name) == .orderedSame
                    }) else { return false }
                    groups[index].name = draft.name
                    groups[index].symbol = draft.symbol
                    groups[index].colorHex = draft.colorHex
                    groups[index].enabled = draft.enabled
                    groups[index].includeApps = draft.scope.includeApps
                    groups[index].excludeApps = draft.scope.excludeApps
                    return true
                }
            }
        )
    }

    @objc private func toggleSelectedGroup() {
        let row = groupOutline.selectedRow
        guard row > 0, row - 1 < groups.count else { return }
        let groupID = groups[row - 1].id
        mutate(loc.s("manager.undo.toggleGroup")) { groups in
            guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[index].enabled.toggle()
        }
    }

    @objc private func deleteSelectedGroup() {
        let row = groupOutline.selectedRow
        guard row > 0, row - 1 < groups.count else { return }
        let group = groups[row - 1]

        guard groups.count > 1 else {
            DevTypeAlert.warn(
                title: loc.s("manager.group.delete.title"),
                message: loc.s("manager.group.delete.last"),
                window: view.window
            )
            return
        }

        let removeGroup: () -> Void = { [weak self] in
            guard let self else { return }
            self.mutateValidated(
                self.loc.s("manager.undo.deleteGroup"),
                onCommit: {
                    if self.selectedGroupID == group.id { self.selectedGroupID = nil }
                }
            ) { groups in
                guard groups.count > 1,
                      let index = groups.firstIndex(where: { $0.id == group.id }),
                      groups[index] == group else { return false }
                groups.remove(at: index)
                return true
            }
        }

        if group.snippets.isEmpty {
            removeGroup()
            return
        }

        // §6.2: was `"%@" contains %d snippet(s)` — a literal "(s)". Now a real
        // plural lookup that collapses to one form in Korean and Japanese.
        DevTypeAlert.present(
            title: loc.s("manager.group.delete.title"),
            message: loc.p(
                "manager.group.delete.message",
                count: group.snippets.count,
                group.name,
                group.snippets.count
            ),
            style: .warning,
            buttons: [
                loc.s("manager.group.delete.move"),
                loc.s("manager.group.delete.all"),
                loc.s("common.cancel")
            ],
            window: view.window
        ) { [weak self] index in
            guard let self else { return }
            switch index {
            case 0:
                // Move snippets into the next available group, then remove this one.
                var destinationID: UUID?
                self.mutateValidated(
                    self.loc.s("manager.undo.deleteGroup"),
                    onCommit: {
                        if self.selectedGroupID == group.id {
                            self.selectedGroupID = destinationID
                        }
                    }
                ) { groups in
                    guard let source = groups.firstIndex(where: { $0.id == group.id }),
                          groups[source] == group,
                          let destination = groups.firstIndex(where: { $0.id != group.id })
                    else { return false }
                    let moved = groups[source].snippets
                    groups.remove(at: source)
                    let adjusted = destination > source ? destination - 1 : destination
                    guard groups.indices.contains(adjusted) else { return false }
                    groups[adjusted].snippets.append(contentsOf: moved)
                    destinationID = groups[adjusted].id
                    return true
                }
            case 1:
                removeGroup()
            default:
                break
            }
        }
    }

    // MARK: - Library actions

    /// §4.6: "Reset Defaults" still requires destructive confirmation and uses the canonical
    /// resource-safe mutation path. It is registered for model-only undo only when the reset did
    /// not change the UUID-to-secret/image projection.
    @objc func resetDefaults() {
        DevTypeAlert.confirm(
            title: loc.s("alert.reset.title"),
            message: loc.s("alert.reset.message"),
            confirmTitle: loc.s("alert.reset.confirm"),
            destructive: true,
            window: view.window
        ) { [weak self] in
            guard let self else { return }
            self.finishMutation(
                library.resetToDefaults(),
                actionName: self.loc.s("manager.undo.reset")
            )
        }
    }

    /// §4.8: delegates to the shared flow instead of duplicating the panel,
    /// the hint text, and the result alert from `AppDelegate`.
    @objc func importSnippets() {
        SnippetImportFlow.present(from: view.window) { [weak self] in
            self?.reloadGroups()
        }
    }

    /// §0.4: JSON / Espanso YAML / CSV export.
    @objc func exportSnippets() {
        LibraryExporter.present(from: view.window)
    }

    /// Header gear — opens Preferences ▸ General without a trip to the menu bar.
    @objc func openSettings() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.openPreferences(nil, tab: .general)
        } else {
            PreferencesWindowController.shared.show(tab: .general, hotkeyManager: nil)
        }
    }

    /// §4.5: opens the statistics pane (Preferences ▸ Snippets).
    @objc func openStatistics() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.openPreferences(nil, tab: .snippets)
        } else {
            PreferencesWindowController.shared.show(tab: .snippets, hotkeyManager: nil)
        }
    }

    // MARK: - Context menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === groupContextMenu {
            buildGroupContextMenu(menu)
        } else if menu === snippetContextMenu {
            buildSnippetContextMenu(menu)
        }
    }

    private func buildGroupContextMenu(_ menu: NSMenu) {
        let row = groupOutline.clickedRow
        guard row > 0, row - 1 < groups.count else { return }
        groupOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let group = groups[row - 1]

        // §5.4: every item used to carry `keyEquivalent: ""`, so these were
        // right-click only. The equivalents shown here double as discoverability
        // for the `keyDown` handlers below.
        let edit = NSMenuItem(title: loc.s("manager.group.edit"), action: #selector(editSelectedGroup), keyEquivalent: "\r")
        edit.keyEquivalentModifierMask = []
        edit.target = self
        edit.image = DevTypeTheme.menuIcon("pencil")

        let toggle = NSMenuItem(
            title: group.enabled ? loc.s("manager.group.disable") : loc.s("manager.group.enable"),
            action: #selector(toggleSelectedGroup),
            keyEquivalent: " "
        )
        toggle.keyEquivalentModifierMask = []
        toggle.target = self
        toggle.image = DevTypeTheme.menuIcon(group.enabled ? "pause.circle" : "play.circle")

        let delete = NSMenuItem(
            title: loc.s("manager.group.delete"),
            action: #selector(deleteSelectedGroup),
            keyEquivalent: "\u{8}"
        )
        delete.keyEquivalentModifierMask = []
        delete.target = self
        delete.image = DevTypeTheme.menuIcon("trash")

        menu.items = [edit, toggle, .separator(), delete]
    }

    // MARK: - §5.4 Keyboard handling

    /// Delete removes, Return edits, ⌘D duplicates, Space toggles enabled.
    /// Returns true when the event was consumed.
    func handleSnippetKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)
        let hasSelection = tableView.selectedRow >= 0 && tableView.selectedRow < snippets.count

        if modifiers == .command, code == kVK_ANSI_A {
            selectAllSnippets()
            return true
        }
        if modifiers == .command, code == kVK_ANSI_D {
            guard hasSelection else { return true }
            if tableView.selectedRowIndexes.count > 1 {
                bulkDuplicateSelected()
            } else {
                duplicateSelectedSnippet()
            }
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch code {
        case kVK_Delete, kVK_ForwardDelete:
            guard hasSelection else { return true }
            if tableView.selectedRowIndexes.count > 1 {
                bulkDeleteSelected()
            } else {
                deleteSnippet()
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard hasSelection else { return true }
            editSelectedSnippet()
            return true
        case kVK_Space:
            guard hasSelection else { return true }
            if tableView.selectedRowIndexes.count > 1 {
                let anyDisabled = tableView.selectedRowIndexes.contains { $0 < snippets.count && !snippets[$0].enabled }
                if anyDisabled { bulkEnableSelected() } else { bulkDisableSelected() }
            } else {
                toggleSelectedSnippetEnabled()
            }
            return true
        default:
            return false
        }
    }

    /// Return edits the group, Delete removes it, Space toggles it.
    func handleGroupKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        let row = groupOutline.selectedRow
        // Row 0 is the synthetic "All Snippets" entry — it has no group actions.
        guard row > 0, row - 1 < groups.count else { return false }
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelectedGroup()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            editSelectedGroup()
            return true
        case kVK_Space:
            toggleSelectedGroup()
            return true
        default:
            return false
        }
    }

    /// Keyboard equivalent of clicking the row's enable switch.
    @objc private func toggleSelectedSnippetEnabled() {
        let row = tableView.selectedRow
        guard row >= 0, row < snippets.count else { return }
        let id = snippets[row].id
        mutate(loc.s("manager.undo.toggle")) { groups in
            for gi in groups.indices {
                if let si = groups[gi].snippets.firstIndex(where: { $0.id == id }) {
                    groups[gi].snippets[si].enabled.toggle()
                    break
                }
            }
        }
    }

    private func buildSnippetContextMenu(_ menu: NSMenu) {
        let row = tableView.clickedRow
        guard row >= 0, row < snippets.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let snippet = snippets[row]

        // §5.4: real key equivalents. Delete deletes, Return edits, ⌘D duplicates
        // — all also handled directly in `handleSnippetKeyDown`.
        let edit = NSMenuItem(title: loc.s("manager.edit"), action: #selector(editSelectedSnippet), keyEquivalent: "\r")
        edit.keyEquivalentModifierMask = []
        edit.target = self
        edit.image = DevTypeTheme.menuIcon("pencil")

        let duplicate = NSMenuItem(
            title: loc.s("manager.duplicate"),
            action: #selector(duplicateSelectedSnippet),
            keyEquivalent: "d"
        )
        duplicate.keyEquivalentModifierMask = [.command]
        duplicate.target = self
        duplicate.image = DevTypeTheme.menuIcon("plus.square.on.square")

        let delete = NSMenuItem(
            title: loc.s("manager.delete"),
            action: #selector(deleteSnippet),
            keyEquivalent: "\u{8}"
        )
        delete.keyEquivalentModifierMask = []
        delete.target = self
        delete.image = DevTypeTheme.menuIcon("trash")

        var items: [NSMenuItem] = [edit, duplicate]

        // "Move to Group" submenu listing every other group.
        let currentGI = groupIndex(for: snippet.id)?.0
        let destinations = groups.indices.filter { $0 != currentGI }
        if !destinations.isEmpty {
            let move = NSMenuItem(title: loc.s("manager.moveToGroup"), action: nil, keyEquivalent: "")
            move.image = DevTypeTheme.menuIcon("folder")
            let submenu = NSMenu()
            for gi in destinations {
                let group = groups[gi]
                let item = NSMenuItem(title: group.name, action: #selector(moveSelectedSnippetToGroup(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = group.id.uuidString
                item.image = DevTypeTheme.menuIcon(group.symbol)
                submenu.addItem(item)
            }
            move.submenu = submenu
            items.append(move)
        }

        items.append(.separator())
        items.append(delete)
        menu.items = items
    }
}
