import AppKit
import Carbon.HIToolbox
import ExpanderEngine

extension SnippetManagerViewController {
    // MARK: - Bulk Operations

    @objc func selectAllSnippets() {
        flushPendingFilter()
        tableView.selectAll(nil)
    }

    @objc func bulkEnableSelected() {
        flushPendingFilter()
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })
        mutate(loc.s("manager.bulk.enable")) { groups in
            for gi in groups.indices {
                for si in groups[gi].snippets.indices {
                    if selectedIDs.contains(groups[gi].snippets[si].id) {
                        groups[gi].snippets[si].enabled = true
                    }
                }
            }
        }
    }

    @objc func bulkDisableSelected() {
        flushPendingFilter()
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })
        mutate(loc.s("manager.bulk.disable")) { groups in
            for gi in groups.indices {
                for si in groups[gi].snippets.indices {
                    if selectedIDs.contains(groups[gi].snippets[si].id) {
                        groups[gi].snippets[si].enabled = false
                    }
                }
            }
        }
    }

    @objc private func bulkMoveSelected(_ sender: NSButton) {
        guard !tableView.selectedRowIndexes.isEmpty else { return }
        // The selection is deliberately not captured here: `confirmBulkMove` reads it again
        // when a destination is chosen, and that later read is the one that must win.

        let menu = NSMenu()
        for group in groups {
            let item = NSMenuItem(title: group.name, action: #selector(confirmBulkMove(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    /// Menu items are not views, so anchor the destination chooser to the overflow
    /// control that opened them instead of force-casting the item to `NSButton`.
    @objc func bulkMoveFromOverflow(_ sender: NSMenuItem) {
        guard let bulkOverflowButton else { return }
        bulkMoveSelected(bulkOverflowButton)
    }

    @objc private func confirmBulkMove(_ sender: NSMenuItem) {
        guard let destID = sender.representedObject as? UUID else { return }
        let selectedRows = tableView.selectedRowIndexes
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })

        mutate(loc.s("manager.bulk.moveToGroup")) { groups in
            guard let destGI = groups.firstIndex(where: { $0.id == destID }) else { return }
            var movedSnippets: [SnippetModel] = []
            for gi in groups.indices {
                if groups[gi].id == destID { continue }
                movedSnippets.append(contentsOf: groups[gi].snippets.filter { selectedIDs.contains($0.id) })
                groups[gi].snippets.removeAll(where: { selectedIDs.contains($0.id) })
            }
            groups[destGI].snippets.append(contentsOf: movedSnippets)
        }
    }

    @objc func bulkDuplicateSelected() {
        flushPendingFilter()
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedSnippets = selectedRows.compactMap { $0 < snippets.count ? snippets[$0] : nil }
        guard selectedSnippets.count == selectedRows.count else { return }

        var stagedImagePaths: [String] = []
        var duplicationError: Error?
        let result = library.mutateGroups { latest in
            guard let targets = SnippetDuplicationPlanner.validatedTargets(
                for: selectedSnippets,
                in: latest
            ) else { return false }

            var planner = SnippetDuplicationPlanner(existing: latest.flatMap(\.snippets))
            var duplicatesByGroupIndex: [Int: [SnippetModel]] = [:]
            do {
                for target in targets {
                    let duplicate = try planner.duplicate(target.snippet) { path in
                        let copied = try self.duplicateImageAttachment(path)
                        stagedImagePaths.append(copied)
                        return copied
                    }
                    duplicatesByGroupIndex[target.groupIndex, default: []].append(duplicate)
                }
                for groupIndex in latest.indices {
                    latest[groupIndex].snippets.append(
                        contentsOf: duplicatesByGroupIndex[groupIndex] ?? []
                    )
                }
                return true
            } catch {
                duplicationError = error
                return false
            }
        }
        if let duplicationError {
            finishFailedDuplication(duplicationError, stagedImagePaths: stagedImagePaths)
            return
        }
        finishMutation(
            result,
            actionName: loc.s("manager.bulk.duplicate"),
            stagedImagePaths: stagedImagePaths
        )
    }

    @objc func bulkDeleteSelected() {
        flushPendingFilter()
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedSnippets = selectedRows.compactMap { $0 < snippets.count ? snippets[$0] : nil }
        let selectedIDs = Set(selectedSnippets.map(\.id))
        guard selectedIDs.count == selectedSnippets.count else {
            DevTypeAlert.warn(
                title: loc.s("library.save.title"),
                message: loc.s("manager.action.stale.message"),
                window: view.window
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = loc.s("manager.delete")
        alert.informativeText = loc.s("manager.bulk.selected", selectedIDs.count)
        alert.addButton(withTitle: loc.s("common.delete"))
        alert.addButton(withTitle: loc.s("common.cancel"))

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                self.mutateValidated(self.loc.s("manager.bulk.delete")) { groups in
                    let liveByID = Dictionary(grouping: groups.flatMap(\.snippets), by: \.id)
                    guard selectedSnippets.allSatisfy({ expected in
                        liveByID[expected.id] == [expected]
                    }) else { return false }
                    for gi in groups.indices {
                        groups[gi].snippets.removeAll(where: { selectedIDs.contains($0.id) })
                    }
                    return true
                }
            }
        }
    }

    @objc func bulkExportSelected() {
        flushPendingFilter()
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })
        guard !selectedIDs.isEmpty else { return }

        LibraryExporter.present(from: view.window, restrictedTo: selectedIDs)
    }

    @objc func bulkPrefixSuffixSelected() {
        flushPendingFilter()
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })

        let alert = NSAlert()
        alert.messageText = loc.s("manager.bulk.prefixSuffix.title")
        alert.addButton(withTitle: loc.s("manager.bulk.prefixSuffix.apply", selectedIDs.count))
        alert.addButton(withTitle: loc.s("common.cancel"))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 60)

        let prefixField = NSTextField()
        prefixField.placeholderString = loc.s("manager.bulk.prefixSuffix.prefix")
        let suffixField = NSTextField()
        suffixField.placeholderString = loc.s("manager.bulk.prefixSuffix.suffix")

        stack.addArrangedSubview(prefixField)
        stack.addArrangedSubview(suffixField)
        alert.accessoryView = stack

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                let prefix = prefixField.stringValue
                let suffix = suffixField.stringValue
                guard !prefix.isEmpty || !suffix.isEmpty else { return }

                self.mutate(self.loc.s("manager.bulk.prefixSuffix")) { groups in
                    for gi in groups.indices {
                        for si in groups[gi].snippets.indices {
                            if selectedIDs.contains(groups[gi].snippets[si].id) {
                                groups[gi].snippets[si].triggerKeyword = prefix + groups[gi].snippets[si].triggerKeyword + suffix
                            }
                        }
                    }
                }
            }
        }
    }
}
