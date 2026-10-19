import CryptoKit
import Foundation

extension SnippetStore {
    /// §1.10: `.merge` shim preserving the original signature.
    @discardableResult
    public func importGroups(_ imported: [SnippetGroup]) -> SaveOutcome {
        importGroups(imported, mode: .merge).outcome
    }

    /// §1.10: the old implementation did `current[idx] = group`, so importing an
    /// Espanso `base.yml` (group name = file basename) or a TextExpander group
    /// called "General" replaced the user's default group wholesale. Merge is now
    /// the default and never drops a local snippet.
    @discardableResult
    public func importGroups(_ imported: [SnippetGroup], mode: ImportMode) -> ImportSummary {
        rmwLock.lock()
        defer { rmwLock.unlock() }
        return importGroupsSerialized(imported, mode: mode)
    }

    /// Caller owns `rmwLock`. Shared by the ordinary group API and the image
    /// promotion transaction so orphan collection cannot observe a promoted
    /// attachment before its library reference commits.
    private func importGroupsSerialized(
        _ imported: [SnippetGroup],
        mode: ImportMode
    ) -> ImportSummary {
        var current = loadGroups()
        var created: [String] = []
        var updatedGroups: [String] = []
        var added = 0
        var changed = 0
        var unchanged = 0

        for group in imported {
            switch mode {
            case .intoNewGroup:
                var copy = group
                // "Duplicate" is a new library entity, not another occurrence of the vendor's
                // stable UUID. Repeating the same import must therefore create a fresh identity
                // every time, even when the first vendor UUID did not collide yet.
                copy.id = Self.freshGroupID(excluding: current)
                copy.name = Self.uniqueGroupName(base: group.name, existing: current.map(\.name))
                added += copy.snippets.count
                current.append(copy)
                created.append(copy.name)

            case .replaceGroup:
                if let idx = Self.importTargetIndex(named: group.name, in: current) {
                    added += group.snippets.count
                    var replacement = group
                    // Replacement keeps the local entity's identity; importing a vendor UUID
                    // must not invalidate selection/restoration state or collide with a peer.
                    replacement.id = current[idx].id
                    current[idx] = replacement
                    updatedGroups.append(group.name)
                } else {
                    var copy = group
                    if current.contains(where: { $0.id == copy.id }) {
                        copy.id = Self.freshGroupID(excluding: current)
                    }
                    added += group.snippets.count
                    current.append(copy)
                    created.append(group.name)
                }

            case .merge:
                if let idx = Self.importTargetIndex(named: group.name, in: current) {
                    let result = Self.mergeSnippets(incoming: group.snippets, into: current[idx].snippets)
                    current[idx].snippets = result.snippets
                    added += result.added
                    changed += result.updated
                    unchanged += result.unchanged
                    if result.added > 0 || result.updated > 0 {
                        updatedGroups.append(group.name)
                    }
                } else {
                    var copy = group
                    if current.contains(where: { $0.id == copy.id }) {
                        copy.id = Self.freshGroupID(excluding: current)
                    }
                    added += group.snippets.count
                    current.append(copy)
                    created.append(group.name)
                }

            case .skipConflicts:
                if let idx = Self.importTargetIndex(named: group.name, in: current) {
                    let result = Self.mergeSnippets(
                        incoming: group.snippets,
                        into: current[idx].snippets,
                        updateMatches: false
                    )
                    current[idx].snippets = result.snippets
                    added += result.added
                    unchanged += result.unchanged
                    if result.added > 0 {
                        updatedGroups.append(group.name)
                    }
                } else {
                    var copy = group
                    if current.contains(where: { $0.id == copy.id }) {
                        copy.id = Self.freshGroupID(excluding: current)
                    }
                    added += group.snippets.count
                    current.append(copy)
                    created.append(group.name)
                }
            }
        }

        // `rmwLock` is already held for this whole read-modify-write; the public
        // `saveGroups` would try to re-acquire it and deadlock.
        let outcome = saveGroupsSerialized(current)
        return ImportSummary(
            mode: mode,
            groupsCreated: created,
            groupsUpdated: updatedGroups,
            snippetsAdded: added,
            snippetsUpdated: changed,
            snippetsUnchanged: unchanged,
            outcome: outcome
        )
    }

    /// Preview a prepared source against the store's current library snapshot.
    /// Commit still reloads under `rmwLock`, preserving edits made while the
    /// confirmation sheet is open.
    public func previewImport(_ plan: SnippetImporter.ImportPlan) -> ImportPreview {
        Self.previewImport(plan, against: loadGroups())
    }

    /// Pure preview seam for tests and UI projections. Same-named imported
    /// groups are simulated in order because commit does the same; a trigger in
    /// another group is deliberately not a collision.
    public static func previewImport(
        _ plan: SnippetImporter.ImportPlan,
        against existingGroups: [SnippetGroup]
    ) -> ImportPreview {
        var projected = existingGroups
        var items: [ImportPreview.Item] = []

        for group in plan.groups {
            if let index = importTargetIndex(named: group.name, in: projected) {
                let merge = mergeSnippets(incoming: group.snippets, into: projected[index].snippets)
                projected[index].snippets = merge.snippets
                items.append(contentsOf: zip(group.snippets, merge.statuses).map { snippet, status in
                    ImportPreview.Item(snippet: snippet, groupName: group.name, status: status)
                })
            } else {
                projected.append(group)
                items.append(contentsOf: group.snippets.map {
                    ImportPreview.Item(snippet: $0, groupName: group.name, status: .isNew)
                })
            }
        }

        return ImportPreview(plan: plan, items: items)
    }

    private static func importTargetIndex(named name: String, in groups: [SnippetGroup]) -> Int? {
        groups.firstIndex { $0.name == name && $0.id != SnippetDocument.secretGroupID }
    }

    private static func freshGroupID(excluding groups: [SnippetGroup]) -> UUID {
        let occupied = Set(groups.map(\.id))
        var candidate = UUID()
        while occupied.contains(candidate) { candidate = UUID() }
        return candidate
    }

    private struct MergeResult {
        var snippets: [SnippetModel]
        var added: Int
        var updated: Int
        var unchanged: Int
        var statuses: [ImportPreview.Status]
    }

    private static func mergeSnippets(
        incoming: [SnippetModel],
        into local: [SnippetModel],
        updateMatches: Bool = true
    ) -> MergeResult {
        var result = local
        var exactIndex: [String: Int] = [:]
        var foldedIndex: [String: Int] = [:]
        for (i, snippet) in result.enumerated() where !snippet.triggerKeyword.isEmpty {
            if exactIndex[snippet.triggerKeyword] == nil {
                exactIndex[snippet.triggerKeyword] = i
            }
            let folded = snippet.triggerKeyword.lowercased()
            if foldedIndex[folded] == nil {
                foldedIndex[folded] = i
            }
        }

        var added = 0
        var updated = 0
        var unchanged = 0
        var statuses: [ImportPreview.Status] = []

        for candidate in incoming {
            let trigger = candidate.triggerKeyword
            let folded = trigger.lowercased()
            let exactMatch = trigger.isEmpty ? nil : exactIndex[trigger]
            let foldedMatch = trigger.isEmpty ? nil : foldedIndex[folded]
            let match = exactMatch ?? foldedMatch

            guard let idx = match else {
                result.append(candidate)
                if !trigger.isEmpty {
                    let position = result.count - 1
                    if exactIndex[trigger] == nil { exactIndex[trigger] = position }
                    if foldedIndex[folded] == nil { foldedIndex[folded] = position }
                }
                added += 1
                statuses.append(.isNew)
                continue
            }

            let localSnippet = result[idx]
            statuses.append(
                exactMatch != nil || localSnippet.id == candidate.id ? .isUpdate : .isConflict
            )
            if !updateMatches {
                unchanged += 1
                continue
            }
            var mergedTags = localSnippet.tags
            for tag in candidate.tags where !mergedTags.contains(tag) {
                mergedTags.append(tag)
            }

            // Local identity and enablement win so usage stats, references, and a
            // deliberate "off" switch survive a re-import.
            let merged = SnippetModel(
                id: localSnippet.id,
                title: candidate.title.isEmpty ? localSnippet.title : candidate.title,
                label: candidate.label.isEmpty ? localSnippet.label : candidate.label,
                triggerKeyword: localSnippet.triggerKeyword,
                replacementText: candidate.replacementText,
                isCaseSensitive: candidate.isCaseSensitive,
                propagateCase: candidate.propagateCase,
                requireWordBoundary: candidate.requireWordBoundary,
                isPlainText: candidate.isPlainText,
                enabled: localSnippet.enabled,
                imagePath: candidate.imagePath.isEmpty ? localSnippet.imagePath : candidate.imagePath,
                createdAt: localSnippet.createdAt,
                updatedAt: Date(),
                usageCount: localSnippet.usageCount,
                tags: mergedTags,
                includeApps: candidate.includeApps.isEmpty ? localSnippet.includeApps : candidate.includeApps,
                excludeApps: candidate.excludeApps.isEmpty ? localSnippet.excludeApps : candidate.excludeApps
            )

            let identical = localSnippet.title == merged.title
                && localSnippet.label == merged.label
                && localSnippet.replacementText == merged.replacementText
                && localSnippet.isCaseSensitive == merged.isCaseSensitive
                && localSnippet.propagateCase == merged.propagateCase
                && localSnippet.requireWordBoundary == merged.requireWordBoundary
                && localSnippet.isPlainText == merged.isPlainText
                && localSnippet.imagePath == merged.imagePath
                && localSnippet.tags == merged.tags
                && localSnippet.includeApps == merged.includeApps
                && localSnippet.excludeApps == merged.excludeApps

            if identical {
                unchanged += 1
            } else {
                result[idx] = merged
                updated += 1
            }
        }

        return MergeResult(
            snippets: result,
            added: added,
            updated: updated,
            unchanged: unchanged,
            statuses: statuses
        )
    }

    private static func uniqueGroupName(base: String, existing: [String]) -> String {
        let name = base.isEmpty ? SnippetDocument.defaultGroupName : base
        let taken = Set(existing)
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)") { suffix += 1 }
        return "\(name) \(suffix)"
    }

    /// Convenience for non-preview callers: auto-detect once, prepare a value
    /// plan, then merge that plan into the library.
    @discardableResult
    public func importSnippets(from url: URL) throws -> SnippetImporter.ImportResult {
        let plan = try SnippetImporter.prepareImport(from: url)
        let committed = commitImport(plan, mode: .merge)
        guard committed.summary.outcome.didSave else {
            throw SnippetImporter.ImportError.libraryCommitFailed
        }
        return committed.result
    }

    /// §1.10: same as `importSnippets(from:)` but returns the merge diff.
    public func importSnippets(from url: URL, mode: ImportMode) throws -> (SnippetImporter.ImportResult, ImportSummary) {
        let plan = try SnippetImporter.prepareImport(from: url)
        return commitImport(plan, mode: mode)
    }

    /// Commits the exact parsed value shown in the confirmation sheet. No URL is
    /// retained or read here; the store rebases these groups onto its current
    /// library under the existing serialized read-modify-write boundary.
    public func commitImport(
        _ plan: SnippetImporter.ImportPlan,
        mode: ImportMode
    ) -> (result: SnippetImporter.ImportResult, summary: ImportSummary) {
        rmwLock.lock()
        defer { rmwLock.unlock() }

        let materialized: SnippetImporter.MaterializedImport
        do {
            materialized = try plan.materializeAttachments()
        } catch {
            return (
                plan.result,
                ImportSummary(
                    mode: mode,
                    groupsCreated: [],
                    groupsUpdated: [],
                    snippetsAdded: 0,
                    snippetsUpdated: 0,
                    snippetsUnchanged: 0,
                    outcome: .failed("attachmentCommitFailed")
                )
            )
        }

        let summary = importGroupsSerialized(materialized.result.groups, mode: mode)
        guard summary.outcome.didSave else {
            materialized.rollbackAll()
            return (materialized.result, summary)
        }

        // `.skipConflicts` can deliberately decline an incoming image snippet.
        // Remove only files created by this promotion that the committed library
        // does not reference; never run a broad orphan sweep here.
        materialized.removeUnreferenced(from: loadGroups())
        return (materialized.result, summary)
    }
}
