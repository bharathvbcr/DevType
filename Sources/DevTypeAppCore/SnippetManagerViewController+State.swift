import AppKit
import Carbon.HIToolbox
import ExpanderEngine

extension SnippetManagerViewController {
    func localizationState() -> SnippetManagerLocalizationState {
        flushPendingFilter()
        let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { row in
            snippets.indices.contains(row) ? snippets[row].id : nil
        })
        return SnippetManagerLocalizationState(
            selectedGroupID: selectedGroupID,
            selectedSnippetIDs: selectedIDs,
            filterText: filterField.stringValue,
            filter: activeFilter,
            isCompactDensity: isCompactDensity,
            sortMode: sortMode,
            groupScrollOrigin: groupScroll.contentView.bounds.origin,
            snippetScrollOrigin: scrollView.contentView.bounds.origin
        )
    }

    /// Applies an app-level navigation request without inheriting stale local scope from a prior
    /// manager session. Insight actions describe the whole library, so a selected group or search
    /// query must not silently narrow their result set.
    func showAllSnippets(filteredBy filterChip: SnippetFilterChip) {
        // A navigation chip has no list state to apply: route before touching anything, so a
        // detour to the Secrets manager cannot leave this list half-reconfigured behind it.
        guard let filter = filterChip.listFilter else {
            (NSApp.delegate as? AppDelegate)?.openSecretManager(nil)
            return
        }
        _ = view
        selectedGroupID = nil
        hasResolvedInitialGroupSelection = true
        pendingRestoredSnippetIDs.removeAll()
        filterField.stringValue = ""
        activeFilter = filter
        tableView.deselectAll(nil)
        groupOutline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        for (chip, button) in filterChipButtons {
            button.style = chip == filter.chip ? .primary : .secondary
        }
        applyFilterAndReloadTable()
        if let button = filterChipButtons[filterChip] {
            button.scrollToVisible(button.bounds)
        }
    }

    func restoreLocalizationStateWhenLaidOut() {
        guard let restorationState else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let selectedRows = IndexSet(self.snippets.indices.filter {
                self.pendingRestoredSnippetIDs.contains(self.snippets[$0].id)
            })
            self.tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
            self.pendingRestoredSnippetIDs.removeAll()

            self.groupScroll.contentView.scroll(to: restorationState.groupScrollOrigin)
            self.groupScroll.reflectScrolledClipView(self.groupScroll.contentView)
            self.scrollView.contentView.scroll(to: restorationState.snippetScrollOrigin)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    func applyHealth(_ condition: LibraryCondition?) {
        healthBanner.apply(
            condition,
            onAction: { [weak self] in
                guard let self, let condition = LibraryHealthMonitor.shared.condition else { return }
                LibraryHealthPresenter.present(condition, window: self.view.window)
            },
            onDismiss: {
                LibraryHealthMonitor.shared.dismiss()
            }
        )
    }

    @objc func densityChanged() {
        isCompactDensity = densityControl.selectedSegment == 1
        tableView.rowHeight = isCompactDensity ? 38 : 52
        tableView.reloadData()
    }

    @objc func filterChipTapped(_ sender: NSButton) {
        guard let chip = SnippetFilterChip(rawValue: sender.tag) else { return }
        guard let filter = chip.listFilter else {
            (NSApp.delegate as? AppDelegate)?.openSecretManager(nil)
            return
        }
        activeFilter = filter
        for (c, btn) in filterChipButtons {
            btn.style = (c == chip ? .primary : .secondary)
        }
        applyFilterAndReloadTable()
    }

    /// Typing in the search field ran the whole pipeline — re-derive the pool, apply the chip
    /// filter, apply the text filter, sort, rebuild the empty state, reload the table — on every
    /// keystroke, with no coalescing. Trailing-edge debounce so a fast typist pays for it once.
    @objc func filterChanged() {
        filterDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.filterDebounce = nil
            self?.applyFilterAndReloadTable()
        }
        filterDebounce = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.filterDebounceInterval,
            execute: work
        )
    }

    /// Applies any pending debounced filter immediately. Anything that acts on the current list
    /// — pressing Return, opening the editor, a bulk action — must see what the user typed, not
    /// what the table happens to be showing mid-debounce.
    func flushPendingFilter() {
        guard let pending = filterDebounce else { return }
        pending.cancel()
        filterDebounce = nil
        applyFilterAndReloadTable()
    }

    @objc private func clearFilter() {
        filterField.stringValue = ""
        filterDebounce?.cancel()
        filterDebounce = nil
        applyFilterAndReloadTable()
    }

    @objc private func resetFilterChip() {
        activeFilter = .all
        for (c, btn) in filterChipButtons {
            btn.style = (c == .all ? .primary : .secondary)
        }
        applyFilterAndReloadTable()
    }

    @objc func sortModeChanged() {
        sortMode = SnippetSortMode(rawValue: sortPopup.selectedTag()) ?? .manual
        UserDefaults.standard.set(sortMode.rawValue, forKey: SnippetSortMode.defaultsKey)
        applyFilterAndReloadTable()
    }

    func reloadGroups() {
        let snapshot = library.loadGroupsWithRevision()
        // `groups` didSet clears `groupsRevision`, so the equality check has to run first.
        guard snapshot.revision != groupsRevision else { return }
        appliedReloadCount += 1
        groups = SnippetDocument(groups: snapshot.groups).groups
        groupsRevision = snapshot.revision
        if !hasResolvedInitialGroupSelection, let first = groups.first {
            selectedGroupID = first.id
            hasResolvedInitialGroupSelection = true
        }
        groupOutline.reloadData()
        if let id = selectedGroupID,
           let index = groups.firstIndex(where: { $0.id == id }) {
            groupOutline.selectRowIndexes(IndexSet(integer: index + 1), byExtendingSelection: false)
        } else {
            selectedGroupID = nil
            groupOutline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        applyFilterAndReloadTable()
    }

    func applyFilterAndReloadTable() {
        let filter = filterField.stringValue
        // Flattened once. The stats pill used to build a second copy of the whole library
        // immediately after the pool did.
        let all = groups.flatMap(\.snippets)
        let pool: [SnippetModel]
        if let id = selectedGroupID, let group = groups.first(where: { $0.id == id }) {
            pool = group.snippets
        } else {
            pool = all
        }

        var filtered = pool
        switch activeFilter {
        case .all:
            break
        case .enabled:
            filtered = filtered.filter(\.enabled)
        case .disabled:
            filtered = filtered.filter { !$0.enabled }
        case .images:
            filtered = filtered.filter(\.isImageSnippet)
        case .macros:
            filtered = filtered.filter { $0.replacementText.contains("%") || $0.replacementText.contains("{{") }
        case .conflicts:
            // Cached against the library revision: this is the O(n²)-shaped whole-library
            // analysis in `triggerConflicts()`, and running it inside the filter pass meant
            // running it on every keystroke in the search field.
            let conflicting = conflictSnippetIDs()
            filtered = filtered.filter { conflicting.contains($0.id) }
        case .unused:
            // One dictionary read rather than one locked store call per snippet.
            let counts = library.usageCountsByID()
            filtered = filtered.filter { max($0.usageCount, counts[$0.id] ?? 0) == 0 }
        case .tagged:
            filtered = filtered.filter { !$0.tags.isEmpty }
        }

        if !filter.isEmpty {
            let matchingIDs = SnippetManagerFilter.matchingIDs(in: groups, query: filter, revision: groupsRevision)
            filtered = filtered.filter { matchingIDs.contains($0.id) }
        }
        // Selection survives the reload: refining a search after selecting rows for a bulk
        // operation used to silently drop the selection, because `reloadData()` clears it.
        let selectedIDs = Set(tableView.selectedRowIndexes.compactMap {
            snippets.indices.contains($0) ? snippets[$0].id : nil
        })
        snippets = sorted(filtered)
        tableView.sortDescriptors = sortMode.sortDescriptor.map { [$0] } ?? []
        let active = all.filter(\.enabled).count
        statsPill.update(text: loc.s("manager.stats", active, all.count), tint: DevTypeTheme.accent)

        emptyState.isHidden = !snippets.isEmpty
        if snippets.isEmpty {
            let title: String
            let subtitle: String
            let cta: String?
            let action: Selector?

            if let issue = SnippetSearch.queryIssue(for: filter) {
                title = loc.s("search.issue.title")
                subtitle = issue.message(loc: loc)
                cta = loc.s("common.clear")
                action = #selector(clearFilter)
            } else if !filter.isEmpty {
                title = loc.s("snippets.empty.noMatch", filterField.stringValue)
                subtitle = ""
                cta = loc.s("common.clear")
                action = #selector(clearFilter)
            } else if activeFilter != .all {
                title = loc.s(activeFilter.localizationKey)
                subtitle = loc.s("snippets.empty.noMatch", "")
                cta = loc.s("manager.filter.all")
                action = #selector(resetFilterChip)
            } else {
                title = loc.s("manager.empty.title")
                subtitle = loc.s("manager.empty.subtitle")
                cta = loc.s("manager.add")
                action = #selector(addSnippet)
            }

            emptyState.configure(
                title: title,
                subtitle: subtitle,
                ctaTitle: cta,
                target: self,
                action: action
            )
        }
        tableView.reloadData()
        restoreSelection(ids: selectedIDs)
        updateBulkBar()
    }

    /// Re-selects the rows still present after a filter or sort change.
    ///
    /// `reloadData()` clears selection, so without this every keystroke in the search field
    /// discarded whatever the user had picked — including a multi-row selection they were
    /// assembling for a bulk action.
    private func restoreSelection(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let rows = IndexSet(snippets.indices.filter { ids.contains(snippets[$0].id) })
        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { tableView.scrollRowToVisible(first) }
    }

    /// Snippet IDs in a trigger conflict, cached against the library revision.
    private func conflictSnippetIDs() -> Set<UUID> {
        let revision = library.libraryRevision
        if let cached = cachedConflictIDs, cachedConflictRevision == revision {
            return cached
        }
        let ids = Set(library.triggerConflicts().flatMap(\.snippetIDs))
        cachedConflictIDs = ids
        cachedConflictRevision = revision
        return ids
    }

    func updateBulkBar() {
        let count = tableView.selectedRowIndexes.count
        if count > 1 {
            bulkBar.isHidden = false
            primaryActionBar?.isHidden = true
            utilityActionBar?.isHidden = true
            selectedCountLabel.stringValue = loc.s("manager.bulk.selected", count)
        } else {
            bulkBar.isHidden = true
            primaryActionBar?.isHidden = false
            utilityActionBar?.isHidden = false
        }
    }

    /// §4.6: applies the active sort. `manual` preserves storage order, which is
    /// also the only mode where drag-to-reorder is meaningful.
    /// Decorate, sort, undecorate.
    ///
    /// Every one of these comparators used to do its expensive work *inside* the comparison:
    /// `.usage` and `.recentlyUsed` called into `SnippetStore` twice per comparison, each call
    /// taking a lock in `UsageStatsStore` (roughly `2 n log n` lock acquisitions for one sort),
    /// and `.title` / `.trigger` ran `localizedStandardCompare` — among the most expensive
    /// comparisons Foundation offers — the same way. Computing each key once per element makes
    /// it `n` reads instead.
    private func sorted(_ input: [SnippetModel]) -> [SnippetModel] {
        switch sortMode {
        case .manual:
            return input
        case .title:
            return sortedByKey(input, key: \.displayTitle) {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        case .trigger:
            return sortedByKey(input, key: \.triggerKeyword) {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        case .usage:
            // §4.5: usage lives in the sidecar, not on the model.
            let counts = library.usageCountsByID()
            return sortedByKey(input, key: { max($0.usageCount, counts[$0.id] ?? 0) }, by: >)
        case .recentlyUsed:
            let lastUsed = library.lastUsedByID()
            return sortedByKey(input, key: { lastUsed[$0.id] ?? Date.distantPast }, by: >)
        case .recentlyEdited:
            return sortedByKey(input, key: \.updatedAt, by: >)
        }
    }

    /// Sorts by a key computed once per element. Ties keep their input order, so a re-sort of an
    /// unchanged list does not reshuffle rows under the user.
    private func sortedByKey<Key>(
        _ input: [SnippetModel],
        key: (SnippetModel) -> Key,
        by areInIncreasingOrder: (Key, Key) -> Bool
    ) -> [SnippetModel] {
        input.enumerated()
            .map { (offset: $0.offset, key: key($0.element), value: $0.element) }
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.key, rhs.key) { return true }
                if areInIncreasingOrder(rhs.key, lhs.key) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.value)
    }
}
